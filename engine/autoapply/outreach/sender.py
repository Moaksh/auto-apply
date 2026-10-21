"""Scheduling and sending approved outreach email (plan §C.3, §C.4).

Scheduling (pure, injected clock): an approved batch is spread over the send window
(default 09:30-17:30 local, weekdays only), a random 3-9 minutes apart (never under 90 s),
within the daily limits:

* new threads per day: ``outreach_daily_cap`` (10; lower during the first week: 5, then 8);
* all sends per day, follow-ups included: 2 x cap, never above 60;
* per recipient domain per day: 2.

``approve_outreach`` never fails because of caps: whatever does not fit today goes to the next
allowed day.

Sending (:class:`OutreachSender`, one message per tick): immediately before the SMTP
conversation it re-checks pause, the send window, the caps, the do-not-contact list and the
thread (no reply / bounce / opt-out yet), then commits ``sending`` (``synchronous=FULL``) with
no ``await`` in between, the same reasoning as ``submit_gate`` + ``begin_submit``. A refusal
before DATA is ``failed`` (not sent); a broken connection during DATA is ``unknown`` and is
never resent automatically.
"""

from __future__ import annotations

import asyncio
import logging
import random
import sqlite3
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from typing import Any

from autoapply import db
from autoapply.config import Preferences
from autoapply.enums import Actor, CapKind, MessageState, ThreadState
from autoapply.models import CapReachedPayload, OutreachMessage, OutreachThread, format_ts, parse_ts, utcnow
from autoapply.outreach import suppression

log = logging.getLogger("autoapply.outreach.sender")

SPACING_S: tuple[float, float] = (180.0, 540.0)
MIN_SPACING_S = 90.0
PER_DOMAIN_PER_DAY = 2
TOTAL_HARD_LIMIT = 60
#: meta: earliest time the next email may go out (spacing survives a restart).
META_NEXT_SEND = "outreach_next_send_at"
#: meta: local date a cap_reached{outreach_daily} was last announced.
META_CAP_ANNOUNCED = "outreach_cap_announced"
#: First emails of an application thread wait this many business days after submission.
APPLICATION_DELAY_BUSINESS_DAYS = 1

EmitFn = Callable[[str, Any], Awaitable[None]]


# =====================================================================================
# Window / calendar (pure)
# =====================================================================================


def _hhmm(s: str) -> time:
    h, m = s.split(":")
    return time(int(h), int(m))


def is_send_day(d: date, weekdays_only: bool) -> bool:
    return not weekdays_only or d.weekday() < 5


def in_window(local: datetime, window: list[str], weekdays_only: bool) -> bool:
    start, end = _hhmm(window[0]), _hhmm(window[1])
    return is_send_day(local.date(), weekdays_only) and start <= local.time() < end


def window_bounds(d: date, window: list[str], tz: Any) -> tuple[datetime, datetime]:
    start, end = _hhmm(window[0]), _hhmm(window[1])
    return datetime.combine(d, start, tz), datetime.combine(d, end, tz)


def next_window_start(local: datetime, window: list[str], weekdays_only: bool) -> datetime:
    """``local`` itself when inside the window, else the next window opening (local time)."""
    if in_window(local, window, weekdays_only):
        return local
    d = local.date()
    start, _ = window_bounds(d, window, local.tzinfo)
    if is_send_day(d, weekdays_only) and local < start:
        return start
    d += timedelta(days=1)
    while not is_send_day(d, weekdays_only):
        d += timedelta(days=1)
    return window_bounds(d, window, local.tzinfo)[0]


def add_business_days(dt: datetime, n: int) -> datetime:
    out = dt
    added = 0
    while added < n:
        out += timedelta(days=1)
        if out.weekday() < 5:
            added += 1
    return out


def total_limit(cap: int) -> int:
    return min(TOTAL_HARD_LIMIT, 2 * cap)


@dataclass(slots=True)
class PlanItem:
    message_id: int
    domain: str
    new_thread: bool
    earliest: datetime | None = None  # aware


@dataclass(slots=True)
class DayLoad:
    """What is already sent / scheduled on one local day."""

    new: int = 0
    total: int = 0
    per_domain: dict[str, int] = field(default_factory=dict)
    last_at: datetime | None = None


def plan_send_times(
    items: list[PlanItem],
    *,
    now: datetime,
    window: list[str],
    weekdays_only: bool,
    new_limit: Callable[[date], int],
    total_cap: int,
    load: Callable[[date], DayLoad],
    rng: random.Random | None = None,
    spacing: tuple[float, float] = SPACING_S,
    max_days: int = 60,
) -> dict[int, datetime]:
    """Assign each item a send time (local, aware). Items are placed in order on the first
    allowed day with room; times inside a day are spaced ``spacing`` seconds apart."""
    rng = rng or random.Random()
    local_now = now.astimezone()
    tz = local_now.tzinfo
    loads: dict[date, DayLoad] = {}
    cursor: dict[date, datetime] = {}
    out: dict[int, datetime] = {}

    def day_load(d: date) -> DayLoad:
        if d not in loads:
            loads[d] = load(d)
        return loads[d]

    def gap() -> timedelta:
        return timedelta(seconds=max(MIN_SPACING_S, rng.uniform(*spacing)))

    for item in items:
        earliest = max(local_now, item.earliest.astimezone(tz)) if item.earliest else local_now
        d = next_window_start(earliest, window, weekdays_only).date()
        for _ in range(max_days):
            if not is_send_day(d, weekdays_only):
                d += timedelta(days=1)
                continue
            start, end = window_bounds(d, window, tz)
            ld = day_load(d)
            room_new = (not item.new_thread) or ld.new < new_limit(d)
            room = room_new and ld.total < total_cap and ld.per_domain.get(item.domain, 0) < PER_DOMAIN_PER_DAY
            if room:
                t = cursor.get(d) or max(start, earliest if earliest.date() == d else start)
                if ld.last_at is not None:
                    t = max(t, ld.last_at.astimezone(tz) + timedelta(seconds=MIN_SPACING_S))
                t = max(t, earliest)
                if t < end:
                    out[item.message_id] = t
                    cursor[d] = t + gap()
                    ld.total += 1
                    ld.new += int(item.new_thread)
                    ld.per_domain[item.domain] = ld.per_domain.get(item.domain, 0) + 1
                    ld.last_at = t
                    break
            d += timedelta(days=1)
        else:  # pragma: no cover - 60 days without room means caps of zero
            raise ValueError("no room to schedule within 60 days (is the daily cap 0?)")
    return out


# =====================================================================================
# DB-backed day load
# =====================================================================================


def day_load(conn: sqlite3.Connection, d: date, tz: Any) -> DayLoad:
    """Messages sent (or possibly sent) or scheduled on local day ``d``."""
    start = datetime.combine(d, time(0), tz)
    end = start + timedelta(days=1)
    rows = conn.execute(
        "SELECT seq, to_email, COALESCE(sent_at, send_at, updated_at) AS at FROM outreach_messages "
        "WHERE direction = 'out' AND state IN ('scheduled','sending','sent','unknown') "
        "AND COALESCE(sent_at, send_at, updated_at) >= ? AND COALESCE(sent_at, send_at, updated_at) < ?",
        (format_ts(start), format_ts(end)),
    ).fetchall()
    ld = DayLoad()
    for r in rows:
        ld.total += 1
        ld.new += int(r["seq"] == 0)
        dom = suppression.email_domain(r["to_email"]) or ""
        ld.per_domain[dom] = ld.per_domain.get(dom, 0) + 1
        at = parse_ts(r["at"])
        if ld.last_at is None or at > ld.last_at:
            ld.last_at = at
    return ld


def ramp_limit(conn: sqlite3.Connection, prefs: Preferences, d: date) -> int:
    """New-thread limit for local day ``d`` (the cap, lowered in the first week)."""
    first = db.get_meta(conn, db.META_OUTREACH_FIRST_SEND, None)
    cap = prefs.outreach_daily_cap
    start = date.fromisoformat(str(first)) if first else (utcnow().astimezone().date())
    days = (d - start).days
    for upto, limit in db.OUTREACH_RAMP:
        if days < upto:
            return min(cap, limit)
    return cap


# =====================================================================================
# The sender
# =====================================================================================


@dataclass(slots=True)
class SendResult:
    message_id: int
    state: MessageState
    detail: str | None = None


class OutreachSender:
    """Sends due ``scheduled`` messages, one per :meth:`tick`.

    ``compose_fn(msg, thread)`` builds the ``EmailMessage`` on the event loop (it reads the
    database); ``deliver_fn(email)`` does the SMTP part in a worker thread and raises
    ``SendRefused`` / ``SendUnknown``. ``ready()`` returns why sending is off (no mailbox, not
    enabled), or None."""

    def __init__(
        self,
        conn: sqlite3.Connection,
        *,
        emit: EmitFn,
        compose_fn: Callable[[OutreachMessage, OutreachThread], Any],
        deliver_fn: Callable[[Any], None],
        ready: Callable[[], str | None],
        is_paused: Callable[[], bool],
        on_sent: Callable[[OutreachMessage, OutreachThread], Awaitable[None]] | None = None,
        now: Callable[[], datetime] | None = None,
        rng: random.Random | None = None,
    ) -> None:
        self.conn = conn
        self.emit = emit
        self.compose_fn = compose_fn
        self.deliver_fn = deliver_fn
        self.ready = ready
        self.is_paused = is_paused
        self.on_sent = on_sent
        self.now = now or utcnow
        self.rng = rng or random.Random()

    def _prefs(self) -> Preferences:
        return db.get_preferences(self.conn)

    def _due(self, now: datetime) -> OutreachMessage | None:
        row = self.conn.execute(
            "SELECT * FROM outreach_messages WHERE direction = 'out' AND state = 'scheduled' AND send_at <= ? "
            "ORDER BY send_at, id LIMIT 1", (format_ts(now),),
        ).fetchone()
        return OutreachMessage.from_row(row) if row else None  # type: ignore[return-value]

    def _reschedule(self, msg: OutreachMessage, at: datetime, why: str) -> None:
        with db.transaction(self.conn):
            self.conn.execute("UPDATE outreach_messages SET send_at = ?, updated_at = ? WHERE id = ?",
                              (format_ts(at), format_ts(self.now()), msg.id))
        log.info("outreach message %s moved to %s (%s)", msg.id, at.isoformat(), why)

    async def _cancel(self, msg: OutreachMessage, reason: str) -> None:
        t = db.transition_outreach(self.conn, msg.id, MessageState.CANCELLED, reason=reason)
        await self.emit("outreach_state", t.to_payload())

    async def tick(self) -> SendResult | None:
        """Send at most one due message. Returns what happened (None: nothing to do)."""
        if self.is_paused() or self.ready() is not None:
            return None
        now = self.now()
        nxt = db.get_meta(self.conn, META_NEXT_SEND, None)
        if nxt and parse_ts(nxt) > now:
            return None
        msg = self._due(now)
        if msg is None:
            return None
        # ---- final gate: no await from here to the `sending` write -------------------------
        prefs = self._prefs()
        local = now.astimezone()
        if not in_window(local, prefs.outreach_send_window, prefs.outreach_weekdays_only):
            self._reschedule(msg, next_window_start(local, prefs.outreach_send_window, prefs.outreach_weekdays_only), "outside the send window")
            return None
        thread = OutreachThread.from_row(self.conn.execute("SELECT * FROM outreach_threads WHERE id = ?", (msg.thread_id,)).fetchone())  # type: ignore[arg-type]
        if thread.state not in (ThreadState.DRAFT, ThreadState.ACTIVE):
            await self._cancel(msg, f"thread {thread.state.value}")
            return SendResult(msg.id, MessageState.CANCELLED, f"thread {thread.state.value}")
        if not msg.to_email or (reason := suppression.check(self.conn, msg.to_email)) is not None:
            await self._cancel(msg, f"do-not-contact ({reason.value if reason else 'no address'})")
            return SendResult(msg.id, MessageState.CANCELLED, "do-not-contact")
        if msg.seq > 0 and thread.application_id is not None:
            st = self.conn.execute("SELECT status FROM applications WHERE id = ?", (thread.application_id,)).fetchone()
            if st and st["status"] in ("rejected", "offer"):
                await self._cancel(msg, f"application {st['status']}")
                return SendResult(msg.id, MessageState.CANCELLED, "application closed")
        today = local.date()
        new_used = db.outreach_new_threads_today(self.conn, now)
        total_used = db.outreach_sends_since(self.conn, db.local_day_start(now))
        dom = suppression.email_domain(msg.to_email) or ""
        dom_used = db.outreach_sends_since(self.conn, db.local_day_start(now), domain=dom)
        limit = ramp_limit(self.conn, prefs, today)
        over = None
        if msg.seq == 0 and new_used >= limit:
            over = ("new threads", new_used, limit)
        elif total_used >= total_limit(prefs.outreach_daily_cap):
            over = ("emails", total_used, total_limit(prefs.outreach_daily_cap))
        elif dom_used >= PER_DOMAIN_PER_DAY:
            over = (f"emails to {dom}", dom_used, PER_DOMAIN_PER_DAY)
        if over is not None:
            tomorrow = local.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
            self._reschedule(msg, next_window_start(tomorrow, prefs.outreach_send_window, prefs.outreach_weekdays_only),
                             f"daily limit of {over[0]} reached")
            await self._announce_cap(over[1], over[2], today)
            return None
        from autoapply.mail.smtp_send import make_message_id

        mailbox = self._mailbox()
        mid = msg.message_id_header or make_message_id(mailbox)
        t = db.transition_outreach(self.conn, msg.id, MessageState.SENDING, expected_from=MessageState.SCHEDULED,
                                   fields={"message_id_header": mid, "from_email": mailbox})
        # ---- committed: now the SMTP conversation ------------------------------------------
        await self.emit("outreach_state", t.to_payload())
        msg = msg.model_copy(update={"message_id_header": mid, "from_email": mailbox, "state": MessageState.SENDING})
        from autoapply.mail.smtp_send import SendRefused, SendUnknown

        try:
            email = self.compose_fn(msg, thread)
        except Exception as e:  # noqa: BLE001 - nothing was sent
            t = db.transition_outreach(self.conn, msg.id, MessageState.FAILED, reason=f"could not compose: {e}"[:300])
            await self.emit("outreach_state", t.to_payload())
            return SendResult(msg.id, MessageState.FAILED, str(e))
        try:
            await asyncio.to_thread(self.deliver_fn, email)
        except SendRefused as e:
            t = db.transition_outreach(self.conn, msg.id, MessageState.FAILED, reason=str(e)[:300])
            await self.emit("outreach_state", t.to_payload())
            return SendResult(msg.id, MessageState.FAILED, str(e))
        except (SendUnknown, Exception) as e:  # noqa: BLE001 - anything mid-DATA: maybe sent
            t = db.transition_outreach(self.conn, msg.id, MessageState.UNKNOWN, reason=f"send interrupted: {e}"[:300])
            await self.emit("outreach_state", t.to_payload())
            return SendResult(msg.id, MessageState.UNKNOWN, str(e))
        sent_at = self.now()
        t = db.transition_outreach(self.conn, msg.id, MessageState.SENT, fields={"sent_at": format_ts(sent_at)}, actor=Actor.SYSTEM)
        if not db.get_meta(self.conn, db.META_OUTREACH_FIRST_SEND, None):
            db.set_meta(self.conn, db.META_OUTREACH_FIRST_SEND, sent_at.astimezone().date().isoformat())
        gap = max(MIN_SPACING_S, self.rng.uniform(*SPACING_S))
        db.set_meta(self.conn, META_NEXT_SEND, format_ts(sent_at + timedelta(seconds=gap)))
        await self.emit("outreach_state", t.to_payload())
        if self.on_sent is not None:
            await self.on_sent(msg.model_copy(update={"state": MessageState.SENT, "sent_at": sent_at}), thread)
        return SendResult(msg.id, MessageState.SENT)

    def _mailbox(self) -> str:
        from autoapply.mail import imap_codes

        acc = imap_codes.account(self.conn) or {}
        return str(acc.get("email") or "")

    async def _announce_cap(self, used: int, limit: int, today: date) -> None:
        if db.get_meta(self.conn, META_CAP_ANNOUNCED, None) == today.isoformat():
            return
        db.set_meta(self.conn, META_CAP_ANNOUNCED, today.isoformat())
        tomorrow = datetime.combine(today + timedelta(days=1), time(0)).astimezone()
        await self.emit("cap_reached", CapReachedPayload(cap=CapKind.OUTREACH_DAILY, used=used, limit=limit, resets_at=tomorrow))


__all__ = [
    "DayLoad", "OutreachSender", "PlanItem", "SendResult", "add_business_days", "day_load", "in_window", "is_send_day",
    "next_window_start", "plan_send_times", "ramp_limit", "total_limit",
]
