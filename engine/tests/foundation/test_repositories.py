from __future__ import annotations

import sqlite3
from datetime import timedelta

import numpy as np
import pytest

from autoapply import db
from autoapply.enums import (
    Actor,
    AnswerOrigin,
    AppState,
    ApplicationMode,
    BoardStatus,
    Mode,
    QuestionReason,
    QuestionStatus,
    RunOutcome,
)
from autoapply.models import utcnow

S = AppState


def job(conn, company="Stripe", title="Backend Engineer", location="Remote", url=None, **kw):
    co = db.upsert_company(conn, company)
    j, created = db.insert_job(conn, company_id=co.id, source=kw.pop("source", "greenhouse"), title=title,
                               location=location, apply_url=url, **kw)
    return j, created


def submit(conn, app_id):
    for s in (S.SCORED, S.QUEUED, S.FILLING, S.SUBMITTING, S.SUBMITTED):
        db.transition(conn, app_id, s)


# ---- helpers ---------------------------------------------------------------------------


def test_normalize_helpers():
    assert db.normalize_text("  Stripé,  Inc. ") == "stripe inc"
    assert db.make_dedupe_key("Stripe", "Backend Engineer (Payments)", "Remote - US") == "stripe|backend engineer payments|remote us"
    assert db.normalize_url("HTTP://www.Boards.Greenhouse.io/stripe/jobs/1/?gh_src=abc&utm_source=li&x=2#apply") == \
        "https://boards.greenhouse.io/stripe/jobs/1?x=2"
    assert db.normalize_url(None) is None


def test_embedding_pack_roundtrip():
    v = np.array([0.1, -0.5, 2.0], dtype=np.float32)
    assert np.allclose(db.unpack_embedding(db.pack_embedding(v)), v)
    assert db.unpack_embedding(None) is None


# ---- meta / profile / never_guess / preferences ---------------------------------------


def test_meta(conn):
    assert db.get_meta(conn, "x", 5) == 5
    db.set_meta(conn, "x", {"a": [1, 2]})
    assert db.get_meta(conn, "x") == {"a": [1, 2]}
    db.set_meta(conn, "x", True)
    assert db.get_meta(conn, "x") is True
    db.delete_meta(conn, "x")
    assert db.get_meta(conn, "x") is None


def test_source_sessions_counter(conn):
    assert db.get_source_sessions(conn, "linkedin") == 0
    assert db.increment_source_sessions(conn, "linkedin") == 1
    assert db.increment_source_sessions(conn, "linkedin") == 2
    assert db.get_source_sessions(conn, "glassdoor") == 0


def test_profile_update(conn):
    p = db.update_profile(conn, {
        "full_name": "Moaksh Kakkar", "skills": ["go", "python"],
        "work_history": [{"company": "Plum", "title": "SWE", "highlights": ["built x"]}],
        "links": {"github": "https://github.com/x"},
    })
    assert p.full_name == "Moaksh Kakkar"
    assert p.work_history[0].company == "Plum"
    assert db.get_profile(conn).skills == ["go", "python"]
    p2 = db.update_profile(conn, {"email": "a@b.c"})
    assert p2.full_name == "Moaksh Kakkar" and p2.email == "a@b.c"
    with pytest.raises(ValueError):
        db.update_profile(conn, {"nope": 1})


def test_never_guess_set_and_clear(conn):
    ng = db.get_never_guess(conn)
    assert ng.sponsorship is None and ng.eeo_policy == "decline" and ng.work_auth == {}
    ng = db.set_never_guess(conn, {"sponsorship": "Requires H-1B", "work_auth": {"US": "requires_sponsorship"},
                                   "attest_accuracy": True, "relocation": "case_by_case"})
    assert ng.sponsorship == "Requires H-1B" and ng.work_auth == {"US": "requires_sponsorship"}
    assert ng.attest_accuracy is True
    ng = db.set_never_guess(conn, {"sponsorship": None})  # back to "always ask"
    assert ng.sponsorship is None
    assert conn.execute("SELECT COUNT(*) FROM never_guess WHERE key='sponsorship'").fetchone()[0] == 0
    with pytest.raises(ValueError):
        db.set_never_guess(conn, {"relocation": "maybe"})
    with pytest.raises(ValueError):
        db.set_never_guess(conn, {"unknown_key": "x"})


def test_preferences_roundtrip_and_patch(conn):
    p = db.get_preferences(conn)
    assert p.match_threshold == 70
    p = db.update_preferences(conn, {"match_threshold": 80, "roles": ["Backend Engineer"], "per_ats_mode": {"lever": "review"},
                                     "schedule": ["18:00", "09:00"], "hide_without_salary": True})
    assert p.match_threshold == 80
    assert p.schedule == ["09:00", "18:00"]
    again = db.get_preferences(conn)
    assert again == p
    assert again.effective_mode(ats="lever") is Mode.REVIEW
    with pytest.raises(ValueError):
        db.update_preferences(conn, {"match_threshold": 101})
    with pytest.raises(ValueError):
        db.update_preferences(conn, {"bogus": 1})
    assert db.get_preferences(conn).match_threshold == 80  # failed patch didn't write


# ---- resume variants / stories / answers -------------------------------------------------


def test_resume_variants_default_and_replace(conn):
    a = db.add_resume_variant(conn, label="Backend", file_path="/r/a.pdf", tags=["backend", "go"], is_default=True)
    b = db.add_resume_variant(conn, label="ML", file_path="/r/b.pdf", tags=["ml"])
    assert a.is_default and not b.is_default
    db.update_resume_variant(conn, b.id, is_default=True)
    assert not db.get_resume_variant(conn, a.id).is_default
    assert db.get_resume_variant(conn, b.id).is_default
    a2 = db.add_resume_variant(conn, label="Backend v2", file_path="/r/a2.pdf", replaces=a.id)
    assert a2.version == 2
    old = db.get_resume_variant(conn, a.id)
    assert old.replaced_by == a2.id and not old.enabled
    assert [v.id for v in db.list_resume_variants(conn, enabled_only=True)] == [b.id, a2.id]
    db.set_resume_embedding(conn, b.id, [1.0, 0.0], "tfidf")
    vec, model = db.get_resume_embedding(conn, b.id)
    assert model == "tfidf" and np.allclose(vec, [1.0, 0.0])
    with pytest.raises(sqlite3.IntegrityError):  # partial unique index: one default
        conn.execute("UPDATE resume_variants SET is_default = 1")


def test_stories_crud(conn):
    s = db.upsert_story(conn, title="Payments scale", situation="s", task="t", action="a", result="r", tags=["scale"])
    s2 = db.upsert_story(conn, id=s.id, title="Payments at scale", tags=["scale", "leadership"])
    assert s2.title == "Payments at scale" and s2.tags == ["scale", "leadership"] and s2.situation == ""
    db.record_story_use(conn, s.id)
    assert db.get_story(conn, s.id).uses == 1
    assert len(db.list_stories(conn)) == 1
    db.delete_story(conn, s.id)
    with pytest.raises(db.NotFound):
        db.get_story(conn, s.id)
    with pytest.raises(db.NotFound):
        db.delete_story(conn, s.id)


def test_answers_upsert_template_and_embeddings(conn):
    a = db.add_answer(conn, canonical_question="Why do you want to work here?", answer="I'm drawn to {company}.")
    assert a.is_template
    b = db.add_answer(conn, canonical_question="why do you want to work here?", answer="Because.", embedding=[0.5, 0.5],
                      embedding_model="tfidf")
    assert b.id == a.id and b.answer == "Because." and not b.is_template
    db.record_answer_use(conn, a.id)
    got = db.get_answer(conn, a.id)
    assert got.uses == 1 and got.last_used_at is not None
    assert db.find_answer_by_question(conn, "WHY DO YOU WANT TO WORK HERE?").id == a.id
    assert [i for i, _ in db.get_answer_embeddings(conn)] == [a.id]
    assert db.get_answer_embeddings(conn, model="other") == []
    upd = db.update_answer(conn, a.id, answer="New", canonical_question="Why us?")
    assert upd.canonical_question == "Why us?" and upd.embedding_model is None
    db.delete_answer(conn, a.id)
    assert db.list_answers(conn) == []


# ---- companies / jobs / scores -------------------------------------------------------------


def test_company_upsert_merges(conn):
    c1 = db.upsert_company(conn, "Stripe, Inc.")
    c2 = db.upsert_company(conn, "stripe inc", ats="greenhouse", board_token="stripe", watch=True)
    assert c1.id == c2.id and c2.ats == "greenhouse" and c2.watch
    assert db.get_company_by_name(conn, "STRIPE INC").id == c1.id
    assert [c.id for c in db.list_companies(conn, watch_only=True)] == [c1.id]
    with pytest.raises(ValueError):
        db.upsert_company(conn, "  ")


def test_job_dedupe_by_key_and_url(conn):
    j1, created = job(conn, url="https://boards.greenhouse.io/stripe/jobs/1")
    assert created
    j2, created = job(conn, company="stripe", title="backend engineer", location="remote")
    assert not created and j2.id == j1.id
    j3, created = job(conn, title="Different title", url="https://boards.greenhouse.io/stripe/jobs/1?gh_src=li", source="linkedin")
    assert not created and j3.id == j1.id
    j4, created = job(conn, title="Staff Engineer", url="https://boards.greenhouse.io/stripe/jobs/2")
    assert created
    assert conn.execute("SELECT COUNT(*) FROM applications").fetchone()[0] == 2
    assert db.find_job_by_apply_url(conn, "https://boards.greenhouse.io/stripe/jobs/2/").id == j4.id
    assert {j.id for j in db.list_jobs(conn, states=[S.DISCOVERED])} == {j1.id, j4.id}
    assert db.list_jobs(conn, source="lever") == []
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO jobs(source, company_id, title, dedupe_key) VALUES ('lever', ?, 'x', ?)",
                     (j1.company_id, j1.dedupe_key))


def test_job_update_summary_and_mode(conn):
    j, _ = job(conn, url="https://x.com/a", salary_min=100, salary_max=200, salary_currency="USD")
    j = db.update_job(conn, j.id, description="JD", apply_url="https://x.com/b?utm_source=z", raw={"k": 1})
    assert j.apply_url_norm == "https://x.com/b" and j.raw == {"k": 1}
    j = db.set_job_mode_override(conn, j.id, "review")
    assert j.mode_override is Mode.REVIEW
    s = db.job_summary(conn, j.id)
    assert s.company == "Stripe" and s.application_id is not None and s.salary_max == 200
    with pytest.raises(ValueError):
        db.update_job(conn, j.id, dedupe_key="x")


def test_scores(conn):
    j, _ = job(conn)
    db.upsert_score(conn, j.id, score=91, reasons={"summary": "good", "factors": {"skills": 95}}, model="fake", tokens_in=10)
    s = db.upsert_score(conn, j.id, score=None, skip_reason="excluded_keyword:crypto")
    assert s.score is None and s.skip_reason == "excluded_keyword:crypto" and s.reasons == {}
    with pytest.raises(sqlite3.IntegrityError):
        db.upsert_score(conn, j.id, score=150)


def test_cooldown(conn):
    j, _ = job(conn)
    app = db.get_application_by_job(conn, j.id)
    assert not db.company_in_cooldown(conn, j.company_id, 30)
    submit(conn, app.id)
    assert db.company_in_cooldown(conn, j.company_id, 30)
    assert not db.company_in_cooldown(conn, j.company_id, 30, now=utcnow() + timedelta(days=31))
    assert not db.company_in_cooldown(conn, j.company_id, 0)


# ---- applications / answers audit -----------------------------------------------------------


def test_application_fields_and_tokens(conn):
    j, _ = job(conn)
    app = db.get_application_by_job(conn, j.id)
    v = db.add_resume_variant(conn, label="B", file_path="/r.pdf")
    app = db.update_application(conn, app.id, mode="review", resume_variant_id=v.id, resume_pick_score=0.9)
    assert app.mode is ApplicationMode.REVIEW and app.resume_variant_id == v.id
    db.add_application_tokens(conn, app.id, 100, 20)
    db.add_application_tokens(conn, app.id, 1, 2)
    app = db.get_application(conn, app.id)
    assert (app.tokens_in, app.tokens_out) == (101, 22)
    assert [a.id for a in db.list_applications(conn, states=["discovered"])] == [app.id]


def test_application_answers_audit_and_edit(conn):
    j, _ = job(conn)
    app = db.get_application_by_job(conn, j.id)
    aa = db.add_application_answer(conn, app.id, question="Years with Go?", answer="4", origin=AnswerOrigin.CV,
                                   confidence=0.93, field_type="number", bbox={"x": 1, "y": 2, "w": 3, "h": 4})
    assert aa.bbox.w == 3
    edited = db.edit_application_answer(conn, aa.id, "5")
    assert edited.answer == "5" and edited.origin is AnswerOrigin.USER and edited.confidence == 1.0
    assert len(db.list_application_answers(conn, app.id)) == 1
    with pytest.raises(sqlite3.IntegrityError):
        db.add_application_answer(conn, app.id, question="q", answer="a", origin="cv", confidence=1.5)


# ---- questions inbox ----------------------------------------------------------------------


def test_questions_merge_cluster_and_resolve(conn):
    j1, _ = job(conn, title="A")
    j2, _ = job(conn, company="Ramp", title="B")
    j3, _ = job(conn, company="Notion", title="C")
    q1, created = db.add_question(conn, canonical_question="Why Stripe?", job_id=j1.id, field_type="textarea")
    assert created
    q1b, created = db.add_question(conn, canonical_question="why stripe?", job_id=j1.id)
    assert not created and q1b.id == q1.id and q1b.job_ids == [j1.id]
    q2, _ = db.add_question(conn, canonical_question="What draws you to Ramp?", job_id=j2.id, cluster_id=q1.cluster_id)
    q3, _ = db.add_question(conn, canonical_question="Notice period?", job_id=j3.id, never_guess_key="notice_period",
                            reason=QuestionReason.NEVER_GUESS, options=["30", "60"])
    db.add_question(conn, canonical_question="Notice period?", job_id=j1.id, options=["60", "90"])

    clusters = db.list_open_clusters(conn)
    assert len(clusters) == 2
    why = next(c for c in clusters if c.cluster_id == q1.cluster_id)
    assert why.job_count == 2 and set(why.companies) == {"Stripe", "Ramp"}
    assert why.variants == ["Why Stripe?", "What draws you to Ramp?"]
    notice = db.get_cluster(conn, q3.cluster_id)
    assert notice.never_guess_key == "notice_period" and notice.options == ["30", "60", "90"]
    assert notice.reason is QuestionReason.NEVER_GUESS

    assert db.jobs_with_open_questions(conn) == {j1.id, j2.id, j3.id}
    ans = db.add_answer(conn, canonical_question="Why {company}?", answer="Because {company}.")
    affected = db.resolve_cluster(conn, q1.cluster_id, answer_text="Because {company}.", answer_id=ans.id)
    assert sorted(affected) == sorted([j1.id, j2.id])
    # j1 still blocked by the notice-period question, j2 free
    assert db.jobs_without_open_questions(conn, affected) == [j2.id]
    assert db.get_cluster(conn, q1.cluster_id) is None
    assert db.get_cluster(conn, q1.cluster_id, open_only=False).cluster_id == q1.cluster_id
    with pytest.raises(db.NotFound):
        db.resolve_cluster(conn, q1.cluster_id)
    # after resolution, the same text can be asked again as a new open question
    _, created = db.add_question(conn, canonical_question="Why Stripe?", job_id=j1.id)
    assert created


def test_skip_and_remove_job_from_questions(conn):
    j1, _ = job(conn, title="A")
    j2, _ = job(conn, title="B")
    q, _ = db.add_question(conn, canonical_question="Portfolio URL?", job_id=j1.id, field_type="url")
    db.add_question(conn, canonical_question="Portfolio URL?", job_id=j2.id)
    db.remove_job_from_questions(conn, j1.id)
    assert db.get_question(conn, q.id).job_ids == [j2.id]
    db.remove_job_from_questions(conn, j2.id)
    assert db.get_question(conn, q.id).status is QuestionStatus.SKIPPED
    j3, _ = job(conn, title="C")
    q2, _ = db.add_question(conn, canonical_question="Kubernetes years?", job_id=j3.id)
    assert db.resolve_cluster(conn, q2.cluster_id, status="skipped") == [j3.id]
    assert db.get_question(conn, q2.id).status is QuestionStatus.SKIPPED
    with pytest.raises(ValueError):
        db.resolve_cluster(conn, q2.cluster_id, status="open")


def test_question_embeddings_and_recluster(conn):
    j, _ = job(conn)
    q, _ = db.add_question(conn, canonical_question="Q1", job_id=j.id, embedding=[1, 0], embedding_model="tfidf")
    q2, _ = db.add_question(conn, canonical_question="Q2", job_id=j.id)
    db.set_question_embedding(conn, q2.id, [0, 1], "tfidf")
    db.set_question_cluster(conn, q2.id, q.cluster_id)
    rows = db.get_question_embeddings(conn)
    assert {r[1] for r in rows} == {q.cluster_id} and all(r[2] is not None for r in rows)
    assert len(db.list_open_clusters(conn)) == 1


# ---- easy apply ----------------------------------------------------------------------------


def test_easy_apply_lifecycle_records_manual_application(conn):
    j, _ = job(conn, source="linkedin", easy_apply=True, ats="linkedin_easy_apply", url="https://linkedin.com/jobs/view/1")
    item = db.upsert_easy_apply(conn, j.id, url="https://linkedin.com/jobs/view/1",
                                drafted_answers=[{"question": "Phone", "answer": "+91", "origin": "profile"}])
    assert item.drafted_answers[0].question == "Phone" and not item.done
    db.mark_easy_apply_opened(conn, j.id)
    assert db.get_easy_apply(conn, j.id).opened
    assert len(db.list_easy_apply(conn)) == 1
    app = db.mark_easy_apply_done(conn, j.id)
    assert app.state is S.SUBMITTED and app.mode is ApplicationMode.MANUAL and app.status is BoardStatus.APPLIED
    assert db.list_easy_apply(conn) == [] and len(db.list_easy_apply(conn, include_done=True)) == 1
    # manual applications don't count against the agent's daily cap
    assert db.submitted_today(conn) == 0
    assert db.count_submitted_since(conn, utcnow() - timedelta(hours=1), include_manual=True) == 1
    with pytest.raises(db.IllegalTransition):
        db.mark_manually_applied(conn, j.id)  # already submitted


def test_easy_apply_dismiss(conn):
    j, _ = job(conn, source="linkedin", easy_apply=True)
    db.upsert_easy_apply(conn, j.id, url="https://linkedin.com/jobs/view/2")
    db.dismiss_easy_apply(conn, j.id)
    assert db.list_easy_apply(conn) == []
    with pytest.raises(db.NotFound):
        db.get_easy_apply(conn, 999)


# ---- events / runs / aggregates -------------------------------------------------------------


def test_events_append_only(conn):
    eid = db.log_event(conn, "log", "hello", actor=Actor.SYSTEM, level="warning", payload={"a": 1})
    ev = db.list_events(conn, after_id=eid - 1)
    assert ev[0].message == "hello" and ev[0].payload == {"a": 1}
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("UPDATE events SET message = 'x' WHERE id = ?", (eid,))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("DELETE FROM events WHERE id = ?", (eid,))


def test_event_fk_nulling_still_allowed(conn):
    j, _ = job(conn)
    assert db.list_events(conn, job_id=j.id)
    conn.execute("DELETE FROM jobs WHERE id = ?", (j.id,))  # cascades; events keep rows with job_id NULL
    assert db.list_events(conn, job_id=j.id) == []
    assert conn.execute("SELECT COUNT(*) FROM events WHERE kind='discover'").fetchone()[0] == 1


def test_runs(conn):
    r = db.start_run(conn, "full", "scheduled")
    assert db.get_current_run(conn).run_uid == r.run_uid
    with pytest.raises(db.Conflict):
        db.start_run(conn, "discover")
    done = db.finish_run(conn, r.run_uid, outcome=RunOutcome.COMPLETED, stats={"discovered": 3, "submitted": 1}, tokens_in=5)
    assert done.finished_at and done.stats.discovered == 3 and done.tokens_in == 5
    assert db.get_current_run(conn) is None and db.get_last_run(conn).run_uid == r.run_uid
    info = db.run_info(done)
    assert info.run_id == r.run_uid and info.stats.submitted == 1
    db.start_run(conn, "prep")
    assert db.abandon_unfinished_runs(conn) == 1
    assert db.get_last_run(conn).outcome is RunOutcome.FAILED


def test_counts_and_caps(conn):
    j1, _ = job(conn, title="A")
    j2, _ = job(conn, company="Ramp", title="B")
    j3, _ = job(conn, company="Notion", title="C", source="linkedin", easy_apply=True)
    a1 = db.get_application_by_job(conn, j1.id)
    a2 = db.get_application_by_job(conn, j2.id)
    submit(conn, a1.id)
    for s in (S.SCORED, S.QUEUED, S.FILLING, S.AWAITING_REVIEW):
        db.transition(conn, a2.id, s)
    db.add_question(conn, canonical_question="Q?", job_id=j3.id)
    db.upsert_easy_apply(conn, j3.id, url="https://linkedin.com/jobs/view/3")
    c = db.compute_counts(conn)
    assert (c.submitted_today, c.awaiting_review, c.needs_you_clusters, c.needs_you_jobs, c.easy_apply_open,
            c.discovered_today, c.submitted_total) == (1, 1, 1, 1, 1, 3, 1)
    caps = db.compute_caps(conn)
    assert caps.daily_used == 1 and caps.daily_limit == 15 and caps.companies_cooling_down == 1
    assert caps.linkedin_sessions_limit == 3


def test_ghosting_and_nudges(conn):
    j, _ = job(conn)
    app = db.get_application_by_job(conn, j.id)
    submit(conn, app.id)
    now = utcnow()
    assert db.due_nudges(conn, [7, 14], now=now) == []
    due = db.due_nudges(conn, [7, 14], now=now + timedelta(days=8))
    assert [(a.id, d) for a, d in due] == [(app.id, 7)]
    db.record_nudge_sent(conn, app.id)
    assert db.due_nudges(conn, [7, 14], now=now + timedelta(days=8)) == []
    assert [d for _, d in db.due_nudges(conn, [7, 14], now=now + timedelta(days=15))] == [14]
    assert db.ghost_stale_applications(conn, 21, now=now + timedelta(days=10)) == []
    ghosted = db.ghost_stale_applications(conn, 21, now=now + timedelta(days=22))
    assert [g.application_id for g in ghosted] == [app.id] and ghosted[0].actor is Actor.SYSTEM
    assert db.get_application(conn, app.id).status is BoardStatus.GHOSTED
