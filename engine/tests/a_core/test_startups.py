"""Startups near you (schema v14): YC directory parsing from recorded responses, funding-news
verification, the deterministic startup score, facts merging, dedupe, location referral queries
and the v14 migration. No network."""

from __future__ import annotations

import json
from datetime import date
from pathlib import Path

import pytest

from autoapply import db
from autoapply.enums import FundingStage, ReferralBasis, ReferralState
from autoapply.models import CompanyFacts, Profile
from autoapply.outreach import contacts, facts, linkedin_export, prospects, referrals, startup_score, startups
from autoapply.outreach.sources.extract import page_text
from autoapply.outreach.sources.google_people import SerpHit
from autoapply.paths import schema_sql_path

FIX = Path(__file__).resolve().parents[1] / "fixtures" / "startups"
TODAY = date(2026, 10, 24)


def fx(name: str) -> str:
    return (FIX / name).read_text(encoding="utf-8")


# ---- location ------------------------------------------------------------------------------------


@pytest.mark.parametrize(("text", "city", "country"), [
    ("Bengaluru, India", "Bengaluru", "India"),
    ("Bangalore", "Bangalore", "India"),
    ("India", None, "India"),
    ("Gurgaon, Haryana, IN", "Gurgaon", "India"),
    ("San Francisco, CA, USA", "San Francisco", "United States of America"),
    ("London", "London", "United Kingdom"),
    ("Remote", None, None),
    ("Atlantis", "Atlantis", None),
    (None, None, None),
])
def test_parse_location(text, city, country):
    p = startups.parse_location(text)
    assert (p.city, p.country) == (city, country)


def test_same_city_knows_old_names():
    assert startups.same_city("Bangalore", "Bengaluru") and startups.same_city("Gurgaon", "gurugram")
    assert not startups.same_city("Pune", "Mumbai") and not startups.same_city(None, "Pune")


def test_user_location_prefers_profile_then_preferences():
    from autoapply.config import Preferences

    assert startups.user_location(Profile(location="Pune, India"), Preferences(locations=["Remote", "Bengaluru"])) == "Pune, India"
    assert startups.user_location(Profile(), Preferences(locations=["Remote", "Bengaluru"])) == "Bengaluru"
    assert startups.user_location(Profile(), Preferences()) is None


# ---- YC directory (recorded responses) ------------------------------------------------------------


def test_algolia_opts_from_the_directory_page():
    opts = startups.parse_algolia_opts(fx("yc_companies_page.html"))
    assert opts == {"app": "45BWZJ1SGC", "key": "RECORDEDTESTKEY", "valid_until": 4102444800}
    assert startups.parse_algolia_opts("<html>no key</html>") is None
    # The host is built from the app id: anything odd is refused.
    assert startups.parse_algolia_opts('window.AlgoliaOpts = {"app":"evil.com/x","key":"k"};') is None


def test_algolia_hits_parse_into_companies():
    cos = startups.parse_algolia_hits(json.loads(fx("yc_algolia_india.json")))
    assert [c.name for c in cos] == ["Kailash Labs", "Waybill", "BentoLabs AI", "Lab0"]
    lab0 = cos[3]
    assert (lab0.slug, lab0.batch, lab0.team_size, lab0.is_hiring, lab0.city, lab0.country, lab0.status) == (
        "lab0", "X26", 7, True, "Bengaluru", "India", "Active")
    assert lab0.url == "https://www.ycombinator.com/companies/lab0"
    assert cos[0].batch == "F26" and cos[1].batch == "S26"


def test_company_page_gives_founders_and_jobs():
    c = startups.parse_company_page(fx("yc_company_page.html"))
    assert c is not None
    assert (c.name, c.slug, c.batch, c.city, c.country, c.team_size) == ("Groww", "groww", "W18", "Bengaluru", "India", 1050)
    assert [f["name"] for f in c.founders][:2] == ["Lalit Keshre", "Ishan Bansal"]
    assert c.founders[0]["title"]
    assert len(c.job_titles) == 2 and c.is_hiring is True
    assert startups.parse_company_page("<div>nothing</div>") is None


@pytest.mark.parametrize(("raw", "short"), [("Winter 2024", "W24"), ("Summer 2021", "S21"), ("Spring 2026", "X26"),
                                            ("Fall 2025", "F25"), ("W18", "W18"), ("", None), ("Unspecified", None)])
def test_batch_short(raw, short):
    assert startups.batch_short(raw) == short


def test_yc_slug_only_for_company_pages():
    assert startups.yc_slug("https://www.ycombinator.com/companies/lab0") == "lab0"
    assert startups.yc_slug("https://www.ycombinator.com/companies/industry/fintech") is None
    assert startups.yc_slug("https://example.com/companies/lab0") is None


def test_hq_from_all_locations():
    assert startups.hq_from("Bengaluru, KA, India; San Francisco, CA, USA") == startups.Place("Bengaluru", "India")
    assert startups.hq_from("") == startups.Place(None, None)


# ---- funding news ----------------------------------------------------------------------------------


@pytest.mark.parametrize(("text", "amount", "currency"), [
    ("$4 million", 4e6, "USD"), ("US$ 4.5 Mn", 4.5e6, "USD"), ("Rs 35 crore", 3.5e8, "INR"), ("₹50 Cr", 5e8, "INR"),
    ("INR 120 Cr", 1.2e9, "INR"), ("€3M", 3e6, "EUR"), ("£2.5 million", 2.5e6, "GBP"), ("$750K", 7.5e5, "USD"),
    ("$500,000", 5e5, "USD"), ("Rs 5 lakh", 5e5, "INR"),
])
def test_parse_amount(text, amount, currency):
    assert startups.parse_amount(text) == (pytest.approx(amount), currency)


@pytest.mark.parametrize("text", ["", "a seed round", "$4", "35 crore rupees of revenue"])
def test_parse_amount_refuses_non_amounts(text):
    assert startups.parse_amount(text) is None


@pytest.mark.parametrize(("text", "stage"), [
    ("seed round", FundingStage.SEED), ("Pre-Seed", FundingStage.PRE_SEED), ("Series A", FundingStage.SERIES_A),
    ("its series-b round", FundingStage.SERIES_B), ("Series E", FundingStage.SERIES_D_PLUS), ("pre-Series A", FundingStage.SEED),
    ("venture debt", FundingStage.OTHER), ("a round", None),
])
def test_parse_stage(text, stage):
    assert startups.parse_stage(text) is stage


def test_usd_conversion_is_fixed_and_documented():
    assert startups.to_usd(3.5e8, "INR") == pytest.approx(3.5e8 / 84)
    assert startups.to_usd(1e6, "USD") == 1e6 and startups.to_usd(1e6, "XYZ") is None


def test_published_date_from_article_metadata():
    assert startups.published_date(fx("funding_article.html")) == "2026-08-14"
    assert startups.published_date('<script type="application/ld+json">{"datePublished": "2026-07-01T00:00:00Z"}</script>') == "2026-07-01"
    assert startups.published_date("<p>no date</p>") is None


def _rounds() -> list[startups.FundingRound]:
    html = fx("funding_article.html")
    raw = [
        {"company": "Kolam Data", "website": "https://kolamdata.example", "round": "Seed", "amount_text": "$4 million",
         "investors": ["Peak XV Partners", "Blume Ventures", "Sequoia Capital"], "city": "Chennai",
         "quote": "Chennai-based Kolam Data has raised $4 million in a seed round led by Peak XV Partners"},
        {"company": "Nimbu Health", "round": "Series A", "amount_text": "Rs 35 crore", "investors": ["Lightbox"], "city": "Bengaluru",
         "quote": "Healthtech startup Nimbu Health raised Rs 35 crore in its Series A round from Lightbox"},
        # Quote not on the page: no funding fact survives (the company still does).
        {"company": "Tarang Robotics", "round": "Series B", "amount_text": "$20 million", "investors": [],
         "quote": "Tarang Robotics raised $20 million in a Series B"},
        # Not on the page at all.
        {"company": "Imaginary Corp", "round": "Seed", "amount_text": "$1 million", "quote": "Imaginary Corp raised $1 million"},
        # Amount not in the quote: kept without the amount.
        {"company": "Kolam Data", "round": "Seed", "amount_text": "$9 million", "quote": "duplicate"},
    ]
    return startups.verify_rounds(raw, page_text(html), "https://news.example/funding-galore", startups.published_date(html))


def test_verify_rounds_keeps_only_what_the_article_says():
    rounds = {r.company: r for r in _rounds()}
    assert set(rounds) == {"Kolam Data", "Nimbu Health", "Tarang Robotics"}
    k = rounds["Kolam Data"]
    assert (k.stage, k.amount, k.currency, k.usd, k.date, k.city) == (FundingStage.SEED, 4e6, "USD", 4e6, "2026-08-14", "Chennai")
    assert k.investors == ["Peak XV Partners", "Blume Ventures"]  # "Sequoia Capital" isn't in the article
    assert k.website == "https://kolamdata.example" and k.source_url == "https://news.example/funding-galore"
    n = rounds["Nimbu Health"]
    assert (n.stage, n.amount, n.currency) == (FundingStage.SERIES_A, 3.5e8, "INR")
    assert n.usd == pytest.approx(3.5e8 / 84)
    t = rounds["Tarang Robotics"]
    assert (t.quote, t.stage, t.amount, t.date) == (None, None, None, None) and not t.has_facts


def test_round_updates_carry_the_source_and_quote():
    k = next(r for r in _rounds() if r.company == "Kolam Data")
    upd, srcs = startups.round_updates(k)
    assert upd["last_round_stage"] == "seed" and upd["last_round_usd"] == 4e6 and upd["last_round_date"] == "2026-08-14"
    assert srcs["last_round_amount"]["url"] == "https://news.example/funding-galore"
    assert "raised $4 million" in srcs["last_round_amount"]["quote"]
    t = next(r for r in _rounds() if r.company == "Tarang Robotics")
    upd, srcs = startups.round_updates(t)
    assert not any(k.startswith("last_round") for k, v in upd.items() if v is not None) and srcs == {}


def test_funding_queries_are_regional():
    india = startups.funding_queries(startups.Place("Bengaluru", "India"), TODAY)
    assert len(india) == 3 and india[0].startswith("site:inc42.com") and '"Bengaluru"' in india[0]
    assert any("entrackr.com" in q for q in india)
    other = startups.funding_queries(startups.Place(None, "Germany"), TODAY)
    assert all("Germany" in q for q in other) and any("techcrunch.com" in q for q in other)


def test_rounds_outside_the_place_are_dropped():
    place = startups.Place("Bengaluru", "India")
    assert startups.in_place("Chennai", place) and startups.in_place(None, place)
    assert not startups.in_place("London", place)


# ---- score ------------------------------------------------------------------------------------------


def _facts(**kw) -> CompanyFacts:
    return CompanyFacts(company_id=1, **kw)


def test_full_score_with_reasons():
    f = _facts(last_round_stage=FundingStage.SEED, last_round_amount=4e6, last_round_currency="USD", last_round_usd=4e6,
               last_round_date="2026-08-14", investors=["Peak XV Partners", "Blume Ventures"], yc_batch="W24", team_size=24,
               is_hiring=True, hq_country="India")
    s = startup_score.score_startup(f, matching_roles=2, today=TODAY)
    pts = {c.key: c.points for c in s.components}
    assert pts == {"recency": 25, "stage": 17, "investors": 15, "yc": 15, "team": 10, "roles": 12}
    assert s.score == 94 and s.confidence == 100
    reasons = {c.key: c.reason for c in s.components}
    assert reasons["recency"] == "Raised a $4M seed round 2 months ago"
    assert reasons["yc"] == "YC W24"
    assert reasons["investors"] == "Backed by Peak XV Partners and Blume Ventures"
    assert reasons["roles"] == "2 open roles match yours"


def test_missing_data_lowers_confidence_not_invents():
    s = startup_score.score_startup(None, matching_roles=None, today=TODAY)
    assert (s.score, s.confidence) == (0, 0)
    assert all(not c.known and c.points == 0 for c in s.components)
    only_yc = startup_score.score_startup(_facts(yc_batch="S21", team_size=1050, is_hiring=False), matching_roles=None, today=TODAY)
    assert only_yc.confidence == 15 + 10 + 15  # YC, team, roles known; funding unknown
    assert {c.key: c.points for c in only_yc.components} == {"recency": 0, "stage": 0, "investors": 0, "yc": 10, "team": 2, "roles": 0}


@pytest.mark.parametrize(("when", "pts"), [("2026-09-30", 25), ("2026-05-01", 20), ("2025-12-01", 13), ("2025-01-01", 6),
                                           ("2023-01-01", 0)])
def test_recency_buckets(when, pts):
    s = startup_score.score_startup(_facts(last_round_date=when), matching_roles=None, today=TODAY)
    assert s.components[0].points == pts


def test_inr_rounds_read_in_rupees_with_dollars():
    f = _facts(last_round_stage=FundingStage.SERIES_A, last_round_amount=3.5e8, last_round_currency="INR",
               last_round_usd=3.5e8 / 84, last_round_date="2026-08-14")
    s = startup_score.score_startup(f, matching_roles=None, today=TODAY)
    assert s.components[0].reason == "Raised ₹35 crore (~$4.2M) in a Series A round 2 months ago"
    assert s.components[1].reason == "Last round: Series A (₹35 crore (~$4.2M))"


def test_unknown_investors_count_a_little():
    s = startup_score.score_startup(_facts(investors=["Some Family Office"]), matching_roles=None, today=TODAY)
    inv = next(c for c in s.components if c.key == "investors")
    assert (inv.points, inv.known) == (3, True)
    assert startup_score.notable_investors(["Accel Partners India", "GVK"], "India") == ["Accel Partners India"]


def test_rank_combines_startup_and_fit():
    s = startup_score.score_startup(_facts(yc_batch="W24", team_size=30), matching_roles=None, today=TODAY)
    assert s.score == 25
    assert startup_score.rank(s, 80) == round(0.6 * 25 + 0.4 * 80)
    assert startup_score.rank(s, None) == 25
    empty = startup_score.score_startup(None, matching_roles=None, today=TODAY)
    assert startup_score.rank(empty, 70) == 70  # nothing known: the fit alone


def test_money_formatting():
    assert startup_score.money(4e6, "USD") == "$4M"
    assert startup_score.money(7.5e5, "USD") == "$750K"
    assert startup_score.money(5e5, "INR", 5e5 / 84) == "₹5 lakh (~$6K)"
    assert startup_score.money(3e6, "EUR", 3.24e6) == "€3M (~$3.2M)"
    assert startup_score.money(None, None) is None


# ---- facts + dedupe (DB) -----------------------------------------------------------------------------


def test_facts_newer_round_wins_and_sources_are_kept(conn):
    co = db.upsert_company(conn, "Kolam Data")
    src = facts.source("https://news.example/a", "raised $4 million")
    facts.upsert(conn, co.id, {"last_round_stage": "seed", "last_round_usd": 4e6, "last_round_date": "2026-08-14",
                               "investors": ["Peak XV Partners"]}, {"last_round_usd": src, "last_round_stage": src})
    # An older round never replaces a newer one; other facts still merge.
    facts.upsert(conn, co.id, {"last_round_stage": "pre_seed", "last_round_usd": 1e6, "last_round_date": "2025-01-01",
                               "team_size": 12}, {"team_size": facts.source("https://yc.example")})
    f = facts.get(conn, co.id)
    assert (f.last_round_stage, f.last_round_usd, f.team_size, f.investors) == (FundingStage.SEED, 4e6, 12, ["Peak XV Partners"])
    assert f.sources["last_round_usd"]["quote"] == "raised $4 million"
    assert f.sources["team_size"]["url"] == "https://yc.example"
    facts.upsert(conn, co.id, {"last_round_stage": "series_a", "last_round_date": "2026-10-01"}, {})
    assert facts.get(conn, co.id).last_round_stage is FundingStage.SERIES_A
    with pytest.raises(ValueError):
        facts.upsert(conn, co.id, {"valuation": 1}, {})


def test_dedupe_by_domain_then_name(conn):
    a = db.upsert_company(conn, "Kolam Data Pvt Ltd", domain="kolamdata.example")
    assert startups.save_company(conn, "Kolam", "www.kolamdata.example") == a.id
    assert startups.save_company(conn, "KOLAM DATA PVT. LTD.", None) == a.id
    b = startups.save_company(conn, "Nimbu Health", "nimbu.example")
    assert b != a.id and db.get_company(conn, b).domain == "nimbu.example"
    # A name match without a domain gets the domain filled in.
    c = db.upsert_company(conn, "Tarang Robotics")
    assert startups.save_company(conn, "Tarang Robotics", "tarang.example") == c.id
    assert db.get_company(conn, c.id).domain == "tarang.example"


def test_prospect_rank_follows_facts(conn):
    co = db.upsert_company(conn, "Lab0")
    p = prospects.upsert(conn, co.id, fit_score=70, found_via="startups")
    assert (p.rank_score, p.startup_score) == (70, None)  # nothing known yet: the fit alone
    facts.upsert(conn, co.id, {"yc_batch": "X26", "team_size": 7, "is_hiring": True}, {})
    p = prospects.rescore(conn, co.id, today=TODAY)
    assert p.startup_score == 15 + 6 + 9 and p.startup_confidence == 40
    assert p.rank_score == round(0.6 * 30 + 0.4 * 70)
    assert [r["key"] for r in p.startup_reasons] == ["recency", "stage", "investors", "yc", "team", "roles"]
    assert prospects.ranked(conn)[0].id == p.id


# ---- people at small startups --------------------------------------------------------------------------


def test_founders_first_at_a_small_startup(conn):
    from autoapply.enums import ScoutPurpose
    from autoapply.outreach.scout import best_contact

    co = db.upsert_company(conn, "Lab0", domain="lab0.ai")
    rec = contacts.upsert_contact(conn, company_id=co.id, full_name="Riya Rao", origin="user", email="riya@lab0.ai",
                                  email_status="user", title="Talent Partner").contact
    founder = contacts.upsert_contact(conn, company_id=co.id, full_name="Arjun Mehta", origin="user", email="arjun@lab0.ai",
                                      email_status="user", title="Co-founder & CEO").contact
    cto = contacts.upsert_contact(conn, company_id=co.id, full_name="Meera Iyer", origin="user", email="meera@lab0.ai",
                                  email_status="user", title="CTO").contact
    assert best_contact(conn, co.id, ScoutPurpose.PROSPECT).id == cto.id  # team size unknown: the usual order
    facts.upsert(conn, co.id, {"team_size": 7}, {})
    assert best_contact(conn, co.id, ScoutPurpose.PROSPECT).id == founder.id
    assert best_contact(conn, co.id, ScoutPurpose.APPLICATION).id == rec.id  # applications keep the recruiter first


def test_yc_founders_become_scout_people(conn):
    from autoapply.outreach.scout import founders_as_people

    co = db.upsert_company(conn, "Groww")
    page = startups.parse_company_page(fx("yc_company_page.html"))
    upd, srcs = startups.yc_updates(page)
    facts.upsert(conn, co.id, upd, srcs)
    people = founders_as_people(conn, db.get_company(conn, co.id))
    assert people[0].name == "Lalit Keshre" and people[0].url == "https://www.ycombinator.com/companies/groww"
    assert "Y Combinator" in people[0].snippet


# ---- location referrals --------------------------------------------------------------------------------


def test_same_city_query_comes_first_when_local():
    prof = Profile(location="Bengaluru, India", work_history=[{"company": "Juspay", "title": "SDE"}],
                   education=[{"school": "IIT Madras"}])
    qs = referrals.referrer_queries(prof, "Lab0", function="Backend Engineer", city="Bengaluru", local=True)
    assert qs[0].query == 'site:linkedin.com/in "Lab0" "Bengaluru"' and qs[0].basis is ReferralBasis.SAME_CITY
    assert len(qs) == 4
    plain = referrals.referrer_queries(prof, "Lab0", function="Backend Engineer", city="Bengaluru")
    assert all(q.basis is not ReferralBasis.SAME_CITY for q in plain)


def test_same_city_candidates_need_the_city_in_the_result():
    q = referrals.ReferrerQuery('site:linkedin.com/in "Lab0" "Bengaluru"', ReferralBasis.SAME_CITY, "Bengaluru")
    hits = [SerpHit("Priya Nair - Software Engineer - Lab0 | LinkedIn", "https://in.linkedin.com/in/priya-nair",
                    "Bengaluru, Karnataka, India · Software Engineer at Lab0"),
            SerpHit("Dev Patel - Engineer - Lab0 | LinkedIn", "https://in.linkedin.com/in/dev-patel", "Pune · Lab0"),
            SerpHit("Sam Roy - Designer - Acme | LinkedIn", "https://in.linkedin.com/in/sam-roy", "Bengaluru · ex-Lab0")]
    got = referrals.candidates_from_results(hits, q, "Lab0")
    assert [c.name for c in got] == ["Priya Nair"] and got[0].basis is ReferralBasis.SAME_CITY


def test_same_city_basis_sentence(conn):
    co = db.upsert_company(conn, "Lab0")
    r, _ = referrals.add(conn, company_id=co.id, person_name="Priya Nair", basis=ReferralBasis.SAME_CITY, basis_detail="Bengaluru")
    assert referrals.basis_sentence(r, Profile(location="Bangalore, India")) == "We're both in Bengaluru."
    assert referrals.basis_sentence(r, Profile(location="Pune")) == "They work in Bengaluru."


def test_imported_connections_at_a_new_startup_become_referrals(conn):
    # Imported before the startup was known: no company on the contact yet.
    c = contacts.upsert_contact(conn, company_id=None, full_name="Kabir Shah", origin="import", title="Backend Engineer",
                                linkedin_url="https://www.linkedin.com/in/kabir-shah",
                                notes="LinkedIn connection · Backend Engineer at Lab0 Technologies Pvt Ltd · connected 2025-03-02",
                                share_ok=False).contact
    contacts.upsert_contact(conn, company_id=None, full_name="Other Person", origin="import",
                            notes="LinkedIn connection · Engineer at Lab Zero · connected 2025-03-02", share_ok=False)
    co = db.upsert_company(conn, "Lab0")
    assert linkedin_export.match_connections(conn, co.id) == 1
    refs = referrals.list_for_company(conn, co.id)
    assert [(r.person_name, r.basis, r.state, r.contact_id) for r in refs] == [
        ("Kabir Shah", ReferralBasis.USER, ReferralState.SUGGESTED, c.id)]
    assert contacts.get_contact(conn, c.id).company_id == co.id
    assert linkedin_export.match_connections(conn, co.id) == 0  # once per person


# ---- migration -----------------------------------------------------------------------------------------


def _v13_schema_sql() -> str:
    """schema.sql as it was at v13: no company_facts, no startup columns, no same_city, no v14 row."""
    sql = schema_sql_path().read_text()
    start = sql.index("-- company_facts (v14)")
    end = sql.index("\n);", start) + 3
    sql = sql[:start] + sql[end:]
    sql = sql.replace(",'same_city')", ")")
    lines = [line for line in sql.splitlines() if "VALUES (14)" not in line and "-- v14" not in line
             and not line.strip().startswith(("startup_score ", "startup_confidence ", "startup_reasons ", "rank_score ",
                                               "-- with fit_score"))]
    out = "\n".join(lines)
    return out.replace("updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),\n);",
                       "updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))\n);")


def _shape(c, table):
    cols = sorted(tuple(r)[1:] for r in c.execute(f"PRAGMA table_info({table})"))
    idx = sorted((r[1], r[2]) for r in c.execute(f"PRAGMA index_list({table})") if not r[1].startswith("sqlite_autoindex"))
    return cols, idx


def test_v13_database_upgrades_to_v14_keeping_referrals(tmp_path, conn):
    c = db.connect(tmp_path / "v13.db")
    c.executescript("BEGIN;\n" + _v13_schema_sql() + "\nCOMMIT;")
    assert db.current_schema_version(c) == 13
    assert c.execute("SELECT name FROM sqlite_master WHERE name = 'company_facts'").fetchone() is None
    co = db.upsert_company(c, "Acme")
    c.execute("INSERT INTO referrals(company_id, person_name, basis, linkedin_url, state) VALUES (?, 'Jane Doe', 'alumni', "
              "'https://www.linkedin.com/in/jane', 'connected')", (co.id,))
    with pytest.raises(Exception):
        c.execute("INSERT INTO referrals(company_id, person_name, basis) VALUES (?, 'X', 'same_city')", (co.id,))
    c.execute("INSERT INTO prospects(company_id, fit_score) VALUES (?, 60)", (co.id,))
    assert db.migrate(c) == db.SCHEMA_VERSION == 14
    for table in ("referrals", "prospects", "company_facts"):
        assert _shape(c, table) == _shape(conn, table), table
    row = c.execute("SELECT person_name, basis, state, linkedin_url FROM referrals").fetchone()
    assert tuple(row) == ("Jane Doe", "alumni", "connected", "https://www.linkedin.com/in/jane")
    c.execute("INSERT INTO referrals(company_id, person_name, basis) VALUES (?, 'Priya', 'same_city')", (co.id,))
    p = c.execute("SELECT fit_score, startup_reasons, rank_score FROM prospects").fetchone()
    assert tuple(p) == (60, "[]", None)
    with pytest.raises(Exception):  # the unique (company, profile URL) index survived the rebuild
        c.execute("INSERT INTO referrals(company_id, person_name, basis, linkedin_url) VALUES (?, 'J', 'user', "
                  "'https://www.linkedin.com/in/jane')", (co.id,))
    assert db.migrate(c) == db.SCHEMA_VERSION  # idempotent
    c.close()
