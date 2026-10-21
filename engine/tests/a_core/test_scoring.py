"""Scoring: every hard filter with its explicit skip reason, batched LLM scoring, score_pending."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import pytest

from autoapply import db
from autoapply.config import Preferences
from autoapply.enums import AppState, Ats, JobSource, RemotePolicy, Seniority
from autoapply.llm.provider import FakeLLMProvider, LLMError
from autoapply.models import format_ts, utcnow
from autoapply.scoring import (
    SCORE_SCHEMA,
    hard_filter,
    infer_countries,
    infer_seniority,
    jd_refuses_sponsorship,
    location_matches,
    score_jobs,
    score_pending,
)

from .conftest import EventSink


def mk(conn, title="Backend Engineer", company="Acme Robotics", **kw: Any):  # type: ignore[no-untyped-def]
    c = db.upsert_company(conn, company)
    kw.setdefault("location", "Remote - US")
    job, _ = db.insert_job(conn, company_id=c.id, source=JobSource.GREENHOUSE, title=title, ats=Ats.GREENHOUSE, **kw)
    return job, db.get_company(conn, c.id)


def hf(conn, prefs: Preferences, **kw: Any) -> str | None:  # type: ignore[no-untyped-def]
    job, company = mk(conn, **kw)
    return hard_filter(conn, job, company, prefs)


# =====================================================================================
# helpers
# =====================================================================================


def test_infer_countries() -> None:
    assert infer_countries("San Francisco, CA")[0] == {"US"}
    assert infer_countries("Remote - US")[0] == {"US"}
    assert infer_countries("Bengaluru, Karnataka")[0] == {"IN"}
    assert infer_countries("Remote (EMEA)")[0] >= {"DE", "GB", "IE"}
    assert infer_countries("Remote - Anywhere") == (set(), True)
    assert infer_countries("Austin, TX")[0] == {"US"}


def test_location_matches() -> None:
    assert location_matches("Bengaluru, India", "Bangalore")
    assert location_matches("Bengaluru, Karnataka", "India")
    assert location_matches("New York, NY", "NYC")
    assert not location_matches("New York, NY", "San Francisco")
    assert not location_matches("Bengaluru", "Mumbai")


@pytest.mark.parametrize(
    ("title", "level"),
    [
        ("Senior Backend Engineer", "senior"), ("Sr. Software Engineer", "senior"), ("Staff Engineer", "staff"),
        ("Principal Engineer", "principal"), ("Junior Developer", "junior"), ("Software Engineer Intern", "intern"),
        ("Director of Engineering", "executive"), ("Backend Engineer", None), ("Software Engineer II", "mid"),
    ],
)
def test_infer_seniority(title: str, level: str | None) -> None:
    assert infer_seniority(title) == level


def test_jd_refuses_sponsorship() -> None:
    assert jd_refuses_sponsorship("We are unable to sponsor visas for this role.")
    assert jd_refuses_sponsorship("Candidates must be able to work without sponsorship.")
    assert jd_refuses_sponsorship("Visa sponsorship is not available.")
    assert not jd_refuses_sponsorship("We offer visa sponsorship and relocation.")
    # Refusing something else next to an OFFER of sponsorship is not a refusal.
    assert not jd_refuses_sponsorship("We do not offer relocation. Visa sponsorship is available for this role.")
    assert not jd_refuses_sponsorship("We can sponsor visas. We do not provide equipment stipends.")
    assert not jd_refuses_sponsorship(
        "This role is eligible for visa sponsorship; we don't support remote work outside the US.")
    assert jd_refuses_sponsorship("We do not offer visa sponsorship.")
    assert jd_refuses_sponsorship("We cannot provide H-1B sponsorship at this time.")
    assert jd_refuses_sponsorship("No visa sponsorship available.")
    assert jd_refuses_sponsorship("The company does not currently offer employment visa sponsorship.")
    assert jd_refuses_sponsorship("We will not sponsor applicants for work visas.")


# =====================================================================================
# hard filters — one test per skip reason
# =====================================================================================


def test_passes_when_nothing_matches(conn) -> None:  # type: ignore[no-untyped-def]
    assert hf(conn, Preferences()) is None


def test_excluded_company(conn) -> None:  # type: ignore[no-untyped-def]
    assert hf(conn, Preferences(exclude_companies=["acme robotics"])) == "excluded_company"
    assert hf(conn, Preferences(exclude_companies=["Initech"]), company="Initech Inc") == "excluded_company"


def test_excluded_keyword(conn) -> None:  # type: ignore[no-untyped-def]
    p = Preferences(exclude_keywords=["Crypto", "on-call"])
    assert hf(conn, p, description="Trade crypto all day") == "excluded_keyword:crypto"
    assert hf(conn, p, title="SRE", description="24/7 on-call rotation") == "excluded_keyword:on-call"
    assert hf(conn, p, title="Data Engineer", description="cryptography libraries") is None  # word boundary


def test_excluded_industry_synonyms(conn) -> None:  # type: ignore[no-untyped-def]
    p = Preferences(exclude_industries=["crypto", "gambling"])
    assert hf(conn, p, description="Build our Web3 wallet") == "excluded_industry:crypto"
    assert hf(conn, p, title="Engineer", company="BetCo", description="the best online sportsbook") == "excluded_industry:gambling"


def test_seniority_mismatch(conn) -> None:  # type: ignore[no-untyped-def]
    p = Preferences(seniority=[Seniority.SENIOR, Seniority.STAFF])
    assert hf(conn, p, title="Junior Backend Engineer") == "seniority_mismatch:junior"
    assert hf(conn, p, title="Backend Engineering Intern") == "seniority_mismatch:intern"
    assert hf(conn, p, title="VP of Engineering") == "seniority_mismatch:executive"
    assert hf(conn, p, title="Senior Backend Engineer") is None
    assert hf(conn, p, title="Backend Engineer") is None  # no signal -> keep
    assert hf(conn, Preferences(), title="Junior Backend Engineer") is None  # no preference -> keep


def test_remote_policy(conn) -> None:  # type: ignore[no-untyped-def]
    p = Preferences(remote_policy=[RemotePolicy.REMOTE])
    assert hf(conn, p, title="Engineer A", location="London", remote="onsite") == "remote_policy:onsite"
    assert hf(conn, p, title="Engineer B", location="Berlin (Hybrid)") == "remote_policy:hybrid"
    assert hf(conn, p, title="Engineer C", location="Remote") is None


def test_location_mismatch(conn) -> None:  # type: ignore[no-untyped-def]
    p = Preferences(locations=["Bangalore", "India"], remote_policy=[RemotePolicy.REMOTE, RemotePolicy.HYBRID, RemotePolicy.ONSITE])
    assert hf(conn, p, title="E1", location="New York, NY") == "location_mismatch"
    assert hf(conn, p, title="E2", location="Bengaluru, Karnataka") is None
    assert hf(conn, p, title="E3", location="Pune, India") is None  # country-level preference
    assert hf(conn, p, title="E4", location="Remote - US", remote="remote") == "location_mismatch"  # remote, wrong country
    assert hf(conn, p, title="E5", location="Remote - Anywhere", remote="remote") is None
    assert hf(conn, p, title="E6", location="Remote", remote="remote") is None  # unknown country -> keep
    # secondary locations (Ashby/Lever raw) count too
    assert hf(conn, p, title="E7", location="Singapore", raw={"secondary_locations": ["Bengaluru, India"]}) is None


def test_work_auth_no_sponsorship(conn) -> None:  # type: ignore[no-untyped-def]
    db.set_never_guess(conn, {"work_auth": {"US": "requires_sponsorship", "IN": "citizen"}})
    jd = "We are unable to provide visa sponsorship for this position."
    assert hf(conn, Preferences(), title="E1", location="Austin, TX", description=jd) == "work_auth:no_sponsorship"
    assert hf(conn, Preferences(), title="E2", location="Bengaluru, India", description=jd) is None  # citizen there
    assert hf(conn, Preferences(), title="E3", location="Austin, TX", description="Great benefits.") is None


def test_work_auth_unknown_status_is_not_skipped(conn) -> None:  # type: ignore[no-untyped-def]
    jd = "No visa sponsorship."
    assert hf(conn, Preferences(), location="Austin, TX", description=jd) is None  # never guess -> ask later


def test_salary_floor(conn) -> None:  # type: ignore[no-untyped-def]
    p = Preferences(salary_floor=150000, salary_currency="USD")
    assert hf(conn, p, title="E1", salary_min=100000, salary_max=140000, salary_currency="USD") == "salary_below_floor"
    assert hf(conn, p, title="E2", salary_min=120000, salary_max=160000, salary_currency="USD") is None
    assert hf(conn, p, title="E3", salary_min=60000, salary_max=80000, salary_currency="EUR") is None  # can't compare
    assert hf(conn, p, title="E4") is None
    assert hf(conn, Preferences(hide_without_salary=True), title="E5") == "missing_salary"


def test_company_cooldown(conn) -> None:  # type: ignore[no-untyped-def]
    job, company = mk(conn)
    conn.execute("UPDATE companies SET last_applied_at = ? WHERE id = ?", (format_ts(utcnow() - timedelta(days=5)), company.id))
    company = db.get_company(conn, company.id)
    assert hard_filter(conn, job, company, Preferences(per_company_cooldown_days=30)) == "company_cooldown"
    assert hard_filter(conn, job, company, Preferences(per_company_cooldown_days=3)) is None


def test_daily_cap_is_opt_in_deferral(conn) -> None:  # type: ignore[no-untyped-def]
    job, company = mk(conn)
    p = Preferences(daily_cap=0)
    assert hard_filter(conn, job, company, p) is None
    assert hard_filter(conn, job, company, p, check_daily_cap=True) == "daily_cap_reached"


# =====================================================================================
# LLM scoring
# =====================================================================================


def responder(scores: dict[str, int]):  # type: ignore[no-untyped-def]
    """Fake model: scores jobs by title, echoing every job_id in the prompt."""
    import json
    import re

    def respond(prompt: str, system: str | None, schema: dict | None) -> Any:
        assert schema == SCORE_SCHEMA
        jobs = json.loads(prompt[prompt.index("jobs:\n") + 6 :])
        out = []
        for j in jobs:
            s = next((v for k, v in scores.items() if re.search(k, j["title"], re.I)), 50)
            out.append({"job_id": j["job_id"], "score": s, "summary": f"fit {s}",
                        "factors": {"skills": s, "seniority": s, "role": s, "domain": s}, "concerns": []})
        return {"results": out}

    return respond


async def test_score_jobs_batches_and_threshold(conn, profile) -> None:  # type: ignore[no-untyped-def]
    pairs = [mk(conn, title=f"Backend Engineer {i}") for i in range(5)] + [mk(conn, title="Sales Lead")]
    llm = FakeLLMProvider(default=responder({"Backend": 88, "Sales": 20}))
    res = await score_jobs(llm, profile=profile, preferences=Preferences(match_threshold=70), jobs=pairs, batch_size=4)
    assert len(llm.calls) == 2  # 6 jobs / batch 4
    assert [r.score for r in res] == [88] * 5 + [20]
    assert [r.skip_reason for r in res] == [None] * 5 + ["below_threshold"]
    assert res[0].reasons["factors"]["skills"] == 88 and res[0].reasons["summary"] == "fit 88"
    assert sum(r.tokens_in for r in res) == llm.usage.input_tokens
    assert '"skills": ["Go"' in llm.calls[0].prompt


async def test_score_jobs_retries_missing_and_failed(conn, profile) -> None:  # type: ignore[no-untyped-def]
    a, b = mk(conn, title="Backend A"), mk(conn, title="Backend B")
    partial = {"results": [{"job_id": a[0].id, "score": 75, "summary": "ok",
                            "factors": {"skills": 75, "seniority": 75, "role": 75, "domain": 75}}]}
    llm = FakeLLMProvider([partial, LLMError("boom")])
    res = await score_jobs(llm, profile=profile, preferences=Preferences(), jobs=[a, b], batch_size=8)
    assert res[0].score == 75 and res[0].error is None
    assert res[1].score is None and "boom" in (res[1].error or "")
    assert len(llm.calls) == 2  # batch + single retry for the missing job


async def test_score_jobs_invalid_schema_output_is_error(conn, profile) -> None:  # type: ignore[no-untyped-def]
    a = mk(conn, title="Backend A")
    llm = FakeLLMProvider(default={"results": [{"job_id": a[0].id, "score": 140}]})
    res = await score_jobs(llm, profile=profile, preferences=Preferences(), jobs=[a])
    assert res[0].score is None and res[0].error


# =====================================================================================
# score_pending (state machine walk)
# =====================================================================================


async def test_score_pending_walks_state_machine(conn, profile) -> None:  # type: ignore[no-untyped-def]
    db.update_preferences(conn, {"exclude_keywords": ["crypto"], "match_threshold": 70})
    good, _ = mk(conn, title="Backend Engineer")
    weak, _ = mk(conn, title="Support Engineer")
    bad, _ = mk(conn, title="Crypto Engineer", description="crypto exchange")
    sink = EventSink()
    llm = FakeLLMProvider(default=responder({"Backend": 90, "Support": 40}))
    report = await score_pending(conn, llm, emit=sink)

    st = {j.id: db.get_application_by_job(conn, j.id) for j in (good, weak, bad)}
    assert st[good.id].state is AppState.QUEUED
    assert st[weak.id].state is AppState.SKIPPED and st[weak.id].state_reason == "below_threshold"
    assert st[bad.id].state is AppState.SKIPPED and st[bad.id].state_reason == "excluded_keyword:crypto"
    assert db.get_score(conn, bad.id).skip_reason == "excluded_keyword:crypto" and db.get_score(conn, bad.id).score is None
    assert db.get_score(conn, good.id).score == 90 and db.get_score(conn, good.id).tokens_in > 0
    assert len(llm.calls) == 1 and "Crypto" not in llm.calls[0].prompt  # hard-filtered jobs never reach the LLM
    scored = sink.of("job_scored")
    assert {p.job_id: p.queued for p in scored} == {good.id: True, weak.id: False, bad.id: False}
    assert set(report.queued) == {st[good.id].id} and len(report.skipped) == 2
    assert db.get_application(conn, st[good.id].id).tokens_in > 0
    # events: discovered->scored->queued recorded
    kinds = [e.payload.get("to") for e in db.list_events(conn, application_id=st[good.id].id, kinds=["state"])]
    assert kinds == ["scored", "queued"]


async def test_score_pending_llm_error_leaves_discovered(conn, profile) -> None:  # type: ignore[no-untyped-def]
    job, _ = mk(conn, title="Backend Engineer")
    report = await score_pending(conn, FakeLLMProvider(default=LLMError("cli not logged in")))
    app = db.get_application_by_job(conn, job.id)
    assert app.state is AppState.DISCOVERED and report.errors == [app.id]
    assert db.get_score(conn, job.id) is None


# =====================================================================================
# Requirement-level evidence + grounding guard
# =====================================================================================


def _req(requirement: str, status: str, evidence: str = "", *, dealbreaker: bool = False, jd_quote: str | None = None,
         confidence: str = "high") -> dict[str, Any]:
    r: dict[str, Any] = {"requirement": requirement, "dealbreaker": dealbreaker, "status": status,
                         "evidence": evidence, "confidence": confidence}
    if jd_quote is not None:
        r["jd_quote"] = jd_quote
    return r


def _one(job_id: int, reqs: list[dict[str, Any]]) -> dict[str, Any]:
    return {"results": [{"job_id": job_id, "score": 82, "summary": "s",
                         "factors": {"skills": 80, "seniority": 80, "role": 80, "domain": 80},
                         "requirements": reqs}]}


def test_is_grounded_normalises_and_needs_whole_words() -> None:
    from autoapply.scoring import _norm, is_grounded

    hay = [_norm("Built Kafka-based ingestion at Analytical Engines; 7 years in Go.")]
    assert is_grounded("built KAFKA based ingestion", hay)
    assert is_grounded("Built Kafka ... Analytical Engines", hay)  # elided quote: every fragment present
    assert not is_grounded("Built Kafka ... Google", hay)
    assert not is_grounded("Engine", [_norm("Engines")])  # whole words only
    assert not is_grounded("", hay) and not is_grounded("...", hay)


async def test_requirements_grounding_drops_hallucinated_evidence(conn, profile) -> None:  # type: ignore[no-untyped-def]
    job, company = mk(conn, title="Senior Backend Engineer",
                      description="You will build Go services. Must have 5+ years of backend experience. "
                                  "Candidates must be based in the US.")
    reqs = [
        _req("Go services", "met", "Go"),                                            # grounded (skills)
        _req("5+ years backend", "met", "7 years"),                                  # grounded (years_experience)
        _req("Kubernetes at scale", "met", "Ran Kubernetes clusters for 200 services at Google"),  # hallucinated
        _req("Kafka", "partial", "Led Kafka migration at Netflix"),                  # hallucinated
        _req("Postgres", "met", ""),                                                 # met without evidence
        _req("US based", "met", "Senior Backend Engineer at Analytical Engines", dealbreaker=True,
             jd_quote="Candidates must be based in the US."),                        # real JD quote
    ]
    reqs_extra = _req("Rust", "missing", dealbreaker=True, jd_quote="Rust experience is mandatory")  # not in JD
    llm = FakeLLMProvider(default=_one(job.id, reqs[:5] + [reqs_extra]))
    [res] = await score_jobs(llm, profile=profile, preferences=Preferences(), jobs=[(job, company)])

    got = {r["requirement"]: r for r in res.reasons["requirements"]}
    assert got["Go services"]["status"] == "met" and got["Go services"]["evidence"] == "Go"
    assert got["5+ years backend"]["evidence"] == "7 years"
    k8s = got["Kubernetes at scale"]
    assert k8s["evidence"] == "" and k8s["status"] == "partial" and k8s["confidence"] == "low"
    assert got["Kafka"]["evidence"] == "" and got["Kafka"]["status"] == "missing"
    assert got["Postgres"]["status"] == "partial"
    assert got["Rust"]["dealbreaker"] is False and "jd_quote" not in got["Rust"]
    assert res.reasons["grounding"] == {"evidence_dropped": 2, "dealbreakers_dropped": 1}
    # Old keys are still there, unchanged, so older readers keep working.
    assert res.reasons["summary"] == "s" and res.reasons["factors"]["skills"] == 80 and res.score == 82
    assert "requirements" in (llm.calls[0].system or "") and llm.calls[0].schema == SCORE_SCHEMA

    # A dealbreaker quoted verbatim from the JD survives (case/punctuation-insensitive).
    llm = FakeLLMProvider(default=_one(job.id, [reqs[5]]))
    [res] = await score_jobs(llm, profile=profile, preferences=Preferences(), jobs=[(job, company)])
    [us] = res.reasons["requirements"]
    assert us["dealbreaker"] is True and us["jd_quote"] == "Candidates must be based in the US."
    assert us["status"] == "met" and "grounding" not in res.reasons


async def test_requirements_absent_keeps_old_reasons_shape(conn, profile) -> None:  # type: ignore[no-untyped-def]
    job, company = mk(conn)
    llm = FakeLLMProvider(default={"results": [{"job_id": job.id, "score": 70, "summary": "ok",
                                                "factors": {"skills": 1, "seniority": 1, "role": 1, "domain": 1}}]})
    [res] = await score_jobs(llm, profile=profile, preferences=Preferences(), jobs=[(job, company)])
    assert res.reasons == {"summary": "ok", "factors": {"skills": 1, "seniority": 1, "role": 1, "domain": 1}, "concerns": []}


async def test_score_pending_grounds_against_stories(conn, profile) -> None:  # type: ignore[no-untyped-def]
    db.upsert_story(conn, title="Payments outage", action="Cut p99 latency of the ledger API from 900ms to 120ms")
    job, _ = mk(conn, title="Backend Engineer", description="Low-latency APIs.")
    reqs = [_req("Low-latency APIs", "met", "cut p99 latency of the ledger API"),
            _req("Scala", "met", "Wrote Scala at Twitter")]
    llm = FakeLLMProvider(default=_one(job.id, reqs))
    await score_pending(conn, llm)
    stored = db.get_score(conn, job.id).reasons
    got = {r["requirement"]: r for r in stored["requirements"]}
    assert got["Low-latency APIs"]["status"] == "met" and got["Low-latency APIs"]["evidence"]
    assert got["Scala"]["evidence"] == "" and got["Scala"]["status"] == "partial"
    assert stored["grounding"]["evidence_dropped"] == 1


def test_score_schema_requirements_contract() -> None:
    item = SCORE_SCHEMA["properties"]["results"]["items"]
    assert "requirements" not in item["required"]  # optional: older/fake responses stay valid
    req = item["properties"]["requirements"]["items"]
    assert set(req["required"]) == {"requirement", "dealbreaker", "status", "evidence", "confidence"}
    assert req["properties"]["status"]["enum"] == ["met", "partial", "missing"]
