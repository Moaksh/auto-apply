"""Answer memory: Q->A store with semantic matching, and question clustering for the inbox.

Embeddings are LOCAL (no tokens). The default :class:`HashingEmbedder` is a stateless
TF-style hashing vectoriser (scikit-learn ``HashingVectorizer``: word 1-2 grams + char
3-5 grams + intent tags) so stored vectors stay comparable across process restarts (a
fitted TF-IDF vocabulary would not). Paraphrases ("Why us?" vs "Why do you want to work
here?") are pulled together by :func:`textnorm.question_intents` tags and a synonym fold.
``model2vec`` may be used when installed (optional extra) via :class:`Model2VecEmbedder`,
but nothing depends on it. Vectors are stored via ``db.set_answer_embedding`` /
``db.set_question_embedding`` together with ``embedder.model_name``; rows embedded by a
different model are re-embedded lazily.
"""

from __future__ import annotations

import re
import sqlite3
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

import numpy as np

from autoapply import db
from autoapply.answers.textnorm import canonical_text, extract_country, normalize_question, question_intents
from autoapply.enums import AnswerSource, FieldType, QuestionKind, QuestionStatus
from autoapply.llm.provider import LLMError, LLMProvider
from autoapply.models import Answer, Question


@runtime_checkable
class Embedder(Protocol):
    model_name: str

    def embed(self, texts: Sequence[str]) -> np.ndarray:
        """(len(texts), dim) float32 array, L2-normalised rows."""
        ...


#: Intents whose *subject* matters ("years of Python" != "years of Go"): the subject's
#: content words become part of the intent token.
_SUBJECT_INTENTS = frozenset({"years_experience"})
_SUBJECT_FILLER = frozenset({"years", "year", "yrs", "experience", "exp", "how", "many", "much", "professional", "total", "work", "working", "hands"})


def intent_tokens(text: str) -> list[str]:
    out = []
    for i in question_intents(text):
        if i in _SUBJECT_INTENTS:
            subject = sorted({t for t in canonical_text(text).split() if t not in _SUBJECT_FILLER})
            out.append(f"intent_{i}:" + "+".join(subject))
        else:
            out.append(f"intent_{i}")
    return out


def _l2(m: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(m, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return m / norms


class HashingEmbedder:
    """Stateless local embedder (default). Deterministic across runs and machines."""

    def __init__(self, dim: int = 1024, *, w_word: float = 0.5, w_char: float = 0.3, w_intent: float = 1.0) -> None:
        from sklearn.feature_extraction.text import HashingVectorizer

        self.dim = dim
        self.weights = (w_word, w_char, w_intent)
        self.model_name = f"hash-v1-{dim}"
        common = {"n_features": dim, "alternate_sign": False, "norm": None, "lowercase": True}
        self._word = HashingVectorizer(analyzer="word", ngram_range=(1, 2), token_pattern=r"(?u)\b\w[\w+#]*\b", **common)
        self._char = HashingVectorizer(analyzer="char_wb", ngram_range=(3, 5), **common)
        self._intent = HashingVectorizer(analyzer="word", token_pattern=r"\S+", **common)

    def embed(self, texts: Sequence[str]) -> np.ndarray:
        if not texts:
            return np.zeros((0, self.dim * 3), dtype=np.float32)
        canon = [canonical_text(t) or normalize_question(t) for t in texts]
        intents = [" ".join(intent_tokens(t)) for t in texts]
        parts = []
        for vec, src, w in ((self._word, canon, self.weights[0]), (self._char, canon, self.weights[1]), (self._intent, intents, self.weights[2])):
            m = np.log1p(vec.transform(src).toarray().astype(np.float32))
            parts.append(_l2(m) * w)
        return _l2(np.hstack(parts)).astype(np.float32)


class Model2VecEmbedder:
    """Optional static-embedding model (``pip install autoapply[model2vec]``). Downloads a
    model on first use, so it is never used in tests."""

    def __init__(self, model: str = "minishlab/potion-base-8M") -> None:
        from model2vec import StaticModel  # type: ignore[import-not-found]

        self._model = StaticModel.from_pretrained(model)
        self.model_name = f"model2vec:{model}"

    def embed(self, texts: Sequence[str]) -> np.ndarray:
        if not texts:
            return np.zeros((0, 1), dtype=np.float32)
        return _l2(np.asarray(self._model.encode(list(texts)), dtype=np.float32))


_DEFAULT: Embedder | None = None


def default_embedder() -> Embedder:
    """Process-wide default embedder (the hashing one)."""
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = HashingEmbedder()
    return _DEFAULT


def intents_compatible(a: str, b: str) -> bool:
    """False when both questions carry intent tags and they share none (e.g. "Why us?"
    vs "Why this role?", or salary vs notice period)."""
    ia, ib = set(question_intents(a)), set(question_intents(b))
    return not (ia and ib and not (ia & ib))


@dataclass(slots=True)
class MemoryMatch:
    answer: Answer
    similarity: float  # cosine, 0..1
    rendered: str  # template tokens ({company}, {role}) substituted


_TEMPLATE_RX = re.compile(r"\{(company|role)\}")


def render_template(answer: str, *, company: str | None, role: str | None) -> str:
    """Substitute ``{company}`` / ``{role}`` tokens (unknown values -> neutral words)."""

    def sub(m: re.Match[str]) -> str:
        if m.group(1) == "company":
            return company or "your company"
        return role or "this role"

    return _TEMPLATE_RX.sub(sub, answer)


class AnswerMemory:
    """Canonical Q->A memory over the ``answers`` table."""

    def __init__(
        self,
        conn: sqlite3.Connection,
        embedder: Embedder | None = None,
        *,
        threshold: float = 0.82,
        llm: LLMProvider | None = None,
        grey_zone: float = 0.62,
    ) -> None:
        self.conn = conn
        self.embedder = embedder or default_embedder()
        self.threshold = threshold
        self.llm = llm
        self.grey_zone = grey_zone

    # ---- embeddings ------------------------------------------------------------------

    def _ensure_answer_embeddings(self) -> None:
        rows = self.conn.execute(
            "SELECT id, canonical_question FROM answers WHERE embedding IS NULL OR embedding_model IS NOT ?",
            (self.embedder.model_name,),
        ).fetchall()
        if not rows:
            return
        vecs = self.embedder.embed([r["canonical_question"] for r in rows])
        with db.transaction(self.conn):
            for r, v in zip(rows, vecs, strict=True):
                db.set_answer_embedding(self.conn, int(r["id"]), v, self.embedder.model_name)

    def _ensure_question_embeddings(self, questions: list[Question]) -> dict[int, np.ndarray]:
        out: dict[int, np.ndarray] = {}
        stale: list[Question] = []
        rows = {
            int(r["id"]): r
            for r in self.conn.execute(
                "SELECT id, embedding, embedding_model FROM questions WHERE status = 'open'"
            ).fetchall()
        }
        for q in questions:
            r = rows.get(q.id)
            if r is not None and r["embedding"] is not None and r["embedding_model"] == self.embedder.model_name:
                out[q.id] = db.unpack_embedding(r["embedding"])  # type: ignore[assignment]
            else:
                stale.append(q)
        if stale:
            vecs = self.embedder.embed([q.canonical_question for q in stale])
            with db.transaction(self.conn):
                for q, v in zip(stale, vecs, strict=True):
                    db.set_question_embedding(self.conn, q.id, v, self.embedder.model_name)
                    out[q.id] = v
        return out

    def embed_one(self, text: str) -> np.ndarray:
        return self.embedder.embed([text])[0]

    # ---- lookup ----------------------------------------------------------------------

    def candidates(self, question: str, *, limit: int = 3) -> list[tuple[Answer, float]]:
        """Top answers by similarity (no threshold), intent-incompatible ones excluded."""
        self._ensure_answer_embeddings()
        embs = db.get_answer_embeddings(self.conn, self.embedder.model_name)
        if not embs:
            return []
        ids = [i for i, _ in embs]
        mat = np.vstack([v for _, v in embs])
        sims = mat @ self.embed_one(question)
        order = np.argsort(-sims)
        out: list[tuple[Answer, float]] = []
        for idx in order:
            ans = db.get_answer(self.conn, ids[int(idx)])
            if not intents_compatible(question, ans.canonical_question):
                continue
            out.append((ans, float(max(0.0, min(1.0, sims[int(idx)])))))
            if len(out) >= limit:
                break
        return out

    def _exact(self, question: str) -> Answer | None:
        found = db.find_answer_by_question(self.conn, question)
        if found is not None:
            return found
        norm = normalize_question(question)
        if not norm:
            return None
        for a in db.list_answers(self.conn):
            if normalize_question(a.canonical_question) == norm:
                return a
        return None

    def lookup(self, question: str, *, company: str | None = None, role: str | None = None) -> MemoryMatch | None:
        """Best stored answer for ``question`` above ``threshold`` (exact match first)."""
        exact = self._exact(question)
        if exact is not None:
            return MemoryMatch(exact, 1.0, render_template(exact.answer, company=company, role=role))
        cands = self.candidates(question, limit=1)
        if cands and cands[0][1] >= self.threshold:
            ans, sim = cands[0]
            return MemoryMatch(ans, sim, render_template(ans.answer, company=company, role=role))
        return None

    async def lookup_async(
        self, question: str, *, company: str | None = None, role: str | None = None
    ) -> MemoryMatch | None:
        """:meth:`lookup`, plus an LLM paraphrase check for grey-zone candidates
        (``grey_zone <= sim < threshold``) when an ``llm`` was given."""
        hit = self.lookup(question, company=company, role=role)
        if hit is not None or self.llm is None:
            return hit
        cands = self.candidates(question, limit=2)
        for ans, sim in cands:
            if sim < self.grey_zone:
                break
            if await self._same_question(question, ans.canonical_question):
                return MemoryMatch(ans, sim, render_template(ans.answer, company=company, role=role))
        return None

    async def _same_question(self, a: str, b: str) -> bool:
        assert self.llm is not None
        schema = {
            "type": "object",
            "properties": {"same": {"type": "boolean"}},
            "required": ["same"],
            "additionalProperties": False,
        }
        prompt = (
            "PARAPHRASE CHECK. Do these two job-application questions ask for the same information, "
            "so that one stored answer would correctly answer both?\n"
            f"Q1: {a}\nQ2: {b}"
        )
        try:
            res = await self.llm.complete(prompt, system="You compare job application questions.", tier="fast", schema=schema, max_tokens=50)
        except LLMError:
            return False
        return bool(res.data and res.data.get("same"))

    def record_use(self, answer_id: int) -> None:
        db.record_answer_use(self.conn, answer_id)

    # ---- write -----------------------------------------------------------------------

    def save(
        self,
        question: str,
        answer: str,
        *,
        source: str | AnswerSource = "user",
        field_type: str | FieldType = "text",
    ) -> Answer:
        """Persist (and embed) an answer. Same question text (case-insensitive) updates."""
        vec = self.embed_one(question)
        return db.add_answer(
            self.conn, canonical_question=question.strip(), answer=answer, field_type=field_type, source=source,
            embedding=vec, embedding_model=self.embedder.model_name,
        )

    # ---- inbox clustering ------------------------------------------------------------

    def cluster_open_questions(self, *, threshold: float = 0.8) -> dict[str, list[Question]]:
        """Re-cluster open inbox questions by similarity; updates ``questions.cluster_id``.
        Returns cluster_id -> questions.

        * Questions mapped to the same never-guess key (and, for work authorisation,
          sponsorship and salary expectations, the same country) always share a cluster;
          different keys never merge. Catch-all keys (``unclassified_sensitive``,
          ``eeo_other``, ``current_salary``) cluster by similarity instead.
        * Others are grouped by average-link cosine similarity >= ``threshold`` with
          compatible intents.
        * Existing cluster ids are kept where possible (majority id of the members, ties ->
          oldest member) so the app's selection survives re-clustering.
        """
        qs = db.list_questions(self.conn, status=QuestionStatus.OPEN)
        if not qs:
            return {}
        vecs = self._ensure_question_embeddings(qs)
        groups: list[_Group] = []
        for q in qs:  # id order => deterministic
            key = self._cluster_key(q)
            best: tuple[float, _Group] | None = None
            for g in groups:
                if key is not None or g.key is not None:
                    if key == g.key:
                        best = (1.0, g)
                        break
                    continue
                if not all(intents_compatible(q.canonical_question, m.canonical_question) for m in g.members):
                    continue
                sim = float(np.mean([vecs[q.id] @ vecs[m.id] for m in g.members]))
                if sim >= threshold and (best is None or sim > best[0]):
                    best = (sim, g)
            if best is None:
                groups.append(_Group(key=key, members=[q]))
            else:
                best[1].members.append(q)

        used: set[str] = set()
        with db.transaction(self.conn):
            for g in sorted(groups, key=lambda g: g.members[0].id):
                counts = Counter(m.cluster_id for m in g.members)
                ranked = sorted(counts, key=lambda cid: (-counts[cid], min(m.id for m in g.members if m.cluster_id == cid)))
                cid = next((c for c in ranked if c not in used), None) or db.new_id()
                used.add(cid)
                for m in g.members:
                    if m.cluster_id != cid:
                        db.set_question_cluster(self.conn, m.id, cid)
        out: dict[str, list[Question]] = {}
        for q in db.list_questions(self.conn, status=QuestionStatus.OPEN):
            out.setdefault(q.cluster_id, []).append(q)
        return out

    def _cluster_key(self, q: Question) -> tuple[str, str | None] | None:
        """Forced-grouping key: agent actions group by (action type, companies) and never
        join form questions; never-guess questions by key (+ country); else None (similarity)."""
        if q.kind is QuestionKind.ACTION:
            return db.action_group_key(self.conn, q.canonical_question, q.reason.value, q.job_ids)
        return self._ng_cluster_key(q)

    def find_action_cluster_for(self, label: str, reason: str | None, job_id: int) -> str | None:
        """Open action cluster for the same blocker at the same company as ``job_id``, if any."""
        key = db.action_group_key(self.conn, label, reason, [job_id])
        for q in db.list_questions(self.conn, status=QuestionStatus.OPEN):
            if q.kind is QuestionKind.ACTION and self._cluster_key(q) == key:
                return q.cluster_id
        return None

    def _ng_cluster_key(self, q: Question) -> tuple[str, str | None] | None:
        """Cluster key of a stored question. For country-scoped keys whose wording names no
        country, the country of the question's job(s) is used when they all agree."""
        return _ng_key_for(q.never_guess_key, q.canonical_question, country=self._jobs_country(q.job_ids))

    def _jobs_country(self, job_ids: list[int]) -> str | None:
        codes: set[str | None] = set()
        for jid in job_ids:
            try:
                job = db.get_job(self.conn, jid)
            except db.NotFound:
                return None
            codes.add(extract_country(job.location, location_mode=True) if job.location else None)
        return next(iter(codes)) if len(codes) == 1 else None

    def find_cluster_for(
        self, question: str, never_guess_key: str | None = None, *, threshold: float = 0.8, country: str | None = None
    ) -> str | None:
        """Cluster id of an existing OPEN cluster that ``question`` belongs to, if any.
        ``country`` (the job's ISO-2 country) scopes work_auth / sponsorship / salary
        questions whose wording names no country."""
        qs = db.list_questions(self.conn, status=QuestionStatus.OPEN)
        if not qs:
            return None
        key = _ng_key_for(never_guess_key, question, country=country)
        vecs = self._ensure_question_embeddings(qs)
        v = self.embed_one(question)
        by_cluster: dict[str, list[Question]] = {}
        for q in qs:
            by_cluster.setdefault(q.cluster_id, []).append(q)
        best: tuple[float, str] | None = None
        for cid, members in by_cluster.items():
            if any(m.kind is QuestionKind.ACTION for m in members):
                continue  # form questions never join an agent action
            gkey = next((k for k in (self._ng_cluster_key(m) for m in members) if k is not None), None)
            if key is not None or gkey is not None:
                if key == gkey:
                    return cid
                continue
            if not all(intents_compatible(question, m.canonical_question) for m in members):
                continue
            sim = float(np.mean([v @ vecs[m.id] for m in members]))
            if sim >= threshold and (best is None or sim > best[0]):
                best = (sim, cid)
        return best[1] if best else None


@dataclass(slots=True)
class _Group:
    key: tuple[str, str | None] | None
    members: list[Question] = field(default_factory=list)


#: Catch-all sensitive keys: two questions sharing one of these can ask entirely different
#: things ("nationality?" vs "consent to our privacy terms?"), so they cluster by
#: similarity like ordinary questions instead of by key.
_CATCH_ALL_KEYS = frozenset({"unclassified_sensitive", "eeo_other", "current_salary"})
#: Keys whose correct answer depends on the country of the job.
COUNTRY_SCOPED_KEYS = frozenset({"work_auth", "sponsorship", "salary_expectation"})


def _ng_key_for(key: str | None, text: str, *, country: str | None = None) -> tuple[str, str | None] | None:
    """Clustering key for a never-guess question, or None (=> similarity clustering).

    Country-scoped keys merge only within one country (named in the question, or the
    ``[job location: ...]`` tag :func:`autoapply.prep.inbox_label` adds); with no country
    identified only the identical wording merges."""
    if not key or key in _CATCH_ALL_KEYS:
        return None
    if key in COUNTRY_SCOPED_KEYS:
        return (key, extract_country(text) or country or "text:" + normalize_question(text))
    return (key, None)


def similarity(a: str, b: str, embedder: Embedder | None = None) -> float:
    """Cosine similarity of two questions with the given (default) embedder."""
    e = embedder or default_embedder()
    m = e.embed([a, b])
    return float(m[0] @ m[1])


__all__: list[Any] = [
    "COUNTRY_SCOPED_KEYS", "AnswerMemory", "Embedder", "HashingEmbedder", "MemoryMatch", "Model2VecEmbedder", "default_embedder",
    "intents_compatible", "render_template", "similarity",
]
