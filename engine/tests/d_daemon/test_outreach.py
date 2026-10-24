"""Cold outreach through the daemon: approval -> sender (SMTP double) -> sent; crash during
``sending`` -> ``unknown`` -> Sent Mail lookup; replies cancel the follow-up and block auto-ghost;
opt-outs and bounces; pause; the outreach cap; auto-scout after a submit; referrals and prospects
through Google results only. No network, SMTP, IMAP, DNS or browser."""

from __future__ import annotations

import asyncio
import contextlib
import email
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import httpx
import pytest
import respx

from autoapply import db
from autoapply.discovery.linkedin import HumanPacer
from autoapply.enums import BoardStatus, EmailStatus, MessageState, ReferralState, SuppressionReason, ThreadState
from autoapply.llm.provider import FakeLLMProvider
from autoapply.mail import imap_codes
from autoapply.models import make_command
from autoapply.outreach import contacts, sender, suppression, threads
from autoapply.paths import Paths
from tests.d_daemon.test_daemon import build_daemon
from tests.outreach_fakes import (
    FOLLOWUP_DRAFT,
    GOOD_DRAFT,
    FakeMailbox,
    FakeSMTP,
    connect_mailbox,
    eml,
    fixture,
    resolver,
    seed_profile,
    seed_submitted_application,
)


class Clock:
    """Injected 'now': a Monday 10:00 local at least a week after the seeded application (so the
    one-business-day wait after submitting has passed whatever day the suite runs)."""

    def __init__(self) -> None:
        today = datetime.now().astimezone()
        monday = today + timedelta(days=((7 - today.weekday()) % 7 or 7) + 7)
        self.t = monday.replace(hour=10, minute=0, second=0, microsecond=0)

    def __call__(self) -> datetime:
        return self.t

    def advance(self, **kw: Any) -> None:
        self.t += timedelta(**kw)


def _http():
    @contextlib.asynccontextmanager
    async def factory():
        async with httpx.AsyncClient() as client:
            yield client

    return factory


class World:
    def __init__(self, home: Paths, *, llm: FakeLLMProvider | None = None, mailbox: FakeMailbox | None = None) -> None:
        self.clock = Clock()
        self.mailbox = mailbox or FakeMailbox()
        self.llm = llm or FakeLLMProvider(rules=[(r"PREVIOUS EMAIL", FOLLOWUP_DRAFT)], default=GOOD_DRAFT)
        FakeSMTP.reset()
        self.daemon = build_daemon(home, Path("/tmp/unused-outreach.sock"), llm=self.llm, outreach_options=dict(
            smtp_factory=FakeSMTP, mailbox_factory=lambda a, p: self.mailbox, mail_password=lambda a: "app-pass",
            mx_resolver=resolver(), http_factory=_http(), provider_key=lambda p: None, now=self.clock,
            pacer=HumanPacer(sleep=_no_sleep),
        ))
        self.daemon._ensure_core()
        self.conn = self.daemon.conn
        self.events: list[tuple[str, Any]] = []

        async def capture(event_type: str, payload: Any) -> None:
            self.events.append((event_type, payload))

        self.daemon.broadcast = capture  # type: ignore[method-assign]

    async def cmd(self, type_: str, payload: dict | None = None) -> dict:
        reply = (await self.daemon.handle(make_command(type_, payload or {})))[0]
        return {"type": reply.type, **reply.payload}

    async def ok(self, type_: str, payload: dict | None = None) -> Any:
        r = await self.cmd(type_, payload)
        assert r["type"] == "ack", r
        return r["result"]

    def types(self) -> list[str]:
        return [t for t, _ in self.events]

    async def drain(self) -> None:
        for _ in range(5):
            tasks = [t for t in list(self.daemon._tasks) if not t.done()]
            if not tasks:
                return
            await asyncio.gather(*tasks, return_exceptions=True)

    def seed(self) -> tuple[int, int, int]:
        seed_profile(self.conn)
        connect_mailbox(self.conn)
        co_id, _job, app_id = seed_submitted_application(self.conn)
        c = contacts.upsert_contact(self.conn, company_id=co_id, full_name="Jane Doe", origin="user", email="jane@acme.com",
                                    email_status=EmailStatus.USER, title="Senior Recruiter").contact
        return app_id, c.id, co_id

    async def drafted_and_approved(self, *, include_followups: bool = False) -> tuple[int, int, int]:
        app_id, cid, _co = self.seed()
        d = await self.ok("draft_outreach", {"contact_id": cid, "kind": "application", "application_id": app_id})
        await self.ok("approve_outreach", {"message_ids": [d["message_id"]], "include_followups": include_followups})
        return app_id, d["thread_id"], d["message_id"]


async def _no_sleep(_s: float) -> None:
    return None


@pytest.fixture
async def world(autoapply_home: Paths):
    w = World(autoapply_home)
    try:
        yield w
    finally:
        await w.daemon.stop()


def _state(conn, message_id: int) -> MessageState:
    return threads.get_message(conn, message_id).state


# ---- approval and sending ----------------------------------------------------------------------


async def test_sending_needs_enable_sending_with_a_test_email(world: World):
    app_id, cid, _ = world.seed()
    db.set_meta(world.conn, imap_codes.META_KEY, {"email": "asha@gmail.com", "enabled": True})  # connected, not enabled
    d = await world.ok("draft_outreach", {"contact_id": cid, "kind": "application", "application_id": app_id})
    r = await world.cmd("approve_outreach", {"message_ids": [d["message_id"]]})
    assert r["type"] == "error" and r["code"] == "unavailable"
    FakeSMTP.reset(fail_at="login")
    r = await world.cmd("enable_sending", {"enabled": True})
    assert r["type"] == "error" and r["code"] == "unavailable"
    assert world.daemon.outreach.send_blocker() is not None
    FakeSMTP.reset()
    res = await world.ok("enable_sending", {"enabled": True})
    assert res == {"send_enabled": True, "test_sent_to": "asha@gmail.com"}
    [test_mail] = FakeSMTP.messages()
    assert test_mail["To"] == "asha@gmail.com" and test_mail["From"].endswith("<asha@gmail.com>")
    assert world.daemon.outreach.send_blocker() is None
    assert (await world.ok("approve_outreach", {"message_ids": [d["message_id"]]}))["scheduled"]


async def test_approve_then_sender_sends_with_sending_prewrite(world: World):
    seen_state: list[str] = []
    real_data = FakeSMTP.data

    def data(self, msg: bytes) -> tuple[int, bytes]:
        ro = db.connect(world.daemon.paths.db, readonly=True)
        try:
            seen_state.append(ro.execute("SELECT state FROM outreach_messages WHERE direction = 'out'").fetchone()[0])
        finally:
            ro.close()
        return real_data(self, msg)

    FakeSMTP.data = data  # type: ignore[method-assign]
    try:
        app_id, thread_id, mid = await world.drafted_and_approved()
        assert _state(world.conn, mid) is MessageState.SCHEDULED
        assert FakeSMTP.messages() == []  # approval alone sends nothing
        res = await world.daemon.outreach.sender.tick()
    finally:
        FakeSMTP.data = real_data  # type: ignore[method-assign]
    assert res is not None and res.state is MessageState.SENT
    assert seen_state == ["sending"]  # committed before DATA
    [sent] = FakeSMTP.messages()
    assert sent["To"] == "jane@acme.com" and sent["Subject"] == GOOD_DRAFT["subject"]
    assert sent.get_content_type() == "text/plain"
    body = sent.get_payload(decode=True).decode()
    assert body.startswith("Hi Jane") and "I won't email again" in body
    m = threads.get_message(world.conn, mid)
    assert m.state is MessageState.SENT and m.message_id_header == sent["Message-ID"]
    assert threads.get_thread(world.conn, thread_id).state is ThreadState.ACTIVE
    assert FakeSMTP.rcpt_calls() == ["jane@acme.com"]  # one RCPT per real email, never a probe
    assert any(e.message.startswith("Emailed Jane") for e in db.list_events(world.conn, application_id=app_id))
    assert "outreach_state" in world.types()


async def test_smtp_refusal_is_failed_and_drop_is_unknown(world: World):
    _app, _thread, mid = await world.drafted_and_approved()
    FakeSMTP.reset(fail_at="rcpt")
    res = await world.daemon.outreach.sender.tick()
    assert res.state is MessageState.FAILED and _state(world.conn, mid) is MessageState.FAILED


async def test_data_drop_is_unknown_and_never_resent(world: World):
    _app, _thread, mid = await world.drafted_and_approved()
    FakeSMTP.reset(fail_at="data_drop")
    res = await world.daemon.outreach.sender.tick()
    assert res.state is MessageState.UNKNOWN
    FakeSMTP.reset()
    db.delete_meta(world.conn, sender.META_NEXT_SEND)
    assert await world.daemon.outreach.sender.tick() is None
    assert FakeSMTP.instances == []


async def test_crash_during_sending_then_sent_mail_check(world: World):
    _app, _thread, mid = await world.drafted_and_approved()
    db.transition_outreach(world.conn, mid, MessageState.SENDING, fields={"message_id_header": "<crash-1@gmail.com>"})
    report = await world.daemon.recover()
    await world.drain()  # recovery's own Sent Mail check (nothing there yet)
    assert [t.message_id for t in report.outreach_unknown] == [mid]
    assert _state(world.conn, mid) is MessageState.UNKNOWN
    assert db.compute_counts(world.conn).outreach_unknown == 1
    # Not in Sent Mail: stays unknown for the user.
    assert await world.daemon.outreach.verify_unknown() == 0
    assert _state(world.conn, mid) is MessageState.UNKNOWN
    # In Sent Mail: resolved to sent.
    world.mailbox.folders['"[Gmail]/Sent Mail"'].append(email.message_from_string(
        "From: asha@gmail.com\nTo: jane@acme.com\nMessage-ID: <crash-1@gmail.com>\nSubject: x\n\nbody"))
    assert await world.daemon.outreach.verify_unknown() == 1
    assert _state(world.conn, mid) is MessageState.SENT
    assert any("rfc822msgid:crash-1@gmail.com" in s for s in world.mailbox.searches)


async def test_resolve_unknown_by_the_user(world: World):
    _app, _thread, mid = await world.drafted_and_approved()
    db.transition_outreach(world.conn, mid, MessageState.SENDING)
    db.transition_outreach(world.conn, mid, MessageState.UNKNOWN)
    await world.ok("resolve_outreach_unknown", {"message_id": mid, "sent": False})
    assert _state(world.conn, mid) is MessageState.FAILED


async def test_pause_stops_the_sender(world: World):
    _app, _thread, mid = await world.drafted_and_approved()
    await world.ok("pause_all")
    assert await world.daemon.outreach.sender.tick() is None
    assert FakeSMTP.instances == [] and _state(world.conn, mid) is MessageState.SCHEDULED
    await world.ok("resume")
    assert (await world.daemon.outreach.sender.tick()).state is MessageState.SENT


async def test_outreach_cap_moves_the_email_and_emits_cap_reached(world: World):
    app_id, cid, _co_id = world.seed()
    db.update_preferences(world.conn, {"outreach_daily_cap": 1})
    co2, _job2, app2 = seed_submitted_application(world.conn, company="Globex", domain="globex.com")
    c2 = contacts.upsert_contact(world.conn, company_id=co2, full_name="Ravi Kumar", origin="user", email="ravi@globex.com",
                                 email_status=EmailStatus.USER).contact
    world.llm.add_rule(r"RECIPIENT: Ravi Kumar", {**GOOD_DRAFT, "body": GOOD_DRAFT["body"].replace("Jane", "Ravi").replace("Acme", "Globex")})
    d1 = await world.ok("draft_outreach", {"contact_id": cid, "kind": "application", "application_id": app_id})
    d2 = await world.ok("draft_outreach", {"contact_id": c2.id, "kind": "application", "application_id": app2})
    res = await world.ok("approve_outreach", {"message_ids": [d1["message_id"], d2["message_id"]]})
    assert len(res["days"]) == 2  # never fails because of caps: the second goes to the next day
    assert (await world.daemon.outreach.sender.tick()).state is MessageState.SENT
    # Someone moved the second one to now (e.g. an older schedule): the sender still holds the cap.
    with db.transaction(world.conn):
        world.conn.execute("UPDATE outreach_messages SET send_at = ? WHERE id = ?",
                           (db.format_ts(world.clock()), d2["message_id"]))
    db.delete_meta(world.conn, sender.META_NEXT_SEND)
    assert await world.daemon.outreach.sender.tick() is None
    caps = [p for t, p in world.events if t == "cap_reached"]
    assert caps and caps[-1].cap.value == "outreach_daily" and caps[-1].limit == 1
    assert threads.get_message(world.conn, d2["message_id"]).send_at.astimezone().date() > world.clock().date()


async def test_suppression_at_send_time_cancels(world: World):
    _app, _thread, mid = await world.drafted_and_approved()
    suppression.add(world.conn, email="jane@acme.com", reason=SuppressionReason.USER)  # added behind the sender's back
    res = await world.daemon.outreach.sender.tick()
    assert res.state is MessageState.CANCELLED and FakeSMTP.instances == []


async def test_suppress_command_cancels_and_opt_out_is_permanent(world: World):
    _app, _thread, mid = await world.drafted_and_approved()
    await world.ok("suppress", {"domain": "acme.com", "reason": "user"})
    assert _state(world.conn, mid) is MessageState.CANCELLED
    await world.ok("unsuppress", {"domain": "acme.com"})
    await world.ok("suppress", {"email": "jane@acme.com", "reason": "opt_out"})
    r = await world.cmd("unsuppress", {"email": "jane@acme.com"})
    assert r["type"] == "error" and r["code"] == "conflict"


async def test_cancel_and_discard(world: World):
    _app, thread_id, mid = await world.drafted_and_approved()
    assert (await world.ok("cancel_outreach", {"message_ids": [mid]})) == {"cancelled": 1}
    assert _state(world.conn, mid) is MessageState.DRAFT
    await world.ok("discard_outreach", {"thread_id": thread_id})
    assert threads.get_thread(world.conn, thread_id).state is ThreadState.CANCELLED


# ---- follow-ups and the mail watcher -------------------------------------------------------------


async def _send_first(world: World, *, include_followups: bool = False) -> tuple[int, int, int, str]:
    app_id, thread_id, mid = await world.drafted_and_approved(include_followups=include_followups)
    await world.daemon.outreach.sender.tick()
    m = threads.get_message(world.conn, mid)
    return app_id, thread_id, mid, str(m.message_id_header)


async def test_followup_drafted_then_reply_cancels_it_and_blocks_ghosting(world: World):
    app_id, thread_id, _mid, sent_mid = await _send_first(world)
    world.clock.advance(days=8)
    await world.daemon.outreach.maintenance(world.clock())
    follow = [m for m in threads.messages(world.conn, thread_id, direction="out") if m.seq == 1]
    assert len(follow) == 1 and follow[0].state is MessageState.DRAFT  # not pre-approved: waits for the user
    assert follow[0].subject == f"Re: {GOOD_DRAFT['subject']}" and follow[0].in_reply_to == sent_mid
    # A second maintenance pass never makes a second follow-up.
    await world.daemon.outreach.maintenance(world.clock())
    assert len([m for m in threads.messages(world.conn, thread_id, direction="out") if m.seq >= 1]) == 1
    world.mailbox.folders["INBOX"].append(eml("reply_positive.eml", **{"<orig-1@gmail.com>": sent_mid}))
    rep = await world.daemon.outreach.scan_mail()
    assert rep is not None and rep.replies == 1
    t = threads.get_thread(world.conn, thread_id)
    assert t.state is ThreadState.REPLIED and t.unread_reply
    assert threads.get_message(world.conn, follow[0].id).state is MessageState.CANCELLED
    replies = [p for typ, p in world.events if typ == "outreach_reply"]
    assert replies and replies[-1].contact_name == "Jane Doe" and replies[-1].company == "Acme"
    assert contacts.get_contact(world.conn, t.contact_id).email_status is EmailStatus.REPLIED
    # Replied threads keep the application off the auto-ghost path.
    assert db.ghost_stale_applications(world.conn, 1, db.utcnow() + timedelta(days=60)) == []
    assert db.get_application(world.conn, app_id).status is BoardStatus.APPLIED
    # Scanning again records nothing new.
    assert (await world.daemon.outreach.scan_mail()).replies == 0
    await world.ok("mark_reply_read", {"thread_id": thread_id})
    assert db.compute_counts(world.conn).outreach_replies_unread == 0
    # The IMAP side was read-only.
    assert all("STORE" not in s.upper() for s in world.mailbox.searches)


async def test_preapproved_followup_is_scheduled(world: World):
    _app, thread_id, _mid, _ = await _send_first(world, include_followups=True)
    world.clock.advance(days=8)
    await world.daemon.outreach.maintenance(world.clock())
    [follow] = [m for m in threads.messages(world.conn, thread_id, direction="out") if m.seq == 1]
    assert follow.state is MessageState.SCHEDULED


async def test_opt_out_reply_lists_the_address(world: World):
    _app, thread_id, _mid, sent_mid = await _send_first(world)
    world.mailbox.folders["INBOX"].append(eml("reply_optout.eml", **{"<orig-1@gmail.com>": sent_mid}))
    await world.daemon.outreach.scan_mail()
    assert threads.get_thread(world.conn, thread_id).state is ThreadState.OPTED_OUT
    assert suppression.check(world.conn, "jane@acme.com") is SuppressionReason.OPT_OUT


async def test_auto_reply_is_not_a_reply(world: World):
    _app, thread_id, _mid, sent_mid = await _send_first(world)
    world.mailbox.folders["INBOX"].append(eml("auto_reply.eml", **{"<orig-1@gmail.com>": sent_mid}))
    rep = await world.daemon.outreach.scan_mail()
    assert rep.ooo == 1 and rep.replies == 0
    assert threads.get_thread(world.conn, thread_id).state is ThreadState.ACTIVE


async def test_hard_bounce(world: World):
    _app, thread_id, _mid, sent_mid = await _send_first(world)
    world.mailbox.folders["INBOX"].append(eml("bounce_gmail_511.eml", **{"<orig-1@gmail.com>": sent_mid,
                                                                         "priya.shah@acme.com": "jane@acme.com"}))
    world.mailbox.folders["INBOX"].append(eml("bounce_delay_4xx.eml"))
    rep = await world.daemon.outreach.scan_mail()
    assert rep.bounces == 1
    t = threads.get_thread(world.conn, thread_id)
    assert t.state is ThreadState.BOUNCED
    c = contacts.get_contact(world.conn, t.contact_id)
    assert c.email_status is EmailStatus.BOUNCED and c.email_confidence == 0
    assert suppression.check(world.conn, "jane@acme.com") is SuppressionReason.HARD_BOUNCE


async def test_linkedin_acceptance_email_moves_referral(world: World):
    world.seed()
    co = db.get_company_by_name(world.conn, "Acme")
    r = await world.ok("add_referral", {"company_id": co.id, "person_name": "Jane Doe", "basis": "alumni", "basis_detail": "IIT Madras"})
    await world.ok("update_referral", {"id": r["referral_id"], "state": "requested"})
    world.mailbox.folders["INBOX"].append(eml("linkedin_accepted.eml"))
    await world.daemon.outreach.scan_mail()
    from autoapply.outreach import referrals

    assert referrals.get(world.conn, r["referral_id"]).state is ReferralState.CONNECTED
    bad = await world.cmd("update_referral", {"id": r["referral_id"], "state": "referred"})
    assert bad["type"] == "error" and bad["code"] == "illegal_transition"


# ---- auto-scout after a submit ---------------------------------------------------------------------


@respx.mock
async def test_mark_applied_auto_scouts_and_drafts(world: World, monkeypatch: pytest.MonkeyPatch):
    from autoapply.enums import AppState, Ats
    from autoapply.outreach import service

    monkeypatch.setattr(service, "AUTO_ENABLED", True)
    respx.get("https://globex.com/").respond(200, html=fixture("home.html").replace("Acme", "Globex"))
    respx.get("https://globex.com/team").respond(200, html=fixture("team.html").replace("acme.com", "globex.com").replace("Acme", "Globex"))
    respx.get(url__regex=r"https://globex\.com/.*").respond(404)
    respx.get(url__regex=r"https://api\.github\.com/.*").respond(404)
    world.llm.add_rule(r"PAGE TEXT", {"people": [{"name": "Ananya Iyer", "title": "Talent Acquisition Lead"}]})
    world.llm.add_rule(r"Rate 0-100", {"items": [{"i": 0, "role_fit": 90}]})
    seed_profile(world.conn)
    connect_mailbox(world.conn)
    co = db.upsert_company(world.conn, "Globex", domain="globex.com")
    job, _ = db.insert_job(world.conn, company_id=co.id, source="greenhouse", title="Backend Engineer",
                           apply_url="https://boards.greenhouse.io/globex/jobs/2", ats=Ats.GREENHOUSE, description="Go")
    app = db.get_application_by_job(world.conn, job.id)
    db.transition(world.conn, app.id, AppState.SCORED)
    await world.ok("mark_applied", {"application_id": app.id})
    await world.drain()
    finished = [p for t, p in world.events if t == "scout_finished"]
    assert finished and finished[-1].company_id == co.id and finished[-1].with_email >= 3
    assert finished[-1].thread_id is not None
    thread = threads.get_thread(world.conn, finished[-1].thread_id)
    assert thread.application_id == app.id and thread.state is ThreadState.DRAFT
    assert db.compute_counts(world.conn).outreach_drafts == 1
    # A second submit at the same company within 30 days reuses the scout.
    calls = len(respx.calls)
    world.daemon.outreach.on_submitted(app.id)
    await world.drain()
    assert len(respx.calls) == calls


# ---- contacts / import / provider keys ----------------------------------------------------------------


async def test_contact_commands_and_csv_import(world: World, tmp_path: Path):
    res = await world.ok("add_contact", {"company_name": "Acme", "full_name": "Jane Doe", "email": "Jane@Acme.com", "title": "Recruiter"})
    c = contacts.get_contact(world.conn, res["contact_id"])
    assert c.email_norm == "jane@acme.com" and c.email_confidence == 100 and not c.share_ok
    await world.ok("update_contact", {"id": c.id, "notes": "met at PyCon", "title": None})
    c = contacts.get_contact(world.conn, c.id)
    assert c.notes == "met at PyCon" and c.title is None
    csv_path = tmp_path / "c.csv"
    csv_path.write_text("name,email,company,title,linkedin_url,notes\nJane Doe,jane@acme.com,Acme,,,\n"
                        "Ravi Kumar,ravi@globex.com,Globex,EM,,\n,nobody@x.com,,,,\nBad,not-an-email,,,,\n")
    assert await world.ok("import_contacts", {"file_path": str(csv_path)}) == {"added": 1, "merged": 1, "skipped": 2}
    await world.ok("delete_contact", {"id": c.id, "suppress": True})
    assert suppression.check(world.conn, "jane@acme.com") is SuppressionReason.USER


@respx.mock
async def test_set_provider_key_checks_then_stores(world: World, monkeypatch: pytest.MonkeyPatch):
    from autoapply.outreach.providers import base

    stored: dict[str, str] = {}
    monkeypatch.setattr(base, "keychain_set", lambda p, k: stored.__setitem__(p, k))
    monkeypatch.setattr(base, "keychain_delete", lambda p: stored.pop(p, None))
    respx.get("https://api.hunter.io/v2/account").mock(side_effect=lambda req: httpx.Response(
        200 if req.url.params["api_key"] == "good" else 401, json={"data": {}}))
    bad = await world.cmd("set_provider_key", {"provider": "hunter", "api_key": "bad"})
    assert bad["type"] == "error" and stored == {}
    assert await world.ok("set_provider_key", {"provider": "hunter", "api_key": "good"}) == {"provider": "hunter", "ok": True}
    assert stored == {"hunter": "good"}
    await world.ok("set_provider_key", {"provider": "hunter", "api_key": None})
    assert stored == {}


# ---- Google work: referrers and company search, never LinkedIn itself -----------------------------------


class _Page:
    def __init__(self, routes: dict[str, str]) -> None:
        self.routes, self._url, self.visited = routes, "about:blank", []

    @property
    def url(self) -> str:
        return self._url

    async def goto(self, url: str) -> None:
        self.visited.append(url)
        self._url = url

    async def content(self) -> str:
        for needle, html in self.routes.items():
            if needle in self._url:
                return html
        return "<html></html>"

    async def scroll(self, pixels: int) -> None:
        pass

    async def close(self) -> None:
        pass


def _browser(page: _Page):
    class B:
        async def new_page(self):
            return page

        async def close(self):
            pass

    async def factory():
        return B()

    return factory


async def test_referrers_from_google_results_only(world: World):
    world.seed()
    co = db.get_company_by_name(world.conn, "Acme")
    page = _Page({"google.com/search": fixture("google_people.html")})
    world.daemon.outreach._browser_factory = _browser(page)
    assert (await world.ok("suggest_referrers", {"company_id": co.id})) == {"queued_google": True, "connections": 0}
    done = await world.daemon.outreach.run_google_work()
    assert done["referrers"] == 1
    from autoapply.outreach import referrals

    found = referrals.list_for_company(world.conn, co.id)
    assert {r.person_name for r in found} == {"Jane Doe"}
    assert found[0].linkedin_url == "https://in.linkedin.com/in/jane-doe-12345"  # stored, never opened
    assert page.visited and all(u.startswith("https://www.google.com/search") for u in page.visited)
    world.llm.add_rule(r"connection note", {"note": "Hi Jane, we both studied at IIT Madras. I'd like to connect."})
    texts = await world.ok("draft_referral", {"id": found[0].id})
    assert len(texts["connect_note"]) <= 300 and texts["referral_dm"]


@respx.mock
async def test_company_search_keeps_only_companies_on_the_page(world: World):
    seed_profile(world.conn)
    page = _Page({"google.com/search": '<div><a href="https://news.example.com/fintech-list"><h3>Top fintech startups</h3></a>'
                                       '<span>list</span></div>'})
    world.daemon.outreach._browser_factory = _browser(page)
    respx.get("https://news.example.com/fintech-list").respond(200, html="<p>Paybox builds UPI rails for merchants. "
                                                                          "Ledgerly does lending.</p>")
    respx.get("https://paybox.in/").respond(200, html='<meta name="description" content="UPI rails for merchants.">')
    world.llm.add_rule(r"Google queries", {"queries": ["fintech startups bangalore"]})
    world.llm.add_rule(r"List the companies", {"companies": [
        {"company": "Paybox", "url": "https://paybox.in", "evidence_quote": "Paybox builds UPI rails for merchants"},
        {"company": "Imaginary Corp", "url": "https://imaginary.example"}]})
    world.llm.add_rule(r"how good a target", {"score": 77, "summary": "payments + Go"})
    res = await world.ok("search_prospects", {"query": "fintech", "location": "Bangalore"})
    assert res["search_id"]
    done = await world.daemon.outreach.run_google_work()
    assert done["searches"] == 1
    rows = world.conn.execute("SELECT c.name, p.fit_score, p.summary FROM prospects p JOIN companies c ON c.id = p.company_id").fetchall()
    assert [(r[0], r[1], r[2]) for r in rows] == [("Paybox", 77, "UPI rails for merchants.")]
