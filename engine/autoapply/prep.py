"""Prep pass: harvest form questions for queued jobs, resolve them against profile /
never_guess / answer memory, and park the rest in the Needs-You inbox (clustered).

Also home to the inbox mutations the daemon calls for socket commands:

* :func:`answer_cluster` (``answer_question``) — saves the answer (memory / never_guess /
  per-job), resolves the cluster and re-queues every parked job that has no other open
  question (needs_you -> queued).
* :func:`skip_cluster` (``skip_question``) — parked jobs -> skipped.
* :func:`park_unresolved` — used by the pipeline when ``fill()`` returns unresolved fields.

Question sources, cheapest first: the ATS question data already captured by discovery in
``job.raw`` (Greenhouse ``questions``, Ashby ``applicationForm``, or a generic
``form_questions`` list), then the adapter's ``harvest_questions`` (API for GH/Lever/Ashby,
browser scan for others — see :class:`autoapply.apply.agentic.AgenticAdapter`).
"""

from __future__ import annotations

import logging
import re
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from autoapply import db
from autoapply.answers.guardrails import NeedsUser
from autoapply.answers.memory import COUNTRY_SCOPED_KEYS, AnswerMemory, render_template
from autoapply.answers.resolver import AnswerResolver, set_inbox_answers
from autoapply.answers.textnorm import COUNTRY_ALIASES, extract_country, normalize_question, yes_no
from autoapply.apply.base import Adapter, ApplyContext, EmitFn, PausedError, UnresolvedField, select_adapter
from autoapply.config import NEVER_GUESS_KEYS
from autoapply.enums import Actor, AnswerOrigin, AnswerSource, AppState, DaemonActivity, FieldType, QuestionReason, QuestionStatus
from autoapply.llm.provider import LLMProvider
from autoapply.models import (
    FormQuestion,
    Job,
    Progress,
    QuestionOpenedPayload,
    QuestionResolvedPayload,
    StatePayload,
)
from autoapply.paths import get_paths

log = logging.getLogger(__name__)

#: Cosine threshold for grouping inbox questions into one cluster.
CLUSTER_THRESHOLD = 0.78


@dataclass(slots=True)
class PrepReport:
    jobs_scanned: int = 0
    questions_seen: int = 0
    resolved: int = 0
    parked_jobs: list[int] = field(default_factory=list)
    new_cluster_ids: list[str] = field(default_factory=list)
    touched_cluster_ids: list[str] = field(default_factory=list)
    requeued_jobs: list[int] = field(default_factory=list)
    harvest_failed_jobs: list[int] = field(default_factory=list)
    paused: bool = False
    tokens_in: int = 0
    tokens_out: int = 0


# =====================================================================================
# question data captured at discovery time
# =====================================================================================

_GH_TYPES = {
    "input_text": FieldType.TEXT, "textarea": FieldType.TEXTAREA, "input_file": FieldType.FILE,
    "multi_value_single_select": FieldType.SELECT, "multi_value_multi_select": FieldType.MULTISELECT,
}
_ASHBY_TYPES = {
    "String": FieldType.TEXT, "LongText": FieldType.TEXTAREA, "Boolean": FieldType.BOOLEAN, "ValueSelect": FieldType.SELECT,
    "MultiValueSelect": FieldType.MULTISELECT, "File": FieldType.FILE, "Email": FieldType.EMAIL, "Phone": FieldType.PHONE,
    "Number": FieldType.NUMBER, "Date": FieldType.DATE, "SocialLink": FieldType.URL, "Url": FieldType.URL,
}


def questions_from_raw(job: Job) -> list[FormQuestion] | None:
    """Form questions already present in ``job.raw`` (no network), or None if absent."""
    raw = job.raw or {}
    if isinstance(raw.get("form_questions"), list):
        return [FormQuestion.model_validate(q) for q in raw["form_questions"]]
    out: list[FormQuestion] = []
    if isinstance(raw.get("questions"), list):  # Greenhouse boards-api ?questions=true
        for q in raw["questions"]:
            if not isinstance(q, dict):
                continue
            label = (q.get("label") or "").strip()
            for f in q.get("fields") or []:
                ftype = f.get("type")
                if ftype not in _GH_TYPES:
                    continue
                out.append(
                    FormQuestion(
                        key=str(f.get("name") or label), label=label or str(f.get("name")), field_type=_GH_TYPES[ftype],
                        required=bool(q.get("required")), description=q.get("description") or None,
                        options=[str(v.get("label")) for v in f.get("values") or [] if v.get("label") is not None],
                    )
                )
                break  # one FormQuestion per GH question (file+text alternatives -> first)
        return out
    form = raw.get("applicationForm")
    if isinstance(form, dict):  # Ashby posting API
        for sec in form.get("sections") or []:
            for entry in sec.get("fieldEntries") or []:
                f = entry.get("field") or {}
                ftype = _ASHBY_TYPES.get(f.get("type"), FieldType.TEXT)
                out.append(
                    FormQuestion(
                        key=str(f.get("path") or f.get("id") or f.get("title")), label=str(f.get("title") or f.get("path")),
                        field_type=ftype, required=bool(entry.get("isRequired")),
                        description=entry.get("descriptionPlain") or None,
                        options=[str(v.get("label")) for v in f.get("selectableValues") or [] if v.get("label") is not None],
                    )
                )
        return out
    return None


# =====================================================================================
# parking
# =====================================================================================


_TAG_RX = re.compile(r"\s*\[job location: [^\]]*\]\s*$")


def _country_name(code: str) -> str:
    alias = next((a for a, c in COUNTRY_ALIASES.items() if c == code and len(a) > 3), None)
    return alias.title() if alias else code


def inbox_label(label: str, never_guess_key: str | None, job: Job, company_name: str, description: str | None = None) -> str:
    """Inbox wording for a parked question.

    For country-dependent never-guess questions (work authorisation, sponsorship, salary
    expectations) whose wording names no country ("...the country where this role is
    based"), the job's country is appended — ``"<label> [job location: United Kingdom]"``
    — so the same wording asked by a US job and a UK job becomes two inbox questions with
    two answers. With no identifiable country the company/location is appended instead
    (never merged with other jobs)."""
    label = label.strip()
    if never_guess_key not in COUNTRY_SCOPED_KEYS or extract_country(f"{label} {description or ''}"):
        return label
    code = extract_country(job.location, location_mode=True) if job.location else None
    tag = _country_name(code) if code else f"{company_name}, {job.location or 'location not stated'} (country unknown)"
    return f"{label} [job location: {tag}]"


def form_label(canonical_question: str) -> str:
    """The form's own wording of an inbox question (drops the ``[job location: ...]`` tag)."""
    return _TAG_RX.sub("", canonical_question).strip()


def park_unresolved(
    conn: sqlite3.Connection,
    job_id: int,
    unresolved: list[UnresolvedField] | list[NeedsUser],
    *,
    memory: AnswerMemory | None = None,
) -> tuple[list[int], set[str]]:
    """Add each unresolved field to the inbox for ``job_id`` (joining an equivalent open
    cluster when one exists). Returns (created question ids, touched cluster ids).
    Does NOT change the application state (the caller transitions to needs_you)."""
    memory = memory or AnswerMemory(conn)
    created: list[int] = []
    touched: set[str] = set()
    job = db.get_job(conn, job_id)
    company_name = db.get_company(conn, job.company_id).name
    job_country = extract_country(job.location, location_mode=True) if job.location else None
    for item in unresolved:
        uf = item.to_unresolved() if isinstance(item, NeedsUser) else item
        label = inbox_label(uf.question.label, uf.never_guess_key, job, company_name, uf.question.description)
        cluster_id = memory.find_cluster_for(label, uf.never_guess_key, threshold=CLUSTER_THRESHOLD, country=job_country)
        vec = memory.embed_one(label)
        q, was_created = db.add_question(
            conn, canonical_question=label, job_id=job_id, cluster_id=cluster_id, field_type=uf.question.field_type,
            options=uf.question.options, never_guess_key=uf.never_guess_key, reason=QuestionReason(uf.reason),
            embedding=vec, embedding_model=memory.embedder.model_name,
            suggested_answer=uf.suggested_answer, suggested_confidence=uf.confidence,
        )
        if was_created:
            created.append(q.id)
        touched.add(q.cluster_id)
    return created, touched


# =====================================================================================
# the prep pass
# =====================================================================================


async def _noop_emit(_type: str, _payload: Any) -> None:
    return None


def build_context(
    conn: sqlite3.Connection,
    application_id: int,
    *,
    llm: LLMProvider,
    emit: EmitFn,
    is_paused: Callable[[], bool] | None = None,
    run_id: str | None = None,
) -> ApplyContext:
    app = db.get_application(conn, application_id)
    job = db.get_job(conn, app.job_id)
    resume = db.get_resume_variant(conn, app.resume_variant_id) if app.resume_variant_id else None
    paths = get_paths(create=True)
    return ApplyContext(
        conn=conn, application=app, job=job, profile=db.get_profile(conn), never_guess=db.get_never_guess(conn),
        preferences=db.get_preferences(conn), llm=llm, resume=resume,
        screenshots_dir=paths.application_screenshot_dir(app.id), emit=emit,
        is_paused=is_paused or (lambda: False), run_id=run_id,
    )


async def run_prep(
    conn: sqlite3.Connection,
    *,
    llm: LLMProvider,
    adapters: list[Adapter],
    emit: EmitFn,
    application_ids: list[int] | None = None,
    is_paused: Callable[[], bool] | None = None,
    run_id: str | None = None,
    run_row_id: int | None = None,
    memory: AnswerMemory | None = None,
) -> PrepReport:
    """Run the prep pass over queued applications (or the given ids).

    Transitions: queued -> prepping -> (queued | needs_you). Emits ``application_state``
    for every transition, ``question_opened`` for new or grown clusters, and ``state``
    progress events. Stops between jobs when paused (``report.paused``).
    """
    emit = emit or _noop_emit
    paused = is_paused or (lambda: False)
    memory = memory or AnswerMemory(conn, llm=llm)
    report = PrepReport()
    if application_ids is None:
        apps = db.list_applications(conn, states=[AppState.QUEUED])
    else:
        apps = [db.get_application(conn, i) for i in application_ids]
        apps = [a for a in apps if a.state is AppState.QUEUED]
    open_before = {q.cluster_id for q in db.list_questions(conn, status=QuestionStatus.OPEN)}
    created_q: list[int] = []
    touched: set[str] = set()
    total = len(apps)

    async def progress(done: int, message: str, app_id: int | None = None, job_id: int | None = None) -> None:
        await emit("state", StatePayload(
            daemon=DaemonActivity.PREPPING, run_id=run_id, progress=Progress(done=done, total=total), message=message,
            active_application_id=app_id, active_job_id=job_id,
        ))

    await progress(0, f"Collecting questions from {total} queued jobs…")
    for i, app in enumerate(apps):
        if paused():
            report.paused = True
            break
        job = db.get_job(conn, app.job_id)
        company = db.get_company(conn, job.company_id)
        t = db.transition(conn, app.id, AppState.PREPPING, reason="prep", expected_from=AppState.QUEUED, run_id=run_row_id)
        await emit("application_state", t.to_payload())
        report.jobs_scanned += 1
        await progress(i, f"Collecting questions · {company.name} · {job.title}", app.id, job.id)

        ctx = build_context(conn, app.id, llm=llm, emit=emit, is_paused=paused, run_id=run_id)
        questions = questions_from_raw(job)
        if questions is None:
            adapter = select_adapter(job, adapters)
            try:
                if adapter is None:
                    raise LookupError("no adapter can handle this job")
                questions = await adapter.harvest_questions(ctx)
            except PausedError:
                t = db.transition(conn, app.id, AppState.QUEUED, reason="paused", run_id=run_row_id)
                await emit("application_state", t.to_payload())
                report.paused = True
                break
            except Exception as e:  # harvest is best-effort: fill() will meet the questions anyway
                log.warning("prep: harvest failed for job %s: %s", job.id, e)
                db.log_event(conn, "prep", f"question harvest failed: {e}", level="warning", job_id=job.id, application_id=app.id)
                t = db.transition(conn, app.id, AppState.QUEUED, reason="harvest_unavailable", run_id=run_row_id)
                await emit("application_state", t.to_payload())
                report.harvest_failed_jobs.append(job.id)
                continue

        resolver = AnswerResolver.from_context(ctx, memory=memory)
        batch = await resolver.resolve_all(questions)
        report.questions_seen += len(questions)
        report.resolved += len(batch.resolved)
        report.tokens_in += resolver.usage.input_tokens
        report.tokens_out += resolver.usage.output_tokens
        if resolver.usage.total_tokens:
            db.add_application_tokens(conn, app.id, resolver.usage.input_tokens, resolver.usage.output_tokens)

        # Same rule as fill(): an optional field the agent can't answer is left blank, so it
        # must not park the job (e.g. Greenhouse's optional EEOC / demographic questions).
        batch.unresolved = [nu for nu in batch.unresolved if nu.question.required]
        if batch.unresolved:
            new_ids, clusters = park_unresolved(conn, job.id, batch.unresolved, memory=memory)
            created_q.extend(new_ids)
            touched |= clusters
            n = len(batch.unresolved)
            t = db.transition(conn, app.id, AppState.NEEDS_YOU, reason=f"{n} question{'s' if n != 1 else ''} need you", run_id=run_row_id)
            report.parked_jobs.append(job.id)
        else:
            t = db.transition(conn, app.id, AppState.QUEUED, reason="prepped", run_id=run_row_id)
            report.requeued_jobs.append(job.id)
        await emit("application_state", t.to_payload())

    # Re-cluster (merges paraphrases parked by different jobs) and announce.
    clusters = memory.cluster_open_questions(threshold=CLUSTER_THRESHOLD)
    created_set = set(created_q)
    for cid, qs in clusters.items():
        if any(q.id in created_set for q in qs) or cid in touched:
            report.touched_cluster_ids.append(cid)
            if cid not in open_before:
                report.new_cluster_ids.append(cid)
            cluster = db.get_cluster(conn, cid)
            if cluster is not None:
                await emit("question_opened", QuestionOpenedPayload(cluster=cluster))
    await progress(report.jobs_scanned, f"Prep done · {len(report.parked_jobs)} jobs need you")
    return report


# =====================================================================================
# inbox mutations (socket commands)
# =====================================================================================


@dataclass(slots=True)
class ClusterOutcome:
    cluster_id: str
    status: str  # answered | skipped
    job_ids: list[int]
    transitions: list[db.Transition] = field(default_factory=list)
    answer_id: int | None = None
    saved_to_profile: bool = False
    #: other clusters that lost their last job as a side effect (now skipped): emit
    #: ``question_resolved`` (status skipped) for each — see :meth:`extra_resolved_payloads`
    extra_resolved: list[str] = field(default_factory=list)
    #: other clusters that lost some (not all) jobs: re-emit ``question_opened`` with
    #: ``db.get_cluster(conn, cid)`` for each
    changed: list[str] = field(default_factory=list)

    @property
    def application_ids(self) -> list[int]:
        return [t.application_id for t in self.transitions]

    def to_payload(self) -> QuestionResolvedPayload:
        return QuestionResolvedPayload(
            cluster_id=self.cluster_id, status=self.status,  # type: ignore[arg-type]
            answer_id=self.answer_id, resumed_application_ids=self.application_ids if self.status == "answered" else [],
        )

    def extra_resolved_payloads(self) -> list[QuestionResolvedPayload]:
        return [QuestionResolvedPayload(cluster_id=cid, status="skipped", answer_id=None, resumed_application_ids=[])
                for cid in self.extra_resolved]


_RIGHT_TO_WORK_RX = re.compile(
    r"\b(authori[sz]ed|eligible|legally (able|allowed|permitted)|legal right|right to work|permitted|allowed) to work\b"
    r"|\bright to work\b|\bwork (permit|authori[sz]ation)\b|\bwork legally\b|\bunrestricted right\b"
    r"|^\W*(are you )?authori[sz]ed\b",
    re.I,
)
_NOT_A_WORK_AUTH_FACT_RX = re.compile(r"\bdeemed export\b|\bif you selected\b|\bprior question\b|\bcuba|iran|north korea|syria\b|\bexport control", re.I)
_WHICH_COUNTRIES_RX = re.compile(r"\b(which|what) countr(y|ies)\b|\bin what countries\b|\blist (the )?countries\b", re.I)


def _status_word(answer: str) -> str | None:
    low = answer.strip().lower()
    for word, status in (("citizen", "citizen"), ("permanent resident", "permanent_resident"), ("green card", "permanent_resident"),
                         ("sponsor", "requires_sponsorship"), ("visa", "work_visa"), ("not authori", "not_authorized"),
                         ("authori", "authorized")):
        if word in low:
            return status
    return None


def never_guess_value(key: str, answer: str, *, question: str = "", country: str | None = None) -> dict[str, Any] | None:
    """Convert an inbox answer into a ``never_guess`` patch for ``key`` (None if it can't
    be stored safely, e.g. work authorisation without a known country)."""
    yn = yes_no(answer)
    if key == "work_auth":
        # Only a direct right-to-work question may become a stored fact. Questions merely tagged
        # work_auth ("Does the deemed export rule affect you?", sanctions follow-ups, "If you
        # selected…") are answered for the job only: a "No" there must never become
        # "not authorized to work in <job country>".
        if not _RIGHT_TO_WORK_RX.search(question) or _NOT_A_WORK_AUTH_FACT_RX.search(question):
            return None
        # "In which countries do you have the right to work?" -> the answer lists countries.
        if _WHICH_COUNTRIES_RX.search(question):
            named = {extract_country(part.strip()) for part in re.split(r"[,;/&]|\band\b", answer) if part.strip()}
            named.discard(None)
            return {"work_auth": {c: "authorized" for c in named}} if named else None
        c = extract_country(question) or country
        if not c:
            return None
        if yn is True:
            status = "authorized"
        elif yn is False:
            status = "requires_sponsorship" if "sponsor" in question.lower() else "not_authorized"
        else:
            # A free-text answer: a country name means "yes, authorised there"; a status word is kept.
            named = extract_country(answer)
            status = "authorized" if named == c else _status_word(answer)
            if status is None:
                return None
        return {"work_auth": {c: status}}
    if key == "sponsorship":
        if yn is True:
            return {"sponsorship": "Requires sponsorship"}
        if yn is False:
            return {"sponsorship": "Not required"}
        return {"sponsorship": answer.strip()}
    if key in {"salary_negotiable", "attest_accuracy", "attest_background_check"}:
        return None if yn is None else {key: yn}
    if key == "relocation":
        low = answer.lower()
        if "case" in low or "depend" in low or "open" in low and yn is None:
            return {"relocation": "case_by_case"}
        return None if yn is None else {"relocation": "yes" if yn else "no"}
    if key in NEVER_GUESS_KEYS and key != "eeo_policy" and key != "work_auth":
        return {key: answer.strip()}
    return None


def answer_cluster(
    conn: sqlite3.Connection,
    cluster_id: str,
    answer: str,
    *,
    save_to_memory: bool = True,
    save_to_profile: bool = False,
    per_job_answers: dict[int, str] | None = None,
    memory: AnswerMemory | None = None,
) -> ClusterOutcome:
    """Handle ``answer_question``. Atomic: memory/never_guess/per-job answers, cluster
    resolution and the needs_you -> queued transitions commit together.

    The daemon should then emit ``question_resolved`` (``outcome.to_payload()``) and one
    ``application_state`` per ``outcome.transitions``."""
    cluster = db.get_cluster(conn, cluster_id)
    if cluster is None:
        raise db.NotFound(f"open cluster {cluster_id!r} not found")
    memory = memory or AnswerMemory(conn)
    per_job = dict(per_job_answers or {})
    questions = db.list_questions(conn, cluster_id=cluster_id, status=QuestionStatus.OPEN)
    key = cluster.never_guess_key
    outcome = ClusterOutcome(cluster_id=cluster_id, status="answered", job_ids=list(cluster.job_ids))
    with db.transaction(conn):
        # 1. durable knowledge
        if key and key in NEVER_GUESS_KEYS:
            if save_to_profile:
                country = None
                for jid in cluster.job_ids:
                    country = extract_country(db.get_job(conn, jid).location, location_mode=True)
                    if country:
                        break
                patch = never_guess_value(key, answer, question=cluster.canonical_question, country=country)
                if patch is not None:
                    if key == "work_auth":
                        patch = {"work_auth": {**db.get_never_guess(conn).work_auth, **patch["work_auth"]}}
                    try:
                        db.set_never_guess(conn, patch)
                        outcome.saved_to_profile = True
                    except ValueError as e:
                        log.warning("answer_cluster: could not save never_guess %s: %s", key, e)
        elif save_to_memory and not cluster.canonical_question.startswith("Security code"):  # single-use codes
            saved = memory.save(form_label(cluster.canonical_question), answer, source=AnswerSource.USER, field_type=cluster.field_type)
            outcome.answer_id = saved.id
            # memory is keyed by the canonical wording; also teach the other wordings
            for variant in cluster.variants[1:]:
                if normalize_question(form_label(variant)) != normalize_question(form_label(cluster.canonical_question)):
                    memory.save(form_label(variant), answer, source=AnswerSource.USER, field_type=cluster.field_type)

        # 2. per-job answers (so this exact question resolves for these jobs at fill time)
        for q in questions:
            for jid in q.job_ids:
                job = db.get_job(conn, jid)
                company = db.get_company(conn, job.company_id)
                text = render_template(per_job.get(jid, answer), company=company.name, role=job.title)
                set_inbox_answers(conn, jid, {form_label(q.canonical_question): text})
                _patch_easy_apply(conn, jid, form_label(q.canonical_question), text)

        # 3. resolve + re-queue
        job_ids = db.resolve_cluster(conn, cluster_id, status=QuestionStatus.ANSWERED, answer_text=answer, answer_id=outcome.answer_id)
        for jid in db.jobs_without_open_questions(conn, job_ids):
            app = db.get_application_by_job(conn, jid)
            if app.state is AppState.NEEDS_YOU:
                outcome.transitions.append(db.transition(conn, app.id, AppState.QUEUED, reason="answered", actor=Actor.USER))
    return outcome


def skip_cluster(conn: sqlite3.Connection, cluster_id: str, *, reason: str | None = None) -> ClusterOutcome:
    """Handle ``skip_question``: every parked job in the cluster -> skipped (user)."""
    cluster = db.get_cluster(conn, cluster_id)
    if cluster is None:
        raise db.NotFound(f"open cluster {cluster_id!r} not found")
    outcome = ClusterOutcome(cluster_id=cluster_id, status="skipped", job_ids=list(cluster.job_ids))
    why = reason or f"skipped question: {cluster.canonical_question}"

    def open_jobs() -> dict[str, set[int]]:
        out: dict[str, set[int]] = {}
        for q in db.list_questions(conn, status=QuestionStatus.OPEN):
            out.setdefault(q.cluster_id, set()).update(q.job_ids)
        return out

    with db.transaction(conn):
        before = open_jobs()
        job_ids = db.resolve_cluster(conn, cluster_id, status=QuestionStatus.SKIPPED)
        for jid in job_ids:
            app = db.get_application_by_job(conn, jid)
            if app.state is AppState.NEEDS_YOU:
                outcome.transitions.append(db.transition(conn, app.id, AppState.SKIPPED, reason=why, actor=Actor.USER))
                db.remove_job_from_questions(conn, jid)
        after = open_jobs()
    for cid, jobs in before.items():
        if cid == cluster_id:
            continue
        if cid not in after:
            outcome.extra_resolved.append(cid)
        elif after[cid] != jobs:
            outcome.changed.append(cid)
    return outcome


def _patch_easy_apply(conn: sqlite3.Connection, job_id: int, question: str, answer: str) -> None:
    """Fill an ``ask_me`` Easy Apply draft row once the user answered it in the inbox."""
    try:
        item = db.get_easy_apply(conn, job_id)
    except db.NotFound:
        return
    norm = normalize_question(question)
    changed = False
    drafts = []
    for d in item.drafted_answers:
        if d.ask_me and normalize_question(d.question) == norm:
            d = d.model_copy(update={"answer": answer, "ask_me": False, "origin": AnswerOrigin.USER})
            changed = True
        drafts.append(d)
    if changed:
        db.upsert_easy_apply(conn, job_id, url=item.url, drafted_answers=drafts, resume_variant_id=item.resume_variant_id)


__all__ = [
    "CLUSTER_THRESHOLD", "ClusterOutcome", "PrepReport", "answer_cluster", "build_context", "form_label", "inbox_label",
    "never_guess_value",
    "park_unresolved", "questions_from_raw", "run_prep", "skip_cluster",
]


# =====================================================================================
# auto-resolve: clear inbox questions that stored facts now answer
# =====================================================================================


def auto_resolve_known(conn: sqlite3.Connection) -> list[ClusterOutcome]:
    """Answer open inbox clusters from what the user already told us — derived facts (residence,
    citizenship, sanctions screens, age, "how did you hear"…) and never-guess facts saved since
    the question was parked (e.g. work authorisation entered once in Settings or for another job).

    Answers are per job (country / source can differ) and nothing is written to memory: these are
    re-derived each time from the facts, which stay the single source of truth."""
    from autoapply.answers.derived import derived_answer
    from autoapply.answers.guardrails import resolve_never_guess

    profile = db.get_profile(conn)
    ng = db.get_never_guess(conn)
    outcomes: list[ClusterOutcome] = []
    for cluster in db.list_open_clusters(conn):
        if cluster.reason is QuestionReason.CAPTCHA or not cluster.job_ids:
            continue
        q = FormQuestion(key="auto", label=form_label(cluster.canonical_question), field_type=cluster.field_type,
                         options=list(cluster.options), required=True)
        per_job: dict[int, str] = {}
        for jid in cluster.job_ids:
            job = db.get_job(conn, jid)
            ans: str | None = None
            if cluster.never_guess_key:
                country = extract_country(job.location, location_mode=True) if job.location else None
                try:
                    ans = resolve_never_guess(cluster.never_guess_key, ng, q, country=country)
                except Exception:  # noqa: BLE001 - keys asked every time raise / return None
                    ans = None
            if ans is None:
                hit = derived_answer(q, profile=profile, never_guess=ng, job=job) or derived_answer(
                    q, profile=profile, never_guess=ng, job=job, kind="defaults")
                ans = hit[0] if hit else None
            if not ans:
                break
            per_job[jid] = ans
        if len(per_job) != len(cluster.job_ids):
            continue
        try:
            outcomes.append(answer_cluster(conn, cluster.cluster_id, next(iter(per_job.values())), save_to_memory=False,
                                           save_to_profile=False, per_job_answers=per_job))
        except Exception:  # noqa: BLE001 - one odd cluster must not stop the rest
            log.warning("auto-resolve of cluster %s failed", cluster.cluster_id, exc_info=True)
    return outcomes
