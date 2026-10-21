"""Cold-outreach gaps: the stored board suggestion of an outreach reply (survives a restart,
accept / dismiss), bulk contact deletion, unwatching a prospect, reconnecting the mailbox keeps
sending, and the ``no_address`` approval conflict. No network, SMTP, IMAP or browser."""

from __future__ import annotations

import re
from datetime import timedelta

import pytest

from autoapply import db
from autoapply.enums import BoardStatus, DraftKind, EmailStatus, MessageState, OutreachKind, SuppressionReason
from autoapply.mail import imap_codes
from autoapply.models import format_ts
from autoapply.outreach import contacts, prospects, suppression, threads
from autoapply.paths import Paths
from tests.d_daemon.test_outreach import World, _send_first
from tests.outreach_fakes import eml

SUGGESTS_INTERVIEW = {"label": "positive", "suggested_status": "interview"}


@pytest.fixture
async def world(autoapply_home: Paths):
    w = World(autoapply_home)
    try:
        yield w
    finally:
        await w.daemon.stop()


async def _reply_suggesting_interview(world: World) -> tuple[int, int]:
    world.llm.rules.insert(0, (re.compile(r"\AREPLY:"), SUGGESTS_INTERVIEW))
    app_id, thread_id, _mid, sent_mid = await _send_first(world)
    world.mailbox.folders["INBOX"].append(eml("reply_positive.eml", **{"<orig-1@gmail.com>": sent_mid}))
    rep = await world.daemon.outreach.scan_mail()
    assert rep is not None and rep.replies == 1
    return app_id, thread_id


# ---- 1. the outreach reply's suggested board move is stored ---------------------------------------


async def test_outreach_suggestion_is_stored_and_survives_a_restart(autoapply_home: Paths):
    w = World(autoapply_home)
    try:
        app_id, thread_id = await _reply_suggesting_interview(w)
        [ev] = [p for t, p in w.events if t == "outreach_reply"]
        assert ev.suggested_status is BoardStatus.INTERVIEW and ev.application_id == app_id
        t = threads.get_thread(w.conn, thread_id)
        assert (t.suggested_status, t.suggestion_state, t.suggestion_decided_at) == (BoardStatus.INTERVIEW, "pending", None)
        assert db.get_application(w.conn, app_id).status is BoardStatus.APPLIED  # never applied by itself
    finally:
        await w.daemon.stop()
    # A new daemon on the same database still has it and can apply it.
    w2 = World(autoapply_home)
    try:
        row = w2.conn.execute("SELECT suggested_status, suggestion_state FROM outreach_threads WHERE id = ?", (thread_id,)).fetchone()
        assert tuple(row) == ("interview", "pending")
        res = await w2.ok("accept_outreach_suggestion", {"thread_id": thread_id})
        assert res == {"thread_id": thread_id, "application_id": app_id, "status": "interview"}
    finally:
        await w2.daemon.stop()


async def test_accept_outreach_suggestion(world: World):
    app_id, thread_id = await _reply_suggesting_interview(world)
    res = await world.ok("accept_outreach_suggestion", {"thread_id": thread_id})
    assert res == {"thread_id": thread_id, "application_id": app_id, "status": "interview"}
    assert db.get_application(world.conn, app_id).status is BoardStatus.INTERVIEW
    status = [p for t, p in world.events if t == "application_status"][-1]
    assert status.status is BoardStatus.INTERVIEW and status.actor.value == "user"
    t = threads.get_thread(world.conn, thread_id)
    assert t.suggestion_state == "accepted" and t.suggestion_decided_at is not None
    again = await world.cmd("accept_outreach_suggestion", {"thread_id": thread_id})
    assert again["type"] == "error" and again["code"] == "conflict"
    assert (await world.cmd("accept_outreach_suggestion", {"thread_id": 999}))["code"] == "not_found"


async def test_dismiss_outreach_suggestion(world: World):
    app_id, thread_id = await _reply_suggesting_interview(world)
    assert await world.ok("dismiss_outreach_suggestion", {"thread_id": thread_id}) is None
    await world.ok("dismiss_outreach_suggestion", {"thread_id": thread_id})  # idempotent
    t = threads.get_thread(world.conn, thread_id)
    assert t.suggestion_state == "dismissed" and t.suggestion_decided_at is not None
    assert db.get_application(world.conn, app_id).status is BoardStatus.APPLIED
    assert (await world.cmd("accept_outreach_suggestion", {"thread_id": thread_id}))["code"] == "conflict"


async def test_no_suggestion_stored_when_the_status_already_matches(world: World):
    world.llm.rules.insert(0, (re.compile(r"\AREPLY:"), SUGGESTS_INTERVIEW))
    app_id, thread_id, _mid, sent_mid = await _send_first(world)
    db.set_status(world.conn, app_id, BoardStatus.INTERVIEW)
    world.mailbox.folders["INBOX"].append(eml("reply_positive.eml", **{"<orig-1@gmail.com>": sent_mid}))
    await world.daemon.outreach.scan_mail()
    t = threads.get_thread(world.conn, thread_id)
    assert (t.suggested_status, t.suggestion_state) == (None, "none")
    [ev] = [p for typ, p in world.events if typ == "outreach_reply"]
    assert ev.suggested_status is None


# ---- 2. bulk contact deletion ---------------------------------------------------------------------


def _contact(world: World, name: str, origin: str, *, company_id: int | None, age_days: int = 0) -> int:
    email = name.lower().replace(" ", ".") + "@acme.com"
    c = contacts.upsert_contact(world.conn, company_id=company_id, full_name=name, origin=origin, email=email,
                                email_status=EmailStatus.USER if origin in ("user", "import") else EmailStatus.PATTERN).contact
    if age_days:
        world.conn.execute("UPDATE contacts SET created_at = ? WHERE id = ?",
                           (format_ts(world.clock() - timedelta(days=age_days)), c.id))
    return c.id


async def test_delete_contacts_older_than_keeps_user_and_imported(world: World):
    _app, thread_id, _mid = await world.drafted_and_approved()  # Jane (user) has a scheduled email
    co = threads.get_thread(world.conn, thread_id).company_id
    old_scout = _contact(world, "Old Scout", "scout", company_id=co, age_days=400)
    new_scout = _contact(world, "New Scout", "scout", company_id=co, age_days=10)
    old_user = _contact(world, "Old Typed", "user", company_id=co, age_days=400)
    old_import = _contact(world, "Old Import", "import", company_id=co, age_days=400)
    res = await world.ok("delete_contacts", {"older_than_days": 180})
    assert res == {"deleted": 1, "skipped_active": 0}
    left = {c.id for c in contacts.list_contacts(world.conn)}
    assert old_scout not in left and {new_scout, old_user, old_import} <= left
    assert suppression.check(world.conn, "old.scout@acme.com") is None  # suppress defaults to false


async def test_delete_contacts_by_ids_and_all_skip_live_conversations(world: World):
    _app, thread_id, mid = await world.drafted_and_approved()
    t = threads.get_thread(world.conn, thread_id)
    jane, co = t.contact_id, t.company_id
    assert threads.get_message(world.conn, mid).state is MessageState.SCHEDULED
    typed = _contact(world, "Ravi Typed", "user", company_id=co)
    res = await world.ok("delete_contacts", {"ids": [jane, typed], "suppress": True})
    assert res == {"deleted": 1, "skipped_active": 1}  # Jane's email is scheduled: kept
    assert suppression.check(world.conn, "ravi.typed@acme.com") is SuppressionReason.USER
    assert contacts.get_contact(world.conn, jane).id == jane
    _contact(world, "Imported One", "import", company_id=co)
    _contact(world, "Scouted One", "scout", company_id=co)
    res = await world.ok("delete_contacts", {"all": True})
    assert res == {"deleted": 2, "skipped_active": 1}
    assert [c.id for c in contacts.list_contacts(world.conn)] == [jane]
    # Once nothing is scheduled the contact can go; a draft-only thread loses its pending draft.
    await world.ok("cancel_outreach", {"message_ids": [mid]})
    assert await world.ok("delete_contacts", {"ids": [jane]}) == {"deleted": 1, "skipped_active": 0}
    assert threads.get_message(world.conn, mid).state is MessageState.CANCELLED


async def test_delete_contacts_skips_active_threads_and_needs_a_filter(world: World):
    _app, thread_id, _mid, _sent = await _send_first(world)
    jane = threads.get_thread(world.conn, thread_id).contact_id
    assert await world.ok("delete_contacts", {"all": True}) == {"deleted": 0, "skipped_active": 1}
    r = await world.cmd("delete_contacts", {})
    assert r["type"] == "error" and r["code"] == "invalid_payload"
    assert await world.ok("delete_contacts", {"ids": []}) == {"deleted": 0, "skipped_active": 0}
    assert contacts.get_contact(world.conn, jane)


# ---- 3. unwatch a prospect ------------------------------------------------------------------------


async def test_update_prospect_can_unwatch(world: World):
    co = db.upsert_company(world.conn, "Globex", domain="globex.com")
    p = prospects.upsert(world.conn, co.id, status=prospects.ProspectStatus.SHORTLISTED, found_via="user")
    await world.ok("update_prospect", {"id": p.id, "watch": True})
    assert db.get_company(world.conn, co.id).watch
    await world.ok("update_prospect", {"id": p.id, "status": "contacted"})  # watch absent: unchanged
    assert db.get_company(world.conn, co.id).watch
    await world.ok("update_prospect", {"id": p.id, "watch": False})
    company = db.get_company(world.conn, co.id)
    assert not company.watch and company.domain == "globex.com"
    assert prospects.get(world.conn, p.id).status is prospects.ProspectStatus.CONTACTED  # history kept


# ---- 4. reconnecting the mailbox keeps sending ------------------------------------------------------


async def test_reconnect_same_address_keeps_sending(world: World, monkeypatch: pytest.MonkeyPatch):
    deleted: list[str] = []
    monkeypatch.setattr(imap_codes, "test_login", lambda a, p: None)
    monkeypatch.setattr(imap_codes, "keychain_set", lambda a, p: None)
    monkeypatch.setattr(imap_codes, "keychain_delete", lambda a: deleted.append(a))
    db.set_meta(world.conn, imap_codes.META_KEY, {"email": "asha@gmail.com", "enabled": True, "send_enabled": True,
                                                  "send_enabled_at": "2026-10-01T00:00:00.000Z"})
    await world.ok("set_mail_account", {"email": "Asha@gmail.com", "app_password": "new-pass"})
    acc = imap_codes.account(world.conn)
    assert acc["send_enabled"] is True and acc["send_enabled_at"] == "2026-10-01T00:00:00.000Z"
    assert world.daemon.outreach.send_blocker() is None and deleted == []
    # A different address needs a new test send.
    await world.ok("set_mail_account", {"email": "asha.rao@gmail.com", "app_password": "pass"})
    acc = imap_codes.account(world.conn)
    assert acc["email"] == "asha.rao@gmail.com" and acc["send_enabled"] is False
    assert world.daemon.outreach.send_blocker() is not None and deleted == ["Asha@gmail.com"]


# ---- 5. approve_outreach: no_address ----------------------------------------------------------------


async def test_approve_reports_no_address_apart_from_do_not_contact(world: World):
    app_id, cid, co = world.seed()
    d = await world.ok("draft_outreach", {"contact_id": cid, "kind": "application", "application_id": app_id})
    world.conn.execute("UPDATE outreach_messages SET to_email = NULL WHERE id = ?", (d["message_id"],))
    other = _contact(world, "Ravi Kumar", "user", company_id=co)
    t2 = threads.create_thread(world.conn, kind=OutreachKind.PROSPECT, company_id=co, contact_id=other)
    m2 = threads.insert_draft(world.conn, thread_id=t2.id, kind=DraftKind.PROSPECT, to_email="ravi.kumar@acme.com", subject="Hi",
                              body="Hello Ravi.", footer=None, grounded=True, unsupported=[], story_ids=[])
    suppression.add(world.conn, email="ravi.kumar@acme.com", reason=SuppressionReason.USER, source="test")
    r = await world.cmd("approve_outreach", {"message_ids": [d["message_id"], m2.id]})
    assert r["type"] == "error" and r["code"] == "conflict"
    assert r["details"] == {"no_address": [d["message_id"]], "do_not_contact": [m2.id]}
    assert "no recipient address" in r["message"]
