from __future__ import annotations

import pytest

from autoapply import db
from autoapply.answers.resolver import get_inbox_answers
from autoapply.apply.base import ApplyContext
from autoapply.enums import Actor, AnswerOrigin, AppState, Ats, FieldType, QuestionStatus
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import DraftedAnswer, FormQuestion, Job
from autoapply.prep import answer_cluster, never_guess_value, questions_from_raw, run_prep, skip_cluster

from .conftest import make_job, seed_profile

GH_RAW = {
    "questions": [
        {"label": "First Name", "required": True, "fields": [{"name": "first_name", "type": "input_text"}]},
        {"label": "Resume/CV", "required": True, "fields": [{"name": "resume", "type": "input_file"}, {"name": "resume_text", "type": "textarea"}]},
        {"label": "Why do you want to work here?", "required": True, "fields": [{"name": "q1", "type": "textarea"}]},
        {"label": "Will you now or in the future require sponsorship?", "required": True,
         "fields": [{"name": "q2", "type": "multi_value_single_select", "values": [{"label": "Yes", "value": 1}, {"label": "No", "value": 0}]}]},
    ]
}


class FakeAdapter:
    """Scripted adapter: questions per job id (or an exception)."""

    ats = Ats.OTHER

    def __init__(self, questions: dict[int, list[FormQuestion] | Exception]):
        self.questions = questions
        self.calls: list[int] = []

    def can_handle(self, job: Job) -> bool:
        return job.id in self.questions

    async def harvest_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        self.calls.append(ctx.job.id)
        q = self.questions[ctx.job.id]
        if isinstance(q, Exception):
            raise q
        return q

    async def fill(self, ctx):  # pragma: no cover - not used by prep
        raise NotImplementedError

    async def submit(self, ctx):  # pragma: no cover
        raise NotImplementedError


def test_questions_from_raw_greenhouse_ashby_generic(conn):
    job, _ = make_job(conn, raw=GH_RAW)
    qs = questions_from_raw(job)
    assert [q.label for q in qs] == [
        "First Name", "Resume/CV", "Why do you want to work here?", "Will you now or in the future require sponsorship?",
    ]
    assert qs[1].field_type is FieldType.FILE and qs[3].options == ["Yes", "No"] and qs[3].field_type is FieldType.SELECT
    ashby, _ = make_job(conn, "Linear", raw={"applicationForm": {"sections": [{"fieldEntries": [
        {"field": {"path": "_systemfield_name", "title": "Name", "type": "String"}, "isRequired": True},
        {"field": {"path": "q", "title": "Are you open to relocation?", "type": "Boolean"}, "isRequired": False},
    ]}]}})
    aq = questions_from_raw(ashby)
    assert [(q.label, q.field_type, q.required) for q in aq] == [("Name", FieldType.TEXT, True), ("Are you open to relocation?", FieldType.BOOLEAN, False)]
    generic, _ = make_job(conn, "Foo", raw={"form_questions": [{"key": "k", "label": "Email"}]})
    assert questions_from_raw(generic)[0].label == "Email"
    none, _ = make_job(conn, "Bar")
    assert questions_from_raw(none) is None


async def test_prep_parks_and_clusters_paraphrases(conn, autoapply_home, emit):
    seed_profile(conn)
    db.add_resume_variant(conn, label="Backend", file_path="/tmp/r.pdf")
    j1, a1 = make_job(conn, "Stripe", raw=GH_RAW)  # 2 unknowns: why + sponsorship
    j2, a2 = make_job(conn, "Airbnb", ats=Ats.WORKDAY)
    j3, a3 = make_job(conn, "Linear", ats=Ats.WORKDAY)
    j4, a4 = make_job(conn, "Figma", ats=Ats.WORKDAY)  # everything resolvable
    adapter = FakeAdapter({
        j2.id: [FormQuestion(key="w", label="Why us?", required=True), FormQuestion(key="e", label="Email")],
        j3.id: [FormQuestion(key="w", label="What excites you about working at our company?", required=True),
                FormQuestion(key="s", label="Do you require visa sponsorship?", options=["Yes", "No"], required=True)],
        j4.id: [FormQuestion(key="e", label="Email"), FormQuestion(key="f", label="First name")],
    })
    report = await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit)

    assert report.jobs_scanned == 4
    assert sorted(report.parked_jobs) == sorted([j1.id, j2.id, j3.id])
    assert report.requeued_jobs == [j4.id]
    assert j1.id not in adapter.calls  # raw GH questions used, no harvest
    states = {a.id: db.get_application(conn, a.id).state for a in (a1, a2, a3, a4)}
    assert states == {a1.id: AppState.NEEDS_YOU, a2.id: AppState.NEEDS_YOU, a3.id: AppState.NEEDS_YOU, a4.id: AppState.QUEUED}

    clusters = db.list_open_clusters(conn)
    assert len(clusters) == 2  # "why us" x3 and sponsorship x2
    why = next(c for c in clusters if c.never_guess_key is None)
    spons = next(c for c in clusters if c.never_guess_key == "sponsorship")
    assert sorted(why.job_ids) == sorted([j1.id, j2.id, j3.id]) and len(why.variants) == 3
    assert sorted(spons.job_ids) == sorted([j1.id, j3.id])
    assert set(report.new_cluster_ids) == {why.cluster_id, spons.cluster_id}

    # events: prepping + parked transitions, question_opened per cluster, progress
    st = emit.of("application_state")
    assert sum(1 for p in st if p.to_state is AppState.PREPPING) == 4
    assert {p.cluster.cluster_id for p in emit.of("question_opened")} == {why.cluster_id, spons.cluster_id}
    assert emit.of("state")[-1].progress.done == 4


async def test_answer_cluster_requeues_all_jobs(conn, emit):
    seed_profile(conn)
    jobs = [make_job(conn, c, ats=Ats.WORKDAY)[0] for c in ("Stripe", "Airbnb", "Linear")]
    labels = ["Why do you want to work here?", "Why us?", "Why do you want to join our team?"]
    adapter = FakeAdapter({j.id: [FormQuestion(key="w", label=lbl, required=True)] for j, lbl in zip(jobs, labels, strict=True)})
    await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit)
    (cluster,) = db.list_open_clusters(conn)
    assert cluster.job_count == 3

    out = answer_cluster(conn, cluster.cluster_id, "I admire {company}'s engineering culture.")
    assert len(out.transitions) == 3
    assert all(t.to_state is AppState.QUEUED and t.actor is Actor.USER for t in out.transitions)
    for j in jobs:
        assert db.get_application_by_job(conn, j.id).state is AppState.QUEUED
    company = db.get_company(conn, jobs[1].company_id).name
    assert get_inbox_answers(conn, jobs[1].id) == {"why us": f"I admire {company}'s engineering culture."}
    # memory now answers every wording for future jobs
    assert out.answer_id is not None
    assert db.find_answer_by_question(conn, "Why us?") is not None
    assert db.list_open_clusters(conn) == []
    payload = out.to_payload()
    assert payload.status == "answered" and sorted(payload.resumed_application_ids) == sorted(out.application_ids)

    # re-prep: resolved now from the inbox answers -> queued, no new questions
    report = await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit)
    assert report.parked_jobs == [] and len(report.requeued_jobs) == 3


async def test_job_with_two_clusters_requeued_only_after_both(conn, emit):
    j, a = make_job(conn, ats=Ats.WORKDAY)
    adapter = FakeAdapter({j.id: [
        FormQuestion(key="n", label="What is your notice period?", required=True),
        FormQuestion(key="x", label="Describe your ideal team", required=True),
    ]})
    await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit)
    c1, c2 = db.list_open_clusters(conn)
    out1 = answer_cluster(conn, c1.cluster_id, "x")
    assert out1.transitions == [] and db.get_application(conn, a.id).state is AppState.NEEDS_YOU
    out2 = answer_cluster(conn, c2.cluster_id, "y")
    assert [t.application_id for t in out2.transitions] == [a.id]


async def test_answer_never_guess_cluster_saves_to_profile(conn, emit):
    j, a = make_job(conn, ats=Ats.WORKDAY)
    adapter = FakeAdapter({j.id: [FormQuestion(key="s", label="Do you require visa sponsorship?", options=["Yes", "No"], required=True)]})
    await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit)
    (c,) = db.list_open_clusters(conn)
    assert c.never_guess_key == "sponsorship"
    out = answer_cluster(conn, c.cluster_id, "No", save_to_profile=True)
    assert out.saved_to_profile and out.answer_id is None  # never-guess answers are not memory
    assert db.get_never_guess(conn).sponsorship == "Not required"
    assert db.get_application(conn, a.id).state is AppState.QUEUED


async def test_answer_work_auth_without_profile_save_and_per_job(conn, emit):
    j1, _ = make_job(conn, "A", ats=Ats.WORKDAY, location="London, UK")
    j2, _ = make_job(conn, "B", ats=Ats.WORKDAY, location="London, UK")
    q = FormQuestion(key="a", label="Are you authorized to work in the UK?", options=["Yes", "No"], required=True)
    adapter = FakeAdapter({j1.id: [q], j2.id: [q]})
    await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit)
    (c,) = db.list_open_clusters(conn)
    out = answer_cluster(conn, c.cluster_id, "Yes", save_to_profile=False, per_job_answers={j2.id: "No"})
    assert len(out.transitions) == 2
    assert db.get_never_guess(conn).work_auth == {}
    assert get_inbox_answers(conn, j1.id) == {"are you authorized to work in the uk": "Yes"}
    assert get_inbox_answers(conn, j2.id) == {"are you authorized to work in the uk": "No"}


def test_never_guess_value_conversion():
    assert never_guess_value("work_auth", "Yes", question="Authorized to work in the US?") == {"work_auth": {"US": "authorized"}}
    assert never_guess_value("work_auth", "Yes", question="Authorized to work here?") is None
    assert never_guess_value("work_auth", "No", question="Authorized here?", country="GB") == {"work_auth": {"GB": "not_authorized"}}
    assert never_guess_value("relocation", "Depends on the city") == {"relocation": "case_by_case"}
    assert never_guess_value("attest_accuracy", "maybe") is None
    assert never_guess_value("notice_period", "60 days") == {"notice_period": "60 days"}
    assert never_guess_value("criminal_history", "No") is None


async def test_skip_cluster(conn, emit):
    j1, a1 = make_job(conn, "A", ats=Ats.WORKDAY)
    j2, a2 = make_job(conn, "B", ats=Ats.WORKDAY)
    adapter = FakeAdapter({
        j1.id: [FormQuestion(key="n", label="Do you hold an active security clearance?", required=True)],
        j2.id: [FormQuestion(key="n", label="Do you hold an active security clearance?", required=True),
                FormQuestion(key="x", label="Describe your ideal team", required=True)],
    })
    await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit)
    clearance = next(c for c in db.list_open_clusters(conn) if "clearance" in c.canonical_question)
    out = skip_cluster(conn, clearance.cluster_id)
    assert {t.application_id for t in out.transitions} == {a1.id, a2.id}
    assert all(t.to_state is AppState.SKIPPED and t.actor is Actor.USER for t in out.transitions)
    # j2's other question was detached (it no longer blocks anything)
    assert db.list_open_clusters(conn) == []
    assert out.to_payload().resumed_application_ids == []


async def test_harvest_failure_requeues(conn, emit):
    j, a = make_job(conn, ats=Ats.WORKDAY)
    adapter = FakeAdapter({j.id: RuntimeError("browser crashed")})
    report = await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit)
    assert report.harvest_failed_jobs == [j.id]
    app = db.get_application(conn, a.id)
    assert app.state is AppState.QUEUED and app.state_reason == "harvest_unavailable"


async def test_no_adapter_requeues(conn, emit):
    j, a = make_job(conn, ats=Ats.WORKDAY)
    report = await run_prep(conn, llm=FakeLLMProvider(), adapters=[], emit=emit)
    assert report.harvest_failed_jobs == [j.id]


async def test_pause_stops_between_jobs(conn, emit):
    j1, a1 = make_job(conn, "A", ats=Ats.WORKDAY)
    j2, a2 = make_job(conn, "B", ats=Ats.WORKDAY)
    adapter = FakeAdapter({j1.id: [FormQuestion(key="e", label="Email")], j2.id: [FormQuestion(key="e", label="Email")]})
    calls = {"n": 0}

    def paused() -> bool:
        calls["n"] += 1
        return calls["n"] > 1  # pause after the first job starts

    report = await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit, is_paused=paused)
    assert report.paused and report.jobs_scanned == 1
    assert db.get_application(conn, a2.id).state is AppState.QUEUED


async def test_prep_only_given_queued_ids(conn, emit):
    j1, a1 = make_job(conn, "A", ats=Ats.WORKDAY)
    j2, a2 = make_job(conn, "B", ats=Ats.WORKDAY, state=AppState.SCORED)
    adapter = FakeAdapter({j1.id: [], j2.id: []})
    report = await run_prep(conn, llm=FakeLLMProvider(), adapters=[adapter], emit=emit, application_ids=[a1.id, a2.id])
    assert report.jobs_scanned == 1


async def test_answer_patches_easy_apply_ask_me_rows(conn):
    j, a = make_job(conn, easy_apply=True, state=AppState.SCORED)
    db.upsert_easy_apply(conn, j.id, url="https://example.test/job", drafted_answers=[
        DraftedAnswer(question="What is your notice period?", answer="", ask_me=True, origin=AnswerOrigin.USER),
    ])
    q, _ = db.add_question(conn, canonical_question="What is your notice period?", job_id=j.id, never_guess_key="notice_period")
    out = answer_cluster(conn, q.cluster_id, "30 days")
    assert out.transitions == []  # easy apply job isn't parked; state untouched
    row = db.get_easy_apply(conn, j.id).drafted_answers[0]
    assert (row.answer, row.ask_me, row.origin) == ("30 days", False, AnswerOrigin.USER)


def test_answer_unknown_cluster_raises(conn):
    with pytest.raises(db.NotFound):
        answer_cluster(conn, "nope", "x")
    assert db.list_questions(conn, status=QuestionStatus.OPEN) == []
