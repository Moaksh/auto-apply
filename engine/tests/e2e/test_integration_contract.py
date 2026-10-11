"""Regression tests for the cross-workstream contract changes applied at integration:

* shared guardrail queries in ``db`` (in-flight / unverified attempts count toward the daily
  cap and hold the company cooldown) used by BOTH the pipeline and
  ``answers.guardrails.check_submit_allowed``;
* ``db.delete_application_answers`` (keeps the user's own answers);
* ``SubmitResult.clicked = False`` -> ``submitting -> failed`` (definitely not sent);
* new commands ``apply_anyway``, ``update_job_notes``, ``set_application_resume``;
* ``skip_question`` announces clusters emptied/shrunk as a side effect;
* event order of ``answer_question`` (question_resolved before application_state).
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

import pytest

from autoapply import db
from autoapply.answers.guardrails import check_submit_allowed
from autoapply.apply.base import ApplyContext, FillResult, SubmitResult
from autoapply.daemon import Daemon
from autoapply.enums import Actor, AnswerOrigin, AppState, Ats, JobSource
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import FormQuestion, Job, SystemCheckItem, SystemCheckResult, make_command
from autoapply.paths import Paths
from autoapply.pipeline import Pipeline
from autoapply.scheduler import Caffeinate


def seed(conn: sqlite3.Connection, company: str, title: str, path: list[AppState]) -> tuple[Job, int]:
    c = db.upsert_company(conn, company)
    job, _ = db.insert_job(conn, company_id=c.id, source=JobSource.MANUAL, title=title,
                           apply_url=f"http://127.0.0.1/{company}/{title}".replace(" ", "_"), ats=Ats.GREENHOUSE)
    app = db.get_application_by_job(conn, job.id)
    for s in path:
        actor = Actor.USER if (app.state, s) in {(AppState.AWAITING_REVIEW, AppState.SUBMITTING)} else Actor.AGENT
        db.transition(conn, app.id, s, actor=actor)
        app = db.get_application(conn, app.id)
    return job, app.id


TO_QUEUED = [AppState.SCORED, AppState.QUEUED]
TO_REVIEW = [*TO_QUEUED, AppState.FILLING, AppState.AWAITING_REVIEW]
TO_SUBMITTING = [*TO_QUEUED, AppState.FILLING, AppState.SUBMITTING]
TO_UNKNOWN = [*TO_SUBMITTING, AppState.UNKNOWN_VERIFY]


# ---- shared guardrail queries ---------------------------------------------------------


def test_check_submit_allowed_counts_in_flight_attempts_toward_cap(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"daily_cap": 1})
    seed(conn, "Alpha", "Backend", TO_SUBMITTING)
    job, app_id = seed(conn, "Beta", "Backend", [*TO_QUEUED, AppState.FILLING])
    assert db.attempts_used_today(conn) == 1 and db.submitted_today(conn) == 0
    check = check_submit_allowed(conn, db.get_application(conn, app_id), job, db.get_preferences(conn), paused=False)
    assert not check.allowed and "daily cap" in (check.reason or "")


def test_check_submit_allowed_holds_company_on_unknown_verify(conn: sqlite3.Connection) -> None:
    seed(conn, "Gamma", "Backend", TO_UNKNOWN)
    job, app_id = seed(conn, "Gamma", "Infra", [*TO_QUEUED, AppState.FILLING])
    check = check_submit_allowed(conn, db.get_application(conn, app_id), job, db.get_preferences(conn), paused=False)
    assert not check.allowed and check.extra.get("unconfirmed") is True
    # The application itself never blocks itself.
    assert db.company_attempt_at(conn, job.company_id, 30, exclude_application_id=app_id) is not None
    own_job, own_id = seed(conn, "Delta", "Solo", TO_SUBMITTING)
    assert db.company_attempt_at(conn, own_job.company_id, 30, exclude_application_id=own_id) is None


def test_delete_application_answers_keeps_user_rows(conn: sqlite3.Connection) -> None:
    _, app_id = seed(conn, "Eps", "Backend", TO_QUEUED)
    for key, origin in (("q1", AnswerOrigin.GENERATED), ("q2", AnswerOrigin.USER), ("q3", AnswerOrigin.MEMORY)):
        db.add_application_answer(conn, app_id, question=key, answer="x", origin=origin, field_key=key)
    assert db.delete_application_answers(conn, app_id, ["q1", "q2"]) == 1
    assert {a.field_key for a in db.list_application_answers(conn, app_id)} == {"q2", "q3"}
    assert db.delete_application_answers(conn, app_id, []) == 0
    assert db.delete_application_answers(conn, app_id, ["q2"], keep_origins=()) == 1


# ---- clicked=False -> failed ----------------------------------------------------------


class NotClickedAdapter:
    ats = Ats.GREENHOUSE

    def can_handle(self, job: Job) -> bool:
        return True

    async def harvest_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        return []

    async def fill(self, ctx: ApplyContext) -> FillResult:
        return FillResult(ok=True)

    async def submit(self, ctx: ApplyContext) -> SubmitResult:
        return SubmitResult(verified=False, error="submit refused: host not allowed", clicked=False)


async def test_not_clicked_submit_goes_to_failed_not_unknown(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    events: list[tuple[str, Any]] = []

    async def emit(type_: str, payload: Any) -> None:
        events.append((type_, payload))

    _, app_id = seed(conn, "Zeta", "Backend", [*TO_REVIEW, AppState.SUBMITTING])
    p = Pipeline(conn, paths=autoapply_home, llm=FakeLLMProvider(default="ok"), sources=[], adapters=[NotClickedAdapter()],
                 emit=emit, is_paused=lambda: False)
    out = await p.submit_approved([app_id])
    assert out == {app_id: AppState.FAILED}
    app = db.get_application(conn, app_id)
    assert app.state is AppState.FAILED and (app.state_reason or "").startswith("not_submitted")


# ---- new commands via Daemon.handle ---------------------------------------------------


@pytest.fixture
async def daemon(autoapply_home: Paths, tmp_path: Path) -> Any:
    import shutil
    import tempfile

    sock_dir = Path(tempfile.mkdtemp(prefix="aai", dir="/tmp"))
    conn = db.open_db(autoapply_home.db)
    d = Daemon(
        autoapply_home, conn=conn, llm=FakeLLMProvider(default="ok"), sources=[], adapters=[],
        socket_path=sock_dir / "d.sock", enable_scheduler=False, enable_maintenance=False,
        caffeinate_factory=lambda: Caffeinate([]),
        system_check=lambda: SystemCheckResult(items=[SystemCheckItem(name="autoapplyd", ok=True)], all_required_ok=True),
        chrome_launcher=lambda profile, url: None,
    )
    await d.start()
    try:
        yield d
    finally:
        await d.stop()
        conn.close()
        shutil.rmtree(sock_dir, ignore_errors=True)


async def cmd(d: Daemon, type_: str, payload: dict[str, Any]) -> dict[str, Any]:
    (reply,) = await d.handle(make_command(type_, payload))
    return reply.model_dump(mode="json")


async def test_apply_anyway_only_from_skipped(daemon: Daemon) -> None:
    _, skipped = seed(daemon.conn, "Eta", "Backend", [AppState.SCORED, AppState.SKIPPED])
    _, queued = seed(daemon.conn, "Theta", "Backend", TO_QUEUED)
    r = await cmd(daemon, "apply_anyway", {"application_id": skipped})
    assert r["type"] == "ack"
    app = db.get_application(daemon.conn, skipped)
    assert app.state is AppState.QUEUED and app.state_reason == "user_apply_anyway"
    r = await cmd(daemon, "apply_anyway", {"application_id": queued})
    assert r["type"] == "error" and r["payload"]["code"] == "illegal_transition"


async def test_update_job_notes(daemon: Daemon) -> None:
    job, _ = seed(daemon.conn, "Iota", "Backend", TO_QUEUED)
    assert (await cmd(daemon, "update_job_notes", {"job_id": job.id, "notes": "  Referred by Sam "}))["type"] == "ack"
    assert db.get_job(daemon.conn, job.id).notes == "Referred by Sam"
    assert (await cmd(daemon, "update_job_notes", {"job_id": job.id, "notes": ""}))["type"] == "ack"
    assert db.get_job(daemon.conn, job.id).notes is None
    r = await cmd(daemon, "update_job_notes", {"job_id": 9999, "notes": "x"})
    assert r["type"] == "error" and r["payload"]["code"] == "not_found"


async def test_set_application_resume(daemon: Daemon, autoapply_home: Paths) -> None:
    conn = daemon.conn
    r1 = db.add_resume_variant(conn, label="A", file_path=str(autoapply_home.resumes / "a.pdf"), is_default=True)
    r2 = db.add_resume_variant(conn, label="B", file_path=str(autoapply_home.resumes / "b.pdf"))
    _, review = seed(conn, "Kappa", "Backend", TO_REVIEW)
    db.update_application(conn, review, resume_variant_id=r1.id)
    r = await cmd(daemon, "set_application_resume", {"application_id": review, "resume_variant_id": r2.id})
    assert r["type"] == "ack" and r["payload"]["result"] == {"requeued": True}
    app = db.get_application(conn, review)
    assert app.resume_variant_id == r2.id and app.state is AppState.QUEUED and app.state_reason == "resume_swapped"

    _, filling = seed(conn, "Lambda", "Backend", [*TO_QUEUED, AppState.FILLING])
    r = await cmd(daemon, "set_application_resume", {"application_id": filling, "resume_variant_id": r2.id})
    assert r["type"] == "error" and r["payload"]["code"] == "conflict"
    r = await cmd(daemon, "set_application_resume", {"application_id": filling, "resume_variant_id": 999})
    assert r["type"] == "error" and r["payload"]["code"] == "not_found"


async def test_answer_question_emits_resolved_before_requeue(daemon: Daemon) -> None:
    conn = daemon.conn
    job, app_id = seed(conn, "Mu", "Backend", [*TO_QUEUED, AppState.PREPPING, AppState.NEEDS_YOU])
    q, _ = db.add_question(conn, canonical_question="How many years of Rust?", job_id=job.id)
    sent: list[str] = []
    orig = daemon.emit

    async def spy(type_: str, payload: Any) -> None:
        sent.append(type_)
        await orig(type_, payload)

    daemon.emit = spy  # type: ignore[method-assign]
    r = await cmd(daemon, "answer_question", {"cluster_id": q.cluster_id, "answer": "3", "save_to_memory": False})
    assert r["type"] == "ack" and app_id in r["payload"]["result"]["resumed_application_ids"]
    assert sent.index("question_resolved") < sent.index("application_state")
    assert db.get_application(conn, app_id).state is AppState.QUEUED


async def test_skip_question_announces_shrunk_clusters(daemon: Daemon) -> None:
    conn = daemon.conn
    parked = [*TO_QUEUED, AppState.PREPPING, AppState.NEEDS_YOU]
    job_a, app_a = seed(conn, "Nu", "Backend", parked)
    job_b, app_b = seed(conn, "Xi", "Backend", parked)
    qx, _ = db.add_question(conn, canonical_question="Do you hold an active TS/SCI clearance?", job_id=job_a.id)
    qy, _ = db.add_question(conn, canonical_question="How many years of Rust have you written?", job_id=job_a.id)
    db.add_question(conn, canonical_question="How many years of Rust have you written?", job_id=job_b.id)
    assert qx.cluster_id != qy.cluster_id
    sent: list[tuple[str, Any]] = []
    orig = daemon.emit

    async def spy(type_: str, payload: Any) -> None:
        sent.append((type_, payload))
        await orig(type_, payload)

    daemon.emit = spy  # type: ignore[method-assign]
    r = await cmd(daemon, "skip_question", {"cluster_id": qx.cluster_id, "reason": "no clearance"})
    assert r["type"] == "ack" and r["payload"]["result"]["skipped_application_ids"] == [app_a]
    assert db.get_application(conn, app_a).state is AppState.SKIPPED
    assert db.get_application(conn, app_b).state is AppState.NEEDS_YOU
    types = [t for t, _ in sent]
    assert types.index("question_resolved") < types.index("application_state")
    shrunk = [p.cluster for t, p in sent if t == "question_opened"]
    assert [c.cluster_id for c in shrunk] == [qy.cluster_id] and shrunk[0].job_ids == [job_b.id]
