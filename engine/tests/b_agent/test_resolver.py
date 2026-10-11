from __future__ import annotations

import pytest

from autoapply import db
from autoapply.answers.guardrails import NeedsUser
from autoapply.answers.memory import AnswerMemory
from autoapply.answers.resolver import AnswerResolver, profile_answer, set_inbox_answers
from autoapply.enums import AnswerOrigin, AnswerSource, FieldType, QuestionReason
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import FormQuestion

from .conftest import gen, make_job, seed_profile


@pytest.fixture
def setup(conn):
    seed_profile(conn)
    job, app = make_job(conn)
    return job, app


def resolver(conn, job, llm=None, **kw):
    return AnswerResolver(conn, llm, job=job, **kw)


async def test_profile_answers(conn, setup):
    job, _ = setup
    r = resolver(conn, job)
    for label, expected in [
        ("First Name", "Ada"), ("Last name", "Lovelace"), ("Full name", "Ada Lovelace"), ("Email", "ada@example.com"),
        ("Phone number", "+1 555 0100"), ("LinkedIn Profile", "https://linkedin.com/in/ada"),
        ("GitHub URL", "https://github.com/ada"), ("Current company", "Acme Pay"), ("Current title", "Senior Backend Engineer"),
        ("Years of experience", "8"), ("School", "University of London"),
    ]:
        res = await r.resolve(label)
        assert (res.answer, res.origin) == (expected, AnswerOrigin.PROFILE), label


async def test_order_profile_before_memory_before_generate(conn, setup):
    job, _ = setup
    AnswerMemory(conn).save("Email", "other@example.com")
    llm = FakeLLMProvider(default=gen("generated"))
    res = await resolver(conn, job, llm).resolve("Email")
    assert res.origin is AnswerOrigin.PROFILE and res.answer == "ada@example.com"
    assert llm.calls == []


async def test_memory_before_generation(conn, setup):
    job, _ = setup
    AnswerMemory(conn).save("How did you hear about us?", "Your engineering blog")
    llm = FakeLLMProvider(default=gen("generated"))
    res = await resolver(conn, job, llm).resolve("How did you learn about this job?")
    assert res.origin is AnswerOrigin.MEMORY and res.answer == "Your engineering blog" and res.memory_answer_id
    assert llm.calls == []


async def test_never_guess_from_store_only(conn, setup):
    job, _ = setup
    llm = FakeLLMProvider(default=gen("No", 0.99))
    r = resolver(conn, job, llm)
    q = FormQuestion(key="s", label="Will you require visa sponsorship?", options=["Yes", "No"])
    # memory answer exists, but never-guess fields never come from memory or the LLM
    AnswerMemory(conn).save("Will you require visa sponsorship?", "No")
    with pytest.raises(NeedsUser) as ei:
        await r.resolve(q)
    assert ei.value.reason is QuestionReason.NEVER_GUESS and ei.value.never_guess_key == "sponsorship"
    assert not any("GENERATE" in c.prompt for c in llm.calls)
    db.set_never_guess(conn, {"sponsorship": "Requires sponsorship"})
    res = await resolver(conn, job, llm).resolve(q)
    assert (res.answer, res.origin, res.origin_ref) == ("Yes", AnswerOrigin.NEVER_GUESS, "never_guess:sponsorship")


async def test_work_auth_uses_job_country(conn, setup):
    job, _ = setup  # San Francisco, CA -> US
    db.set_never_guess(conn, {"work_auth": {"US": "citizen", "IN": "requires_sponsorship"}})
    q = FormQuestion(key="a", label="Are you legally authorized to work in the country this job is in?", options=["Yes", "No"])
    res = await resolver(conn, job).resolve(q)
    assert res.answer == "Yes"


async def test_eeo_prefer_not_to_say(conn, setup):
    job, _ = setup
    q = FormQuestion(key="g", label="Gender", options=["Male", "Female", "Decline to self-identify"])
    res = await resolver(conn, job).resolve(q)
    assert (res.answer, res.origin) == ("Decline to self-identify", AnswerOrigin.NEVER_GUESS)


async def test_generate_confident_and_low_confidence(conn, setup):
    job, _ = setup
    story = db.upsert_story(conn, title="Ledger rebuild", situation="Slow ledger", action="Rewrote in Go", result="40% faster")
    llm = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("I rebuilt our ledger in Go.", 0.9, story_ids=[story.id]))])
    res = await resolver(conn, job, llm).resolve(FormQuestion(key="p", label="Describe a technical challenge", field_type=FieldType.TEXTAREA))
    assert res.origin is AnswerOrigin.STORY and res.story_ids == [story.id] and res.confidence == 0.9
    assert "Rewrote in Go" in llm.calls[0].prompt and "Acme Pay" in llm.calls[0].prompt

    low = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("Maybe", 0.6))])
    with pytest.raises(NeedsUser) as ei:
        await resolver(conn, job, low).resolve("What is your favourite data structure and why?")
    assert ei.value.reason is QuestionReason.LOW_CONFIDENCE and ei.value.suggested_answer == "Maybe"


async def test_ungrounded_generation_is_capped(conn, setup):
    job, _ = setup
    llm = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("I led a team of 50", 0.95, grounded=False))])
    with pytest.raises(NeedsUser) as ei:
        await resolver(conn, job, llm).resolve("Describe your leadership experience")
    assert ei.value.confidence == 0.5


async def test_draft_gaps_become_a_separate_note(conn, setup):
    """What the facts don't cover goes to the user as a note, never into the recruiter-facing draft."""
    job, _ = setup
    resp = {**gen("I keep work moving with written specs and async reviews.", 0.4, grounded=False),
            "gaps": "Say whether your past roles were remote or hybrid."}
    llm = FakeLLMProvider(rules=[("GENERATE ANSWER", resp)])
    with pytest.raises(NeedsUser) as ei:
        await resolver(conn, job, llm).resolve("Tell us about working in a remote environment")
    uf = ei.value.to_unresolved()
    assert uf.suggested_answer.startswith("I keep work moving")
    assert uf.note == "Say whether your past roles were remote or hybrid."
    assert "never mention the facts" in llm.calls[0].system or "must never" in llm.calls[0].system


async def test_generated_select_must_be_an_option(conn, setup):
    job, _ = setup
    llm = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("Purple", 0.95))])
    q = FormQuestion(key="x", label="Preferred team", options=["Payments", "Risk"])
    with pytest.raises(NeedsUser):
        await resolver(conn, job, llm).resolve(q)


async def test_unknown_without_llm(conn, setup):
    job, _ = setup
    with pytest.raises(NeedsUser) as ei:
        await resolver(conn, job).resolve(FormQuestion(key="x", label="Describe your ideal manager", required=True))
    assert ei.value.reason is QuestionReason.UNKNOWN
    optional = await resolver(conn, job).resolve(FormQuestion(key="x", label="Anything else?", required=False))
    assert optional.action == "skip"


async def test_always_ask_beats_everything_but_inbox(conn, setup):
    job, _ = setup
    db.update_preferences(conn, {"always_ask_patterns": ["hear about"]})
    AnswerMemory(conn).save("How did you hear about us?", "blog")
    with pytest.raises(NeedsUser) as ei:
        await resolver(conn, job).resolve("How did you hear about us?")
    assert ei.value.reason is QuestionReason.ALWAYS_ASK
    set_inbox_answers(conn, job.id, {"How did you hear about us?": "A friend"})
    res = await resolver(conn, job).resolve("How did you hear about us?")
    assert (res.answer, res.origin) == ("A friend", AnswerOrigin.USER)


async def test_inbox_answer_unblocks_never_guess_for_that_job_only(conn, setup):
    job, _ = setup
    other, _ = make_job(conn, "Airbnb")
    set_inbox_answers(conn, job.id, {"What is your notice period?": "45 days"})
    res = await resolver(conn, job).resolve("What is your notice period?")
    assert (res.answer, res.origin) == ("45 days", AnswerOrigin.USER)
    with pytest.raises(NeedsUser):
        await resolver(conn, other).resolve("What is your notice period?")


async def test_always_ask_key_from_user_memory(conn, setup):
    job, _ = setup
    mem = AnswerMemory(conn)
    with pytest.raises(NeedsUser):
        await resolver(conn, job).resolve("Have you ever been convicted of a felony?")
    mem.save("Have you ever been convicted of a felony?", "No", source=AnswerSource.USER)
    res = await resolver(conn, job).resolve(FormQuestion(key="f", label="Have you ever been convicted of a felony?", options=["Yes", "No"]))
    assert (res.answer, res.origin) == ("No", AnswerOrigin.MEMORY)


async def test_per_company_adaptation(conn, setup):
    job, _ = setup  # Stripe
    AnswerMemory(conn).save("Why do you want to work here?", "Airbnb's focus on travel matches my background.")
    llm = FakeLLMProvider(rules=[("ADAPT ANSWER", {"answer": "Stripe's payments focus matches my background.", "confidence": 0.85})])
    res = await resolver(conn, job, llm).resolve("Why do you want to work at Stripe?")
    assert res.origin is AnswerOrigin.MEMORY and res.answer.startswith("Stripe's")
    assert "ADAPT ANSWER for Stripe" in llm.calls[0].prompt
    # failed adaptation falls through to generation instead of reusing another company's answer
    llm2 = FakeLLMProvider(rules=[("ADAPT ANSWER", {"answer": "x", "confidence": 0.2}), ("GENERATE ANSWER", gen("Fresh answer", 0.8))])
    res2 = await resolver(conn, job, llm2).resolve("Why do you want to work at Stripe?")
    assert res2.answer == "Fresh answer" and res2.origin is AnswerOrigin.GENERATED


async def test_resume_file_and_record(conn, setup):
    job, app = setup
    v = db.add_resume_variant(conn, label="Backend", file_path="/tmp/backend.pdf", tags=["backend"])
    r = resolver(conn, job, resume=v)
    res = await r.resolve(FormQuestion(key="resume", label="Resume/CV", field_type=FieldType.FILE, required=True))
    assert res.action == "upload_resume" and res.answer == "/tmp/backend.pdf" and res.origin is AnswerOrigin.CV
    mem_ans = AnswerMemory(conn).save("How did you hear about us?", "blog")
    m = await r.resolve("How did you hear about us?")
    r.record(app.id, res)
    r.record(app.id, m)
    rows = db.list_application_answers(conn, app.id)
    assert [x.origin for x in rows] == [AnswerOrigin.CV, AnswerOrigin.MEMORY]
    assert db.get_answer(conn, mem_ans.id).uses == 1


async def test_resolve_all_batches(conn, setup):
    job, _ = setup
    batch = await resolver(conn, job).resolve_all([
        FormQuestion(key="e", label="Email"), FormQuestion(key="n", label="Notice period", required=True),
    ])
    assert len(batch.resolved) == 1 and len(batch.unresolved) == 1
    uf = batch.unresolved_fields()[0]
    assert uf.reason == "never_guess" and uf.never_guess_key == "notice_period"


def test_profile_answer_option_mapping(conn):
    seed_profile(conn)
    p = db.get_profile(conn)
    q = FormQuestion(key="d", label="Degree", options=["High school", "BSc Mathematics", "MSc"])
    assert profile_answer(p, q) == ("BSc Mathematics", "degree")
