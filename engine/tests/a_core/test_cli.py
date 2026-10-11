"""Developer CLI (typer) against an isolated AUTOAPPLY_HOME. No network, no real LLM."""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest
import respx
from typer.testing import CliRunner

from autoapply import cli, db
from autoapply.enums import AppState, Ats, QuestionStatus
from autoapply.llm.provider import FakeLLMProvider

from .conftest import PROFILE, load_json, seed_job

runner = CliRunner()


def invoke(*args: str, input: str | None = None) -> Any:
    res = runner.invoke(cli.app, list(args), input=input, catch_exceptions=False)
    return res


@pytest.fixture
def fake_factory(monkeypatch: pytest.MonkeyPatch) -> FakeLLMProvider:
    def gen(prompt: str, system: str | None, schema: dict | None) -> Any:
        if "Score these" in prompt:
            jobs = json.loads(prompt[prompt.index("jobs:\n") + 6 :])
            return {"results": [{"job_id": j["job_id"], "score": 80 if "Backend" in j["title"] else 30, "summary": "s",
                                 "factors": {"skills": 1, "seniority": 1, "role": 1, "domain": 1}} for j in jobs]}
        if "How did you hear" in prompt:
            return {"answer": "Company website", "confidence": 0.95, "grounded": True, "story_ids": []}
        return {"answer": "Because I build reliable Go services.", "confidence": 0.9, "grounded": True, "story_ids": []}

    fake = FakeLLMProvider(default=gen)
    monkeypatch.setattr(cli, "LLM_FACTORY", lambda name: fake)
    return fake


def test_init_loads_profile_and_resume(autoapply_home, tmp_path) -> None:  # type: ignore[no-untyped-def]
    prof = tmp_path / "profile.json"
    prof.write_text(json.dumps(PROFILE))
    pdf = tmp_path / "cv.pdf"
    pdf.write_bytes(b"%PDF-1.4\n%%EOF\n")
    res = invoke("init", "--profile", str(prof), "--resume", str(pdf), "--label", "Backend")
    assert res.exit_code == 0, res.output
    assert "added resume variant #1" in res.output
    conn = db.open_db(autoapply_home.db)
    try:
        assert db.get_profile(conn).email == "ada@example.com"
        [rv] = db.list_resume_variants(conn)
        assert rv.label == "Backend" and rv.is_default and (autoapply_home.resumes / "cv.pdf").exists()
    finally:
        conn.close()


def test_watch_add_list_remove(conn) -> None:  # type: ignore[no-untyped-def]
    assert invoke("watch", "add", "Acme Robotics", "https://boards.greenhouse.io/acmerobotics").exit_code == 0
    assert invoke("watch", "add", "Ramp", "ramp", "--ats", "ashby").exit_code == 0
    out = invoke("watch", "list").output
    assert "acmerobotics" in out and "ramp" in out
    assert invoke("watch", "remove", "Ramp").exit_code == 0
    assert [c.name for c in db.list_companies(conn, watch_only=True)] == ["Acme Robotics"]


@respx.mock
def test_discover_persists_and_dedupes(conn) -> None:  # type: ignore[no-untyped-def]
    respx.get("https://boards-api.greenhouse.io/v1/boards/acmerobotics/jobs").mock(
        return_value=httpx.Response(200, json=load_json("greenhouse_board.json"))
    )
    db.upsert_company(conn, "Acme Robotics", ats=Ats.GREENHOUSE, board_token="acmerobotics", watch=True)
    res = invoke("discover", "--source", "greenhouse")
    assert res.exit_code == 0, res.output
    assert "3 postings found; 3 new" in res.output
    assert "3 postings found; 0 new" in invoke("discover", "--source", "greenhouse").output
    assert len(db.list_jobs(conn)) == 3
    out = invoke("discover", "--source", "greenhouse", "--no-persist", "--json").output
    assert "Senior Backend Engineer" in out and "(not persisted)" in out


def test_score_queues_and_skips(conn, profile, fake_factory) -> None:  # type: ignore[no-untyped-def]
    seed_job(conn, ats=Ats.GREENHOUSE, apply_url="https://x.example/1", title="Backend Engineer", state=AppState.DISCOVERED)
    seed_job(conn, ats=Ats.GREENHOUSE, apply_url="https://x.example/2", title="Sales Manager", state=AppState.DISCOVERED)
    res = invoke("score")
    assert res.exit_code == 0, res.output
    assert "queued 1, skipped 1, errors 0" in res.output
    assert {a.state for a in db.list_applications(conn)} == {AppState.QUEUED, AppState.SKIPPED}


def test_status(conn, profile) -> None:  # type: ignore[no-untyped-def]
    seed_job(conn, ats=Ats.GREENHOUSE, apply_url="https://x.example/1")
    res = invoke("status", "--queue")
    assert res.exit_code == 0, res.output
    assert "daily cap" in res.output and "Acme Robotics · Backend Engineer" in res.output


def test_answer_resolves_cluster_and_requeues(conn, profile) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url="https://x.example/1")
    db.transition(conn, app.id, AppState.PREPPING)
    db.transition(conn, app.id, AppState.NEEDS_YOU)
    q, _ = db.add_question(conn, canonical_question="What is your notice period?", job_id=job.id)
    res = invoke("answer", q.cluster_id, "60 days")
    assert res.exit_code == 0, res.output
    assert db.get_application(conn, app.id).state is AppState.QUEUED
    assert db.get_question(conn, q.id).status is QuestionStatus.ANSWERED
    assert any(a.answer == "60 days" for a in db.list_answers(conn))


def test_apply_dry_run_and_submit(conn, profile, resume, ats_server, fake_factory) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    res = invoke("apply", str(app.id))  # dry run is the default
    assert res.exit_code == 0, res.output
    assert "state: queued (dry_run)" in res.output and "ada@example.com" in res.output
    assert ats_server.submissions == []
    assert db.list_application_answers(conn, app.id) == []
    # --submit asks for confirmation; "n" aborts without touching anything
    assert invoke("apply", str(app.id), "--submit", input="n\n").exit_code == 1
    assert ats_server.submissions == []
    res = invoke("apply", str(app.id), "--submit", "--yes")
    assert res.exit_code == 0, res.output
    assert "state: submitted" in res.output and len(ats_server.submissions) == 1
    # a submitted application can't be submitted again
    assert invoke("apply", str(app.id), "--submit", "--yes").exit_code == 2
    assert len(ats_server.submissions) == 1
