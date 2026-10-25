"""Issue #4: approving from Review kept failing with ``cap_reached`` and no way out.

* a ``submitting`` row no live task owns no longer holds its company forever (it becomes
  ``unknown_verify`` the user can resolve);
* every company refusal carries what holds the company (kind, since, resets_at, the other
  application), in the gate, in ``review_sendability`` and in the ``approve`` error / reply;
* a batch with two jobs at one company sends the first and holds the other (``same_batch``)
  instead of refusing the whole batch.
"""

from __future__ import annotations

import asyncio
import shutil
import sqlite3
import tempfile
from collections.abc import Iterator
from datetime import timedelta
from pathlib import Path
from typing import Any

import pytest

from autoapply import db
from autoapply.enums import AppState, CapKind
from autoapply.models import make_command
from autoapply.paths import Paths
from autoapply.pipeline import STALE_SUBMIT_AFTER

from .fakes import FakeAdapter
from .test_daemon import _seed_app, build_daemon
from .test_guardrails import REVIEW_PATH, BlockingAdapter, _wait_for
from .test_pipeline import make_pipeline

SUBMITTED_PATH = [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.SUBMITTING, AppState.SUBMITTED]


@pytest.fixture
def sock_dir() -> Iterator[Path]:
    d = tempfile.mkdtemp(prefix="aah", dir="/tmp")
    yield Path(d)
    shutil.rmtree(d, ignore_errors=True)


def _age(conn: sqlite3.Connection, app_id: int, by: timedelta) -> None:
    """Pretend the application entered its current state ``by`` ago."""
    ts = db.format_ts(db.utcnow() - by)
    conn.execute("UPDATE applications SET state_updated_at = ? WHERE id = ?", (ts, app_id))


def _company_of(conn: sqlite3.Connection, app_id: int) -> int:
    return db.get_job(conn, db.get_application(conn, app_id).job_id).company_id


async def _cmd(d: Any, type_: str, payload: dict[str, Any]) -> dict[str, Any]:
    (reply,) = await d.handle(make_command(type_, payload))
    return reply.model_dump(mode="json")


# ---- stale submitting ----------------------------------------------------------------


async def test_orphaned_submitting_is_moved_to_unknown_verify(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    stale = _seed_app(conn, REVIEW_PATH, "Prodigal", "ML Engineer")
    fresh = _seed_app(conn, REVIEW_PATH, "Ramp", "Backend")
    owned = _seed_app(conn, REVIEW_PATH, "Notion", "Infra")
    for a in (stale, fresh, owned):
        db.begin_submit(conn, a, actor="user")
    _age(conn, stale, STALE_SUBMIT_AFTER + timedelta(minutes=1))
    _age(conn, owned, timedelta(hours=6))
    p, sink, _adapter, _ = make_pipeline(conn, autoapply_home, [])
    p.submits_in_flight.add(owned)  # an approved submit still waiting for the browser
    assert await p.expire_stale_submits() == [stale]
    assert db.get_application(conn, stale).state is AppState.UNKNOWN_VERIFY
    assert db.get_application(conn, stale).state_reason == "submit_stalled"
    assert db.get_application(conn, fresh).state is AppState.SUBMITTING
    assert db.get_application(conn, owned).state is AppState.SUBMITTING
    assert [t.to_state for t in sink.of("application_state")] == [AppState.UNKNOWN_VERIFY]


async def test_stale_submit_stops_blocking_once_resolved(autoapply_home: Paths, sock_dir: Path) -> None:
    """The tester's loop: an orphaned submit held Prodigal; Approve kept failing. Now the orphan
    becomes an unconfirmed attempt the user can resolve, and then the other job goes."""
    conn = db.open_db(autoapply_home.db)
    adapter = FakeAdapter(conn)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    try:
        orphan = _seed_app(conn, REVIEW_PATH, "Prodigal", "Data Scientist")
        waiting = _seed_app(conn, REVIEW_PATH, "Prodigal", "ML Engineer")
        db.begin_submit(conn, orphan, actor="user")
        _age(conn, orphan, timedelta(hours=2))
        r = await _cmd(d, "approve", {"application_ids": [waiting]})
        assert r["type"] == "error" and r["payload"]["code"] == "cap_reached"
        details = r["payload"]["details"]
        assert details["kind"] == db.HOLD_UNCONFIRMED and details["reason"] == "company_attempt_unconfirmed"
        assert details["other_application_id"] == orphan and details["other_state"] == "unknown_verify"
        assert details["company"] == "Prodigal" and details["resets_at"] and details["since"]
        assert db.get_application(conn, orphan).state is AppState.UNKNOWN_VERIFY
        # "It didn't go through": the company is free again and Approve works.
        assert (await _cmd(d, "resolve_unknown", {"application_id": orphan, "submitted": False}))["type"] == "ack"
        assert (await _cmd(d, "approve", {"application_ids": [waiting]}))["type"] == "ack"
        await _wait_for(lambda: db.get_application(conn, waiting).state is AppState.SUBMITTED)
    finally:
        await d.stop()


async def test_approved_submit_that_cannot_start_is_not_left_submitting(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    a = _seed_app(conn, REVIEW_PATH, "Stripe", "A")
    db.begin_submit(conn, a, actor="user")
    p, _sink, _adapter, _ = make_pipeline(conn, autoapply_home, [])

    def boom(*_a: Any, **_k: Any) -> Any:
        raise RuntimeError("profile missing")

    p.build_context = boom  # type: ignore[method-assign]
    out = await p.submit_approved([a])
    assert out == {a: AppState.FAILED}  # nothing was clicked: definitely not sent, company free
    assert p.submits_in_flight == set()
    assert db.company_hold(conn, _company_of(conn, a), 30) is None


# ---- what holds a company ------------------------------------------------------------


def test_company_hold_names_the_other_application(conn: sqlite3.Connection) -> None:
    sent = _seed_app(conn, SUBMITTED_PATH, "Prodigal", "Data Scientist")
    waiting = _seed_app(conn, REVIEW_PATH, "Prodigal", "ML Engineer")
    free = _seed_app(conn, REVIEW_PATH, "Ramp", "Backend")
    co = _company_of(conn, waiting)
    hold = db.company_hold(conn, co, 30, exclude_application_id=waiting)
    assert hold is not None and hold.kind == db.HOLD_COOLDOWN
    assert hold.other_application_id == sent and hold.other_state == "submitted"
    assert hold.since is not None and hold.resets_at == hold.since + timedelta(days=30)
    assert db.company_hold(conn, co, 0, exclude_application_id=waiting) is None  # cooldown off
    holds = db.review_sendability(conn, 30)
    assert set(holds) == {waiting} and free not in holds
    assert holds[waiting].to_dict(waiting, 0)["kind"] == "cooldown"


def test_unconfirmed_attempt_hold_and_its_window(conn: sqlite3.Connection) -> None:
    unsure = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.SUBMITTING, AppState.UNKNOWN_VERIFY], "Prodigal", "A")
    waiting = _seed_app(conn, REVIEW_PATH, "Prodigal", "B")
    co = _company_of(conn, waiting)
    hold = db.company_hold(conn, co, 30, exclude_application_id=waiting)
    assert hold is not None and hold.kind == db.HOLD_UNCONFIRMED and hold.other_application_id == unsure
    # An unverified attempt older than the window no longer holds the company.
    _age(conn, unsure, timedelta(days=31))
    assert db.company_hold(conn, co, 30, exclude_application_id=waiting) is None
    # Two jobs both waiting at one company are each sendable on their own.
    assert db.review_sendability(conn, 30) == {}


async def test_gate_carries_the_hold(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    _seed_app(conn, SUBMITTED_PATH, "Prodigal", "A")
    b = _seed_app(conn, REVIEW_PATH, "Prodigal", "B")
    p, _sink, _adapter, _ = make_pipeline(conn, autoapply_home, [])
    check = p.submit_gate(db.get_job(conn, db.get_application(conn, b).job_id), db.get_preferences(conn), application_id=b)
    assert not check.allowed and check.reason == "company_cooldown" and check.cap is CapKind.COMPANY_COOLDOWN
    assert check.hold is not None and check.resets_at == check.hold.resets_at


# ---- approve -------------------------------------------------------------------------


async def test_approve_cooldown_error_says_why_and_until_when(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=FakeAdapter(conn))
    await d.start()
    try:
        sent = _seed_app(conn, SUBMITTED_PATH, "Prodigal", "Data Scientist")
        waiting = _seed_app(conn, REVIEW_PATH, "Prodigal", "ML Engineer")
        r = await _cmd(d, "approve", {"application_ids": [waiting]})
        p = r["payload"]
        assert r["type"] == "error" and p["code"] == "cap_reached" and p["application_id"] == waiting
        assert p["message"].startswith("company_cooldown:")  # older apps parse this prefix
        det = p["details"]
        assert det["cap"] == "company_cooldown" and det["kind"] == "cooldown" and det["company"] == "Prodigal"
        assert det["other_application_id"] == sent and det["cooldown_days"] == 30
        assert det["resets_at"] is not None and det["since"] is not None
        assert [h["application_id"] for h in det["held"]] == [waiting]
        assert db.get_application(conn, waiting).state is AppState.AWAITING_REVIEW
    finally:
        await d.stop()


async def test_approve_batch_sends_one_per_company_and_explains_the_other(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    gate = asyncio.Event()
    adapter = BlockingAdapter(conn, gate=gate)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    try:
        first = _seed_app(conn, REVIEW_PATH, "Prodigal", "ML Engineer")
        second = _seed_app(conn, REVIEW_PATH, "Prodigal", "Data Scientist")
        other = _seed_app(conn, REVIEW_PATH, "Ramp", "Backend")
        r = await _cmd(d, "approve", {"application_ids": [first, second, other]})
        assert r["type"] == "ack"
        result = r["payload"]["result"]
        assert result["application_ids"] == [first, other]
        (held,) = result["held"]
        assert held["application_id"] == second and held["kind"] == "same_batch" and held["reason"] == "company_same_batch"
        assert held["other_application_id"] == first and held["company"] == "Prodigal" and held["resets_at"]
        assert db.get_application(conn, second).state is AppState.AWAITING_REVIEW
        gate.set()
        await _wait_for(lambda: db.get_application(conn, other).state is AppState.SUBMITTED)
        assert sorted(adapter.submitted) == sorted([first, other])
        # Afterwards the held one is in the company's cooldown, named after the one that went.
        hold = db.review_sendability(conn, 30)[second]
        assert hold.kind == "cooldown" and hold.other_application_id == first
    finally:
        gate.set()
        await d.stop()


async def test_approve_only_same_company_pair_still_sends_one(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=FakeAdapter(conn))
    await d.start()
    try:
        a = _seed_app(conn, REVIEW_PATH, "Prodigal", "A")
        b = _seed_app(conn, REVIEW_PATH, "Prodigal", "B")
        r = await _cmd(d, "approve", {"application_ids": [b, a]})  # the app lists the focused job first
        assert r["type"] == "ack" and r["payload"]["result"]["application_ids"] == [b]
        assert r["payload"]["result"]["held"][0]["application_id"] == a
        await _wait_for(lambda: db.get_application(conn, b).state is AppState.SUBMITTED)
    finally:
        await d.stop()
