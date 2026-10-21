"""Learning from outcomes (autoapply/insights.py): score calibration, skip blockers, upskill
hints, resume-variant performance, the 6-hour cache and the ``get_insights`` command.
Seeded SQLite DBs only; the model is a FakeLLMProvider."""

from __future__ import annotations

import sqlite3
from datetime import timedelta
from pathlib import Path
from typing import Any

import pytest

from autoapply import db, insights
from autoapply.enums import AppState, Ats
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import Insights, format_ts, make_command, utcnow

NOW = utcnow().replace(microsecond=0)

K8S_JD = ("We run Kubernetes and Terraform on AWS. You will build Go services, own CI/CD and on-call. "
          "Python is a plus.")
SPARK_JD = "Data platform team: Spark, Airflow and Snowflake pipelines in Python. React to incidents quickly."

_n = 0


def _job(conn: sqlite3.Connection, *, title: str, company: str = "Acme", description: str = "") -> int:
    global _n
    _n += 1
    co = db.upsert_company(conn, company)
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title=title, ats=Ats.GREENHOUSE,
                           location=f"Office {_n}", apply_url=f"https://boards.greenhouse.io/x/jobs/{_n}", description=description)
    return db.get_application_by_job(conn, job.id).id


def submitted(conn: sqlite3.Connection, *, score: int | None, days_ago: float, status: str | None = None,
              reply: str | None = None, title: str = "Backend Engineer", company: str = "Acme",
              description: str = "", variant: int | None = None) -> int:
    app_id = _job(conn, title=title, company=company, description=description)
    app = db.get_application(conn, app_id)
    if score is not None:
        db.upsert_score(conn, app.job_id, score=score, reasons={"summary": "", "factors": {}, "concerns": []})
    for s in (AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.SUBMITTING, AppState.SUBMITTED):
        db.transition(conn, app_id, s)
    with db.transaction(conn):
        conn.execute("UPDATE applications SET submitted_at = ?, resume_variant_id = ? WHERE id = ?",
                     (format_ts(NOW - timedelta(days=days_ago)), variant, app_id))
    if status:
        db.set_status(conn, app_id, status)
    if reply:
        db.insert_application_reply(
            conn, application_id=app_id, message_id=f"<m{app_id}@x>", from_email="talent@acme.com", from_name=None,
            subject="Your application", snippet="", received_at=NOW - timedelta(days=max(0.0, days_ago - 2)), label=reply,
            classified_by="rules", match_basis="domain", ambiguous=False, suggested_status=None)
    return app_id


def skipped(conn: sqlite3.Connection, *, reason: str, days_ago: float = 3, score: int | None = None,
            concerns: list[str] | None = None, title: str = "Platform Engineer", company: str = "Globex",
            description: str = "") -> int:
    app_id = _job(conn, title=title, company=company, description=description)
    app = db.get_application(conn, app_id)
    db.upsert_score(conn, app.job_id, score=score, reasons={"summary": "", "factors": {}, "concerns": concerns or []},
                    skip_reason=reason)
    db.transition(conn, app_id, AppState.SKIPPED, reason=reason)
    with db.transaction(conn):
        conn.execute("UPDATE applications SET state_updated_at = ? WHERE id = ?",
                     (format_ts(NOW - timedelta(days=days_ago)), app_id))
    return app_id


def band(ins: Insights, label: str) -> Any:
    return next(b for b in ins.calibration.bands if b.label == label)


# ---- 1. calibration -----------------------------------------------------------------------------


def test_calibration_flat_suggests_threshold_may_be_high(conn: sqlite3.Connection) -> None:
    # 10 in 70–79 and 10 in 80–89, both 50% replies (status, reply email, or rejection all count).
    for i in range(10):
        hit = i < 5
        submitted(conn, score=72 + (i % 5), days_ago=30,
                  status="interview" if hit and i % 2 == 0 else None, reply="rejection" if hit and i % 2 else None)
        submitted(conn, score=82 + (i % 5), days_ago=30, status="assessment" if hit else None)
    # In flight (recent, no reply): not counted. Unscored: counted separately.
    for _ in range(4):
        submitted(conn, score=85, days_ago=3)
    submitted(conn, score=None, days_ago=40)
    # An automatic acknowledgement is not a reply.
    submitted(conn, score=55, days_ago=20, reply="received_ack")

    ins = insights.compute_insights(conn, now=NOW)
    cal = ins.calibration
    assert (cal.resolved, cal.in_flight, cal.unscored) == (21, 4, 1)
    b7, b8 = band(ins, "70–79"), band(ins, "80–89")
    assert (b7.applications, b7.responses, b7.enough_data, b7.response_rate) == (10, 5, True, 0.5)
    assert (b8.applications, b8.responses, b8.interviews) == (10, 5, 5)
    assert band(ins, "<60").applications == 1 and band(ins, "<60").responses == 0
    assert band(ins, "<60").response_rate is None  # below the sample floor: no rate
    assert cal.verdict == "flat" and cal.match_threshold == 70
    assert "70–79" in cal.finding and "threshold (70) may be higher" in cal.finding


def test_calibration_separating(conn: sqlite3.Connection) -> None:
    for i in range(8):
        submitted(conn, score=65, days_ago=25, status="rejected" if i == 0 else None)  # 1/8
        submitted(conn, score=92, days_ago=25, status="interview" if i < 5 else "ghosted")  # 5/8
    cal = insights.compute_insights(conn, now=NOW).calibration
    assert cal.verdict == "separating"
    assert "90+" in cal.finding and "62%" in cal.finding and "12%" in cal.finding


def test_calibration_not_enough_data(conn: sqlite3.Connection) -> None:
    for _ in range(7):  # one short of the floor
        submitted(conn, score=75, days_ago=30, status="interview")
    for _ in range(8):
        submitted(conn, score=88, days_ago=30)
    for _ in range(10):
        submitted(conn, score=78, days_ago=2)  # all in flight
    cal = insights.compute_insights(conn, now=NOW).calibration
    assert cal.verdict == "insufficient" and cal.finding.startswith("Not enough data yet")
    assert cal.in_flight == 10 and cal.resolved == 15
    assert band_rate(cal, "70–79") is None and band_rate(cal, "80–89") == 0.0


def band_rate(cal: Any, label: str) -> float | None:
    return next(b for b in cal.bands if b.label == label).response_rate


def test_empty_db(conn: sqlite3.Connection) -> None:
    ins = insights.compute_insights(conn, now=NOW)
    assert ins.calibration.verdict == "insufficient" and ins.calibration.resolved == 0
    assert ins.skip_blockers.skipped == 0 and ins.skip_blockers.reasons == []
    assert ins.upskill.hints == [] and ins.variants.variants == []
    assert ins.variants.finding == "No applications sent with a resume yet."


# ---- 2. skip blockers ---------------------------------------------------------------------------


def test_skip_blockers_reasons_examples_and_window(conn: sqlite3.Connection) -> None:
    for i in range(4):
        skipped(conn, reason="below_threshold", score=55 + i, title=f"ML Engineer {i}", days_ago=i + 1,
                concerns=["No Kubernetes experience in production", "Requires 5+ years of people management"])
    skipped(conn, reason="below_threshold", score=60, title="Data Engineer",
            concerns=["Limited k8s exposure", "No fintech domain experience"])
    for _ in range(2):
        skipped(conn, reason="excluded_keyword:crypto", title="Web3 Engineer")
    skipped(conn, reason="location_mismatch", title="Onsite SRE")
    skipped(conn, reason="below_threshold", days_ago=45, title="Old job")  # outside the 30-day window

    sb = insights.compute_insights(conn, now=NOW).skip_blockers
    assert sb.window_days == 30 and sb.skipped == 8
    top = sb.reasons[0]
    assert (top.reason, top.count) == ("below_threshold", 5)
    assert top.label == "Match score below your threshold (70)"
    assert len(top.examples) == 3 and top.examples[0] == "ML Engineer 0 · Globex"  # newest first
    kw = next(r for r in sb.reasons if r.reason == "excluded_keyword:crypto")
    assert kw.count == 2 and kw.label == "Excluded keyword “crypto”"
    assert next(r for r in sb.reasons if r.reason == "location_mismatch").label == "Location doesn't match"
    # Requirement-level blockers from the scorer's concerns: k8s / Kubernetes group as one skill.
    reqs = {r.label: r for r in sb.requirements}
    assert reqs["Kubernetes"].count == 5 and reqs["Kubernetes"].kind == "skill"
    assert reqs["People management"].count == 4 and reqs["People management"].kind == "theme"
    assert "Domain experience" not in reqs  # only one job: below the floor
    assert sb.requirements[0].label == "Kubernetes"


def test_reason_labels() -> None:
    assert insights.reason_label("seniority_mismatch:staff", 70) == "Seniority doesn't match (staff)"
    assert insights.reason_label("role_off_field:electrical", 70) == "Different field (electrical)"
    assert insights.reason_label("user_said_no", 70) == "User said no"


# ---- 3. upskill ---------------------------------------------------------------------------------


def test_upskill_hints_exclude_profile_skills(conn: sqlite3.Connection) -> None:
    db.update_profile(conn, {"skills": ["Python", "AWS", "k8s"], "headline": "Backend engineer",
                             "work_history": [{"company": "Initech", "title": "Engineer", "highlights": ["Built CI/CD on GitHub"]}]})
    for i in range(3):
        skipped(conn, reason="below_threshold", score=50 + i, description=K8S_JD, title=f"Platform {i}")
    submitted(conn, score=80, days_ago=20, status="rejected", description=K8S_JD, title="SRE")
    submitted(conn, score=80, days_ago=20, reply="rejection", description=SPARK_JD, title="Data Eng")
    submitted(conn, score=80, days_ago=20, status="interview", description=SPARK_JD)  # not rejected: ignored
    skipped(conn, reason="location_mismatch", description=SPARK_JD)  # hard filter (no score): ignored
    skipped(conn, reason="below_threshold", score=40, description=SPARK_JD, days_ago=120)  # outside 90 days

    up = insights.compute_insights(conn, now=NOW).upskill
    assert up.jobs_considered == 5 and up.min_jobs == 3
    by = {h.skill: h for h in up.hints}
    assert set(by) == {"Terraform", "Go"}  # Spark etc. appear in < 3 jobs
    assert (by["Terraform"].jobs, by["Terraform"].skipped, by["Terraform"].rejected) == (4, 3, 1)
    # Never suggest what the profile already has (k8s == Kubernetes, CI/CD from a highlight).
    for known in ("Python", "AWS", "Kubernetes", "CI/CD"):
        assert known not in by
    assert "React" not in insights.extract_skills(SPARK_JD)  # "React to incidents" is not React
    assert "only once you actually have it" in up.note and up.summary is None


def test_extract_skills_vocabulary() -> None:
    got = insights.extract_skills("Go, Rust/C++ and C#; Postgres, NoSQL; React Native; ReactJS; let's go to market")
    assert got == {"Go", "Rust", "C++", "C#", "PostgreSQL", "React Native", "React"}
    assert insights.extract_skills("JavaScript only") == {"JavaScript"}


async def test_summary_is_advisory_and_records_tokens(conn: sqlite3.Connection) -> None:
    for i in range(3):
        skipped(conn, reason="below_threshold", score=50, description=K8S_JD, title=f"P{i}")
    ins = insights.compute_insights(conn, now=NOW)
    llm = FakeLLMProvider(default={"summary": "Terraform keeps coming up; a small project could help."})
    out = await insights.summarize_upskill(ins, llm)
    assert out.upskill.summary and out.tokens_in > 0 and out.tokens_out > 0
    assert llm.tiers == ["fast"] and "Never suggest adding a skill" in (llm.calls[0].system or "")
    assert llm.calls[0].schema == insights.SUMMARY_SCHEMA
    broken = await insights.summarize_upskill(ins, FakeLLMProvider(default=RuntimeError("down")))
    assert broken.upskill.summary is None and broken.tokens_in == 0


# ---- 4. variants --------------------------------------------------------------------------------


def test_variant_performance(conn: sqlite3.Connection) -> None:
    a = db.add_resume_variant(conn, label="Backend", file_path="/r/a.pdf", tags=[], text="", is_default=True).id
    b = db.add_resume_variant(conn, label="ML", file_path="/r/b.pdf", tags=[], text="").id
    for i in range(10):
        submitted(conn, score=80, days_ago=20, variant=a, status="interview" if i < 4 else None)
        submitted(conn, score=80, days_ago=20, variant=b, reply="other" if i < 1 else None)
    c = db.add_resume_variant(conn, label="Short", file_path="/r/c.pdf", tags=[], text="").id
    submitted(conn, score=80, days_ago=20, variant=c)
    v = insights.compute_insights(conn, now=NOW).variants
    rows = {x.label: x for x in v.variants}
    assert (rows["Backend"].applications, rows["Backend"].responses, rows["Backend"].interviews) == (10, 4, 4)
    assert rows["ML"].responses == 1 and rows["Short"].low_sample and not rows["ML"].low_sample
    assert v.finding.startswith("“Backend” heard back 40% of the time vs 10% for “ML”")


# ---- cache + daemon command ---------------------------------------------------------------------


def test_cache_six_hours_and_force(conn: sqlite3.Connection) -> None:
    first = insights.get_insights(conn, now=NOW)
    assert not first.cached and first.skip_blockers.skipped == 0
    skipped(conn, reason="below_threshold", score=50)
    hit = insights.get_insights(conn, now=NOW + timedelta(hours=5))
    assert hit.cached and hit.skip_blockers.skipped == 0 and hit.computed_at == first.computed_at
    forced = insights.get_insights(conn, now=NOW + timedelta(hours=5), force=True)
    assert not forced.cached and forced.skip_blockers.skipped == 1
    stale = insights.get_insights(conn, now=NOW + timedelta(hours=11, minutes=1))
    assert not stale.cached and stale.computed_at == NOW + timedelta(hours=11, minutes=1)
    db.set_meta(conn, insights.META_INSIGHTS_CACHE, {"garbage": True})  # unreadable cache: recompute
    assert not insights.get_insights(conn, now=NOW).cached


async def test_get_insights_command(autoapply_home: Any, conn: sqlite3.Connection) -> None:
    from tests.d_daemon.test_daemon import build_daemon

    llm = FakeLLMProvider(default={"summary": "Terraform shows up often."})
    d = build_daemon(autoapply_home, Path("/tmp/unused.sock"), conn=conn, llm=llm)
    try:
        for i in range(3):
            skipped(d.conn, reason="below_threshold", score=50, description=K8S_JD, title=f"P{i}")
        (reply,) = await d.handle(make_command("get_insights", {}))
        assert reply.type == "ack"
        res = Insights.model_validate(reply.payload["result"])
        assert not res.cached and res.skip_blockers.skipped == 3 and res.upskill.summary is None and not llm.calls
        (reply,) = await d.handle(make_command("get_insights", {"summarize": True}))
        res = Insights.model_validate(reply.payload["result"])
        assert res.cached and res.upskill.summary == "Terraform shows up often." and res.tokens_in > 0
        (reply,) = await d.handle(make_command("get_insights", {"summarize": True}))  # summary cached too
        assert Insights.model_validate(reply.payload["result"]).upskill.summary and len(llm.calls) == 1
        (reply,) = await d.handle(make_command("get_insights", {"force": True}))
        res = Insights.model_validate(reply.payload["result"])
        assert not res.cached and res.upskill.summary is None
        with pytest.raises(ValueError):
            make_command("get_insights", {"bogus": 1})  # strict payload
    finally:
        await d.stop()


@pytest.mark.parametrize("hours", [0, 5.9])
def test_cached_insights_window(conn: sqlite3.Connection, hours: float) -> None:
    insights.store_insights(conn, insights.compute_insights(conn, now=NOW))
    assert insights.cached_insights(conn, now=NOW + timedelta(hours=hours)) is not None
    assert insights.cached_insights(conn, now=NOW + timedelta(hours=6)) is None
    assert insights.cached_insights(conn, now=NOW - timedelta(minutes=1)) is None  # clock went back
