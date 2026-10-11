"""Easy Apply drafts: pre-drafted copy-paste answers for LinkedIn Easy Apply jobs that the
USER applies to manually. Never automates LinkedIn (no browser, no network here).

Rows produced (in order): contact (profile), years of experience, never-guess facts
(locked rows; ``ask_me`` when not stored — those also land in the Needs-You inbox),
"Why {company}?" and a short pitch (memory first, else grounded generation).
"""

from __future__ import annotations

import sqlite3

from autoapply import db
from autoapply.answers.guardrails import NeedsUser
from autoapply.answers.memory import AnswerMemory
from autoapply.answers.resolver import AnswerResolver
from autoapply.answers.resume_picker import pick_resume
from autoapply.enums import AnswerOrigin, FieldType, QuestionReason
from autoapply.llm.provider import LLMProvider
from autoapply.models import DraftedAnswer, EasyApplyItem, FormQuestion

#: (key, label, field_type) — the questions LinkedIn Easy Apply forms ask most often.
STANDARD_QUESTIONS: tuple[tuple[str, str, FieldType], ...] = (
    ("email", "Email address", FieldType.EMAIL),
    ("phone", "Mobile phone number", FieldType.PHONE),
    ("years", "Years of experience", FieldType.NUMBER),
    ("work_auth", "Are you legally authorized to work in {country}?", FieldType.TEXT),
    ("sponsorship", "Will you now or in the future require sponsorship for employment visa status?", FieldType.TEXT),
    ("salary", "What are your salary expectations?", FieldType.TEXT),
    ("notice", "What is your notice period?", FieldType.TEXT),
    ("start", "When can you start?", FieldType.TEXT),
    ("relocation", "Are you willing to relocate?", FieldType.TEXT),
    ("why", "Why do you want to work at {company}?", FieldType.TEXTAREA),
    ("pitch", "Tell us about yourself (short pitch)", FieldType.TEXTAREA),
)

_COUNTRY_NAMES = {"US": "the United States", "GB": "the United Kingdom", "IN": "India", "CA": "Canada", "DE": "Germany"}


async def draft_easy_apply(conn: sqlite3.Connection, llm: LLMProvider, job_id: int) -> list[DraftedAnswer]:
    """Draft answers for the common Easy Apply questions (phone, years of experience,
    never-guess facts as locked rows, 'why {company}' from memory/stories). Unknown ones are
    ``ask_me=True`` rows linked to the inbox."""
    from autoapply.prep import park_unresolved

    job = db.get_job(conn, job_id)
    company = db.get_company(conn, job.company_id)
    memory = AnswerMemory(conn, llm=llm)
    resolver = AnswerResolver(conn, llm, job=job, company=company, memory=memory)
    country = resolver.country
    drafts: list[DraftedAnswer] = []
    unresolved: list[NeedsUser] = []
    for key, label, ftype in STANDARD_QUESTIONS:
        if key == "work_auth" and not country:
            label = "Are you legally authorized to work in the country of this job?"
        text = label.format(company=company.name, country=_COUNTRY_NAMES.get(country or "", country or ""))
        q = FormQuestion(key=key, label=text, field_type=ftype, required=key in {"email", "phone"})
        try:
            r = await resolver.resolve(q)
        except NeedsUser as nu:
            if nu.reason is QuestionReason.LOW_CONFIDENCE and nu.suggested_answer:
                # the user reviews every Easy Apply draft before pasting it: show the suggestion
                drafts.append(DraftedAnswer(question=text, answer=nu.suggested_answer, origin=AnswerOrigin.GENERATED))
                continue
            drafts.append(DraftedAnswer(question=text, answer="", origin=AnswerOrigin.USER, locked=bool(nu.never_guess_key), ask_me=True))
            unresolved.append(nu)
            continue
        if r.action == "skip" or not r.answer:
            continue
        drafts.append(
            DraftedAnswer(question=text, answer=r.answer, origin=r.origin, locked=r.origin is AnswerOrigin.NEVER_GUESS)
        )
        if r.memory_answer_id is not None:
            memory.record_use(r.memory_answer_id)
    if unresolved:
        park_unresolved(conn, job.id, unresolved, memory=memory)
    app = db.get_application_by_job(conn, job.id)
    if resolver.usage.total_tokens:
        db.add_application_tokens(conn, app.id, resolver.usage.input_tokens, resolver.usage.output_tokens)
    return drafts


async def refresh_easy_apply(conn: sqlite3.Connection, llm: LLMProvider, job_id: int) -> EasyApplyItem:
    """Draft and persist (``db.upsert_easy_apply``) for one job."""
    job = db.get_job(conn, job_id)
    drafts = await draft_easy_apply(conn, llm, job_id)
    pick = pick_resume(conn, job)
    url = job.source_url or job.apply_url
    if not url:
        raise ValueError(f"job {job_id} has no URL for the Easy Apply list")
    return db.upsert_easy_apply(conn, job_id, url=url, drafted_answers=drafts, resume_variant_id=pick.variant.id if pick else None)
