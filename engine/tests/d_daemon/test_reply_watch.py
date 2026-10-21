"""Employer reply reading (mail/replywatch.py): matching emails to submitted applications,
phrase-rule classification with a model fallback, dedupe, suggestions the user accepts or
dismisses, "heard back" stopping auto-ghost, and pause. Fake IMAP + FakeLLMProvider only."""

from __future__ import annotations

import email
from datetime import timedelta
from email.message import Message
from email.utils import format_datetime
from pathlib import Path
from typing import Any

import pytest

from autoapply import db
from autoapply.enums import AppState, ApplicationReplyLabel as L, Ats, BoardStatus, EmailStatus
from autoapply.llm.provider import FakeLLMProvider
from autoapply.mail import replywatch
from autoapply.mail.replywatch import Candidate, classify_rules, match
from autoapply.models import utcnow
from autoapply.notify import Notifier
from autoapply.outreach import contacts
from tests.d_daemon.test_outreach import World
from tests.outreach_fakes import FakeMailbox, connect_mailbox, seed_profile, seed_submitted_application

FIX = Path(__file__).resolve().parent.parent / "fixtures" / "replies"


def reply_eml(name: str, *, hours: float = 1, **replace: str) -> Message:
    text = (FIX / name).read_text(encoding="utf-8").replace("{DATE}", format_datetime(utcnow() + timedelta(hours=hours)))
    for k, v in replace.items():
        text = text.replace(k, v)
    return email.message_from_string(text)


def submit(conn, company_id: int, title: str) -> int:
    job, _ = db.insert_job(conn, company_id=company_id, source="greenhouse", title=title, ats=Ats.GREENHOUSE,
                           apply_url=f"https://boards.greenhouse.io/acme/jobs/{title.replace(' ', '')}")
    app = db.get_application_by_job(conn, job.id)
    for s in (AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.SUBMITTING, AppState.SUBMITTED):
        db.transition(conn, app.id, s)
    return app.id


# ---- pure: classification rules -----------------------------------------------------------------


def _body(name: str) -> tuple[str, str]:
    msg = reply_eml(name)
    from autoapply.mail.common import _text
    from autoapply.outreach.mailwatch import header, reply_text

    return header(msg, "Subject"), reply_text(_text(msg))


@pytest.mark.parametrize(("name", "label"), [
    ("greenhouse_rejection.eml", L.REJECTION), ("workday_interview.eml", L.INTERVIEW_INVITE),
    ("hackerrank_assessment.eml", L.ASSESSMENT), ("offer.eml", L.OFFER), ("ack.eml", L.RECEIVED_ACK),
    ("unsure.eml", None),
])
def test_fixture_classification(name, label):
    assert classify_rules(*_body(name)) is label


@pytest.mark.parametrize(("text", "label"), [
    ("We will not be moving forward with your application.", L.REJECTION),
    ("Thanks for applying! Unfortunately we are not able to move forward.", L.REJECTION),
    ("We regret to inform you that the position has been filled.", L.REJECTION),
    ("We'd be pleased to offer you an interview next week — book a time here", L.INTERVIEW_INVITE),
    ("Please complete the take-home assignment by Friday.", L.ASSESSMENT),
    ("Your Codility test is ready", L.ASSESSMENT),
    ("Could you share your availability for a recruiter call?", L.INTERVIEW_INVITE),
    ("Thank you for applying. Unfortunately…", None),  # ack + weak rejection: unsure
    ("Next steps to follow.", None),                    # weak only
    ("Weekly jobs digest: 20 new roles", None),
    ("We are not moving forward, but we'd like to schedule a call about another role", None),  # conflict
])
def test_phrase_rules(text, label):
    assert classify_rules("", text) is label


async def test_model_fallback_only_when_unsure():
    llm = FakeLLMProvider(default={"label": "rejection"})
    label, by, tin, tout = await replywatch.classify(llm, *_body("unsure.eml"))
    assert (label, by) == (L.REJECTION, "model") and tin > 0 and tout > 0
    assert llm.tiers == ["fast"] and "untrusted" in (llm.calls[0].system or "")
    label, by, *_ = await replywatch.classify(llm, *_body("offer.eml"))
    assert (label, by) == (L.OFFER, "rules") and len(llm.calls) == 1
    assert (await replywatch.classify(None, *_body("unsure.eml")))[:2] == (L.OTHER, "rules")
    assert (await replywatch.classify(FakeLLMProvider(default=RuntimeError("down")), *_body("unsure.eml")))[0] is L.OTHER


# ---- pure: matching -----------------------------------------------------------------------------


def cand(app_id: int, company: str, title: str, domain: str | None, days_ago: float = 3) -> Candidate:
    return Candidate(app_id, app_id, hash(company) % 1000, company, domain, title, utcnow() - timedelta(days=days_ago), BoardStatus.APPLIED)


NOW = utcnow()


def test_match_by_company_domain():
    cs = [cand(1, "Acme", "Backend Engineer", "acme.com"), cand(2, "Globex", "SRE", "globex.io")]
    m = match("talent@mail.acme.com", "", "Hello", "", NOW, cs)
    assert m and m.candidate.application_id == 1 and m.basis == "domain" and not m.ambiguous
    assert match("someone@other.com", "", "Acme", "Acme", NOW, cs) is None  # unknown sender, no ATS


def test_match_by_ats_sender_needs_company_name():
    cs = [cand(1, "Acme", "Backend Engineer", "acme.com"), cand(2, "Globex", "SRE", "globex.io")]
    m = match("no-reply@us.greenhouse-mail.io", "", "Your application to Globex", "", NOW, cs)
    assert m and m.candidate.application_id == 2 and m.basis == "ats"
    assert match("no-reply@us.greenhouse-mail.io", "", "Your application", "Thanks!", NOW, cs) is None
    # Workday: company in the sender address; body mention also counts.
    assert match("acme@myworkday.com", "", "Next steps", "", NOW, cs).candidate.application_id == 1
    assert match("no-reply@ashbyhq.com", "", "Update", "Thanks for your interest in Globex.", NOW, cs).candidate.application_id == 2
    # Two companies named and no title to tell them apart: no match.
    assert match("no-reply@lever.co", "", "Acme and Globex", "", NOW, cs) is None


def test_match_only_after_submission():
    cs = [cand(1, "Acme", "Backend Engineer", "acme.com", days_ago=1)]
    assert match("hr@acme.com", "", "x", "", NOW - timedelta(days=2), cs) is None


def test_match_title_picks_among_applications_at_one_company():
    cs = [cand(1, "Acme", "Backend Engineer", "acme.com", days_ago=5), cand(2, "Acme", "Data Engineer (Platform)", "acme.com", days_ago=2)]
    m = match("hr@acme.com", "", "Your Backend Engineer application", "", NOW, cs)
    assert m.candidate.application_id == 1 and not m.ambiguous
    m = match("hr@acme.com", "", "Update", "About the Data Engineer role…", NOW, cs)
    assert m.candidate.application_id == 2 and not m.ambiguous
    m = match("hr@acme.com", "", "Update on your application", "", NOW, cs)
    assert m.candidate.application_id == 2 and m.ambiguous  # most recent, flagged


def test_search_criteria_bounded():
    spec = replywatch.WatchSpec(NOW.date(), [f"d{i}.com" for i in range(23)])
    crit = replywatch.search_criteria(spec)
    assert len(crit) == 3 and all("SINCE" in c for c in crit) and crit[0].count("FROM") == replywatch.SEARCH_CHUNK


# ---- through the daemon -------------------------------------------------------------------------


@pytest.fixture
async def world(autoapply_home):
    w = World(autoapply_home, llm=FakeLLMProvider(default={"label": "other"}))
    seed_profile(w.conn)
    connect_mailbox(w.conn)
    try:
        yield w
    finally:
        await w.daemon.stop()


def replies(w: World) -> list[Any]:
    return [p for t, p in w.events if t == "application_reply"]


async def scan(w: World):
    return await w.daemon.replywatch.scan()


async def test_scan_records_and_suggests(world: World):
    _co, job_id, app_id = seed_submitted_application(world.conn)
    world.mailbox.folders["INBOX"] += [reply_eml("workday_interview.eml"), reply_eml("ack.eml", hours=0.5)]
    rep = await scan(world)
    assert rep.recorded == 2
    by_label = {p.label: p for p in replies(world)}
    p = by_label[L.INTERVIEW_INVITE]
    assert (p.application_id, p.job_id, p.company, p.suggested_status) == (app_id, job_id, "Acme", BoardStatus.INTERVIEW)
    assert p.from_email == "acme@myworkday.com" and p.message_id == "<wd-interview-1@myworkday.com>"
    assert "phone screen" in p.snippet and p.subject == "Next steps for Backend Engineer"
    assert by_label[L.RECEIVED_ACK].suggested_status is None
    # Never changes the board by itself.
    assert db.get_application(world.conn, app_id).status is BoardStatus.APPLIED
    # Unread rows (the acknowledgement) plus pending suggestions (the invite), each once.
    assert db.compute_counts(world.conn).application_replies_unread == 2
    assert replywatch.gmail_link(p.message_id).endswith("#search/rfc822msgid%3Awd-interview-1%40myworkday.com")


async def test_fixtures_end_to_end_and_model_tokens(world: World):
    _co, _job, app_id = seed_submitted_application(world.conn)
    world.llm.default = {"label": "rejection"}
    for n in ("greenhouse_rejection.eml", "hackerrank_assessment.eml", "offer.eml", "unsure.eml"):
        world.mailbox.folders["INBOX"].append(reply_eml(n))
    await scan(world)
    rows = {r.message_id: r for r in db.list_application_replies(world.conn, app_id)}
    assert rows["<gh-reject-1@us.greenhouse-mail.io>"].label is L.REJECTION
    assert rows["<gh-reject-1@us.greenhouse-mail.io>"].match_basis == "ats"
    assert rows["<acme-hr-1@acme.com>"].suggested_status is BoardStatus.ASSESSMENT
    assert rows["<acme-offer-1@acme.com>"].suggested_status is BoardStatus.OFFER
    unsure = rows["<acme-unsure-1@acme.com>"]
    assert unsure.classified_by == "model" and unsure.label is L.REJECTION and unsure.tokens_in > 0
    assert db.get_application(world.conn, app_id).tokens_in == unsure.tokens_in
    assert len(world.llm.calls) == 1  # rules decided the other three


async def test_ambiguous_match_suggests_nothing(world: World):
    co_id, _job, first = seed_submitted_application(world.conn)
    second = submit(world.conn, co_id, "Data Engineer")
    world.mailbox.folders["INBOX"].append(reply_eml("greenhouse_rejection.eml", **{"Backend Engineer position": "position"}))
    await scan(world)
    (p,) = replies(world)
    assert p.application_id == second and p.ambiguous and p.suggested_status is None and p.label is L.REJECTION
    # With the title in it, the right application gets the suggestion.
    world.mailbox.folders["INBOX"].append(reply_eml("workday_interview.eml"))
    await scan(world)
    assert replies(world)[-1].application_id == first and replies(world)[-1].suggested_status is BoardStatus.INTERVIEW


async def test_dedupe_by_message_id(world: World):
    seed_submitted_application(world.conn)
    world.mailbox.folders["INBOX"] += [reply_eml("offer.eml"), reply_eml("offer.eml")]
    assert (await scan(world)).recorded == 1
    assert (await scan(world)).recorded == 0
    assert len(replies(world)) == 1
    assert world.conn.execute("SELECT COUNT(*) FROM application_replies").fetchone()[0] == 1


async def test_unrelated_and_outreach_mail_ignored(world: World):
    co_id, _job, app_id = seed_submitted_application(world.conn)
    contacts.upsert_contact(world.conn, company_id=co_id, full_name="Jane Doe", origin="user", email="jane.doe@acme.com",
                            email_status=EmailStatus.USER, title="Recruiter")
    world.conn.execute("INSERT INTO outreach_threads(company_id, contact_id, application_id, kind, state) "
                       "SELECT ?, id, ?, 'application', 'active' FROM contacts", (co_id, app_id))
    world.mailbox.folders["INBOX"] += [reply_eml("offer.eml"),  # from the outreach contact: outreach's
                                       reply_eml("ack.eml", **{"Acme": "Initech"})]  # another company
    rep = await scan(world)
    assert rep.recorded == 0 and rep.skipped_outreach == 1 and rep.unmatched == 1


async def test_reply_stops_auto_ghost_and_nudges(world: World):
    _co, _job, replied = seed_submitted_application(world.conn)
    _co2, _job2, silent = seed_submitted_application(world.conn, company="Globex", domain="globex.io")
    world.mailbox.folders["INBOX"].append(reply_eml("ack.eml"))
    await scan(world)
    assert db.heard_back_at(world.conn, replied) is not None and db.heard_back_at(world.conn, silent) is None
    later = utcnow() + timedelta(days=60)
    assert [a.id for a, _day in db.due_nudges(world.conn, [7], later)] == [silent]
    ghosted = db.ghost_stale_applications(world.conn, 21, later)
    assert [p.application_id for p in ghosted] == [silent]
    assert db.get_application(world.conn, replied).status is BoardStatus.APPLIED


async def test_accept_and_dismiss(world: World):
    _co, _job, app_id = seed_submitted_application(world.conn)
    world.mailbox.folders["INBOX"] += [reply_eml("workday_interview.eml"), reply_eml("hackerrank_assessment.eml")]
    await scan(world)
    ids = {p.label: p.reply_id for p in replies(world)}
    res = await world.ok("accept_reply_suggestion", {"reply_id": ids[L.INTERVIEW_INVITE]})
    assert res == {"reply_id": ids[L.INTERVIEW_INVITE], "application_id": app_id, "status": "interview"}
    assert db.get_application(world.conn, app_id).status is BoardStatus.INTERVIEW
    status_events = [p for t, p in world.events if t == "application_status"]
    assert status_events[-1].status is BoardStatus.INTERVIEW and status_events[-1].actor.value == "user"
    again = await world.cmd("accept_reply_suggestion", {"reply_id": ids[L.INTERVIEW_INVITE]})
    assert again["type"] == "error" and again["code"] == "conflict"
    await world.ok("dismiss_reply_suggestion", {"reply_id": ids[L.ASSESSMENT]})
    await world.ok("dismiss_reply_suggestion", {"reply_id": ids[L.ASSESSMENT]})  # idempotent
    assert db.get_application_reply(world.conn, ids[L.ASSESSMENT]).suggestion_state == "dismissed"
    assert db.get_application(world.conn, app_id).status is BoardStatus.INTERVIEW
    assert db.compute_counts(world.conn).application_replies_unread == 0
    assert (await world.cmd("accept_reply_suggestion", {"reply_id": 999}))["code"] == "not_found"


async def test_read_flag_and_unread_count(world: World):
    _co, _job, _app_id = seed_submitted_application(world.conn)
    world.mailbox.folders["INBOX"] += [reply_eml("workday_interview.eml"), reply_eml("ack.eml", hours=0.5)]
    await scan(world)
    ids = {p.label: p.reply_id for p in replies(world)}
    assert all(r.read_at is None for r in db.list_application_replies(world.conn))
    assert db.compute_counts(world.conn).application_replies_unread == 2
    # Reading the acknowledgement clears it; reading is idempotent and keeps the first time.
    assert await world.ok("mark_application_reply_read", {"reply_id": ids[L.RECEIVED_ACK]}) is None
    first = db.get_application_reply(world.conn, ids[L.RECEIVED_ACK]).read_at
    await world.ok("mark_application_reply_read", {"reply_id": ids[L.RECEIVED_ACK]})
    assert first is not None and db.get_application_reply(world.conn, ids[L.RECEIVED_ACK]).read_at == first
    assert db.compute_counts(world.conn).application_replies_unread == 1
    # A read reply with a pending suggestion still counts until it is accepted or dismissed.
    await world.ok("mark_application_reply_read", {"reply_id": ids[L.INTERVIEW_INVITE]})
    invite = db.get_application_reply(world.conn, ids[L.INTERVIEW_INVITE])
    assert invite.read_at is not None and invite.suggestion_state == "pending"
    assert db.compute_counts(world.conn).application_replies_unread == 1
    await world.ok("dismiss_reply_suggestion", {"reply_id": ids[L.INTERVIEW_INVITE]})
    assert db.compute_counts(world.conn).application_replies_unread == 0
    assert (await world.cmd("mark_application_reply_read", {"reply_id": 999}))["code"] == "not_found"


async def test_deciding_a_suggestion_marks_the_reply_read(world: World):
    seed_submitted_application(world.conn)
    world.mailbox.folders["INBOX"].append(reply_eml("workday_interview.eml"))
    await scan(world)
    [p] = replies(world)
    await world.ok("accept_reply_suggestion", {"reply_id": p.reply_id})
    assert db.get_application_reply(world.conn, p.reply_id).read_at is not None
    assert db.compute_counts(world.conn).application_replies_unread == 0


async def test_pause_and_no_mailbox(world: World):
    seed_submitted_application(world.conn)
    world.mailbox.folders["INBOX"].append(reply_eml("offer.eml"))
    world.daemon.paused = True
    assert await world.daemon.replywatch.tick() is None and await scan(world) is None
    assert world.mailbox.searches == []
    world.daemon.paused = False
    from autoapply.mail import imap_codes

    db.set_meta(world.conn, imap_codes.META_KEY, None)
    assert await scan(world) is None and world.mailbox.searches == []
    connect_mailbox(world.conn)
    assert (await world.daemon.replywatch.tick()).recorded == 1
    assert await world.daemon.replywatch.tick() is None  # next scan only after SCAN_EVERY_S
    world.clock.advance(seconds=replywatch.SCAN_EVERY_S)
    assert (await world.daemon.replywatch.tick()).recorded == 0


async def test_scan_is_bounded(world: World):
    seed_submitted_application(world.conn)
    for i in range(replywatch.MAX_MESSAGES + 20):
        world.mailbox.folders["INBOX"].append(reply_eml("ack.eml", **{"ashby-ack-1": f"ashby-ack-{i}"}))
    rep = await scan(world)
    assert rep.looked_at == replywatch.MAX_MESSAGES


async def test_notification_text():
    sent: list[tuple[str, str]] = []

    async def send(title: str, message: str) -> None:
        sent.append((title, message))

    n = Notifier(send)
    base = {"reply_id": 1, "application_id": 1, "job_id": 1, "company": "Acme", "from_email": "a@acme.com",
            "subject": "Next steps", "snippet": "", "received_at": "2026-10-10T09:00:00.000Z", "message_id": "<x@y>"}
    await n.on_event("application_reply", {**base, "label": "interview_invite"})
    await n.on_event("application_reply", {**base, "label": "received_ack"})
    assert sent == [("Acme replied: interview invite", "Next steps")]
