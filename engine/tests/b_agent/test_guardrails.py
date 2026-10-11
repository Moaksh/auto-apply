from __future__ import annotations

from datetime import timedelta

import pytest

from autoapply import db
from autoapply.answers.guardrails import (
    AnswerForCheck,
    NeverGuessClassifier,
    check_answers,
    check_submit_allowed,
    classify_never_guess,
    detect_captcha,
    matches_always_ask,
    parse_amount,
    passes_confidence,
    resolve_never_guess,
)
from autoapply.config import NeverGuess, Preferences
from autoapply.enums import AnswerOrigin, AppState, AskConfidence, CapKind, FieldType, QuestionReason
from autoapply.llm.provider import FakeLLMProvider, LLMError
from autoapply.models import FormQuestion

from .conftest import make_job

# Real-world phrasings collected from Greenhouse / Lever / Ashby / Workday forms.
CLASSIFICATION_TABLE: list[tuple[str, str | None]] = [
    # work authorisation
    ("Are you legally authorized to work in the United States?", "work_auth"),
    ("Are you authorised to work in the UK?", "work_auth"),
    ("Do you have the right to work in Germany?", "work_auth"),
    ("Are you eligible to work in Canada without restriction?", "work_auth"),
    ("Are you a U.S. citizen or permanent resident?", "work_auth"),
    ("Can you provide proof of employment eligibility?", "work_auth"),
    ("Are you legally able to work in India?", "work_auth"),
    ("Are you authorized to work in the US without sponsorship?", "work_auth"),
    # sponsorship
    ("Will you now or in the future require sponsorship for employment visa status (e.g., H-1B visa status)?", "sponsorship"),
    ("Do you require visa sponsorship?", "sponsorship"),
    ("Will you need us to sponsor a work visa?", "sponsorship"),
    ("What is your current visa status?", "sponsorship"),
    ("Do you now, or will you in the future, need immigration sponsorship?", "sponsorship"),
    # salary
    ("What are your salary expectations?", "salary_expectation"),
    ("Desired compensation", "salary_expectation"),
    ("Expected CTC (in LPA)", "salary_expectation"),
    ("What is your desired pay range for this role?", "salary_expectation"),
    ("What is your current CTC?", "current_salary"),
    ("Current base salary", "current_salary"),
    ("Is your salary expectation negotiable?", "salary_negotiable"),
    # timing / logistics
    ("What is your notice period?", "notice_period"),
    ("How much notice do you need to give your current employer?", "notice_period"),
    ("When can you start?", "start_date"),
    ("Earliest start date", "start_date"),
    ("How soon could you join?", "start_date"),
    ("Are you willing to relocate to New York?", "relocation"),
    ("Would you be open to relocation?", "relocation"),
    # EEO
    ("Gender", "eeo_gender"),
    ("What are your pronouns?", "eeo_gender"),
    ("Please select your race / ethnicity", "eeo_race"),
    ("Are you Hispanic or Latino?", "eeo_race"),
    ("Veteran status", "eeo_veteran"),
    ("Are you a protected veteran?", "eeo_veteran"),
    ("Do you have a disability (or previously had a disability)?", "eeo_disability"),
    ("Voluntary self-identification of disability", "eeo_disability"),
    ("What is your sexual orientation?", "eeo_other"),
    # legal attestations
    ("I certify that the information provided in this application is true and complete to the best of my knowledge.", "attest_accuracy"),
    ("By checking this box I confirm all statements are accurate", "attest_accuracy"),
    ("Electronic signature", "attest_accuracy"),
    ("Do you consent to a background check?", "attest_background_check"),
    ("Are you willing to undergo a drug test?", "attest_background_check"),
    ("Have you ever been convicted of a felony?", "criminal_history"),
    ("Do you hold an active security clearance?", "security_clearance"),
    ("Are you bound by a non-compete agreement?", "non_compete"),
    ("Are you at least 18 years of age?", "age_confirmation"),
    # NOT never-guess
    ("Why do you want to work at Stripe?", None),
    ("LinkedIn profile", None),
    ("How many years of experience do you have with Go?", None),
    ("Tell us about a project you are proud of", None),
    ("What is your current job title?", None),
    ("First name", None),
    ("How did you hear about us?", None),
    ("Website", None),
]


def test_table_is_big_enough():
    assert sum(1 for _, k in CLASSIFICATION_TABLE if k) >= 30


@pytest.mark.parametrize("question,expected", CLASSIFICATION_TABLE)
def test_classify_never_guess(question: str, expected: str | None):
    assert classify_never_guess(question) == expected


def test_classify_accepts_form_question_with_description():
    q = FormQuestion(key="q1", label="Status", description="Do you require visa sponsorship to work here?")
    assert classify_never_guess(q) == "sponsorship"


# ---- LLM fallback ------------------------------------------------------------------


async def test_llm_fallback_only_for_sensitive_looking_unmatched():
    llm = FakeLLMProvider(rules=[("NEVER-GUESS CLASSIFICATION", {"key": "work_auth"})])
    clf = NeverGuessClassifier(llm)
    # matched by rules -> no LLM call
    assert await clf.classify_async("Do you require visa sponsorship?") == "sponsorship"
    # harmless question -> no LLM call
    assert await clf.classify_async("What is your favourite programming language?") is None
    assert llm.calls == []
    # sensitive-looking but unmatched -> LLM, cached
    q = "What is your employment status in the country of this role?"
    assert await clf.classify_async(q) == "work_auth"
    assert await clf.classify_async(q) == "work_auth"
    assert len(llm.calls) == 1


async def test_llm_fallback_fails_closed():
    clf = NeverGuessClassifier(FakeLLMProvider(default=LLMError("down")))
    assert await clf.classify_async("Please state your legal status") == "unclassified_sensitive"


# ---- resolving from stored facts only ------------------------------------------------

YN = ["Yes", "No"]


def test_missing_fact_returns_none():
    ng = NeverGuess()
    for key in ("sponsorship", "salary_expectation", "notice_period", "start_date", "relocation", "work_auth", "attest_accuracy"):
        assert resolve_never_guess(key, ng) is None, key


def test_sponsorship_mapped_to_options():
    ng = NeverGuess(sponsorship="Requires sponsorship (H-1B)")
    q = FormQuestion(key="s", label="Will you require sponsorship?", options=["Yes", "No"])
    assert resolve_never_guess("sponsorship", ng, q) == "Yes"
    ng2 = NeverGuess(sponsorship="Not required")
    assert resolve_never_guess("sponsorship", ng2, q) == "No"
    free = FormQuestion(key="s", label="Sponsorship details")
    assert resolve_never_guess("sponsorship", ng, free) == "Requires sponsorship (H-1B)"


def test_work_auth_uses_question_or_job_country():
    ng = NeverGuess(work_auth={"US": "requires_sponsorship", "IN": "citizen"})
    us = FormQuestion(key="a", label="Are you legally authorized to work in the United States?", options=YN)
    assert resolve_never_guess("work_auth", ng, us) == "No"
    india = FormQuestion(key="a", label="Are you legally authorized to work in India?", options=YN)
    assert resolve_never_guess("work_auth", ng, india) == "Yes"
    generic = FormQuestion(key="a", label="Are you authorized to work in the country where this job is located?", options=YN)
    assert resolve_never_guess("work_auth", ng, generic) is None  # two countries, no hint -> ask
    assert resolve_never_guess("work_auth", ng, generic, country="IN") == "Yes"
    citizen = FormQuestion(key="a", label="Are you a citizen of India?", options=YN)
    assert resolve_never_guess("work_auth", ng, citizen) == "Yes"


def test_eeo_defaults_to_prefer_not_to_say():
    ng = NeverGuess()  # eeo_policy = decline
    q = FormQuestion(key="g", label="Gender", options=["Male", "Female", "Non-binary", "I don't wish to answer"])
    assert resolve_never_guess("eeo_gender", ng, q) == "I don't wish to answer"
    assert resolve_never_guess("eeo_race", ng, FormQuestion(key="r", label="Race")) == "Prefer not to say"
    # options without a decline choice -> ask
    assert resolve_never_guess("eeo_veteran", ng, FormQuestion(key="v", label="Veteran", options=["Yes", "No"])) is None
    # user opted to fill
    ng2 = NeverGuess(eeo_policy="fill", eeo_gender="Female")
    assert resolve_never_guess("eeo_gender", ng2, q) == "Female"


def test_attestations_need_explicit_permission():
    q = FormQuestion(key="c", label="I certify the information is accurate", field_type=FieldType.BOOLEAN)
    assert resolve_never_guess("attest_accuracy", NeverGuess(), q) is None
    assert resolve_never_guess("attest_accuracy", NeverGuess(attest_accuracy=True), q) == "true"
    sig = FormQuestion(key="s", label="Electronic signature (type your full name)")
    assert resolve_never_guess("attest_accuracy", NeverGuess(attest_accuracy=True), sig) is None


def test_relocation_and_numbers():
    q = FormQuestion(key="r", label="Are you willing to relocate?", options=YN)
    assert resolve_never_guess("relocation", NeverGuess(relocation="yes"), q) == "Yes"
    assert resolve_never_guess("relocation", NeverGuess(relocation="case_by_case"), q) is None
    sal = FormQuestion(key="s", label="Expected salary (USD)", field_type=FieldType.NUMBER)
    assert resolve_never_guess("salary_expectation", NeverGuess(salary_expectation="$180k"), sal) == "180000"
    assert parse_amount("₹45L") == 4_500_000
    assert parse_amount("1.2M") == 1_200_000


def test_always_ask_keys_never_resolve():
    for key in ("current_salary", "criminal_history", "security_clearance"):
        assert resolve_never_guess(key, NeverGuess(salary_expectation="x")) is None


# ---- gates ---------------------------------------------------------------------------


def test_confidence_gate():
    prefs = Preferences()  # balanced = 0.75
    assert passes_confidence(0.8, prefs)
    assert not passes_confidence(0.7, prefs)
    assert not passes_confidence(None, prefs)
    assert not passes_confidence(0.8, Preferences(ask_confidence=AskConfidence.STRICT))


def test_always_ask_patterns():
    prefs = Preferences(always_ask_patterns=[r"why .* us", "[invalid(", "portfolio"])
    assert matches_always_ask("Why do you want to join us?", prefs)
    assert matches_always_ask("Link to your PORTFOLIO", prefs)
    assert matches_always_ask("tell me [invalid( stuff", prefs)
    assert not matches_always_ask("First name", prefs)


def test_detect_captcha():
    assert detect_captcha('- iframe "reCAPTCHA" [ref=e5]:\n  - checkbox "I\'m not a robot" [ref=e6]')
    assert detect_captcha('- iframe "recaptcha challenge expires in two minutes" [ref=e8]\n- text: Select all images with traffic lights')
    assert detect_captcha("Checking your browser before accessing jobs.example.com")
    # the passive reCAPTCHA v3 badge is on many forms and needs nothing from the user
    assert not detect_captcha('- iframe "reCAPTCHA" [ref=e9]\n- text: This site is protected by reCAPTCHA and the Google '
                              'Privacy Policy and Terms of Service apply.')
    assert detect_captcha("Please verify you are human")
    assert not detect_captcha("Upload your resume")


def test_check_answers():
    ng = NeverGuess(sponsorship="Not required")
    prefs = Preferences()
    spons = FormQuestion(key="s", label="Do you require visa sponsorship?", options=YN)
    ok = AnswerForCheck(spons, "No", AnswerOrigin.NEVER_GUESS, 1.0)
    wrong = AnswerForCheck(spons, "Yes", AnswerOrigin.NEVER_GUESS, 1.0)
    generated_ng = AnswerForCheck(FormQuestion(key="n", label="What is your notice period?"), "30 days", AnswerOrigin.GENERATED, 0.99)
    low = AnswerForCheck(FormQuestion(key="w", label="Why us?"), "...", AnswerOrigin.GENERATED, 0.5)
    high = AnswerForCheck(FormQuestion(key="w", label="Why us?"), "...", AnswerOrigin.GENERATED, 0.9)
    user_ng = AnswerForCheck(FormQuestion(key="n", label="What is your notice period?"), "30 days", AnswerOrigin.USER, 1.0)
    assert check_answers([ok, high, user_ng], ng, prefs) == []
    problems = check_answers([wrong, generated_ng, low], ng, prefs)
    assert [p.reason for p in problems] == [QuestionReason.NEVER_GUESS, QuestionReason.NEVER_GUESS, QuestionReason.LOW_CONFIDENCE]


def test_check_submit_allowed(conn):
    job, app = make_job(conn, state=AppState.FILLING)
    prefs = Preferences(daily_cap=1, per_company_cooldown_days=30)
    assert check_submit_allowed(conn, app, job, prefs, paused=True).reason == "paused"
    assert check_submit_allowed(conn, app, job, prefs, paused=False).allowed

    # one agent submission today -> daily cap
    job2, app2 = make_job(conn, "Airbnb", state=AppState.FILLING)
    db.begin_submit(conn, app2.id)
    db.complete_submit(conn, app2.id)
    res = check_submit_allowed(conn, app, job, prefs, paused=False)
    assert not res.allowed and res.cap is CapKind.DAILY and res.used == 1 and res.limit == 1

    # cooldown for the company we just applied to
    job3, app3 = make_job(conn, "Airbnb", "Data Engineer", state=AppState.FILLING)
    res = check_submit_allowed(conn, app3, job3, Preferences(daily_cap=10), paused=False)
    assert not res.allowed and res.cap is CapKind.COMPANY_COOLDOWN
    assert res.resets_at is not None and res.resets_at - db.get_company(conn, job3.company_id).last_applied_at == timedelta(days=30)
