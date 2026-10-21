"""Thread and message bookkeeping shared by the service, the sender and the mail watcher.

Message state changes go through ``db.transition_outreach`` (state machine + activity log);
thread state changes go through :func:`set_thread_state`, which also logs an ``outreach``
event. Every function returns the ``outreach_state`` payloads the caller should emit.
"""

from __future__ import annotations

import sqlite3
from typing import Any

from autoapply import db
from autoapply.enums import Actor, DraftKind, MessageState, OutreachKind, ThreadOutcome, ThreadState
from autoapply.models import (
    PENDING_MESSAGE_STATES,
    OutreachMessage,
    OutreachStatePayload,
    OutreachThread,
    now_ts,
)


def get_thread(conn: sqlite3.Connection, thread_id: int) -> OutreachThread:
    row = conn.execute("SELECT * FROM outreach_threads WHERE id = ?", (thread_id,)).fetchone()
    if row is None:
        raise db.NotFound(f"outreach thread {thread_id} not found")
    return OutreachThread.from_row(row)  # type: ignore[return-value]


def get_message(conn: sqlite3.Connection, message_id: int) -> OutreachMessage:
    row = conn.execute("SELECT * FROM outreach_messages WHERE id = ?", (message_id,)).fetchone()
    if row is None:
        raise db.NotFound(f"outreach message {message_id} not found")
    return OutreachMessage.from_row(row)  # type: ignore[return-value]


def messages(conn: sqlite3.Connection, thread_id: int, *, direction: str | None = None) -> list[OutreachMessage]:
    sql, params = "SELECT * FROM outreach_messages WHERE thread_id = ?", [thread_id]
    if direction:
        sql += " AND direction = ?"
        params.append(direction)
    return [OutreachMessage.from_row(r) for r in conn.execute(sql + " ORDER BY seq, id", params)]  # type: ignore[misc]


def sent_messages(conn: sqlite3.Connection, thread_id: int) -> list[OutreachMessage]:
    return [m for m in messages(conn, thread_id, direction="out") if m.state is MessageState.SENT]


def create_thread(
    conn: sqlite3.Connection, *, kind: OutreachKind, company_id: int, contact_id: int | None,
    job_id: int | None = None, application_id: int | None = None,
) -> OutreachThread:
    ts = now_ts()
    with db.transaction(conn):
        cur = conn.execute(
            "INSERT INTO outreach_threads(kind, contact_id, company_id, job_id, application_id, state, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, 'draft', ?, ?)",
            (kind.value, contact_id, company_id, job_id, application_id, ts, ts),
        )
        tid = int(cur.lastrowid)
        db.log_event(conn, "outreach", f"new {kind.value} email thread", job_id=job_id, application_id=application_id,
                     payload={"thread_id": tid, "contact_id": contact_id})
    return get_thread(conn, tid)


def update_thread(conn: sqlite3.Connection, thread_id: int, **fields: Any) -> None:
    fields["updated_at"] = now_ts()
    sql, params = db._update_sql("outreach_threads", fields, "id = ?")
    with db.transaction(conn):
        conn.execute(sql, [*params, thread_id])


def set_thread_state(
    conn: sqlite3.Connection, thread_id: int, to: ThreadState, *, reason: str | None = None,
    actor: Actor = Actor.SYSTEM, outcome: ThreadOutcome | None = None, **fields: Any,
) -> OutreachStatePayload | None:
    """Change a thread's state (None when it is already there)."""
    with db.transaction(conn):
        t = get_thread(conn, thread_id)
        if t.state is to and outcome is None and not fields:
            return None
        upd: dict[str, Any] = {"state": to.value, **fields}
        if outcome is not None:
            upd["outcome"] = outcome.value
        update_thread(conn, thread_id, **upd)
        db.log_event(conn, "outreach", f"thread {t.state.value} → {to.value}" + (f" ({reason})" if reason else ""),
                     actor=actor, job_id=t.job_id, application_id=t.application_id,
                     payload={"thread_id": thread_id, "from": t.state.value, "to": to.value, "reason": reason})
    return OutreachStatePayload(thread_id=thread_id, entity="thread", from_state=t.state.value, to_state=to.value,
                                reason=reason, at=now_ts())


def cancel_pending(conn: sqlite3.Connection, thread_id: int, reason: str, *, actor: Actor = Actor.SYSTEM,
                   followups_only: bool = False) -> list[OutreachStatePayload]:
    """Cancel every draft / approved / scheduled outbound message of the thread."""
    out: list[OutreachStatePayload] = []
    with db.transaction(conn):
        for m in messages(conn, thread_id, direction="out"):
            if m.state in PENDING_MESSAGE_STATES and (not followups_only or m.seq > 0):
                out.append(db.transition_outreach(conn, m.id, MessageState.CANCELLED, reason=reason, actor=actor).to_payload())
    return out


def next_seq(conn: sqlite3.Connection, thread_id: int) -> int:
    row = conn.execute("SELECT MAX(seq) FROM outreach_messages WHERE thread_id = ? AND direction = 'out' AND state <> 'cancelled'",
                       (thread_id,)).fetchone()
    return 0 if row[0] is None else int(row[0]) + 1


def insert_draft(
    conn: sqlite3.Connection, *, thread_id: int, kind: DraftKind, to_email: str | None, subject: str | None, body: str,
    footer: str | None, grounded: bool, unsupported: list[str], story_ids: list[int], tokens_in: int = 0,
    tokens_out: int = 0, in_reply_to: str | None = None, seq: int | None = None,
) -> OutreachMessage:
    ts = now_ts()
    with db.transaction(conn):
        seq = next_seq(conn, thread_id) if seq is None else seq
        cur = conn.execute(
            "INSERT INTO outreach_messages(thread_id, seq, direction, kind, state, to_email, subject, body, footer, origin, grounded, "
            "unsupported_claims, story_ids, in_reply_to, tokens_in, tokens_out, created_at, updated_at) "
            "VALUES (?, ?, 'out', ?, 'draft', ?, ?, ?, ?, 'generated', ?, ?, ?, ?, ?, ?, ?, ?)",
            (thread_id, seq, kind.value, to_email, subject, body, footer,
             int(grounded), db._j(unsupported), db._j(story_ids), in_reply_to, tokens_in, tokens_out, ts, ts),
        )
        if subject and seq == 0:
            conn.execute("UPDATE outreach_threads SET subject = ?, updated_at = ? WHERE id = ?", (subject, ts, thread_id))
    return get_message(conn, int(cur.lastrowid))


def thread_for_message_id(conn: sqlite3.Connection, message_id_header: str) -> OutreachMessage | None:
    mid = message_id_header.strip()
    if not mid.startswith("<"):
        mid = f"<{mid}>"
    row = conn.execute("SELECT * FROM outreach_messages WHERE message_id_header = ?", (mid,)).fetchone()
    return OutreachMessage.from_row(row) if row else None  # type: ignore[return-value]


__all__ = [
    "cancel_pending", "create_thread", "get_message", "get_thread", "insert_draft", "messages", "next_seq", "sent_messages",
    "set_thread_state", "thread_for_message_id", "update_thread",
]
