"""AnswerResolver: one place that decides how every form question gets answered.

Order (first hit wins):

0. **inbox** — the user already answered this exact question for this job in the Needs-You
   inbox (per-job answers live in ``meta['inbox_answers:<job_id>']``)  -> origin ``user``.
1. **always-ask** patterns (Settings ▸ Guardrails)                     -> NeedsUser.
2. **profile** — deterministic fields (name, email, phone, links, current title, ...) for
   questions that are NOT never-guess                                  -> origin ``profile``.
3. **never_guess** — sensitive fields resolve ONLY from the stored facts; EEO defaults to
   "prefer not to say"; missing                                       -> NeedsUser(never_guess).
4. **memory** — semantic match in the answer memory (templates rendered, per-company
   adaptation through the LLM for "why us" style answers)              -> origin ``memory``.
5. **generate** — grounded LLM answer from profile + stories + JD with a self-reported
   confidence; below ``preferences.confidence_threshold``             -> NeedsUser(low_confidence).
6. otherwise                                                           -> NeedsUser(unknown).

The result is typed (:class:`ResolvedAnswer`: answer, origin, confidence, origin_ref).
Scripted adapters and the agentic adapter call :meth:`AnswerResolver.resolve`; the Prep
pass calls :meth:`AnswerResolver.resolve_all`.
"""

from __future__ import annotations

import json
import re
import sqlite3
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

from autoapply import db
from autoapply.answers.guardrails import (
    ALWAYS_ASK_KEYS,
    NeedsUser,
    NeverGuessClassifier,
    as_form_question,
    matches_always_ask,
    passes_confidence,
    resolve_never_guess,
)
from autoapply.answers.memory import AnswerMemory
from autoapply.answers.textnorm import extract_country, match_option, normalize_question, question_intents
from autoapply.config import NeverGuess, Preferences
from autoapply.enums import AnswerOrigin, AnswerSource, FieldType, QuestionReason
from autoapply.llm.provider import LLMError, LLMProvider, TokenUsage
from autoapply.models import Company, FormQuestion, Job, Profile, ResumeVariant, Story

if TYPE_CHECKING:
    from autoapply.apply.base import ApplyContext, UnresolvedField


# =====================================================================================
# result types
# =====================================================================================


@dataclass(slots=True)
class ResolvedAnswer:
    question: FormQuestion
    answer: str
    origin: AnswerOrigin
    confidence: float | None = None
    origin_ref: str | None = None  # "answers:12", "stories:3", "resume_variants:2", "profile:email", "never_guess:sponsorship"
    never_guess_key: str | None = None
    #: Non-text actions for the adapter: "upload_resume" (answer = file path),
    #: "cover_letter" (adapter generates/uploads one), "skip" (optional field left blank).
    action: str | None = None
    similarity: float | None = None
    memory_answer_id: int | None = None
    story_ids: list[int] = field(default_factory=list)


@dataclass(slots=True)
class ResolveBatch:
    resolved: list[ResolvedAnswer] = field(default_factory=list)
    unresolved: list[NeedsUser] = field(default_factory=list)

    def unresolved_fields(self) -> list[UnresolvedField]:
        return [n.to_unresolved() for n in self.unresolved]


# =====================================================================================
# per-job inbox answers
# =====================================================================================


def _inbox_key(job_id: int) -> str:
    return f"inbox_answers:{job_id}"


def get_inbox_answers(conn: sqlite3.Connection, job_id: int) -> dict[str, str]:
    """normalized question -> answer the user gave in the inbox for this job."""
    return dict(db.get_meta(conn, _inbox_key(job_id), {}) or {})


def set_inbox_answers(conn: sqlite3.Connection, job_id: int, answers: dict[str, str]) -> None:
    """Merge per-job inbox answers (keys are normalized automatically)."""
    current = get_inbox_answers(conn, job_id)
    current.update({normalize_question(k): v for k, v in answers.items()})
    db.set_meta(conn, _inbox_key(job_id), current)


def clear_inbox_answers(conn: sqlite3.Connection, job_id: int) -> None:
    db.delete_meta(conn, _inbox_key(job_id))


# =====================================================================================
# profile mapping
# =====================================================================================


def _current_role(profile: Profile) -> Any:
    for w in profile.work_history:
        if not w.end or str(w.end).strip().lower() in {"present", "current", "now", ""}:
            return w
    return profile.work_history[0] if profile.work_history else None


def _split_name(profile: Profile) -> tuple[str | None, str | None]:
    first, last = profile.first_name, profile.last_name
    if (not first or not last) and profile.full_name:
        parts = profile.full_name.split()
        if len(parts) >= 2:
            first = first or parts[0]
            last = last or parts[-1]
    return first, last


def _link(profile: Profile, *names: str) -> str | None:
    links = {k.lower(): v for k, v in profile.links.items()}
    for n in names:
        for k, v in links.items():
            if n in k and v:
                return v
    return None


_PROFILE_RULES: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (name, re.compile(rx, re.I))
    for name, rx in (
        ("first_name", r"^(legal )?(first|given|fore) ?name$|^preferred (first )?name$"),
        ("last_name", r"^(legal )?(last|family|sur) ?name$|^surname$"),
        ("full_name", r"^(full |legal |your )?(full )?name$|^name \(first and last\)$|^candidate name$"),
        ("email", r"^(your )?e-?mail( address)?$"),
        ("phone", r"^(your )?(mobile |cell |contact )?(phone|mobile|cell|telephone|contact)( number| no)?$"),
        ("location", r"^(current )?(location|city|city of residence)$|^where are you (currently )?(based|located)$|^current city$"),
        ("linkedin", r"linked ?in"),
        ("github", r"git ?hub"),
        ("portfolio", r"^(portfolio|personal website|website|personal site|blog)( url| link)?$|portfolio (url|link|website)"),
        ("twitter", r"^(twitter|x)( url| handle| profile)?$"),
        ("current_company", r"^(current|most recent|present) (company|employer)( name)?$|^(company|employer)$"),
        ("current_title", r"^(current|most recent|present) (job )?(title|role|position)$|^(job )?title$"),
        ("years_experience", r"^(total |overall )?(years of (professional |work |relevant )?experience|how many years of (professional |work )?experience do you have)$"),
        ("school", r"^(school|university|college|institution)( name)?$|^(most recent|highest) (school|university)"),
        ("degree", r"^(degree|highest (degree|level of education)|education level)$"),
        ("summary", r"^(professional )?summary$|^about (you|yourself)$"),
    )
)


def profile_answer(profile: Profile, question: FormQuestion) -> tuple[str, str] | None:
    """(answer, profile field) for deterministic profile questions, else None."""
    label = normalize_question(question.label).replace("*", "").strip()
    for name, rx in _PROFILE_RULES:
        if not rx.search(label):
            continue
        val: Any = None
        if name == "first_name":
            val = _split_name(profile)[0]
        elif name == "last_name":
            val = _split_name(profile)[1]
        elif name == "full_name":
            f, last = _split_name(profile)
            val = profile.full_name or (f"{f} {last}" if f and last else None)
        elif name in {"email", "phone", "location", "summary"}:
            val = getattr(profile, name)
        elif name == "linkedin":
            val = _link(profile, "linkedin")
        elif name == "github":
            val = _link(profile, "github")
        elif name == "portfolio":
            val = _link(profile, "portfolio", "website", "personal", "site", "blog")
        elif name == "twitter":
            val = _link(profile, "twitter", "x.com")
        elif name == "current_company":
            r = _current_role(profile)
            val = r.company if r else None
        elif name == "current_title":
            r = _current_role(profile)
            val = r.title if r else (profile.headline or None)
        elif name == "years_experience":
            if profile.years_experience is not None:
                y = profile.years_experience
                val = str(int(y)) if float(y).is_integer() or question.field_type is FieldType.NUMBER else str(y)
        elif name == "school":
            val = profile.education[0].school if profile.education else None
        elif name == "degree":
            e = profile.education[0] if profile.education else None
            val = (" ".join(x for x in (e.degree, e.field) if x) or None) if e else None
        if val is None or not str(val).strip():
            return None
        val = str(val).strip()
        if question.options:
            opt = match_option(val, question.options)
            if opt is None:
                return None
            val = opt
        return val, name
    return None


# =====================================================================================
# facts for generation (shared with cover letters / easy apply)
# =====================================================================================


def profile_facts(profile: Profile) -> list[str]:
    """Flat list of factual statements about the candidate (the only allowed source)."""
    facts: list[str] = []
    if profile.full_name:
        facts.append(f"Name: {profile.full_name}")
    if profile.headline:
        facts.append(f"Headline: {profile.headline}")
    if profile.location:
        facts.append(f"Location: {profile.location}")
    if profile.years_experience is not None:
        facts.append(f"Years of professional experience: {profile.years_experience}")
    if profile.summary:
        facts.append(f"Summary: {profile.summary}")
    for w in profile.work_history:
        span = " - ".join(x for x in (w.start, w.end or "present") if x)
        facts.append(f"Worked as {w.title} at {w.company}" + (f" ({span})" if span else ""))
        facts.extend(f"At {w.company}: {h}" for h in w.highlights)
    for e in profile.education:
        facts.append("Education: " + ", ".join(x for x in (e.degree, e.field, e.school, e.end) if x))
    if profile.skills:
        facts.append("Skills: " + ", ".join(profile.skills))
    return facts


def story_text(s: Story) -> str:
    parts = [f"Story #{s.id} \"{s.title}\""]
    for label, v in (("Situation", s.situation), ("Task", s.task), ("Action", s.action), ("Result", s.result)):
        if v:
            parts.append(f"{label}: {v}")
    if s.tags:
        parts.append("Tags: " + ", ".join(s.tags))
    return " | ".join(parts)


def trim(text: str | None, limit: int = 3500) -> str:
    if not text:
        return ""
    return text if len(text) <= limit else text[:limit] + " …"


_GEN_SCHEMA = {
    "type": "object",
    "properties": {
        "answer": {"type": "string"},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "grounded": {"type": "boolean"},
        "story_ids": {"type": "array", "items": {"type": "integer"}},
        "gaps": {"type": "string"},
    },
    "required": ["answer", "confidence", "grounded"],
    "additionalProperties": False,
}

_ADAPT_SCHEMA = {
    "type": "object",
    "properties": {"answer": {"type": "string"}, "confidence": {"type": "number", "minimum": 0, "maximum": 1}},
    "required": ["answer", "confidence"],
    "additionalProperties": False,
}

GEN_SYSTEM = (
    "You fill in job applications on behalf of the candidate. Use ONLY the facts provided about the candidate "
    "(profile, stories) and the job description. Never invent employers, titles, numbers, skills, dates, or "
    "credentials. If the facts are insufficient to answer truthfully, say so via low confidence and grounded=false. "
    "Write in the first person, concise, plain, no clichés. The answer is read by the recruiter: it must never "
    "mention the facts, what they do or don't say, or that something is unknown. Put anything the facts don't "
    "cover in `gaps` (a short note to the candidate), not in the answer."
)


# =====================================================================================
# the resolver
# =====================================================================================


class AnswerResolver:
    """Resolve form questions for one job (``job``/``company`` may be None for generic use)."""

    def __init__(
        self,
        conn: sqlite3.Connection,
        llm: LLMProvider | None = None,
        *,
        job: Job | None = None,
        company: Company | str | None = None,
        profile: Profile | None = None,
        never_guess: NeverGuess | None = None,
        preferences: Preferences | None = None,
        resume: ResumeVariant | None = None,
        stories: list[Story] | None = None,
        memory: AnswerMemory | None = None,
        classifier: NeverGuessClassifier | None = None,
        generate: bool = True,
        adapt_memory: bool = True,
        memory_threshold: float = 0.78,
    ) -> None:
        self.conn = conn
        self.llm = llm
        self.job = job
        if company is None and job is not None:
            company = db.get_company(conn, job.company_id)
        self.company_name = company.name if isinstance(company, Company) else company
        self.profile = profile or db.get_profile(conn)
        self.never_guess = never_guess or db.get_never_guess(conn)
        self.preferences = preferences or db.get_preferences(conn)
        self.resume = resume
        self._stories = stories
        self.memory = memory or AnswerMemory(conn, threshold=memory_threshold, llm=llm)
        self.classifier = classifier or NeverGuessClassifier(llm)
        self.generate_enabled = generate and llm is not None
        self.adapt_memory = adapt_memory
        self.usage = TokenUsage()
        self.country = extract_country(job.location, location_mode=True) if job and job.location else None
        self._inbox = get_inbox_answers(conn, job.id) if job is not None else {}

    @classmethod
    def from_context(cls, ctx: ApplyContext, **kwargs: Any) -> AnswerResolver:
        """Build from an :class:`~autoapply.apply.base.ApplyContext` (adapters use this)."""
        return cls(
            ctx.conn, ctx.llm, job=ctx.job, profile=ctx.profile, never_guess=ctx.never_guess,
            preferences=ctx.preferences, resume=ctx.resume, **kwargs,
        )

    @property
    def stories(self) -> list[Story]:
        if self._stories is None:
            self._stories = db.list_stories(self.conn)
        return self._stories

    @property
    def role(self) -> str | None:
        return self.job.title if self.job else None

    # ---- public API ------------------------------------------------------------------

    async def resolve(self, question: FormQuestion | str) -> ResolvedAnswer:
        """Resolve one question or raise :class:`NeedsUser`."""
        q = as_form_question(question)

        # files: resume / cover letter / anything else
        if q.field_type is FieldType.FILE:
            return self._resolve_file(q)

        # 0. the user's own inbox answer for this job
        inbox = self._inbox.get(normalize_question(q.label))
        if inbox is not None:
            ans = match_option(inbox, q.options) if q.options else inbox
            if ans is not None:
                return ResolvedAnswer(q, ans, AnswerOrigin.USER, 1.0, origin_ref="inbox")

        # 1. always-ask
        if matches_always_ask(q.label, self.preferences):
            raise NeedsUser(q, QuestionReason.ALWAYS_ASK, detail="matches an always-ask pattern")

        # 1b. answers derived from facts already given (residence, citizenship, "how did you hear",
        #     sanctions screens, age, opt-ins): never sent to the inbox when the facts are known.
        from autoapply.answers.derived import derived_answer

        derived = derived_answer(q, profile=self.profile, never_guess=self.never_guess, job=self.job)
        if derived is not None:
            return ResolvedAnswer(q, derived[0], AnswerOrigin.PROFILE, 1.0, origin_ref=derived[1])

        key = await self.classifier.classify_async(q)

        # 2. profile (never for sensitive questions)
        if key is None:
            hit = profile_answer(self.profile, q)
            if hit is not None:
                return ResolvedAnswer(q, hit[0], AnswerOrigin.PROFILE, 1.0, origin_ref=f"profile:{hit[1]}")

        # 3. never-guess
        if key is not None:
            return self._resolve_never_guess(q, key)

        # 4. memory
        mem = await self._resolve_memory(q)
        if mem is not None:
            return mem

        # 4b. defaults from known facts (your saved answers above win over these)
        dflt = derived_answer(q, profile=self.profile, never_guess=self.never_guess, job=self.job, kind="defaults")
        if dflt is not None:
            return ResolvedAnswer(q, dflt[0], AnswerOrigin.PROFILE, 1.0, origin_ref=dflt[1])

        # 5. generate
        if self.generate_enabled and q.field_type not in {FieldType.EMAIL, FieldType.PHONE, FieldType.URL}:
            return await self._generate(q)

        if not q.required:
            return ResolvedAnswer(q, "", AnswerOrigin.GENERATED, None, action="skip")
        raise NeedsUser(q, QuestionReason.UNKNOWN, detail="no profile/memory answer and generation unavailable")

    async def resolve_all(self, questions: list[FormQuestion]) -> ResolveBatch:
        batch = ResolveBatch()
        for q in questions:
            try:
                batch.resolved.append(await self.resolve(q))
            except NeedsUser as nu:
                batch.unresolved.append(nu)
        return batch

    def record(self, application_id: int, resolved: ResolvedAnswer, *, answer_override: str | None = None) -> None:
        """Write the Q&A audit row and bump memory / story use counters."""
        if resolved.action == "skip":
            return
        db.add_application_answer(
            self.conn, application_id, question=resolved.question.label, answer=answer_override or resolved.answer,
            origin=resolved.origin, field_type=resolved.question.field_type, confidence=resolved.confidence,
            field_key=resolved.question.key, origin_ref=resolved.origin_ref,
        )
        if resolved.memory_answer_id is not None:
            self.memory.record_use(resolved.memory_answer_id)
        for sid in resolved.story_ids:
            db.record_story_use(self.conn, sid)

    # ---- steps -----------------------------------------------------------------------

    def _resolve_file(self, q: FormQuestion) -> ResolvedAnswer:
        # New Greenhouse forms label both upload buttons just "Attach": the field key ("resume",
        # "cover_letter") and description carry what the file is.
        label = f"{q.label} {q.key.replace('_', ' ')} {q.description or ''}".lower()
        if re.search(r"\b(resume|résumé|cv|curriculum)\b", label):
            if self.resume is None and self.job is not None:
                from autoapply.answers.resume_picker import pick_resume

                pick = pick_resume(self.conn, self.job)
                self.resume = pick.variant if pick else None
            if self.resume is None:
                raise NeedsUser(q, QuestionReason.UNKNOWN, detail="no approved resume uploaded")
            return ResolvedAnswer(q, self.resume.file_path, AnswerOrigin.CV, 1.0,
                                  origin_ref=f"resume_variants:{self.resume.id}", action="upload_resume")
        if re.search(r"\bcover letter\b", label):
            return ResolvedAnswer(q, "", AnswerOrigin.GENERATED, None, action="cover_letter")
        if not q.required:
            return ResolvedAnswer(q, "", AnswerOrigin.GENERATED, None, action="skip")
        raise NeedsUser(q, QuestionReason.UNKNOWN, detail="required file upload")

    def _resolve_never_guess(self, q: FormQuestion, key: str) -> ResolvedAnswer:
        if key in ALWAYS_ASK_KEYS:
            # only the user's own words from memory may answer these
            hit = self.memory.lookup(self._memory_query(q.label), company=self.company_name, role=self.role)
            if hit is not None and hit.answer.source is AnswerSource.USER and hit.similarity >= 0.9:
                ans = match_option(hit.rendered, q.options) if q.options else hit.rendered
                if ans is not None:
                    return ResolvedAnswer(q, ans, AnswerOrigin.MEMORY, 1.0, origin_ref=f"answers:{hit.answer.id}",
                                          never_guess_key=key, similarity=hit.similarity, memory_answer_id=hit.answer.id)
            raise NeedsUser(q, QuestionReason.NEVER_GUESS, never_guess_key=key, detail="sensitive; always asked")
        ans = resolve_never_guess(key, self.never_guess, q, country=self.country)
        if ans is None:
            raise NeedsUser(q, QuestionReason.NEVER_GUESS, never_guess_key=key, detail=f"no stored value for {key}")
        return ResolvedAnswer(q, ans, AnswerOrigin.NEVER_GUESS, 1.0, origin_ref=f"never_guess:{key}", never_guess_key=key)

    def _memory_query(self, label: str) -> str:
        """Question text with the company name folded out ("Why Stripe?" -> "Why your company?")."""
        if self.company_name:
            return re.sub(re.escape(self.company_name), "your company", label, flags=re.I)
        return label

    async def _resolve_memory(self, q: FormQuestion) -> ResolvedAnswer | None:
        hit = await self.memory.lookup_async(self._memory_query(q.label), company=self.company_name, role=self.role)
        if hit is None:
            return None
        text = hit.rendered
        confidence = round(min(1.0, hit.similarity), 3)
        intents = set(question_intents(q.label))
        needs_adapt = (
            self.adapt_memory
            and self.llm is not None
            and self.company_name
            and not hit.answer.is_template
            and intents & {"why_company", "why_role"}
            and self.company_name.lower() not in text.lower()
        )
        if needs_adapt:
            adapted = await self._adapt(q, text)
            if adapted is None:
                return None  # fall through to generation rather than reuse another company's "why us"
            text, confidence = adapted
        if q.options:
            opt = match_option(text, q.options)
            if opt is None:
                return None
            text = opt
        return ResolvedAnswer(q, text, AnswerOrigin.MEMORY, confidence, origin_ref=f"answers:{hit.answer.id}",
                              similarity=hit.similarity, memory_answer_id=hit.answer.id)

    async def _adapt(self, q: FormQuestion, answer: str) -> tuple[str, float] | None:
        assert self.llm is not None
        prompt = (
            f"ADAPT ANSWER for {self.company_name}" + (f" ({self.role})" if self.role else "") + ".\n"
            f"Question: {q.label}\n"
            f"The candidate's saved answer (written for another company):\n{answer}\n\n"
            f"Job description:\n{trim(self.job.description if self.job else None, 2500)}\n\n"
            "Rewrite the saved answer so it is about this company/role. Keep every claim about the candidate exactly "
            "as in the saved answer; add nothing new about the candidate. Return the answer and your confidence (0-1) "
            "that it is accurate and appropriate."
        )
        try:
            res = await self.llm.complete(prompt, system=GEN_SYSTEM, schema=_ADAPT_SCHEMA, max_tokens=600)
        except LLMError:
            return None
        self.usage.add(res.usage)
        conf = float(res.data["confidence"])
        if not passes_confidence(conf, self.preferences):
            return None
        return str(res.data["answer"]).strip(), conf

    async def _generate(self, q: FormQuestion) -> ResolvedAnswer:
        assert self.llm is not None
        facts = "\n".join(f"- {f}" for f in profile_facts(self.profile)) or "- (none)"
        stories = "\n".join(f"- {story_text(s)}" for s in self.stories) or "- (none)"
        job_part = ""
        if self.job is not None:
            job_part = f"Company: {self.company_name}\nRole: {self.job.title}\nJob description:\n{trim(self.job.description)}\n"
        constraints = []
        if q.options:
            constraints.append(f"The answer MUST be exactly one of these options: {json.dumps(q.options)}")
        if q.max_length:
            constraints.append(f"At most {q.max_length} characters.")
        if q.field_type is FieldType.NUMBER:
            constraints.append("Answer with a number only.")
        if q.field_type is FieldType.BOOLEAN:
            constraints.append("Answer Yes or No.")
        prompt = (
            "GENERATE ANSWER to a job application question.\n"
            f"Question: {q.label}\n" + (f"Help text: {q.description}\n" if q.description else "")
            + (("Constraints: " + " ".join(constraints) + "\n") if constraints else "")
            + f"\nCandidate facts:\n{facts}\n\nCandidate stories:\n{stories}\n\n{job_part}\n"
            "Return: answer; confidence (0-1) that the answer is truthful given ONLY these facts and appropriate; "
            "grounded (true only if every claim about the candidate comes from the facts/stories); story_ids used; "
            "gaps: one short sentence to the candidate naming what they should add (empty if nothing is missing)."
        )
        try:
            res = await self.llm.complete(prompt, system=GEN_SYSTEM, schema=_GEN_SCHEMA, max_tokens=700)
        except LLMError as e:
            raise NeedsUser(q, QuestionReason.UNKNOWN, detail=f"generation failed: {e}") from e
        self.usage.add(res.usage)
        data = res.data
        answer = str(data["answer"]).strip()
        conf = float(data["confidence"])
        note = str(data.get("gaps") or "").strip() or None
        if not data.get("grounded", False):
            conf = min(conf, 0.5)
        if q.options:
            opt = match_option(answer, q.options)
            if opt is None:
                raise NeedsUser(q, QuestionReason.LOW_CONFIDENCE, suggested_answer=answer, confidence=conf, note=note,
                                detail="generated answer is not one of the options")
            answer = opt
        if q.max_length and len(answer) > q.max_length:
            answer = answer[: q.max_length].rstrip()
        if not answer:
            raise NeedsUser(q, QuestionReason.UNKNOWN, detail="empty generated answer")
        valid_story_ids = {s.id for s in self.stories}
        story_ids = [int(i) for i in data.get("story_ids") or [] if int(i) in valid_story_ids]
        if not passes_confidence(conf, self.preferences):
            raise NeedsUser(q, QuestionReason.LOW_CONFIDENCE, suggested_answer=answer, confidence=conf, note=note,
                            detail=f"confidence {conf:.2f} < {self.preferences.confidence_threshold:.2f}")
        origin = AnswerOrigin.STORY if story_ids else AnswerOrigin.GENERATED
        ref = f"stories:{story_ids[0]}" if story_ids else None
        return ResolvedAnswer(q, answer, origin, round(conf, 3), origin_ref=ref, story_ids=story_ids)


__all__ = [
    "AnswerResolver", "NeedsUser", "ResolveBatch", "ResolvedAnswer", "clear_inbox_answers", "get_inbox_answers",
    "profile_answer", "profile_facts", "set_inbox_answers", "story_text",
]
