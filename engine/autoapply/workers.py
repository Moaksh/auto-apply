"""Bounded worker pool for per-application work (prep and fill/submit).

Up to ``limit`` applications are worked on at once, each in its own asyncio task with its
own *worker slot* (1..limit). The slot is visible to everything the task calls through
:func:`current_slot` (a context variable), which is how:

* the agentic adapter picks a Chrome profile per slot (Chromium allows one process per
  user-data-dir, so two agents can never share one), and
* log / state messages get an ``[agent N]`` prefix (:func:`tag`) when more than one
  worker runs.

Rules enforced by :func:`run_pool`:

* never two items with the same ``key`` (company) in flight at once;
* ``can_start(n_running)`` is asked before every dispatch (daily-cap reservation);
* ``should_stop()`` (pause) stops new dispatches; running workers stop themselves (they
  check the same pause flag), so nothing is cancelled half-way through a submit;
* a worker exception stops new dispatches; the pool waits for the others to finish and
  then re-raises (``PausedError`` first, then ``CapReached``, then anything else).

Everything runs on the daemon's single event loop thread, so the shared sqlite3
connection is never used from two threads, and a ``check -> db write`` sequence with no
``await`` in between (``submit_gate`` -> ``begin_submit``) stays atomic across workers.
"""

from __future__ import annotations

import asyncio
import contextvars
from collections.abc import Awaitable, Callable, Hashable, Sequence
from dataclasses import dataclass, field
from typing import Any, Generic, TypeVar

T = TypeVar("T")


@dataclass(frozen=True, slots=True)
class _Worker:
    slot: int
    tagged: bool


_WORKER: contextvars.ContextVar[_Worker | None] = contextvars.ContextVar("autoapply_worker", default=None)


def current_slot() -> int | None:
    """Worker slot (1-based) of the running task, or None outside a pool."""
    w = _WORKER.get()
    return w.slot if w is not None else None


def tag() -> str:
    """``"[agent N] "`` inside a multi-worker pool, else ``""``."""
    w = _WORKER.get()
    return f"[agent {w.slot}] " if w is not None and w.tagged else ""


def tagged(message: str | None) -> str | None:
    t = tag()
    if not t or message is None or message.startswith("[agent "):
        return message
    return t + message


@dataclass(slots=True)
class PoolResult(Generic[T]):
    started: list[T] = field(default_factory=list)
    #: items never dispatched (paused / stopped / blocked by ``can_start`` with nothing running)
    left: list[T] = field(default_factory=list)
    results: dict[int, Any] = field(default_factory=dict)  # index in items -> worker return value
    max_in_flight: int = 0


def _priority(exc: BaseException, order: Sequence[type[BaseException]]) -> int:
    for i, t in enumerate(order):
        if isinstance(exc, t):
            return i
    return len(order)


async def run_pool(
    items: Sequence[T],
    work: Callable[[int, T], Awaitable[Any]],
    *,
    limit: int,
    key: Callable[[T], Hashable | None] = lambda _i: None,
    should_stop: Callable[[], bool] = lambda: False,
    can_start: Callable[[int], bool] = lambda _n: True,
    raise_order: Sequence[type[BaseException]] = (),
) -> PoolResult[T]:
    """Run ``work(index, item)`` for every item, at most ``limit`` at a time, in order,
    skipping past items whose ``key`` is already in flight (they run once it frees up)."""
    limit = max(1, int(limit))
    multi = limit > 1 and len(items) > 1
    pending: list[int] = list(range(len(items)))
    running: dict[asyncio.Task[Any], tuple[int, int, Hashable | None]] = {}  # task -> (index, slot, key)
    busy_keys: set[Hashable] = set()
    free_slots = list(range(1, limit + 1))
    errors: list[BaseException] = []
    out: PoolResult[T] = PoolResult()

    async def _run(slot: int, idx: int) -> Any:
        _WORKER.set(_Worker(slot=slot, tagged=multi))
        return await work(idx, items[idx])

    def dispatch() -> None:
        for idx in list(pending):
            if len(running) >= limit or errors or should_stop():
                return
            k = key(items[idx])
            if k is not None and k in busy_keys:
                continue
            if not can_start(len(running)):
                return
            pending.remove(idx)
            slot = free_slots.pop(0)
            if k is not None:
                busy_keys.add(k)
            # create_task copies the current context; _run sets the worker in the copy only.
            task = asyncio.create_task(_run(slot, idx))
            running[task] = (idx, slot, k)
            out.started.append(items[idx])
            out.max_in_flight = max(out.max_in_flight, len(running))

    try:
        while True:
            dispatch()
            if not running:
                break
            done, _ = await asyncio.wait(running, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                idx, slot, k = running.pop(task)
                free_slots.append(slot)
                free_slots.sort()
                if k is not None:
                    busy_keys.discard(k)
                if task.cancelled():
                    errors.append(asyncio.CancelledError())
                    continue
                exc = task.exception()
                if exc is not None:
                    errors.append(exc)
                else:
                    out.results[idx] = task.result()
    except asyncio.CancelledError:
        # The run itself was cancelled: cancel the workers (they put their applications back).
        for task in running:
            task.cancel()
        await asyncio.gather(*running, return_exceptions=True)
        raise
    out.left = [items[i] for i in pending]
    if errors:
        raise min(errors, key=lambda e: _priority(e, raise_order))
    return out


__all__ = ["PoolResult", "current_slot", "run_pool", "tag", "tagged"]
