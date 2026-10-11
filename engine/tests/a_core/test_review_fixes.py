"""Regressions for review findings on the scripted adapters (all local; real headless Chromium).

* submit verification must not trust confirmation text that was already on the form page;
* answers the pre-submit audit rejected must not be reused on the next fill;
* B's deliberate "no match" is final, and choice controls record what was actually selected;
* a combobox never clicks a non-matching suggestion;
* a fetch/XHR submit during fill is blocked like a native form POST;
* a re-opened session for the same application closes the previous one.
"""

from __future__ import annotations

from typing import Any

import pytest

from autoapply import db
from autoapply.apply import base as apply_base
from autoapply.apply.ashby import AshbyAdapter
from autoapply.apply.base import (
    _OPEN_SESSIONS,
    _is_stray_submit,
    _strict_match_option,
    close_all_sessions,
    fill_control_value,
    match_option,
    open_session,
    run_application,
)
from autoapply.apply.greenhouse import GreenhouseAdapter
from autoapply.enums import Actor, AnswerOrigin, AppState, Ats

from .conftest import ScriptedResolver, seed_job
from .test_adapters import ASHBY_RULES, GH_RULES, ctx_for
from .test_runner import make_ctx

pytestmark = pytest.mark.usefixtures("profile", "resume")


@pytest.fixture(autouse=True)
async def _cleanup_sessions() -> Any:
    yield
    await close_all_sessions()


# =====================================================================================
# Verification false positives
# =====================================================================================

_INJECT_THANKS_AND_BLOCK = """() => {
  const p = document.createElement('p');
  p.textContent = 'Thank you for applying to Acme Robotics! Thank you for your interest in Acme Robotics.';
  document.body.prepend(p);
  const form = document.getElementById('application-form');
  form.addEventListener('submit', (ev) => ev.preventDefault());  // the click does nothing
}"""


class _DescriptionThanksGreenhouse(GreenhouseAdapter):
    """The job description above the form already contains confirmation wording, and the
    form's submit handler swallows the click (client-side validation / broken JS)."""

    submit_timeout_s = 2.0

    async def open_form(self, page, ctx):  # type: ignore[no-untyped-def]
        await super().open_form(page, ctx)
        await page.evaluate(_INJECT_THANKS_AND_BLOCK)


async def test_preexisting_confirmation_text_does_not_verify(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    res = await run_application(make_ctx(conn, app.id, GH_RULES), _DescriptionThanksGreenhouse())
    assert ats_server.submissions == []
    assert res.final_state is AppState.UNKNOWN_VERIFY, res
    assert res.submit is not None and res.submit.clicked and not res.submit.verified
    assert db.get_company(conn, job.company_id).last_applied_at is None


async def test_preexisting_text_still_verifies_after_real_submit(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    """Same description text, but the form really posts: the navigation verifies it."""

    class DescriptionOnly(GreenhouseAdapter):
        async def open_form(self, page, ctx):  # type: ignore[no-untyped-def]
            await super().open_form(page, ctx)
            await page.evaluate("() => { const p = document.createElement('p');"
                                " p.textContent = 'Thank you for applying!'; document.body.prepend(p); }")

    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    res = await run_application(make_ctx(conn, app.id, GH_RULES), DescriptionOnly())
    assert res.final_state is AppState.SUBMITTED, res
    assert len(ats_server.submissions) == 1


async def test_verify_without_snapshot_requires_page_change(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    ctx = ctx_for(conn, app.id, ScriptedResolver(conn, GH_RULES))
    adapter = GreenhouseAdapter()
    adapter.submit_timeout_s = 1.0
    session = await open_session(ctx)
    await session.page.goto(ats_server.url("/greenhouse"))
    await session.page.evaluate(_INJECT_THANKS_AND_BLOCK)
    before = session.page.url
    res = await adapter._verify(session.page, ctx, before)
    assert not res.verified
    res = await adapter._verify(session.page, ctx, before, confirm_hits_before=0)
    assert res.verified  # new text (hits grew from 0) counts


def test_default_confirm_text_ignores_your_interest() -> None:
    assert not apply_base._DEFAULT_CONFIRM_TEXT.search("Thank you for your interest in Acme Robotics.")
    assert apply_base._DEFAULT_CONFIRM_TEXT.search("Thank you for applying.")


# =====================================================================================
# Audit-flagged answers are not reused
# =====================================================================================


async def test_flagged_low_confidence_answer_is_not_reused_after_inbox_answer(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    rules = [(r"why do you want", ("meh guess", "generated", 0.2)), *GH_RULES]
    res = await run_application(make_ctx(conn, app.id, rules), GreenhouseAdapter())
    assert res.final_state is AppState.NEEDS_YOU
    assert [(u.question.key, u.reason) for u in res.fill.unresolved] == [("question_1002", "low_confidence")]
    keys = {r.field_key for r in db.list_application_answers(conn, app.id)}
    assert "question_1002" not in keys and "first_name" in keys  # rejected row dropped, others kept

    db.transition(conn, app.id, AppState.QUEUED, actor=Actor.USER)  # user answered in the inbox
    rules2 = [(r"why do you want", ("USER ANSWER", "user", 1.0)), *GH_RULES]
    ctx = make_ctx(conn, app.id, rules2)
    res2 = await run_application(ctx, GreenhouseAdapter())
    assert res2.final_state is AppState.SUBMITTED, res2
    assert "Why do you want to work at Acme Robotics?" in ctx.extra["resolver"].asked
    [sub] = ats_server.submissions
    assert sub.fields["question_1002"] == ["USER ANSWER"]
    rows = [r for r in db.list_application_answers(conn, app.id) if r.field_key == "question_1002"]
    assert [(r.answer, r.origin) for r in rows] == [("USER ANSWER", AnswerOrigin.USER)]


async def test_flagged_always_ask_answer_is_not_reused(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    db.update_preferences(conn, {"always_ask_patterns": ["hear about"]})
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    res = await run_application(make_ctx(conn, app.id, GH_RULES), GreenhouseAdapter())
    assert res.final_state is AppState.NEEDS_YOU
    assert [(u.question.key, u.reason) for u in res.fill.unresolved] == [("question_1004", "always_ask")]
    db.transition(conn, app.id, AppState.QUEUED, actor=Actor.USER)
    rules2 = [(r"hear about", ("Referral", "user", 1.0)), *GH_RULES]
    res2 = await run_application(make_ctx(conn, app.id, rules2), GreenhouseAdapter())
    assert res2.final_state is AppState.SUBMITTED, res2
    assert ats_server.submissions[-1].fields["question_1004"] == ["Referral"]


# =====================================================================================
# Option matching
# =====================================================================================


def test_b_none_is_not_overridden() -> None:
    assert match_option("I prefer not to answer", ["Yes", "No"]) is None
    assert match_option("No", ["Yes", "No"]) == "No"


def test_strict_fallback_is_whole_word() -> None:
    assert _strict_match_option("I prefer not to answer", ["Yes", "No"]) is None
    assert _strict_match_option("no", ["No", "Yes"]) == "No"
    assert _strict_match_option("Referral", ["LinkedIn", "Employee Referral"]) == "Employee Referral"
    assert _strict_match_option("", ["Yes"]) is None


def test_strict_fallback_used_when_b_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    import autoapply.answers.textnorm as tn

    def boom(*a: Any, **k: Any) -> None:
        raise RuntimeError("broken")

    monkeypatch.setattr(tn, "match_option", boom)
    assert match_option("I prefer not to answer", ["Yes", "No"]) is None
    assert match_option("yes", ["Yes", "No"]) == "Yes"


_CHOICE_PAGE = """<html><body><form>
<select data-aa-key="sel"><option value="">--</option><option value="1">Yes</option><option value="0">No</option></select>
<input data-aa-key="cb" role="combobox" aria-controls="cb-list" autocomplete="off">
<ul id="cb-list" role="listbox" hidden><li role="option">Company website</li></ul>
<script>
  const i = document.querySelector('[data-aa-key=cb]'), l = document.getElementById('cb-list');
  i.addEventListener('input', () => { l.hidden = false; });  // always suggests the same one
  l.querySelector('li').addEventListener('click', (e) => { i.value = e.target.textContent; l.hidden = true; });
</script>
<input data-aa-key="cb2" role="combobox" aria-controls="cb2-list" autocomplete="off">
<ul id="cb2-list" role="listbox" hidden><li role="option">San Francisco, California, United States</li></ul>
<script>
  const i2 = document.querySelector('[data-aa-key=cb2]'), l2 = document.getElementById('cb2-list');
  i2.addEventListener('input', () => { l2.hidden = false; });
  l2.querySelector('li').addEventListener('click', (e) => { i2.value = e.target.textContent; l2.hidden = true; });
</script>
</form></body></html>"""


async def test_choice_controls_report_applied_option() -> None:
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page()
        await page.set_content(_CHOICE_PAGE)
        assert await fill_control_value(page, "sel", "select", "no", ["Yes", "No"]) == "No"
        assert await fill_control_value(page, "sel", "select", "I prefer not to answer", ["Yes", "No"]) is None
        # The only suggestion does not match the answer: never click it.
        assert await fill_control_value(page, "cb", "combobox", "Twitter") is None
        assert await page.input_value("[data-aa-key=cb]") != "Company website"
        # A single suggestion extending the typed text at a word boundary is a match.
        got = await fill_control_value(page, "cb2", "combobox", "San Francisco")
        assert got == "San Francisco, California, United States"
        await browser.close()


async def test_greenhouse_combobox_without_match_is_unresolved(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    rules = [(r"hear about", ("Twitter", "memory", 0.95)), *GH_RULES]
    fill = await GreenhouseAdapter().fill(ctx_for(conn, app.id, ScriptedResolver(conn, rules), dry_run=True))
    [u] = fill.unresolved
    assert u.question.key == "question_1004" and u.suggested_answer == "Twitter"
    assert "question_1004" not in {a.key for a in fill.answers}


# =====================================================================================
# Fetch/XHR submit during fill
# =====================================================================================


async def test_xhr_submit_during_fill_is_blocked(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.ASHBY, apply_url=ats_server.url("/ashby"))

    class RequestSubmitDuringFill(AshbyAdapter):
        async def _fill_questions(self, ctx, page, questions, kinds, result):  # type: ignore[no-untyped-def]
            await super()._fill_questions(ctx, page, questions, kinds, result)
            await page.evaluate("document.querySelector('form').requestSubmit()")
            await page.wait_for_timeout(500)

    fill = await RequestSubmitDuringFill().fill(ctx_for(conn, app.id, ScriptedResolver(conn, ASHBY_RULES)))
    assert not fill.ok and "tried to submit" in (fill.error or "")
    assert ats_server.submissions == []


class _Req:
    def __init__(self, method: str, url: str, rtype: str, nav: bool = False, body: str = "") -> None:
        self.method, self.url, self.resource_type, self._nav, self.post_data = method, url, rtype, nav, body

    def is_navigation_request(self) -> bool:
        return self._nav


def test_is_stray_submit_classification() -> None:
    page = "https://jobs.ashbyhq.com/acme/123/application"
    assert _is_stray_submit(_Req("POST", "https://boards.greenhouse.io/acme/jobs/1", "document", nav=True), page)
    assert not _is_stray_submit(_Req("GET", "https://jobs.ashbyhq.com/x", "fetch"), page)
    assert _is_stray_submit(_Req("POST", "https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiSubmitSingleApplicationFormAction",
                                 "fetch"), page)
    assert _is_stray_submit(_Req("POST", "https://jobs.ashbyhq.com/api/graphql", "fetch",
                                 body='{"operationName":"ApiSubmitApplication","variables":{}}'), page)
    assert not _is_stray_submit(_Req("POST", "https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiCreateFileUploadHandle",
                                     "fetch"), page)
    assert not _is_stray_submit(_Req("POST", "https://jobs.ashbyhq.com/api/graphql", "xhr",
                                     body='{"operationName":"ApiAutocompleteGeoLocation"}'), page)
    assert not _is_stray_submit(_Req("POST", "https://s3.amazonaws.com/bucket/applications/upload", "xhr"), page)


# =====================================================================================
# Session registry
# =====================================================================================


async def test_reopening_session_for_same_application_closes_previous(conn, ats_server) -> None:  # type: ignore[no-untyped-def]
    job, app = seed_job(conn, ats=Ats.GREENHOUSE, apply_url=ats_server.url("/greenhouse"))
    first = await open_session(ctx_for(conn, app.id, ScriptedResolver(conn, GH_RULES)))
    second = await open_session(ctx_for(conn, app.id, ScriptedResolver(conn, GH_RULES)))
    assert first is not second
    assert first.page.is_closed()
    assert _OPEN_SESSIONS[app.id] is second
