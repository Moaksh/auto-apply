"""State-machine integration: run_application walks queued -> ... with real Chromium and the
local fixture server (which reads the DB at the moment the POST arrives)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from autoapply import db
from autoapply.apply.ashby import AshbyAdapter
from autoapply.apply.base import PausedError, build_context, close_all_sessions, run_application
from autoapply.apply.greenhouse import GreenhouseAdapter
from autoapply.enums import Actor, AnswerOrigin, AppState, Ats, QuestionReason
from autoapply.llm.provider import FakeLLMProvider

from .conftest import EventSink, ScriptedResolver, seed_job
from .test_adapters import ASHBY_RULES, GH_RULES

pytestmark = pytest.mark.usefixtures("profile", "resume")


@pytest.fixture(autouse=True)
async def _cleanup_sessions() -> Any:
    yield
    await close_all_sessions()


def make_ctx(conn, app_id: int, rules: list[tuple[str, Any]], **kw: Any):  # type: ignore[no-untyped-def]
    extra = {"resolver": ScriptedResolver(conn, rules), "always_cover_letter": False, **kw.pop("extra", {})}
    return build_context(conn, app_id, llm=kw.pop("llm", FakeLLMProvider()), extra=extra, **kw)


def states(conn, app_id: int) -> list[str]:  # type: ignore[no-untyped-def]
    return [e.payload["to"] for e in db.list_events(conn, application_id=app_id, kinds=["state"])]


async def test_auto_mode_submits_with_durable_prewrite(conn, ats_server, autoapply_home) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    ats_server.db_path, ats_server.watch_application_id = autoapply_home.db, app.id
    sink = EventSink()
    res = await run_application(make_ctx(conn, app.id, GH_RULES, emit=sink), GreenhouseAdapter())
    assert res.final_state is AppState.SUBMITTED, res
    [sub] = ats_server.submissions
    assert sub.app_state_at_post == "submitting"  # written + committed BEFORE the click
    a = db.get_application(conn, app.id)
    assert a.state is AppState.SUBMITTED and a.status.value == "applied" and a.mode.value == "auto"
    assert a.screenshot_path and Path(a.screenshot_path).exists()
    assert a.confirmation_screenshot_path and Path(a.confirmation_screenshot_path).exists()
    assert db.get_company(conn, job.company_id).last_applied_at is not None
    assert states(conn, app.id)[-3:] == ["filling", "submitting", "submitted"]
    assert [p.to_state.value for p in sink.of("application_state")] == ["filling", "submitting", "submitted"]
    origins = {x.field_key: x.origin for x in db.list_application_answers(conn, app.id)}
    assert origins["question_1002"] is AnswerOrigin.GENERATED and origins["resume"] is AnswerOrigin.CV


async def test_review_mode_then_user_approval_uses_edited_answer(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    db.update_preferences(conn, {"per_ats_mode": {"greenhouse": "review"}})
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    res = await run_application(make_ctx(conn, app.id, GH_RULES), GreenhouseAdapter())
    assert res.final_state is AppState.AWAITING_REVIEW
    assert ats_server.submissions == []
    rows = {r.field_key: r for r in db.list_application_answers(conn, app.id)}
    n_rows = len(rows)
    db.edit_application_answer(conn, rows["question_1002"].id, "Edited by me in Review.")

    # The agent may never approve its own review item.
    with pytest.raises(db.IllegalTransition):
        db.begin_submit(conn, app.id)
    db.begin_submit(conn, app.id, actor=Actor.USER)  # the daemon does this on `approve`
    # Fresh context (new process / later time): the adapter re-opens the form, re-fills from the
    # recorded answers and clicks once.
    resolver_rules = [(r"why do you want", ("SHOULD NOT BE USED", "generated", 0.99)), *GH_RULES]
    ctx = make_ctx(conn, app.id, resolver_rules, extra={"approved": True})
    sub_res = await GreenhouseAdapter().submit(ctx)
    assert sub_res.verified, sub_res
    db.complete_submit(conn, app.id, confirmation_screenshot_path=sub_res.confirmation_screenshot_path)
    [sub] = ats_server.submissions
    assert sub.fields["question_1002"] == ["Edited by me in Review."]
    assert len(db.list_application_answers(conn, app.id)) == n_rows  # reused, no duplicates
    assert db.get_application(conn, app.id).state is AppState.SUBMITTED


async def test_unresolved_parks_job_in_inbox(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    rules = [(r"why do you want", ("needs", QuestionReason.LOW_CONFIDENCE)), *GH_RULES]
    res = await run_application(make_ctx(conn, app.id, rules), GreenhouseAdapter())
    assert res.final_state is AppState.NEEDS_YOU
    [cluster] = db.list_open_clusters(conn)
    assert cluster.canonical_question == "Why do you want to work at Acme Robotics?"
    assert cluster.job_ids == [job.id] and cluster.reason is QuestionReason.LOW_CONFIDENCE
    assert ats_server.submissions == []


async def test_pause_between_steps_requeues(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    calls = {"n": 0}

    def paused() -> bool:
        calls["n"] += 1
        return calls["n"] > 3  # kill switch flips mid-fill

    res = await run_application(make_ctx(conn, app.id, GH_RULES, is_paused=paused), GreenhouseAdapter())
    assert res.final_state is AppState.QUEUED and res.reason == "paused"
    assert db.get_application(conn, app.id).state_reason == "paused"
    assert ats_server.submissions == []


async def test_paused_before_start_raises_from_fill(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    with pytest.raises(PausedError):
        await GreenhouseAdapter().fill(make_ctx(conn, app.id, GH_RULES, is_paused=lambda: True))


async def test_daily_cap_gate_blocks_submit(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    db.update_preferences(conn, {"daily_cap": 0})
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    res = await run_application(make_ctx(conn, app.id, GH_RULES), GreenhouseAdapter())
    assert res.final_state is AppState.QUEUED and "daily cap" in (res.reason or "")
    assert ats_server.submissions == []
    assert states(conn, app.id)[-2:] == ["filling", "queued"]


async def test_unverified_submit_goes_to_unknown_verify(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.ASHBY, apply_url=ats_server.url("/ashby?fail=1"))
    res = await run_application(make_ctx(conn, app.id, ASHBY_RULES), AshbyAdapter())
    assert res.final_state is AppState.UNKNOWN_VERIFY
    assert len(ats_server.submissions) == 1
    # never retried automatically: the agent cannot leave unknown_verify
    for to in (AppState.SUBMITTED, AppState.FAILED, AppState.QUEUED):
        with pytest.raises(db.IllegalTransition):
            db.transition(conn, app.id, to)


async def test_submit_exception_goes_to_unknown_verify(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))

    class Exploding(GreenhouseAdapter):
        async def submit(self, ctx):  # type: ignore[no-untyped-def]
            raise RuntimeError("browser crashed mid-click")

    res = await run_application(make_ctx(conn, app.id, GH_RULES), Exploding())
    assert res.final_state is AppState.UNKNOWN_VERIFY and "browser crashed" in (res.reason or "")


async def test_fill_error_fails_application(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/nothing-here"))
    res = await run_application(make_ctx(conn, app.id, GH_RULES), GreenhouseAdapter())
    assert res.final_state is AppState.FAILED and "no application form" in (res.reason or "")


async def test_dry_run_changes_no_state(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    res = await run_application(make_ctx(conn, app.id, GH_RULES, dry_run=True), GreenhouseAdapter())
    assert res.final_state is AppState.QUEUED and res.reason == "dry_run"
    assert res.fill is not None and res.fill.ok and len(res.fill.answers) >= 9
    assert db.list_application_answers(conn, app.id) == []
    assert ats_server.submissions == []


async def test_with_workstream_b_answer_resolver(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    """End-to-end with B's real AnswerResolver (profile / never_guess / generation via a fake LLM)."""
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"),
                        description="Acme Robotics builds warehouse robots. Go, Kafka.")

    def gen(prompt: str, system: str | None, schema: dict | None) -> Any:
        if "How did you hear" in prompt:
            return {"answer": "Company website", "confidence": 0.95, "grounded": True, "story_ids": []}
        return {"answer": "I have built Go and Kafka systems and want to apply that to Acme's robots.",
                "confidence": 0.9, "grounded": True, "story_ids": []}

    llm = FakeLLMProvider(rules=[(r"GENERATE ANSWER", gen)])
    ctx = build_context(conn, app.id, llm=llm, extra={"always_cover_letter": False})
    res = await run_application(ctx, GreenhouseAdapter())
    assert res.final_state is AppState.SUBMITTED, (res, res.fill and res.fill.unresolved)
    [sub] = ats_server.submissions
    assert sub.fields["question_1003"] == ["0"]  # never_guess: sponsorship "Not required" -> No
    assert sub.fields["gender"] == ["3"]  # EEO declined by default
    assert sub.fields["question_1004"] == ["Company website"]
    rows = {r.field_key: r for r in db.list_application_answers(conn, app.id)}
    assert rows["question_1003"].origin is AnswerOrigin.NEVER_GUESS
    assert rows["question_1002"].origin is AnswerOrigin.GENERATED and rows["question_1002"].confidence == 0.9
