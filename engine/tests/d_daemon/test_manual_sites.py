"""Sites that keep stopping the agent with a task for the user go to the Easy Apply list."""

from __future__ import annotations

import sqlite3

from autoapply import db, manual_sites
from autoapply.discovery.base import DiscoveredJob
from autoapply.enums import Ats, JobSource, RunKind
from autoapply.paths import Paths

from .fakes import gh_job
from .test_pipeline import make_pipeline, states


def wd_job(company: str, title: str, n: int) -> DiscoveredJob:
    return DiscoveredJob(source=JobSource.CAREERS, company_name=company, title=title, ats=Ats.WORKDAY,
                         apply_url=f"https://{company.lower()}.wd5.myworkdayjobs.com/careers/job/{n}",
                         location="Remote", description="Python and Go")


def test_site_of_groups_shared_boards_by_company() -> None:
    assert manual_sites.site_of("https://www.Acme.com/careers/1") == "acme.com"
    assert manual_sites.site_of("https://acme.wd5.myworkdayjobs.com/x/job/1") == "acme.wd5.myworkdayjobs.com"
    assert manual_sites.site_of("https://boards.greenhouse.io/Stripe/jobs/1") == "boards.greenhouse.io/stripe"
    assert manual_sites.site_of("https://boards.greenhouse.io/stripe/jobs/1") != manual_sites.site_of("https://boards.greenhouse.io/plaid/jobs/2")
    assert manual_sites.site_of(None) is None and manual_sites.site_of("not a url") is None


async def test_one_sign_in_wall_stays_a_task(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    p, _sink, adapter, calls = make_pipeline(conn, autoapply_home, [wd_job("Acme", "Backend", 1)])
    adapter.action_titles = {"Backend"}
    await p.run(RunKind.FULL)
    assert states(conn) == {"Backend": "needs_you"}
    assert manual_sites.sites(conn) == {} and db.list_easy_apply(conn) == []


async def test_a_site_that_keeps_asking_moves_its_jobs_to_easy_apply(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    jobs = [wd_job("Acme", "Backend", 1), wd_job("Acme", "Platform", 2), wd_job("Other", "Infra", 3)]
    p, _sink, adapter, calls = make_pipeline(conn, autoapply_home, jobs)
    adapter.action_titles = {"Backend", "Platform", "Infra"}
    await p.run(RunKind.FULL)
    # Both Acme jobs (the one waiting in Needs You too) move; the other site's single block stays a task.
    assert states(conn) == {"Backend": "skipped", "Platform": "skipped", "Infra": "needs_you"}
    assert set(manual_sites.sites(conn)) == {"acme.wd5.myworkdayjobs.com"}
    assert manual_sites.sites(conn)["acme.wd5.myworkdayjobs.com"]["action"] == "account"
    items = db.list_easy_apply(conn)
    assert sorted(i.url for i in items) == [jobs[0].apply_url, jobs[1].apply_url]  # the company's own apply link
    assert len(calls["easy_apply"]) == 2  # answers drafted for both
    open_jobs = {j for c in db.list_open_clusters(conn) for j in c.job_ids}
    acme_ids = {i.job_id for i in items}
    assert not open_jobs & acme_ids  # their tasks left the inbox
    reasons = {r["state_reason"] for r in conn.execute("SELECT state_reason FROM applications WHERE state = 'skipped'")}
    assert reasons == {manual_sites.SKIP_REASON}


async def test_new_jobs_on_a_manual_site_skip_the_agent(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    manual_sites.mark(conn, "acme.wd5.myworkdayjobs.com", "captcha")
    p, _sink, adapter, calls = make_pipeline(conn, autoapply_home, [wd_job("Acme", "Data", 4), wd_job("Fine", "Web", 5)])
    await p.run(RunKind.FULL)
    assert states(conn) == {"Data": "skipped", "Web": "awaiting_review"}  # Workday waits for review by default
    assert [i.url for i in db.list_easy_apply(conn)] == ["https://acme.wd5.myworkdayjobs.com/careers/job/4"]
    assert len(adapter.filled) == 1  # only the other site's job reached the agent


async def test_form_questions_still_go_to_needs_you(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    manual_sites.mark(conn, "boards.greenhouse.io/stripe", "account")
    # Already applying when the site went manual, but the block is a form question: it stays in the inbox.
    p, _sink, adapter, _calls = make_pipeline(conn, autoapply_home, [gh_job("Plaid", "API", 6)])
    adapter.unresolved_titles = {"API"}
    await p.run(RunKind.FULL)
    assert states(conn) == {"API": "needs_you"}


async def test_sites_already_waiting_in_the_inbox_are_swept(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    # Two jobs blocked on one site before this feature existed: the next pass moves both.
    p, _sink, adapter, _calls = make_pipeline(conn, autoapply_home, [wd_job("Acme", "Backend", 1), wd_job("Acme", "Platform", 2)])
    adapter.action_titles = {"Backend", "Platform"}
    real = manual_sites.REPEAT
    manual_sites.REPEAT = 99  # the old behaviour: everything parks
    try:
        await p.run(RunKind.FULL)
    finally:
        manual_sites.REPEAT = real
    assert states(conn) == {"Backend": "needs_you", "Platform": "needs_you"}
    assert await p.sweep_blocked_sites() == 2
    assert states(conn) == {"Backend": "skipped", "Platform": "skipped"}
    assert len(db.list_easy_apply(conn)) == 2 and db.list_open_clusters(conn) == []
