"""Parallel prep + fill/submit (preferences.parallel_applications)."""

from __future__ import annotations

import asyncio
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from autoapply import db, workers
from autoapply.apply.base import ApplyContext, FillResult, SubmitResult
from autoapply.config import Preferences
from autoapply.enums import AppState, CapKind, Mode, RunKind, RunOutcome
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import FormQuestion, Job
from autoapply.paths import Paths
from autoapply.pipeline import Pipeline
from autoapply.prep import run_prep

from .fakes import EventSink, FakeSource, fake_hooks, gh_job


@dataclass
class SlowAdapter:
    """Fill/harvest take a few event-loop turns so workers really overlap. Records overlap."""

    conn: sqlite3.Connection
    delay: float = 0.02
    on_fill: object = None  # callable(ctx) run mid-fill
    active: dict[int, int] = field(default_factory=dict)  # app id -> company id
    max_active: int = 0
    company_overlap: list[int] = field(default_factory=list)
    filled: list[int] = field(default_factory=list)
    submitted: list[int] = field(default_factory=list)
    harvested: list[int] = field(default_factory=list)
    fill_order: list[str] = field(default_factory=list)

    def can_handle(self, job: Job) -> bool:
        return bool(job.apply_url)

    async def _busy(self, ctx: ApplyContext) -> None:
        cid = ctx.job.company_id
        if cid in self.active.values():
            self.company_overlap.append(cid)
        self.active[ctx.application.id] = cid
        self.max_active = max(self.max_active, len(self.active))
        try:
            await asyncio.sleep(self.delay)
            if callable(self.on_fill):
                self.on_fill(ctx)
            await asyncio.sleep(self.delay)
            ctx.check_pause()
        finally:
            self.active.pop(ctx.application.id, None)

    async def harvest_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        self.harvested.append(ctx.application.id)
        await self._busy(ctx)
        return []

    async def fill(self, ctx: ApplyContext) -> FillResult:
        ctx.check_pause()
        self.filled.append(ctx.application.id)
        self.fill_order.append(ctx.job.title)
        await self._busy(ctx)
        return FillResult(ok=True)

    async def submit(self, ctx: ApplyContext) -> SubmitResult:
        assert db.get_application(self.conn, ctx.application.id).state is AppState.SUBMITTING
        await asyncio.sleep(self.delay / 2)
        self.submitted.append(ctx.application.id)
        return SubmitResult(verified=True)


def make(conn: sqlite3.Connection, paths: Paths, jobs, *, parallel: int, paused: list[bool] | None = None,
         adapter: SlowAdapter | None = None, **prefs) -> tuple[Pipeline, EventSink, SlowAdapter]:
    db.update_preferences(conn, {"parallel_applications": parallel, **prefs})
    sink = EventSink()
    adapter = adapter or SlowAdapter(conn)
    hooks, _ = fake_hooks()
    flag = paused if paused is not None else [False]
    p = Pipeline(conn, paths=paths, llm=FakeLLMProvider(default="ok"), sources=[FakeSource(jobs)], adapters=[adapter],
                 emit=sink, hooks=hooks, is_paused=lambda: flag[0])
    return p, sink, adapter


def states(conn: sqlite3.Connection) -> dict[str, str]:
    return {r["title"]: r["state"] for r in conn.execute("SELECT j.title, a.state FROM jobs j JOIN applications a ON a.job_id = j.id")}


def distinct_jobs(n: int) -> list:
    return [gh_job(f"Co{i}", f"Role {i}", i) for i in range(n)]


# ---- preference ------------------------------------------------------------------------


def test_preference_default_and_bounds(conn: sqlite3.Connection) -> None:
    assert Preferences().parallel_applications == 3
    assert db.get_preferences(conn).parallel_applications == 3
    assert db.update_preferences(conn, {"parallel_applications": 4}).parallel_applications == 4
    for bad in (0, 5):
        with pytest.raises(ValueError):
            db.update_preferences(conn, {"parallel_applications": bad})
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("UPDATE preferences SET parallel_applications = 9 WHERE id = 1")


def test_v6_migration_adds_column(tmp_path: Path) -> None:
    """A v5 database (no parallel_applications) gains the column with its default."""
    c = db.connect(tmp_path / "v5.db")
    db.migrate(c)
    c.execute("ALTER TABLE preferences DROP COLUMN parallel_applications")
    c.execute("DELETE FROM schema_version WHERE version = 6")
    c.execute("INSERT OR IGNORE INTO preferences(id) VALUES (1)")
    assert db.current_schema_version(c) == 5
    assert db.migrate(c) == db.SCHEMA_VERSION
    assert db.get_preferences(c).parallel_applications == 3
    c.close()


# ---- apply -----------------------------------------------------------------------------


async def test_n_applications_in_flight(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    p, sink, adapter = make(conn, autoapply_home, distinct_jobs(5), parallel=3)
    info = await p.run(RunKind.FULL)
    assert info.outcome is RunOutcome.COMPLETED
    assert adapter.max_active == 3
    assert len(adapter.submitted) == 5 and info.stats.submitted == 5
    assert set(states(conn).values()) == {"submitted"}
    # activity lines say which agent they came from
    filling = [s.message for s in sink.of("state") if s.message and "Filling" in s.message]
    assert filling and all(m.startswith("[agent ") for m in filling)
    assert {m.split("]")[0] for m in filling} == {"[agent 1", "[agent 2", "[agent 3"}
    submitted_logs = [lg.message for lg in sink.of("log") if "Submitted" in lg.message]
    assert len(submitted_logs) == 5 and all(m.startswith("[agent ") for m in submitted_logs)
    # each transition stays legal and is emitted once per state change
    tos = [e.to_state for e in sink.of("application_state")]
    assert tos.count(AppState.SUBMITTED) == 5 and tos.count(AppState.SUBMITTING) == 5 and tos.count(AppState.FILLING) == 5


async def test_parallel_one_is_sequential_and_untagged(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = distinct_jobs(4)
    p, sink, adapter = make(conn, autoapply_home, jobs, parallel=1)
    info = await p.run(RunKind.FULL)
    assert info.outcome is RunOutcome.COMPLETED
    assert adapter.max_active == 1
    queued_order = [db.get_job(conn, a.job_id).title for a in db.list_applications(conn, states=[AppState.SUBMITTED])]
    assert sorted(adapter.fill_order) == sorted(queued_order) and len(adapter.fill_order) == 4
    assert not any("[agent" in (lg.message or "") for lg in sink.of("log"))
    assert not any("[agent" in (s.message or "") for s in sink.of("state"))


async def test_same_company_never_in_flight_twice(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("Stripe", f"Stripe {i}", i) for i in range(3)] + [gh_job("Notion", "Notion 1", 10), gh_job("Figma", "Figma 1", 11)]
    p, _sink, adapter = make(conn, autoapply_home, jobs, parallel=4)
    await p.run(RunKind.FULL)
    assert adapter.company_overlap == []
    st = states(conn)
    stripe = [v for k, v in st.items() if k.startswith("Stripe")]
    # cooldown still applies: one Stripe application, the rest skipped once the first went in
    assert sorted(stripe) == ["skipped", "skipped", "submitted"]
    assert st["Notion 1"] == "submitted" and st["Figma 1"] == "submitted"
    assert adapter.max_active >= 2  # other companies still ran alongside


async def test_daily_cap_not_overshot(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    p, sink, adapter = make(conn, autoapply_home, distinct_jobs(8), parallel=4, daily_cap=3)
    info = await p.run(RunKind.FULL)
    assert info.outcome is RunOutcome.CAP_REACHED
    assert len(adapter.submitted) == 3 and db.submitted_today(conn) == 3
    assert adapter.max_active <= 3
    assert sorted(states(conn).values()) == ["queued"] * 5 + ["submitted"] * 3
    caps = [c for c in sink.of("cap_reached") if c.cap is CapKind.DAILY]
    assert caps and caps[-1].used == 3 and caps[-1].limit == 3


async def test_submit_gate_is_atomic_across_concurrent_workers(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    """Even without the dispatch-time reservation, workers finishing together can't overshoot:
    the gate and the durable 'submitting' pre-write have no await between them."""
    p, _sink, adapter = make(conn, autoapply_home, distinct_jobs(6), parallel=4, daily_cap=2)
    await p.run(RunKind.DISCOVER)
    apps = db.list_applications(conn, states=[AppState.QUEUED])
    assert len(apps) == 6
    results = await asyncio.gather(*(p.apply_one(a.id) for a in apps), return_exceptions=True)
    assert len(adapter.submitted) == 2 and db.submitted_today(conn) == 2
    assert adapter.max_active == 6  # all six really filled at once
    assert sum(1 for r in results if isinstance(r, Exception)) == 4  # CapReached for the rest
    assert sorted(states(conn).values()) == ["queued"] * 4 + ["submitted"] * 2


async def test_pause_stops_all_workers(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    paused = [False]
    adapter = SlowAdapter(conn)
    p, _sink, adapter = make(conn, autoapply_home, distinct_jobs(6), parallel=3, paused=paused, adapter=adapter)

    def pause_once(ctx: ApplyContext) -> None:
        if len(adapter.filled) >= 3:
            paused[0] = True

    adapter.on_fill = pause_once
    await p.run(RunKind.DISCOVER)
    adapter.harvested.clear()
    info = await p.run(RunKind.APPLY)
    assert info.outcome is RunOutcome.PAUSED
    assert len(adapter.filled) == 3  # the three in flight; nothing new started
    assert adapter.submitted == []
    assert set(states(conn).values()) == {"queued"}  # every worker put its application back
    reasons = {a.state_reason for a in db.list_applications(conn, states=[AppState.QUEUED]) if a.id in adapter.filled}
    assert reasons == {"paused"}


async def test_review_mode_never_submits_in_parallel(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    p, _sink, adapter = make(conn, autoapply_home, distinct_jobs(4), parallel=4, mode=Mode.REVIEW.value)
    await p.run(RunKind.FULL)
    assert adapter.submitted == [] and adapter.max_active == 4
    assert set(states(conn).values()) == {"awaiting_review"}


async def test_tokens_attributed_per_application(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    """Concurrent LLM calls are billed to the application that made them, not to its neighbours."""
    llm = FakeLLMProvider(default="ok")
    adapter = SlowAdapter(conn)
    own: dict[int, int] = {}

    async def fill(ctx: ApplyContext) -> FillResult:
        await asyncio.sleep(0.005 * ctx.application.id)
        res = await ctx.llm.complete(f"fill application {ctx.application.id} " + "x" * 40 * ctx.application.id)
        own[ctx.application.id] = res.usage.total_tokens
        await asyncio.sleep(0.02)
        return FillResult(ok=True)

    adapter.fill = fill  # type: ignore[method-assign]
    p, _sink, _ = make(conn, autoapply_home, distinct_jobs(3), parallel=3, adapter=adapter)
    p.llm = llm
    await p.run(RunKind.DISCOVER)

    def billed() -> dict[int, int]:
        return {r["id"]: r["tokens_in"] + r["tokens_out"] for r in conn.execute("SELECT id, tokens_in, tokens_out FROM applications")}

    before = billed()
    await p.run(RunKind.APPLY)
    after = billed()
    assert len(own) == 3 and all(after[i] - before[i] == own[i] for i in own)


# ---- prep ------------------------------------------------------------------------------


async def test_prep_runs_in_parallel_without_same_company_overlap(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("Stripe", "Stripe A", 1), gh_job("Stripe", "Stripe B", 2)] + [gh_job(f"Co{i}", f"Role {i}", 10 + i) for i in range(4)]
    p, _sink, adapter = make(conn, autoapply_home, jobs, parallel=3)
    await p.run(RunKind.DISCOVER)
    sink = EventSink()
    report = await run_prep(conn, llm=FakeLLMProvider(default="ok"), adapters=[adapter], emit=sink)
    assert report.jobs_scanned == 6 and len(report.requeued_jobs) == 6
    assert adapter.max_active == 3 and adapter.company_overlap == []
    assert set(states(conn).values()) == {"queued"}
    msgs = [s.message for s in sink.of("state") if s.message and "Collecting questions ·" in s.message]
    assert len(msgs) == 6


async def test_prep_pause_stops_dispatch(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    paused = [False]
    p, _sink, adapter = make(conn, autoapply_home, distinct_jobs(6), parallel=2)
    await p.run(RunKind.DISCOVER)
    adapter.on_fill = lambda ctx: paused.__setitem__(0, True)
    report = await run_prep(conn, llm=FakeLLMProvider(default="ok"), adapters=[adapter], emit=EventSink(), is_paused=lambda: paused[0])
    assert report.paused
    assert len(adapter.harvested) == 2
    assert set(states(conn).values()) == {"queued"}


# ---- worker pool / agent profiles ------------------------------------------------------


async def test_pool_slots_and_keys() -> None:
    seen: list[tuple[int | None, str]] = []
    live: set[str] = set()
    overlap: list[str] = []

    async def work(_i: int, item: tuple[str, str]) -> None:
        key, name = item
        if key in live:
            overlap.append(key)
        live.add(key)
        seen.append((workers.current_slot(), workers.tag()))
        await asyncio.sleep(0.01)
        live.discard(key)

    items = [("a", "1"), ("a", "2"), ("b", "3"), ("c", "4"), ("a", "5")]
    res = await workers.run_pool(items, work, limit=2, key=lambda it: it[0])
    assert overlap == [] and res.max_in_flight == 2 and res.left == []
    assert {s for s, _ in seen} == {1, 2} and all(t in ("[agent 1] ", "[agent 2] ") for _, t in seen)
    assert workers.current_slot() is None and workers.tag() == ""


def test_agentic_profile_per_worker_slot(tmp_path: Path) -> None:
    from autoapply.apply.agentic import AgenticAdapter
    from autoapply.workers import _WORKER, _Worker

    base = tmp_path / "chrome-profile"
    a = AgenticAdapter(chrome_profile_dir=base, client_factory=lambda *_: None)  # type: ignore[arg-type,return-value]
    assert a.profile_dir() == base
    tok = _WORKER.set(_Worker(slot=1, tagged=True))
    assert a.profile_dir() == base
    _WORKER.reset(tok)
    tok = _WORKER.set(_Worker(slot=3, tagged=True))
    try:
        p3 = a.profile_dir()
    finally:
        _WORKER.reset(tok)
    assert p3 == tmp_path / "chrome-profile-3" and p3.is_dir()


async def test_agentic_close_slot_leaves_other_workers_sessions(tmp_path: Path) -> None:
    from autoapply.apply.agentic import AgenticAdapter
    from autoapply.workers import _WORKER, _Worker

    class Client:
        def __init__(self) -> None:
            self.disconnected = False

        async def disconnect(self) -> None:
            self.disconnected = True

    a = AgenticAdapter(chrome_profile_dir=tmp_path / "p", client_factory=lambda *_: None)  # type: ignore[arg-type,return-value]
    c1, c2 = Client(), Client()
    a._live = {1: (c1, None), 2: (c2, None)}  # type: ignore[dict-item]
    a._live_slot = {1: 1, 2: 2}
    tok = _WORKER.set(_Worker(slot=2, tagged=True))
    try:
        await a._close_slot()
    finally:
        _WORKER.reset(tok)
    assert c2.disconnected and not c1.disconnected and list(a._live) == [1]


async def test_reaper_skips_sessions_of_running_workers() -> None:
    from autoapply.apply import base

    class Ctx:
        async def close(self) -> None:
            pass

    hold = asyncio.Event()
    made: list[base.BrowserSession] = []

    async def other_worker() -> None:
        s = base.BrowserSession(application_id=991, page=None, context=Ctx())  # type: ignore[arg-type]
        s.last_used -= 10_000
        base._OPEN_SESSIONS[991] = s
        made.append(s)
        await hold.wait()

    t = asyncio.create_task(other_worker())
    await asyncio.sleep(0)
    try:
        assert await base.reap_idle_sessions() == 0 and 991 in base._OPEN_SESSIONS
        hold.set()
        await t
        assert await base.reap_idle_sessions() == 1 and 991 not in base._OPEN_SESSIONS
    finally:
        base._OPEN_SESSIONS.pop(991, None)

