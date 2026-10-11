"""Scheduler math, wake catch-up (injected clock), caffeinate, and run non-overlap."""

from __future__ import annotations

import asyncio
import sys
from datetime import UTC, datetime, timedelta

import pytest

from autoapply.enums import RunKind, RunTrigger
from autoapply.scheduler import Caffeinate, RunConflict, RunCoordinator, Scheduler

TZ = UTC


def dt(day: int, hh: int, mm: int = 0, ss: int = 0) -> datetime:
    return datetime(2026, 10, day, hh, mm, ss, tzinfo=TZ)


class Clock:
    def __init__(self, start: datetime) -> None:
        self.t = start

    def __call__(self) -> datetime:
        return self.t


def test_next_run_at() -> None:
    s = Scheduler(["13:00", "09:00", "18:00"], tz=TZ)
    assert s.schedule == ["09:00", "13:00", "18:00"]
    assert s.next_run_at(dt(10, 8)) == dt(10, 9)
    assert s.next_run_at(dt(10, 9)) == dt(10, 13)  # strictly after
    assert s.next_run_at(dt(10, 18, 30)) == dt(11, 9)
    assert Scheduler([], tz=TZ).next_run_at(dt(10, 8)) is None


def test_missed_runs() -> None:
    s = Scheduler(["09:00", "13:00", "18:00"], tz=TZ)
    assert s.missed_runs(None, dt(10, 20)) == []  # fresh install: nothing missed
    assert s.missed_runs(dt(10, 8), dt(10, 8, 59)) == []
    assert s.missed_runs(dt(10, 8), dt(10, 9)) == [dt(10, 9)]
    assert s.missed_runs(dt(10, 10), dt(11, 10)) == [dt(10, 13), dt(10, 18), dt(11, 9)]


def test_catchup_due_respects_age() -> None:
    s = Scheduler(["09:00"], tz=TZ, last_run=dt(1, 9), max_catchup_age=timedelta(hours=24))
    assert s.catchup_due(dt(10, 10)) == dt(10, 9)  # most recent missed slot
    s2 = Scheduler(["09:00"], tz=TZ, last_run=dt(1, 9), max_catchup_age=timedelta(hours=12))
    assert s2.catchup_due(dt(10, 22)) is None  # missed slot too old
    assert Scheduler(["09:00"], tz=TZ, last_run=dt(10, 9, 1)).catchup_due(dt(10, 10)) is None


def test_update_schedule() -> None:
    s = Scheduler(["09:00"], tz=TZ)
    s.update_schedule(["07:30", "21:00"])
    assert s.next_run_at(dt(10, 8)) == dt(10, 21)


async def drive(s: Scheduler, clock: Clock, script: list[timedelta], *, run_time: timedelta = timedelta(0)) -> list[tuple[RunTrigger, datetime]]:
    """Run the scheduler loop with a fake sleep that advances the clock per ``script``
    (each sleep jumps by the next delta, or the requested amount when the script is empty)."""
    fired: list[tuple[RunTrigger, datetime]] = []
    steps = list(script)

    async def fake_sleep(seconds: float) -> None:
        if not steps:
            s.stop()
            return
        jump = steps.pop(0)
        clock.t += jump if jump.total_seconds() > 0 else timedelta(seconds=seconds)

    s._sleep = fake_sleep  # type: ignore[attr-defined]

    async def on_fire(trigger: RunTrigger) -> None:
        fired.append((trigger, clock.t))
        clock.t += run_time

    await asyncio.wait_for(s.run_forever(on_fire), timeout=5)
    return fired


async def test_fires_on_schedule() -> None:
    clock = Clock(dt(10, 8, 59, ))
    s = Scheduler(["09:00", "13:00"], now=clock, tz=TZ, poll_seconds=30)
    # 0 = "sleep exactly as long as requested"
    fired = await drive(s, clock, [timedelta(0), timedelta(0), timedelta(hours=4), timedelta(0)])
    assert fired[0] == (RunTrigger.SCHEDULED, dt(10, 9))
    assert fired[1][0] is RunTrigger.SCHEDULED and fired[1][1] == dt(10, 13)


async def test_wake_after_sleep_fires_once() -> None:
    """Mac asleep 08:50 -> 19:00 across three slots: exactly one catch-up run, marked wake."""
    clock = Clock(dt(10, 8, 50))
    s = Scheduler(["09:00", "13:00", "18:00"], now=clock, tz=TZ)
    fired = await drive(s, clock, [timedelta(hours=10, minutes=10)])
    assert fired == [(RunTrigger.WAKE, dt(10, 19))]
    assert s.next_run_at(clock()) == dt(11, 9)


async def test_startup_catchup_from_last_run() -> None:
    clock = Clock(dt(10, 14))
    s = Scheduler(["09:00", "13:00"], now=clock, tz=TZ, last_run=dt(9, 18))
    fired = await drive(s, clock, [])
    assert fired == [(RunTrigger.WAKE, dt(10, 14))]


async def test_long_run_never_overlaps_slots() -> None:
    """A run lasting past the next slot: the slot fires once afterwards, never concurrently."""
    clock = Clock(dt(10, 8, 59, 59))
    s = Scheduler(["09:00", "09:30"], now=clock, tz=TZ)
    fired = await drive(s, clock, [timedelta(0), timedelta(0)], run_time=timedelta(hours=1))
    assert fired[0] == (RunTrigger.SCHEDULED, dt(10, 9))
    assert fired[1] == (RunTrigger.WAKE, dt(10, 10))  # 09:30 slot caught up after the run
    assert len(fired) == 2


async def test_stop_wakes_real_sleep() -> None:
    s = Scheduler(["09:00"], poll_seconds=60)

    async def never(_t: RunTrigger) -> None:
        raise AssertionError("should not fire")

    task = asyncio.create_task(s.run_forever(never))
    await asyncio.sleep(0.05)
    s.stop()
    await asyncio.wait_for(task, timeout=2)


async def test_failed_run_does_not_kill_scheduler() -> None:
    clock = Clock(dt(10, 8, 59, 59))
    s = Scheduler(["09:00", "10:00"], now=clock, tz=TZ, poll_seconds=3600)
    calls = []

    async def boom(trigger: RunTrigger) -> None:
        calls.append(trigger)
        raise RuntimeError("run crashed")

    steps = [timedelta(0), timedelta(0), timedelta(0)]

    async def fake_sleep(seconds: float) -> None:
        if not steps:
            s.stop()
            return
        steps.pop(0)
        clock.t += timedelta(seconds=seconds)

    s._sleep = fake_sleep  # type: ignore[attr-defined]
    await asyncio.wait_for(s.run_forever(boom), timeout=5)
    assert len(calls) == 2


# ---- caffeinate -------------------------------------------------------------------


async def test_caffeinate_subprocess_lifecycle() -> None:
    cmd = [sys.executable, "-c", "import time; time.sleep(30)"]
    async with Caffeinate(cmd) as c:
        assert c.running
        proc = c.proc
    assert not c.running and proc is not None and proc.returncode is not None


async def test_caffeinate_missing_binary_is_noop() -> None:
    async with Caffeinate([]) as c:
        assert not c.running
    async with Caffeinate(["/nonexistent/caffeinate-xyz"]) as c2:
        assert not c2.running


def test_caffeinate_default_command_ties_to_pid() -> None:
    c = Caffeinate()
    if c.command:
        assert c.command[1:3] == ["-i", "-w"]


# ---- run coordinator ----------------------------------------------------------------


class _Run:
    def __init__(self, uid: str) -> None:
        self.run_uid = uid


async def test_coordinator_prevents_overlap_and_uses_caffeinate() -> None:
    gate = asyncio.Event()
    began: list[tuple[RunKind, RunTrigger]] = []
    caf: list[Caffeinate] = []

    async def begin(kind: RunKind, trigger: RunTrigger) -> _Run:
        began.append((kind, trigger))
        return _Run(f"r{len(began)}")

    async def execute(run: _Run) -> str:
        assert caf and caf[-1].running  # awake for the whole run
        await gate.wait()
        return run.run_uid

    def factory() -> Caffeinate:
        c = Caffeinate([sys.executable, "-c", "import time; time.sleep(30)"])
        caf.append(c)
        return c

    coord = RunCoordinator(begin, execute, caffeinate_factory=factory)
    run = await coord.start(RunKind.FULL, RunTrigger.MANUAL)
    assert run.run_uid == "r1" and coord.busy
    with pytest.raises(RunConflict):
        await coord.start(RunKind.DISCOVER, RunTrigger.SCHEDULED)
    gate.set()
    await coord.wait()
    assert not coord.busy and not caf[0].running
    assert await coord.run(RunKind.APPLY, RunTrigger.WAKE) == "r2"
    assert began == [(RunKind.FULL, RunTrigger.MANUAL), (RunKind.APPLY, RunTrigger.WAKE)]


async def test_coordinator_begin_failure_releases_lock() -> None:
    async def begin(kind: RunKind, trigger: RunTrigger) -> _Run:
        raise RuntimeError("db conflict")

    async def execute(run: _Run) -> None:
        return None

    coord = RunCoordinator(begin, execute, caffeinate_factory=lambda: Caffeinate([]))
    with pytest.raises(RuntimeError):
        await coord.start(RunKind.FULL, RunTrigger.MANUAL)
    assert not coord.busy


async def test_coordinator_cancel() -> None:
    async def begin(kind: RunKind, trigger: RunTrigger) -> _Run:
        return _Run("x")

    async def execute(run: _Run) -> None:
        await asyncio.sleep(60)

    coord = RunCoordinator(begin, execute, caffeinate_factory=lambda: Caffeinate([]))
    await coord.start(RunKind.FULL, RunTrigger.MANUAL)
    await coord.cancel()
    assert not coord.busy
