"""Pipeline: discover -> score -> prep -> apply with fakes for workstreams A/B."""

from __future__ import annotations

import sqlite3
from datetime import timedelta

import pytest

from autoapply import db
from autoapply.discovery.base import DiscoveredJob
from autoapply.enums import AppState, Ats, BoardStatus, CapKind, JobSource, Mode, RunKind, RunOutcome
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import utcnow
from autoapply.paths import Paths
from autoapply.pipeline import Pipeline, basic_hard_filter

from .fakes import EventSink, FakeAdapter, FakeSource, fake_hooks, gh_job


def make_pipeline(conn: sqlite3.Connection, paths: Paths, jobs: list[DiscoveredJob], *, adapter: FakeAdapter | None = None,
                  paused: list[bool] | None = None, **hook_kw: object) -> tuple[Pipeline, EventSink, FakeAdapter, dict]:
    sink = EventSink()
    adapter = adapter or FakeAdapter(conn)
    hooks, calls = fake_hooks(**hook_kw)  # type: ignore[arg-type]
    flag = paused if paused is not None else [False]
    p = Pipeline(conn, paths=paths, llm=FakeLLMProvider(default="ok"), sources=[FakeSource(jobs)], adapters=[adapter],
                 emit=sink, hooks=hooks, is_paused=lambda: flag[0])
    return p, sink, adapter, calls


def states(conn: sqlite3.Connection) -> dict[str, str]:
    out = {}
    for row in conn.execute("SELECT j.title, a.state FROM jobs j JOIN applications a ON a.job_id = j.id"):
        out[row["title"]] = row["state"]
    return out


async def test_full_run_submits_and_emits(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("Stripe", "Backend Engineer", 1), gh_job("Notion", "Platform Engineer", 2), gh_job("Figma", "Low Fit", 3)]
    p, sink, adapter, calls = make_pipeline(conn, autoapply_home, jobs, scores={"Low Fit": 40})
    info = await p.run(RunKind.FULL)

    assert info.outcome is RunOutcome.COMPLETED
    assert states(conn) == {"Backend Engineer": "submitted", "Platform Engineer": "submitted", "Low Fit": "skipped"}
    assert info.stats.discovered == 3 and info.stats.scored == 3 and info.stats.submitted == 2 and info.stats.skipped == 1
    # durable pre-write: the adapter only ever saw 'submitting' when clicking
    assert adapter.state_at_submit == [AppState.SUBMITTING, AppState.SUBMITTING]
    types = sink.types()
    assert types[0] == "run_started" and "run_finished" in types
    assert len(sink.of("job_discovered")) == 3 and len(sink.of("job_scored")) == 3
    tos = [e.to_state for e in sink.of("application_state")]
    assert tos.count(AppState.SUBMITTED) == 2 and AppState.SUBMITTING in tos
    app = db.get_application_by_job(conn, db.list_jobs(conn, states=["submitted"])[0].id)
    assert app.status is BoardStatus.APPLIED and app.mode == "auto" and app.screenshot_path
    assert calls["run_prep"] == [None]
    # run row finished with stats + tokens
    run = db.get_run(conn, info.run_id)
    assert run.finished_at is not None and run.stats.submitted == 2


async def test_dedupe_second_run_discovers_nothing(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("Stripe", "Backend Engineer", 1)]
    p, sink, _a, _c = make_pipeline(conn, autoapply_home, jobs)
    await p.run(RunKind.DISCOVER)
    info = await p.run(RunKind.DISCOVER)
    assert info.stats.discovered == 0
    assert len(db.list_jobs(conn)) == 1


async def test_daily_cap_stops_before_submit(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    db.update_preferences(conn, {"daily_cap": 2})
    jobs = [gh_job(f"Co{i}", f"Role {i}", i) for i in range(4)]
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs)
    info = await p.run(RunKind.FULL)
    assert info.outcome is RunOutcome.CAP_REACHED
    assert db.submitted_today(conn) == 2
    assert sorted(states(conn).values()) == ["queued", "queued", "submitted", "submitted"]
    caps = sink.of("cap_reached")
    assert caps and caps[-1].cap is CapKind.DAILY and caps[-1].used == 2 and caps[-1].limit == 2
    assert len(adapter.submitted) == 2


async def test_manual_easy_apply_does_not_count_toward_cap(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    db.update_preferences(conn, {"daily_cap": 1})
    co = db.upsert_company(conn, "LinkedCo")
    job, _ = db.insert_job(conn, company_id=co.id, source="linkedin", title="EA", source_url="https://www.linkedin.com/jobs/view/1/", easy_apply=True, ats=Ats.LINKEDIN_EASY_APPLY)
    db.upsert_easy_apply(conn, job.id, url="https://www.linkedin.com/jobs/view/1/")
    db.mark_easy_apply_done(conn, job.id)
    p, _sink, adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)])
    info = await p.run(RunKind.FULL)
    assert info.stats.submitted == 1 and adapter.submitted


async def test_company_cooldown_skips(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("Stripe", "Backend Engineer", 1), gh_job("Stripe", "Infra Engineer", 2)]
    # First run applies to one Stripe job; the second job of the same company must not be submitted.
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs)
    await p.run(RunKind.FULL)
    st = states(conn)
    assert sorted(st.values()) == ["skipped", "submitted"]
    assert len(adapter.submitted) == 1
    skipped_app = db.list_applications(conn, states=["skipped"])[0]
    assert skipped_app.state_reason == "company_cooldown"
    cd = [c for c in sink.of("cap_reached") if c.cap is CapKind.COMPANY_COOLDOWN]
    assert cd and cd[0].limit == 30 and cd[0].company_id is not None


async def test_cooldown_rechecked_right_before_submit(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    """If the company enters cooldown while the form is being filled, nothing is submitted."""
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)])

    def applied_elsewhere_meanwhile() -> None:
        conn.execute("UPDATE companies SET last_applied_at = ? WHERE name = 'Stripe'", (db.format_ts(utcnow()),))

    adapter.pause_on_fill = applied_elsewhere_meanwhile
    info = await p.run(RunKind.FULL)
    assert adapter.submitted == []
    assert states(conn) == {"Backend Engineer": "queued"}
    assert info.outcome is RunOutcome.COMPLETED
    assert any(c.cap is CapKind.COMPANY_COOLDOWN for c in sink.of("cap_reached"))


async def test_pause_between_steps(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    paused = [False]
    jobs = [gh_job("Stripe", "Backend Engineer", 1)]
    p, sink, adapter, calls = make_pipeline(conn, autoapply_home, jobs, paused=paused)

    orig = p.score

    async def score_then_pause(**kw) -> None:
        await orig(**kw)
        paused[0] = True

    p.score = score_then_pause  # type: ignore[method-assign]
    info = await p.run(RunKind.FULL)
    assert info.outcome is RunOutcome.PAUSED
    assert calls["run_prep"] == [] and adapter.filled == []
    assert states(conn) == {"Backend Engineer": "queued"}


async def test_pause_mid_fill_requeues(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    paused = [False]
    adapter_box: list[FakeAdapter] = []
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)], paused=paused)
    adapter.pause_on_fill = lambda: paused.__setitem__(0, True)
    adapter_box.append(adapter)
    info = await p.run(RunKind.FULL)
    assert info.outcome is RunOutcome.PAUSED
    assert states(conn) == {"Backend Engineer": "queued"}
    assert adapter.submitted == []
    last = db.list_applications(conn)[0]
    assert last.state_reason == "paused"


async def test_review_mode_awaits_review(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    db.update_preferences(conn, {"mode": "review"})
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)])
    info = await p.run(RunKind.FULL)
    assert states(conn) == {"Backend Engineer": "awaiting_review"}
    assert adapter.submitted == [] and info.stats.awaiting_review == 1


async def test_per_ats_workday_review_default(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    wd = DiscoveredJob(source=JobSource.CAREERS, company_name="BigCorp", title="SWE", apply_url="https://bigcorp.wd5.myworkdayjobs.com/x/job/1", ats=Ats.WORKDAY)
    p, _sink, adapter, _ = make_pipeline(conn, autoapply_home, [wd])
    p.sources[0].name = JobSource.CAREERS  # type: ignore[attr-defined]
    await p.run(RunKind.FULL)
    assert states(conn) == {"SWE": "awaiting_review"}
    assert db.list_applications(conn)[0].mode == Mode.REVIEW.value


async def test_unresolved_fields_park_job(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    adapter = None
    p, sink, adapter, calls = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)])
    adapter.unresolved_titles = {"Backend Engineer"}
    info = await p.run(RunKind.FULL)
    assert states(conn) == {"Backend Engineer": "needs_you"}
    clusters = db.list_open_clusters(conn)
    assert len(clusters) == 2
    assert {c.canonical_question for c in clusters} == {"Why do you want to work here?", "Do you require visa sponsorship?"}
    opened = sink.of("question_opened")
    assert len(opened) == 2 and calls["cluster"]
    spons = next(c for c in clusters if c.never_guess_key)
    assert spons.never_guess_key == "sponsorship" and spons.reason.value == "never_guess"
    assert info.stats.needs_you == 1


async def test_fill_errors_fail(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("A", "Raises", 1), gh_job("B", "Fails", 2)]
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs)
    adapter.raise_titles = {"Raises"}
    adapter.fail_titles = {"Fails"}
    await p.run(RunKind.FULL)
    assert states(conn) == {"Raises": "failed", "Fails": "failed"}
    reasons = {a.state_reason for a in db.list_applications(conn)}
    assert "form closed" in reasons and any(r.startswith("adapter_error") for r in reasons)


async def test_unverified_or_crashing_submit_goes_unknown_verify(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("A", "Unverified", 1), gh_job("B", "Boom", 2)]
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs)
    adapter.unverified_titles = {"Unverified"}
    adapter.submit_raises_titles = {"Boom"}
    await p.run(RunKind.FULL)
    assert states(conn) == {"Unverified": "unknown_verify", "Boom": "unknown_verify"}
    # never retried automatically
    await p.run(RunKind.APPLY)
    assert len(adapter.submitted) == 2


async def test_crash_recovery_never_double_applies(autoapply_home: Paths) -> None:
    """Crash after begin_submit (before the click resolved): reopen -> unknown_verify, no retry."""
    conn = db.open_db(autoapply_home.db)
    p, _sink, adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)])
    await p.run(RunKind.DISCOVER)
    app = db.list_applications(conn, states=["queued"])[0]
    db.transition(conn, app.id, AppState.FILLING)
    db.begin_submit(conn, app.id)
    run = db.start_run(conn, RunKind.APPLY)
    conn.close()  # "crash"

    conn2 = db.open_db(autoapply_home.db)
    report = db.recover_after_crash(conn2)
    assert db.abandon_unfinished_runs(conn2) == 1
    assert [t.to_state for t in report.unknown_verify] == [AppState.UNKNOWN_VERIFY]
    p2, _s2, adapter2, _ = make_pipeline(conn2, autoapply_home, [])
    await p2.run(RunKind.APPLY)
    assert adapter2.submitted == [] and adapter2.filled == []
    assert db.get_application(conn2, app.id).state is AppState.UNKNOWN_VERIFY
    assert db.get_run(conn2, run.run_uid).outcome is RunOutcome.FAILED
    conn2.close()


async def test_hard_filter_and_no_apply_url(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    no_url = DiscoveredJob(source=JobSource.GREENHOUSE, company_name="X", title="No URL")
    jobs = [gh_job("A", "Intern", 1), no_url, gh_job("B", "Good", 2)]
    p, sink, _adapter, calls = make_pipeline(conn, autoapply_home, jobs, hard_skip={"Intern": "seniority:intern"})
    await p.run(RunKind.DISCOVER)
    assert states(conn) == {"Intern": "skipped", "No URL": "skipped", "Good": "queued"}
    reasons = {s.job_id: s.skip_reason for s in (db.get_score(conn, j.id) for j in db.list_jobs(conn)) if s}
    assert set(reasons.values()) == {"seniority:intern", "no_apply_url", None}
    scored = sink.of("job_scored")
    assert {e.queued for e in scored} == {True, False}


async def test_easy_apply_jobs_never_queued(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    ea = DiscoveredJob(source=JobSource.LINKEDIN, company_name="Razorpay", title="Backend SDE II", easy_apply=True,
                       ats=Ats.LINKEDIN_EASY_APPLY, source_url="https://www.linkedin.com/jobs/view/4023456789/")
    weak = DiscoveredJob(source=JobSource.LINKEDIN, company_name="Weak", title="Weak Fit", easy_apply=True,
                         ats=Ats.LINKEDIN_EASY_APPLY, source_url="https://www.linkedin.com/jobs/view/4000000001/")
    p, sink, adapter, calls = make_pipeline(conn, autoapply_home, [ea, weak], scores={"Weak Fit": 10})
    p.sources[0].name = JobSource.LINKEDIN  # type: ignore[attr-defined]
    db.update_preferences(conn, {"sources_enabled": {"linkedin": True}})
    await p.run(RunKind.FULL)
    assert states(conn) == {"Backend SDE II": "scored", "Weak Fit": "skipped"}
    items = db.list_easy_apply(conn)
    assert [i.url for i in items] == ["https://www.linkedin.com/jobs/view/4023456789/"]  # weak one dismissed
    assert adapter.filled == [] and len(calls["easy_apply"]) == 1


async def test_disabled_sources_are_not_called(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    p, _sink, _a, _c = make_pipeline(conn, autoapply_home, [gh_job("A", "B", 1)])
    db.update_preferences(conn, {"sources_enabled": {"greenhouse": False}})
    await p.run(RunKind.DISCOVER)
    assert p.sources[0].calls == 0  # type: ignore[attr-defined]


async def test_unimplemented_seams_degrade(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    """With A/B stubs still raising NotImplementedError the run completes without crashing."""
    from autoapply.pipeline import PipelineHooks

    def nie(*a: object, **k: object) -> None:
        raise NotImplementedError

    async def anie(*a: object, **k: object) -> None:
        raise NotImplementedError

    sink = EventSink()
    hooks = PipelineHooks(hard_filter=nie, score_jobs=anie, run_prep=anie, pick_resume=nie, refresh_easy_apply=anie, cluster_questions=nie)
    p = Pipeline(conn, paths=autoapply_home, llm=FakeLLMProvider(), sources=[FakeSource([gh_job("A", "B", 1)])], adapters=[],
                 emit=sink, hooks=hooks, is_paused=lambda: False)
    info = await p.run(RunKind.FULL)
    assert info.outcome is RunOutcome.COMPLETED
    assert states(conn) == {"B": "discovered"}  # waits for score_jobs
    assert any("not implemented" in log.message for log in sink.of("log"))


async def test_maintenance_ghosts_and_nudges(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    p, sink, _adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("A", "Old", 1), gh_job("B", "Mid", 2)])
    await p.run(RunKind.FULL)
    old = db.get_application_by_job(conn, db.list_jobs(conn, states=["submitted"])[-1].id)
    mid = [a for a in db.list_applications(conn, states=["submitted"]) if a.id != old.id][0]
    now = utcnow()
    conn.execute("UPDATE applications SET submitted_at = ?, status_updated_at = ? WHERE id = ?",
                 (db.format_ts(now - timedelta(days=22)), db.format_ts(now - timedelta(days=22)), old.id))
    conn.execute("UPDATE applications SET submitted_at = ?, status_updated_at = ? WHERE id = ?",
                 (db.format_ts(now - timedelta(days=8)), db.format_ts(now - timedelta(days=8)), mid.id))
    sink.events.clear()
    await p.maintenance()
    ghosted = sink.of("application_status")
    assert [g.application_id for g in ghosted] == [old.id] and ghosted[0].status is BoardStatus.GHOSTED
    nudges = sink.of("nudge_due")
    assert [(n.application_id, n.day) for n in nudges] == [(mid.id, 7)]
    sink.events.clear()
    await p.maintenance()
    assert sink.of("nudge_due") == []  # not re-sent


def test_basic_hard_filter(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"exclude_companies": ["Evil Corp"], "exclude_keywords": ["crypto"], "salary_floor": 100000})
    prefs = db.get_preferences(conn)
    co = db.upsert_company(conn, "Evil Corp")
    j, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="SWE", apply_url="https://x/1")
    assert basic_hard_filter(conn, j, co, prefs) == "excluded_company:Evil Corp"
    co2 = db.upsert_company(conn, "Good")
    j2, _ = db.insert_job(conn, company_id=co2.id, source="greenhouse", title="Crypto SWE", description="crypto stuff", apply_url="https://x/2")
    assert basic_hard_filter(conn, j2, co2, prefs) == "excluded_keyword:crypto"
    j3, _ = db.insert_job(conn, company_id=co2.id, source="greenhouse", title="SWE 3", salary_max=90000, salary_currency="USD", apply_url="https://x/3")
    assert basic_hard_filter(conn, j3, co2, prefs) == "below_salary_floor"
    j4, _ = db.insert_job(conn, company_id=co2.id, source="greenhouse", title="SWE 4", apply_url="https://x/4")
    assert basic_hard_filter(conn, j4, co2, prefs) is None


@pytest.mark.parametrize("kind,expected", [(RunKind.DISCOVER, "queued"), (RunKind.PREP, None), (RunKind.APPLY, None)])
async def test_run_kinds(conn: sqlite3.Connection, autoapply_home: Paths, kind: RunKind, expected: str | None) -> None:
    p, _sink, adapter, calls = make_pipeline(conn, autoapply_home, [gh_job("A", "B", 1)])
    await p.run(kind)
    assert states(conn).get("B") == expected
    assert bool(calls["run_prep"]) == (kind is RunKind.PREP)


def test_borderline_band_and_quota_constants() -> None:
    from autoapply.pipeline import BORDERLINE_BAND, MAX_EXTRA_ROUNDS, MIN_MATCHES_PER_RUN

    assert MIN_MATCHES_PER_RUN >= 1 and MAX_EXTRA_ROUNDS >= 1 and 0 < BORDERLINE_BAND < 50


async def test_quota_promotes_best_near_misses_into_review(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    """Nothing clears the bar (70): the best near-misses (>= 55) fill the quota of 3, forced to review mode."""
    jobs = [gh_job(f"Co{i}", f"Role {i}", i) for i in range(5)]
    scores = {"Role 0": 66, "Role 1": 64, "Role 2": 62, "Role 3": 58, "Role 4": 30}
    p, sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs, scores=scores)
    info = await p.run(RunKind.DISCOVER)
    st = states(conn)
    assert sorted(t for t, s in st.items() if s == "queued") == ["Role 0", "Role 1", "Role 2"]
    assert st["Role 3"] == "skipped" and st["Role 4"] == "skipped"
    for job in db.list_jobs(conn, states=["queued"]):
        assert job.mode_override == "review"  # near-misses never auto-submit
    assert info.stats.queued == 3


def test_profile_country_is_the_location_fallback() -> None:
    from autoapply.config import Preferences
    from autoapply.models import Job
    from autoapply.scoring import _location_reason

    prefs = Preferences(locations=[], remote_policy=[])
    def job(loc: str) -> Job:
        return Job.model_construct(title="ML Engineer", description="", location=loc, remote=None, raw={})
    assert _location_reason(job("Remote - US"), prefs, home="Bangalore") == "location_mismatch"
    assert _location_reason(job("San Francisco, CA, United States"), prefs, home="Bangalore") == "location_mismatch"
    assert _location_reason(job("Bengaluru, India"), prefs, home="Bangalore") is None
    assert _location_reason(job("Remote - India"), prefs, home="Bangalore") is None
    assert _location_reason(job("Remote, Global"), prefs, home="Bangalore") is None
    assert _location_reason(job("Remote - US"), prefs, home=None) is None  # no home known: unchanged behaviour


async def test_queued_job_is_rechecked_before_applying(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [gh_job("Stripe", "Backend Engineer", 1), gh_job("Notion", "Platform Engineer", 2)]
    rules: dict[str, str] = {"(none)": "x"}  # non-empty: fake_hooks replaces a falsy dict
    p, _sink, adapter, _ = make_pipeline(conn, autoapply_home, jobs, hard_skip=rules)
    await p.run(RunKind.DISCOVER)
    assert sorted(states(conn).values()) == ["queued", "queued"]
    rules["Backend Engineer"] = "location_mismatch"  # a filter fix / preference change after queueing
    await p.run(RunKind.APPLY)
    st = states(conn)
    assert st["Backend Engineer"] == "skipped" and st["Platform Engineer"] == "submitted"
    assert db.list_applications(conn, states=["skipped"])[0].state_reason == "location_mismatch"


async def test_apply_anyway_is_not_rechecked(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    rules = {"Backend Engineer": "location_mismatch"}
    p, _sink, _adapter, _ = make_pipeline(conn, autoapply_home, [gh_job("Stripe", "Backend Engineer", 1)], hard_skip=rules)
    await p.run(RunKind.DISCOVER)
    app = db.list_applications(conn, states=["skipped"])[0]
    db.transition(conn, app.id, AppState.QUEUED, reason="user_apply_anyway", actor="user")
    await p.run(RunKind.APPLY)
    assert states(conn) == {"Backend Engineer": "submitted"}
