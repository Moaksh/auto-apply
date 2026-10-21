"""Pipeline safety gates: posting liveness before fill, legitimacy risk before submit."""

from __future__ import annotations

import sqlite3

import httpx
import pytest

from autoapply import db, liveness
from autoapply.enums import AppState, Mode, RunKind
from autoapply.paths import Paths

from .test_pipeline import make_pipeline, states
from .fakes import gh_job

GOOD_JD = (
    "Responsibilities: design and build backend services in Python and Go. "
    "Requirements: 3+ years of experience with distributed systems."
)


def _app(conn: sqlite3.Connection, title: str):
    job = next(j for j in db.list_jobs(conn) if j.title == title)
    return job, db.get_application_by_job(conn, job.id)


async def test_closed_posting_skipped_before_fill(conn: sqlite3.Connection, autoapply_home: Paths,
                                                  monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(liveness, "ENABLED", True)
    seen: list[str] = []

    def handler(req: httpx.Request) -> httpx.Response:
        seen.append(str(req.url))
        # job 1's posting is gone from the Greenhouse board; job 2 is listed
        return httpx.Response(404) if req.url.path.endswith("/jobs/1") else httpx.Response(200, json={"id": 2})

    monkeypatch.setattr(liveness, "make_client", lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    jobs = [gh_job("Stripe", "Backend Engineer", 1, description=GOOD_JD), gh_job("Notion", "Platform Engineer", 2, description=GOOD_JD)]
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs)
    await p.run(RunKind.FULL)

    assert states(conn) == {"Backend Engineer": "skipped", "Platform Engineer": "submitted"}
    closed_job, closed_app = _app(conn, "Backend Engineer")
    assert closed_app.state_reason == "posting_closed"
    assert closed_app.id not in adapter.filled
    assert closed_job.raw["liveness"]["status"] == "closed" and closed_job.raw["liveness"]["method"] == "api"
    assert all("boards-api.greenhouse.io" in u for u in seen)
    logs = [e.message for e in sink.of("log")]
    assert any("posting has closed" in m for m in logs)


async def test_unknown_liveness_still_applies(conn: sqlite3.Connection, autoapply_home: Paths,
                                              monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(liveness, "ENABLED", True)

    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline")

    monkeypatch.setattr(liveness, "make_client", lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    p, _sink, adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1, description=GOOD_JD)])
    await p.run(RunKind.FULL)
    assert states(conn) == {"Backend Engineer": "submitted"} and len(adapter.submitted) == 1


async def test_high_risk_job_goes_to_review_in_auto_mode(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    assert db.get_preferences(conn).mode == Mode.AUTO
    jd = GOOD_JD + " Interested candidates send your CV to acme.hiring.desk@gmail.com"
    jobs = [gh_job("Acme", "Backend Engineer", 1, description=jd), gh_job("Notion", "Platform Engineer", 2, description=GOOD_JD)]
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs)
    await p.run(RunKind.FULL)

    assert states(conn) == {"Backend Engineer": "awaiting_review", "Platform Engineer": "submitted"}
    job, app = _app(conn, "Backend Engineer")
    assert app.state_reason == "risk_review" and app.mode == "review"
    assert app.id in adapter.filled and app.id not in adapter.submitted
    risk = job.raw["risk"]
    assert risk["level"] == "high" and [s["code"] for s in risk["signals"]] == ["personal_email_contact"]
    assert job.mode_override is None  # the user's own per-job choice is not overwritten
    assert any("Risk high" in e.message for e in sink.of("log"))


async def test_fee_asking_job_is_skipped_at_scoring(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jd = GOOD_JD + " Selected candidates must pay a refundable security deposit of Rs. 2,500 before joining."
    jobs = [gh_job("Acme", "Backend Engineer", 1, description=jd)]
    p, _sink, adapter, calls = make_pipeline(conn, autoapply_home, jobs)
    await p.run(RunKind.FULL)

    job, app = _app(conn, "Backend Engineer")
    assert app.state is AppState.SKIPPED and app.state_reason == "asks_candidate_to_pay"
    assert db.get_score(conn, job.id).skip_reason == "asks_candidate_to_pay"
    assert calls["score_jobs"] == [] and adapter.filled == []  # no LLM tokens, no agent run
    assert job.raw["risk"]["level"] == "high"


async def test_caution_only_is_logged_and_applies(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jd = GOOD_JD + " We are hiring for one of our clients, a fintech in Pune."
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("TalentBridge", "Backend Engineer", 1, description=jd)])
    await p.run(RunKind.FULL)
    job, app = _app(conn, "Backend Engineer")
    assert app.state is AppState.SUBMITTED
    assert job.raw["risk"]["level"] == "caution"
    assert [s["code"] for s in job.raw["risk"]["signals"]] == ["agency_unnamed_employer"]
    assert any("Risk caution" in e.message for e in sink.of("log"))
