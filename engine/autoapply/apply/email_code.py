"""Email verification codes after Submit (Greenhouse's "A verification code was sent to …").

Some ATSs only accept an application after the applicant types a code they emailed. The
browser page is kept open while the code is obtained, so the code always lands on the exact
application that asked for it:

* a Needs-You question is opened for THIS job ("Security code … emailed to you@… for Acme ·
  ML Engineer") and a notification fires; the user types the code there;
* the page waits (polling the question) and, once the code arrives, types it and the adapter
  clicks Submit again and verifies as usual.

Codes are never stored in answer memory (they are single-use).
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from typing import Any

log = logging.getLogger("autoapply.apply")

CODE_PROMPT_RX = re.compile(
    r"\b(verification|security|confirmation) code (was|has been) (sent|emailed)\b|\benter the \d+[- ]?(character|digit) code\b",
    re.I,
)
CODE_LABEL_PREFIX = "Security code"


def _log_payload(message: str) -> Any:
    from autoapply.enums import LogLevel
    from autoapply.models import LogPayload, utcnow

    return LogPayload(level=LogLevel.INFO, message=message, logger="autoapply.apply", at=utcnow())


def code_requested(body: str) -> bool:
    return bool(CODE_PROMPT_RX.search(body or ""))


def code_length(body: str) -> int | None:
    m = re.search(r"\b(\d+)[- ]?(character|digit)\b", body or "", re.I)
    return int(m.group(1)) if m else None


def code_email(body: str) -> str | None:
    m = re.search(r"sent to\s+([\w.+-]+@[\w-]+(?:\.[\w-]+)+)", body or "", re.I)
    return m.group(1) if m else None


def is_code_question(label: str) -> bool:
    return (label or "").startswith(CODE_LABEL_PREFIX)


def clean_code(text: str, length: int | None) -> str | None:
    code = re.sub(r"[\s-]", "", text or "")
    if not code or (length and len(code) != length) or not re.fullmatch(r"[A-Za-z0-9]+", code):
        return None
    return code


async def wait_for_code(ctx: Any, *, ats: str, email: str | None, length: int | None, timeout_s: float = 900.0,
                        poll_s: float = 2.0) -> str | None:
    """Open a Needs-You question tied to this job and wait for the user's answer."""
    from autoapply import db
    from autoapply.enums import QuestionReason, QuestionStatus
    from autoapply.models import QuestionOpenedPayload, QuestionResolvedPayload

    conn, job = ctx.conn, ctx.job
    company = db.get_company(conn, job.company_id).name
    from datetime import UTC, datetime, timedelta

    from autoapply.mail import imap_codes

    sent_after = datetime.now(UTC) - timedelta(seconds=60)
    has_mailbox = imap_codes.account(conn) is not None
    # 1. A connected mailbox answers by itself: no inbox question at all when the code arrives in time.
    if has_mailbox:
        try:
            await ctx.emit("log", _log_payload(f"Reading the security code for {company} from your email…"))
        except Exception:  # noqa: BLE001
            pass
        code = clean_code(await imap_codes.poll_code(conn, company=company, sent_after=sent_after, length=length,
                                                     timeout_s=min(120.0, timeout_s)) or "", length)
        if code:
            return code
    size = f"{length}-character " if length else ""
    label = f"{CODE_LABEL_PREFIX} {ats} emailed to {email or 'your email'} for {company} · {job.title} ({size}code, expires soon)"
    q, _ = db.add_question(conn, canonical_question=label, job_id=job.id, field_type="text", reason=QuestionReason.ALWAYS_ASK)
    cluster = db.get_cluster(conn, q.cluster_id)
    if cluster is not None:
        try:
            await ctx.emit("question_opened", QuestionOpenedPayload(cluster=cluster))
        except Exception:  # noqa: BLE001
            log.debug("emit question_opened failed", exc_info=True)
    deadline = time.monotonic() + timeout_s
    code: str | None = None
    next_mail = time.monotonic() + 15
    while time.monotonic() < deadline:
        if has_mailbox and time.monotonic() >= next_mail:  # keep watching the mailbox while the question is open
            next_mail = time.monotonic() + 15
            found = clean_code(await imap_codes.poll_code(conn, company=company, sent_after=sent_after, length=length,
                                                          timeout_s=1, every_s=1) or "", length)
            if found:
                db.resolve_cluster(conn, q.cluster_id, status=QuestionStatus.ANSWERED, answer_text="(read from email)")
                try:
                    await ctx.emit("question_resolved", QuestionResolvedPayload(cluster_id=q.cluster_id, status="answered"))
                except Exception:  # noqa: BLE001
                    pass
                return found
        cur = db.get_question(conn, q.id)
        if cur.status is QuestionStatus.ANSWERED:
            code = clean_code(cur.answer_text or "", length)
            if code is None:
                log.warning("security code for job %s had the wrong format", job.id)
            break
        if cur.status is QuestionStatus.SKIPPED:
            break
        await asyncio.sleep(poll_s)
    cur = db.get_question(conn, q.id)
    if cur.status is QuestionStatus.OPEN:  # timed out: close it so the inbox doesn't keep a dead code request
        db.resolve_cluster(conn, q.cluster_id, status=QuestionStatus.SKIPPED)
        try:
            await ctx.emit("question_resolved", QuestionResolvedPayload(cluster_id=q.cluster_id, status="skipped"))
        except Exception:  # noqa: BLE001
            pass
    return code


async def type_code(page: Any, code: str) -> bool:
    """Type the code into the page's code boxes (one box per character) or single code field."""
    boxes = page.locator("input[maxlength='1']:visible")
    n = await boxes.count()
    if n >= len(code):
        await boxes.first.click()
        for i, ch in enumerate(code):
            await boxes.nth(i).fill(ch)
        return True
    single = page.locator("input[name*=code i]:visible, input[id*=code i]:visible, input[autocomplete=one-time-code]:visible")
    if await single.count():
        await single.first.fill(code)
        return True
    return False
