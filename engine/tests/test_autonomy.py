"""Earned autonomy (autonomy.py): per-site Review track record, the threshold, the one-time
``autonomy_suggestion``, ``get_autonomy`` / ``dismiss_autonomy_suggestion`` and the Review default.

These tests run on a real fresh DB (no legacy Auto fixture): a new install starts in Review.
"""

from __future__ import annotations

import shutil
import sqlite3
import tempfile
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

from autoapply import autonomy, db
from autoapply.enums import Actor, AppState, Ats, Mode
from autoapply.models import make_command
from autoapply.paths import Paths

_n = 0


def _review_app(conn: sqlite3.Connection, ats: Ats = Ats.GREENHOUSE) -> int:
    global _n
    _n += 1
    co = db.upsert_company(conn, f"Co{_n}")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title=f"SWE {_n}",
                           apply_url=f"https://boards.greenhouse.io/co{_n}/jobs/{_n}", ats=ats)
    app = db.get_application_by_job(conn, job.id)
    for s in (AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.AWAITING_REVIEW):
        db.transition(conn, app.id, s)
    return app.id


def approve(conn: sqlite3.Connection, ats: Ats = Ats.GREENHOUSE, *, edited: bool = False) -> int:
    app_id = _review_app(conn, ats)
    if edited:
        aa = db.add_application_answer(conn, app_id, question="Why us?", answer="draft", origin="generated", confidence=0.8)
        db.edit_application_answer(conn, aa.id, "my words")
    db.begin_submit(conn, app_id, actor=Actor.USER)
    return app_id


def reject(conn: sqlite3.Connection, reason: str, ats: Ats = Ats.GREENHOUSE) -> int:
    app_id = _review_app(conn, ats)
    db.transition(conn, app_id, AppState.SKIPPED, reason=reason, actor=Actor.USER, expected_from=AppState.AWAITING_REVIEW)
    return app_id


def site(conn: sqlite3.Connection, ats: Ats = Ats.GREENHOUSE) -> Any:
    return next(s for s in autonomy.report(conn).sites if s.ats is ats)


# ---- default for a new install -------------------------------------------------------------


def test_new_install_starts_in_review(conn: sqlite3.Connection) -> None:
    prefs = db.get_preferences(conn)
    assert prefs.mode is Mode.REVIEW
    assert prefs.effective_mode(ats="greenhouse") is Mode.REVIEW


# ---- stats -----------------------------------------------------------------------------------


def test_stats_count_clean_and_edited_approvals_per_site(conn: sqlite3.Connection) -> None:
    for _ in range(3):
        approve(conn)
    approve(conn, edited=True)
    approve(conn)
    approve(conn, Ats.LEVER)
    reject(conn, "not_interested")  # about the job: neutral
    gh = site(conn)
    assert (gh.approved, gh.approved_without_edits, gh.edited, gh.rejected_wrong_answers) == (5, 4, 1, 0)
    assert gh.clean_approvals == 1 and gh.since is not None  # the edit reset the streak
    assert site(conn, Ats.LEVER).clean_approvals == 1
    assert site(conn, Ats.ASHBY).approved == 0
    assert {s.ats for s in autonomy.report(conn).sites} == set(Ats)


def test_agent_submits_and_inbox_answers_do_not_count(conn: sqlite3.Connection) -> None:
    app_id = _review_app(conn)
    # An answer typed in the Needs-You inbox has origin 'user' but is not a Review edit.
    db.add_application_answer(conn, app_id, question="Notice period?", answer="60 days", origin="user",
                              field_key="inbox:abc", confidence=1.0)
    db.begin_submit(conn, app_id, actor=Actor.USER)
    co = db.upsert_company(conn, "AutoCo")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="Auto SWE",
                           apply_url="https://boards.greenhouse.io/autoco/jobs/1", ats=Ats.GREENHOUSE)
    auto_app = db.get_application_by_job(conn, job.id).id
    for st in (AppState.SCORED, AppState.QUEUED, AppState.FILLING):
        db.transition(conn, auto_app, st)
    db.begin_submit(conn, auto_app)  # an Auto submit by the agent is not a review decision
    s = site(conn)
    assert (s.approved, s.approved_without_edits, s.clean_approvals) == (1, 1, 1)


def test_wrong_answers_reject_resets_the_streak(conn: sqlite3.Connection) -> None:
    for _ in range(12):
        approve(conn)
    assert site(conn).eligible
    reject(conn, "wrong_answers")
    s = site(conn)
    assert s.rejected_wrong_answers == 1 and s.clean_approvals == 0 and not s.eligible and s.suggestion == "none"


def test_edit_after_approval_does_not_taint_it(conn: sqlite3.Connection) -> None:
    app_id = approve(conn)
    aa = db.add_application_answer(conn, app_id, question="Q", answer="a", origin="generated")
    db.edit_application_answer(conn, aa.id, "b")  # later, unrelated to the decision
    assert site(conn).approved_without_edits == 1


# ---- threshold and suggestion state -------------------------------------------------------------


def test_threshold_is_ten_clean_approvals_in_a_row(conn: sqlite3.Connection) -> None:
    assert autonomy.THRESHOLD == 10
    for _ in range(9):
        approve(conn)
    assert not site(conn).eligible and autonomy.new_suggestions(conn) == []
    approve(conn)
    s = site(conn)
    assert s.eligible and s.clean_approvals == 10 and s.suggestion == "pending" and s.mode is Mode.REVIEW


def test_suggestion_is_emitted_once_per_site(conn: sqlite3.Connection) -> None:
    for _ in range(10):
        approve(conn)
    first = autonomy.new_suggestions(conn)
    assert [(p.ats, p.clean_approvals) for p in first] == [(Ats.GREENHOUSE, 10)]
    assert first[0].since == site(conn).since
    approve(conn)
    assert autonomy.new_suggestions(conn) == []
    s = site(conn)
    assert s.suggestion == "pending" and s.suggested_at is not None and s.clean_approvals == 11
    # A broken and re-earned streak is not announced again.
    approve(conn, edited=True)
    for _ in range(10):
        approve(conn)
    assert autonomy.new_suggestions(conn) == []


def test_no_suggestion_for_a_site_already_in_auto(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"per_ats_mode": {"greenhouse": "auto"}})
    for _ in range(10):
        approve(conn)
    s = site(conn)
    assert s.eligible and s.mode is Mode.AUTO and s.mode_source == "site" and s.suggestion == "none"
    assert autonomy.new_suggestions(conn) == []


def test_accepting_is_just_update_preferences(conn: sqlite3.Connection) -> None:
    for _ in range(10):
        approve(conn)
    autonomy.new_suggestions(conn)
    db.update_preferences(conn, {"per_ats_mode": {"greenhouse": "auto"}})
    assert site(conn).suggestion == "none" and site(conn).mode is Mode.AUTO
    # ...and the user can go back to Review at any time; nothing is re-announced.
    db.update_preferences(conn, {"per_ats_mode": {"greenhouse": "review"}})
    assert site(conn).suggestion == "pending" and autonomy.new_suggestions(conn) == []


def test_dismiss_stops_the_offer(conn: sqlite3.Connection) -> None:
    for _ in range(10):
        approve(conn)
    autonomy.dismiss(conn, Ats.GREENHOUSE)
    s = site(conn)
    assert s.suggestion == "dismissed" and s.dismissed_at is not None
    assert autonomy.new_suggestions(conn) == []
    autonomy.dismiss(conn, Ats.GREENHOUSE)  # idempotent
    assert site(conn).dismissed_at == s.dismissed_at
    # Dismissed before it was ever offered: never emitted later either.
    autonomy.dismiss(conn, Ats.LEVER)
    for _ in range(10):
        approve(conn, Ats.LEVER)
    assert autonomy.new_suggestions(conn) == []


# ---- daemon wiring --------------------------------------------------------------------------------


@pytest.fixture
def sock_dir() -> Iterator[Path]:
    d = tempfile.mkdtemp(prefix="aat", dir="/tmp")
    yield Path(d)
    shutil.rmtree(d, ignore_errors=True)


async def test_daemon_emits_on_approve_and_serves_commands(autoapply_home: Paths, sock_dir: Path) -> None:
    from tests.d_daemon.fakes import FakeAdapter
    from tests.d_daemon.test_daemon import build_daemon

    conn = db.open_db(autoapply_home.db)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=FakeAdapter(conn))
    sent: list[tuple[str, Any]] = []
    real = d.broadcast

    async def capture(event_type: str, payload: Any) -> None:
        sent.append((event_type, payload))
        await real(event_type, payload)

    d.broadcast = capture  # type: ignore[method-assign]
    try:
        db.update_preferences(conn, {"daily_cap": 100, "per_company_cooldown_days": 0})
        for _ in range(9):
            approve(conn)
        app_id = _review_app(conn)
        replies = await d.handle(make_command("approve", {"application_ids": [app_id]}))
        assert replies[0].type == "ack"
        suggested = [p for t, p in sent if t == "autonomy_suggestion"]
        assert len(suggested) == 1 and suggested[0].ats is Ats.GREENHOUSE and suggested[0].clean_approvals == 10

        app2 = _review_app(conn)
        await d.handle(make_command("approve", {"application_ids": [app2]}))
        assert len([t for t, _ in sent if t == "autonomy_suggestion"]) == 1  # once per site

        rep = (await d.handle(make_command("get_autonomy", {})))[0]
        gh = next(s for s in rep.payload["result"]["sites"] if s["ats"] == "greenhouse")
        assert rep.payload["result"]["threshold"] == 10
        assert gh["suggestion"] == "pending" and gh["clean_approvals"] == 11 and gh["mode"] == "review"

        ack = (await d.handle(make_command("dismiss_autonomy_suggestion", {"ats": "greenhouse"})))[0]
        assert ack.type == "ack" and ack.payload["result"] is None
        assert site(conn).suggestion == "dismissed"
        assert db.get_preferences(conn).per_ats_mode.get(Ats.GREENHOUSE) is None  # nothing changed by itself
    finally:
        await d.stop()
