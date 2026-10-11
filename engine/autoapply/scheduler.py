"""Internal schedule (default 09:00/13:00/18:00 local), missed-run-on-wake, caffeinate,
and the never-overlapping run coordinator.

Owner: Workstream D (daemon & LinkedIn).

* :class:`Scheduler` turns ``Preferences.schedule`` (local ``HH:MM`` strings) into fire times.
  It polls the **wall clock** in short slices rather than sleeping until the slot, because
  the monotonic clock asyncio uses stops while the Mac sleeps. A slot noticed late (after a
  wake) fires once with trigger ``wake``; several missed slots still fire only once.
* :class:`Caffeinate` keeps the machine awake (``caffeinate -i``) for the duration of a run.
* :class:`RunCoordinator` guarantees at most one pipeline run at a time (scheduled, wake,
  ``run_now`` or onboarding prep) and wraps each run in caffeinate.
"""

from __future__ import annotations

import asyncio
import contextvars
import logging
import os
import shutil
import sys
from collections.abc import Awaitable, Callable, Sequence
from datetime import datetime, time, timedelta, tzinfo
from typing import Any

from autoapply.enums import RunKind, RunTrigger

log = logging.getLogger("autoapply.scheduler")

Clock = Callable[[], datetime]
SleepFn = Callable[[float], Awaitable[None]]


def _local_now() -> datetime:
    return datetime.now().astimezone()


def _parse_hhmm(value: str) -> time:
    hh, mm = value.split(":")
    return time(int(hh), int(mm))


class Scheduler:
    #: A slot noticed more than this late is reported as a wake catch-up.
    LATE_GRACE = timedelta(minutes=2)
    #: Longest single sleep between wall-clock checks (seconds).
    POLL_SECONDS = 30.0

    def __init__(
        self,
        schedule: list[str],
        *,
        now: Clock | None = None,
        tz: tzinfo | None = None,
        sleep: SleepFn | None = None,
        last_run: datetime | None = None,
        max_catchup_age: timedelta | None = timedelta(hours=24),
        poll_seconds: float | None = None,
    ) -> None:
        """``schedule``: local HH:MM strings (``Preferences.schedule``).

        ``now``/``sleep`` are injectable for tests. ``tz`` defaults to the system local zone.
        ``last_run`` = when the previous run started (from the DB), used for the start-up
        catch-up. Missed slots older than ``max_catchup_age`` are not caught up (``None`` =
        no limit).
        """
        self._now = now or _local_now
        self._tz = tz
        self._sleep = sleep or asyncio.sleep
        self.last_run = last_run
        self.max_catchup_age = max_catchup_age
        self.poll_seconds = poll_seconds or self.POLL_SECONDS
        self._times: list[time] = []
        self._changed = asyncio.Event()
        self._stopped = False
        self.update_schedule(schedule)

    # ---- time math ---------------------------------------------------------------------

    def _local(self, dt: datetime) -> datetime:
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=self._tz) if self._tz else dt.astimezone()
        return dt.astimezone(self._tz) if self._tz else dt.astimezone()

    def now(self) -> datetime:
        return self._local(self._now())

    @property
    def schedule(self) -> list[str]:
        return [t.strftime("%H:%M") for t in self._times]

    def _slots_on(self, day: datetime) -> list[datetime]:
        out = []
        for t in self._times:
            naive = datetime.combine(day.date(), t)
            # Naive -> system local rules (DST-correct); explicit tz -> that zone.
            out.append(naive.replace(tzinfo=self._tz) if self._tz else naive.astimezone())
        return out

    def next_run_at(self, after: datetime | None = None) -> datetime | None:
        """First scheduled slot strictly after ``after`` (default now). None if no schedule."""
        if not self._times:
            return None
        ref = self._local(after) if after is not None else self.now()
        for offset in range(0, 3):
            day = ref + timedelta(days=offset)
            for slot in self._slots_on(day):
                if slot > ref:
                    return slot
        return None  # pragma: no cover - unreachable with a non-empty schedule

    def missed_runs(self, last_run: datetime | None, now: datetime | None = None) -> list[datetime]:
        """Scheduled slots in ``(last_run, now]`` (fire at most one on wake).

        ``last_run=None`` (fresh install) returns ``[]``: nothing was missed.
        """
        if last_run is None or not self._times:
            return []
        start = self._local(last_run)
        end = self._local(now) if now is not None else self.now()
        out: list[datetime] = []
        cursor = start
        while True:
            slot = self.next_run_at(cursor)
            if slot is None or slot > end:
                break
            out.append(slot)
            cursor = slot
        return out

    def catchup_due(self, now: datetime | None = None) -> datetime | None:
        """The most recent missed slot worth catching up now, or None."""
        end = self._local(now) if now is not None else self.now()
        missed = self.missed_runs(self.last_run, end)
        if not missed:
            return None
        latest = missed[-1]
        if self.max_catchup_age is not None and end - latest > self.max_catchup_age:
            return None
        return latest

    def update_schedule(self, schedule: list[str]) -> None:
        self._times = sorted({_parse_hhmm(s) for s in schedule})
        self._changed.set()

    def stop(self) -> None:
        self._stopped = True
        self._changed.set()

    # ---- loop --------------------------------------------------------------------------

    async def _nap(self, seconds: float) -> None:
        """Sleep up to ``seconds`` but wake early when the schedule changes / stop()."""
        if self._sleep is not asyncio.sleep:
            await self._sleep(seconds)
            return
        self._changed.clear()
        try:
            await asyncio.wait_for(self._changed.wait(), timeout=max(0.0, seconds))
        except TimeoutError:
            pass

    async def run_forever(self, on_fire: Callable[[RunTrigger], Awaitable[None]]) -> None:
        """Fire ``on_fire(trigger)`` at each slot until :meth:`stop`.

        ``on_fire`` is awaited, so a long run simply delays the next check (no overlap); any
        slot that passed meanwhile fires once afterwards as a catch-up.
        """
        self._stopped = False
        due = self.catchup_due()
        if due is not None:
            log.info("catching up missed run scheduled for %s", due.isoformat())
            await self._fire(on_fire, RunTrigger.WAKE)
        target = self.next_run_at(self.now())
        while not self._stopped:
            now = self.now()
            if target is None:
                await self._nap(self.poll_seconds)
                target = self.next_run_at(self.now())
                continue
            if now >= target:
                trigger = RunTrigger.WAKE if now - target > self.LATE_GRACE else RunTrigger.SCHEDULED
                await self._fire(on_fire, trigger)
                # Next slot after the moment this run *started*: a slot that passed while the
                # run was going fires once right after it (as a catch-up), never concurrently.
                target = self.next_run_at(now)
                continue
            remaining = (target - now).total_seconds()
            await self._nap(min(remaining, self.poll_seconds))
            if self._changed.is_set():
                # Schedule edited while waiting: recompute from *before* the nap so a slot
                # that passed during the nap still fires.
                self._changed.clear()
                target = self.next_run_at(now)

    async def _fire(self, on_fire: Callable[[RunTrigger], Awaitable[None]], trigger: RunTrigger) -> None:
        self.last_run = self.now()
        try:
            await on_fire(trigger)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - a failed run must not kill the scheduler
            log.exception("scheduled run (%s) failed", trigger.value)


# =====================================================================================
# caffeinate
# =====================================================================================


class Caffeinate:
    """``async with Caffeinate(): ...`` keeps the Mac from idle-sleeping (``caffeinate -i``).

    ``-w <pid>`` ties caffeinate to the daemon so it can never outlive a crash. A missing
    binary (non-macOS) is a no-op. ``command`` is injectable for tests.
    """

    def __init__(self, command: Sequence[str] | None = None, *, enabled: bool = True) -> None:
        if command is None:
            exe = shutil.which("caffeinate")
            command = [exe, "-i", "-w", str(os.getpid())] if exe else []
        self.command = list(command)
        self.enabled = enabled and bool(self.command)
        self.proc: asyncio.subprocess.Process | None = None

    async def __aenter__(self) -> "Caffeinate":
        if self.enabled:
            try:
                self.proc = await asyncio.create_subprocess_exec(
                    *self.command, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL
                )
            except OSError:
                log.warning("could not start caffeinate", exc_info=True)
                self.proc = None
        return self

    async def __aexit__(self, *exc: Any) -> None:
        await self.release()

    async def release(self) -> None:
        proc, self.proc = self.proc, None
        if proc is None or proc.returncode is not None:
            return
        try:
            proc.terminate()
            await asyncio.wait_for(proc.wait(), timeout=3)
        except ProcessLookupError:
            pass
        except TimeoutError:
            proc.kill()
            await proc.wait()

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.returncode is None


# =====================================================================================
# Run coordinator (never overlapping runs)
# =====================================================================================


class RunConflict(Exception):
    """A run is already in progress."""


class RunCoordinator:
    """Starts pipeline runs one at a time.

    ``begin(kind, trigger)`` must synchronously create the run (DB row) and return an object
    with a ``run_uid``/``run_id``; ``execute(run)`` performs it. The split lets ``run_now``
    reply with the run id immediately while the run continues in the background.
    """

    def __init__(
        self,
        begin: Callable[[RunKind, RunTrigger], Awaitable[Any]],
        execute: Callable[[Any], Awaitable[Any]],
        *,
        caffeinate_factory: Callable[[], Caffeinate] | None = None,
    ) -> None:
        self._begin = begin
        self._execute = execute
        self._caffeinate_factory = caffeinate_factory or Caffeinate
        self._lock = asyncio.Lock()
        self.task: asyncio.Task[Any] | None = None
        self.current: Any = None

    @property
    def busy(self) -> bool:
        return self._lock.locked() or (self.task is not None and not self.task.done())

    async def start(self, kind: RunKind, trigger: RunTrigger) -> Any:
        """Begin a run and execute it in the background. Raises :class:`RunConflict`."""
        if self.busy:
            raise RunConflict("a run is already in progress")
        await self._lock.acquire()
        try:
            run = await self._begin(kind, trigger)
        except BaseException:
            self._lock.release()
            raise
        self.current = run
        # The lock is released when the task finishes, even if it is cancelled before it starts.
        # Fresh context: the run must not inherit the caller's (e.g. a command's) contextvars.
        self.task = asyncio.get_running_loop().create_task(
            self._guarded(run), name=f"run-{kind.value}", context=contextvars.Context()
        )
        self.task.add_done_callback(self._on_done)
        return run

    def _on_done(self, _task: asyncio.Task[Any]) -> None:
        self.current = None
        if self._lock.locked():
            self._lock.release()

    async def run(self, kind: RunKind, trigger: RunTrigger) -> Any:
        """Begin + await the whole run (used by the scheduler so slots never overlap)."""
        await self.start(kind, trigger)
        assert self.task is not None
        return await self.task

    async def _guarded(self, run: Any) -> Any:
        async with self._caffeinate_factory():
            return await self._execute(run)

    async def wait(self) -> None:
        if self.task is not None:
            try:
                await self.task
            except BaseException:  # noqa: BLE001
                pass

    async def cancel(self) -> None:
        t = self.task
        if t is not None and not t.done():
            t.cancel()
            try:
                await t
            except BaseException:  # noqa: BLE001
                pass


__all__ = ["Caffeinate", "RunConflict", "RunCoordinator", "Scheduler"]

if sys.platform != "darwin":  # pragma: no cover
    log.debug("caffeinate unavailable on %s; runs won't prevent sleep", sys.platform)
