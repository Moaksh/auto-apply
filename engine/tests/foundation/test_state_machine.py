from __future__ import annotations

import itertools
import json

import pytest

from autoapply import db
from autoapply.enums import Actor, AppState, BoardStatus
from autoapply.models import ALLOWED_TRANSITIONS, USER_ONLY_TRANSITIONS, is_allowed_transition

S = AppState


def make_app(conn, title="Backend Engineer", company="Stripe"):
    co = db.upsert_company(conn, company, ats="greenhouse", board_token=company.lower())
    job, created = db.insert_job(
        conn, company_id=co.id, source="greenhouse", ats="greenhouse", title=title, location="Remote",
        apply_url=f"https://boards.greenhouse.io/{company.lower()}/jobs/{db.normalize_text(title).replace(' ', '-')}",
    )
    assert created
    return db.get_application_by_job(conn, job.id)


def force_state(conn, app_id, state):
    """Test helper: put a row in an arbitrary state, bypassing the machine."""
    extra = ", submitted_at = '2026-01-01T00:00:00.000Z'" if state == "submitted" else ""
    conn.execute(f"UPDATE applications SET state = ?{extra} WHERE id = ?", (state, app_id))


def walk(conn, app_id, *states, actor=Actor.AGENT):
    for s in states:
        db.transition(conn, app_id, s, actor=actor)


def test_new_job_creates_discovered_application(conn):
    app = make_app(conn)
    assert app.state is S.DISCOVERED
    assert app.status is None


def test_happy_path_auto_mode(conn):
    app = make_app(conn)
    walk(conn, app.id, S.SCORED, S.QUEUED, S.PREPPING, S.QUEUED, S.FILLING)
    db.begin_submit(conn, app.id)
    t = db.complete_submit(conn, app.id, confirmation_screenshot_path="/tmp/confirm.png")
    assert t.from_state is S.SUBMITTING and t.to_state is S.SUBMITTED
    got = db.get_application(conn, app.id)
    assert got.state is S.SUBMITTED
    assert got.submitted_at is not None
    assert got.status is BoardStatus.APPLIED
    assert got.confirmation_screenshot_path == "/tmp/confirm.png"
    job = db.get_job(conn, app.job_id)
    assert db.get_company(conn, job.company_id).last_applied_at is not None


def test_review_mode_requires_user_approval(conn):
    app = make_app(conn)
    walk(conn, app.id, S.SCORED, S.QUEUED, S.FILLING, S.AWAITING_REVIEW)
    with pytest.raises(db.IllegalTransition, match="user-only"):
        db.begin_submit(conn, app.id)  # agent can't approve its own work
    db.begin_submit(conn, app.id, actor=Actor.USER)
    assert db.get_application(conn, app.id).state is S.SUBMITTING


def test_needs_you_round_trip(conn):
    app = make_app(conn)
    walk(conn, app.id, S.SCORED, S.QUEUED, S.PREPPING, S.NEEDS_YOU, S.QUEUED, S.FILLING, S.NEEDS_YOU, S.QUEUED)
    assert db.get_application(conn, app.id).state is S.QUEUED


ALL_PAIRS = list(itertools.product(list(S), list(S)))
ILLEGAL = [(f, t) for f, t in ALL_PAIRS if t not in ALLOWED_TRANSITIONS[f]]


@pytest.mark.parametrize(("frm", "to"), ILLEGAL, ids=[f"{f.value}->{t.value}" for f, t in ILLEGAL])
def test_illegal_transitions_rejected_for_every_actor(conn, frm, to):
    app = make_app(conn)
    force_state(conn, app.id, frm.value)
    for actor in Actor:
        with pytest.raises(db.IllegalTransition):
            db.transition(conn, app.id, to, actor=actor)
    assert db.get_application(conn, app.id).state is frm  # unchanged


@pytest.mark.parametrize(("frm", "to"), sorted(USER_ONLY_TRANSITIONS), ids=lambda p: getattr(p, "value", p))
def test_user_only_transitions(conn, frm, to):
    app = make_app(conn)
    force_state(conn, app.id, frm.value)
    for actor in (Actor.AGENT, Actor.SYSTEM):
        with pytest.raises(db.IllegalTransition, match="user-only"):
            db.transition(conn, app.id, to, actor=actor)
    db.transition(conn, app.id, to, actor=Actor.USER)
    assert db.get_application(conn, app.id).state is to


def test_is_allowed_transition_helper():
    assert is_allowed_transition("filling", "submitting")
    assert not is_allowed_transition("queued", "submitted")
    assert not is_allowed_transition("unknown_verify", "submitted", "agent")
    assert is_allowed_transition("unknown_verify", "submitted", "user")


def test_submitted_is_terminal(conn):
    app = make_app(conn)
    force_state(conn, app.id, "submitted")
    for to in S:
        with pytest.raises(db.IllegalTransition):
            db.transition(conn, app.id, to, actor=Actor.USER)


def test_expected_from_guard(conn):
    app = make_app(conn)
    walk(conn, app.id, S.SCORED, S.QUEUED)
    with pytest.raises(db.IllegalTransition, match="expected"):
        db.transition(conn, app.id, S.FILLING, expected_from=S.PREPPING)
    db.transition(conn, app.id, S.FILLING, expected_from=[S.QUEUED, S.PREPPING])


def test_begin_submit_only_from_filling_or_review(conn):
    app = make_app(conn)
    walk(conn, app.id, S.SCORED, S.QUEUED)
    with pytest.raises(db.IllegalTransition):
        db.begin_submit(conn, app.id)


def test_transition_writes_event_row_atomically(conn):
    app = make_app(conn)
    t = db.transition(conn, app.id, S.SKIPPED, reason="below_threshold")
    ev = db.list_events(conn, application_id=app.id, kinds=["state"])
    assert len(ev) == 1
    assert ev[0].payload == {"from": "discovered", "to": "skipped", "reason": "below_threshold"}
    assert db.get_application(conn, app.id).state_reason == "below_threshold"
    p = t.to_payload()
    assert p.from_state is S.DISCOVERED and p.to_state is S.SKIPPED and p.reason == "below_threshold"


def test_failed_transition_writes_nothing(conn):
    app = make_app(conn)
    before = len(db.list_events(conn, limit=1000))
    with pytest.raises(db.IllegalTransition):
        db.transition(conn, app.id, S.SUBMITTED)
    assert len(db.list_events(conn, limit=1000)) == before


def test_transition_inside_outer_transaction_rolls_back(conn):
    app = make_app(conn)
    with pytest.raises(RuntimeError), db.transaction(conn):
        db.transition(conn, app.id, S.SCORED)
        raise RuntimeError("boom")
    assert db.get_application(conn, app.id).state is S.DISCOVERED


def test_unknown_application_raises_not_found(conn):
    with pytest.raises(db.NotFound):
        db.transition(conn, 12345, S.SCORED)


# ---- crash recovery -------------------------------------------------------------------


def test_crash_during_submitting_becomes_unknown_verify(conn, autoapply_home):
    app = make_app(conn)
    walk(conn, app.id, S.SCORED, S.QUEUED, S.FILLING)
    db.begin_submit(conn, app.id)
    conn.close()  # simulate the daemon dying right after the pre-write

    conn2 = db.open_db(autoapply_home.db)
    try:
        assert db.get_application(conn2, app.id).state is S.SUBMITTING  # pre-write was durable
        report = db.recover_after_crash(conn2)
        assert [t.application_id for t in report.unknown_verify] == [app.id]
        got = db.get_application(conn2, app.id)
        assert got.state is S.UNKNOWN_VERIFY
        assert got.state_reason == "crash_during_submit"
        # never retried automatically: agent/system can't move it anywhere
        for to in S:
            for actor in (Actor.AGENT, Actor.SYSTEM):
                with pytest.raises(db.IllegalTransition):
                    db.transition(conn2, app.id, to, actor=actor)
        # recovery is idempotent
        assert db.recover_after_crash(conn2).unknown_verify == []
        # the user resolves it
        db.transition(conn2, app.id, S.SUBMITTED, actor=Actor.USER)
        assert db.get_application(conn2, app.id).status is BoardStatus.APPLIED
    finally:
        conn2.close()


def test_recovery_requeues_interrupted_prepping_and_filling(conn):
    a1 = make_app(conn, "A")
    a2 = make_app(conn, "B")
    a3 = make_app(conn, "C")
    walk(conn, a1.id, S.SCORED, S.QUEUED, S.PREPPING)
    walk(conn, a2.id, S.SCORED, S.QUEUED, S.FILLING)
    walk(conn, a3.id, S.SCORED, S.QUEUED, S.FILLING, S.SUBMITTING)
    report = db.recover_after_crash(conn)
    assert sorted(t.application_id for t in report.requeued) == sorted([a1.id, a2.id])
    assert [t.application_id for t in report.unknown_verify] == [a3.id]
    assert db.get_application(conn, a1.id).state is S.QUEUED
    assert db.get_application(conn, a2.id).state is S.QUEUED
    assert db.get_application(conn, a3.id).state is S.UNKNOWN_VERIFY
    rows = db.list_events(conn, application_id=a3.id, kinds=["state"])
    assert rows[-1].actor is Actor.SYSTEM


# ---- board status ---------------------------------------------------------------------


def test_set_status_requires_submitted(conn):
    app = make_app(conn)
    with pytest.raises(db.IllegalTransition):
        db.set_status(conn, app.id, "interview")


def test_set_status_flow_and_event(conn):
    app = make_app(conn)
    walk(conn, app.id, S.SCORED, S.QUEUED, S.FILLING, S.SUBMITTING, S.SUBMITTED)
    p = db.set_status(conn, app.id, BoardStatus.INTERVIEW)
    assert p.previous_status is BoardStatus.APPLIED and p.status is BoardStatus.INTERVIEW
    assert db.get_application(conn, app.id).status is BoardStatus.INTERVIEW
    ev = db.list_events(conn, application_id=app.id, kinds=["status"])[-1]
    assert ev.actor is Actor.USER and json.dumps(ev.payload) == json.dumps({"from": "applied", "to": "interview"})


def test_update_application_cannot_touch_state(conn):
    app = make_app(conn)
    with pytest.raises(ValueError):
        db.update_application(conn, app.id, state="submitted")
