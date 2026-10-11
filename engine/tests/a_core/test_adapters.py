"""Scripted adapters driven by real headless Chromium against local fixture forms.

Dry-run (fill, never click) and fake-submit (the fixture form posts to the local server).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import httpx
import pytest
import respx

from autoapply import db
from autoapply.apply.ashby import AshbyAdapter
from autoapply.apply.base import (
    ApplyContext,
    build_context,
    close_all_sessions,
    scan_form,
    select_adapter,
    scripted_adapters,
)
from autoapply.apply.greenhouse import GreenhouseAdapter
from autoapply.apply.lever import LeverAdapter
from autoapply.enums import AnswerOrigin, Ats, FieldType, QuestionReason
from autoapply.llm.provider import FakeLLMProvider

from .conftest import EventSink, ScriptedResolver, load_json, seed_job

pytestmark = pytest.mark.usefixtures("profile", "resume")

GH_RULES: list[tuple[str, Any]] = [
    (r"why do you want", ("I want to build reliable robot fleets with Go.", "generated", 0.91)),
    (r"sponsorship", ("No", "never_guess", 1.0)),
    (r"hear about", ("LinkedIn", "memory", 0.95)),
    (r"gender", ("Decline To Self Identify", "never_guess", 1.0)),
]


def ctx_for(conn, app_id: int, resolver: ScriptedResolver | None = None, **kw: Any) -> ApplyContext:  # type: ignore[no-untyped-def]
    llm = kw.pop("llm", FakeLLMProvider(default=LLMBoom()))
    extra = kw.pop("extra", {})
    if resolver is not None:
        extra["resolver"] = resolver
    extra.setdefault("always_cover_letter", False)
    return build_context(conn, app_id, llm=llm, extra=extra, **kw)


class LLMBoom(Exception):
    """The default fake LLM response: any unexpected LLM call raises."""


@pytest.fixture(autouse=True)
async def _cleanup_sessions() -> Any:
    yield
    await close_all_sessions()


# =====================================================================================
# Routing
# =====================================================================================


def test_select_adapter_by_ats_and_url(conn) -> None:  # type: ignore[no-untyped-def]
    adapters = scripted_adapters()
    gh, _ = seed_job(conn, ats=Ats.GREENHOUSE, apply_url="https://boards.greenhouse.io/acme/jobs/1", title="A")
    lv, _ = seed_job(conn, ats=Ats.OTHER, apply_url="https://jobs.lever.co/acme/abc", title="B")
    ab, _ = seed_job(conn, ats=Ats.ASHBY, apply_url="https://jobs.ashbyhq.com/acme/abc", title="C")
    wd, _ = seed_job(conn, ats=Ats.WORKDAY, apply_url="https://acme.wd5.myworkdayjobs.com/x/job/1", title="D")
    assert isinstance(select_adapter(gh, adapters), GreenhouseAdapter)
    assert isinstance(select_adapter(lv, adapters), LeverAdapter)
    assert isinstance(select_adapter(ab, adapters), AshbyAdapter)
    assert select_adapter(wd, adapters) is None


def test_form_urls(conn) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url="https://acme.example/careers?gh_jid=42", title="A")
    db.upsert_company(conn, "Acme Robotics", ats=Ats.GREENHOUSE, board_token="acme")
    assert GreenhouseAdapter().form_url(ctx_for(conn, app.id)) == "https://job-boards.greenhouse.io/embed/job_app?for=acme&token=42"
    job, app = seed_job(conn, ats=Ats.LEVER, apply_url="https://jobs.lever.co/acme/abc", title="B")
    assert LeverAdapter().form_url(ctx_for(conn, app.id)) == "https://jobs.lever.co/acme/abc/apply"
    job, app = seed_job(conn, ats=Ats.ASHBY, apply_url="https://jobs.ashbyhq.com/acme/abc", title="C")
    assert AshbyAdapter().form_url(ctx_for(conn, app.id)) == "https://jobs.ashbyhq.com/acme/abc/application"
    assert AshbyAdapter().form_url(ctx_for(conn, app.id, extra={"form_url": "http://x/y"})) == "http://x/y"


# =====================================================================================
# Greenhouse
# =====================================================================================


async def test_greenhouse_scan(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page()
        await page.goto(ats_server.url("/greenhouse"))
        questions, kinds = await scan_form(page)
        await browser.close()
    by_key = {q.key: q for q in questions}
    assert list(by_key) == ["first_name", "last_name", "email", "phone", "resume", "cover_letter", "question_1001",
                            "question_1002", "question_1003", "question_1004", "gender"]
    assert by_key["first_name"].label == "First Name" and by_key["first_name"].required
    assert not by_key["phone"].required and by_key["phone"].field_type is FieldType.PHONE
    assert by_key["resume"].field_type is FieldType.FILE and by_key["resume"].required
    assert by_key["question_1003"].options == ["Yes", "No"]
    assert kinds["question_1004"] == "combobox" and by_key["question_1004"].options == ["LinkedIn", "Referral", "Company website"]
    assert by_key["question_1004"].label == "How did you hear about this job?"
    assert kinds["resume"] == "file" and kinds["gender"] == "select"


async def test_greenhouse_dry_run_fills_everything_without_submitting(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    sink = EventSink()
    resolver = ScriptedResolver(conn, GH_RULES)
    ctx = ctx_for(conn, app.id, resolver, emit=sink, dry_run=True)
    adapter = GreenhouseAdapter()
    fill = await adapter.fill(ctx)
    assert fill.ok and not fill.unresolved, fill
    got = {a.key: (a.answer, a.origin) for a in fill.answers}
    assert got["first_name"] == ("Ada", AnswerOrigin.PROFILE)
    assert got["last_name"] == ("Lovelace", AnswerOrigin.PROFILE)
    assert got["email"] == ("ada@example.com", AnswerOrigin.PROFILE)
    assert got["resume"] == ("ada_resume.pdf", AnswerOrigin.CV)
    assert got["question_1001"] == ("https://linkedin.com/in/ada", AnswerOrigin.PROFILE)
    assert got["question_1003"] == ("No", AnswerOrigin.NEVER_GUESS)
    assert got["question_1004"] == ("LinkedIn", AnswerOrigin.MEMORY)
    assert "cover_letter" not in got  # optional, generation disabled
    assert Path(fill.screenshot_path).exists() and Path(fill.screenshot_path).stat().st_size > 1000
    assert db.list_application_answers(conn, app.id) == []  # dry-run persists nothing
    res = await adapter.submit(ctx)
    assert not res.verified and not res.clicked and "dry_run" in (res.error or "")
    assert ats_server.submissions == []
    steps = sink.of("agent_step")
    assert steps and steps[0].index == 0 and any("Why do you want" in s.action for s in steps)


async def test_greenhouse_fake_submit(conn, ats_server, autoapply_home) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    resolver = ScriptedResolver(conn, GH_RULES)
    ctx = ctx_for(conn, app.id, resolver)
    adapter = GreenhouseAdapter()
    fill = await adapter.fill(ctx)
    assert fill.ok and not fill.unresolved
    rows = {a.field_key: a for a in db.list_application_answers(conn, app.id)}
    assert rows["question_1002"].origin is AnswerOrigin.GENERATED and rows["question_1002"].confidence == 0.91
    assert rows["first_name"].origin is AnswerOrigin.PROFILE and rows["first_name"].origin_ref == "profile:first_name"
    assert rows["resume"].origin is AnswerOrigin.CV and rows["resume"].answer == "ada_resume.pdf"
    res = await adapter.submit(ctx)
    assert res.verified, res
    assert Path(res.confirmation_screenshot_path).exists()
    [sub] = ats_server.submissions
    f = sub.fields
    assert f["first_name"] == ["Ada"] and f["last_name"] == ["Lovelace"] and f["email"] == ["ada@example.com"]
    assert f["question_1002"] == ["I want to build reliable robot fleets with Go."]
    assert f["question_1003"] == ["0"]  # option "No"
    assert f["question_1004"] == ["LinkedIn"]  # combobox picked from the listbox
    assert f["gender"] == ["3"]
    assert sub.files["resume"][0] == "ada_resume.pdf" and sub.files["resume"][1].startswith(b"%PDF")


async def test_greenhouse_unresolved_required_question(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    rules = [r for r in GH_RULES if "sponsorship" not in r[0]] + [(r"sponsorship", ("needs", QuestionReason.NEVER_GUESS, "sponsorship"))]
    fill = await GreenhouseAdapter().fill(ctx_for(conn, app.id, ScriptedResolver(conn, rules)))
    assert fill.ok
    [u] = fill.unresolved
    assert u.question.key == "question_1003" and u.reason == "never_guess" and u.never_guess_key == "sponsorship"
    assert u.question.options == ["Yes", "No"]
    # the other answers were still filled + recorded so the inbox gets every gap in one pass
    assert {a.field_key for a in db.list_application_answers(conn, app.id)} >= {"first_name", "question_1002", "question_1004"}


async def test_greenhouse_missing_resume_is_unresolved(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    ctx = ctx_for(conn, app.id, ScriptedResolver(conn, GH_RULES))
    ctx.resume = None
    fill = await GreenhouseAdapter().fill(ctx)
    assert [u.question.key for u in fill.unresolved] == ["resume"]


async def test_greenhouse_harvest_questions_via_api(conn) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url="https://job-boards.greenhouse.io/acmerobotics/jobs/4012345002")
    with respx.mock:
        respx.get("https://boards-api.greenhouse.io/v1/boards/acmerobotics/jobs/4012345002").mock(
            return_value=httpx.Response(200, json=load_json("greenhouse_job_questions.json"))
        )
        async with httpx.AsyncClient() as http:
            qs = await GreenhouseAdapter().harvest_questions(ctx_for(conn, app.id, extra={"http": http}))
    assert [q.key for q in qs][:3] == ["first_name", "last_name", "email"] and len(qs) == 13


async def test_captcha_is_reported_not_filled(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/captcha"))
    fill = await GreenhouseAdapter().fill(ctx_for(conn, app.id, ScriptedResolver(conn, [])))
    [u] = fill.unresolved
    assert u.reason == "captcha"
    assert db.list_application_answers(conn, app.id) == []


async def test_submit_refused_on_disallowed_host(conn, ats_server, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    ctx = ctx_for(conn, app.id, ScriptedResolver(conn, GH_RULES))
    adapter = GreenhouseAdapter()
    assert (await adapter.fill(ctx)).ok
    monkeypatch.setenv("AUTOAPPLY_SUBMIT_ALLOWED_HOSTS", "only-this-host.invalid")
    res = await adapter.submit(ctx)
    assert not res.verified and not res.clicked and "refused" in (res.error or "")
    assert ats_server.submissions == []


# =====================================================================================
# Lever
# =====================================================================================

LEVER_RULES: list[tuple[str, Any]] = [
    (r"distributed system", ("Designed a Kafka-based telemetry pipeline at Analytical Engines.", "story", 0.88)),
    (r"authorized to work", ("Yes", "never_guess", 1.0)),
    (r"languages", ("Go; Python", "profile", 1.0)),
    (r"gender", ("Decline to self-identify", "never_guess", 1.0)),
    (r"I agree", ("Yes", "user", 1.0)),
]


async def test_lever_fake_submit(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.LEVER, apply_url=ats_server.url("/lever"))
    ctx = ctx_for(conn, app.id, ScriptedResolver(conn, LEVER_RULES))
    adapter = LeverAdapter()
    fill = await adapter.fill(ctx)
    assert fill.ok and not fill.unresolved, fill.unresolved
    got = {a.key: a.answer for a in fill.answers}
    assert got["name"] == "Ada Lovelace" and got["org"] == "Analytical Engines"
    assert got["urls[GitHub]"] == "https://github.com/ada"
    res = await adapter.submit(ctx)
    assert res.verified, res
    [sub] = ats_server.submissions
    f = sub.fields
    assert f["name"] == ["Ada Lovelace"] and f["email"] == ["ada@example.com"] and f["org"] == ["Analytical Engines"]
    assert f["urls[LinkedIn]"] == ["https://linkedin.com/in/ada"]
    assert f["cards[7c1a][field0]"] == ["Designed a Kafka-based telemetry pipeline at Analytical Engines."]
    assert f["cards[7c1a][field1]"] == ["Yes"]
    assert f["cards[7c1a][field2]"] == ["Go", "Python"]
    assert f["eeo[gender]"] == ["Decline to self-identify"]
    assert f["consent[store]"] == ["true"]
    assert "comments" not in f or f["comments"] == [""]  # optional, resolver skipped it
    assert sub.files["resume"][0] == "ada_resume.pdf"


async def test_lever_harvest_questions_by_scanning(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.LEVER, apply_url=ats_server.url("/lever"))
    qs = await LeverAdapter().harvest_questions(ctx_for(conn, app.id))
    by_key = {q.key: q for q in qs}
    assert by_key["cards[7c1a][field0]"].label == "Describe a distributed system you designed." and by_key["cards[7c1a][field0]"].required
    assert by_key["cards[7c1a][field1]"].options == ["Yes", "No"] and by_key["cards[7c1a][field1]"].required
    assert by_key["cards[7c1a][field2]"].field_type is FieldType.MULTISELECT and not by_key["cards[7c1a][field2]"].required
    assert by_key["resume"].required and by_key["consent[store]"].field_type is FieldType.BOOLEAN
    assert not by_key["phone"].required
    assert ats_server.submissions == []


# =====================================================================================
# Ashby
# =====================================================================================

ASHBY_RULES: list[tuple[str, Any]] = [
    (r"excites you", ("Robots that ship packages are the best kind of distributed system.", "generated", 0.9)),
    (r"years of professional experience", ("6-9", "profile", 1.0)),
    (r"relocating", ("No", "never_guess", 1.0)),
]


async def test_ashby_fake_submit_with_yes_no_buttons(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.ASHBY, apply_url=ats_server.url("/ashby"))
    ctx = ctx_for(conn, app.id, ScriptedResolver(conn, ASHBY_RULES))
    adapter = AshbyAdapter()
    fill = await adapter.fill(ctx)
    assert fill.ok and not fill.unresolved, fill.unresolved
    keys = {a.key for a in fill.answers}
    assert {"_systemfield_name", "_systemfield_email", "_systemfield_resume", "a91e-relocate"} <= keys
    res = await adapter.submit(ctx)
    assert res.verified, res
    [sub] = ats_server.submissions
    assert sub.fields["_systemfield_name"] == ["Ada Lovelace"]
    assert sub.fields["a91e-relocate"] == ["No"]
    assert sub.fields["8f00b7aa-yoe"] == ["6-9"]
    assert sub.files["_systemfield_resume"][0] == "ada_resume.pdf"


async def test_ashby_rejected_submission_is_not_verified(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.ASHBY, apply_url=ats_server.url("/ashby?fail=1"))
    ctx = ctx_for(conn, app.id, ScriptedResolver(conn, ASHBY_RULES))
    adapter = AshbyAdapter()
    assert (await adapter.fill(ctx)).ok
    res = await adapter.submit(ctx)
    assert not res.verified and res.clicked and "went wrong" in (res.error or "")
    assert len(ats_server.submissions) == 1  # clicked exactly once, never retried


# =====================================================================================
# Safety regressions: filling must never submit
# =====================================================================================


async def test_combobox_non_first_option_never_submits(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    """Regression: picking a filtered combobox option used to fall back to pressing Enter,
    which submitted the form mid-fill."""
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    rules = [(r"hear about", ("Referral", "memory", 0.95)), *GH_RULES]
    ctx = ctx_for(conn, app.id, ScriptedResolver(conn, rules), dry_run=True)
    fill = await GreenhouseAdapter().fill(ctx)
    assert fill.ok and not fill.unresolved
    assert {a.key: a.answer for a in fill.answers}["question_1004"] == "Referral"
    assert ats_server.submissions == []


async def test_stray_form_submit_during_fill_is_blocked(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))

    class SubmitsDuringFill(GreenhouseAdapter):
        async def open_form(self, page, ctx):  # type: ignore[no-untyped-def]
            await super().open_form(page, ctx)
            await page.evaluate("document.getElementById('application-form').submit()")
            await page.wait_for_timeout(300)

    fill = await SubmitsDuringFill().fill(ctx_for(conn, app.id, ScriptedResolver(conn, GH_RULES)))
    assert not fill.ok and "tried to submit" in (fill.error or "")
    assert ats_server.submissions == []
