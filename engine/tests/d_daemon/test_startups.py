"""Startups near you through the daemon: YC's directory (recorded responses, respx), the Google
fallback when the search key is refused, funding news verified against the article, the batch
"find people at the top N" with its guardrails, and location referrals with imported LinkedIn
connections. No network, browser or real model."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import httpx
import pytest
import respx
from pydantic import ValidationError

from autoapply import db
from autoapply.enums import FundingStage, ProspectStatus, ReferralBasis, ScoutPurpose
from autoapply.models import ScoutTopProspectsPayload
from autoapply.outreach import contacts, facts, prospects, referrals
from autoapply.paths import Paths
from tests.d_daemon.test_outreach import World, _browser, _no_sleep, _Page
from tests.outreach_fakes import seed_profile, seed_submitted_application

FIX = Path(__file__).resolve().parents[1] / "fixtures" / "startups"
ALGOLIA = "https://45bwzj1sgc-dsn.algolia.net/1/indexes/*/queries"
YC = "https://www.ycombinator.com/companies"


def fx(name: str) -> str:
    return (FIX / name).read_text(encoding="utf-8")


@pytest.fixture
async def world(autoapply_home: Paths):
    w = World(autoapply_home)
    w.daemon.outreach.sleep = _no_sleep  # YC pacing without real waits
    seed_profile(w.conn)
    db.update_profile(w.conn, {"location": "Bengaluru, India"})
    db.update_preferences(w.conn, {"roles": ["Backend Engineer"]})
    try:
        yield w
    finally:
        await w.daemon.stop()


def _lab0_page() -> str:
    """The recorded Groww page, as Lab0's: two founders and a backend role."""
    html = fx("yc_company_page.html")
    return (html.replace("groww", "lab0").replace("Groww", "Lab0").replace("React Native Developer", "Backend Engineer"))


def _mock_yc(*, hits: dict | None = None, algolia_status: int = 200) -> respx.Route:
    respx.get(YC).respond(200, html=fx("yc_companies_page.html"))
    route = respx.post(ALGOLIA).mock(return_value=httpx.Response(algolia_status, json=hits if hits is not None
                                                                 else json.loads(fx("yc_algolia_india.json"))))
    respx.get(f"{YC}/lab0").respond(200, html=_lab0_page())
    respx.get(url__regex=r"https://www\.ycombinator\.com/companies/(kailash-labs|waybill|bentolabs-ai)").respond(404)
    return route


def _serp(*results: tuple[str, str, str]) -> str:
    """Google-like results; each snippet is long enough to be found in its own result block."""
    pad = " · result text shown under the title on the results page"
    return "<div>" + "".join(f'<div><a href="{u}"><h3>{t}</h3></a><span>{s}{pad}</span></div>' for t, u, s in results) + "</div>"


def _prospect(conn, name: str) -> tuple[Any, Any]:
    co = db.get_company_by_name(conn, name)
    return prospects.get_by_company(conn, co.id), facts.get(conn, co.id)


@respx.mock
async def test_yc_directory_startups_land_with_facts_and_a_rank(world: World):
    route = _mock_yc()
    world.llm.add_rule(r"how good a target", {"score": 80, "summary": "Backend + infra"})
    res = await world.ok("discover_startups", {"yc_only": True, "limit": 10})
    assert res["location"] == "Bengaluru, India" and res["queued_google"] is False and res["search_id"]
    await world.drain()
    names = {r[0] for r in world.conn.execute("SELECT c.name FROM prospects p JOIN companies c ON c.id = p.company_id")}
    assert names == {"Kailash Labs", "Waybill", "BentoLabs AI", "Lab0"}
    p, f = _prospect(world.conn, "Lab0")
    assert (f.yc_batch, f.team_size, f.is_hiring, f.hq_city, f.hq_country) == ("X26", 7, True, "Bengaluru", "India")
    assert f.yc_url == f"{YC}/lab0" and f.sources["yc_batch"]["url"] == f"{YC}/lab0"
    assert [x["name"] for x in f.founders][:1] == ["Lalit Keshre"] and f.open_roles == 2
    assert p.found_via == "startups" and p.search_query == "Bengaluru, India" and p.matching_roles == 1
    assert p.fit_score == 80 and p.startup_score is not None and p.rank_score is not None
    assert any(r["reason"] == "YC X26" for r in p.startup_reasons)
    assert db.get_company_by_name(world.conn, "Lab0").domain == "lab0.ai"
    # The key and the results are cached: a second search reads neither the page nor the index again.
    calls = route.call_count
    await world.ok("discover_startups", {"yc_only": True, "limit": 10})
    await world.drain()
    assert route.call_count == calls
    body = json.loads(route.calls[0].request.content)
    params = body["requests"][0]["params"]
    assert "regions%3AIndia" in params and "status%3AActive" in params and "hitsPerPage=40" in params
    assert route.calls[0].request.headers["user-agent"].startswith("AutoApply/")
    s = prospects.get_search(world.conn, res["search_id"])
    assert s["status"] == "done" and s["found"] == 4


@respx.mock
async def test_dismissed_and_existing_companies_are_not_duplicated(world: World):
    _mock_yc()
    existing = db.upsert_company(world.conn, "Lab Zero Inc", domain="lab0.ai")  # same domain, other name
    gone = db.upsert_company(world.conn, "Waybill")
    prospects.upsert(world.conn, gone.id, status=ProspectStatus.DISMISSED)
    db.update_preferences(world.conn, {"exclude_companies": ["Kailash Labs"]})
    await world.ok("discover_startups", {"yc_only": True})
    await world.drain()
    rows = world.conn.execute("SELECT c.name, p.status FROM prospects p JOIN companies c ON c.id = p.company_id ORDER BY c.name").fetchall()
    assert [tuple(r) for r in rows] == [("BentoLabs AI", "suggested"), ("Lab Zero Inc", "suggested"), ("Waybill", "dismissed")]
    assert facts.get(world.conn, existing.id).yc_batch == "X26"
    assert world.conn.execute("SELECT COUNT(*) FROM companies WHERE domain = 'lab0.ai'").fetchone()[0] == 1


async def test_a_location_without_a_country_is_refused(world: World):
    r = await world.cmd("discover_startups", {"location": "Atlantis"})
    assert r["type"] == "error" and r["code"] == "invalid_payload" and "country" in r["message"]


@respx.mock
async def test_refused_key_falls_back_to_yc_pages_found_on_google(world: World):
    _mock_yc(algolia_status=403)
    page = _Page({"google.com/search": _serp(("Lab0 | Y Combinator", f"{YC}/lab0", "Lab0 builds ... Bengaluru"),
                                              ("Startup lists", "https://www.ycombinator.com/companies/industry/fintech", "x"))})
    world.daemon.outreach._browser_factory = _browser(page)
    res = await world.ok("discover_startups", {"yc_only": True})
    await world.drain()
    s = prospects.get_search(world.conn, res["search_id"])
    assert s["yc_fallback"] is True and s["status"] == "queued"
    assert world.conn.execute("SELECT COUNT(*) FROM prospects").fetchone()[0] == 0
    done = await world.daemon.outreach.run_google_work()
    assert done["searches"] == 1
    p, f = _prospect(world.conn, "Lab0")
    assert p is not None and f.yc_batch == "W18" and f.founders
    assert len(page.visited) == 1 and "ycombinator.com%2Fcompanies" in page.visited[0]
    assert all(u.startswith("https://www.google.com/search") for u in page.visited)


@respx.mock
async def test_funding_news_keeps_only_verified_facts(world: World):
    _mock_yc(hits={"results": [{"hits": [], "nbPages": 0}]})
    article = "https://news.example/funding-galore"
    page = _Page({"google.com/search": _serp(("Funding Galore", article, "Kolam Data, Nimbu Health raise"))})
    world.daemon.outreach._browser_factory = _browser(page)
    respx.get(article).respond(200, html=fx("funding_article.html"))
    respx.get("https://kolamdata.example/").respond(200, html='<meta name="description" content="Data pipelines for banks.">')
    world.llm.add_rule(r"List the startups this article", {"rounds": [
        {"company": "Kolam Data", "website": "https://kolamdata.example", "round": "Seed", "amount_text": "$4 million",
         "investors": ["Peak XV Partners", "Blume Ventures"], "city": "Chennai",
         "quote": "Chennai-based Kolam Data has raised $4 million in a seed round led by Peak XV Partners"},
        {"company": "Nimbu Health", "round": "Series A", "amount_text": "Rs 35 crore", "investors": ["Lightbox"],
         "city": "Bengaluru", "quote": "Healthtech startup Nimbu Health raised Rs 35 crore in its Series A round from Lightbox"},
        {"company": "Imaginary Corp", "round": "Seed", "amount_text": "$1 million", "quote": "Imaginary Corp raised $1 million"},
    ]})
    world.llm.add_rule(r"how good a target", {"score": 70, "summary": "data infra"})
    res = await world.ok("discover_startups", {"stages": ["seed", "series_a"]})
    assert res["queued_google"] is True
    await world.drain()
    done = await world.daemon.outreach.run_google_work()
    assert done["searches"] == 1
    p, f = _prospect(world.conn, "Kolam Data")
    assert (f.last_round_stage, f.last_round_amount, f.last_round_currency, f.last_round_date) == (
        FundingStage.SEED, 4e6, "USD", "2026-08-14")
    assert f.investors == ["Peak XV Partners", "Blume Ventures"] and (f.hq_city, f.hq_country) == ("Chennai", "India")
    assert f.sources["last_round_amount"] == {**f.sources["last_round_amount"], "url": article}
    assert "raised $4 million" in f.sources["last_round_amount"]["quote"]
    assert p.summary == "Data pipelines for banks." and p.fit_reasons["evidence_url"] == article
    assert p.startup_score and any("Peak XV Partners" in r["reason"] for r in p.startup_reasons)
    _n, nf = _prospect(world.conn, "Nimbu Health")
    assert (nf.last_round_stage, nf.last_round_currency) == (FundingStage.SERIES_A, "INR")
    assert db.get_company_by_name(world.conn, "Imaginary Corp") is None
    # 3 funding-news queries, each a Google result page; the article was fetched over HTTP, never in the browser.
    assert len(page.visited) == 3 and all(u.startswith("https://www.google.com/search") for u in page.visited)
    assert prospects.get_search(world.conn, res["search_id"])["status"] == "done"


async def test_find_people_at_the_top_n_respects_the_guardrails(world: World, monkeypatch):
    scouted: list[tuple[int, ScoutPurpose]] = []

    async def fake_scout(company_id, purpose, **kw):
        scouted.append((company_id, purpose))

    monkeypatch.setattr(world.daemon.outreach, "scout_and_draft", fake_scout)
    ids = {}
    for name, fit in (("Lab0", 90), ("Kolam Data", 85), ("Acme", 80), ("Nimbu Health", 60), ("Waybill", 40)):
        co = db.upsert_company(world.conn, name)
        ids[name] = co.id
        prospects.upsert(world.conn, co.id, fit_score=fit)
    seed_submitted_application(world.conn)  # Acme: applied -> an application follow-up instead
    db.update_preferences(world.conn, {"exclude_companies": ["Kolam Data"]})
    res = await world.ok("scout_top_prospects", {"limit": 2})
    assert [q["company"] for q in res["queued"]] == ["Lab0", "Nimbu Health"]
    assert {s["company"]: s["reason"] for s in res["skipped"]} == {
        "Kolam Data": "Kolam Data is on your excluded companies",
        "Acme": "you applied to Acme: use an application follow-up instead"}
    await world.drain()
    assert scouted == [(ids["Lab0"], ScoutPurpose.PROSPECT), (ids["Nimbu Health"], ScoutPurpose.PROSPECT)]
    assert prospects.get_by_company(world.conn, ids["Lab0"]).status is ProspectStatus.SHORTLISTED
    assert prospects.get_by_company(world.conn, ids["Waybill"]).status is ProspectStatus.SUGGESTED
    with pytest.raises(ValidationError):
        ScoutTopProspectsPayload(limit=11)


async def test_location_referrals_and_connections(world: World):
    co = db.upsert_company(world.conn, "Lab0")
    prospects.upsert(world.conn, co.id, found_via="startups")
    contacts.upsert_contact(world.conn, company_id=None, full_name="Kabir Shah", origin="import", title="Backend Engineer",
                            linkedin_url="https://www.linkedin.com/in/kabir-shah",
                            notes="LinkedIn connection · Backend Engineer at Lab0 · connected 2025-03-02", share_ok=False)
    page = _Page({"google.com/search": _serp(
        ("Priya Nair - Software Engineer - Lab0 | LinkedIn", "https://in.linkedin.com/in/priya-nair",
         "Bengaluru, Karnataka, India · Software Engineer at Lab0"),
        ("Dev Patel - Engineer - Lab0 | LinkedIn", "https://in.linkedin.com/in/dev-patel", "Pune · Lab0"))})
    world.daemon.outreach._browser_factory = _browser(page)
    res = await world.ok("suggest_referrers", {"company_id": co.id, "location": "Bengaluru"})
    assert res == {"queued_google": True, "connections": 1}
    done = await world.daemon.outreach.run_google_work()
    assert done["referrers"] == 1
    refs = {r.person_name: r for r in referrals.list_for_company(world.conn, co.id)}
    assert refs["Kabir Shah"].basis is ReferralBasis.USER
    assert refs["Priya Nair"].basis is ReferralBasis.SAME_CITY and refs["Priya Nair"].basis_detail == "Bengaluru"
    assert refs["Dev Patel"].basis is not ReferralBasis.SAME_CITY  # Pune: no evidence for the city
    assert 'site%3Alinkedin.com%2Fin+%22Lab0%22+%22Bengaluru%22' in page.visited[0]
    assert all(u.startswith("https://www.google.com/search") for u in page.visited)
