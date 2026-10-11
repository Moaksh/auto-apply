"""LinkedIn / Glassdoor read-only discovery, against local fixture HTML only."""

from __future__ import annotations

import sqlite3

import httpx
import pytest

from autoapply import db
from autoapply.discovery.base import DiscoveryContext, Source
from autoapply.discovery.glassdoor import (
    GLASSDOOR_SELECTORS,
    GlassdoorSource,
    glassdoor_search_urls,
    parse_glassdoor_detail,
    parse_glassdoor_search,
)
from autoapply.discovery.linkedin import (
    LINKEDIN_SELECTORS,
    LinkedinSource,
    PageState,
    detect_page_state,
    guess_ats,
    linkedin_search_urls,
    parse_linkedin_detail,
    parse_linkedin_search,
    parse_salary,
    unwrap_redirect,
)
from autoapply.enums import Ats, CapKind, ErrorCode, RemotePolicy

from .fakes import EventSink, FakeBrowser, FakePage, fixture, instant_pacer

LI_ROUTES = [
    (r"linkedin\.com/jobs/search", lambda: fixture("linkedin_search.html")),
    (r"/jobs/view/4012345678", lambda: fixture("linkedin_job_4012345678.html")),
    (r"/jobs/view/4023456789", lambda: fixture("linkedin_job_4023456789.html")),
    (r"/jobs/view/4034567890", lambda: fixture("linkedin_job_4034567890.html")),
    (r"linkedin\.com/login", lambda: fixture("linkedin_login.html")),
    (r"linkedin\.com/feed", lambda: fixture("linkedin_feed.html")),
]


def ctx_for(conn: sqlite3.Connection) -> DiscoveryContext:
    return DiscoveryContext(preferences=db.get_preferences(conn), companies=[], http=httpx.AsyncClient())


@pytest.fixture
def prefs_set(conn: sqlite3.Connection) -> None:
    db.update_preferences(conn, {"roles": ["Backend Engineer"], "locations": ["India"], "sources_enabled": {"linkedin": True, "glassdoor": True}})


# ---- pure parsing -------------------------------------------------------------------


def test_parse_linkedin_search_cards() -> None:
    cards = parse_linkedin_search(fixture("linkedin_search.html"), "https://www.linkedin.com/jobs/search/?keywords=x")
    assert [(c.title, c.company, c.external_id, c.easy_apply) for c in cards] == [
        ("Senior Backend Engineer", "Stripe", "4012345678", False),
        ("Backend SDE II", "Razorpay", "4023456789", True),
        ("Platform Engineer", "Acme Robotics", "4034567890", False),
    ]  # the occluded placeholder card is ignored
    assert cards[0].detail_url == "https://www.linkedin.com/jobs/view/4012345678/"  # tracking stripped
    assert cards[0].location == "Bengaluru, Karnataka, India (Hybrid)"
    assert cards[2].salary_text == "$150K/yr - $190K/yr"


def test_parse_linkedin_detail_external_apply() -> None:
    d = parse_linkedin_detail(fixture("linkedin_job_4012345678.html"))
    assert d.title == "Senior Backend Engineer" and d.company == "Stripe" and not d.easy_apply
    # LinkedIn redirect unwrapped, tracking dropped, ATS params kept
    assert d.apply_url == "https://boards.greenhouse.io/stripe/jobs/5551234"
    assert "payment APIs" in (d.description or "") and d.workplace == "Hybrid"


def test_parse_linkedin_detail_easy_apply_has_no_apply_url() -> None:
    d = parse_linkedin_detail(fixture("linkedin_job_4023456789.html"))
    assert d.easy_apply is True and d.apply_url is None


def test_parse_linkedin_guest_detail_apply_url_comment() -> None:
    d = parse_linkedin_detail(fixture("linkedin_job_4034567890.html"))
    assert d.apply_url == "https://jobs.lever.co/acme/7f3e2c1a-aaaa-bbbb-cccc-1234567890ab/apply"
    assert d.company == "Acme Robotics"
    assert parse_salary(d.salary_text) == (150000, 190000, "USD")


@pytest.mark.parametrize(
    "fixture_name,url,expected",
    [
        ("linkedin_login.html", "https://www.linkedin.com/login", PageState.LOGIN_REQUIRED),
        ("linkedin_search.html", "https://www.linkedin.com/authwall?trk=x", PageState.LOGIN_REQUIRED),
        ("linkedin_captcha.html", "https://www.linkedin.com/jobs/search/", PageState.CAPTCHA),
        ("linkedin_search.html", "https://www.linkedin.com/checkpoint/challenge/abc", PageState.CAPTCHA),
        ("linkedin_search.html", "https://www.linkedin.com/jobs/search/", PageState.OK),
    ],
)
def test_detect_page_state(fixture_name: str, url: str, expected: PageState) -> None:
    src = LinkedinSource.__new__(LinkedinSource)
    assert src.page_state(fixture(fixture_name), url) is expected


def test_selector_tables_are_the_single_source() -> None:
    for table in (LINKEDIN_SELECTORS, GLASSDOOR_SELECTORS):
        for key in ("search_card", "card_title", "card_company", "detail_description", "login_wall", "captcha", "logged_in"):
            assert table[key], key
    # a broken selector in the table degrades instead of raising
    assert detect_page_state("<html></html>", None, {"captcha": ["::bad(("], "login_wall": []}) is PageState.OK


@pytest.mark.parametrize(
    "text,expected",
    [
        ("$120K - $160K (Employer est.)", (120000, 160000, "USD")),
        ("₹25L", (None, None, None)),
        ("$50/hr - $70/hr", (104000, 145600, "USD")),
        ("€70,000 - €90,000", (70000, 90000, "EUR")),
        (None, (None, None, None)),
    ],
)
def test_parse_salary(text: str | None, expected: tuple) -> None:
    assert parse_salary(text) == expected


def test_unwrap_and_guess_ats() -> None:
    assert unwrap_redirect("https://www.linkedin.com/redirect?url=https%3A%2F%2Fjobs.ashbyhq.com%2Flinear%2Fabc") == "https://jobs.ashbyhq.com/linear/abc"
    assert guess_ats("https://boards.greenhouse.io/stripe/jobs/1")[0] is Ats.GREENHOUSE
    assert guess_ats("https://jobs.lever.co/acme/x")[0] is Ats.LEVER
    assert guess_ats("https://acme.wd1.myworkdayjobs.com/en-US/x")[0] is Ats.WORKDAY
    assert guess_ats(None) == (Ats.OTHER, None)


def test_search_urls_from_preferences(conn: sqlite3.Connection, prefs_set: None) -> None:
    prefs = db.get_preferences(conn)
    li = linkedin_search_urls(prefs)
    assert li == ["https://www.linkedin.com/jobs/search/?keywords=Backend+Engineer&f_TPR=r86400&location=India&f_WT=2%2C3"]
    gd = glassdoor_search_urls(prefs)
    assert gd == ["https://www.glassdoor.com/Job/jobs.htm?sc.keyword=Backend+Engineer&fromAge=1&locKeyword=India"]


# ---- full source sessions (fixture browser) -----------------------------------------


async def test_linkedin_session_extracts_jobs_and_easy_apply(conn: sqlite3.Connection, prefs_set: None) -> None:
    browser = FakeBrowser(routes=LI_ROUTES)
    sink = EventSink()
    pacer = instant_pacer()
    src = LinkedinSource(conn, emit=sink, browser_factory=browser.factory(), pacer=pacer)
    assert isinstance(src, Source)
    jobs = await src.discover(ctx_for(conn))

    by_title = {j.title: j for j in jobs}
    assert set(by_title) == {"Senior Backend Engineer", "Backend SDE II", "Platform Engineer"}
    stripe = by_title["Senior Backend Engineer"]
    assert stripe.apply_url == "https://boards.greenhouse.io/stripe/jobs/5551234"
    assert stripe.ats is Ats.GREENHOUSE and stripe.board_token == "stripe" and stripe.remote is RemotePolicy.HYBRID
    assert stripe.source_url == "https://www.linkedin.com/jobs/view/4012345678/" and stripe.external_id == "4012345678"
    ea = by_title["Backend SDE II"]
    assert ea.easy_apply and ea.apply_url is None and ea.ats is Ats.LINKEDIN_EASY_APPLY
    acme = by_title["Platform Engineer"]
    assert acme.ats is Ats.LEVER and acme.salary_min == 150000 and acme.remote is RemotePolicy.REMOTE

    # human pacing happened, session counted, browser closed, status reported connected
    assert pacer.total_slept > 0 and browser.pages[0].scrolled > 0
    assert db.get_source_sessions(conn, "linkedin") == 1
    assert browser.launches == 1 and browser.closed == 1
    statuses = sink.of("source_status")
    assert statuses and statuses[-1].source.connected is True
    # read-only: only listing + detail pages were visited; nothing like an apply endpoint
    assert all("/jobs/search" in u or "/jobs/view/" in u for u in browser.visited)
    assert not hasattr(FakePage, "click")


async def test_linkedin_session_budget(conn: sqlite3.Connection, prefs_set: None) -> None:
    db.update_preferences(conn, {"linkedin_sessions_per_day": 2})
    browser = FakeBrowser(routes=LI_ROUTES)
    sink = EventSink()
    src = LinkedinSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer(), max_details=1)
    for _ in range(3):
        await src.discover(ctx_for(conn))
    assert browser.launches == 2  # third call never opened the browser
    caps = sink.of("cap_reached")
    assert len(caps) == 1 and caps[0].cap is CapKind.LINKEDIN_BUDGET and caps[0].used == 2 and caps[0].limit == 2
    assert caps[0].resets_at is not None
    assert db.compute_caps(conn).linkedin_sessions_used == 2


async def test_linkedin_login_wall_stops_and_asks_user(conn: sqlite3.Connection, prefs_set: None) -> None:
    browser = FakeBrowser(routes=LI_ROUTES, redirects=[(r"/jobs/search", "https://www.linkedin.com/login?session_redirect=x")])
    sink = EventSink()
    src = LinkedinSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer())
    jobs = await src.discover(ctx_for(conn))
    assert jobs == [] and src.last_state is PageState.LOGIN_REQUIRED
    errors = sink.of("error")
    assert len(errors) == 1 and errors[0].code is ErrorCode.UNAVAILABLE and errors[0].details["reason"] == "login_required"
    assert "log in" in errors[0].message.lower()
    status = sink.of("source_status")[-1].source
    assert status.connected is False
    assert db.get_meta(conn, db.META_SOURCES)["linkedin"]["connected"] is False
    assert browser.closed == 1


async def test_linkedin_captcha_on_detail_page(conn: sqlite3.Connection, prefs_set: None) -> None:
    routes = [(r"/jobs/view/4012345678", lambda: fixture("linkedin_captcha.html")), *LI_ROUTES]
    browser = FakeBrowser(routes=routes)
    sink = EventSink()
    src = LinkedinSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer())
    jobs = await src.discover(ctx_for(conn))
    assert jobs == []
    assert sink.of("error")[0].details["reason"] == "captcha"
    assert len([u for u in browser.visited if "/jobs/view/" in u]) == 1  # stopped immediately


async def test_linkedin_connect_flow(conn: sqlite3.Connection) -> None:
    state = {"n": 0}

    def login_then_feed() -> str:
        state["n"] += 1
        return fixture("linkedin_login.html")

    browser = FakeBrowser(routes=[(r"linkedin\.com/login", login_then_feed)])
    sink = EventSink()
    src = LinkedinSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer())
    page_holder: list = []

    async def fake_sleep(_s: float) -> None:
        # the user logs in: the page now shows the feed
        page = browser.pages[0]
        page_holder.append(page)
        page._url = "https://www.linkedin.com/feed/"
        page._html = fixture("linkedin_feed.html")

    ok = await src.connect(sleep=fake_sleep, poll=1, timeout=5)
    assert ok is True
    st = sink.of("source_status")
    assert st[0].source.connected is False and st[-1].source.connected is True


async def test_linkedin_connect_timeout(conn: sqlite3.Connection) -> None:
    browser = FakeBrowser(routes=LI_ROUTES)
    src = LinkedinSource(conn, browser_factory=browser.factory())

    async def no_sleep(_s: float) -> None:
        return None

    assert await src.connect(sleep=no_sleep, poll=1, timeout=3) is False


async def test_check_session(conn: sqlite3.Connection) -> None:
    browser = FakeBrowser(routes=LI_ROUTES)
    src = LinkedinSource(conn, browser_factory=browser.factory())
    assert (await src.check_session()).connected is True
    browser2 = FakeBrowser(routes=LI_ROUTES, redirects=[(r"/feed", "https://www.linkedin.com/login")])
    sink = EventSink()
    src2 = LinkedinSource(conn, emit=sink, browser_factory=browser2.factory())
    assert (await src2.check_session()).connected is False
    assert sink.of("error")


# ---- Glassdoor ----------------------------------------------------------------------


def test_parse_glassdoor() -> None:
    cards = parse_glassdoor_search(fixture("glassdoor_search.html"), "https://www.glassdoor.com/Job/jobs.htm")
    assert [(c.title, c.company, c.external_id, c.easy_apply) for c in cards] == [
        ("Backend Engineer", "Notion", "1009123456", False),
        ("SDE 2", "Freshworks", "1009234567", True),
    ]
    assert cards[0].detail_url.endswith("?jl=1009123456") and "src=" not in cards[0].detail_url
    d = parse_glassdoor_detail(fixture("glassdoor_job_1009123456.html"))
    assert d.company == "Notion" and d.apply_url is None
    assert d.apply_redirect and "/partner/jobListing.htm" in d.apply_redirect
    assert parse_glassdoor_detail(fixture("glassdoor_job_1009234567.html")).easy_apply is True


async def test_glassdoor_session_resolves_redirect(conn: sqlite3.Connection, prefs_set: None) -> None:
    browser = FakeBrowser(
        routes=[
            (r"glassdoor\.com/Job/jobs\.htm", lambda: fixture("glassdoor_search.html")),
            (r"jl=1009123456", lambda: fixture("glassdoor_job_1009123456.html")),
            (r"jl=1009234567", lambda: fixture("glassdoor_job_1009234567.html")),
            (r"ashbyhq\.com", "<html><body>Notion careers</body></html>"),
        ],
        redirects=[(r"/partner/jobListing\.htm", "https://jobs.ashbyhq.com/notion/1234-abcd?utm_source=glassdoor")],
    )
    sink = EventSink()
    src = GlassdoorSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer())
    jobs = await src.discover(ctx_for(conn))
    by = {j.title: j for j in jobs}
    assert by["Backend Engineer"].apply_url == "https://jobs.ashbyhq.com/notion/1234-abcd"
    assert by["Backend Engineer"].ats is Ats.ASHBY and by["Backend Engineer"].salary_max == 220000
    assert by["SDE 2"].easy_apply and by["SDE 2"].apply_url is None
    # the easy-apply job's redirect was never followed
    assert sum("/partner/" in u for u in browser.visited) == 1
    assert db.get_source_sessions(conn, "glassdoor") == 1


async def test_glassdoor_captcha(conn: sqlite3.Connection, prefs_set: None) -> None:
    browser = FakeBrowser(routes=[(r"glassdoor", lambda: fixture("glassdoor_captcha.html"))])
    sink = EventSink()
    src = GlassdoorSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer())
    assert await src.discover(ctx_for(conn)) == []
    assert sink.of("error")[0].details == {"source": "glassdoor", "reason": "captcha", "action": "onboarding_connect_source"}


async def test_no_roles_means_no_session(conn: sqlite3.Connection) -> None:
    browser = FakeBrowser(routes=LI_ROUTES)
    src = LinkedinSource(conn, browser_factory=browser.factory(), pacer=instant_pacer())
    assert await src.discover(ctx_for(conn)) == []
    assert browser.launches == 0 and db.get_source_sessions(conn, "linkedin") == 0


async def test_linkedin_jobs_persist_through_pipeline(conn: sqlite3.Connection, prefs_set: None, autoapply_home) -> None:
    """End-to-end: LinkedIn source -> pipeline persistence -> easy_apply table."""
    from autoapply.enums import RunKind
    from autoapply.llm.provider import FakeLLMProvider
    from autoapply.pipeline import Pipeline

    from .fakes import fake_hooks

    browser = FakeBrowser(routes=LI_ROUTES)
    sink = EventSink()
    src = LinkedinSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer())
    hooks, _ = fake_hooks()
    p = Pipeline(conn, paths=autoapply_home, llm=FakeLLMProvider(), sources=[src], adapters=[], emit=sink, hooks=hooks, is_paused=lambda: False)
    await p.run(RunKind.DISCOVER)
    jobs = {j.title: j for j in db.list_jobs(conn)}
    assert len(jobs) == 3
    ea = db.list_easy_apply(conn)
    assert [e.job_id for e in ea] == [jobs["Backend SDE II"].id]
    assert db.get_application_by_job(conn, jobs["Backend SDE II"].id).state.value == "scored"
    assert db.get_application_by_job(conn, jobs["Senior Backend Engineer"].id).state.value == "queued"
    stripe = db.get_company_by_name(conn, "Stripe")
    assert stripe is not None and stripe.ats is Ats.GREENHOUSE and stripe.board_token == "stripe"


# ---- login detection resilience ("Check now", navigation errors, closed window) -----------------


class _FlakyPage(FakePage):
    """content() raises the given errors first, then behaves normally."""

    def __init__(self, browser: FakeBrowser, errors: list[str]) -> None:
        super().__init__(browser)
        self.errors = list(errors)

    async def content(self) -> str:
        if self.errors:
            raise RuntimeError(self.errors.pop(0))
        return await super().content()


def _flaky_browser(errors: list[str], routes: list) -> FakeBrowser:
    browser = FakeBrowser(routes=routes)

    async def new_page() -> FakePage:
        p = _FlakyPage(browser, errors)
        browser.pages.append(p)
        return p

    browser.new_page = new_page  # type: ignore[method-assign]
    return browser


async def _no_sleep(_s: float) -> None:
    return None


async def test_connect_survives_navigation_errors(conn: sqlite3.Connection) -> None:
    nav = "Page.content: Unable to retrieve content because the page is navigating and changing the content."
    browser = _flaky_browser([nav, nav, nav], LI_ROUTES)
    src = LinkedinSource(conn, browser_factory=browser.factory())

    async def user_logs_in(_s: float) -> None:
        page = browser.pages[0]
        page._url, page._html = "https://www.linkedin.com/feed/", fixture("linkedin_feed.html")

    assert await src.connect(sleep=user_logs_in, poll=1, timeout=10) is True
    assert db_status(conn, "linkedin")["connected"] is True


async def test_connect_reports_closed_window(conn: sqlite3.Connection) -> None:
    browser = _flaky_browser(["Target page, context or browser has been closed"], LI_ROUTES)
    src = LinkedinSource(conn, browser_factory=browser.factory())
    assert await src.connect(sleep=_no_sleep, poll=1, timeout=10) is False
    st = db_status(conn, "linkedin")
    assert st["connected"] is False and "closed" in st["detail"]


async def test_connect_timeout_message_is_explicit(conn: sqlite3.Connection) -> None:
    src = LinkedinSource(conn, browser_factory=FakeBrowser(routes=LI_ROUTES).factory())
    assert await src.connect(sleep=_no_sleep, poll=1, timeout=2) is False
    assert "Timed out" in db_status(conn, "linkedin")["detail"]


async def test_check_login_uses_headless_factory_and_records(conn: sqlite3.Connection) -> None:
    headless = FakeBrowser(routes=LI_ROUTES)
    window = FakeBrowser(routes=LI_ROUTES)
    src = LinkedinSource(conn, browser_factory=window.factory(), headless_browser_factory=headless.factory())
    assert await src.check_login(sleep=_no_sleep) is True
    assert headless.launches == 1 and window.launches == 0
    assert db_status(conn, "linkedin")["connected"] is True


async def test_check_login_logged_out_and_locked_profile(conn: sqlite3.Connection) -> None:
    out = FakeBrowser(routes=LI_ROUTES, redirects=[(r"/feed", "https://www.linkedin.com/login")])
    src = LinkedinSource(conn, browser_factory=out.factory())
    assert await src.check_login(sleep=_no_sleep, attempts=2) is False
    assert "Not logged in" in db_status(conn, "linkedin")["detail"]

    async def locked() -> FakeBrowser:
        raise RuntimeError("ProcessSingleton: profile in use")

    src2 = LinkedinSource(conn, browser_factory=locked)
    assert await src2.check_login(sleep=_no_sleep) is False
    assert "close the AutoApply Chrome window" in db_status(conn, "linkedin")["detail"]


def db_status(conn: sqlite3.Connection, name: str) -> dict:
    from autoapply.discovery.linkedin import load_source_statuses

    s = load_source_statuses(conn)[name]
    get = s.get if isinstance(s, dict) else lambda k, d=None: getattr(s, k, d)
    return {"connected": bool(get("connected")), "detail": get("detail") or ""}


class _CookieBrowser(FakeBrowser):
    cookie_jar: list = []

    async def cookies(self) -> list:
        return self.cookie_jar


async def test_cookie_login_detection(conn: sqlite3.Connection) -> None:
    """li_at present + not on the login wall = signed in, even when the DOM has no known marker."""
    blank = "<html><body>some redesigned markup</body></html>"
    b = _CookieBrowser(routes=[(r"linkedin\.com/feed", blank)])
    b.cookie_jar = [{"name": "li_at", "domain": ".www.linkedin.com", "value": "x"}]
    src = LinkedinSource(conn, browser_factory=b.factory())
    assert await src.check_login(sleep=_no_sleep, attempts=1) is True

    stale = _CookieBrowser(routes=[(r"linkedin\.com/login", blank)], redirects=[(r"/feed", "https://www.linkedin.com/login")])
    stale.cookie_jar = b.cookie_jar
    assert await LinkedinSource(conn, browser_factory=stale.factory()).check_login(sleep=_no_sleep, attempts=1) is False

    none = _CookieBrowser(routes=[(r"linkedin\.com/feed", blank)])
    none.cookie_jar = []
    assert await LinkedinSource(conn, browser_factory=none.factory()).check_login(sleep=_no_sleep, attempts=1) is False


async def test_failed_session_refunds_daily_budget(conn: sqlite3.Connection, prefs_set: None) -> None:
    class Boom(FakePage):
        async def content(self) -> str:
            raise RuntimeError("unexpected browser failure")

    browser = FakeBrowser(routes=LI_ROUTES)

    async def new_page() -> FakePage:
        return Boom(browser)

    browser.new_page = new_page  # type: ignore[method-assign]
    src = LinkedinSource(conn, browser_factory=browser.factory(), pacer=instant_pacer())
    with pytest.raises(RuntimeError):
        await src.discover(ctx_for(conn))
    assert db.get_source_sessions(conn, "linkedin") == 0


def test_reset_source_sessions(conn: sqlite3.Connection) -> None:
    db.increment_source_sessions(conn, "linkedin")
    db.increment_source_sessions(conn, "linkedin")
    db.reset_source_sessions(conn, "linkedin")
    assert db.get_source_sessions(conn, "linkedin") == 0


def test_skip_tag_is_short_and_human() -> None:
    from autoapply.pipeline import skip_tag

    assert skip_tag("below_threshold", 40, 70) == "match 40 is below your 70"
    assert skip_tag("seniority_mismatch:staff") == "too senior (staff)"
    assert skip_tag("excluded_keyword:crypto") == "excluded keyword 'crypto'"
    assert skip_tag("salary_below_floor") == "salary below your floor"
    assert skip_tag("work_auth:no_sponsorship").startswith("needs work authorization")
    assert skip_tag("something_new") == "something new"


async def test_already_stored_listings_are_not_reread(conn: sqlite3.Connection, prefs_set: None) -> None:
    sink = EventSink()
    browser = FakeBrowser(routes=LI_ROUTES)
    src = LinkedinSource(conn, emit=sink, browser_factory=browser.factory(), pacer=instant_pacer())
    first = await src.discover(ctx_for(conn))
    assert first
    company = db.upsert_company(conn, first[0].company_name)
    for j in first:  # store them as a previous run would have
        c = db.upsert_company(conn, j.company_name)
        db.insert_job(conn, company_id=c.id, source=j.source, title=j.title, location=j.location, apply_url=j.apply_url,
                      source_url=j.source_url, ats=j.ats, external_id=j.external_id, easy_apply=j.easy_apply, raw=j.raw)
    browser2 = FakeBrowser(routes=LI_ROUTES)
    again = await LinkedinSource(conn, emit=sink, browser_factory=browser2.factory(), pacer=instant_pacer()).discover(ctx_for(conn))
    assert again == []
    assert not [u for u in browser2.visited if "/jobs/view/" in u]
