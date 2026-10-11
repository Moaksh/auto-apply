"""Questions answerable from facts the user already gave never reach the inbox."""

from __future__ import annotations

from autoapply.answers.derived import derived_answer
from autoapply.config import NeverGuess
from autoapply.enums import FieldType
from autoapply.models import FormQuestion, Job, Profile

P = Profile.model_construct(full_name="A B", location="Bangalore", work_history=[], education=[], years_experience=2.3)
NG = NeverGuess(work_auth={"IN": "citizen"})


def q(label: str, options: list[str] | None = None, ft: FieldType = FieldType.TEXT, desc: str | None = None) -> FormQuestion:
    return FormQuestion(key="k", label=label, options=options or [], field_type=ft, description=desc)


def ans(question: FormQuestion, ng: NeverGuess = NG, job: Job | None = None) -> str | None:
    r = derived_answer(question, profile=P, never_guess=ng, job=job) or derived_answer(
        question, profile=P, never_guess=ng, job=job, kind="defaults")
    return r[0] if r else None


def test_residence_city_citizenship() -> None:
    assert ans(q("Country of Residence")) == "India"
    assert ans(q("Country", ["United States", "India", "Canada"], FieldType.SELECT)) == "India"
    assert ans(q("Location (City)")) == "Bangalore"
    assert ans(q("Passport Country")) == "India"
    assert ans(q("Passport Country"), ng=NeverGuess()) is None  # citizenship unknown -> still asked


def test_sanctions_screens() -> None:
    sel = q("Is your most recent country of citizenship one of the following countries: Cuba, Iran, North Korea (DPRK), or Syria?", ["Yes", "No"], FieldType.SELECT)
    assert ans(sel) == "No"
    multi = q("Please confirm whether any of the below applies to you. Select all that apply.",
              ["Citizen or permanent resident of Cuba, Iran, North Korea, or Syria", "None of the above"], FieldType.MULTISELECT)
    assert ans(multi) == "None of the above"
    assert ans(sel, ng=NeverGuess()) is None


def test_age_heard_optins() -> None:
    assert ans(q("Are you over the age of 18?", ["Yes", "No"], FieldType.BOOLEAN)) == "Yes"
    gh = Job.model_construct(source="greenhouse")
    assert ans(q("How did you hear about this job?", ["LinkedIn", "Company Website", "Referral"], FieldType.SELECT), job=gh) == "Company Website"
    assert ans(q("How did you hear about this job?"), job=Job.model_construct(source="linkedin")) == "LinkedIn"
    assert ans(q("Would you like to join our talent community for future opportunities?", ["Yes", "No"])) == "Yes"
    assert ans(q("Would you like to stay up to date with our newsletter?", ["Yes", "No"])) == "No"


def test_unrelated_question_is_not_derived() -> None:
    assert ans(q("Why do you want to work here?", ft=FieldType.TEXTAREA)) is None
    assert ans(q("What is your current CTC?")) is None


def test_auto_resolve_clears_answerable_inbox_questions(conn) -> None:  # type: ignore[no-untyped-def]
    from autoapply import db, prep
    from autoapply.enums import AppState, QuestionStatus

    db.update_profile(conn, {"full_name": "A B", "location": "Bangalore", "years_experience": 2})
    db.set_never_guess(conn, {"work_auth": {"IN": "citizen"}})
    co = db.upsert_company(conn, "Acme")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="ML Engineer",
                           apply_url="https://boards.greenhouse.io/acme/jobs/1", location="Bengaluru, India")
    app = db.get_application_by_job(conn, job.id)
    for to in (AppState.SCORED, AppState.QUEUED, AppState.PREPPING, AppState.NEEDS_YOU):
        db.transition(conn, app.id, to)
    db.add_question(conn, canonical_question="Country of Residence", job_id=job.id, never_guess_key="work_auth", reason="never_guess")
    db.add_question(conn, canonical_question="How did you hear about this job?", job_id=job.id,
                    field_type="select", options=["LinkedIn", "Company Website"])
    db.add_question(conn, canonical_question="Why do you want to work here?", job_id=job.id, field_type="textarea")

    outcomes = prep.auto_resolve_known(conn)
    assert len(outcomes) == 2
    open_q = [q.canonical_question for q in db.list_questions(conn, status=QuestionStatus.OPEN)]
    assert open_q == ["Why do you want to work here?"]
    assert db.get_application_by_job(conn, job.id).state is AppState.NEEDS_YOU  # still one open question


def test_only_real_right_to_work_answers_become_facts() -> None:
    from autoapply.prep import never_guess_value as v

    assert v("work_auth", "No", question="Does the deemed export rule affect your employment by Everpure?", country="IN") is None
    assert v("work_auth", "Not applicable", question="If you selected a response to the prior question other than none…", country="IN") is None
    assert v("work_auth", "India", question="In what countries do you have the unrestricted right to work? [job location: India]", country="IN") == {"work_auth": {"IN": "authorized"}}
    assert v("work_auth", "India", question="Are you authorized to work in the country you are applying to work in? [job location: India]", country="IN") == {"work_auth": {"IN": "authorized"}}
    assert v("work_auth", "No", question="Are you legally authorized to work in the country in which you are applying? [job location: Serbia]", country="RS") == {"work_auth": {"RS": "not_authorized"}}
    assert v("work_auth", "Yes", question="Are you legally authorized to work in India?", country=None) == {"work_auth": {"IN": "authorized"}}


def test_conditional_follow_ups_are_not_applicable() -> None:
    assert ans(q("If you answered MongoDB Employee, MongoDB Event, or Other, please specify here:")) == "N/A"
    assert ans(q("If other, please specify")) == "N/A"


async def test_attach_buttons_are_identified_by_field_key(conn) -> None:  # type: ignore[no-untyped-def]
    from autoapply import db
    from autoapply.answers.resolver import AnswerResolver

    db.add_resume_variant(conn, label="CV", file_path="/tmp/cv.pdf", tags=[], text="x", is_default=True)
    r = AnswerResolver(conn, None, resume=db.list_resume_variants(conn)[0])
    resume = await r.resolve(FormQuestion(key="resume", label="Attach", field_type=FieldType.FILE, required=False))
    cover = await r.resolve(FormQuestion(key="cover_letter", label="Attach", field_type=FieldType.FILE, required=False))
    assert resume.action == "upload_resume" and resume.answer == "/tmp/cv.pdf"
    assert cover.action == "cover_letter"


def test_cover_letter_clip_keeps_paragraphs_and_sign_off() -> None:
    from autoapply.answers.cover_letter import _clip_words

    letter = "Dear team,\n\n" + "One two three four five. " * 20 + "\n\nSecond para here.\n\nSincerely,\nJane Doe"
    out = _clip_words(letter, 40)
    assert out.startswith("Dear team,\n\n") and out.endswith("Sincerely,\nJane Doe")
    assert len(out.split()) <= 40


def test_citizen_never_needs_sponsorship_in_own_country() -> None:
    from autoapply.answers.guardrails import resolve_never_guess

    ng = NeverGuess(work_auth={"IN": "citizen"}, sponsorship="Requires sponsorship")
    sel = q("Will you now or in the future require sponsorship for employment visa status?", ["Yes", "No"], FieldType.SELECT)
    assert resolve_never_guess("sponsorship", ng, sel, country="IN") == "No"
    assert resolve_never_guess("sponsorship", ng, sel, country="US") == "Yes"  # abroad: the general answer applies
    visa = NeverGuess(work_auth={"US": "authorized"}, sponsorship="Requires sponsorship (H-1B)")
    assert resolve_never_guess("sponsorship", visa, sel, country="US") is None  # ambiguous: ask


def test_contact_preference_defaults_to_email() -> None:
    assert ans(q("How should we communicate with you?", ["Email", "SMS / Text", "WhatsApp"], FieldType.MULTISELECT)) == "Email"
