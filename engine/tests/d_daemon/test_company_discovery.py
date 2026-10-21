"""Company discovery: suggestions (v6 table + commands), the Google company finder and the
career-page agents. Fake browser / HTTP / LLM only."""

from __future__ import annotations

import asyncio
import json
import sqlite3
from typing import Any

import httpx
import pytest

from autoapply import db
from autoapply.discovery.base import DiscoveredJob, DiscoveryContext
from autoapply.discovery.careers_agent import CareerPageAgent, content_hash, link_postings, parse_jsonld_postings
from autoapply.discovery.company_finder import (
    ATS_SITES,
    BoardHit,
    CompanyFinder,
    company_name_for,
    parse_board_results,
    plan_queries,
)
from autoapply.discovery.suggestions import careers_url_for, is_job_board
from autoapply.enums import Ats, JobSource, SuggestionStatus
from autoapply.llm.provider import FakeLLMProvider
from autoapply.paths import Paths
from autoapply.pipeline import Pipeline

from .fakes import EventSink, FakeBrowser, FakeSource, fake_hooks, instant_pacer

# =====================================================================================
# helpers
# =====================================================================================


def gh_board(*titles: str, name: str | None = None) -> dict[str, Any]:
    return {"jobs": [{"id": 100 + i, "title": t, "location": {"name": "Bengaluru"}, "content": "&lt;p&gt;Build things&lt;/p&gt;",
                      "absolute_url": f"https://job-boards.greenhouse.io/x/jobs/{100 + i}", **({"company_name": name} if name else {})}
                     for i, t in enumerate(titles)]}


def mock_http(routes: dict[str, Any], calls: list[str] | None = None, delay: float = 0.0) -> httpx.AsyncClient:
    """``routes``: substring of the URL -> JSON (dict/list), HTML (str) or an int status."""

    async def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if calls is not None:
            calls.append(url)
        if delay:
            await asyncio.sleep(delay)
        for needle, body in routes.items():
            if needle in url:
                if isinstance(body, int):
                    return httpx.Response(body)
                if isinstance(body, str):
                    return httpx.Response(200, text=body, headers={"content-type": "text/html"})
                return httpx.Response(200, json=body)
        return httpx.Response(404)

    return httpx.AsyncClient(transport=httpx.MockTransport(handler), follow_redirects=True)


def ctx_for(conn: sqlite3.Connection, http: httpx.AsyncClient, *, roles: list[str] | None = None, round_: int = 0) -> DiscoveryContext:
    if roles is not None:
        db.update_preferences(conn, {"roles": roles, "locations": ["Bengaluru"]})
    return DiscoveryContext(preferences=db.get_preferences(conn), companies=db.list_companies(conn, watch_only=True),
                            http=http, round=round_)


def google_job(company: str, title: str, apply_url: str | None, n: int = 1) -> DiscoveredJob:
    from autoapply.discovery.base import detect_ats

    ats, token = detect_ats(apply_url)
    return DiscoveredJob(source=JobSource.GOOGLE, company_name=company, title=title, apply_url=apply_url, ats=ats,
                         board_token=token, external_id=f"g:{company}:{n}", location="Bengaluru")


# =====================================================================================
# DB: migration + suggestions
# =====================================================================================


def test_v6_migration_adds_suggestions_table(conn: sqlite3.Connection) -> None:
    assert db.current_schema_version(conn) == db.SCHEMA_VERSION >= 6
    conn.execute("DROP TABLE company_suggestions")
    conn.execute("DELETE FROM schema_version WHERE version >= 6")
    assert db.current_schema_version(conn) == 5
    assert db.migrate(conn) == db.SCHEMA_VERSION
    assert conn.execute("SELECT COUNT(*) FROM company_suggestions").fetchone()[0] == 0


def test_suggest_accept_dismiss_and_badge(conn: sqlite3.Connection) -> None:
    s = db.suggest_company(conn, "Acme", url="https://careers.acme.com/jobs", source="google", sample_title="AI Engineer",
                           add_matching=1)
    assert s is not None and s.status is SuggestionStatus.PENDING and s.matching_roles == 1
    s = db.suggest_company(conn, "ACME", url="https://careers.acme.com/jobs", source="linkedin", add_matching=2)
    assert s is not None and s.matching_roles == 3 and s.source == "google"  # same company, counts add up
    # a verified board upgrades the unverified careers URL
    s = db.suggest_company(conn, "Acme", url="https://jobs.lever.co/acme", source="company_finder", ats=Ats.LEVER,
                           board_token="acme", verified=True)
    assert s is not None and s.verified and s.board_token == "acme" and s.url == "https://jobs.lever.co/acme"
    assert db.compute_counts(conn).suggestions_pending == 1

    company = db.accept_company_suggestion(conn, s.id)
    assert company.watch and company.ats is Ats.LEVER and company.board_token == "acme"
    assert db.get_company_suggestion(conn, s.id).status is SuggestionStatus.ACCEPTED
    assert db.compute_counts(conn).suggestions_pending == 0
    # watched companies are not suggested again
    assert db.suggest_company(conn, "Acme", url="https://x", source="google") is None

    g = db.suggest_company(conn, "Globex", url="https://globex.com/careers", source="google")
    assert g is not None
    db.dismiss_company_suggestion(conn, g.id)
    assert db.company_dismissed(conn, "globex")
    assert db.suggest_company(conn, "Globex", url="https://globex.com/careers", source="google", add_matching=5) is None
    # accepting a plain careers page stores it as careers_url
    i = db.suggest_company(conn, "Initech", url="https://initech.com/careers", source="google")
    co = db.accept_company_suggestion(conn, i.id)
    assert co.watch and co.careers_url == "https://initech.com/careers" and co.ats is None


def test_dismissing_an_auto_watched_company_unwatches_it(conn: sqlite3.Connection) -> None:
    co = db.upsert_company(conn, "Hooli", ats=Ats.GREENHOUSE, board_token="hooli", watch=True)
    s = db.suggest_company(conn, "Hooli", url="https://job-boards.greenhouse.io/hooli", source="company_finder",
                           ats=Ats.GREENHOUSE, board_token="hooli", verified=True, status=SuggestionStatus.AUTO, company_id=co.id)
    assert s is not None and s.status is SuggestionStatus.AUTO
    assert db.compute_counts(conn).suggestions_pending == 0  # auto rows are not pending
    db.dismiss_company_suggestion(conn, s.id)
    assert not db.get_company(conn, co.id).watch


@pytest.mark.parametrize(("url", "expected"), [
    ("https://careers.acme.com/jobs/123-backend-engineer", "https://careers.acme.com/jobs"),
    ("https://acme.com/en/careers/positions/42", "https://acme.com/en/careers/positions"),
    ("https://jobs.smartrecruiters.com/Acme/7431-eng", "https://jobs.smartrecruiters.com/Acme"),
    ("https://acme.wd5.myworkdayjobs.com/en-US/External/job/Bangalore/AI-Engineer_R1", "https://acme.wd5.myworkdayjobs.com/en-US/External"),
    ("https://apply.workable.com/acme/j/ABC123/", "https://apply.workable.com/acme"),
    ("https://www.linkedin.com/jobs/view/123", None),
    ("https://in.indeed.com/viewjob?jk=1", None),
    (None, None),
])
def test_careers_url_for(url: str | None, expected: str | None) -> None:
    assert careers_url_for(url) == expected


def test_job_boards_are_not_company_sites() -> None:
    assert is_job_board("https://www.glassdoor.co.in/job-listing/x")
    assert not is_job_board("https://careers.acme.com/jobs/1")


# =====================================================================================
# Suggestions from browser listings (pipeline._persist)
# =====================================================================================


def _pipeline(conn: sqlite3.Connection, paths: Paths, jobs: list[DiscoveredJob]) -> Pipeline:
    hooks, _ = fake_hooks()
    return Pipeline(conn, paths=paths, llm=FakeLLMProvider(default="ok"), sources=[FakeSource(jobs, name=JobSource.GOOGLE)],
                    adapters=[], emit=EventSink(), hooks=hooks, is_paused=lambda: False)


async def test_browser_listings_become_suggestions(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    db.upsert_company(conn, "Globex", watch=False)
    gx = db.suggest_company(conn, "Globex", url="https://globex.com/careers", source="google")
    db.dismiss_company_suggestion(conn, gx.id)
    jobs = [
        google_job("Acme", "AI Engineer", "https://careers.acme.com/jobs/1-ai-engineer", 1),
        google_job("Acme", "ML Engineer", "https://careers.acme.com/jobs/2-ml-engineer", 2),
        google_job("Ramp", "AI Engineer", "https://jobs.ashbyhq.com/ramp/abc-uuid", 3),
        google_job("Globex", "AI Engineer", "https://boards.greenhouse.io/globex/jobs/9", 4),
        google_job("Initech", "AI Engineer", "https://www.linkedin.com/jobs/view/5", 5),
    ]
    p = _pipeline(conn, autoapply_home, jobs)
    await p.discover()
    acme = db.get_company_suggestion_by_name(conn, "Acme")
    assert acme is not None and acme.status is SuggestionStatus.PENDING
    assert acme.url == "https://careers.acme.com/jobs" and acme.matching_roles == 2 and acme.source == "google"
    assert not db.get_company_by_name(conn, "Acme").watch  # a plain career page is only suggested
    ramp = db.get_company_suggestion_by_name(conn, "Ramp")
    assert ramp is not None and ramp.status is SuggestionStatus.AUTO  # readable board: watched by the agent
    assert db.get_company_by_name(conn, "Ramp").watch
    assert not db.get_company_by_name(conn, "Globex").watch  # dismissed: never auto-watched
    assert db.get_company_suggestion_by_name(conn, "Initech") is None  # a job board is no company site


async def test_boards_past_the_watch_cap_are_suggested(conn: sqlite3.Connection, autoapply_home: Paths,
                                                       monkeypatch: pytest.MonkeyPatch) -> None:
    import autoapply.pipeline as pipeline_mod

    monkeypatch.setattr(pipeline_mod, "MAX_WATCHED_COMPANIES", 0)
    p = _pipeline(conn, autoapply_home, [google_job("Ramp", "AI Engineer", "https://jobs.ashbyhq.com/ramp/abc", 1)])
    await p.discover()
    s = db.get_company_suggestion_by_name(conn, "Ramp")
    assert s is not None and s.status is SuggestionStatus.PENDING and s.ats is Ats.ASHBY and s.board_token == "ramp"
    assert not db.get_company_by_name(conn, "Ramp").watch
    co = db.accept_company_suggestion(conn, s.id)
    assert co.watch and co.ats is Ats.ASHBY


# =====================================================================================
# Company finder
# =====================================================================================

GOOGLE_RESULTS = """<html><head><title>site:boards.greenhouse.io "AI Engineer" - Google Search</title></head><body>
<div><a href="/url?q=https://boards.greenhouse.io/acmeai/jobs/123&sa=U"><h3>Job Application for AI Engineer at Acme AI</h3></a></div>
<div><a href="https://job-boards.greenhouse.io/acmeai/jobs/124"><h3>Job Application for ML Engineer at Acme AI</h3></a></div>
<div><a href="https://jobs.lever.co/zeta/0b1c-uuid"><h3>Zeta - AI Engineer</h3></a></div>
<div><a href="https://jobs.ashbyhq.com/plain/1-2-3"><h3>Senior AI Engineer @ Plain Co</h3></a></div>
<div><a href="https://jobs.ashbyhq.com/watched/9"><h3>AI Engineer @ Watched</h3></a></div>
<div><a href="https://www.google.com/search?q=next">Next</a><a href="https://example.com/blog">Blog</a></div>
</body></html>"""

CAPTCHA_HTML = "<html><head><title>Sorry...</title></head><body><form id='captcha-form'></form></body></html>"


def test_parse_board_results_unwraps_and_dedupes() -> None:
    hits = parse_board_results(GOOGLE_RESULTS, "q")
    assert [(h.ats, h.token) for h in hits] == [(Ats.GREENHOUSE, "acmeai"), (Ats.LEVER, "zeta"), (Ats.ASHBY, "plain"),
                                                (Ats.ASHBY, "watched")]
    assert hits[0].title.startswith("Job Application for AI Engineer")


def test_company_name_for() -> None:
    gh = BoardHit(Ats.GREENHOUSE, "acmeai", "Job Application for AI Engineer at Acme AI")
    assert company_name_for(gh, []) == "Acme AI"
    assert company_name_for(BoardHit(Ats.LEVER, "zeta", "Zeta - AI Engineer"), []) == "Zeta"
    assert company_name_for(BoardHit(Ats.ASHBY, "plain", "Senior AI Engineer @ Plain Co"), []) == "Plain Co"
    assert company_name_for(BoardHit(Ats.ASHBY, "foo-bar", ""), []) == "Foo Bar"
    job = DiscoveredJob(source=JobSource.GREENHOUSE, company_name="Acme, Inc.", title="x")
    assert company_name_for(gh, [job]) == "Acme, Inc."  # the board's own name wins


def test_plan_queries_rotates_and_rests() -> None:
    state: dict[str, Any] = {}
    first = plan_queries(["AI Engineer", "ML Engineer"], ["Bengaluru"], state, 2)
    assert {q.role for q in first} == {"AI Engineer", "ML Engineer"}  # roles interleaved
    assert first[0].text == 'site:boards.greenhouse.io "AI Engineer" Bengaluru'
    state["queries"] = {q.key: {"runs": 1, "last_at": "2026-01-01T00:00:00", "page": 1} for q in first}
    second = plan_queries(["AI Engineer", "ML Engineer"], ["Bengaluru"], state, 2)
    assert not {q.key for q in second} & {q.key for q in first}  # new queries first
    state["queries"] = {q.key: {"runs": 1, "rest_until": "2999-01-01T00:00:00"} for q in [*first, *second]}
    third = plan_queries(["AI Engineer", "ML Engineer"], ["Bengaluru"], state, 8)
    assert len(third) == min(8, 2 * len(ATS_SITES) - 4) and not {q.key for q in third} & {q.key for q in [*first, *second]}
    assert "start=10" in type(first[0])(first[0].key, "r", "", Ats.LEVER, "jobs.lever.co", 1).url()


def _finder(conn: sqlite3.Connection, browser: FakeBrowser, **kw: Any) -> CompanyFinder:
    return CompanyFinder(conn, emit=EventSink(), browser_factory=browser.factory(), pacer=instant_pacer(), **kw)


FINDER_HTTP = {
    "boards-api.greenhouse.io/v1/boards/acmeai/jobs": gh_board("AI Engineer", "Account Executive"),
    "api.lever.co/v0/postings/zeta": [{"text": "Sales Manager", "hostedUrl": "https://jobs.lever.co/zeta/1", "id": "1",
                                        "categories": {"location": "Bengaluru"}}],
    "api.ashbyhq.com/posting-api/job-board/plain": 404,
}


async def test_company_finder_watches_verified_boards_with_matching_roles(conn: sqlite3.Connection) -> None:
    db.upsert_company(conn, "Watched", ats=Ats.ASHBY, board_token="watched", watch=True)
    browser = FakeBrowser(routes=[(r"google\.com/search", GOOGLE_RESULTS)])
    calls: list[str] = []
    http = mock_http(FINDER_HTTP, calls)
    finder = _finder(conn, browser)
    jobs = await finder.discover(ctx_for(conn, http, roles=["AI Engineer"]))
    assert len(browser.visited) == 2 and all("google.com/search" in u for u in browser.visited)
    assert not any("watched" in c for c in calls)  # already watched: not re-verified
    acme = db.get_company_by_name(conn, "Acme AI")
    assert acme is not None and acme.watch and acme.ats is Ats.GREENHOUSE and acme.board_token == "acmeai"
    s = db.get_company_suggestion_by_name(conn, "Acme AI")
    assert s.status is SuggestionStatus.AUTO and s.verified and s.matching_roles == 1 and s.open_roles == 2
    assert [j.title for j in jobs] == ["AI Engineer"] and jobs[0].company_name == "Acme AI"
    assert db.get_company_by_name(conn, "Zeta") is None  # verified but no matching roles
    assert db.get_company_suggestion_by_name(conn, "Plain Co") is None  # did not verify
    rep = finder.last_report
    assert rep.queries == 2 and rep.watched == ["Acme AI"] and rep.no_match == 1 and rep.failed == 1
    assert db.get_source_sessions(conn, "company_finder") == 2
    # next run: the same boards are not verified again, and the cursor moved to new queries
    calls.clear()
    await finder.discover(ctx_for(conn, http))
    assert not any("zeta" in c or "plain" in c for c in calls)
    assert len(set(browser.visited)) == 4


async def test_company_finder_suggests_when_watchlist_is_full(conn: sqlite3.Connection) -> None:
    browser = FakeBrowser(routes=[(r"google\.com/search", GOOGLE_RESULTS)])
    finder = _finder(conn, browser, max_watched=0, queries_per_run=1)
    jobs = await finder.discover(ctx_for(conn, mock_http(FINDER_HTTP), roles=["AI Engineer"]))
    assert jobs == []
    s = db.get_company_suggestion_by_name(conn, "Acme AI")
    assert s is not None and s.status is SuggestionStatus.PENDING and s.verified and s.source == "company_finder"
    assert db.get_company_by_name(conn, "Acme AI") is None  # nothing watched or created until the user adds it


async def test_company_finder_stops_on_captcha_and_respects_budget(conn: sqlite3.Connection) -> None:
    browser = FakeBrowser(routes=[(r"google\.com/sorry", CAPTCHA_HTML)], redirects=[(r"google\.com/search", "https://www.google.com/sorry/index")])
    finder = _finder(conn, browser)
    assert await finder.discover(ctx_for(conn, mock_http({}), roles=["AI Engineer"])) == []
    assert finder.last_report.captcha and len(browser.visited) == 1
    # resting after the CAPTCHA: no browser at all
    assert await finder.discover(ctx_for(conn, mock_http({}))) == [] and browser.launches == 1

    conn.execute("DELETE FROM meta WHERE key = 'company_finder_state'")
    db.set_meta(conn, db.source_sessions_key("company_finder"), 6)
    assert await finder.discover(ctx_for(conn, mock_http({}))) == [] and browser.launches == 1
    # deeper rounds and an explicit opt-out don't search either
    db.set_meta(conn, db.source_sessions_key("company_finder"), 0)
    assert await finder.discover(ctx_for(conn, mock_http({}), round_=1)) == []
    db.update_preferences(conn, {"sources_enabled": {**db.get_preferences(conn).sources_enabled, "company_finder": False}})
    assert await finder.discover(ctx_for(conn, mock_http({}))) == [] and browser.launches == 1


async def test_company_finder_follows_google_toggle_in_pipeline(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    finder = _finder(conn, FakeBrowser())
    hooks, _ = fake_hooks()
    p = Pipeline(conn, paths=autoapply_home, llm=FakeLLMProvider(default="ok"), sources=[finder], adapters=[],
                 emit=EventSink(), hooks=hooks, is_paused=lambda: False)
    prefs = db.get_preferences(conn)
    assert p._enabled_sources(prefs) == [finder]
    prefs = db.update_preferences(conn, {"sources_enabled": {**prefs.sources_enabled, "google": False}})
    assert p._enabled_sources(prefs) == []


# =====================================================================================
# Career-page agents
# =====================================================================================

JSONLD_PAGE = """<html><head><script type="application/ld+json">
{"@context": "https://schema.org", "@graph": [
  {"@type": "JobPosting", "title": "AI Engineer", "url": "/careers/ai-engineer", "datePosted": "2026-10-01",
   "jobLocation": {"@type": "Place", "address": {"addressLocality": "Bengaluru", "addressCountry": "IN"}},
   "description": "&lt;p&gt;Agents in Python&lt;/p&gt;"},
  {"@type": "JobPosting", "title": "Office Manager", "url": "/careers/office-manager", "jobLocationType": "TELECOMMUTE"}
]}</script></head><body><h1>Careers</h1></body></html>"""

LINKS_PAGE = """<html><body><h1>Open roles</h1><ul>
<li><a href="/jobs/ai-engineer-123">AI Engineer</a></li>
<li><a href="/jobs/designer-456">Product Designer</a></li>
<li><a href="/about">About us</a></li></ul></body></html>"""

EMBED_PAGE = """<html><body><div id="grnhse_app"></div>
<script src="https://boards.greenhouse.io/embed/job_board/js?for=initech"></script></body></html>"""

PROSE = " ".join(["We are hiring across many teams and we love building products."] * 12)
LLM_PAGE = f"""<html><body><h1>Join us</h1><p>{PROSE}</p>
<div class="role"><span>AI Engineer</span> <span>Bengaluru</span> <a href="https://hooli.example/apply?r=77">Apply</a></div>
<div class="role"><span>Chef</span> <a href="https://hooli.example/apply?r=78">Apply</a></div></body></html>"""

JS_SHELL = "<html><body><div id='root'></div><script src='/app.js'></script></body></html>"


def test_jsonld_and_link_extraction() -> None:
    posts = parse_jsonld_postings(JSONLD_PAGE, "https://acme.com/careers")
    assert [(p.title, p.url, p.location) for p in posts] == [
        ("AI Engineer", "https://acme.com/careers/ai-engineer", "Bengaluru, IN"),
        ("Office Manager", "https://acme.com/careers/office-manager", "Remote"),
    ]
    assert "Agents in Python" in (posts[0].description or "")
    links = link_postings(LINKS_PAGE, "https://globex.com/careers")
    assert [(p.title, p.url) for p in links] == [("AI Engineer", "https://globex.com/jobs/ai-engineer-123"),
                                                ("Product Designer", "https://globex.com/jobs/designer-456")]
    # the hash ignores scripts/nonces but sees text and links
    assert content_hash("<p>a</p><script>nonce=1</script>") == content_hash("<p>a</p><script>nonce=2</script>")
    assert content_hash("<p>a</p>") != content_hash("<p>b</p>")


def _watch(conn: sqlite3.Connection, name: str, url: str) -> None:
    db.upsert_company(conn, name, careers_url=url, watch=True)


async def test_career_agents_read_each_site_the_cheapest_way(conn: sqlite3.Connection) -> None:
    _watch(conn, "Acme", "https://acme.com/careers")
    _watch(conn, "Globex", "https://globex.com/careers")
    _watch(conn, "Initech", "https://initech.com/careers")
    _watch(conn, "Hooli", "https://hooli.example/careers")
    _watch(conn, "Umbrella", "https://umbrella.example/careers")
    _watch(conn, "Zeta", "https://jobs.lever.co/zeta")
    db.upsert_company(conn, "Covered", ats=Ats.GREENHOUSE, board_token="covered", careers_url="https://covered.com/jobs", watch=True)
    calls: list[str] = []
    http = mock_http({
        "acme.com/careers": JSONLD_PAGE, "globex.com/careers": LINKS_PAGE, "initech.com/careers": EMBED_PAGE,
        "hooli.example/careers": LLM_PAGE, "umbrella.example/careers": JS_SHELL,
        "boards-api.greenhouse.io/v1/boards/initech/jobs": gh_board("AI Engineer", "Chef"),
        "api.lever.co/v0/postings/zeta": [{"text": "AI Engineer", "hostedUrl": "https://jobs.lever.co/zeta/1", "id": "1"}],
    }, calls)
    llm = FakeLLMProvider(rules=[("EXTRACT JOB POSTINGS", {"jobs": [
        {"title": "AI Engineer", "url": "https://hooli.example/apply?r=77", "location": "Bengaluru"},
        {"title": "Chef", "url": "https://made-up.example/x", "location": None}]})])
    rendered: list[str] = []

    async def renderer(url: str) -> list[tuple[str, str, str]]:
        rendered.append(url)
        return [("https://umbrella.example/jobs/9", "AI Engineer", "AI Engineer · Remote")]

    sink = EventSink()
    agent = CareerPageAgent(conn, llm, emit=sink, renderer=renderer)
    ctx = ctx_for(conn, http, roles=["AI Engineer"])
    jobs = await agent.discover(ctx)
    by = {r.company: r for r in agent.results}
    assert set(by) == {"Acme", "Globex", "Initech", "Hooli", "Umbrella", "Zeta"}  # "Covered" has a board reader
    assert by["Acme"].method == "json-ld" and by["Globex"].method == "links" and by["Initech"].method == "embedded-ats"
    assert by["Hooli"].method == "llm" and by["Umbrella"].method == "rendered" and by["Zeta"].method == "ats"
    assert rendered == ["https://umbrella.example/careers"]
    assert len(llm.calls) == 1 and llm.tiers == ["fast"]
    assert {j.company_name for j in jobs} == {"Acme", "Globex", "Initech", "Hooli", "Umbrella", "Zeta"}
    assert all(j.title == "AI Engineer" for j in jobs)  # role focus filter
    assert all(j.source is JobSource.CAREERS for j in jobs)
    hooli = next(j for j in jobs if j.company_name == "Hooli")
    assert hooli.apply_url == "https://hooli.example/apply?r=77" and hooli.location == "Bengaluru"
    # the embedded board is learned onto the company, so the Greenhouse source reads it next time
    ini = db.get_company_by_name(conn, "Initech")
    assert ini.ats is Ats.GREENHOUSE and ini.board_token == "initech"
    assert any("Career page · Hooli" in p.message for p in sink.of("log"))

    # Second run: unchanged pages reuse the cached extraction (no tokens); the JS shell re-renders.
    llm.calls.clear()
    ctx = ctx_for(conn, http)
    jobs2 = await agent.discover(ctx)
    by = {r.company: r for r in agent.results}
    assert "Initech" not in by  # now read by its board
    assert by["Hooli"].method == "cached:llm" and by["Acme"].method == "cached:json-ld"
    assert llm.calls == [] and rendered == ["https://umbrella.example/careers"] * 2
    assert {j.company_name for j in jobs2} >= {"Acme", "Hooli"}


async def test_career_agents_run_three_at_a_time_and_survive_failures(conn: sqlite3.Connection) -> None:
    for i in range(7):
        _watch(conn, f"Co{i}", f"https://co{i}.example/careers")
    live = {"now": 0, "max": 0}

    async def handler(request: httpx.Request) -> httpx.Response:
        live["now"] += 1
        live["max"] = max(live["max"], live["now"])
        await asyncio.sleep(0.02)
        live["now"] -= 1
        if "co3." in str(request.url):
            return httpx.Response(500)
        return httpx.Response(200, text=LINKS_PAGE)

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    agent = CareerPageAgent(conn, None)
    ctx = ctx_for(conn, http, roles=["AI Engineer"])
    jobs = await agent.discover(ctx)
    assert live["max"] == 3
    assert len(jobs) == 6 and "Co3" in ctx.errors


async def test_career_page_without_llm_or_postings_reports_why(conn: sqlite3.Connection) -> None:
    _watch(conn, "Quiet", "https://quiet.example/careers")
    agent = CareerPageAgent(conn, None)
    ctx = ctx_for(conn, mock_http({"quiet.example": f"<html><body><p>{PROSE}</p></body></html>"}), roles=["AI Engineer"])
    assert await agent.discover(ctx) == []
    assert "no job postings" in ctx.errors["Quiet"]


# =====================================================================================
# Daemon commands
# =====================================================================================


async def test_daemon_accept_and_dismiss_commands(autoapply_home: Paths) -> None:
    import shutil
    import tempfile
    from pathlib import Path

    from .test_daemon import build_daemon, client

    sock = Path(tempfile.mkdtemp(prefix="aad", dir="/tmp"))
    d = build_daemon(autoapply_home, sock / "d.sock")
    await d.start()
    try:
        a = db.suggest_company(d.conn, "Acme", url="https://careers.acme.com/jobs", source="google", add_matching=3)
        b = db.suggest_company(d.conn, "Globex", url="https://jobs.lever.co/globex", source="linkedin", ats=Ats.LEVER,
                               board_token="globex")
        c = await client(d)
        snap, _ = await c.request("hello", {"client": "test", "protocol_version": 1})
        assert snap["payload"]["counts"]["suggestions_pending"] == 2
        reply, _ = await c.request("accept_company_suggestion", {"suggestion_id": b.id})
        assert reply["type"] == "ack"
        co = db.get_company(d.conn, reply["payload"]["result"]["company_id"])
        assert co.watch and co.ats is Ats.LEVER and co.board_token == "globex"
        reply, _ = await c.request("dismiss_company_suggestion", {"suggestion_id": a.id})
        assert reply["type"] == "ack" and db.company_dismissed(d.conn, "Acme")
        reply, _ = await c.request("dismiss_company_suggestion", {"suggestion_id": 999})
        assert reply["type"] == "error" and reply["payload"]["code"] == "not_found"
        await c.close()
    finally:
        await d.stop()
        shutil.rmtree(sock, ignore_errors=True)


def test_default_sources_include_finder_and_career_agents(conn: sqlite3.Connection, autoapply_home: Paths) -> None:
    from autoapply.daemon import default_sources

    srcs = default_sources({"conn": conn, "llm": FakeLLMProvider(), "emit": EventSink(), "is_paused": lambda: False,
                            "profile_dir": autoapply_home.chrome_profile, "headless": True})
    kinds = {type(s).__name__ for s in srcs}
    assert {"CareerPageAgent", "CompanyFinder"} <= kinds and "CareersSource" not in kinds
    agent = next(s for s in srcs if isinstance(s, CareerPageAgent))
    assert agent.llm is not None and agent._conn is conn
    json.dumps([str(getattr(s.name, "value", s.name)) for s in srcs])
