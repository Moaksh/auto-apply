"""Pipeline orchestration: Discover -> Score -> Prep -> Apply for one run.

Owner: Workstream D (daemon & LinkedIn).

Owns every application state transition during a run (``db.transition``), the
guardrail check + ``db.begin_submit`` before ``Adapter.submit``, and event emission.

Seams (all injectable through :class:`PipelineHooks`, defaulting to the real modules):

* Workstream A: ``scoring.hard_filter`` / ``scoring.score_jobs``, sources, scripted adapters.
* Workstream B: ``prep.run_prep``, ``answers.resume_picker.pick_resume``,
  ``easy_apply.refresh_easy_apply``, ``answers.memory.AnswerMemory.cluster_open_questions``.

A seam that still raises ``NotImplementedError`` degrades gracefully (logged, step skipped
or a conservative local fallback is used) so the daemon is usable while other workstreams
land.

Double-apply protection (PLAN.md §4.2, protocol.md §7):

1. ``submit_gate`` (pause, daily cap, company cooldown) is evaluated immediately before
   ``db.begin_submit`` with no ``await`` in between, so nothing can slip past it.
2. ``db.begin_submit`` durably commits ``submitting`` before ``Adapter.submit`` clicks.
3. Any outcome other than a verified confirmation -> ``unknown_verify`` (never retried).
"""

from __future__ import annotations

import asyncio
import os
import contextvars
import inspect
import logging
import sqlite3
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

import httpx
from pydantic import BaseModel

from autoapply import db
from autoapply.apply.base import Adapter, ApplyContext, EmitFn, FillResult, PausedError, UnresolvedField, close_session
from autoapply.config import Preferences
from autoapply.discovery.base import DiscoveredJob, DiscoveryContext, Source
from autoapply.enums import (
    Actor,
    AppState,
    Ats,
    CapKind,
    DaemonActivity,
    LogLevel,
    Mode,
    QuestionReason,
    RemotePolicy,
    RunKind,
    RunOutcome,
    RunTrigger,
)
from autoapply.llm.provider import LLMProvider
from autoapply.models import (
    Application,
    CapReachedPayload,
    Company,
    ErrorPayload,
    Job,
    JobDiscoveredPayload,
    JobScoredPayload,
    LogPayload,
    NudgeDuePayload,
    Progress,
    QuestionOpenedPayload,
    Run,
    RunFinishedPayload,
    RunInfo,
    RunStartedPayload,
    RunStats,
    StatePayload,
    parse_ts,
    utcnow,
)
from autoapply.paths import Paths

log = logging.getLogger("autoapply.pipeline")

USER_AGENT = "AutoApply/0.1 (personal job search assistant; read-only)"


# =====================================================================================
# Seams
# =====================================================================================


@dataclass(slots=True)
class SubmitCheck:
    """Result of the final gate before ``begin_submit``."""

    allowed: bool
    cap: CapKind | None = None
    reason: str | None = None
    used: int = 0
    limit: int = 0
    resets_at: datetime | None = None


#: Set while work runs outside any pipeline run (approved submits): transitions get no run
#: id, run stats are not bumped and the run's ``run_id`` is not stamped on events.
_DETACHED: contextvars.ContextVar[bool] = contextvars.ContextVar("autoapply_pipeline_detached", default=False)


# =====================================================================================
# Guardrail queries (attempts whose outcome is unknown count like submissions)
# =====================================================================================


# Shared with ``answers.guardrails.check_submit_allowed``; re-exported for callers/tests.
unconfirmed_attempts_today = db.unconfirmed_attempts_today
attempts_used_today = db.attempts_used_today
company_attempt_at = db.company_attempt_at


async def _maybe_await(value: Any) -> Any:
    return await value if inspect.isawaitable(value) else value


def _default_hard_filter(conn: sqlite3.Connection, job: Job, company: Company, prefs: Preferences) -> str | None:
    from autoapply import scoring

    return scoring.hard_filter(conn, job, company, prefs)


async def _default_score_jobs(llm: LLMProvider, *, profile: Any, preferences: Preferences, jobs: list[tuple[Job, Company]]) -> list[Any]:
    from autoapply import scoring

    return await scoring.score_jobs(llm, profile=profile, preferences=preferences, jobs=jobs)


async def _default_run_prep(conn: sqlite3.Connection, *, llm: LLMProvider, adapters: list[Adapter], emit: EmitFn,
                            application_ids: list[int] | None = None, **kw: Any) -> Any:
    from autoapply import prep

    return await prep.run_prep(conn, llm=llm, adapters=adapters, emit=emit, application_ids=application_ids, **kw)


def _default_pick_resume(conn: sqlite3.Connection, job: Job) -> Any:
    from autoapply.answers import resume_picker

    return resume_picker.pick_resume(conn, job)


async def _default_refresh_easy_apply(conn: sqlite3.Connection, llm: LLMProvider, job_id: int) -> Any:
    from autoapply import easy_apply

    return await easy_apply.refresh_easy_apply(conn, llm, job_id)


def _default_cluster_questions(conn: sqlite3.Connection) -> Any:
    from autoapply import prep
    from autoapply.answers.memory import AnswerMemory

    return AnswerMemory(conn).cluster_open_questions(threshold=prep.CLUSTER_THRESHOLD)


def _default_park(conn: sqlite3.Connection, job_id: int, unresolved: list[UnresolvedField]) -> Any:
    """B's ``prep.park_unresolved``: joins semantically equivalent open clusters."""
    from autoapply import prep

    return prep.park_unresolved(conn, job_id, unresolved)


def _default_is_deferral(reason: str | None) -> bool:
    from autoapply import scoring

    return bool(getattr(scoring, "is_deferral", lambda _r: False)(reason))


@dataclass(slots=True)
class PipelineHooks:
    """Workstream A/B entry points. Sync or async callables are both accepted."""

    hard_filter: Callable[..., Any] = _default_hard_filter
    score_jobs: Callable[..., Any] = _default_score_jobs
    run_prep: Callable[..., Any] = _default_run_prep
    pick_resume: Callable[..., Any] = _default_pick_resume
    refresh_easy_apply: Callable[..., Any] = _default_refresh_easy_apply
    cluster_questions: Callable[..., Any] = _default_cluster_questions
    park: Callable[..., Any] = _default_park
    is_deferral: Callable[[str | None], bool] = _default_is_deferral


def basic_hard_filter(conn: sqlite3.Connection, job: Job, company: Company, prefs: Preferences) -> str | None:
    """Conservative local fallback used only while ``scoring.hard_filter`` is a stub."""
    name = db.normalize_text(company.name)
    if any(db.normalize_text(c) == name for c in prefs.exclude_companies if c.strip()):
        return f"excluded_company:{company.name}"
    hay = f" {db.normalize_text(job.title)} {db.normalize_text(job.description)} "
    for kw in prefs.exclude_keywords:
        k = db.normalize_text(kw)
        if k and f" {k} " in hay:
            return f"excluded_keyword:{kw}"
    if prefs.hide_without_salary and job.salary_min is None and job.salary_max is None:
        return "no_salary"
    if prefs.salary_floor is not None:
        top = job.salary_max or job.salary_min
        same_currency = not job.salary_currency or job.salary_currency == prefs.salary_currency
        if top is not None and same_currency and top < prefs.salary_floor:
            return "below_salary_floor"
    if job.remote is not None and prefs.remote_policy and RemotePolicy(job.remote) not in prefs.remote_policy:
        return f"remote_policy:{RemotePolicy(job.remote).value}"
    if db.company_in_cooldown(conn, company.id, prefs.per_company_cooldown_days):
        return "company_cooldown"
    return None


#: A run keeps searching (up to ``MAX_EXTRA_ROUNDS`` deeper rounds) until this many jobs are queued.
MIN_MATCHES_PER_RUN = int(os.environ.get("AUTOAPPLY_MIN_MATCHES", "3"))
MAX_EXTRA_ROUNDS = 2
#: Jobs scoring within this many points below the threshold are kept as "borderline" and the best of
#: them fill the quota when the run would otherwise end with fewer than ``MIN_MATCHES_PER_RUN``.
BORDERLINE_BAND = 15

RUN_STEPS: dict[RunKind, tuple[str, ...]] = {
    RunKind.FULL: ("discover", "score", "prep", "apply"),
    RunKind.DISCOVER: ("discover", "score"),
    RunKind.PREP: ("prep",),
    RunKind.APPLY: ("apply",),
}


#: SubmitCheck reason: the company is held by an attempt whose outcome is unknown.
COMPANY_ATTEMPT_PENDING = "company_attempt_unconfirmed"


def skip_tag(reason: str | None, score: int | None = None, threshold: int | None = None) -> str:
    """Short human reason for a skipped job ("too senior (staff)", "match 40 < 70", ...)."""
    key, _, detail = (reason or "").partition(":")
    if key == "below_threshold":
        return f"match {score} is below your {threshold}" if score is not None and threshold is not None else "match below your threshold"
    table = {
        "seniority_mismatch": f"too senior ({detail})" if detail in ("staff", "principal", "executive", "lead") else f"seniority mismatch ({detail})" if detail else "seniority mismatch",
        "excluded_keyword": f"excluded keyword '{detail}'",
        "excluded_company": f"excluded company {detail}".strip(),
        "salary_below_floor": "salary below your floor",
        "missing_salary": "no salary listed",
        "location_mismatch": "location doesn't match",
        "work_auth": "needs work authorization you don't have" if detail == "no_sponsorship" else "work authorization",
        "remote_policy": f"{detail} roles not wanted" if detail else "work-style mismatch",
        "company_cooldown": "applied to this company recently",
        "daily_cap_reached": "daily application cap reached",
        "no_apply_url": "no company apply link (LinkedIn/Glassdoor only)",
        "unscored": "couldn't be scored",
    }
    return table.get(key) or (reason or "other").replace("_", " ")


class CapReached(Exception):
    """The daily cap stopped the apply step."""


# =====================================================================================
# Pipeline
# =====================================================================================


class Pipeline:
    def __init__(
        self,
        conn: sqlite3.Connection,
        *,
        paths: Paths,
        llm: LLMProvider,
        sources: list[Source],
        adapters: list[Adapter],
        emit: EmitFn,
        is_paused: Callable[[], bool] | None = None,
        hooks: PipelineHooks | None = None,
        http: httpx.AsyncClient | None = None,
        headless: bool = True,
        captcha_wait_s: float = 300.0,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.conn = conn
        self.paths = paths
        self.llm = llm
        self.sources = list(sources)
        self.adapters = list(adapters)
        self._emit = emit
        self.is_paused = is_paused or (lambda: bool(db.get_meta(conn, db.META_PAUSED, False)))
        self.hooks = hooks or PipelineHooks()
        self._http = http
        self.headless = headless
        #: Seconds to wait for the user in a visible window after a headless CAPTCHA (0 disables).
        self.captcha_wait_s = captcha_wait_s
        self.notifier: Any = None  # set by the daemon (autoapply.notify.Notifier)
        self._now = now or utcnow
        self.run_row: Run | None = None
        self.stats = RunStats()
        self._borderline: list[tuple[int, int, int]] = []  # (application_id, job_id, score), still SCORED
        self._best_score: int | None = None
        self._usage0 = llm.usage.snapshot()
        self._missing_warned: set[str] = set()
        #: One holder at a time for anything that drives the shared agent Chrome profile
        #: (runs, approved submits, the daemon's source-connect window): Chromium allows a
        #: single process per user-data-dir.
        self.browser_lock = asyncio.Lock()

    # ---- emit helpers ------------------------------------------------------------------

    async def emit(self, type_: str, payload: BaseModel | dict[str, Any]) -> None:
        try:
            await self._emit(type_, payload)
        except Exception:  # noqa: BLE001 - a broken client must never break a run
            log.exception("emit %s failed", type_)

    @property
    def _in_run(self) -> bool:
        return self.run_row is not None and not _DETACHED.get()

    @property
    def run_uid(self) -> str | None:
        return self.run_row.run_uid if self._in_run else None  # type: ignore[union-attr]

    @property
    def _run_db_id(self) -> int | None:
        return self.run_row.id if self._in_run else None  # type: ignore[union-attr]

    async def _log(self, level: LogLevel, message: str, *, job_id: int | None = None, application_id: int | None = None) -> None:
        log.log(
            {LogLevel.DEBUG: logging.DEBUG, LogLevel.INFO: logging.INFO, LogLevel.WARNING: logging.WARNING}.get(level, logging.ERROR),
            message,
        )
        await self.emit(
            "log",
            LogPayload(level=level, message=message, logger=log.name, job_id=job_id, application_id=application_id, at=self._now()),
        )

    async def _not_implemented(self, what: str) -> None:
        if what not in self._missing_warned:
            self._missing_warned.add(what)
            await self._log(LogLevel.WARNING, f"{what} is not implemented yet; skipping")

    async def _state(
        self,
        activity: DaemonActivity,
        message: str | None = None,
        *,
        progress: tuple[int, int] | None = None,
        application_id: int | None = None,
        job_id: int | None = None,
    ) -> None:
        await self.emit(
            "state",
            StatePayload(
                daemon=activity, paused=bool(self.is_paused()), run_id=self.run_uid,
                progress=Progress(done=progress[0], total=progress[1]) if progress else None,
                message=message, active_application_id=application_id, active_job_id=job_id,
            ),
        )

    def _check_pause(self) -> None:
        if self.is_paused():
            raise PausedError("paused by user")

    async def _transition(
        self,
        application_id: int,
        to: AppState,
        *,
        reason: str | None = None,
        actor: Actor = Actor.AGENT,
        expected_from: AppState | Iterable[AppState] | None = None,
    ) -> db.Transition:
        t = db.transition(
            self.conn, application_id, to, reason=reason, actor=actor, expected_from=expected_from,
            run_id=self._run_db_id,
        )
        await self.emit_transition(t)
        return t

    async def emit_transition(self, t: db.Transition) -> None:
        bump = {
            AppState.SKIPPED: "skipped", AppState.QUEUED: "queued", AppState.NEEDS_YOU: "needs_you",
            AppState.AWAITING_REVIEW: "awaiting_review", AppState.SUBMITTED: "submitted", AppState.FAILED: "failed",
        }.get(t.to_state)
        if bump and self._in_run:
            setattr(self.stats, bump, getattr(self.stats, bump) + 1)
        await self.emit("application_state", t.to_payload())

    # ---- run lifecycle -----------------------------------------------------------------

    async def begin(self, kind: RunKind = RunKind.FULL, trigger: RunTrigger = RunTrigger.MANUAL) -> Run:
        """Create the run row (raises ``db.Conflict`` if one is active) and emit ``run_started``."""
        run = db.start_run(self.conn, kind, trigger)
        self.run_row = run
        self.stats = RunStats()
        self._borderline = []
        self._best_score = None
        self._usage0 = self.llm.usage.snapshot()
        await self.emit("run_started", RunStartedPayload(run=db.run_info(run)))
        return run

    async def execute(self, run: Run) -> RunInfo:
        """Run the steps for ``run.kind``; always finishes the run row and emits ``run_finished``."""
        self.run_row = run
        outcome = RunOutcome.COMPLETED
        try:
            async with self.browser_lock:  # waits for an approved-submit batch / connect window
                for step in RUN_STEPS[run.kind]:
                    self._check_pause()
                    await getattr(self, f"_step_{step}")()
            await self.maintenance()
        except PausedError:
            outcome = RunOutcome.PAUSED
            await self._log(LogLevel.INFO, "run paused")
        except CapReached:
            outcome = RunOutcome.CAP_REACHED
        except asyncio.CancelledError:
            self._finish(run, RunOutcome.FAILED)
            raise
        except Exception as e:  # noqa: BLE001
            log.exception("run %s failed", run.run_uid)
            outcome = RunOutcome.FAILED
            await self.emit("error", ErrorPayload(code="internal", message=f"Run failed: {e}", details={"run_id": run.run_uid}))
        finished = self._finish(run, outcome)
        info = db.run_info(finished)
        await self.emit("run_finished", RunFinishedPayload(run=info))
        await self._state(DaemonActivity.IDLE, f"Run {outcome.value}")
        return info

    def _finish(self, run: Run, outcome: RunOutcome) -> Run:
        usage = self.llm.usage.since(self._usage0)
        finished = db.finish_run(
            self.conn, run.run_uid, outcome=outcome, stats=self.stats,
            tokens_in=usage.input_tokens, tokens_out=usage.output_tokens,
        )
        self.run_row = None
        return finished

    async def run(self, kind: RunKind = RunKind.FULL, trigger: RunTrigger = RunTrigger.MANUAL) -> RunInfo:
        return await self.execute(await self.begin(kind, trigger))

    def live_run_info(self) -> RunInfo | None:
        """Current run with live (not yet persisted) stats, for the daemon snapshot."""
        if self.run_row is None:
            return None
        usage = self.llm.usage.since(self._usage0)
        info = db.run_info(self.run_row)
        return info.model_copy(update={"stats": self.stats.model_copy(), "tokens_in": usage.input_tokens, "tokens_out": usage.output_tokens})

    async def _step_discover(self) -> None:
        await self.discover()

    async def _step_score(self) -> None:
        """Score, and keep searching deeper while the run has found fewer than the quota of matches."""
        await self.score(settle=False)
        for rnd in range(1, MAX_EXTRA_ROUNDS + 1):
            # Jobs already waiting in the queue from earlier runs count toward the quota too.
            if self._ready_count() >= MIN_MATCHES_PER_RUN:
                break
            self._check_pause()
            await self._log(
                LogLevel.INFO,
                f"Only {self._ready_count()} match(es) ready so far (goal {MIN_MATCHES_PER_RUN}); searching deeper (round {rnd}/{MAX_EXTRA_ROUNDS})",
            )
            if not await self.discover(round_=rnd):
                await self._log(LogLevel.INFO, "No new listings found in the deeper search; stopping the search here")
                break
            await self.score(settle=False)
        await self._settle_borderline()
        await self._run_summary()

    def _ready_count(self) -> int:
        """Jobs ready to apply (queued now, from this run or earlier ones)."""
        return len(db.list_applications(self.conn, states=[AppState.QUEUED]))

    async def _settle_borderline(self) -> None:
        """Fill the quota with the best near-misses (review mode only), skip the rest."""
        prefs = db.get_preferences(self.conn)
        need = max(0, MIN_MATCHES_PER_RUN - self._ready_count())
        ranked = sorted(self._borderline, key=lambda t: t[2], reverse=True)
        for i, (app_id, job_id, score) in enumerate(ranked):
            job = db.get_job(self.conn, job_id)
            who = f"{job.title} · {db.get_company(self.conn, job.company_id).name}"
            if i < need:
                db.set_job_mode_override(self.conn, job_id, Mode.REVIEW)  # near-misses never auto-submit
                await self._transition(app_id, AppState.QUEUED, reason=f"best available: match {score} (threshold {prefs.match_threshold})")
                await self._log(
                    LogLevel.INFO, f"Queued {who} as a near-miss (match {score}, your bar is {prefs.match_threshold}) - needs your review",
                    job_id=job_id, application_id=app_id,
                )
            else:
                await self._transition(app_id, AppState.SKIPPED, reason="below_threshold")
                await self._log(
                    LogLevel.INFO, f"Skipped {who}: {skip_tag('below_threshold', score, prefs.match_threshold)}",
                    job_id=job_id, application_id=app_id,
                )
        self._borderline = []

    async def _run_summary(self) -> None:
        prefs = db.get_preferences(self.conn)
        best = f"; best match was {self._best_score}" if self._best_score is not None else ""
        msg = f"Search summary: {self.stats.discovered} new listings, {self.stats.queued} queued{best}"
        if self._ready_count() < MIN_MATCHES_PER_RUN:
            msg += f". Fewer than {MIN_MATCHES_PER_RUN} matched your bar of {prefs.match_threshold}; consider lowering it or adding roles"
        await self._log(LogLevel.INFO, msg)

    async def _step_prep(self) -> None:
        await self.prep()

    async def _step_apply(self) -> None:
        await self.apply_queued()

    # ---- discover ----------------------------------------------------------------------

    def _enabled_sources(self, prefs: Preferences) -> list[Source]:
        return [s for s in self.sources if prefs.sources_enabled.get(str(getattr(s.name, "value", s.name)), False)]

    async def discover(self, round_: int = 0) -> list[int]:
        """Returns new job ids. ``round_`` > 0 = a deeper pass: only the browser sources, on the next search URLs."""
        prefs = db.get_preferences(self.conn)
        sources = self._enabled_sources(prefs)
        if round_ > 0:
            sources = [s for s in sources if hasattr(s, "browser_factory")]
        companies = db.list_companies(self.conn, watch_only=True)
        new_ids: list[int] = []
        own_client = self._http is None
        http = self._http or httpx.AsyncClient(timeout=20.0, follow_redirects=True, headers={"User-Agent": USER_AGENT})
        try:
            done = 0

            async def run_source(src: Source) -> None:
                nonlocal done
                self._check_pause()
                name = str(getattr(src.name, "value", src.name))
                await self._state(DaemonActivity.DISCOVERING, f"Reading {name}", progress=(done, len(sources)))
                ctx = DiscoveryContext(preferences=prefs, companies=companies, http=http, run_id=self.run_uid, round=round_)
                try:
                    found = await src.discover(ctx)
                except NotImplementedError:
                    await self._not_implemented(f"discovery source {name!r}")
                    return
                except PausedError:
                    raise
                except Exception as e:  # noqa: BLE001 - one bad source never aborts the run
                    log.exception("source %s failed", name)
                    await self._log(LogLevel.ERROR, f"{name} discovery failed: {e}")
                    return
                fresh = 0
                for dj in found:
                    jid = await self._persist(dj)
                    if jid is not None:
                        new_ids.append(jid)
                        fresh += 1
                done += 1
                await self._log(LogLevel.INFO, f"{name}: {len(found)} listings read, {fresh} new")
                for who, why in (ctx.errors or {}).items():
                    await self._log(LogLevel.WARNING, f"{name} · {who}: {why}")

            async def browser_chain(items: list[Source]) -> None:
                for src in items:
                    await run_source(src)

            # LinkedIn/Glassdoor drive one shared Chrome profile at human pace, so they stay sequential
            # (one window, one site at a time). Plain-HTTP job boards touch other hosts and run alongside.
            browser_sources = [s for s in sources if hasattr(s, "browser_factory")]
            http_sources = [s for s in sources if not hasattr(s, "browser_factory")]
            outcomes = await asyncio.gather(
                browser_chain(browser_sources), *(run_source(s) for s in http_sources), return_exceptions=True,
            )
            for outcome in outcomes:
                if isinstance(outcome, BaseException):
                    raise outcome
            await self._state(DaemonActivity.DISCOVERING, f"Found {len(new_ids)} new jobs", progress=(len(sources), len(sources)))
        finally:
            if own_client:
                await http.aclose()
        return new_ids

    async def _persist(self, dj: DiscoveredJob) -> int | None:
        try:
            enrich: dict[str, Any] = {}
            if dj.board_token and dj.ats in (Ats.GREENHOUSE, Ats.LEVER, Ats.ASHBY):
                enrich = {"ats": dj.ats, "board_token": dj.board_token}
            company = db.upsert_company(self.conn, dj.company_name, domain=dj.company_domain, **enrich)
            job, created = db.insert_job(
                self.conn, company_id=company.id, source=dj.source, title=dj.title, location=dj.location,
                apply_url=dj.apply_url, source_url=dj.source_url, ats=dj.ats, external_id=dj.external_id,
                remote=dj.remote.value if dj.remote else None, salary_min=dj.salary_min, salary_max=dj.salary_max,
                salary_currency=dj.salary_currency, description=dj.description, posted_at=dj.posted_at,
                easy_apply=dj.easy_apply, raw=dj.raw,
            )
        except (ValueError, sqlite3.IntegrityError) as e:
            await self._log(LogLevel.WARNING, f"could not save {dj.company_name} · {dj.title}: {e}")
            return None
        if not created:
            return None
        if dj.easy_apply:
            url = dj.source_url or dj.apply_url
            if url:
                db.upsert_easy_apply(self.conn, job.id, url=url)
        self.stats.discovered += 1
        await self.emit("job_discovered", JobDiscoveredPayload(job=db.job_summary(self.conn, job.id), run_id=self.run_uid))
        return job.id

    # ---- score -------------------------------------------------------------------------

    async def _hard_filter(self, job: Job, company: Company, prefs: Preferences) -> str | None:
        try:
            return await _maybe_await(self.hooks.hard_filter(self.conn, job, company, prefs))
        except NotImplementedError:
            await self._not_implemented("scoring.hard_filter (using the basic local filter)")
            return basic_hard_filter(self.conn, job, company, prefs)

    def _dismiss_easy_apply(self, job: Job) -> None:
        """A skipped Easy Apply job leaves the manual list."""
        if job.easy_apply:
            try:
                db.dismiss_easy_apply(self.conn, job.id)
            except db.NotFound:
                pass

    async def score(self, settle: bool = True) -> None:
        """Score discovered jobs. ``settle=False`` keeps near-misses pending (a run decides them at its end)."""
        await self._score_pass()
        if settle:
            await self._settle_borderline()

    async def _score_pass(self) -> None:
        prefs = db.get_preferences(self.conn)
        profile = db.get_profile(self.conn)
        apps = db.list_applications(self.conn, states=[AppState.DISCOVERED])
        total = len(apps)
        survivors: list[tuple[Job, Company]] = []
        app_by_job: dict[int, Application] = {}
        await self._state(DaemonActivity.SCORING, f"Scoring {total} jobs", progress=(0, total))
        done = 0
        for app in apps:
            self._check_pause()
            job = db.get_job(self.conn, app.job_id)
            company = db.get_company(self.conn, job.company_id)
            app_by_job[job.id] = app
            if not job.easy_apply and not job.apply_url and job.source in ("linkedin", "glassdoor") and job.source_url:
                # No company apply link could be read: don't drop a possibly good job. It goes to the manual
                # list (like Easy Apply): scored normally, and you apply yourself from the listing link.
                job = db.update_job(self.conn, job.id, easy_apply=True)
                db.upsert_easy_apply(self.conn, job.id, url=job.source_url)
                await self._log(
                    LogLevel.INFO, f"{job.title} · {company.name}: no company apply link found, listed under Easy Apply for you to apply manually",
                    job_id=job.id, application_id=app.id,
                )
            if not job.easy_apply and not job.apply_url:
                reason: str | None = "no_apply_url"
            else:
                reason = await self._hard_filter(job, company, prefs)
            if reason and self.hooks.is_deferral(reason):
                continue  # "not now" (e.g. daily cap): stays discovered for a later run
            if reason:
                db.upsert_score(self.conn, job.id, score=None, skip_reason=reason)
                await self._transition(app.id, AppState.SKIPPED, reason=reason, expected_from=AppState.DISCOVERED)
                self._dismiss_easy_apply(job)
                self.stats.scored += 1
                done += 1
                await self.emit(
                    "job_scored",
                    JobScoredPayload(job_id=job.id, application_id=app.id, score=None, skip_reason=reason, queued=False, run_id=self.run_uid),
                )
                await self._log(
                    LogLevel.INFO, f"Skipped {job.title} · {company.name}: {skip_tag(reason, None, prefs.match_threshold)}",
                    job_id=job.id, application_id=app.id,
                )
            else:
                survivors.append((job, company))
        if not survivors:
            return
        self._check_pause()
        try:
            results = await _maybe_await(self.hooks.score_jobs(self.llm, profile=profile, preferences=prefs, jobs=survivors))
        except NotImplementedError:
            await self._not_implemented("scoring.score_jobs (jobs stay 'discovered' until it is)")
            return
        by_job = {r.job_id: r for r in results}
        for job, _company in survivors:
            r = by_job.get(job.id)
            app = app_by_job[job.id]
            if r is None or getattr(r, "error", None):
                # LLM failure: stays 'discovered' and is retried next run.
                why = getattr(r, "error", None) or "no score returned"
                await self._log(LogLevel.WARNING, f"scoring failed for job {job.id}: {why}", job_id=job.id, application_id=app.id)
                continue
            db.upsert_score(
                self.conn, job.id, score=r.score, reasons=r.reasons, skip_reason=r.skip_reason,
                model=getattr(r, "model", None) or getattr(self.llm, "model", None), tokens_in=r.tokens_in, tokens_out=r.tokens_out,
            )
            if r.tokens_in or r.tokens_out:
                db.add_application_tokens(self.conn, app.id, r.tokens_in, r.tokens_out)
            self.stats.scored += 1
            done += 1
            passed = r.score is not None and r.skip_reason is None and r.score >= prefs.match_threshold
            queued = False
            borderline = False
            if r.score is None:
                reason = r.skip_reason or "unscored"
                await self._transition(app.id, AppState.SKIPPED, reason=reason, expected_from=AppState.DISCOVERED)
                self._dismiss_easy_apply(job)
            else:
                await self._transition(app.id, AppState.SCORED, reason=f"score {r.score}", expected_from=AppState.DISCOVERED)
                if job.easy_apply:
                    # Easy Apply jobs are NEVER queued for the agent; the user applies manually.
                    if passed:
                        await self._draft_easy_apply(job)
                    else:
                        reason = r.skip_reason or "below_threshold"
                        await self._transition(app.id, AppState.SKIPPED, reason=reason)
                        self._dismiss_easy_apply(job)
                elif passed:
                    await self._transition(app.id, AppState.QUEUED, reason=f"score {r.score} >= {prefs.match_threshold}")
                    queued = True
                elif (
                    r.skip_reason in (None, "below_threshold") and r.score is not None
                    and prefs.match_threshold - BORDERLINE_BAND <= r.score < prefs.match_threshold
                ):
                    borderline = True  # stays SCORED; the run's quota decides at the end (_settle_borderline)
                    self._borderline.append((app.id, job.id, r.score))
                else:
                    await self._transition(app.id, AppState.SKIPPED, reason=r.skip_reason or "below_threshold")
            if r.score is not None and (self._best_score is None or r.score > self._best_score):
                self._best_score = r.score
            who = f"{job.title} · {db.get_company(self.conn, job.company_id).name}"
            if queued:
                await self._log(LogLevel.INFO, f"Queued {who}: match {r.score}", job_id=job.id, application_id=app.id)
            elif borderline:
                await self._log(
                    LogLevel.INFO, f"Near-miss {who}: match {r.score} (bar {prefs.match_threshold}); kept in case the run finds too few",
                    job_id=job.id, application_id=app.id,
                )
            elif not (passed and job.easy_apply):
                why = r.skip_reason or ("below_threshold" if not passed else None)
                if why:
                    await self._log(
                        LogLevel.INFO, f"Skipped {who}: {skip_tag(why, r.score, prefs.match_threshold)}",
                        job_id=job.id, application_id=app.id,
                    )
            await self.emit(
                "job_scored",
                JobScoredPayload(
                    job_id=job.id, application_id=app.id, score=r.score, reasons=r.reasons,
                    skip_reason=None if (passed or borderline) else r.skip_reason, queued=queued, run_id=self.run_uid,
                ),
            )
            await self._state(DaemonActivity.SCORING, f"Scored {done}/{total}", progress=(done, total))

    async def _draft_easy_apply(self, job: Job) -> None:
        try:
            await _maybe_await(self.hooks.refresh_easy_apply(self.conn, self.llm, job.id))
        except NotImplementedError:
            await self._not_implemented("easy_apply.refresh_easy_apply")
        except Exception as e:  # noqa: BLE001
            await self._log(LogLevel.WARNING, f"could not draft Easy Apply answers: {e}", job_id=job.id)

    # ---- prep --------------------------------------------------------------------------

    async def _skip_if_stale(self, app: Application, job: Job, company: Company, prefs: Preferences) -> bool:
        """Re-run the cheap filters on a queued job: one queued before a preference change or a filter
        fix must not be prepped or applied to. "Apply anyway" (user_* reasons) is exempt."""
        if (app.state_reason or "").startswith("user_"):
            return False
        stale = await self._hard_filter(job, company, prefs)
        if not stale or self.hooks.is_deferral(stale) or stale == "company_cooldown":
            return False
        await self._transition(app.id, AppState.SKIPPED, reason=stale, expected_from=(AppState.QUEUED, AppState.NEEDS_YOU))
        if app.state is AppState.NEEDS_YOU:
            db.remove_job_from_questions(self.conn, job.id)  # its inbox questions no longer need answers
        await self._log(
            LogLevel.INFO, f"Skipped {job.title} · {company.name} before applying: {skip_tag(stale)}",
            job_id=job.id, application_id=app.id,
        )
        return True

    async def _recheck_queue(self) -> None:
        prefs = db.get_preferences(self.conn)
        for app in db.list_applications(self.conn, states=[AppState.QUEUED, AppState.NEEDS_YOU]):
            job = db.get_job(self.conn, app.job_id)
            await self._skip_if_stale(app, job, db.get_company(self.conn, job.company_id), prefs)

    async def auto_resolve_inbox(self) -> int:
        """Clear Needs-You questions that stored facts now answer; parked jobs go back to the queue."""
        try:
            from autoapply import prep as _prep

            outcomes = _prep.auto_resolve_known(self.conn)
        except Exception:  # noqa: BLE001 - never block a run on this
            log.warning("auto-resolving inbox questions failed", exc_info=True)
            return 0
        for o in outcomes:
            await self.emit("question_resolved", o.to_payload())
            for t in o.transitions:
                await self.emit("application_state", t.to_payload())
        if outcomes:
            await self._log(LogLevel.INFO, f"Answered {len(outcomes)} Needs-You question(s) from what you've already told AutoApply")
        return len(outcomes)

    async def prep(self, application_ids: list[int] | None = None) -> Any:
        await self.auto_resolve_inbox()
        await self._recheck_queue()
        await self._state(DaemonActivity.PREPPING, "Collecting application questions")
        try:
            report = await _maybe_await(
                self.hooks.run_prep(
                    self.conn, llm=self.llm, adapters=self.adapters, emit=self.emit, application_ids=application_ids,
                    is_paused=self.is_paused, run_id=self.run_uid, run_row_id=self._run_db_id,
                )
            )
        except NotImplementedError:
            await self._not_implemented("prep.run_prep")
            return None
        parked = getattr(report, "parked_jobs", None) or []
        self.stats.needs_you += len(parked)
        if getattr(report, "paused", False):
            raise PausedError("paused by user")
        return report

    # ---- apply -------------------------------------------------------------------------

    async def apply_queued(self) -> None:
        apps = db.list_applications(self.conn, states=[AppState.QUEUED])
        total = len(apps)
        for i, app in enumerate(apps):
            self._check_pause()
            prefs = db.get_preferences(self.conn)
            used = attempts_used_today(self.conn, self._now())
            if used >= prefs.daily_cap:
                await self.emit(
                    "cap_reached",
                    CapReachedPayload(cap=CapKind.DAILY, used=used, limit=prefs.daily_cap, resets_at=db.local_day_start(self._now()) + timedelta(days=1)),
                )
                await self._log(LogLevel.INFO, f"daily cap reached ({used}/{prefs.daily_cap}); {total - i} jobs stay queued")
                raise CapReached()
            await self.apply_one(app.id, progress=(i, total))

    def _cooldown_check(
        self, company: Company, prefs: Preferences, *, application_id: int | None = None,
    ) -> SubmitCheck | None:
        now = self._now()
        reason = "company_cooldown"
        if db.company_in_cooldown(self.conn, company.id, prefs.per_company_cooldown_days, now):
            last = parse_ts(company.last_applied_at) if company.last_applied_at else now
        else:
            # Not confirmed: another application here is mid-submit or unverified. Block, but
            # callers keep the job queued (if that one turns out "not sent", this one may go).
            reason = COMPANY_ATTEMPT_PENDING
            attempt = company_attempt_at(
                self.conn, company.id, prefs.per_company_cooldown_days, now, exclude_application_id=application_id,
            )
            if attempt is None:
                return None
            last = min(attempt, now)
        return SubmitCheck(
            allowed=False, cap=CapKind.COMPANY_COOLDOWN, reason=reason,
            used=max(0, (now - last).days), limit=prefs.per_company_cooldown_days,
            resets_at=last + timedelta(days=prefs.per_company_cooldown_days),
        )

    def submit_gate(
        self, job: Job, prefs: Preferences, *, pending: int = 0, application_id: int | None = None,
    ) -> SubmitCheck:
        """Final guardrail immediately before ``db.begin_submit``: pause, daily cap, cooldown.

        The cap counts confirmed submissions plus every attempt whose outcome is unknown
        (``submitting`` / ``unknown_verify``), and the cooldown is also held by such attempts
        at the same company, so concurrent paths (a run and a background approve batch) and
        unverifiable submits can never exceed either guardrail. ``pending`` = submissions
        already committed to in the same check-then-begin batch (approve).
        """
        if self.is_paused():
            return SubmitCheck(allowed=False, reason="paused")
        used = attempts_used_today(self.conn, self._now()) + pending
        if used >= prefs.daily_cap:
            return SubmitCheck(
                allowed=False, cap=CapKind.DAILY, reason="daily_cap", used=used, limit=prefs.daily_cap,
                resets_at=db.local_day_start(self._now()) + timedelta(days=1),
            )
        company = db.get_company(self.conn, job.company_id)
        cooldown = self._cooldown_check(company, prefs, application_id=application_id)
        if cooldown is not None:
            return cooldown
        return SubmitCheck(allowed=True)

    async def emit_cap(self, check: SubmitCheck, company_id: int | None = None) -> None:
        if check.cap is None:
            return
        await self.emit(
            "cap_reached",
            CapReachedPayload(
                cap=check.cap, used=check.used, limit=check.limit, resets_at=check.resets_at,
                company_id=company_id if check.cap is CapKind.COMPANY_COOLDOWN else None,
            ),
        )

    def _select_adapter(self, job: Job) -> Adapter | None:
        for a in self.adapters:
            try:
                if a.can_handle(job):
                    return a
            except NotImplementedError:
                continue
            except Exception:  # noqa: BLE001
                log.exception("adapter %r can_handle failed", a)
        return None

    def _pick_resume(self, job: Job) -> tuple[int | None, float | None]:
        try:
            pick = self.hooks.pick_resume(self.conn, job)
        except NotImplementedError:
            pick = None
            variants = db.list_resume_variants(self.conn, enabled_only=True)
            if variants:
                return variants[0].id, None  # default first (list is is_default DESC)
        except Exception:  # noqa: BLE001
            log.exception("resume pick failed")
            pick = None
        if pick is None:
            return None, None
        return pick.variant.id, float(pick.score)

    def build_context(self, application_id: int, *, extra: dict[str, Any] | None = None) -> ApplyContext:
        app = db.get_application(self.conn, application_id)
        job = db.get_job(self.conn, app.job_id)
        resume = None
        if app.resume_variant_id is not None:
            try:
                resume = db.get_resume_variant(self.conn, app.resume_variant_id)
            except db.NotFound:
                resume = None
        return ApplyContext(
            conn=self.conn, application=app, job=job, profile=db.get_profile(self.conn),
            never_guess=db.get_never_guess(self.conn), preferences=db.get_preferences(self.conn), llm=self.llm,
            resume=resume, screenshots_dir=self.paths.application_screenshot_dir(app.id), emit=self.emit,
            is_paused=self.is_paused, headless=self.headless, run_id=self.run_uid, extra=dict(extra or {}),
        )

    async def apply_one(self, application_id: int, *, progress: tuple[int, int] | None = None) -> AppState:
        """Fill (and, in auto mode, submit) one queued application. Returns the final state."""
        app = db.get_application(self.conn, application_id)
        if app.state is not AppState.QUEUED:
            return app.state
        job = db.get_job(self.conn, app.job_id)
        company = db.get_company(self.conn, job.company_id)
        prefs = db.get_preferences(self.conn)
        self._check_pause()

        cooldown = self._cooldown_check(company, prefs, application_id=app.id)
        if cooldown is not None:
            await self.emit_cap(cooldown, company.id)
            if cooldown.reason == COMPANY_ATTEMPT_PENDING:
                await self._log(
                    LogLevel.INFO, f"{company.name}: another application is unverified; keeping {job.title} queued",
                    job_id=job.id, application_id=app.id,
                )
                return AppState.QUEUED
            await self._transition(app.id, AppState.SKIPPED, reason="company_cooldown", expected_from=AppState.QUEUED)
            return AppState.SKIPPED

        # Re-check the cheap filters right before applying: a job queued earlier may no longer pass
        # after a preference change or a filter fix (location, seniority, excludes, salary).
        if await self._skip_if_stale(app, job, company, prefs):
            return AppState.SKIPPED

        adapter = self._select_adapter(job)
        if adapter is None:
            await self._transition(app.id, AppState.FAILED, reason="no_adapter", expected_from=AppState.QUEUED)
            return AppState.FAILED

        mode = prefs.effective_mode(job.ats, company.id, job.mode_override)
        variant_id, pick_score = self._pick_resume(job)
        fields: dict[str, Any] = {"mode": mode.value}
        if variant_id is not None:
            fields.update(resume_variant_id=variant_id, resume_pick_score=pick_score)
        db.update_application(self.conn, app.id, **fields)

        await self._transition(app.id, AppState.FILLING, expected_from=AppState.QUEUED)
        await self._state(
            DaemonActivity.APPLYING, f"Filling {company.name} · {job.title}", progress=progress,
            application_id=app.id, job_id=job.id,
        )
        ctx = self.build_context(app.id)
        try:
            return await self._fill_and_submit(app, job, company, mode, adapter, ctx)
        finally:
            # Whatever happened (needs-you, review, gate blocked, error, pause, submitted),
            # never leave the adapter's browser / agent session behind: an open agentic
            # session keeps the shared Chrome profile locked.
            await self._release_session(adapter, ctx)

    async def _release_session(self, adapter: Adapter, ctx: ApplyContext) -> None:
        try:
            await close_session(ctx)
        except Exception:  # noqa: BLE001 - best effort
            log.warning("closing the browser session for application %s failed", ctx.application.id, exc_info=True)
        closer = getattr(adapter, "close", None)
        if closer is None:
            return
        try:
            await _maybe_await(closer(ctx.application.id))
        except Exception:  # noqa: BLE001 - best effort
            log.warning("adapter close for application %s failed", ctx.application.id, exc_info=True)

    async def close_adapters(self) -> None:
        """Close every adapter browser / agent session (daemon shutdown)."""
        from autoapply.apply.base import close_all_sessions

        try:
            await close_all_sessions()
        except Exception:  # noqa: BLE001
            log.warning("close_all_sessions failed", exc_info=True)
        for a in self.adapters:
            closer = getattr(a, "close", None)
            if closer is None:
                continue
            try:
                await _maybe_await(closer())
            except Exception:  # noqa: BLE001
                log.warning("closing adapter %r failed", a, exc_info=True)

    async def _fill_and_submit(
        self, app: Application, job: Job, company: Company, mode: Mode, adapter: Adapter, ctx: ApplyContext,
    ) -> AppState:
        usage0 = self.llm.usage.snapshot()
        try:
            fill = await adapter.fill(ctx)
        except PausedError:
            await self._transition(app.id, AppState.QUEUED, reason="paused", expected_from=AppState.FILLING)
            raise
        except asyncio.CancelledError:
            await self._transition(app.id, AppState.QUEUED, reason="interrupted", expected_from=AppState.FILLING)
            raise
        except NotImplementedError:
            await self._transition(app.id, AppState.FAILED, reason="adapter_not_implemented", expected_from=AppState.FILLING)
            return AppState.FAILED
        except Exception as e:  # noqa: BLE001
            log.exception("fill failed for application %s", app.id)
            await self._transition(app.id, AppState.FAILED, reason=f"adapter_error: {e}"[:300], expected_from=AppState.FILLING)
            return AppState.FAILED
        finally:
            used = self.llm.usage.since(usage0)
            if used.total_tokens:
                db.add_application_tokens(self.conn, app.id, used.input_tokens, used.output_tokens)

        if await self._captcha_handoff_wanted(fill, ctx):
            await self._log(LogLevel.INFO, f"CAPTCHA on {company.name}: reopening in a visible window for you", job_id=job.id, application_id=app.id)
            if self.notifier is not None:
                await self.notifier.notify("CAPTCHA needs you", f"{company.name}: solve it in the browser window that just opened.")
            ctx.headless = False
            ctx.extra["captcha_wait_s"] = self.captcha_wait_s
            try:
                fill = await adapter.fill(ctx)
            except (PausedError, asyncio.CancelledError):
                raise
            except Exception as e:  # noqa: BLE001
                log.exception("headed retry failed for application %s", app.id)
                fill = FillResult(ok=False, error=f"adapter_error: {e}"[:300])
            finally:
                ctx.extra.pop("captcha_wait_s", None)

        art: dict[str, Any] = {}
        if fill.screenshot_path:
            art["screenshot_path"] = fill.screenshot_path
        if fill.cover_letter_path:
            art["cover_letter_path"] = fill.cover_letter_path
        if art:
            db.update_application(self.conn, app.id, **art)

        if fill.unresolved:
            await self.park(app.id, job, fill.unresolved)
            await self._transition(app.id, AppState.NEEDS_YOU, reason="unresolved_questions", expected_from=AppState.FILLING)
            return AppState.NEEDS_YOU
        if not fill.ok:
            await self._transition(app.id, AppState.FAILED, reason=fill.error or "fill_failed", expected_from=AppState.FILLING)
            return AppState.FAILED
        if mode is Mode.REVIEW:
            await self._transition(app.id, AppState.AWAITING_REVIEW, reason="review_mode", expected_from=AppState.FILLING)
            return AppState.AWAITING_REVIEW

        # ---- final gate -> durable pre-write -> click (no await between gate and pre-write)
        prefs = db.get_preferences(self.conn)
        check = self.submit_gate(job, prefs, application_id=app.id)
        if not check.allowed:
            await self._transition(app.id, AppState.QUEUED, reason=check.reason, expected_from=AppState.FILLING)
            await self.emit_cap(check, company.id)
            if check.reason == "paused":
                raise PausedError("paused by user")
            if check.cap is CapKind.DAILY:
                raise CapReached()
            return AppState.QUEUED
        t = db.begin_submit(self.conn, app.id, run_id=self._run_db_id)
        await self.emit_transition(t)
        return await self.click_submit(app.id, adapter, ctx)

    async def _captcha_handoff_wanted(self, fill: Any, ctx: ApplyContext) -> bool:
        """Headless fill hit only a CAPTCHA: retry once in a visible window the user can solve it in."""
        if not (ctx.headless and self.captcha_wait_s > 0) or ctx.is_dry_run:
            return False
        reasons = [u.reason for u in (fill.unresolved or [])]
        return bool(reasons) and all(r == QuestionReason.CAPTCHA.value for r in reasons)

    async def click_submit(self, application_id: int, adapter: Adapter, ctx: ApplyContext) -> AppState:
        """Call ``Adapter.submit`` once for an application already in ``submitting``."""
        app = db.get_application(self.conn, application_id)
        job = db.get_job(self.conn, app.job_id)
        company = db.get_company(self.conn, job.company_id)
        await self._state(
            DaemonActivity.APPLYING, f"Submitting {company.name} · {job.title}", application_id=app.id, job_id=job.id,
        )
        try:
            res = await adapter.submit(ctx)
        except asyncio.CancelledError:
            await self._transition(app.id, AppState.UNKNOWN_VERIFY, reason="interrupted_during_submit", expected_from=AppState.SUBMITTING)
            raise
        except Exception as e:  # noqa: BLE001 - outcome unknown: the click may have happened
            log.exception("submit failed for application %s", app.id)
            await self._transition(app.id, AppState.UNKNOWN_VERIFY, reason=f"submit_error: {e}"[:300], expected_from=AppState.SUBMITTING)
            return AppState.UNKNOWN_VERIFY
        if res.verified:
            t = db.complete_submit(
                self.conn, app.id, confirmation_screenshot_path=res.confirmation_screenshot_path,
                run_id=self._run_db_id,
            )
            await self.emit_transition(t)
            await self._log(LogLevel.INFO, f"Submitted {company.name} · {job.title}", job_id=job.id, application_id=app.id)
            return AppState.SUBMITTED
        if res.confirmation_screenshot_path:
            db.update_application(self.conn, app.id, confirmation_screenshot_path=res.confirmation_screenshot_path)
        if not getattr(res, "clicked", True):
            # The adapter is certain nothing was clicked (dry run, refused host, re-fill left
            # gaps, agent refused): definitely not sent, so ``failed`` rather than unknown.
            await self._transition(
                app.id, AppState.FAILED, reason=f"not_submitted: {res.error or 'submit not clicked'}"[:300],
                expected_from=AppState.SUBMITTING,
            )
            return AppState.FAILED
        await self._transition(app.id, AppState.UNKNOWN_VERIFY, reason=res.error or "unverified", expected_from=AppState.SUBMITTING)
        return AppState.UNKNOWN_VERIFY

    async def submit_approved(self, application_ids: list[int]) -> dict[int, AppState]:
        """Submit applications the user approved (already moved to ``submitting`` by the
        daemon with actor ``user``). Adapters get ``ctx.extra["approved"] = True``.

        Runs outside any pipeline run (no run id, no run stats) and holds ``browser_lock``,
        so it queues behind an active run instead of fighting it for the Chrome profile.
        The applications stay in ``submitting`` while waiting, so they already count toward
        the daily cap and hold their companies' cooldown.
        """
        token = _DETACHED.set(True)
        out: dict[int, AppState] = {}
        try:
            async with self.browser_lock:
                for app_id in application_ids:
                    app = db.get_application(self.conn, app_id)
                    if app.state is not AppState.SUBMITTING:
                        out[app_id] = app.state
                        continue
                    job = db.get_job(self.conn, app.job_id)
                    adapter = self._select_adapter(job)
                    if adapter is None:
                        # Nothing was clicked, so this is definitely not sent.
                        await self._transition(app_id, AppState.FAILED, reason="no_adapter", expected_from=AppState.SUBMITTING)
                        out[app_id] = AppState.FAILED
                        continue
                    ctx = self.build_context(app_id, extra={"approved": True})
                    try:
                        out[app_id] = await self.click_submit(app_id, adapter, ctx)
                    finally:
                        await self._release_session(adapter, ctx)
                if self.run_row is None:  # never report idle over a run that is about to start
                    await self._state(DaemonActivity.IDLE)
        finally:
            _DETACHED.reset(token)
        return out

    async def park(self, application_id: int, job: Job, unresolved: list[UnresolvedField]) -> list[str]:
        """Put unresolved fields in the Needs-You inbox; emits ``question_opened`` per cluster."""
        touched: list[str] = []
        try:
            res = await _maybe_await(self.hooks.park(self.conn, job.id, unresolved))
            touched = list(res[1]) if isinstance(res, tuple) and len(res) == 2 else []
        except NotImplementedError:
            await self._not_implemented("prep.park_unresolved (using plain inbox questions)")
            for u in unresolved:
                try:
                    reason = QuestionReason(u.reason)
                except ValueError:
                    reason = QuestionReason.UNKNOWN
                q, _created = db.add_question(
                    self.conn, canonical_question=u.question.label, job_id=job.id, field_type=u.question.field_type,
                    options=u.question.options, never_guess_key=u.never_guess_key, reason=reason,
                    suggested_answer=u.suggested_answer, suggested_confidence=u.confidence,
                )
                touched.append(q.cluster_id)
        try:
            await _maybe_await(self.hooks.cluster_questions(self.conn))
        except NotImplementedError:
            await self._not_implemented("answers.memory clustering")
        except Exception:  # noqa: BLE001
            log.exception("clustering failed")
        # Clustering may have merged clusters: announce whatever now holds this job's questions.
        cluster_ids = [c.cluster_id for c in db.list_open_clusters(self.conn) if job.id in c.job_ids]
        for cid in dict.fromkeys(cluster_ids):
            cluster = db.get_cluster(self.conn, cid)
            if cluster is not None:
                await self.emit("question_opened", QuestionOpenedPayload(cluster=cluster))
        return cluster_ids

    # ---- housekeeping ------------------------------------------------------------------

    async def maintenance(self, now: datetime | None = None) -> None:
        """Auto-ghost stale ``applied`` applications and emit day-N "Heard back?" nudges."""
        now = now or self._now()
        prefs = db.get_preferences(self.conn)
        for payload in db.ghost_stale_applications(self.conn, prefs.ghost_after_days, now):
            await self.emit("application_status", payload)
        for app, day in db.due_nudges(self.conn, prefs.nudge_days, now):
            job = db.get_job(self.conn, app.job_id)
            company = db.get_company(self.conn, job.company_id)
            db.record_nudge_sent(self.conn, app.id)
            await self.emit(
                "nudge_due", NudgeDuePayload(application_id=app.id, job_id=job.id, day=day, company=company.name, title=job.title)
            )


__all__ = [
    "COMPANY_ATTEMPT_PENDING", "CapReached", "Pipeline", "PipelineHooks", "RUN_STEPS", "SubmitCheck",
    "attempts_used_today", "basic_hard_filter", "company_attempt_at", "unconfirmed_attempts_today",
]
