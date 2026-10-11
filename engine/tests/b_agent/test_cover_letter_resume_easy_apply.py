from __future__ import annotations

from autoapply import db
from autoapply.answers.cover_letter import allowed_sources, extract_claims, fact_check, generate_cover_letter
from autoapply.answers.memory import AnswerMemory
from autoapply.answers.resume_picker import pick_resume
from autoapply.easy_apply import draft_easy_apply, refresh_easy_apply
from autoapply.enums import AnswerOrigin, AppState, BoardStatus, QuestionStatus
from autoapply.llm.provider import FakeLLMProvider

from .conftest import gen, make_job, seed_profile

GOOD = (
    "Dear Stripe hiring team,\n\nAt Acme Pay I cut payment latency by 40% and led our migration to Go microservices. "
    "I would like to bring that experience with Go and Postgres to your payments infrastructure.\n\nAda Lovelace"
)
INVENTED = (
    "Dear Stripe hiring team,\n\nAt Google I scaled Kubernetes clusters to 10,000 nodes and cut latency by 70%. "
    "I hold a PhD from MIT.\n\nAda Lovelace"
)


def _ctx(conn):
    seed_profile(conn)
    job, _ = make_job(conn)
    story = db.upsert_story(conn, title="Ledger", situation="Ledger was slow", action="Rewrote it in Go", result="40% faster")
    return db.get_profile(conn), [story], job, db.get_company(conn, job.company_id)


def test_fact_check_flags_unsupported_claims(conn):
    profile, stories, job, company = _ctx(conn)
    sources = allowed_sources(profile, stories, job, company)
    assert fact_check(GOOD, sources) == []
    bad = fact_check(INVENTED, sources)
    for claim in ("Google", "Kubernetes", "10,000", "70%", "PhD", "MIT"):
        assert any(claim in b for b in bad), (claim, bad)


def test_extract_claims_ignores_letter_boilerplate():
    claims = extract_claims("Dear Hiring Manager,\nI am excited. Sincerely, Ada")
    assert claims == ["Ada"]


async def test_cover_letter_grounded_written_to_disk(conn, tmp_path):
    profile, stories, job, company = _ctx(conn)
    llm = FakeLLMProvider(rules=[("COVER LETTER", {"text": GOOD, "story_ids": [stories[0].id, 999]})])
    letter = await generate_cover_letter(llm, profile=profile, stories=stories, job=job, company=company, out_dir=tmp_path)
    assert letter.grounded and letter.unsupported_claims == [] and letter.attempts == 1
    assert letter.story_ids == [stories[0].id]
    assert letter.path is not None and letter.path.read_text().startswith("Dear Stripe")
    prompt = llm.calls[0].prompt
    assert "F1." in prompt and "Rewrote it in Go" in prompt and "payments infrastructure" in prompt
    assert letter.tokens_in > 0 and letter.tokens_out > 0


async def test_cover_letter_regenerates_then_succeeds(conn, tmp_path):
    profile, stories, job, company = _ctx(conn)
    llm = FakeLLMProvider([{"text": INVENTED, "story_ids": []}, {"text": GOOD, "story_ids": []}])
    letter = await generate_cover_letter(llm, profile=profile, stories=stories, job=job, company=company, out_dir=tmp_path)
    assert letter.grounded and letter.attempts == 2
    assert "NOT in the facts" in llm.calls[1].prompt and "Kubernetes" in llm.calls[1].prompt


async def test_cover_letter_still_ungrounded_is_not_written(conn, tmp_path):
    profile, stories, job, company = _ctx(conn)
    llm = FakeLLMProvider(default={"text": INVENTED, "story_ids": []})
    out = tmp_path / "letters"
    letter = await generate_cover_letter(llm, profile=profile, stories=stories, job=job, company=company, out_dir=out)
    assert not letter.grounded and letter.path is None and letter.unsupported_claims
    assert not out.exists()


async def test_cover_letter_word_limit(conn):
    profile, stories, job, company = _ctx(conn)
    long = GOOD + " " + " ".join(["Go"] * 400)
    llm = FakeLLMProvider(default={"text": long, "story_ids": []})
    letter = await generate_cover_letter(llm, profile=profile, stories=stories, job=job, company=company, max_words=60)
    assert len(letter.text.split()) <= 60


# ---- resume picker -----------------------------------------------------------------


def test_pick_resume_by_tags_and_text(conn):
    job, _ = make_job(conn, title="Machine Learning Engineer", description="Train PyTorch models, ML pipelines, Python.")
    assert pick_resume(conn, job) is None
    be = db.add_resume_variant(conn, label="Backend", file_path="/r/be.pdf", tags=["backend", "go"],
                               text="Go Postgres Kafka distributed systems payments", is_default=True)
    ml = db.add_resume_variant(conn, label="ML", file_path="/r/ml.pdf", tags=["machine learning", "pytorch"],
                               text="PyTorch models training pipelines Python")
    pick = pick_resume(conn, job)
    assert pick.variant.id == ml.id and pick.score > 0
    assert any("tags match" in r for r in pick.reasons)
    assert pick.alternatives[0][0] == be.id and pick.alternatives[0][1] < pick.score

    backend_job, _ = make_job(conn, "Acme", title="Backend Engineer", description="Go and Postgres services")
    assert pick_resume(conn, backend_job).variant.id == be.id


def test_pick_resume_skips_disabled_and_uses_response_rate(conn):
    job, _ = make_job(conn, title="Engineer", description="Software")
    a = db.add_resume_variant(conn, label="A", file_path="/r/a.pdf", text="software engineer")
    b = db.add_resume_variant(conn, label="B", file_path="/r/b.pdf", text="software engineer")
    db.update_resume_variant(conn, a.id, enabled=False)
    assert pick_resume(conn, job).variant.id == b.id
    db.update_resume_variant(conn, a.id, enabled=True)
    # B got interviews on 3 past submissions -> preferred over identical A
    for i in range(3):
        j, app = make_job(conn, f"Past{i}", state=AppState.FILLING)
        db.update_application(conn, app.id, resume_variant_id=b.id)
        db.begin_submit(conn, app.id)
        db.complete_submit(conn, app.id)
        db.set_status(conn, app.id, BoardStatus.INTERVIEW)
    pick = pick_resume(conn, job)
    assert pick.variant.id == b.id and any("response rate 3/3" in r for r in pick.reasons)


# ---- easy apply ----------------------------------------------------------------------


async def test_draft_easy_apply(conn):
    seed_profile(conn)
    db.set_never_guess(conn, {"sponsorship": "Not required", "work_auth": {"US": "citizen"}, "salary_expectation": "$180k"})
    v = db.add_resume_variant(conn, label="Backend", file_path="/r/be.pdf", tags=["backend"])
    job, _ = make_job(conn, easy_apply=True, state=AppState.SCORED)
    db.update_job(conn, job.id, source_url="https://www.linkedin.com/jobs/view/123")
    AnswerMemory(conn).save("Why do you want to work here?", "I love what {company} builds.")
    llm = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("Backend engineer focused on payments.", 0.9))])
    drafts = await draft_easy_apply(conn, llm, job.id)
    by_q = {d.question: d for d in drafts}
    assert by_q["Email address"].answer == "ada@example.com" and by_q["Email address"].origin is AnswerOrigin.PROFILE
    assert by_q["Mobile phone number"].answer == "+1 555 0100"
    assert by_q["Years of experience"].answer == "8"
    assert by_q["Are you legally authorized to work in the United States?"].answer == "Yes"
    assert by_q["Are you legally authorized to work in the United States?"].locked
    assert by_q["What are your salary expectations?"].answer == "$180k"
    assert by_q["Why do you want to work at Stripe?"].answer == "I love what Stripe builds."
    assert by_q["Tell us about yourself (short pitch)"].origin is AnswerOrigin.GENERATED
    notice = by_q["What is your notice period?"]
    assert notice.ask_me and notice.locked and notice.answer == ""
    # unknown never-guess facts are in the inbox, linked to this job
    open_qs = db.list_questions(conn, status=QuestionStatus.OPEN)
    assert {q.never_guess_key for q in open_qs} == {"notice_period", "start_date", "relocation"}
    assert all(q.job_ids == [job.id] for q in open_qs)

    item = await refresh_easy_apply(conn, llm, job.id)
    assert item.url == "https://www.linkedin.com/jobs/view/123" and item.resume_variant_id == v.id
    assert len(item.drafted_answers) == len(drafts)
    # LinkedIn state untouched: the job is still just scored (user applies manually)
    assert db.get_application_by_job(conn, job.id).state is AppState.SCORED
