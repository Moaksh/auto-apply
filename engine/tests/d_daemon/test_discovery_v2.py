"""Search planner (cursors, role interleaving, learning), parallel tabs, Google Jobs parsing,
and re-checking skipped jobs after a settings change."""

from __future__ import annotations

import sqlite3

import httpx
import pytest

from autoapply import db
from autoapply.discovery.base import DiscoveryContext
from autoapply.discovery.google_jobs import GoogleJobsSource, google_search_url, parse_google_jobs
from autoapply.discovery.linkedin import LinkedinSource
from autoapply.discovery.planner import SearchPlanner
from autoapply.enums import AppState, Ats
from autoapply.reconsider import reconsider

from .fakes import EventSink, FakeBrowser, fixture, instant_pacer

LI_ROUTES = [
    (r"linkedin\.com/jobs/search", lambda: fixture("linkedin_search.html")),
    (r"/jobs/view/4012345678", lambda: fixture("linkedin_job_4012345678.html")),
    (r"/jobs/view/4023456789", lambda: fixture("linkedin_job_4023456789.html")),
    (r"/jobs/view/4034567890", lambda: fixture("linkedin_job_4034567890.html")),
]

GOOGLE_HTML = """<html><head><title>AI engineer jobs - Google Search</title></head><body>
<div jscontroller="b11o3b">
  <div>AI Engineer</div><div>Acme</div><div>Bengaluru, Karnataka • via Acme Careers</div><span>2 days ago</span><span>Full-time</span>
  <template><div data-encoded-docid="D1" data-is-preview="true" data-title="AI Engineer">
    <a href="/goto?url=LI" title="Apply on LinkedIn"></a>
    <a href="/goto?url=ACME" title="Apply on Acme Careers"></a>
    <a href="/goto?url=BB" title="Apply on BeBee"></a>
    <h2>Job description</h2><div>Build LLM agents in Python.</div>
  </div></template>
</div>
<div jscontroller="b11o3b">
  <div>Data Scientist</div><div>Globex</div><div>Remote • via LinkedIn</div><span>5 hours ago</span>
  <template><div data-encoded-docid="D2" data-is-preview="true" data-title="Data Scientist">
    <a href="/goto?url=GLI" title="Apply on LinkedIn"></a><h2>Job description</h2><div>Models.</div>
  </div></template>
</div>
</body></html>"""


def ctx_for(conn: sqlite3.Connection, round_: int = 0) -> DiscoveryContext:
    return DiscoveryContext(preferences=db.get_preferences(conn), companies=[], http=httpx.AsyncClient(), round=round_)


# ---- planner ------------------------------------------------------------------------


def test_planner_interleaves_roles_and_advances_cursor(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["AI Engineer", "ML Engineer", "Data Scientist"], "locations": ["India", "Remote"]})
    prefs = db.get_preferences(conn)
    pl = SearchPlanner(conn, "linkedin", windows=3, max_pages=2)
    first = pl.plan(prefs, 3)
    assert [s.role for s in first] == ["AI Engineer", "ML Engineer", "Data Scientist"]  # one per role first
    s = first[0]
    assert (s.window, s.page) == (0, 0)
    pl.record(s, cards=25, new=0, complete=True)      # nothing new -> next page
    st = pl.summary()[s.key]
    assert (st["window"], st["page"]) == (0, 1)
    pl.record(SearchPlanner.__dict__ and type(s)(s.key, s.role, s.location, 0, 1), cards=25, new=3, complete=True)
    assert (pl.summary()[s.key]["window"], pl.summary()[s.key]["page"]) == (1, 0)  # last page -> wider window
    # never-run searches come before ones already read
    second = pl.plan(prefs, 3)
    assert all(x.key != s.key for x in second)


def test_planner_rests_exhausted_search_and_learns(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["AI Engineer"], "locations": []})
    prefs = db.get_preferences(conn)
    pl = SearchPlanner(conn, "google", windows=2, max_pages=1)
    s = pl.plan(prefs, 1)[0]
    pl.record(s, cards=0, new=0, complete=True)        # empty -> widen
    s2 = pl.plan(prefs, 1)[0]
    assert s2.window == 1
    pl.record(s2, cards=0, new=0, complete=True)       # widest window empty -> rest
    assert pl.plan(prefs, 1) == []
    assert pl.summary()[s.key]["rest_until"]
    pl.record_matches(s.key, 2)
    assert pl.summary()[s.key]["matched"] == 2


def test_budget_cutoff_keeps_the_same_page(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["AI Engineer"]})
    pl = SearchPlanner(conn, "linkedin", windows=3, max_pages=3)
    s = pl.plan(db.get_preferences(conn), 1)[0]
    pl.record(s, cards=25, new=5, complete=False)
    st = pl.summary()[s.key]
    assert (st["window"], st["page"]) == (0, 0)


# ---- browser sessions ---------------------------------------------------------------


async def test_parallel_tabs_and_second_run_reads_new_pages(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["Backend Engineer", "Platform Engineer"], "locations": ["India"],
                                 "sources_enabled": {"linkedin": True}, "searches_per_session": 2})
    browser = FakeBrowser(routes=LI_ROUTES)
    src = LinkedinSource(conn, emit=EventSink(), browser_factory=browser.factory(), pacer=instant_pacer())
    jobs = await src.discover(ctx_for(conn))
    assert jobs and all(j.raw.get("search_key") for j in jobs)
    assert len(browser.pages) == 2                      # two searches -> two tabs
    searches = [u for u in browser.visited if "/jobs/search" in u]
    assert any("Backend" in u for u in searches) and any("Platform" in u for u in searches)
    # store them, then run again: the planner moves to the next result page instead of re-reading page 1
    from autoapply.pipeline import Pipeline  # noqa: F401 - persistence path used by the daemon
    for j in jobs:
        company = db.upsert_company(conn, j.company_name)
        db.insert_job(conn, company_id=company.id, source=j.source, title=j.title, location=j.location,
                      apply_url=j.apply_url, source_url=j.source_url, ats=j.ats, external_id=j.external_id)
    browser.visited.clear()
    await src.discover(ctx_for(conn))
    again = [u for u in browser.visited if "/jobs/search" in u]
    assert again and all("start=25" in u for u in again)


def test_parse_google_jobs_prefers_company_site() -> None:
    cards = parse_google_jobs(GOOGLE_HTML)
    assert [c.title for c in cards] == ["AI Engineer", "Data Scientist"]
    ai = cards[0]
    assert ai.company == "Acme" and ai.location == "Bengaluru, Karnataka" and ai.external_id == "g:D1"
    assert ai.extra["via"] == "Acme Careers" and ai.extra["posted"] == "2 days ago"
    assert ai.detail.apply_redirect.endswith("/goto?url=ACME")   # company site beats LinkedIn and aggregators
    assert "Build LLM agents" in ai.detail.description
    assert cards[1].detail.workplace == "remote"


async def test_google_session_resolves_apply_link_and_lists_board_jobs_for_manual(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["AI Engineer", "Data Scientist"], "locations": [], "searches_per_session": 1})
    browser = FakeBrowser(
        routes=[(r"google\.com/search", GOOGLE_HTML), (r"boards\.greenhouse\.io", "<html>apply</html>"),
                (r"linkedin\.com/jobs/view", "<html>li</html>")],
        redirects=[(r"goto\?url=ACME", "https://boards.greenhouse.io/acme/jobs/123"),
                   (r"goto\?url=GLI", "https://www.linkedin.com/jobs/view/999/")],
    )
    src = GoogleJobsSource(conn, emit=EventSink(), browser_factory=browser.factory(), pacer=instant_pacer())
    jobs = {j.title: j for j in await src.discover(ctx_for(conn))}
    assert "AI Engineer" in jobs
    ai = jobs["AI Engineer"]
    assert ai.apply_url == "https://boards.greenhouse.io/acme/jobs/123" and ai.ats is Ats.GREENHOUSE
    assert ai.board_token == "acme" and ai.posted_at is not None
    # a LinkedIn-only posting is not a form to fill: it goes to the manual (Easy Apply) list
    ds = jobs["Data Scientist"]
    assert ds.easy_apply and ds.apply_url is None and ds.source_url == "https://www.linkedin.com/jobs/view/999/"
    assert not any("BeBee" in u or "url=BB" in u for u in browser.visited)
    assert google_search_url(db.get_preferences(conn), "AI Engineer", "India").count("udm=8") == 1


# ---- reconsider ---------------------------------------------------------------------


def _skipped_job(conn: sqlite3.Connection, title: str, score: int | None, reason: str) -> int:
    co = db.upsert_company(conn, f"Co {title}")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title=title, apply_url=f"https://x.io/{title}")
    app = db.get_application_by_job(conn, job.id)
    db.upsert_score(conn, job.id, score=score, skip_reason=None if reason == "below_threshold" else reason)
    db.transition(conn, app.id, AppState.SKIPPED, reason=reason)
    return app.id


def test_threshold_lowered_reopens_only_jobs_that_now_pass(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["AI Engineer"], "match_threshold": 70})
    assert reconsider(conn) == (0, None)                 # first sighting: just remember
    a = _skipped_job(conn, "A", 65, "below_threshold")
    b = _skipped_job(conn, "B", 40, "below_threshold")
    c = _skipped_job(conn, "C", 66, "user_skipped")
    db.update_preferences(conn, {"match_threshold": 60})
    n, why = reconsider(conn)
    assert n == 1 and "threshold" in why
    states = {i: db.get_application(conn, i).state for i in (a, b, c)}
    assert states == {a: AppState.DISCOVERED, b: AppState.SKIPPED, c: AppState.SKIPPED}
    assert db.get_score(conn, db.get_application(conn, a).job_id).basis  # stamped so scoring reuses it


def test_preference_change_reopens_filter_skips_not_user_skips(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["AI Engineer"]})
    reconsider(conn)
    a = _skipped_job(conn, "A", None, "seniority_mismatch:staff")
    b = _skipped_job(conn, "B", None, "no_apply_url")
    c = _skipped_job(conn, "C", None, "user_not_interested")
    db.update_preferences(conn, {"seniority": ["staff"]})
    n, _ = reconsider(conn)
    assert n == 1
    assert db.get_application(conn, a).state is AppState.DISCOVERED
    assert db.get_application(conn, b).state is AppState.SKIPPED and db.get_application(conn, c).state is AppState.SKIPPED
    assert reconsider(conn) == (0, None)                 # nothing changed since


@pytest.mark.parametrize("source", ["google"])
def test_google_is_a_valid_job_source(conn: sqlite3.Connection, source: str) -> None:
    co = db.upsert_company(conn, "Initech")
    job, created = db.insert_job(conn, company_id=co.id, source=source, title="AI Engineer")
    assert created and job.source.value == "google"
