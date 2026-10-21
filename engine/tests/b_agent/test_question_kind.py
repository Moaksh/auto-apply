"""Needs-You kinds: form questions vs agent actions (blockers), and choice options.

* the deterministic classifier (account / password / CAPTCHA / verification -> action);
* ask_user(kind=...) and the fallback for LLM slips / harvested password fields;
* actions never reach answer memory and never cluster with form questions;
* the v8 migration classifies already-open rows;
* options survive into the questions row (text + options -> select) and an exact option answers.
"""

from __future__ import annotations

import json

import pytest

from autoapply import db, prep
from autoapply.answers.memory import AnswerMemory
from autoapply.apply.agentic import AgentToolbox, ToolGate
from autoapply.apply.base import UnresolvedField
from autoapply.enums import AppState, FieldType, Mode, QuestionKind, QuestionReason
from autoapply.models import FormQuestion
from autoapply.question_kind import action_type, classify, resolve_kind

from .conftest import make_ctx, make_job, seed_profile


@pytest.mark.parametrize(
    ("label", "expected"),
    [
        ("Account required to apply at jpmc.fa.oraclecloud.com (JPMC)", "account"),
        ("Choose Password", "account"),
        ("Retype Password", "account"),
        ("Retype Email Address", "account"),
        ("Confirm your email", "account"),
        ("Create an account to continue", "account"),
        ("Sign in to apply", "account"),
        ("Solve the CAPTCHA on the Jpmc application", "captcha"),
        ("Verify you are human", "captcha"),
        ("Enter the verification code we sent to your phone", "verification"),
        ("No online application form at acme.com: email your CV to jobs@acme.com", "other"),
        ("Are you authorized to work in the United States?", None),
        ("Years of Go experience?", None),
        ("Expected salary", None),
        ("Why do you want to work at {company}?", None),
        ("Email", None),
        ("GitHub username", None),
        # the live email-code flow: the user TYPES the code while the session waits
        ("Security code Workday emailed to a@b.c for Acme · SWE (6-character code, expires soon)", None),
    ],
)
def test_classifier(label, expected):
    assert action_type(label) == expected
    assert classify(label) is (QuestionKind.ACTION if expected else QuestionKind.QUESTION)


def test_captcha_reason_is_always_an_action():
    assert classify("Anything at all", QuestionReason.CAPTCHA) is QuestionKind.ACTION
    # an explicit action from the agent wins; an explicit "question" is overridden for passwords
    assert resolve_kind("Upload your portfolio on our site", None, "action") is QuestionKind.ACTION
    assert resolve_kind("Choose Password", None, "question") is QuestionKind.ACTION
    assert resolve_kind("Years of Go?", None, "question") is QuestionKind.QUESTION


# ---- agent tools -----------------------------------------------------------------------


@pytest.fixture
def toolbox(conn, autoapply_home, fake_llm, emit, tmp_path):
    seed_profile(conn)
    job, app = make_job(conn, company="Bayer", state=AppState.FILLING)
    ctx = make_ctx(conn, app.id, fake_llm, autoapply_home, emit)
    return AgentToolbox(ctx, ToolGate(), phase="fill", output_dir=tmp_path, mode=Mode.REVIEW, cover_letters_dir=tmp_path / "cl")


async def test_ask_user_kind_action(toolbox):
    out = await toolbox.ask_user({"question": "Account required to apply at bayer.wd3.myworkdayjobs.com", "kind": "action"})
    assert "task" in out["content"][0]["text"]
    (uf,) = toolbox.unresolved.values()
    assert uf.kind == "action" and uf.suggested_answer is None and uf.never_guess_key is None


async def test_ask_user_question_slip_is_reclassified(toolbox):
    await toolbox.ask_user({"question": "Choose Password", "kind": "question"})
    await toolbox.ask_user({"question": "Years of Go?", "field_type": "number"})
    kinds = {u.question.label: u.kind for u in toolbox.unresolved.values()}
    assert kinds == {"Choose Password": "action", "Years of Go?": "question"}


async def test_lookup_answer_never_fills_password_fields(toolbox):
    out = await toolbox.lookup_answer({"question": "Retype Password"})
    payload = json.loads(out["content"][0]["text"])
    assert payload["status"] == "needs_user" and payload["reason"] == "action"
    assert not toolbox.resolved
    assert [u.kind for u in toolbox.unresolved.values()] == ["action"]


async def test_ask_user_choice_options_become_select(toolbox):
    await toolbox.ask_user({"question": "Comfortable with working from office?", "options": ["Strong No", "No", "Yes", "Strong Yes"]})
    (uf,) = toolbox.unresolved.values()
    assert uf.question.field_type is FieldType.SELECT
    assert uf.question.options == ["Strong No", "No", "Yes", "Strong Yes"]


async def test_report_form_questions_keeps_options(toolbox):
    toolbox.phase = "harvest"
    await toolbox.report_form_questions({"questions": [
        {"label": "Availability", "field_type": "text", "options": ["Immediate", "Less than 30 days", "30 days", "More than 30 days"]},
        {"label": "Years of Go?", "field_type": "number"},
    ]})
    avail, years = toolbox.harvested
    assert avail.field_type is FieldType.SELECT and avail.options[1] == "Less than 30 days"
    assert years.field_type is FieldType.NUMBER and years.options == []


# ---- inbox: parking, clustering, resolving ----------------------------------------------


def _park(conn, job_id, *items):
    return prep.park_unresolved(conn, job_id, [UnresolvedField(question=q, reason=r, kind=k) for q, r, k in items],
                                memory=AnswerMemory(conn))


def test_actions_group_per_company_and_never_join_questions(conn):
    bayer, _ = make_job(conn, company="Bayer", state=AppState.NEEDS_YOU)
    jpmc, _ = make_job(conn, company="JPMC", state=AppState.NEEDS_YOU)
    _park(conn, bayer.id,
          (FormQuestion(key="p1", label="Choose Password"), "unknown", None),
          (FormQuestion(key="p2", label="Retype Password"), "unknown", None),
          (FormQuestion(key="e", label="Retype Email Address"), "unknown", None),
          (FormQuestion(key="em", label="Email"), "unknown", None))
    _park(conn, jpmc.id, (FormQuestion(key="a", label="Account required to apply at jpmc.fa.oraclecloud.com"), "unknown", "action"))
    AnswerMemory(conn).cluster_open_questions()
    clusters = db.list_open_clusters(conn)
    actions = [c for c in clusters if c.kind == "action"]
    questions = [c for c in clusters if c.kind == "question"]
    assert len(actions) == 2  # one "create an account" item per company
    bayer_action = next(c for c in actions if c.companies == ["Bayer"])
    assert set(bayer_action.variants) == {"Choose Password", "Retype Password", "Retype Email Address"}
    assert bayer_action.action_type == "account"
    assert [c.canonical_question for c in questions] == ["Email"]
    counts = db.compute_counts(conn)
    assert counts.needs_you_clusters == 3 and counts.needs_you_actions == 2


def test_done_on_an_action_requeues_and_never_touches_memory(conn):
    job, app = make_job(conn, company="Bayer", state=AppState.NEEDS_YOU)
    _park(conn, job.id, (FormQuestion(key="p", label="Choose Password"), "unknown", None))
    (cluster,) = db.list_open_clusters(conn)
    assert cluster.kind == "action"
    before = len(db.list_answers(conn))
    outcome = prep.answer_cluster(conn, cluster.cluster_id, "hunter2", save_to_memory=True, save_to_profile=True)
    assert len(db.list_answers(conn)) == before
    assert outcome.answer_id is None
    assert db.get_application(conn, app.id).state is AppState.QUEUED
    from autoapply.answers.resolver import get_inbox_answers

    assert get_inbox_answers(conn, job.id) == {}  # nothing typed into the form on retry
    assert db.list_questions(conn, cluster_id=cluster.cluster_id)[0].answer_text == "(done by you)"


def test_actions_are_not_auto_resolved_from_facts(conn):
    job, _ = make_job(conn, state=AppState.NEEDS_YOU)
    seed_profile(conn)
    _park(conn, job.id, (FormQuestion(key="e", label="Retype Email Address", field_type=FieldType.EMAIL), "unknown", None))
    assert prep.auto_resolve_known(conn) == []
    assert len(db.list_open_clusters(conn)) == 1


def test_options_survive_into_the_questions_row_and_an_exact_option_answers(conn):
    job, app = make_job(conn, company="Rippling", state=AppState.NEEDS_YOU)
    opts = ["Strong No", "No", "Yes", "Strong Yes"]
    _park(conn, job.id, (FormQuestion(key="wfo", label="Comfortable with working from office?", options=opts), "unknown", None))
    (q,) = db.list_questions(conn)
    assert q.options == opts and q.field_type is FieldType.SELECT and q.kind is QuestionKind.QUESTION
    (cluster,) = db.list_open_clusters(conn)
    assert cluster.options == opts and cluster.field_type is FieldType.SELECT
    prep.answer_cluster(conn, cluster.cluster_id, "Strong Yes", save_to_memory=False)
    assert db.get_application(conn, app.id).state is AppState.QUEUED
    assert db.list_questions(conn)[0].answer_text == "Strong Yes"


def test_v8_migration_classifies_already_open_rows(conn):
    a, _ = make_job(conn, company="JPMC", state=AppState.NEEDS_YOU)
    b, _ = make_job(conn, company="Bayer", state=AppState.NEEDS_YOU)
    shared = db.new_id()
    for label, job in [("Choose Password", b), ("Retype Password", b), ("Retype Email Address", b),
                       ("Solve the CAPTCHA on the Jpmc application", a), ("Years of Go?", a)]:
        db.add_question(conn, canonical_question=label, job_id=job.id, cluster_id=shared, kind="question")
    # rows from before v8: everything a "question", all in one (bad) cluster
    conn.execute("DELETE FROM schema_version WHERE version = 8")
    db._migrate_v8(conn)
    assert conn.execute("SELECT 1 FROM schema_version WHERE version = 8").fetchone() is not None
    kinds = {q.canonical_question: (q.kind, q.cluster_id) for q in db.list_questions(conn)}
    assert kinds["Years of Go?"] == (QuestionKind.QUESTION, shared)
    assert kinds["Choose Password"][0] is QuestionKind.ACTION
    assert kinds["Choose Password"][1] == kinds["Retype Password"][1] == kinds["Retype Email Address"][1] != shared
    assert kinds["Solve the CAPTCHA on the Jpmc application"][1] not in (shared, kinds["Choose Password"][1])
    # idempotent
    conn.execute("DELETE FROM schema_version WHERE version = 8")
    db._migrate_v8(conn)
    assert {q.canonical_question: q.cluster_id for q in db.list_questions(conn)} == {k: v[1] for k, v in kinds.items()}
