"""Regression tests for the submit guardrails under concurrency and unknown outcomes.

* unverified / in-flight submits count toward the daily cap and hold the company cooldown;
* approved submits are serialized with runs (shared Chrome profile) and never attributed
  to a concurrent run;
* adapter sessions are always released; the kill switch is never stuck behind a slow command.
"""

from __future__ import annotations

import asyncio
import plistlib
import shutil
import sqlite3
import tempfile
import time
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest

from autoapply import db
from autoapply.apply.base import ApplyContext, SubmitResult
from autoapply.discovery.linkedin import LinkedinSource
from autoapply.enums import AppState, CapKind, RunKind, RunOutcome
from autoapply.launchd_install import package_root, render_plist
from autoapply.models import SystemCheckItem, SystemCheckResult, make_command
from autoapply.paths import Paths
from autoapply.pipeline import COMPANY_ATTEMPT_PENDING, attempts_used_today, company_attempt_at

from .fakes import FakeAdapter, FakeSource, gh_job, instant_pacer
from .test_daemon import Conn, _seed_app, build_daemon
from .test_linkedin import LI_ROUTES, ctx_for
from .test_pipeline import make_pipeline, states

REVIEW_PATH = [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.AWAITING_REVIEW]


@pytest.fixture
def sock_dir() -> Iterator[Path]:
    d = tempfile.mkdtemp(prefix="aag", dir="/tmp")
    yield Path(d)
    shutil.rmtree(d, ignore_errors=True)


@dataclass
class BlockingAdapter(FakeAdapter):
    """FakeAdapter whose submit() waits on ``gate`` and which records close() calls."""

    gate: asyncio.Event | None = None
    entered: asyncio.Event = field(default_factory=asyncio.Event)
    closed_ids: list[int | None] = field(default_factory=list)

    async def submit(self, ctx: ApplyContext) -> SubmitResult:
        self.entered.set()
        if self.gate is not None:
            await self.gate.wait()
        return await super().submit(ctx)

    async def close(self, application_id: int | None = None) -> None:
        self.closed_ids.append(application_id)


async def _wait_for(pred: Any, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while not pred():
        if time.monotonic() > deadline:
            raise AssertionError("condition not reached")
        await asyncio.sleep(0.01)


# ---- pipeline: unknown outcomes count ------------------------------------------------


async def test_unverified_submits_count_toward_daily_cap(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    db.update_preferences(conn, {"daily_cap": 1})
    jobs = [gh_job(f"Co{i}", f"Role {i}", i) for i in range(4)]
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs)
    adapter.unverified_titles = {f"Role {i}" for i in range(4)}
    info = await p.run(RunKind.FULL)
    assert len(adapter.submitted) == 1  # exactly one click, never four
    assert sorted(states(conn).values()) == ["queued", "queued", "queued", "unknown_verify"]
    assert info.outcome is RunOutcome.CAP_REACHED
    assert db.submitted_today(conn) == 0 and attempts_used_today(conn) == 1
    cap = [c for c in sink.of("cap_reached") if c.cap is CapKind.DAILY][-1]
    assert cap.used == 1 and cap.limit == 1


async def test_submitting_rows_count_toward_daily_cap(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    db.update_preferences(conn, {"daily_cap": 1})
    in_flight = _seed_app(conn, REVIEW_PATH, "Elsewhere", "Busy")
    db.begin_submit(conn, in_flight, actor="user")
    p, _sink, adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)])
    info = await p.run(RunKind.FULL)
    assert adapter.submitted == [] and info.outcome is RunOutcome.CAP_REACHED
    assert states(conn)["Backend Engineer"] == "queued"


async def test_unknown_verify_blocks_same_company(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("Stripe", "Backend Engineer", 1), gh_job("Stripe", "Infra Engineer", 2)]
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs)
    adapter.unverified_titles = {"Backend Engineer", "Infra Engineer"}
    await p.run(RunKind.FULL)
    assert len(adapter.submitted) == 1  # no second application to Stripe
    assert sorted(states(conn).values()) == ["queued", "unknown_verify"]  # kept queued, not skipped
    cd = [c for c in sink.of("cap_reached") if c.cap is CapKind.COMPANY_COOLDOWN]
    assert cd and cd[0].company_id is not None
    # Another run still does not touch Stripe while the outcome is unknown.
    await p.run(RunKind.APPLY)
    assert len(adapter.submitted) == 1
    # Once the user says the first one was NOT sent, the queued one may go.
    first = db.list_applications(conn, states=[AppState.UNKNOWN_VERIFY])[0]
    db.transition(conn, first.id, AppState.FAILED, actor="user", reason="not_sent")
    adapter.unverified_titles = set()
    await p.run(RunKind.APPLY)
    assert len(adapter.submitted) == 2 and "submitted" in states(conn).values()


def test_company_attempt_query(conn: sqlite3.Connection) -> None:
    a = _seed_app(conn, REVIEW_PATH, "Stripe", "A")
    co = db.get_job(conn, db.get_application(conn, a).job_id).company_id
    assert company_attempt_at(conn, co, 30) is None
    db.begin_submit(conn, a, actor="user")
    assert company_attempt_at(conn, co, 30) is not None
    assert company_attempt_at(conn, co, 30, exclude_application_id=a) is None
    assert company_attempt_at(conn, co, 0) is None  # cooldown disabled
    db.transition(conn, a, AppState.UNKNOWN_VERIFY)
    assert company_attempt_at(conn, co, 30) is not None


async def test_gate_reason_for_unconfirmed_company_attempt(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    a = _seed_app(conn, REVIEW_PATH, "Stripe", "A")
    b = _seed_app(conn, REVIEW_PATH, "Stripe", "B")
    db.begin_submit(conn, a, actor="user")
    p, _sink, _adapter, _ = make_pipeline(conn, autoapply_home, [])
    job_b = db.get_job(conn, db.get_application(conn, b).job_id)
    check = p.submit_gate(job_b, db.get_preferences(conn), application_id=b)
    assert not check.allowed and check.reason == COMPANY_ATTEMPT_PENDING and check.cap is CapKind.COMPANY_COOLDOWN


# ---- pipeline: sessions are always released ------------------------------------------


@pytest.mark.parametrize(
    ("setup", "expected"),
    [
        (lambda conn, a: setattr(a, "unresolved_titles", {"Backend Engineer"}), "needs_you"),
        (lambda conn, a: setattr(a, "fail_titles", {"Backend Engineer"}), "failed"),
        (lambda conn, a: setattr(a, "raise_titles", {"Backend Engineer"}), "failed"),
        (lambda conn, a: db.update_preferences(conn, {"mode": "review"}), "awaiting_review"),
        (lambda conn, a: setattr(a, "pause_on_fill", lambda: conn.execute(
            "UPDATE companies SET last_applied_at = ? WHERE name = 'Stripe'", (db.format_ts(db.utcnow()),))), "queued"),
        (lambda conn, a: None, "submitted"),
    ],
    ids=["needs_you", "fill_not_ok", "fill_raises", "review", "gate_blocked", "submitted"],
)
async def test_adapter_session_released_on_every_path(
    conn: sqlite3.Connection, autoapply_home: Paths, setup: Any, expected: str,
) -> None:
    adapter = BlockingAdapter(conn)
    setup(conn, adapter)
    p, _sink, _a, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)], adapter=adapter)
    await p.run(RunKind.FULL)
    assert states(conn) == {"Backend Engineer": expected}
    app = db.list_applications(conn)[0]
    assert adapter.closed_ids == [app.id]


async def test_close_adapters_closes_everything(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    adapter = BlockingAdapter(conn)
    p, _sink, _a, _ = make_pipeline(conn, autoapply_home, [], adapter=adapter)
    await p.close_adapters()
    assert adapter.closed_ids == [None]


# ---- daemon: approve vs runs ----------------------------------------------------------


async def _cmd(d: Any, type_: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    (reply,) = await d.handle(make_command(type_, payload or {}))
    return reply.model_dump(mode="json")


async def test_second_approve_batch_counts_in_flight_submits(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    gate = asyncio.Event()
    adapter = BlockingAdapter(conn, gate=gate)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    try:
        db.update_preferences(conn, {"daily_cap": 2})
        a1, a2, a3 = (_seed_app(conn, REVIEW_PATH, f"Co{i}", f"T{i}") for i in range(3))
        r1 = await _cmd(d, "approve", {"application_ids": [a1, a2]})
        assert r1["type"] == "ack"
        await asyncio.wait_for(adapter.entered.wait(), 3)
        r2 = await _cmd(d, "approve", {"application_ids": [a3]})
        assert r2["type"] == "error" and r2["payload"]["code"] == "cap_reached"
        assert db.get_application(conn, a3).state is AppState.AWAITING_REVIEW
        gate.set()
        await _wait_for(lambda: db.get_application(conn, a2).state is AppState.SUBMITTED)
        assert sorted(adapter.submitted) == [a1, a2]
    finally:
        gate.set()
        await d.stop()


async def test_approve_same_company_as_in_flight_submit_is_refused(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    gate = asyncio.Event()
    adapter = BlockingAdapter(conn, gate=gate)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    try:
        a1 = _seed_app(conn, REVIEW_PATH, "Stripe", "A")
        a2 = _seed_app(conn, REVIEW_PATH, "Stripe", "B")
        assert (await _cmd(d, "approve", {"application_ids": [a1]}))["type"] == "ack"
        r2 = await _cmd(d, "approve", {"application_ids": [a2]})
        assert r2["type"] == "error" and r2["payload"]["code"] == "cap_reached"
        gate.set()
        await _wait_for(lambda: db.get_application(conn, a1).state is AppState.SUBMITTED)
        assert adapter.submitted == [a1]
    finally:
        gate.set()
        await d.stop()


async def test_approve_during_run_waits_and_is_not_attributed_to_it(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    adapter = BlockingAdapter(conn)
    run_gate = asyncio.Event()
    src = FakeSource([])

    async def slow_discover(ctx: Any) -> Any:
        await run_gate.wait()
        return []

    src.discover = slow_discover  # type: ignore[method-assign]
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter, sources=[src])
    await d.start()
    try:
        app_id = _seed_app(conn, REVIEW_PATH, "Stripe", "A")
        run = await _cmd(d, "run_now", {"kind": "full"})
        run_id = run["payload"]["result"]["run_id"]
        await _wait_for(lambda: d.pipeline.browser_lock.locked())
        assert (await _cmd(d, "approve", {"application_ids": [app_id]}))["type"] == "ack"
        await asyncio.sleep(0.1)
        # The run holds the Chrome profile: the approved submit queues (still `submitting`).
        assert adapter.submitted == [] and db.get_application(conn, app_id).state is AppState.SUBMITTING
        # ...and while it waits it already holds the daily cap / company slot.
        assert attempts_used_today(conn) == 1
        run_gate.set()
        await _wait_for(lambda: db.get_application(conn, app_id).state is AppState.SUBMITTED)
        await d.coordinator.wait()
        finished = db.get_run(conn, run_id)
        assert finished.stats.submitted == 0  # the approved submit is not the run's
        rows = conn.execute(
            "SELECT run_id FROM events WHERE kind = 'state' AND application_id = ? AND message LIKE 'submitting →%'", (app_id,),
        ).fetchall()
        assert len(rows) == 1 and rows[0]["run_id"] is None  # transition logged without the run's id
    finally:
        run_gate.set()
        await d.stop()


async def test_connect_source_refused_while_browser_busy(autoapply_home: Paths, sock_dir: Path) -> None:
    connected = asyncio.Event()

    class StubSource:
        async def connect(self) -> bool:
            connected.set()
            return True

    d = build_daemon(autoapply_home, sock_dir / "d.sock", source_factory=lambda name: StubSource())
    await d.start()
    try:
        lock = d.pipeline.browser_lock
        await lock.acquire()
        r = await _cmd(d, "onboarding_connect_source", {"source": "linkedin"})
        assert r["type"] == "error" and r["payload"]["code"] == "conflict"
        r = await _cmd(d, "open_agent_chrome", {})
        assert r["type"] == "error" and r["payload"]["code"] == "conflict"
        lock.release()
        r = await _cmd(d, "onboarding_connect_source", {"source": "linkedin"})
        assert r["type"] == "ack"
        await asyncio.wait_for(connected.wait(), 3)
        await _wait_for(lambda: not lock.locked())  # released when the connect task ends
    finally:
        await d.stop()


async def test_stop_closes_adapters(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    adapter = BlockingAdapter(conn)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    await d.stop()
    assert None in adapter.closed_ids


async def test_pause_all_not_blocked_by_slow_command_on_same_client(autoapply_home: Paths, sock_dir: Path) -> None:
    def slow_check() -> SystemCheckResult:
        time.sleep(1.5)
        return SystemCheckResult(items=[SystemCheckItem(name="autoapplyd", ok=True)], all_required_ok=True)

    d = build_daemon(autoapply_home, sock_dir / "d.sock", system_check=slow_check)
    await d.start()
    try:
        c = await Conn.open(d.socket_path)
        slow_id = await c.send("onboarding_system_check")
        await asyncio.sleep(0.05)
        t0 = time.monotonic()
        pause_id = await c.send("pause_all")
        reply, seen = await c.recv_until(lambda m: m.get("reply_to") == pause_id, timeout=3)
        assert reply["type"] == "ack" and time.monotonic() - t0 < 1.0
        assert not any(m.get("reply_to") == slow_id for m in seen)  # the slow one is still running
        assert d.paused is True
        slow, _ = await c.recv_until(lambda m: m.get("reply_to") == slow_id, timeout=5)
        assert slow["type"] == "ack"
        # ordinary commands from one client still answer in order
        ids = [await c.send("ping") for _ in range(3)] + [await c.send("onboarding_set_step", {"step": 2})]
        got = []
        while len(got) < len(ids):
            m = await c.recv()
            if m.get("reply_to") in ids:
                got.append(m["reply_to"])
        assert got == ids
        await c.close()
    finally:
        await d.stop()


# ---- discovery budget / launchd --------------------------------------------------------


async def test_failed_browser_launch_does_not_spend_session_budget(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["Backend Engineer"], "locations": ["India"], "sources_enabled": {"linkedin": True}})

    async def broken_factory() -> Any:
        raise RuntimeError("profile in use (SingletonLock)")

    src = LinkedinSource(conn, browser_factory=broken_factory, pacer=instant_pacer())
    with pytest.raises(RuntimeError):
        await src.discover(ctx_for(conn))
    assert db.get_source_sessions(conn, src.source_key) == 0
    assert LI_ROUTES  # (fixture routes exist for the happy path in test_linkedin)


def test_plist_pins_pythonpath(autoapply_home: Paths) -> None:
    data = plistlib.loads(render_plist(autoapply_home, program_arguments=["/x/autoapplyd"], path_env="/usr/bin"))
    pp = data["EnvironmentVariables"]["PYTHONPATH"]
    assert pp == str(package_root()) and (Path(pp) / "autoapply" / "__init__.py").exists()
