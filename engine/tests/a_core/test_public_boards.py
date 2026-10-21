"""Public ATS boards beyond Greenhouse / Lever / Ashby (Workday, SmartRecruiters, Workable, Recruitee):
detection, board tokens, parsers and sources against respx-mocked APIs (recorded JSON fixtures)."""

from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime, timedelta

import httpx
import pytest
import respx

from autoapply import db
from autoapply.config import Preferences
from autoapply.discovery.base import (
    DiscoveredJob,
    DiscoveryContext,
    detect_ats,
    persist_discovered,
    split_provider_token,
    split_workday_token,
)
from autoapply.discovery.boards import (
    RecruiteeSource,
    SmartRecruitersSource,
    WorkableSource,
    WorkdaySource,
    board_provider,
    is_readable_board,
    read_board,
)
from autoapply.discovery.recruitee import parse_recruitee_offer
from autoapply.discovery.smartrecruiters import parse_smartrecruiters_posting
from autoapply.discovery.suggestions import board_enrichment, board_url
from autoapply.discovery.workable import parse_workable_job
from autoapply.discovery.workday import parse_posted_on, parse_workday_job
from autoapply.enums import Ats, JobSource, RemotePolicy

from .conftest import load_json

WD_TOKEN = "globex.wd5/Globex_Careers"
WD_API = "https://globex.wd5.myworkdayjobs.com/wday/cxs/globex/Globex_Careers"
SR_API = "https://api.smartrecruiters.com/v1/companies/AcmeRobotics/postings"
WK_API = "https://apply.workable.com/api/v3/accounts/acme/jobs"


# =====================================================================================
# detect_ats / board tokens / board_url
# =====================================================================================


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite/job/x_JR1", (Ats.WORKDAY, "nvidia.wd5/NVIDIAExternalCareerSite")),
        ("https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite", (Ats.WORKDAY, "nvidia.wd5/NVIDIAExternalCareerSite")),
        ("https://acme.wd1.myworkdayjobs.com/wday/cxs/acme/External/jobs", (Ats.WORKDAY, "acme.wd1/External")),
        ("https://acme.wd103.myworkdayjobs.com/fr-FR/Careers/details/Role_R1", (Ats.WORKDAY, "acme.wd103/Careers")),
        ("https://acme.wd5.myworkdayjobs.com/job/1", (Ats.WORKDAY, "acme")),  # no site: identity only
        ("https://wd3.myworkdaysite.com/recruiting/acme/Ext/job/1", (Ats.WORKDAY, "acme")),
        ("https://jobs.smartrecruiters.com/BoschGroup/744000156878278-shipping", (Ats.OTHER, "smartrecruiters:BoschGroup")),
        ("https://careers.smartrecruiters.com/Visa", (Ats.OTHER, "smartrecruiters:Visa")),
        ("https://api.smartrecruiters.com/v1/companies/Visa/postings?limit=100", (Ats.OTHER, "smartrecruiters:Visa")),
        ("https://jobs.smartrecruiters.com/oneclick-ui/company/x", (Ats.OTHER, None)),
        ("https://apply.workable.com/huggingface/j/81B46579FE/", (Ats.OTHER, "workable:huggingface")),
        ("https://apply.workable.com/api/v3/accounts/netguru/jobs", (Ats.OTHER, "workable:netguru")),
        ("https://apply.workable.com/j/81B46579FE", (Ats.OTHER, None)),  # short link names no account
        ("https://acme.workable.com/jobs/123", (Ats.OTHER, "workable:acme")),
        ("https://bunq.recruitee.com/o/head-of-product-6", (Ats.OTHER, "recruitee:bunq")),
        ("https://bunq.recruitee.com/api/offers/", (Ats.OTHER, "recruitee:bunq")),
        ("https://www.recruitee.com/pricing", (Ats.OTHER, None)),
    ],
)
def test_detect_ats_new_boards(url: str, expected: tuple[Ats, str | None]) -> None:
    assert detect_ats(url) == expected


def test_token_helpers() -> None:
    assert split_workday_token("nvidia.wd5/Ext") == ("nvidia.wd5.myworkdayjobs.com", "nvidia", "Ext")
    assert split_workday_token("nvidia") is None and split_workday_token("nvidia.prod/Ext") is None
    assert split_provider_token("workable:acme") == ("workable", "acme")
    assert split_provider_token("eu:acme") is None and split_provider_token("acme") is None
    assert board_provider(Ats.WORKDAY, "nvidia.wd5/Ext") == "workday"
    assert board_provider(Ats.WORKDAY, "nvidia") is None  # bare tenant: not readable
    assert board_provider(Ats.OTHER, "recruitee:bunq") == "recruitee"
    assert board_provider(None, "smartrecruiters:Visa") == "smartrecruiters"  # persisted rows keep ats NULL
    assert board_provider("other", "workable:acme") == "workable"
    assert board_provider(Ats.GREENHOUSE, "stripe") == "greenhouse"
    assert board_provider(Ats.GREENHOUSE, "workable:acme") == "greenhouse"  # the ats column wins
    assert not is_readable_board(Ats.OTHER, "acme") and not is_readable_board(Ats.OTHER, None)


@pytest.mark.parametrize(
    ("ats", "token", "url"),
    [
        (Ats.WORKDAY, "nvidia.wd5/NVIDIAExternalCareerSite", "https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite"),
        (Ats.OTHER, "smartrecruiters:BoschGroup", "https://jobs.smartrecruiters.com/BoschGroup"),
        (Ats.OTHER, "workable:huggingface", "https://apply.workable.com/huggingface/"),
        (Ats.OTHER, "recruitee:bunq", "https://bunq.recruitee.com/"),
        (Ats.GREENHOUSE, "stripe", "https://job-boards.greenhouse.io/stripe"),
        (Ats.LEVER, "eu:acme", "https://jobs.eu.lever.co/acme"),
        (Ats.ASHBY, "ramp", "https://jobs.ashbyhq.com/ramp"),
    ],
)
def test_board_url_round_trips(ats: Ats, token: str, url: str) -> None:
    assert board_url(ats, token) == url
    assert detect_ats(url) == (ats, token)


# =====================================================================================
# Parsers
# =====================================================================================


def test_parse_posted_on() -> None:
    now = datetime(2026, 10, 22, tzinfo=UTC)
    assert parse_posted_on("Posted Today", now=now) == now
    assert parse_posted_on("Posted Yesterday", now=now) == now - timedelta(days=1)
    assert parse_posted_on("Posted 3 Days Ago", now=now) == now - timedelta(days=3)
    assert parse_posted_on("Posted 30+ Days Ago", now=now) is None
    assert parse_posted_on(None) is None


def test_parse_workday_job() -> None:
    now = datetime(2026, 10, 22, tzinfo=UTC)
    payments, platform, sales = (parse_workday_job(p, token=WD_TOKEN, company_name="Globex", now=now)
                                 for p in load_json("workday_jobs.json")["jobPostings"])
    assert payments.apply_url == ("https://globex.wd5.myworkdayjobs.com/Globex_Careers/job/India-Bengaluru/"
                                  "Backend-Engineer--Payments_JR2027049")
    assert payments.ats is Ats.WORKDAY and payments.source is JobSource.CAREERS and payments.board_token == WD_TOKEN
    assert payments.external_id == "JR2027049" and payments.location == "India, Bengaluru"
    assert payments.posted_at == now - timedelta(days=2) and payments.remote is None
    assert platform.location == "US CA Santa Clara"  # "2 Locations" -> the place in the posting path
    assert platform.remote is RemotePolicy.HYBRID  # explicit remoteType
    assert sales.remote is RemotePolicy.REMOTE and sales.posted_at is None


def test_parse_smartrecruiters_posting() -> None:
    java, platform, shipping = (parse_smartrecruiters_posting(p, slug="AcmeRobotics")
                                for p in load_json("smartrecruiters_postings.json")["content"])
    assert java.company_name == "Acme Robotics" and java.board_token == "smartrecruiters:AcmeRobotics"
    assert java.ats is Ats.OTHER and java.source is JobSource.CAREERS and java.external_id == "744000156878278"
    assert java.apply_url == "https://jobs.smartrecruiters.com/AcmeRobotics/744000156878278-backend-engineer-java"
    assert java.location == "Bengaluru, KA, India" and java.remote is RemotePolicy.HYBRID
    assert java.posted_at == datetime(2026, 10, 21, 19, 25, 58, 435000, tzinfo=UTC)
    assert platform.location == "de" and platform.remote is RemotePolicy.REMOTE
    assert shipping.remote is None and shipping.raw["department"] is None


def test_parse_workable_job() -> None:
    remote, hybrid = (parse_workable_job(r, slug="acme", company_name="Acme") for r in load_json("workable_jobs_page1.json")["results"])
    (office,) = (parse_workable_job(r, slug="acme") for r in load_json("workable_jobs_page2.json")["results"])
    assert remote.apply_url == "https://apply.workable.com/acme/j/DB4D7C0EC8/" and remote.external_id == "DB4D7C0EC8"
    assert remote.remote is RemotePolicy.REMOTE and remote.location == "France" and remote.board_token == "workable:acme"
    assert hybrid.remote is RemotePolicy.HYBRID and hybrid.location == "Pune, Maharashtra, India · Bengaluru, Karnataka, India"
    assert office.remote is RemotePolicy.ONSITE and office.company_name == "acme"


def test_parse_recruitee_offer() -> None:
    backend, data, warehouse, _closed = (parse_recruitee_offer(o, slug="acme") for o in load_json("recruitee_offers.json")["offers"])
    assert backend.company_name == "Acme Robotics" and backend.board_token == "recruitee:acme"
    assert backend.apply_url.endswith("/c/new") and backend.source_url == "https://careers.acme.example/o/backend-engineer-6"
    assert backend.location == "Amsterdam, Netherlands · Sofia, Bulgaria" and backend.remote is RemotePolicy.HYBRID
    assert (backend.salary_min, backend.salary_max, backend.salary_currency) == (60000, 84000, "EUR")  # monthly annualised
    assert "core banking ledger" in backend.description and "Go, Postgres" in backend.description
    assert backend.posted_at == datetime(2026, 10, 15, 9, 31, 36, tzinfo=UTC)
    assert data.remote is RemotePolicy.REMOTE and data.location == "Germany"
    assert (data.salary_min, data.salary_max, data.salary_currency) == (60000, 80000, "EUR")  # from the text
    assert warehouse.remote is RemotePolicy.ONSITE


# =====================================================================================
# Sources (respx-mocked APIs)
# =====================================================================================


def _company(conn: sqlite3.Connection, name: str, ats: Ats | None, token: str):  # type: ignore[no-untyped-def]
    return db.upsert_company(conn, name, ats=ats, board_token=token, watch=True)


@respx.mock
async def test_workday_source_searches_roles_and_reads_details(conn: sqlite3.Connection) -> None:
    listing = respx.post(f"{WD_API}/jobs").mock(return_value=httpx.Response(200, json=load_json("workday_jobs.json")))
    detail = respx.get(url__startswith=f"{WD_API}/job/").mock(
        return_value=httpx.Response(200, json=load_json("workday_job_detail.json"))
    )
    cs = [_company(conn, "Globex", Ats.WORKDAY, WD_TOKEN), _company(conn, "Bare Tenant", Ats.WORKDAY, "bare")]
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(roles=["Backend Engineer"]), companies=cs, http=http)
        jobs = await WorkdaySource().discover(ctx)
    body = json.loads(listing.calls[0].request.content)
    assert body == {"appliedFacets": {}, "limit": 20, "offset": 0, "searchText": "Backend Engineer"}
    assert listing.call_count == 1  # 3 < page size: one page; the bare-tenant company is not read
    assert [j.title for j in jobs] == ["Backend Engineer, Payments", "Senior Software Engineer, Backend Platform"]
    assert detail.call_count == 2  # only the postings that passed the title filter
    platform = jobs[1]
    assert "5+ years of Go or Java" in platform.description and platform.location == "US, CA, Santa Clara"
    assert platform.posted_at == datetime(2026, 10, 21, tzinfo=UTC) and platform.remote is RemotePolicy.HYBRID
    assert platform.raw["additional_locations"] == ["US, WA, Seattle"] and ctx.errors == {}


@respx.mock
async def test_workday_source_pages_without_roles_and_survives_detail_errors(conn: sqlite3.Connection) -> None:
    page = load_json("workday_jobs.json")
    full = {"total": 23, "jobPostings": [
        {**page["jobPostings"][0], "externalPath": f"/job/X/Role_{i}", "title": f"Engineer {i}"} for i in range(20)
    ]}
    listing = respx.post(f"{WD_API}/jobs").mock(side_effect=[httpx.Response(200, json=full), httpx.Response(200, json=page)])
    respx.get(url__startswith=f"{WD_API}/job/").mock(return_value=httpx.Response(404))
    c = _company(conn, "Globex", Ats.WORKDAY, WD_TOKEN)
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(), companies=[c], http=http)
        jobs = await WorkdaySource(detail_limit=2).discover(ctx)
    assert [json.loads(call.request.content)["offset"] for call in listing.calls] == [0, 20]
    assert len(jobs) == 23 and ctx.errors == {}  # a failing detail keeps the listing


@respx.mock
async def test_smartrecruiters_source(conn: sqlite3.Connection) -> None:
    listing = respx.get(SR_API).mock(return_value=httpx.Response(200, json=load_json("smartrecruiters_postings.json")))
    respx.get(f"{SR_API}/744000156878278").mock(
        return_value=httpx.Response(200, json=load_json("smartrecruiters_posting_detail.json"))
    )
    respx.get(f"{SR_API}/744000156878279").mock(return_value=httpx.Response(404))
    c = _company(conn, "Acme Robotics", Ats.OTHER, "smartrecruiters:AcmeRobotics")
    other = _company(conn, "Elsewhere", Ats.OTHER, "workable:elsewhere")  # another provider: not read here
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(roles=["Backend Engineer", "Platform Engineer"]), companies=[c, other], http=http)
        jobs = await SmartRecruitersSource().discover(ctx)
    params = [dict(call.request.url.params) for call in listing.calls]
    assert params == [{"limit": "100", "offset": "0", "q": "Backend Engineer"}, {"limit": "100", "offset": "0", "q": "Platform Engineer"}]
    assert [j.title for j in jobs] == ["Backend Engineer (Java)", "Platform Engineer"]  # deduped across searches
    java = jobs[0]
    assert java.description.startswith("Job Description\nBuild payment APIs")
    assert (java.salary_min, java.salary_max, java.salary_currency) == (3_000_000, 4_500_000, "INR")
    assert java.apply_url == "https://jobs.smartrecruiters.com/AcmeRobotics/744000156878278-backend-engineer-java-"
    assert jobs[1].description is None and ctx.errors == {}


@respx.mock
async def test_workable_source_follows_next_page(conn: sqlite3.Connection) -> None:
    listing = respx.post(WK_API).mock(side_effect=[
        httpx.Response(200, json=load_json("workable_jobs_page1.json")),
        httpx.Response(200, json=load_json("workable_jobs_page2.json")),
    ])
    respx.get("https://apply.workable.com/api/v2/accounts/acme/jobs/DB4D7C0EC8").mock(
        return_value=httpx.Response(200, json=load_json("workable_job_detail.json"))
    )
    respx.get("https://apply.workable.com/api/v2/accounts/acme/jobs/9E2A4C02C7").mock(return_value=httpx.Response(200, json={}))
    c = _company(conn, "Acme", None, "workable:acme")
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(roles=["Backend Engineer"]), companies=[c], http=http)
        jobs = await WorkableSource().discover(ctx)
    assert listing.call_count == 2
    assert json.loads(listing.calls[1].request.content)["token"] == "WzE3ODkzNDQwMDAwMDAsNjA5NzUyMl0="
    assert [j.title for j in jobs] == ["Senior Backend Engineer - EMEA Remote", "Backend Developer (Python)"]
    assert "Python and Rust" in jobs[0].description and jobs[0].salary_currency == "EUR"


@respx.mock
async def test_recruitee_source_filters_titles(conn: sqlite3.Connection) -> None:
    respx.get("https://acme.recruitee.com/api/offers/").mock(return_value=httpx.Response(200, json=load_json("recruitee_offers.json")))
    respx.get("https://gone.recruitee.com/api/offers/").mock(return_value=httpx.Response(404))
    cs = [_company(conn, "Acme Robotics", Ats.OTHER, "recruitee:acme"), _company(conn, "Gone", Ats.OTHER, "recruitee:gone")]
    async with httpx.AsyncClient() as http:
        ctx = DiscoveryContext(preferences=Preferences(roles=["Backend Engineer", "Data Engineer"]), companies=cs, http=http)
        jobs = await RecruiteeSource().discover(ctx)
        assert [j.title for j in jobs] == ["Backend Engineer", "Data Engineer (Remote)"]
        assert "Gone" in ctx.errors and "404" in ctx.errors["Gone"]
        everything = await read_board(http, Ats.OTHER, "recruitee:acme")
    assert [j.title for j in everything] == ["Backend Engineer", "Data Engineer (Remote)", "Warehouse Lead"]  # closed skipped


async def test_read_board_rejects_unreadable_tokens() -> None:
    async with httpx.AsyncClient() as http:
        with pytest.raises(ValueError):
            await read_board(http, Ats.WORKDAY, "bare")
        with pytest.raises(ValueError):
            await read_board(http, Ats.OTHER, "acme")


# =====================================================================================
# Watchlist learning (Google Jobs listings -> auto-watch)
# =====================================================================================


def _google(company: str, url: str) -> DiscoveredJob:
    ats, token = detect_ats(url)
    return DiscoveredJob(source=JobSource.GOOGLE, company_name=company, title="Backend Engineer", apply_url=url, ats=ats, board_token=token)


@pytest.mark.parametrize(
    ("url", "ats", "token"),
    [
        ("https://acme.wd5.myworkdayjobs.com/en-US/External/job/Bengaluru/Backend_R1", Ats.WORKDAY, "acme.wd5/External"),
        ("https://jobs.smartrecruiters.com/Acme/7431-backend-engineer", Ats.OTHER, "smartrecruiters:Acme"),
        ("https://apply.workable.com/acme/j/AB12CD/", Ats.OTHER, "workable:acme"),
        ("https://acme.recruitee.com/o/backend-engineer", Ats.OTHER, "recruitee:acme"),
    ],
)
def test_board_enrichment_watches_new_boards(conn: sqlite3.Connection, url: str, ats: Ats, token: str) -> None:
    enrich, auto = board_enrichment(conn, _google("Acme", url), room=True)
    assert auto and enrich == {"ats": ats, "board_token": token, "watch": True}
    company = db.upsert_company(conn, "Acme", **enrich)  # what the pipeline does next: no CHECK violation
    assert company.watch and board_provider(company.ats, company.board_token) is not None


def test_board_enrichment_skips_unreadable_workday(conn: sqlite3.Connection) -> None:
    enrich, auto = board_enrichment(conn, _google("Acme", "https://acme.wd5.myworkdayjobs.com/job/1"), room=True)
    assert (enrich, auto) == ({}, False)


def test_persist_discovered_keeps_provider_token(conn: sqlite3.Connection) -> None:
    dj = parse_workable_job(load_json("workable_jobs_page1.json")["results"][0], slug="acme", company_name="Acme")
    [(job, created)] = persist_discovered(conn, [dj])
    company = db.get_company(conn, job.company_id)
    assert created and job.ats is Ats.OTHER and job.source is JobSource.CAREERS
    assert company.ats is None and company.board_token == "workable:acme"
    assert board_provider(company.ats, company.board_token) == "workable"


# =====================================================================================
# Company finder (Google result links -> readable boards)
# =====================================================================================


def test_company_finder_reads_new_board_links() -> None:
    from autoapply.discovery.company_finder import ATS_SITES, BoardHit, company_name_for, parse_board_results

    html = """<html><body>
    <a href="/url?q=https://acme.wd5.myworkdayjobs.com/en-US/External/job/Pune/Backend_R1&sa=U"><h3>Backend Engineer - Acme</h3></a>
    <a href="https://jobs.smartrecruiters.com/Globex/7431-backend"><h3>Backend Engineer</h3></a>
    <a href="https://apply.workable.com/initech/j/AB12CD/"><h3>Backend Engineer - Initech</h3></a>
    <a href="https://hooli.recruitee.com/o/backend"><h3>Backend Engineer</h3></a>
    <a href="https://acme.wd5.myworkdayjobs.com/job/1"><h3>no site: not readable</h3></a>
    <a href="https://apply.workable.com/j/ZZ99"><h3>short link: no account</h3></a>
    </body></html>"""
    hits = parse_board_results(html, "q")
    assert [(h.ats, h.token) for h in hits] == [
        (Ats.WORKDAY, "acme.wd5/External"), (Ats.OTHER, "smartrecruiters:Globex"),
        (Ats.OTHER, "workable:initech"), (Ats.OTHER, "recruitee:hooli"),
    ]
    assert company_name_for(BoardHit(Ats.OTHER, "recruitee:hooli-labs", ""), []) == "Hooli Labs"
    assert company_name_for(BoardHit(Ats.WORKDAY, "acme.wd5/External", ""), []) == "Acme"
    assert {site for _, site in ATS_SITES} >= {"myworkdayjobs.com", "jobs.smartrecruiters.com", "apply.workable.com", "recruitee.com"}
