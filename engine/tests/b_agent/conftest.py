"""Fixtures/helpers for workstream B tests (answers, prep, agentic). No network, no real SDK."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from autoapply import db
from autoapply.apply.base import ApplyContext
from autoapply.enums import AppState, Ats, JobSource
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import Application, Job
from autoapply.paths import Paths


@dataclass
class Emitted:
    events: list[tuple[str, Any]]

    async def __call__(self, type_: str, payload: Any) -> None:
        self.events.append((type_, payload))

    def of(self, type_: str) -> list[Any]:
        return [p for t, p in self.events if t == type_]


@pytest.fixture
def emit() -> Emitted:
    return Emitted([])


def make_job(
    conn: sqlite3.Connection,
    company: str = "Stripe",
    title: str = "Backend Engineer",
    *,
    location: str | None = "San Francisco, CA",
    ats: Ats = Ats.GREENHOUSE,
    apply_url: str | None = None,
    raw: dict[str, Any] | None = None,
    description: str = "We build payments infrastructure in Go and Postgres. You will design APIs.",
    state: AppState = AppState.QUEUED,
    easy_apply: bool = False,
) -> tuple[Job, Application]:
    c = db.upsert_company(conn, company)
    job, created = db.insert_job(
        conn, company_id=c.id, source=JobSource.GREENHOUSE, title=title, location=location, ats=ats,
        apply_url=apply_url or f"https://example.test/{company.lower().replace(' ', '-')}/{title.lower().replace(' ', '-')}",
        description=description, raw=raw or {}, easy_apply=easy_apply,
    )
    assert created
    app = db.get_application_by_job(conn, job.id)
    path = {
        AppState.DISCOVERED: [],
        AppState.SCORED: [AppState.SCORED],
        AppState.QUEUED: [AppState.SCORED, AppState.QUEUED],
        AppState.FILLING: [AppState.SCORED, AppState.QUEUED, AppState.FILLING],
        AppState.NEEDS_YOU: [AppState.SCORED, AppState.QUEUED, AppState.PREPPING, AppState.NEEDS_YOU],
    }[state]
    for s in path:
        db.transition(conn, app.id, s)
    return job, db.get_application(conn, app.id)


def seed_profile(conn: sqlite3.Connection) -> None:
    db.update_profile(conn, {
        "full_name": "Ada Lovelace", "first_name": "Ada", "last_name": "Lovelace", "email": "ada@example.com",
        "phone": "+1 555 0100", "location": "San Francisco, CA", "headline": "Senior Backend Engineer",
        "summary": "Backend engineer focused on payments systems.",
        "links": {"linkedin": "https://linkedin.com/in/ada", "github": "https://github.com/ada"},
        "work_history": [
            {"company": "Acme Pay", "title": "Senior Backend Engineer", "start": "2021", "end": None,
             "highlights": ["Cut payment latency by 40%", "Led migration to Go microservices"]},
            {"company": "Initech", "title": "Software Engineer", "start": "2017", "end": "2021", "highlights": []},
        ],
        "education": [{"school": "University of London", "degree": "BSc", "field": "Mathematics", "end": "2017"}],
        "skills": ["Go", "Postgres", "Kafka", "Python"],
        "years_experience": 8,
    })


def make_ctx(conn: sqlite3.Connection, app_id: int, llm: FakeLLMProvider, home: Paths, emit: Any, **kw: Any) -> ApplyContext:
    app = db.get_application(conn, app_id)
    job = db.get_job(conn, app.job_id)
    resume = db.get_resume_variant(conn, app.resume_variant_id) if app.resume_variant_id else None
    return ApplyContext(
        conn=conn, application=app, job=job, profile=db.get_profile(conn), never_guess=db.get_never_guess(conn),
        preferences=db.get_preferences(conn), llm=llm, resume=resume,
        screenshots_dir=Path(home.application_screenshot_dir(app.id)), emit=emit, **kw,
    )


def gen(answer: str, confidence: float = 0.9, grounded: bool = True, story_ids: list[int] | None = None) -> dict[str, Any]:
    """A FakeLLMProvider response for the resolver's GENERATE ANSWER prompt."""
    return {"answer": answer, "confidence": confidence, "grounded": grounded, "story_ids": story_ids or []}

from tests.legacy_auto_mode import _fresh_db_starts_in_auto  # noqa: E402,F401  (autouse: fresh DBs start in Auto)
