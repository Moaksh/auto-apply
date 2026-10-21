"""Watching the mailbox for replies, bounces, auto-replies, opt-outs and LinkedIn notification
emails (plan §C.6). Read-only IMAP (``mail.common.Mailbox``: ``readonly=True`` + ``BODY.PEEK[]``).

Two phases so the daemon stays the only database writer on its event loop:

1. :func:`collect` (blocking, in a worker thread): IMAP searches for each watched thread
   (``In-Reply-To`` / ``References`` on our Message-IDs, and ``FROM`` the contact since the
   first send), bounce reports from ``mailer-daemon`` / ``postmaster``, and LinkedIn's
   "accepted your invitation" / "sent you a message" emails;
2. :func:`apply` (async, on the loop): classify and record. Auto-replies are recognised from
   headers and subjects without the model and never count as replies (the follow-up is pushed
   to the stated return date). Other replies go to the model; an opt-out (regex or model) puts
   the sender on the do-not-contact list. A 5.x.x bounce marks the thread bounced, zeroes the
   contact, lists the address and penalises the domain pattern; 4.x.x is ignored.

Also :func:`find_in_sent`: the Sent Mail lookup that resolves messages left in ``unknown``.
"""

from __future__ import annotations

import logging
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from email.header import decode_header, make_header
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime
from typing import Any

from autoapply import db
from autoapply.enums import (
    BoardStatus,
    EmailStatus,
    EvidenceKind,
    ReferralState,
    ReplyLabel,
    SuppressionReason,
    ThreadOutcome,
    ThreadState,
)
from autoapply.llm.provider import LLMProvider
from autoapply.mail.common import GMAIL_SENT, Mailbox, _text
from autoapply.models import OutreachReplyPayload, format_ts, now_ts, utcnow
from autoapply.outreach import contacts, domains, suppression, threads

log = logging.getLogger("autoapply.outreach.mailwatch")

WATCH_DAYS = 45
SCAN_EVERY_S = 600.0
MAX_FETCH_PER_SEARCH = 10
LINKEDIN_SENDERS = ("invitations@linkedin.com", "messages-noreply@linkedin.com")
META_LINKEDIN_SEEN = "outreach_linkedin_seen"

OPT_OUT_RX = re.compile(
    r"\b(unsubscribe|remove me|take me off|stop (emailing|e-mailing|contacting|messaging)|"
    r"(don'?t|do not|please don'?t) (contact|email|e-mail|write to|reach out to) me|no thanks|no, thanks|"
    r"not interested,? (please )?stop)\b", re.I)
_AUTO_SUBJECT = re.compile(r"\b(out of (the )?office|automatic reply|auto[- ]?reply|autoreply|away from (the )?office|"
                           r"on (annual |parental |maternity )?leave|vacation|ooo)\b", re.I)
_BOUNCE_FROM = re.compile(r"(mailer-daemon|postmaster)@", re.I)
_LI_ACCEPTED = re.compile(r"^(?P<name>.+?) (?:has )?accepted your invitation", re.I)
_LI_MESSAGE = re.compile(r"^(?:(?P<a>.+?) (?:sent you a (?:new )?message|just messaged you)|new message from (?P<b>.+))$", re.I)

REPLY_SCHEMA = {
    "type": "object",
    "properties": {
        "label": {"type": "string", "enum": ["positive", "referred", "not_interested", "opt_out", "question", "other"]},
        "suggested_status": {"type": ["string", "null"], "enum": ["interview", "rejected", None]},
        "return_date": {"type": ["string", "null"]},
    },
    "required": ["label"],
}
REPLY_SYSTEM = (
    "You classify a reply to a job seeker's email. positive: interested / will pass it on / wants to talk. referred: "
    "points to another person or says they referred the candidate. not_interested: no role / not a fit. opt_out: asks "
    "not to be contacted. question: asks the candidate something. suggested_status: 'interview' only if they invite "
    "the candidate to interview, 'rejected' only if they clearly reject; else null."
)
OOO_SCHEMA = {"type": "object", "properties": {"return_date": {"type": ["string", "null"]}}, "required": ["return_date"]}


# =====================================================================================
# Pure parsing
# =====================================================================================


def header(msg: Message, name: str) -> str:
    raw = msg.get(name)
    if raw is None:
        return ""
    try:
        return str(make_header(decode_header(str(raw))))
    except Exception:  # noqa: BLE001
        return str(raw)


def sender_address(msg: Message) -> str:
    return parseaddr(header(msg, "From"))[1].lower()


def is_auto_reply(msg: Message) -> bool:
    auto = header(msg, "Auto-Submitted").lower()
    if auto and auto != "no":
        return True
    if msg.get("X-Autoreply") or msg.get("X-Autorespond"):
        return True
    if header(msg, "Precedence").lower() in ("auto_reply", "auto-reply"):
        return True
    return bool(_AUTO_SUBJECT.search(header(msg, "Subject")))


def reply_text(text: str) -> str:
    """The new part of a reply: quoted history ("On … wrote:", "> …", "From: …") removed, so
    our own footer ("reply \\"no thanks\\"") in the quote never reads as an opt-out."""
    out: list[str] = []
    for line in (text or "").splitlines():
        s = line.strip()
        if s.startswith(">"):
            break
        if re.match(r"^on .{4,200} wrote:?$", s, re.I) or re.match(r"^-{2,}\s*original message", s, re.I) \
                or re.match(r"^(from|sent|de|von):\s", s, re.I) and out:
            break
        if "i found your address on" in s.lower():
            break  # our own footer, quoted without ">" by some clients
        out.append(line)
    return "\n".join(out).strip()


def is_opt_out(text: str) -> bool:
    return bool(OPT_OUT_RX.search(reply_text(text)))


@dataclass(slots=True)
class Bounce:
    recipient: str | None
    status: str | None  # e.g. 5.1.1
    original_message_id: str | None

    @property
    def hard(self) -> bool:
        return bool(self.status and self.status.startswith("5"))


def parse_bounce(msg: Message) -> Bounce | None:
    """A delivery status notification (RFC 3464), or a mailer-daemon message that looks like one."""
    is_report = msg.get_content_type() == "multipart/report" and "delivery-status" in str(msg.get("Content-Type", "")).lower()
    if not is_report and not _BOUNCE_FROM.search(header(msg, "From")):
        return None
    recipient = status = original = None
    for part in msg.walk():
        ctype = part.get_content_type()
        if ctype == "message/delivery-status":
            payload = part.get_payload()
            blocks = payload if isinstance(payload, list) else []
            for b in blocks:
                fr = b.get("Final-Recipient") or b.get("Original-Recipient")
                if fr and not recipient:
                    recipient = str(fr).split(";", 1)[-1].strip().strip("<>").lower()
                st = b.get("Status")
                if st and not status:
                    status = str(st).strip().split()[0]
        elif ctype in ("message/rfc822", "text/rfc822-headers"):
            inner = part.get_payload()
            if isinstance(inner, list) and inner:
                original = original or (inner[0].get("Message-ID") or None)
            elif isinstance(inner, str):
                m = re.search(r"^Message-ID:\s*(<[^>]+>)", inner, re.I | re.M)
                original = original or (m.group(1) if m else None)
    text = _text(msg)
    if not status:
        m = re.search(r"\b([45]\.\d{1,3}\.\d{1,3})\b", text)
        status = m.group(1) if m else None
    if not recipient:
        m = re.search(r"Final-Recipient:\s*rfc822;\s*<?([^\s>]+@[^\s>]+)", text, re.I)
        recipient = m.group(1).lower() if m else None
    if not original:
        m = re.search(r"Message-ID:\s*(<[^>]+>)", text, re.I)
        original = m.group(1) if m else None
    if status is None and recipient is None:
        return None
    return Bounce(recipient, status, str(original).strip() if original else None)


def parse_linkedin_notification(msg: Message) -> tuple[str, str] | None:
    """("accepted" | "message", person name) for LinkedIn's notification emails."""
    sender = sender_address(msg)
    if sender not in LINKEDIN_SENDERS:
        return None
    subject = re.sub(r"\s+", " ", header(msg, "Subject")).strip()
    m = _LI_ACCEPTED.match(subject)
    if m:
        return "accepted", m.group("name").strip()
    m = _LI_MESSAGE.match(subject)
    if m:
        return "message", (m.group("a") or m.group("b") or "").strip()
    return None


def imap_date(d: date) -> str:
    return d.strftime("%d-%b-%Y")


# =====================================================================================
# Phase 1: collect (blocking)
# =====================================================================================


@dataclass(slots=True)
class ThreadWatch:
    thread_id: int
    message_ids: list[str]
    contact_email: str | None
    since: date


@dataclass(slots=True)
class WatchSpec:
    threads: list[ThreadWatch] = field(default_factory=list)
    bounce_since: date | None = None
    linkedin_since: date | None = None


@dataclass(slots=True)
class Collected:
    replies: list[tuple[int, Message]] = field(default_factory=list)  # (thread_id, message)
    bounces: list[Message] = field(default_factory=list)
    linkedin: list[Message] = field(default_factory=list)


def _fetch_all(mb: Mailbox, criteria: str) -> list[Message]:
    out: list[Message] = []
    for uid in mb.search(criteria)[-MAX_FETCH_PER_SEARCH:]:
        msg = mb.fetch(uid)
        if msg is not None:
            out.append(msg)
    return out


def collect(mb: Mailbox, spec: WatchSpec) -> Collected:
    """Run the IMAP searches for ``spec`` on INBOX (read-only)."""
    got = Collected()
    if not mb.select("INBOX"):
        return got
    for tw in spec.threads:
        seen: set[str] = set()
        for mid in tw.message_ids:
            for msg in _fetch_all(mb, f'(OR HEADER In-Reply-To "{mid}" HEADER References "{mid}")'):
                key = str(msg.get("Message-ID") or id(msg))
                if key not in seen:
                    seen.add(key)
                    got.replies.append((tw.thread_id, msg))
        if tw.contact_email:
            for msg in _fetch_all(mb, f'(FROM "{tw.contact_email}" SINCE {imap_date(tw.since)})'):
                key = str(msg.get("Message-ID") or id(msg))
                if key not in seen:
                    seen.add(key)
                    got.replies.append((tw.thread_id, msg))
    if spec.bounce_since:
        got.bounces = _fetch_all(mb, f'(OR FROM "mailer-daemon" FROM "postmaster") SINCE {imap_date(spec.bounce_since)}')
    if spec.linkedin_since:
        for sender in LINKEDIN_SENDERS:
            got.linkedin += _fetch_all(mb, f'(FROM "{sender}" SINCE {imap_date(spec.linkedin_since)})')
    return got


def find_in_sent(mb: Mailbox, message_id: str) -> bool:
    """Is ``message_id`` in Gmail's Sent Mail? (``X-GM-RAW rfc822msgid:`` when available.)"""
    if not mb.select(GMAIL_SENT):
        return False
    mid = message_id.strip()
    if mb.has_gmail_ext():
        if mb.search(f'X-GM-RAW "rfc822msgid:{mid.strip("<>")}"'):
            return True
    return bool(mb.search(f'HEADER Message-ID "{mid}"'))


# =====================================================================================
# Phase 2: apply (async, on the daemon loop)
# =====================================================================================


def build_spec(conn: sqlite3.Connection, now: datetime | None = None) -> WatchSpec | None:
    """What to look for; None when nothing was sent in the last ``WATCH_DAYS`` days and no
    referral waits for a LinkedIn notification."""
    now = now or utcnow()
    cutoff = format_ts(now - timedelta(days=WATCH_DAYS))
    rows = conn.execute(
        "SELECT t.id AS thread_id, c.email_norm AS email, MIN(m.sent_at) AS first_sent FROM outreach_threads t "
        "JOIN outreach_messages m ON m.thread_id = t.id AND m.direction = 'out' AND m.state = 'sent' "
        "LEFT JOIN contacts c ON c.id = t.contact_id "
        "WHERE t.state IN ('active','replied') GROUP BY t.id HAVING MAX(m.sent_at) >= ?", (cutoff,),
    ).fetchall()
    spec = WatchSpec()
    earliest: date | None = None
    for r in rows:
        mids = [m["message_id_header"] for m in conn.execute(
            "SELECT message_id_header FROM outreach_messages WHERE thread_id = ? AND direction = 'out' AND state = 'sent' "
            "AND message_id_header IS NOT NULL", (r["thread_id"],))]
        since = (datetime.fromisoformat(r["first_sent"].replace("Z", "+00:00")) - timedelta(days=1)).date()
        earliest = since if earliest is None or since < earliest else earliest
        spec.threads.append(ThreadWatch(int(r["thread_id"]), mids, r["email"], since))
    if earliest is not None:
        spec.bounce_since = earliest
    waiting = conn.execute("SELECT MIN(state_updated_at) FROM referrals WHERE state IN ('requested','asked')").fetchone()[0]
    if waiting:
        spec.linkedin_since = (datetime.fromisoformat(waiting.replace("Z", "+00:00")) - timedelta(days=1)).date()
    if not spec.threads and spec.linkedin_since is None:
        return None
    return spec


@dataclass(slots=True)
class ApplyReport:
    events: list[tuple[str, Any]] = field(default_factory=list)
    notifications: list[tuple[str, str]] = field(default_factory=list)
    replies: int = 0
    bounces: int = 0
    ooo: int = 0
    opt_outs: int = 0


def _when(msg: Message) -> str:
    try:
        d = parsedate_to_datetime(header(msg, "Date"))
        return format_ts(d)
    except Exception:  # noqa: BLE001
        return now_ts()


def _already_recorded(conn: sqlite3.Connection, mid: str | None) -> bool:
    return bool(mid) and conn.execute("SELECT 1 FROM outreach_messages WHERE message_id_header = ?", (mid,)).fetchone() is not None


def _record_inbound(conn: sqlite3.Connection, thread_id: int, msg: Message, body: str, label: ReplyLabel) -> int:
    ts = now_ts()
    mid = str(msg.get("Message-ID") or "").strip() or None
    with db.transaction(conn):
        seq = int(conn.execute("SELECT COALESCE(MAX(seq), 0) FROM outreach_messages WHERE thread_id = ?", (thread_id,)).fetchone()[0])
        cur = conn.execute(
            "INSERT INTO outreach_messages(thread_id, seq, direction, state, from_email, subject, body, message_id_header, "
            "in_reply_to, sent_at, classification, created_at, updated_at) VALUES (?, ?, 'in', 'received', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (thread_id, seq, sender_address(msg), header(msg, "Subject")[:300], body[:4000] or "(empty)", mid,
             str(msg.get("In-Reply-To") or "").strip() or None, _when(msg), label.value, ts, ts),
        )
    return int(cur.lastrowid)


async def classify(llm: LLMProvider | None, text: str) -> tuple[ReplyLabel, BoardStatus | None]:
    if llm is None or not text.strip():
        return ReplyLabel.OTHER, None
    try:
        res = await llm.complete(f"REPLY:\n{text[:3000]}", system=REPLY_SYSTEM, schema=REPLY_SCHEMA, tier="fast", max_tokens=200)
    except Exception as e:  # noqa: BLE001
        log.info("reply classification failed: %s", e)
        return ReplyLabel.OTHER, None
    data = res.data or {}
    label = ReplyLabel(data.get("label") or "other")
    st = data.get("suggested_status")
    return label, (BoardStatus(st) if st in ("interview", "rejected") else None)


async def return_date(llm: LLMProvider | None, text: str) -> datetime | None:
    if llm is None:
        return None
    try:
        res = await llm.complete(f"Today is {date.today().isoformat()}. When is this person back? Reply YYYY-MM-DD or null.\n\n{text[:1500]}",
                                 schema=OOO_SCHEMA, tier="fast", max_tokens=60)
        val = (res.data or {}).get("return_date")
        return datetime.fromisoformat(val).astimezone() if val else None
    except Exception:  # noqa: BLE001
        return None


_LABEL_OUTCOME = {
    ReplyLabel.POSITIVE: ThreadOutcome.POSITIVE, ReplyLabel.REFERRED: ThreadOutcome.REFERRED,
    ReplyLabel.NOT_INTERESTED: ThreadOutcome.NOT_INTERESTED, ReplyLabel.QUESTION: ThreadOutcome.QUESTION,
    ReplyLabel.OTHER: ThreadOutcome.OTHER,
}


async def apply(conn: sqlite3.Connection, got: Collected, llm: LLMProvider | None) -> ApplyReport:
    rep = ApplyReport()
    for thread_id, msg in got.replies:
        await _apply_reply(conn, thread_id, msg, llm, rep)
    for msg in got.bounces:
        _apply_bounce(conn, msg, rep)
    _apply_linkedin(conn, got.linkedin, rep)
    return rep


async def _apply_reply(conn: sqlite3.Connection, thread_id: int, msg: Message, llm: LLMProvider | None, rep: ApplyReport) -> None:
    mid = str(msg.get("Message-ID") or "").strip() or None
    if _already_recorded(conn, mid):
        return
    if _BOUNCE_FROM.search(header(msg, "From")):
        return  # handled as a bounce
    try:
        t = threads.get_thread(conn, thread_id)
    except db.NotFound:
        return
    mailbox_self = conn.execute("SELECT from_email FROM outreach_messages WHERE thread_id = ? AND from_email IS NOT NULL LIMIT 1",
                                (thread_id,)).fetchone()
    if mailbox_self and sender_address(msg) == (mailbox_self[0] or "").lower():
        return  # our own message (Gmail threads show it)
    body = reply_text(_text(msg))
    if is_auto_reply(msg):
        _record_inbound(conn, thread_id, msg, body, ReplyLabel.OOO)
        rep.ooo += 1
        back = await return_date(llm, body)
        if back is not None:
            threads.update_thread(conn, thread_id, next_action_at=format_ts(back))
        return
    label, suggested = await classify(llm, body)
    if is_opt_out(body):
        label = ReplyLabel.OPT_OUT
    inbound_id = _record_inbound(conn, thread_id, msg, body, label)
    rep.replies += 1
    for p in threads.cancel_pending(conn, thread_id, "reply received"):
        rep.events.append(("outreach_state", p))
    contact = None
    if t.contact_id is not None:
        try:
            contact = contacts.get_contact(conn, t.contact_id)
        except db.NotFound:
            contact = None
    if label is ReplyLabel.OPT_OUT:
        rep.opt_outs += 1
        suppression.add(conn, email=sender_address(msg), reason=SuppressionReason.OPT_OUT, source=f"reply on thread {thread_id}")
        if contact and contact.email_norm and contact.email_norm != sender_address(msg):
            suppression.add(conn, email=contact.email_norm, reason=SuppressionReason.OPT_OUT, source=f"reply on thread {thread_id}")
        p = threads.set_thread_state(conn, thread_id, ThreadState.OPTED_OUT, reason="asked not to be contacted", unread_reply=1)
    else:
        p = threads.set_thread_state(conn, thread_id, ThreadState.REPLIED, reason=f"reply: {label.value}",
                                     outcome=_LABEL_OUTCOME.get(label), unread_reply=1)
    if p is not None:
        rep.events.append(("outreach_state", p))
    if contact is not None and contact.email_norm == sender_address(msg):
        contacts.set_email_status(conn, contact.id, EmailStatus.REPLIED,
                                  evidence=contacts.NewEvidence(EvidenceKind.REPLY, "email", snippet="they replied"))
    company = db.get_company(conn, t.company_id).name
    name = contact.full_name if contact else sender_address(msg)
    snippet = re.sub(r"\s+", " ", body)[:200]
    rep.events.append(("outreach_reply", OutreachReplyPayload(
        thread_id=thread_id, message_id=inbound_id, contact_name=name, company=company, label=label, snippet=snippet,
        application_id=t.application_id, suggested_status=suggested,
    )))


def _apply_bounce(conn: sqlite3.Connection, msg: Message, rep: ApplyReport) -> None:
    mid = str(msg.get("Message-ID") or "").strip() or None
    if _already_recorded(conn, mid):
        return
    b = parse_bounce(msg)
    if b is None or not b.hard:
        return  # 4.x.x: wait for the final failure
    original = threads.thread_for_message_id(conn, b.original_message_id) if b.original_message_id else None
    if original is None and b.recipient:
        row = conn.execute(
            "SELECT * FROM outreach_messages WHERE direction = 'out' AND state = 'sent' AND lower(to_email) = ? "
            "ORDER BY sent_at DESC LIMIT 1", (b.recipient,)).fetchone()
        if row is not None:
            from autoapply.models import OutreachMessage

            original = OutreachMessage.from_row(row)  # type: ignore[assignment]
    if original is None:
        return
    thread_id = original.thread_id
    _record_inbound(conn, thread_id, msg, f"Delivery failed ({b.status}) for {b.recipient or original.to_email}", ReplyLabel.BOUNCE)
    rep.bounces += 1
    for p in threads.cancel_pending(conn, thread_id, "bounced"):
        rep.events.append(("outreach_state", p))
    p = threads.set_thread_state(conn, thread_id, ThreadState.BOUNCED, reason=f"bounce {b.status}")
    if p is not None:
        rep.events.append(("outreach_state", p))
    address = (b.recipient or original.to_email or "").lower()
    if address:
        suppression.add(conn, email=address, reason=SuppressionReason.HARD_BOUNCE, source=f"bounce {b.status}")
    t = threads.get_thread(conn, thread_id)
    if t.contact_id is not None:
        try:
            c = contacts.get_contact(conn, t.contact_id)
        except db.NotFound:
            return
        was_pattern = c.email_status is EmailStatus.PATTERN or (
            c.email_status is EmailStatus.DELIVERED and conn.execute(
                "SELECT 1 FROM contact_evidence WHERE contact_id = ? AND field = 'email' AND kind = 'pattern'", (c.id,)).fetchone())
        contacts.set_email_status(conn, c.id, EmailStatus.BOUNCED,
                                  evidence=contacts.NewEvidence(EvidenceKind.BOUNCE, "email", snippet=f"bounced {b.status}"))
        dom = suppression.email_domain(address)
        if was_pattern and dom:
            domains.register_bounce(conn, dom)


def _apply_linkedin(conn: sqlite3.Connection, msgs: list[Message], rep: ApplyReport) -> None:
    if not msgs:
        return
    seen = list(db.get_meta(conn, META_LINKEDIN_SEEN, []) or [])
    from autoapply.outreach import referrals

    for msg in msgs:
        mid = str(msg.get("Message-ID") or "")
        if mid and mid in seen:
            continue
        parsed = parse_linkedin_notification(msg)
        if mid:
            seen.append(mid)
        if parsed is None:
            continue
        kind, name = parsed
        for r in referrals.match_by_name(conn, name, states=(ReferralState.REQUESTED, ReferralState.ASKED)):
            if kind == "accepted" and r.state is ReferralState.REQUESTED:
                referrals.transition(conn, r.id, ReferralState.CONNECTED, reason="LinkedIn: accepted your invitation")
                rep.notifications.append((f"{name} accepted your invitation", "Ask them for a referral when you're ready."))
            elif kind == "message":
                if r.state is ReferralState.REQUESTED:
                    referrals.transition(conn, r.id, ReferralState.CONNECTED, reason="LinkedIn: sent you a message")
                db.log_event(conn, "outreach", f"{name} sent you a LinkedIn message", payload={"referral_id": r.id})
                rep.notifications.append((f"{name} sent you a message on LinkedIn", "Open LinkedIn to read it."))
    db.set_meta(conn, META_LINKEDIN_SEEN, seen[-300:])


__all__ = [
    "Bounce", "Collected", "OPT_OUT_RX", "ThreadWatch", "WatchSpec", "apply", "build_spec", "classify", "collect", "find_in_sent",
    "is_auto_reply", "is_opt_out", "parse_bounce", "parse_linkedin_notification", "reply_text",
]
