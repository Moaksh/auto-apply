"""Search planner (cursors, role interleaving, learning), parallel tabs, Google Jobs parsing,
and re-checking skipped jobs after a settings change."""

from __future__ import annotations

import asyncio
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

from .fakes import EventSink, FakeBrowser, FakePage, fixture, instant_pacer

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
    # two searches -> two search tabs; job pages are read in tabs of their own, never the search tab
    search_tabs = [p for p in browser.pages if any("/jobs/search" in u for u in p.history)]
    assert len(search_tabs) == 2
    assert all(all("/jobs/search" in u for u in p.history) for p in search_tabs)
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


# ---- concurrency: several searches and several job-page visits in flight at once ------


class _SlowPage(FakePage):
    """A tab whose navigation takes a moment, counting how many tabs are mid-navigation."""

    async def goto(self, url: str) -> None:
        b = self.browser
        kind = "search" if "/search" in url else "visit"
        b.in_flight[kind] += 1
        b.peak[kind] = max(b.peak[kind], b.in_flight[kind])
        try:
            await asyncio.sleep(0.01)
            await super().goto(url)
        finally:
            b.in_flight[kind] -= 1


class _SlowBrowser(FakeBrowser):
    def __init__(self, **kw: object) -> None:
        super().__init__(**kw)  # type: ignore[arg-type]
        self.in_flight = {"search": 0, "visit": 0}
        self.peak = {"search": 0, "visit": 0}

    async def new_page(self) -> FakePage:
        p = _SlowPage(self)
        self.pages.append(p)
        return p


def _google_page(role: str, prefix: str, n: int) -> str:
    panes = "".join(
        f"""<div jscontroller="b11o3b"><div>{role}</div><div>{prefix} Co {i}</div><div>Bengaluru • via {prefix} Co {i} Careers</div>
        <span>1 day ago</span><template><div data-encoded-docid="{prefix}{i}" data-is-preview="true" data-title="{role}">
        <a href="/goto?url={prefix}{i}" title="Apply on {prefix} Co {i} Careers"></a><h2>Job description</h2><div>Python.</div>
        </div></template></div>"""
        for i in range(n)
    )
    return f"<html><head><title>{role} jobs - Google Search</title></head><body>{panes}</body></html>"


def _google_browser(*roles: tuple[str, str]) -> _SlowBrowser:
    routes: list = [(r"q=" + role.replace(" ", r"\+"), _google_page(role, prefix, 4)) for role, prefix in roles]
    return _SlowBrowser(routes=[*routes, (r"greenhouse", "<html>apply</html>")],
                        redirects=[(r"goto\?url=", "https://boards.greenhouse.io/co/jobs/1")])


async def test_google_runs_searches_and_apply_links_in_parallel_tabs(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["AI Engineer", "ML Engineer", "Data Scientist"], "locations": [],
                                 "searches_per_session": 3, "jobs_per_session": 30})
    browser = _google_browser(("AI Engineer", "A"), ("ML Engineer", "M"), ("Data Scientist", "D"))
    sink = EventSink()
    src = GoogleJobsSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer())
    jobs = await src.discover(ctx_for(conn))

    assert len(jobs) == 12 and all(j.apply_url for j in jobs)
    assert browser.peak["search"] == 3          # three roles searched at the same time
    assert browser.peak["visit"] >= 2           # apply links resolved side by side...
    assert browser.peak["visit"] <= GoogleJobsSource.detail_tabs  # ...by a bounded pool of tabs
    # search tabs only ever show result pages; apply links open in the job-page tabs
    search_tabs = [p for p in browser.pages if any("/search" in u for u in p.history)]
    assert len(search_tabs) == 3 and all(all("/search" in u for u in p.history) for p in search_tabs)
    # every search was recorded once, with its own new-listing count
    summary = SearchPlanner(conn, "google", windows=4, max_pages=1).summary()
    assert sorted((st["runs"], st["last_new"]) for st in summary.values()) == [(1, 4)] * 3
    # log lines name the tab doing the work
    logs = [p.message for p in sink.of("log")]
    opening = [m for m in logs if "opening apply link" in m]
    assert opening and all(m.startswith("Google Jobs [tab ") for m in opening)
    assert len({m.split("]")[0] for m in opening}) >= 2


async def test_parallel_visits_respect_the_shared_budget(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["AI Engineer", "ML Engineer"], "locations": [], "searches_per_session": 2,
                                 "jobs_per_session": 5})
    browser = _google_browser(("AI Engineer", "A"), ("ML Engineer", "M"))
    src = GoogleJobsSource(conn, emit=EventSink(), browser_factory=browser.factory(), pacer=instant_pacer())
    jobs = await src.discover(ctx_for(conn))
    assert len(jobs) == 5
    assert sum("goto?url=" in u for u in browser.visited) == 5
    summary = SearchPlanner(conn, "google", windows=4, max_pages=1).summary()
    assert sum(st["last_new"] for st in summary.values()) == 5
    # the search the budget cut short stays on the same page for next time
    assert any((st["window"], st["page"]) == (0, 0) for st in summary.values())


async def test_linkedin_job_pages_read_in_parallel_and_captcha_stops_every_tab(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["Backend Engineer"], "locations": ["India"], "searches_per_session": 1})
    browser = _SlowBrowser(routes=LI_ROUTES)
    src = LinkedinSource(conn, emit=EventSink(), browser_factory=browser.factory(), pacer=instant_pacer())
    jobs = await src.discover(ctx_for(conn))
    assert len(jobs) == 3 and browser.peak["visit"] >= 2

    db.update_preferences(conn, {"roles": ["Platform Engineer"]})
    routes = [(r"/jobs/view/4012345678", lambda: fixture("linkedin_captcha.html")), *LI_ROUTES]
    blocked = _SlowBrowser(routes=routes)
    sink = EventSink()
    src2 = LinkedinSource(conn, emit=sink, browser_factory=blocked.factory(), pacer=instant_pacer())
    await src2.discover(ctx_for(conn))
    assert [e.details["reason"] for e in sink.of("error")] == ["captcha"]   # reported once, not per tab
    assert src2.last_state is not None and src2.last_state.value == "captcha"
