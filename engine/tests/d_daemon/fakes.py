"""Test doubles for workstream D: fixture-serving browser, fake sources/adapters/hooks.

Nothing here touches the network, a real browser, or a real LLM.
"""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from autoapply import db
from autoapply.apply.base import ApplyContext, FillResult, PausedError, SubmitResult, UnresolvedField
from autoapply.discovery.base import DiscoveredJob, DiscoveryContext
from autoapply.discovery.linkedin import HumanPacer
from autoapply.enums import AppState, Ats, JobSource
from autoapply.models import FormQuestion, Job
from autoapply.pipeline import PipelineHooks
from autoapply.scoring import ScoreResult

FIXTURES = Path(__file__).parent / "fixtures"


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


# =====================================================================================
# Browser
# =====================================================================================


class FakePage:
    """Serves fixture HTML by URL regex. Deliberately has NO click method (like the real seam)."""

    def __init__(self, browser: "FakeBrowser") -> None:
        self.browser = browser
        self._url = "about:blank"
        self._html = ""
        self.scrolled = 0

    @property
    def url(self) -> str:
        return self._url

    async def goto(self, url: str) -> None:
        self.browser.visited.append(url)
        final = url
        for pattern, target in self.browser.redirects:
            if re.search(pattern, url):
                final = target
                break
        self._url = final
        for pattern, page in self.browser.routes:
            if re.search(pattern, final):
                self._html = page() if callable(page) else page
                return
        self._html = "<html><body>not found</body></html>"

    async def content(self) -> str:
        return self._html

    async def scroll(self, pixels: int) -> None:
        self.scrolled += pixels

    async def close(self) -> None:
        pass


@dataclass
class FakeBrowser:
    routes: list[tuple[str, Any]] = field(default_factory=list)
    redirects: list[tuple[str, str]] = field(default_factory=list)
    visited: list[str] = field(default_factory=list)
    launches: int = 0
    closed: int = 0
    pages: list[FakePage] = field(default_factory=list)

    async def new_page(self) -> FakePage:
        p = FakePage(self)
        self.pages.append(p)
        return p

    async def close(self) -> None:
        self.closed += 1

    def factory(self) -> Callable[[], Any]:
        async def make() -> "FakeBrowser":
            self.launches += 1
            return self

        return make


async def _no_sleep(_s: float) -> None:
    return None


def instant_pacer(seed: int = 7) -> HumanPacer:
    import random

    return HumanPacer(rng=random.Random(seed), sleep=_no_sleep)


class EventSink:
    """Collects emitted (type, payload) pairs."""

    def __init__(self) -> None:
        self.events: list[tuple[str, Any]] = []

    async def __call__(self, type_: str, payload: Any) -> None:
        self.events.append((type_, payload))

    def of(self, type_: str) -> list[Any]:
        return [p for t, p in self.events if t == type_]

    def types(self) -> list[str]:
        return [t for t, _ in self.events]


# =====================================================================================
# Pipeline fakes
# =====================================================================================


class FakeSource:
    name = JobSource.GREENHOUSE

    def __init__(self, jobs: list[DiscoveredJob], *, name: JobSource = JobSource.GREENHOUSE) -> None:
        self.jobs = jobs
        self.name = name
        self.calls = 0

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        self.calls += 1
        return list(self.jobs)


def gh_job(company: str, title: str, n: int, **kw: Any) -> DiscoveredJob:
    return DiscoveredJob(
        source=JobSource.GREENHOUSE, company_name=company, title=title,
        apply_url=f"https://boards.greenhouse.io/{company.lower()}/jobs/{n}", ats=Ats.GREENHOUSE,
        location=kw.pop("location", "Remote"), description=kw.pop("description", "Python and Go"), **kw,
    )


@dataclass
class FakeAdapter:
    """Configurable adapter. Records the DB state of the application when submit() is called
    (to prove the durable 'submitting' pre-write happened before the click)."""

    conn: sqlite3.Connection
    ats: Ats = Ats.GREENHOUSE
    unresolved_titles: set[str] = field(default_factory=set)
    fail_titles: set[str] = field(default_factory=set)
    raise_titles: set[str] = field(default_factory=set)
    unverified_titles: set[str] = field(default_factory=set)
    submit_raises_titles: set[str] = field(default_factory=set)
    pause_on_fill: Callable[[], None] | None = None
    filled: list[int] = field(default_factory=list)
    submitted: list[int] = field(default_factory=list)
    state_at_submit: list[AppState] = field(default_factory=list)
    approved_flags: list[bool] = field(default_factory=list)

    def can_handle(self, job: Job) -> bool:
        return bool(job.apply_url)

    async def harvest_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        return []

    async def fill(self, ctx: ApplyContext) -> FillResult:
        ctx.check_pause()
        self.filled.append(ctx.application.id)
        title = ctx.job.title
        if self.pause_on_fill is not None:
            self.pause_on_fill()
            ctx.check_pause()
        if title in self.raise_titles:
            raise RuntimeError("selector not found")
        if title in self.fail_titles:
            return FillResult(ok=False, error="form closed")
        if title in self.unresolved_titles:
            return FillResult(
                ok=False,
                unresolved=[
                    UnresolvedField(question=FormQuestion(key="why", label="Why do you want to work here?", field_type="textarea"), reason="unknown"),
                    UnresolvedField(question=FormQuestion(key="spons", label="Do you require visa sponsorship?", field_type="select", options=["Yes", "No"]),
                                    reason="never_guess", never_guess_key="sponsorship"),
                ],
            )
        db.add_application_answer(self.conn, ctx.application.id, question="Email", answer="me@example.com", origin="profile")
        return FillResult(ok=True, screenshot_path=str(ctx.screenshots_dir / "full.png"))

    async def submit(self, ctx: ApplyContext) -> SubmitResult:
        self.state_at_submit.append(db.get_application(self.conn, ctx.application.id).state)
        self.submitted.append(ctx.application.id)
        self.approved_flags.append(bool(ctx.extra.get("approved")))
        if ctx.job.title in self.submit_raises_titles:
            raise TimeoutError("navigation timeout after click")
        if ctx.job.title in self.unverified_titles:
            return SubmitResult(verified=False, error="no confirmation page")
        return SubmitResult(verified=True, confirmation_screenshot_path=str(ctx.screenshots_dir / "confirm.png"))


def fake_hooks(
    *,
    scores: dict[str, int] | None = None,
    default_score: int = 85,
    hard_skip: dict[str, str] | None = None,
    prep: Callable[..., Any] | None = None,
) -> tuple[PipelineHooks, dict[str, list[Any]]]:
    calls: dict[str, list[Any]] = {"hard_filter": [], "score_jobs": [], "run_prep": [], "easy_apply": [], "cluster": []}
    scores = scores or {}
    hard_skip = hard_skip or {}

    def hard_filter(conn: sqlite3.Connection, job: Job, company: Any, prefs: Any) -> str | None:
        calls["hard_filter"].append(job.id)
        return hard_skip.get(job.title)

    async def score_jobs(llm: Any, *, profile: Any, preferences: Any, jobs: list[tuple[Job, Any]]) -> list[ScoreResult]:
        calls["score_jobs"].append([j.id for j, _ in jobs])
        out = []
        for job, _c in jobs:
            s = scores.get(job.title, default_score)
            out.append(ScoreResult(job_id=job.id, score=s, reasons={"summary": "fake"},
                                   skip_reason=None if s >= preferences.match_threshold else "below_threshold",
                                   tokens_in=10, tokens_out=5))
        return out

    async def run_prep(conn: sqlite3.Connection, **kw: Any) -> Any:
        calls["run_prep"].append(kw.get("application_ids"))
        if prep is not None:
            return await prep(conn, **kw)

        @dataclass
        class Report:
            parked_jobs: list[int] = field(default_factory=list)

        return Report()

    async def refresh_easy_apply(conn: sqlite3.Connection, llm: Any, job_id: int) -> Any:
        calls["easy_apply"].append(job_id)
        return None

    def cluster(conn: sqlite3.Connection) -> None:
        calls["cluster"].append(True)

    def pick(conn: sqlite3.Connection, job: Job) -> None:
        return None

    def park(conn: sqlite3.Connection, job_id: int, unresolved: list[UnresolvedField]) -> tuple[list[int], set[str]]:
        ids, touched = [], set()
        for u in unresolved:
            q, _ = db.add_question(conn, canonical_question=u.question.label, job_id=job_id, field_type=u.question.field_type,
                                   options=u.question.options, never_guess_key=u.never_guess_key, reason=u.reason)
            ids.append(q.id)
            touched.add(q.cluster_id)
        return ids, touched

    hooks = PipelineHooks(
        hard_filter=hard_filter, score_jobs=score_jobs, run_prep=run_prep, pick_resume=pick,
        refresh_easy_apply=refresh_easy_apply, cluster_questions=cluster, park=park,
        is_deferral=lambda r: r == "daily_cap_reached",
    )
    return hooks, calls


def raise_pause() -> None:
    raise PausedError("paused")
