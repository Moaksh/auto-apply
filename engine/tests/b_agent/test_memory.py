from __future__ import annotations

import numpy as np

from autoapply import db
from autoapply.answers.memory import AnswerMemory, HashingEmbedder, intents_compatible, render_template, similarity
from autoapply.enums import AnswerSource, QuestionReason
from autoapply.llm.provider import FakeLLMProvider

from .conftest import make_job


def test_embedder_is_deterministic_and_normalised():
    e1, e2 = HashingEmbedder(), HashingEmbedder()
    a = e1.embed(["Why do you want to work here?", "Desired salary"])
    b = e2.embed(["Why do you want to work here?", "Desired salary"])
    assert np.allclose(a, b)
    assert np.allclose(np.linalg.norm(a, axis=1), 1.0, atol=1e-5)


def test_paraphrases_close_distinct_questions_far():
    assert similarity("Why us?", "Why do you want to work here?") >= 0.82
    assert similarity("What is your expected salary?", "Desired compensation") >= 0.82
    assert similarity("Years of experience with Python", "How many years of Python experience do you have?") >= 0.82
    assert similarity("Years of experience with Python", "How many years of Go experience do you have?") < 0.5
    assert similarity("Why us?", "Why this role?") < 0.5
    assert not intents_compatible("Why us?", "Why this role?")
    assert not intents_compatible("What is your expected salary?", "What is your notice period?")


def test_render_template():
    assert render_template("I love {company} and the {role} role", company="Stripe", role="SRE") == "I love Stripe and the SRE role"
    assert render_template("{company}", company=None, role=None) == "your company"


def test_save_and_lookup_exact_paraphrase_and_miss(conn):
    mem = AnswerMemory(conn)
    saved = mem.save("Why do you want to work here?", "Because {company} builds things I care about.")
    assert saved.is_template and saved.embedding_model == mem.embedder.model_name
    exact = mem.lookup("why do you want to work here", company="Stripe")
    assert exact and exact.similarity == 1.0 and exact.rendered == "Because Stripe builds things I care about."
    para = mem.lookup("Why us?", company="Airbnb")
    assert para and para.answer.id == saved.id and para.rendered.startswith("Because Airbnb")
    assert mem.lookup("What is your notice period?") is None
    assert mem.lookup("Why this role?") is None  # intent mismatch


def test_lookup_reembeds_answers_missing_embeddings(conn):
    db.add_answer(conn, canonical_question="Desired compensation", answer="Negotiable")  # no embedding
    mem = AnswerMemory(conn)
    hit = mem.lookup("What are your salary expectations?")
    assert hit and hit.answer.answer == "Negotiable"
    assert db.get_answer_embeddings(conn, mem.embedder.model_name)


def test_use_counts(conn):
    mem = AnswerMemory(conn)
    a = mem.save("How did you hear about us?", "Your engineering blog")
    mem.record_use(a.id)
    mem.record_use(a.id)
    got = db.get_answer(conn, a.id)
    assert got.uses == 2 and got.last_used_at is not None


async def test_grey_zone_llm_paraphrase_check(conn):
    llm = FakeLLMProvider(rules=[("PARAPHRASE CHECK", {"same": True})])
    mem = AnswerMemory(conn, llm=llm)
    mem.save("Describe a project you are proud of", "I rebuilt our ledger service.")
    q = "Tell us about a project you are proud of"
    assert mem.lookup(q) is None  # below threshold
    hit = await mem.lookup_async(q)
    assert hit and hit.answer.answer == "I rebuilt our ledger service."
    assert len(llm.calls) == 1
    no = AnswerMemory(conn, llm=FakeLLMProvider(rules=[("PARAPHRASE CHECK", {"same": False})]))
    assert await no.lookup_async(q) is None


def test_cluster_open_questions_groups_paraphrases(conn):
    jobs = [make_job(conn, f"Co{i}", "Engineer")[0] for i in range(5)]
    mem = AnswerMemory(conn)
    db.add_question(conn, canonical_question="Why do you want to work here?", job_id=jobs[0].id)
    db.add_question(conn, canonical_question="Why us?", job_id=jobs[1].id)
    db.add_question(conn, canonical_question="What excites you about working at our company?", job_id=jobs[2].id)
    db.add_question(conn, canonical_question="How many years of Go experience do you have?", job_id=jobs[3].id)
    db.add_question(conn, canonical_question="Do you require visa sponsorship?", job_id=jobs[0].id,
                    never_guess_key="sponsorship", reason=QuestionReason.NEVER_GUESS)
    db.add_question(conn, canonical_question="Will you need us to sponsor a work visa?", job_id=jobs[4].id,
                    never_guess_key="sponsorship", reason=QuestionReason.NEVER_GUESS)
    clusters = mem.cluster_open_questions(threshold=0.78)
    by_text = {q.canonical_question: cid for cid, qs in clusters.items() for q in qs}
    assert by_text["Why do you want to work here?"] == by_text["Why us?"] == by_text["What excites you about working at our company?"]
    assert by_text["How many years of Go experience do you have?"] != by_text["Why us?"]
    assert by_text["Do you require visa sponsorship?"] == by_text["Will you need us to sponsor a work visa?"]
    assert len(clusters) == 3
    # the cluster keeps the oldest member's id and is stable on re-run
    first = db.list_questions(conn)[0]
    assert by_text["Why do you want to work here?"] == first.cluster_id
    again = mem.cluster_open_questions(threshold=0.78)
    assert {cid for cid in again} == {cid for cid in clusters}
    cluster = db.get_cluster(conn, first.cluster_id)
    assert cluster.job_count == 3 and len(cluster.variants) == 3


def test_work_auth_clusters_split_by_country(conn):
    j1, _ = make_job(conn, "A", "E")
    j2, _ = make_job(conn, "B", "E")
    mem = AnswerMemory(conn)
    db.add_question(conn, canonical_question="Are you authorized to work in the United States?", job_id=j1.id, never_guess_key="work_auth")
    db.add_question(conn, canonical_question="Are you authorized to work in India?", job_id=j2.id, never_guess_key="work_auth")
    assert len(mem.cluster_open_questions()) == 2


def test_find_cluster_for(conn):
    j1, _ = make_job(conn, "A", "E")
    mem = AnswerMemory(conn)
    q, _ = db.add_question(conn, canonical_question="Why do you want to work here?", job_id=j1.id)
    assert mem.find_cluster_for("Why us?") == q.cluster_id
    assert mem.find_cluster_for("What is your favourite editor?") is None


def test_save_updates_same_question(conn):
    mem = AnswerMemory(conn)
    a = mem.save("Notice?", "30 days", source=AnswerSource.GENERATED)
    b = mem.save("notice?", "60 days")
    assert a.id == b.id and b.answer == "60 days" and b.source is AnswerSource.USER
