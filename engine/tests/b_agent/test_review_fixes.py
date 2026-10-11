"""Regression tests for the review findings on workstream B (gate bypasses, never-guess
resolution, inbox clustering, submit-phase guarantees, captcha badge, cover-letter check)."""

from __future__ import annotations

import itertools
import os
import time

from autoapply import db
from autoapply.answers.cover_letter import fact_check
from autoapply.answers.guardrails import (
    AnswerForCheck,
    check_answers,
    classify_never_guess,
    resolve_never_guess,
)
from autoapply.answers.textnorm import match_option
from autoapply.apply.agentic import ToolGate, browser_id
from autoapply.apply.base import UnresolvedField
from autoapply.config import NeverGuess, Preferences
from autoapply.enums import AnswerOrigin, AppState, QuestionReason, QuestionStatus
from autoapply.models import FormQuestion
from autoapply.prep import answer_cluster, form_label, park_unresolved, skip_cluster

from .conftest import make_job
from .test_agentic import (  # noqa: F401
    FILL_SCRIPT,
    SNAPSHOT,
    adapter_with,
    ctx_for,
    step,
    submit_request,
    world,
)

CLICK, KEY, TYPE = browser_id("browser_click"), browser_id("browser_press_key"), browser_id("browser_type")
_c = itertools.count()


def _chk(g: ToolGate, tool: str, inp: dict) -> bool:
    return g.check(tool, inp, f"r{next(_c)}").allowed


# ---- gate: keyboard -------------------------------------------------------------------


def test_tab_then_enter_or_space_after_combobox_is_denied():
    g = ToolGate()
    g.observe('- combobox "Country" [ref=e1]\n- button "Submit application" [ref=e2]\n- checkbox "Subscribe" [ref=e3]')
    assert _chk(g, TYPE, {"element": "Country", "ref": "e1", "text": "Uni"})
    assert _chk(g, KEY, {"key": "ArrowDown"})
    assert _chk(g, KEY, {"key": "Enter"})          # picking the option: allowed
    assert not _chk(g, KEY, {"key": "Enter"})      # a second Enter needs a new interaction
    assert _chk(g, TYPE, {"element": "Country", "ref": "e1", "text": "Uni"})
    assert _chk(g, KEY, {"key": "Tab"})            # focus may now be on the submit button
    assert not _chk(g, KEY, {"key": "Enter"})
    assert not _chk(g, KEY, {"key": " "})
    assert not _chk(g, KEY, {"key": "Space"})
    assert not _chk(g, KEY, {"key": "Shift+Enter"})
    assert not _chk(g, KEY, {"key": "NumpadEnter"})
    # Space on a checkbox that was just clicked is fine
    assert _chk(g, CLICK, {"element": "Subscribe", "ref": "e3"})
    assert _chk(g, KEY, {"key": " "})


def test_typed_newline_key_by_key_is_denied():
    g = ToolGate()
    g.observe(SNAPSHOT)
    assert not _chk(g, TYPE, {"element": "First name", "ref": "e2", "text": "hi\n", "slowly": True})
    assert _chk(g, TYPE, {"element": "First name", "ref": "e2", "text": "Ada"})


# ---- gate: final buttons with weak labels ------------------------------------------------


def test_apply_send_done_complete_are_submit_controls_once_data_entered():
    snap = "\n".join(f'- button "{lbl}" [ref=b{i}]' for i, lbl in enumerate(
        ["Apply", "Apply for this job", "Send", "Done", "Complete", "Apply Now", "Next", "Save and continue"]))
    snap += '\n- textbox "First name" [ref=e2]\n- radio "Done" [ref=r1]'
    g = ToolGate()
    g.observe(snap)
    assert _chk(g, CLICK, {"element": "Apply", "ref": "b0"})  # opening the form: no data entered yet
    assert _chk(g, TYPE, {"element": "First name", "ref": "e2", "text": "Ada"})
    for i in range(6):
        assert not _chk(g, CLICK, {"element": "the button", "ref": f"b{i}"}), i
    assert _chk(g, CLICK, {"element": "Next", "ref": "b6"})
    assert _chk(g, CLICK, {"element": "Save and continue", "ref": "b7"})
    assert _chk(g, CLICK, {"element": "Done option", "ref": "r1"})  # a radio, not a button
    # armed: a weak-label final button IS the submit click, and is counted
    g.arm_submit()
    assert _chk(g, CLICK, {"element": "Send", "ref": "b2"}) and g.submit_clicked
    assert not _chk(g, CLICK, {"element": "Send", "ref": "b2"})


# ---- request_submit cross-checks entered values ------------------------------------------


async def test_unreported_typed_value_blocks_request_submit(world):  # noqa: F811
    log: dict = {}
    sneaky = [*FILL_SCRIPT[:3],
              step("browser_type", {"element": "First name", "ref": "e2", "text": "Ada"}),
              step("browser_type", {"element": "Are you authorized to work in the US?", "ref": "e7", "text": "Yes"}),
              *FILL_SCRIPT[4:], submit_request()]
    res = await adapter_with([sneaky], log).fill(ctx_for(world))
    assert not res.ok
    refusal = log["clients"][0].results[-1][1]
    assert "authorized to work" in refusal and "'Yes'" in refusal
    assert db.list_application_answers(world["conn"], world["app"].id) == []


# ---- submit phase: stale screenshot / unapproved answers / leaks -------------------------


async def test_submit_phase_rejects_stale_prefill_screenshot(world):  # noqa: F811
    conn = world["conn"]
    log: dict = {}
    ad = adapter_with([[*FILL_SCRIPT, submit_request()], [
        *[s for s in FILL_SCRIPT if not s[0].endswith("browser_take_screenshot")],
        submit_request(),  # no screenshot taken in this session: the Review-time prefill.png must not count
        step("browser_click", {"element": "Submit application", "ref": "e9"}),
    ]], log)
    ctx = ctx_for(world)
    assert (await ad.fill(ctx)).ok
    shot = os.path.join(ctx.screenshots_dir, "prefill.png")
    old = time.time() - 600
    os.utime(shot, (old, old))
    db.transition(conn, world["app"].id, AppState.AWAITING_REVIEW)
    db.begin_submit(conn, world["app"].id, actor="user")
    res = await ad.submit(ctx_for(world))
    assert not res.verified and res.error.startswith("not_submitted") and "screenshot" in res.error
    assert not ad.last_toolbox.gate.submit_clicked


async def test_submit_phase_refuses_answers_not_approved(world):  # noqa: F811
    conn = world["conn"]
    log: dict = {}
    ad = adapter_with([[*FILL_SCRIPT, submit_request()], [
        step("lookup_answer", {"question": "Why Stripe, in one line?", "field_type": "text"}),  # new, generated
        step("browser_take_screenshot", {"fullPage": True, "filename": "presubmit.png"}),
        step("request_submit", {"answers": [
            {"question": "First name", "answer": "Ada"},
            {"question": "Email", "answer": "ada@example.com"},
            {"question": "Will you require sponsorship?", "answer": "No"},
            {"question": "Why do you want to work at Stripe?", "answer": "I want to build payments infrastructure."},
            {"question": "Why Stripe, in one line?", "answer": "I want to build payments infrastructure."},
        ], "screenshot": "presubmit.png"}),
    ]], log)
    assert (await ad.fill(ctx_for(world))).ok
    db.transition(conn, world["app"].id, AppState.AWAITING_REVIEW)
    db.begin_submit(conn, world["app"].id, actor="user")
    res = await ad.submit(ctx_for(world))
    assert not res.verified and "not part of the approved answers" in res.error
    assert not ad.last_toolbox.gate.submit_armed


async def test_new_fill_releases_leaked_live_session(world):  # noqa: F811
    conn = world["conn"]
    db.update_preferences(conn, {"per_ats_mode": {}})  # Auto => session kept open after fill
    log: dict = {}
    ad = adapter_with([[*FILL_SCRIPT, submit_request()], [*FILL_SCRIPT, submit_request()]], log)
    assert (await ad.fill(ctx_for(world))).ok
    first = log["clients"][0]
    assert first.connected and ad._live
    # the pipeline never called close() (e.g. cap reached) and fills again later
    assert (await ad.fill(ctx_for(world))).ok
    assert not first.connected


# ---- never-guess resolution ----------------------------------------------------------------


def test_sponsorship_uses_country_specific_status_over_global_text():
    q = FormQuestion(key="s", label="Will you now or in the future require visa sponsorship to work in the United States?")
    q_any = FormQuestion(key="s", label="Will you require visa sponsorship?")
    # country status wins (no global text)
    ng = NeverGuess(work_auth={"US": "requires_sponsorship", "IN": "citizen"})
    assert resolve_never_guess("sponsorship", ng, q, country="IN") == "Yes"  # question names the US
    assert resolve_never_guess("sponsorship", ng, q_any, country="IN") == "No"
    # global "Not required" (true for India) contradicts the US status -> ask, never "No"
    ng = NeverGuess(work_auth={"US": "requires_sponsorship", "IN": "citizen"}, sponsorship="Not required")
    assert resolve_never_guess("sponsorship", ng, q, country="US") is None
    assert resolve_never_guess("sponsorship", ng, q_any, country="IN") == "No"  # agree
    v = check_answers([AnswerForCheck(q, "No", AnswerOrigin.NEVER_GUESS)], ng, Preferences(), country="US")
    assert v  # the false "No" no longer passes the pre-submit audit
    # no country status at all -> the global text applies
    assert resolve_never_guess("sponsorship", NeverGuess(sponsorship="Not required"), q_any, country="DE") == "No"


def test_work_auth_unknown_job_country_is_never_guessed():
    ng = NeverGuess(work_auth={"US": "citizen"})
    q = FormQuestion(key="w", label="Are you legally authorized to work in the country where this job is located?", options=["Yes", "No"])
    assert resolve_never_guess("work_auth", ng, q, country=None) is None
    assert resolve_never_guess("work_auth", ng, q, country="US") == "Yes"
    assert resolve_never_guess("sponsorship", ng, FormQuestion(key="s", label="Do you require sponsorship?"), country=None) is None


def test_work_auth_status_select_picks_the_stored_status():
    ng = NeverGuess(work_auth={"US": "green_card"})
    opts = ["Yes - US Citizen", "Yes - Green Card holder", "Yes - H-1B visa (will require sponsorship)", "No"]
    q = FormQuestion(key="w", label="What is your work authorization status in the US?", options=opts)
    assert resolve_never_guess("work_auth", ng, q, country="US") == "Yes - Green Card holder"
    # an "authorized" status cannot pick between several status options -> ask
    assert resolve_never_guess("work_auth", NeverGuess(work_auth={"US": "authorized"}), q, country="US") is None


def test_match_option_ambiguous_yes_options():
    assert match_option(True, ["Yes - US Citizen", "Yes - Green Card holder", "No"]) is None
    assert match_option(True, ["Yes", "Yes, I will require sponsorship", "No"]) == "Yes"
    assert match_option(False, ["Yes", "No"]) == "No"


def test_commute_and_team_moves_are_not_relocation():
    assert classify_never_guess("Are you willing to commute to our San Francisco office three days a week?") is None
    assert classify_never_guess("Are you open to moving between teams after onboarding?") is None
    assert classify_never_guess("Are you open to moving to another team after onboarding?") is None
    assert classify_never_guess("Are you willing to relocate to London?") == "relocation"
    assert classify_never_guess("Are you open to moving to Berlin for this role?") == "relocation"


# ---- inbox clustering ----------------------------------------------------------------------


def _uf(label: str, key: str | None) -> UnresolvedField:
    return UnresolvedField(question=FormQuestion(key="k", label=label), reason=QuestionReason.NEVER_GUESS.value, never_guess_key=key)


def test_unclassified_sensitive_questions_do_not_share_a_cluster(conn):
    j1, _ = make_job(conn, "Stripe", "Eng", state=AppState.NEEDS_YOU)
    j2, _ = make_job(conn, "Monzo", "Eng", state=AppState.NEEDS_YOU)
    park_unresolved(conn, j1.id, [_uf("What is your nationality?", "unclassified_sensitive")])
    park_unresolved(conn, j2.id, [_uf("Do you consent to our privacy policy terms?", "unclassified_sensitive")])
    clusters = {q.cluster_id for q in db.list_questions(conn, status=QuestionStatus.OPEN)}
    assert len(clusters) == 2


def test_country_dependent_questions_split_by_country(conn):
    us, _ = make_job(conn, "Stripe", "Eng", location="San Francisco, CA", state=AppState.NEEDS_YOU)
    uk, _ = make_job(conn, "Monzo", "Eng", location="London", state=AppState.NEEDS_YOU)
    label = "Are you legally authorized to work in the country where this role is based?"
    park_unresolved(conn, us.id, [_uf(label, "work_auth")])
    park_unresolved(conn, uk.id, [_uf(label, "work_auth")])
    park_unresolved(conn, us.id, [_uf("Will you require sponsorship to work in the US?", "sponsorship")])
    park_unresolved(conn, uk.id, [_uf("Will you require sponsorship to work in the UK?", "sponsorship")])
    qs = db.list_questions(conn, status=QuestionStatus.OPEN)
    assert len({q.cluster_id for q in qs}) == 4
    uk_q = next(q for q in qs if q.job_ids == [uk.id] and "where this role" in q.canonical_question)
    assert uk_q.canonical_question.endswith("[job location: United Kingdom]")
    # answering the UK cluster only touches the UK job, keyed by the form's own wording
    out = answer_cluster(conn, uk_q.cluster_id, "No")
    assert out.job_ids == [uk.id]
    from autoapply.answers.resolver import get_inbox_answers

    assert get_inbox_answers(conn, uk.id) == {"are you legally authorized to work in the country where this role is based": "No"}
    assert get_inbox_answers(conn, us.id) == {}
    assert form_label(uk_q.canonical_question) == label


def test_skip_cluster_reports_side_effect_clusters(conn):
    j1, _ = make_job(conn, "Stripe", "Eng", state=AppState.NEEDS_YOU)
    j2, _ = make_job(conn, "Monzo", "Eng", state=AppState.NEEDS_YOU)
    j3, _ = make_job(conn, "Wise", "Eng", state=AppState.NEEDS_YOU)
    unk = QuestionReason.UNKNOWN.value
    park_unresolved(conn, j1.id, [UnresolvedField(question=FormQuestion(key="t", label="Do you like turtles?"), reason=unk)])
    park_unresolved(conn, j2.id, [UnresolvedField(question=FormQuestion(key="t", label="Do you like turtles?"), reason=unk)])
    park_unresolved(conn, j1.id, [UnresolvedField(question=FormQuestion(key="c", label="Have you written a compiler?"), reason=unk)])
    park_unresolved(conn, j1.id, [UnresolvedField(question=FormQuestion(key="g", label="Favourite chess opening?"), reason=unk)])
    park_unresolved(conn, j3.id, [UnresolvedField(question=FormQuestion(key="g", label="Favourite chess opening?"), reason=unk)])
    by_label = {q.canonical_question: q.cluster_id for q in db.list_questions(conn, status=QuestionStatus.OPEN)}
    out = skip_cluster(conn, by_label["Do you like turtles?"])
    assert out.extra_resolved == [by_label["Have you written a compiler?"]]
    assert out.changed == [by_label["Favourite chess opening?"]]
    assert [p.cluster_id for p in out.extra_resolved_payloads()] == out.extra_resolved
    assert all(p.status == "skipped" for p in out.extra_resolved_payloads())


# ---- cover letter fact check ---------------------------------------------------------------


def test_fact_check_whole_words_and_first_person_claims():
    corpus = ["Skills: JavaScript, Postgres. We value trust and draw on laws of physics."]
    bad = fact_check("I have shipped production Rust and Java services on AWS.", corpus)
    assert "AWS" in bad and any("Rust" in c for c in bad) and any("Java" in c for c in bad)
    jd = "Job description: Requirements: 5+ years of Kubernetes experience."
    own = ["Worked as Engineer at Acme"]
    flagged = fact_check("I bring 5+ years of Kubernetes experience.", [jd, *own], own)
    assert "Kubernetes" in flagged and any(c.startswith("5") for c in flagged)
    # describing the company/role from the JD is fine; so is naming the company in first person
    assert fact_check("Your team runs Kubernetes at scale. I'd love to join Acme.", [jd, *own], own) == []

