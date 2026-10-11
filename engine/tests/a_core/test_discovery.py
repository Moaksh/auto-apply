"""Discovery: ATS detection, parsers, sources against respx-mocked board APIs, persistence."""

from __future__ import annotations

from datetime import UTC, datetime

import httpx
import pytest
import respx

from autoapply import db
from autoapply.config import Preferences
from autoapply.discovery.ashby import AshbySource, parse_ashby_job
from autoapply.discovery.base import (
    DiscoveryContext,
    detect_ats,
    extract_job_id,
    html_to_text,
    infer_remote,
    parse_salary_text,
    persist_discovered,
    title_matches_roles,
)
from autoapply.discovery.careers import CareersSource, add_to_watchlist, find_ats_boards, learn_board_tokens
from autoapply.discovery.greenhouse import (
    GreenhouseSource,
    fetch_greenhouse_questions,
    parse_greenhouse_job,
    parse_greenhouse_questions,
)
from autoapply.discovery.lever import LeverSource
from autoapply.enums import Ats, FieldType, JobSource, RemotePolicy

from .conftest import FIXTURES, load_json

GH_API = "https://boards-api.greenhouse.io/v1/boards"


# =====================================================================================
# detect_ats
# =====================================================================================


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("https://boards.greenhouse.io/stripe/jobs/123", (Ats.GREENHOUSE, "stripe")),
        ("https://job-boards.greenhouse.io/gitlab/jobs/8860302002", (Ats.GREENHOUSE, "gitlab")),
        ("https://job-boards.eu.greenhouse.io/acme/jobs/1", (Ats.GREENHOUSE, "acme")),
        ("https://boards.greenhouse.io/embed/job_app?for=figma&token=555", (Ats.GREENHOUSE, "figma")),
        ("https://boards-api.greenhouse.io/v1/boards/airbnb/jobs?content=true", (Ats.GREENHOUSE, "airbnb")),
        ("https://stripe.com/jobs/listing/x?gh_jid=123", (Ats.GREENHOUSE, None)),
        ("https://jobs.lever.co/palantir/6ed76ce8-4156/apply", (Ats.LEVER, "palantir")),
        ("https://jobs.eu.lever.co/acme/123", (Ats.LEVER, "eu:acme")),
        ("https://api.lever.co/v0/postings/netflix?mode=json", (Ats.LEVER, "netflix")),
        ("https://jobs.ashbyhq.com/ramp/34413f8d/application", (Ats.ASHBY, "ramp")),
        ("https://api.ashbyhq.com/posting-api/job-board/linear", (Ats.ASHBY, "linear")),
        ("https://www.notion.so/careers?ashby_jid=abc", (Ats.ASHBY, None)),
        ("https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite/job/x_JR1", (Ats.WORKDAY, "nvidia")),
        ("https://www.linkedin.com/jobs/view/123", (Ats.OTHER, None)),
        ("", (Ats.OTHER, None)),
        (None, (Ats.OTHER, None)),
        ("not a url", (Ats.OTHER, None)),
    ],
)
def test_detect_ats(url: str | None, expected: tuple[Ats, str | None]) -> None:
    assert detect_ats(url) == expected


def test_extract_job_id() -> None:
    assert extract_job_id("https://boards.greenhouse.io/stripe/jobs/123") == "123"
    assert extract_job_id("https://x.com/careers?gh_jid=987") == "987"
    assert extract_job_id("https://jobs.lever.co/acme/uuid-1/apply") == "uuid-1"
    assert extract_job_id("https://jobs.ashbyhq.com/ramp/uuid-2") == "uuid-2"
    assert extract_job_id("https://example.com/") is None


# =====================================================================================
# normalisation helpers
# =====================================================================================


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("The base salary range is $170,000 - $210,000 USD.", (170000, 210000, "USD")),
        ("$211.4K – $290.6K • Offers Equity", (211400, 290600, "USD")),
        ("USD 120k-150k", (120000, 150000, "USD")),
        ("Salary: €70.000 – €90.000 per year.", (70000, 90000, "EUR")),
        ("CTC ₹30L - ₹45L", (3000000, 4500000, "INR")),
        ("Pay: $60 - $80 per hour.", (124800, 166400, "USD")),
        ("CA$150K - CA$190K", (150000, 190000, "CAD")),
        ("Requires 3-5 years of experience", (None, None, None)),
        ("", (None, None, None)),
    ],
)
def test_parse_salary_text(text: str, expected: tuple) -> None:
    assert parse_salary_text(text) == expected


def test_infer_remote() -> None:
    assert infer_remote("Remote - US") is RemotePolicy.REMOTE
    assert infer_remote("Berlin", "Frontend Engineer (Hybrid)") is RemotePolicy.HYBRID
    assert infer_remote("New York, NY") is None
    assert infer_remote(explicit="on-site") is RemotePolicy.ONSITE
    assert infer_remote(explicit="OnSite") is RemotePolicy.ONSITE
    assert infer_remote(explicit="Remote") is RemotePolicy.REMOTE


def test_html_to_text_unescapes_greenhouse_content() -> None:
    txt = html_to_text("&lt;p&gt;Hello&lt;/p&gt;&lt;ul&gt;&lt;li&gt;Go&lt;/li&gt;&lt;li&gt;SQL&lt;/li&gt;&lt;/ul&gt;", unescape_first=True)
    assert "Hello" in txt and "• Go" in txt and "• SQL" in txt and "<" not in txt


@pytest.mark.parametrize(
    ("title", "roles", "ok"),
    [
        ("Senior Software Engineer, Backend", ["Backend Engineer"], True),
        ("Back End Developer", ["Backend Engineer"], True),
        ("Staff Platform Engineer", ["Backend Engineer"], True),
        ("Account Executive", ["Backend Engineer"], False),
        ("Machine Learning Engineer", ["ML Engineer"], True),
        ("Anything", [], True),
        ("Product Designer", ["Backend Engineer", "Product Designer"], True),
    ],
)
def test_title_matches_roles(title: str, roles: list[str], ok: bool) -> None:
    assert title_matches_roles(title, roles) is ok


# =====================================================================================
# Parsers
# =====================================================================================


def test_parse_greenhouse_job() -> None:
    data = load_json("greenhouse_board.json")["jobs"][0]
    j = parse_greenhouse_job(data, token="acmerobotics", company_name="Acme Robotics")
    assert j.source is JobSource.GREENHOUSE and j.ats is Ats.GREENHOUSE
    assert j.title == "Senior Backend Engineer"
    assert j.location == "Remote - US" and j.remote is RemotePolicy.REMOTE
    assert (j.salary_min, j.salary_max, j.salary_currency) == (170000, 210000, "USD")
    assert j.external_id == "4012345002" and j.board_token == "acmerobotics"
    assert j.posted_at is not None and j.posted_at.tzinfo is not None
    assert "Design Go services" in (j.description or "") and "&lt;" not in (j.description or "")
    assert j.raw["hosted_url"] == "https://job-boards.greenhouse.io/acmerobotics/jobs/4012345002"
    assert j.dedupe_key() == "acme robotics|senior backend engineer|remote us"


def test_parse_greenhouse_questions_covers_all_blocks() -> None:
    qs = parse_greenhouse_questions(load_json("greenhouse_job_questions.json"))
    by_key = {q.key: q for q in qs}
    assert list(by_key)[:4] == ["first_name", "last_name", "email", "phone"]
    assert by_key["email"].field_type is FieldType.EMAIL
    assert by_key["phone"].field_type is FieldType.PHONE and not by_key["phone"].required
    assert by_key["resume"].field_type is FieldType.FILE and by_key["resume"].required
    assert by_key["question_1001"].field_type is FieldType.URL  # LinkedIn
    assert by_key["question_1002"].field_type is FieldType.TEXTAREA and by_key["question_1002"].description == "Max 500 words."
    assert by_key["question_1003"].options == ["Yes", "No"] and by_key["question_1003"].field_type is FieldType.SELECT
    assert "question_1005" not in by_key  # input_hidden dropped
    assert by_key["gender"].options[-1] == "Decline To Self Identify"
    assert by_key["veteran_status"].field_type is FieldType.SELECT
    assert by_key["demographic_77"].field_type is FieldType.MULTISELECT and "they/them" in by_key["demographic_77"].options


def test_parse_ashby_job_compensation_and_remote() -> None:
    data = load_json("ashby_board.json")["jobs"][0]
    j = parse_ashby_job(data, org="acmerobotics", company_name="Acme Robotics")
    assert j.title == "Data Engineer"  # stripped
    assert j.remote is RemotePolicy.HYBRID
    assert (j.salary_min, j.salary_max, j.salary_currency) == (211400, 290600, "USD")
    assert j.apply_url.endswith("/application")
    assert j.raw["secondary_locations"] == ["Remote (US)"]
    ml = parse_ashby_job(load_json("ashby_board.json")["jobs"][2], org="acmerobotics")
    assert (ml.salary_min, ml.salary_max, ml.salary_currency) == (150000, 190000, "CAD")
    assert ml.remote is RemotePolicy.REMOTE


# =====================================================================================
# Sources (respx)
# =====================================================================================


def _company(conn, name: str, ats: Ats, token: str):  # type: ignore[no-untyped-def]
    return db.upsert_company(conn, name, ats=ats, board_token=token, watch=True)


@respx.mock
async def test_greenhouse_source(conn) -> None:  # type: ignore[no-untyped-def]
    respx.get(f"{GH_API}/acmerobotics/jobs", params={"content": "true"}).mock(
        return_value=httpx.Response(200, json=load_json("greenhouse_board.json"))
    )
    c = _company(conn, "Acme Robotics", Ats.GREENHOUSE, "acmerobotics")
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(), companies=[c], http=http)
        jobs = await GreenhouseSource().discover(ctx)
    assert [j.title for j in jobs] == ["Senior Backend Engineer", "Frontend Engineer (Hybrid)", "Account Executive"]
    assert jobs[1].salary_currency == "EUR" and jobs[1].remote is RemotePolicy.HYBRID
    assert all(j.company_name == "Acme Robotics" for j in jobs)
    assert ctx.errors == {}


@respx.mock
async def test_role_filter_and_limit(conn) -> None:  # type: ignore[no-untyped-def]
    respx.get(f"{GH_API}/acmerobotics/jobs").mock(return_value=httpx.Response(200, json=load_json("greenhouse_board.json")))
    c = _company(conn, "Acme Robotics", Ats.GREENHOUSE, "acmerobotics")
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(roles=["Backend Engineer", "Frontend Engineer"]), companies=[c], http=http)
        jobs = await GreenhouseSource().discover(ctx)
        assert [j.title for j in jobs] == ["Senior Backend Engineer", "Frontend Engineer (Hybrid)"]
        ctx2 = DiscoveryContext(preferences=Preferences(roles=["Backend Engineer"]), companies=[c], http=http, limit_per_company=1,
                                filter_roles=False)
        assert len(await GreenhouseSource().discover(ctx2)) == 1


@respx.mock
async def test_failing_company_is_skipped_not_raised(conn) -> None:  # type: ignore[no-untyped-def]
    respx.get(f"{GH_API}/good/jobs").mock(return_value=httpx.Response(200, json=load_json("greenhouse_board.json")))
    respx.get(f"{GH_API}/gone/jobs").mock(return_value=httpx.Response(404, json={"status": 404}))
    flaky = respx.get(f"{GH_API}/flaky/jobs").mock(
        side_effect=[httpx.Response(503), httpx.Response(200, json={"jobs": [], "meta": {"total": 0}})]
    )
    cs = [_company(conn, "Good Co", Ats.GREENHOUSE, "good"), _company(conn, "Gone Co", Ats.GREENHOUSE, "gone"),
          _company(conn, "Flaky Co", Ats.GREENHOUSE, "flaky")]
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(), companies=cs, http=http)
        jobs = await GreenhouseSource().discover(ctx)
    assert len(jobs) == 3 and {j.company_name for j in jobs} == {"Good Co"}
    assert "Gone Co" in ctx.errors and "404" in ctx.errors["Gone Co"]
    assert flaky.call_count == 2 and "Flaky Co" not in ctx.errors  # retried after 503


@respx.mock
async def test_lever_source(conn) -> None:  # type: ignore[no-untyped-def]
    route = respx.get("https://api.lever.co/v0/postings/acmerobotics", params={"mode": "json"}).mock(
        return_value=httpx.Response(200, json=load_json("lever_postings.json"))
    )
    eu = respx.get("https://api.eu.lever.co/v0/postings/euco").mock(return_value=httpx.Response(200, json=[]))
    cs = [_company(conn, "Acme Robotics", Ats.LEVER, "acmerobotics"), _company(conn, "EU Co", Ats.LEVER, "eu:euco"),
          _company(conn, "Not Lever", Ats.GREENHOUSE, "x")]
    async with httpx.AsyncClient() as http:
        jobs = await LeverSource().discover(DiscoveryContext(preferences=Preferences(), companies=cs, http=http))
    assert route.called and eu.called
    platform, contract, office = jobs
    assert platform.title == "Platform Engineer" and platform.remote is RemotePolicy.HYBRID
    assert (platform.salary_min, platform.salary_max, platform.salary_currency) == (160000, 200000, "USD")
    assert "5+ years with Kubernetes" in platform.description and platform.apply_url.endswith("/apply")
    assert platform.raw["all_locations"] == ["San Francisco, CA", "New York, NY"]
    assert platform.posted_at == datetime.fromtimestamp(1786469891368 / 1000, tz=UTC)
    assert contract.remote is RemotePolicy.REMOTE and contract.salary_min == 60 * 2080  # hourly annualised
    assert office.remote is RemotePolicy.ONSITE


@respx.mock
async def test_ashby_source_skips_unlisted(conn) -> None:  # type: ignore[no-untyped-def]
    respx.get("https://api.ashbyhq.com/posting-api/job-board/acmerobotics", params={"includeCompensation": "true"}).mock(
        return_value=httpx.Response(200, json=load_json("ashby_board.json"))
    )
    c = _company(conn, "Acme Robotics", Ats.ASHBY, "acmerobotics")
    async with httpx.AsyncClient() as http:
        jobs = await AshbySource().discover(DiscoveryContext(preferences=Preferences(), companies=[c], http=http))
    assert [j.title for j in jobs] == ["Data Engineer", "ML Engineer"]


async def test_greenhouse_questions_fetch() -> None:
    with respx.mock:
        respx.get(f"{GH_API}/acmerobotics/jobs/4012345002", params={"questions": "true", "pay_transparency": "true"}).mock(
            return_value=httpx.Response(200, json=load_json("greenhouse_job_questions.json"))
        )
        async with httpx.AsyncClient() as http:
            qs = await fetch_greenhouse_questions(http, "acmerobotics", "4012345002")
    assert len(qs) == 13


# =====================================================================================
# Career pages + watchlist
# =====================================================================================


def test_find_ats_boards_in_careers_page() -> None:
    html = (FIXTURES / "careers_page.html").read_text()
    boards, others = find_ats_boards(html, "https://globex.example/careers")
    assert boards == {(Ats.GREENHOUSE, "globex"), (Ats.ASHBY, "globexlabs")}
    assert others == [(
        "https://globex.wd5.myworkdayjobs.com/en-US/Globex_Careers/job/Austin-TX/Site-Reliability-Engineer_R123",
        "Site Reliability Engineer",
    )]


@respx.mock
async def test_careers_source(conn) -> None:  # type: ignore[no-untyped-def]
    respx.get("https://globex.example/careers").mock(
        return_value=httpx.Response(200, text=(FIXTURES / "careers_page.html").read_text())
    )
    respx.get(f"{GH_API}/globex/jobs").mock(return_value=httpx.Response(200, json=load_json("greenhouse_board.json")))
    respx.get("https://api.ashbyhq.com/posting-api/job-board/globexlabs").mock(
        return_value=httpx.Response(200, json=load_json("ashby_board.json"))
    )
    lever_board = respx.get("https://api.lever.co/v0/postings/acmerobotics").mock(
        return_value=httpx.Response(200, json=load_json("lever_postings.json"))
    )
    prefs = Preferences(career_page_urls=["https://globex.example/careers", "https://jobs.lever.co/acmerobotics"])
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=prefs, companies=[], http=http)
        jobs = await CareersSource().discover(ctx)
    assert lever_board.called  # ATS board URL fetched directly, no page load
    assert all(j.source is JobSource.CAREERS for j in jobs)
    companies = {j.company_name for j in jobs}
    assert "Globex" in companies  # derived from the career page domain
    sre = [j for j in jobs if j.ats is Ats.WORKDAY]
    assert len(sre) == 1 and sre[0].title == "Site Reliability Engineer" and sre[0].board_token == "globex"
    assert len(jobs) == 3 + 2 + 3 + 1
    assert ctx.errors == {}


@respx.mock
async def test_careers_source_skips_boards_already_watched(conn) -> None:  # type: ignore[no-untyped-def]
    page = respx.get("https://globex.example/careers").mock(
        return_value=httpx.Response(200, text=(FIXTURES / "careers_page.html").read_text())
    )
    gh = respx.get(f"{GH_API}/globex/jobs").mock(return_value=httpx.Response(200, json=load_json("greenhouse_board.json")))
    respx.get("https://api.ashbyhq.com/posting-api/job-board/globexlabs").mock(return_value=httpx.Response(500))
    c = db.upsert_company(conn, "Globex", ats=Ats.GREENHOUSE, board_token="globex", careers_url="https://globex.example/careers", watch=True)
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(), companies=[c], http=http)
        jobs = await CareersSource().discover(ctx)
    assert page.called and not gh.called  # greenhouse source covers it
    assert [j.ats for j in jobs] == [Ats.WORKDAY]
    assert any("globexlabs" in k for k in ctx.errors)  # failing ashby board recorded, not raised


def test_add_to_watchlist(conn) -> None:  # type: ignore[no-untyped-def]
    a = add_to_watchlist(conn, "Stripe", "https://boards.greenhouse.io/stripe/jobs/1")
    assert (a.ats, a.board_token, a.watch) == (Ats.GREENHOUSE, "stripe", True)
    b = add_to_watchlist(conn, "Ramp", "ramp", ats=Ats.ASHBY)
    assert (b.ats, b.board_token) == (Ats.ASHBY, "ramp")
    c = add_to_watchlist(conn, "Globex", "https://globex.example/careers")
    assert c.ats is None and c.careers_url == "https://globex.example/careers" and c.domain == "globex.example"
    with pytest.raises(ValueError):
        add_to_watchlist(conn, "X", "token-only")
    assert {x.name for x in db.list_companies(conn, watch_only=True)} == {"Stripe", "Ramp", "Globex"}


def test_learn_board_tokens_never_sets_watch(conn) -> None:  # type: ignore[no-untyped-def]
    out = learn_board_tokens(conn, [("Linear", "https://jobs.ashbyhq.com/linear/1"), ("Nowhere", "https://example.com/x")])
    assert len(out) == 1 and out[0].ats is Ats.ASHBY and out[0].board_token == "linear" and not out[0].watch


# =====================================================================================
# Persistence
# =====================================================================================


def test_persist_discovered_dedupes_and_learns_company(conn) -> None:  # type: ignore[no-untyped-def]
    data = load_json("greenhouse_board.json")["jobs"]
    jobs = [parse_greenhouse_job(d, token="acmerobotics") for d in data]
    first = persist_discovered(conn, jobs)
    assert [created for _, created in first] == [True, True, True]
    again = persist_discovered(conn, jobs)
    assert [created for _, created in again] == [False, False, False]
    company = db.get_company_by_name(conn, "Acme Robotics")
    assert company.ats is Ats.GREENHOUSE and company.board_token == "acmerobotics" and not company.watch
    job, _ = first[0]
    assert job.salary_min == 170000 and job.remote is RemotePolicy.REMOTE
    assert db.get_application_by_job(conn, job.id).state.value == "discovered"
