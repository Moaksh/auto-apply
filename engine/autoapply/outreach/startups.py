"""Startups near you: discovery by location from free, public sources (plan §A.2 extension).

Two sources, both read-only and polite:

* **YC's public company directory.** ycombinator.com/companies is a client-side page backed by
  an Algolia index; the page embeds a search-only key in ``window.AlgoliaOpts`` (restricted to
  the public company indices, with an expiry). :class:`YCDirectory` reads that key from the
  page (cached in ``meta`` until it expires), then asks the index for active companies in the
  user's country (``regions``), newest batch first, optionally only those hiring. Small pages
  (40 hits), at most 2 pages per search, one request a second, results cached for a day, and
  the engine's usual User-Agent. A company's own YC page (``/companies/<slug>``) carries its
  founders and open jobs in a ``data-page`` JSON attribute; that is read for the top few only.
  If the key can't be read or the index refuses it, the Google stage falls back to
  ``site:ycombinator.com/companies "<country>"`` results and reads those company pages.
* **Funding news.** Google result pages (the agent Chrome, the ``prospect_finder`` budget)
  for regional funding news (Inc42, Entrackr, YourStory, VCCircle for India; TechCrunch and a
  generic "raises seed / Series A" query elsewhere). Each article is fetched over HTTP and the
  model lists the rounds it reports. A round is kept only when the company name, the quote and
  the amount as written all appear in the article; investors and the city must appear too, or
  they are dropped. The date is the article's published date from its own metadata. Nothing is
  estimated: an unverified fact is left empty.

Amounts keep the currency as reported; ``USD_RATES`` converts them for ranking at fixed,
approximate rates (documented, not live).
"""

from __future__ import annotations

import asyncio
import html as htmlmod
import json
import logging
import re
import sqlite3
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any
from urllib.parse import urlencode, urlsplit

import httpx

from autoapply import db
from autoapply.config import Preferences
from autoapply.enums import FundingStage
from autoapply.llm.provider import LLMProvider, TokenUsage
from autoapply.models import Profile, format_ts, parse_ts, utcnow
from autoapply.outreach.domains import USER_AGENT, domain_from_url, is_aggregator
from autoapply.outreach.sources.extract import appears_in, norm_text

log = logging.getLogger("autoapply.outreach.startups")

YC_DIRECTORY_URL = "https://www.ycombinator.com/companies"
YC_INDEX = "YCCompany_By_Launch_Date_production"
YC_PAGE_SIZE = 40
YC_MAX_PAGES = 2
#: Seconds between two requests to ycombinator.com / its search index.
YC_MIN_INTERVAL_S = 1.0
YC_CACHE_HOURS = 24
#: YC company pages read per discovery (founders, open jobs) — the top of the list only.
YC_PAGES_PER_SEARCH = 8
META_YC_KEY = "yc_algolia_opts"
META_YC_CACHE = "yc_directory_cache"

#: Approximate USD per unit, for ranking only (a stored amount keeps its own currency).
USD_RATES: dict[str, float] = {
    "USD": 1.0, "INR": 1 / 84.0, "EUR": 1.08, "GBP": 1.27, "SGD": 0.74, "CAD": 0.73, "AUD": 0.66, "AED": 0.27,
    "IDR": 1 / 16000.0, "BRL": 0.18, "JPY": 1 / 150.0, "CHF": 1.13, "SEK": 0.095,
}

# =====================================================================================
# Location
# =====================================================================================

#: Spellings -> YC's ``regions`` value for a country.
_COUNTRY_ALIASES: dict[str, str] = {
    "india": "India", "in": "India", "bharat": "India",
    "us": "United States of America", "usa": "United States of America", "united states": "United States of America",
    "united states of america": "United States of America", "america": "United States of America",
    "uk": "United Kingdom", "united kingdom": "United Kingdom", "england": "United Kingdom", "great britain": "United Kingdom",
    "uae": "United Arab Emirates", "united arab emirates": "United Arab Emirates",
    "korea": "South Korea", "south korea": "South Korea",
}
_COUNTRIES = (
    "Canada", "Germany", "France", "Singapore", "Indonesia", "Brazil", "Mexico", "Nigeria", "Kenya", "Israel", "Australia",
    "Spain", "Sweden", "Switzerland", "Netherlands", "Ireland", "Poland", "Portugal", "Egypt", "Pakistan", "Philippines",
    "Vietnam", "Malaysia", "Colombia", "Argentina", "Chile", "Peru", "Turkey", "Japan", "Denmark", "Norway", "Finland",
    "Austria", "Belgium", "Italy", "Estonia", "Ghana", "South Africa", "New Zealand", "Hong Kong", "Bangladesh", "Nepal",
    "Saudi Arabia", "China", "Taiwan", "Thailand",
)
for _c in _COUNTRIES:
    _COUNTRY_ALIASES[_c.lower()] = _c
#: Cities -> country, for a location typed without one ("Bangalore").
_CITY_COUNTRY: dict[str, str] = {
    **{c: "India" for c in ("bengaluru", "bangalore", "mumbai", "bombay", "delhi", "new delhi", "gurgaon", "gurugram", "noida",
                           "hyderabad", "pune", "chennai", "madras", "kolkata", "ahmedabad", "jaipur", "kochi", "cochin",
                           "chandigarh", "indore", "coimbatore", "thiruvananthapuram", "trivandrum", "bhubaneswar", "goa",
                           "ncr", "delhi ncr", "mysuru", "mysore", "lucknow", "nagpur", "surat", "vadodara")},
    **{c: "United States of America" for c in ("san francisco", "sf", "new york", "nyc", "seattle", "austin", "boston",
                                               "los angeles", "palo alto", "mountain view", "chicago", "bay area")},
    **{c: "United Kingdom" for c in ("london", "manchester", "cambridge", "edinburgh")},
    "berlin": "Germany", "munich": "Germany", "paris": "France", "toronto": "Canada", "vancouver": "Canada",
    "singapore": "Singapore", "jakarta": "Indonesia", "lagos": "Nigeria", "nairobi": "Kenya", "dubai": "United Arab Emirates",
    "tel aviv": "Israel", "sydney": "Australia", "melbourne": "Australia", "sao paulo": "Brazil", "mexico city": "Mexico",
    "amsterdam": "Netherlands", "stockholm": "Sweden", "dublin": "Ireland", "zurich": "Switzerland",
}
#: Spellings of the same city ("Bangalore" is "Bengaluru").
_CITY_ALIASES: dict[str, tuple[str, ...]] = {
    "bengaluru": ("bengaluru", "bangalore"), "bangalore": ("bengaluru", "bangalore"),
    "gurugram": ("gurugram", "gurgaon"), "gurgaon": ("gurugram", "gurgaon"),
    "mumbai": ("mumbai", "bombay"), "bombay": ("mumbai", "bombay"), "chennai": ("chennai", "madras"),
    "delhi": ("delhi", "new delhi", "delhi ncr"), "new delhi": ("delhi", "new delhi", "delhi ncr"),
    "kochi": ("kochi", "cochin"), "mysuru": ("mysuru", "mysore"),
}
#: US/Canadian state and province codes that appear as the middle part of "City, ST, Country".
_REMOTE = ("remote", "anywhere", "worldwide")


@dataclass(slots=True, frozen=True)
class Place:
    city: str | None
    country: str | None

    @property
    def label(self) -> str:
        return ", ".join(x for x in (self.city, self.country) if x) or "anywhere"

    def as_dict(self) -> dict[str, str | None]:
        return {"city": self.city, "country": self.country}


def country_of(text: str | None) -> str | None:
    t = re.sub(r"\s+", " ", (text or "").strip().strip(".")).lower()
    return _COUNTRY_ALIASES.get(t) or _CITY_COUNTRY.get(t)


def parse_location(text: str | None) -> Place:
    """'Bengaluru, India' -> (Bengaluru, India); 'Bangalore' -> (Bangalore, India); 'India' -> (None, India)."""
    parts = [p.strip() for p in re.split(r"[,/|]", text or "") if p.strip() and p.strip().lower() not in _REMOTE]
    if not parts:
        return Place(None, None)
    country = None
    for p in reversed(parts):
        if p.lower() in _COUNTRY_ALIASES:
            country = _COUNTRY_ALIASES[p.lower()]
            break
    city = parts[0] if parts[0].lower() not in _COUNTRY_ALIASES else None
    if country is None and city:
        country = _CITY_COUNTRY.get(city.lower())
    return Place(city, country)


def same_city(a: str | None, b: str | None) -> bool:
    if not a or not b:
        return False
    x, y = a.strip().lower(), b.strip().lower()
    return x == y or y in _CITY_ALIASES.get(x, ()) or x in _CITY_ALIASES.get(y, ())


def user_location(profile: Profile | None, prefs: Preferences | None) -> str | None:
    """The user's own location: the profile's, else the first preferred location."""
    if profile is not None and (profile.location or "").strip():
        return profile.location.strip()  # type: ignore[union-attr]
    for loc in (prefs.locations if prefs else []):
        if loc.strip() and loc.strip().lower() not in _REMOTE:
            return loc.strip()
    return None


def hq_from(all_locations: str | None) -> Place:
    """YC's 'Bengaluru, KA, India; San Francisco, CA, USA' -> the first place."""
    first = (all_locations or "").split(";")[0]
    parts = [p.strip() for p in first.split(",") if p.strip()]
    if not parts:
        return Place(None, None)
    country = country_of(parts[-1]) or (parts[-1] if len(parts) > 1 else None)
    city = parts[0] if len(parts) > 1 or country_of(parts[0]) is None else None
    return Place(city, country)


# =====================================================================================
# YC directory
# =====================================================================================

_SEASON = {"winter": "W", "summer": "S", "spring": "X", "fall": "F", "autumn": "F"}


def batch_short(batch: str | None) -> str | None:
    """'Winter 2024' -> 'W24', 'Spring 2026' -> 'X26', 'Fall 2025' -> 'F25'; 'W18' stays."""
    b = (batch or "").strip()
    if re.fullmatch(r"[WSXF]\d{2}", b, re.I):
        return b.upper()
    m = re.fullmatch(r"(winter|summer|spring|fall|autumn)\s+(\d{4})", b, re.I)
    return f"{_SEASON[m.group(1).lower()]}{m.group(2)[2:]}" if m else None


@dataclass(slots=True)
class YCCompany:
    name: str
    slug: str
    website: str | None = None
    one_liner: str | None = None
    description: str | None = None
    team_size: int | None = None
    is_hiring: bool | None = None
    batch: str | None = None
    status: str | None = None
    city: str | None = None
    country: str | None = None
    industry: str | None = None
    founders: list[dict[str, Any]] = field(default_factory=list)
    job_titles: list[str] = field(default_factory=list)

    @property
    def url(self) -> str:
        return f"{YC_DIRECTORY_URL}/{self.slug}"


class YCUnavailable(Exception):
    """The directory's search key could not be read, or the index refused it."""


def parse_algolia_opts(page_html: str) -> dict[str, Any] | None:
    """``window.AlgoliaOpts = {"app": ..., "key": ..., "valid_until": ...}`` from the directory page."""
    m = re.search(r"window\.AlgoliaOpts\s*=\s*(\{.*?\})\s*;", page_html or "", re.S)
    if not m:
        return None
    try:
        opts = json.loads(m.group(1))
    except ValueError:
        return None
    if not isinstance(opts, dict) or not opts.get("app") or not opts.get("key"):
        return None
    if not re.fullmatch(r"[A-Z0-9]{6,20}", str(opts["app"])):
        return None  # the host is built from it: never trust anything else
    return {"app": str(opts["app"]), "key": str(opts["key"]), "valid_until": int(opts.get("valid_until") or 0)}


def _int(v: Any) -> int | None:
    try:
        return int(v) if v is not None and str(v).strip() != "" else None
    except (TypeError, ValueError):
        return None


def _hit_company(h: dict[str, Any]) -> YCCompany | None:
    name = re.sub(r"\s+", " ", str(h.get("name") or "")).strip()
    slug = str(h.get("slug") or "").strip()
    if not name or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", slug):
        return None
    hq = hq_from(h.get("all_locations"))
    hiring = h.get("isHiring")
    return YCCompany(
        name=name, slug=slug, website=(str(h.get("website") or "").strip() or None),
        one_liner=(str(h.get("one_liner") or "").strip() or None),
        description=(str(h.get("long_description") or "").strip() or None),
        team_size=_int(h.get("team_size")), is_hiring=hiring if isinstance(hiring, bool) else None,
        batch=batch_short(h.get("batch")), status=(str(h.get("status") or "").strip() or None),
        city=hq.city, country=hq.country, industry=(str(h.get("industry") or "").strip() or None),
    )


def parse_algolia_hits(data: dict[str, Any]) -> list[YCCompany]:
    """Companies in an Algolia multi-query response (``results[0].hits``)."""
    results = (data or {}).get("results") or [data or {}]
    out: list[YCCompany] = []
    for h in (results[0] or {}).get("hits") or []:
        c = _hit_company(h) if isinstance(h, dict) else None
        if c is not None and not any(x.slug == c.slug for x in out):
            out.append(c)
    return out


def parse_company_page(page_html: str) -> YCCompany | None:
    """A YC company page's ``data-page`` JSON: the company, its founders and open jobs."""
    m = re.search(r'data-page="([^"]+)"', page_html or "")
    if not m:
        return None
    try:
        data = json.loads(htmlmod.unescape(m.group(1)))
    except ValueError:
        return None
    props = (data or {}).get("props") or {}
    c = props.get("company") or {}
    name = re.sub(r"\s+", " ", str(c.get("name") or "")).strip()
    slug = str(c.get("slug") or "").strip()
    if not name or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", slug):
        return None
    loc = str(c.get("location") or "")
    hq = hq_from(loc)
    country = country_of(str(c.get("country") or "")) or hq.country
    founders = []
    for f in c.get("founders") or []:
        fname = re.sub(r"\s+", " ", str((f or {}).get("full_name") or "")).strip()
        if fname and (f or {}).get("is_active", True) is not False:
            founders.append({"name": fname, "title": (str(f.get("title") or "").strip() or None),
                             "linkedin_url": (str(f.get("linkedin_url") or "").strip() or None)})
    jobs = [str(j.get("title") or "").strip() for j in (props.get("jobPostings") or c.get("jobs") or []) if isinstance(j, dict)]
    return YCCompany(
        name=name, slug=slug, website=(str(c.get("website") or "").strip() or None),
        one_liner=(str(c.get("one_liner") or "").strip() or None), team_size=_int(c.get("team_size")),
        is_hiring=(bool(jobs) or None), batch=batch_short(c.get("batch") or c.get("batch_name")),
        status=(str(c.get("ycdc_status") or "").strip() or None), city=(str(c.get("city") or "").strip() or hq.city),
        country=country, founders=founders, job_titles=[j for j in jobs if j],
    )


def yc_slug(url: str) -> str | None:
    """'https://www.ycombinator.com/companies/acme' -> 'acme' (None for any other page)."""
    try:
        parts = urlsplit(url)
    except ValueError:
        return None
    if (parts.hostname or "").lower() not in ("www.ycombinator.com", "ycombinator.com"):
        return None
    m = re.fullmatch(r"/companies/([a-z0-9][a-z0-9-]*)/?", parts.path)
    return m.group(1) if m and m.group(1) not in ("industry", "location", "batch", "founders") else None


Sleep = Callable[[float], Awaitable[None]]


class YCDirectory:
    """Polite reader for YC's directory: one request a second, cached search key and results."""

    def __init__(self, conn: sqlite3.Connection, http: httpx.AsyncClient, *, sleep: Sleep | None = None,
                 clock: Callable[[], float] = time.monotonic, now: Callable[[], datetime] = utcnow) -> None:
        self.conn = conn
        self.http = http
        self.sleep = sleep or asyncio.sleep
        self.clock = clock
        self.now = now
        self._last: float | None = None
        self.requests = 0

    async def _pace(self) -> None:
        if self._last is not None:
            wait = YC_MIN_INTERVAL_S - (self.clock() - self._last)
            if wait > 0:
                await self.sleep(wait)
        self._last = self.clock()
        self.requests += 1

    async def _opts(self, *, refresh: bool = False) -> dict[str, Any]:
        cached = db.get_meta(self.conn, META_YC_KEY, None)
        if not refresh and isinstance(cached, dict) and int(cached.get("valid_until") or 0) > self.now().timestamp() + 60:
            return cached
        await self._pace()
        try:
            r = await self.http.get(YC_DIRECTORY_URL, headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=20)
        except httpx.HTTPError as e:
            raise YCUnavailable(f"YC directory page: {e}") from e
        opts = parse_algolia_opts(r.text) if r.status_code < 400 else None
        if opts is None:
            raise YCUnavailable(f"no search key on the YC directory page (HTTP {r.status_code})")
        if not opts["valid_until"]:
            opts["valid_until"] = int(self.now().timestamp()) + 6 * 3600
        db.set_meta(self.conn, META_YC_KEY, opts)
        return opts

    async def _query(self, opts: dict[str, Any], params: dict[str, Any]) -> dict[str, Any]:
        await self._pace()
        url = f"https://{opts['app'].lower()}-dsn.algolia.net/1/indexes/*/queries"
        body = {"requests": [{"indexName": YC_INDEX, "params": urlencode(params)}]}
        try:
            r = await self.http.post(url, json=body, timeout=20, headers={
                "User-Agent": USER_AGENT, "x-algolia-application-id": opts["app"], "x-algolia-api-key": opts["key"]})
        except httpx.HTTPError as e:
            raise YCUnavailable(f"YC search: {e}") from e
        if r.status_code in (401, 403):
            raise PermissionError("search key refused")
        if r.status_code >= 400:
            raise YCUnavailable(f"YC search: HTTP {r.status_code}")
        try:
            return r.json()
        except ValueError as e:
            raise YCUnavailable("YC search: not JSON") from e

    async def search(self, country: str, *, hiring_only: bool = False, limit: int = 40) -> list[YCCompany]:
        """Active YC companies in ``country`` (YC's ``regions``), newest batch first."""
        key = f"{country}|{int(hiring_only)}|{limit}"
        cache = db.get_meta(self.conn, META_YC_CACHE, {}) or {}
        hit = cache.get(key)
        if hit and self.now() - parse_ts(hit["at"]) < timedelta(hours=YC_CACHE_HOURS):
            return parse_algolia_hits({"results": [{"hits": hit["hits"]}]})
        filters: list[list[str]] = [[f"regions:{country}"], ["status:Active"]]
        if hiring_only:
            filters.append(["isHiring:true"])
        hits: list[dict[str, Any]] = []
        opts = await self._opts()
        for page in range(YC_MAX_PAGES):
            params = {"query": "", "hitsPerPage": YC_PAGE_SIZE, "page": page, "facetFilters": json.dumps(filters)}
            try:
                data = await self._query(opts, params)
            except PermissionError:
                opts = await self._opts(refresh=True)  # the key expired early: read it once more
                try:
                    data = await self._query(opts, params)
                except PermissionError as e:
                    raise YCUnavailable("YC's search key was refused") from e
            res = ((data.get("results") or [{}])[0]) or {}
            page_hits = [h for h in res.get("hits") or [] if isinstance(h, dict)]
            hits += page_hits
            if len(hits) >= limit or len(page_hits) < YC_PAGE_SIZE or page + 1 >= int(res.get("nbPages") or 1):
                break
        keep = ("name", "slug", "website", "one_liner", "team_size", "isHiring", "batch", "status", "all_locations", "industry")
        slim = [{k: h.get(k) for k in keep} for h in hits[:limit]]
        cache = {k: v for k, v in cache.items() if self.now() - parse_ts(v["at"]) < timedelta(hours=YC_CACHE_HOURS)}
        cache[key] = {"at": format_ts(self.now()), "hits": slim}
        db.set_meta(self.conn, META_YC_CACHE, dict(list(cache.items())[-12:]))
        return parse_algolia_hits({"results": [{"hits": slim}]})

    async def company_page(self, slug: str) -> YCCompany | None:
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", slug or ""):
            return None
        await self._pace()
        try:
            r = await self.http.get(f"{YC_DIRECTORY_URL}/{slug}", headers={"User-Agent": USER_AGENT}, follow_redirects=True,
                                    timeout=20)
        except httpx.HTTPError as e:
            log.info("YC page %s: %s", slug, e)
            return None
        return parse_company_page(r.text) if r.status_code < 400 else None


def yc_fallback_query(place: Place) -> str:
    return f'site:ycombinator.com/companies "{place.city or place.country}"'


def yc_updates(c: YCCompany) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    """company_facts updates (+ their sources) from a YC listing or page."""
    from autoapply.outreach.facts import source

    src = source(c.url)
    upd: dict[str, Any] = {"yc_batch": c.batch, "yc_url": c.url, "yc_status": c.status, "hq_city": c.city,
                           "hq_country": c.country, "team_size": c.team_size, "is_hiring": c.is_hiring, "industry": c.industry}
    if c.founders:
        upd["founders"] = [{**f, "url": c.url} for f in c.founders]
    if c.job_titles:
        upd["open_roles"] = len(c.job_titles)
    return upd, {k: src for k, v in upd.items() if v is not None}


# =====================================================================================
# Funding news
# =====================================================================================

#: Regional funding-news sites read through Google results.
NEWS_SITES: dict[str, tuple[str, ...]] = {
    "India": ("inc42.com", "entrackr.com", "yourstory.com", "vccircle.com"),
}
MAX_NEWS_QUERIES = 3

ROUNDS_SCHEMA = {
    "type": "object",
    "properties": {"rounds": {"type": "array", "maxItems": 15, "items": {
        "type": "object",
        "properties": {
            "company": {"type": "string"}, "website": {"type": ["string", "null"]},
            "round": {"type": ["string", "null"]}, "amount_text": {"type": ["string", "null"]},
            "investors": {"type": "array", "items": {"type": "string"}}, "city": {"type": ["string", "null"]},
            "quote": {"type": "string"},
        },
        "required": ["company", "quote"]}}},
    "required": ["rounds"],
}


def funding_queries(place: Place, today: date) -> list[str]:
    """Google queries for recent funding news in ``place`` (most specific first)."""
    where = place.city or place.country or ""
    year = today.year
    sites = NEWS_SITES.get(place.country or "", ())
    out: list[str] = []
    if sites:
        city = f' "{place.city}"' if place.city else ""
        out += [f'site:{sites[0]} raises funding{city} {year}', f'site:{sites[1]} raises seed OR "Series A" {year}',
                f'site:{sites[2]} raises funding startup{city} {year}']
    else:
        out += [f'startup "{where}" raises seed OR "Series A" {year}', f'site:techcrunch.com "{where}" raises "Series A" {year}',
                f'"{where}" startup funding round {year}']
    return out[:MAX_NEWS_QUERIES]


_AMOUNT = re.compile(
    r"(?P<pre>US\$|USD|\$|₹|Rs\.?|INR|€|EUR|£|GBP|S\$|SGD)?\s*(?P<num>\d+(?:[.,]\d+)?)\s*"
    r"(?P<unit>million|mn|mln|m|billion|bn|b|thousand|k|crore|cr|lakh|lac|l)?\b\.?\s*(?P<post>USD|INR|EUR|GBP|SGD|dollars)?",
    re.I)
_UNITS = {"million": 1e6, "mn": 1e6, "mln": 1e6, "m": 1e6, "billion": 1e9, "bn": 1e9, "b": 1e9, "thousand": 1e3, "k": 1e3,
          "crore": 1e7, "cr": 1e7, "lakh": 1e5, "lac": 1e5, "l": 1e5}
_CURRENCY = {"us$": "USD", "usd": "USD", "$": "USD", "dollars": "USD", "₹": "INR", "rs": "INR", "rs.": "INR", "inr": "INR",
             "€": "EUR", "eur": "EUR", "£": "GBP", "gbp": "GBP", "s$": "SGD", "sgd": "SGD"}


def parse_amount(text: str | None) -> tuple[float, str] | None:
    """'$4 million' -> (4e6, USD); 'Rs 35 crore' -> (3.5e8, INR); '₹50 Cr' -> (5e8, INR); '€3M' -> (3e6, EUR)."""
    for m in _AMOUNT.finditer(text or ""):
        cur_raw = (m.group("pre") or m.group("post") or "").lower()
        unit = (m.group("unit") or "").lower()
        if not cur_raw or (not unit and cur_raw not in ("$", "us$", "usd", "€", "£")):
            continue
        cur = _CURRENCY.get(cur_raw)
        if cur is None:
            continue
        try:
            num = float(m.group("num").replace(",", "")) if "," in m.group("num") and len(m.group("num").split(",")[-1]) == 3 \
                else float(m.group("num").replace(",", "."))
        except ValueError:
            continue
        if unit in ("crore", "cr", "lakh", "lac", "l") and cur != "INR":
            cur = "INR"
        amount = num * _UNITS.get(unit, 1.0)
        if amount <= 0 or (not unit and amount < 1000):
            continue  # "$4" is not a funding round
        return amount, cur
    return None


def to_usd(amount: float | None, currency: str | None) -> float | None:
    if amount is None or not currency:
        return None
    rate = USD_RATES.get(currency.upper())
    return round(amount * rate, 2) if rate else None


_STAGES: tuple[tuple[re.Pattern[str], FundingStage], ...] = (
    (re.compile(r"\bpre[- ]?seed\b", re.I), FundingStage.PRE_SEED),
    (re.compile(r"\bpre[- ]?series[- ]?a\b", re.I), FundingStage.SEED),
    (re.compile(r"\bseries[- ]?a\b", re.I), FundingStage.SERIES_A),
    (re.compile(r"\bseries[- ]?b\b", re.I), FundingStage.SERIES_B),
    (re.compile(r"\bseries[- ]?c\b", re.I), FundingStage.SERIES_C),
    (re.compile(r"\bseries[- ]?[d-j]\b", re.I), FundingStage.SERIES_D_PLUS),
    (re.compile(r"\bseed\b", re.I), FundingStage.SEED),
    (re.compile(r"\b(angel|bridge|debt|venture debt|growth)\b", re.I), FundingStage.OTHER),
)


def parse_stage(text: str | None) -> FundingStage | None:
    for rx, stage in _STAGES:
        if rx.search(text or ""):
            return stage
    return None


_DATE_META = (
    re.compile(r'<meta[^>]+(?:property|name|itemprop)=["\'](?:article:published_time|og:published_time|datePublished|'
               r'publish-date|pubdate|date)["\'][^>]*content=["\']([^"\']+)["\']', re.I),
    re.compile(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]*(?:property|name|itemprop)=["\'](?:article:published_time|'
               r'datePublished)["\']', re.I),
    re.compile(r'"datePublished"\s*:\s*"([^"]+)"'),
    re.compile(r'<time[^>]+datetime=["\']([^"\']+)["\']', re.I),
)


def published_date(page_html: str) -> str | None:
    """The article's own published date (YYYY-MM-DD) from its metadata, else None."""
    for rx in _DATE_META:
        m = rx.search(page_html or "")
        if m:
            d = re.match(r"(\d{4})-(\d{2})-(\d{2})", m.group(1).strip())
            if d:
                try:
                    return date(int(d.group(1)), int(d.group(2)), int(d.group(3))).isoformat()
                except ValueError:
                    continue
    return None


@dataclass(slots=True)
class FundingRound:
    company: str
    source_url: str
    quote: str | None = None
    website: str | None = None
    stage: FundingStage | None = None
    amount: float | None = None
    currency: str | None = None
    usd: float | None = None
    date: str | None = None
    investors: list[str] = field(default_factory=list)
    city: str | None = None
    amount_text: str | None = None

    @property
    def has_facts(self) -> bool:
        return self.quote is not None and (self.stage is not None or self.amount is not None)


def verify_rounds(raw: list[dict], text: str, source_url: str, published: str | None) -> list[FundingRound]:
    """Keep what the article itself says: the company must be named, the quote must be on the
    page (otherwise every funding fact is dropped), the amount must be written in the quote,
    the stage must be named in the quote, and each investor / the city must be on the page."""
    tn = norm_text(text)
    out: list[FundingRound] = []
    for r in raw:
        if not isinstance(r, dict):
            continue
        name = re.sub(r"\s+", " ", str(r.get("company") or "")).strip()
        if not name or len(name) > 60 or not appears_in(name, tn):
            if name:
                log.info("dropped funding round for a company not on the page: %r", name)
            continue
        if any(f.company.lower() == name.lower() for f in out):
            continue
        fr = FundingRound(company=name, source_url=source_url)
        site = str(r.get("website") or "").strip()
        if site.startswith("http") and not is_aggregator(urlsplit(site).hostname) and domain_from_url(site):
            fr.website = site
        quote = re.sub(r"\s+", " ", str(r.get("quote") or "")).strip()
        if quote and appears_in(quote, tn):
            fr.quote = quote[:400]
            qn = norm_text(quote)
            amount_text = str(r.get("amount_text") or "").strip()
            parsed = parse_amount(amount_text) if amount_text and appears_in(amount_text, qn) else None
            if parsed:
                fr.amount, fr.currency = parsed
                fr.usd = to_usd(fr.amount, fr.currency)
                fr.amount_text = amount_text
            stage = parse_stage(str(r.get("round") or ""))
            if stage is not None and parse_stage(quote) is stage:
                fr.stage = stage
            elif stage is None and parse_stage(quote) is not None:
                fr.stage = parse_stage(quote)
            fr.investors = [i.strip() for i in r.get("investors") or [] if isinstance(i, str) and i.strip()
                            and len(i.strip()) <= 60 and appears_in(i.strip(), tn)][:8]
            fr.date = published if fr.has_facts else None
        city = str(r.get("city") or "").strip()
        if city and appears_in(city, tn):
            fr.city = city
        out.append(fr)
    return out


async def extract_rounds(llm: LLMProvider, text: str, source_url: str, published: str | None,
                         usage: TokenUsage | None = None) -> list[FundingRound]:
    prompt = ("List the startups this article says raised money. For each give: company (exactly as written), its website "
              "if the article links it, the round (pre-seed, seed, Series A, ...), amount_text copied exactly as written "
              "(e.g. '$4 million', 'Rs 35 crore'), investors named, the city if stated, and quote: one sentence copied "
              "word for word from the article that states the raise. Leave anything the article doesn't say empty. "
              "Do not include investors, publishers or acquirers as companies.\n\nARTICLE:\n" + text[:9000])
    try:
        res = await llm.complete(prompt, schema=ROUNDS_SCHEMA, tier="fast", max_tokens=1800)
    except Exception as e:  # noqa: BLE001
        log.info("extract_rounds failed: %s", e)
        return []
    if usage is not None:
        usage.add(res.usage)
    return verify_rounds(list((res.data or {}).get("rounds") or []), text, source_url, published)


def round_updates(r: FundingRound) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    """company_facts updates (+ their sources) from a verified funding round."""
    from autoapply.outreach.facts import source

    if not r.has_facts:
        upd: dict[str, Any] = {"hq_city": r.city}
        return upd, ({"hq_city": source(r.source_url)} if r.city else {})
    src = source(r.source_url, r.quote)
    upd = {"last_round_stage": r.stage.value if r.stage else None, "last_round_amount": r.amount, "last_round_currency": r.currency,
           "last_round_usd": r.usd, "last_round_date": r.date, "investors": r.investors or None, "hq_city": r.city}
    return upd, {k: src for k, v in upd.items() if v is not None}


def in_place(round_city: str | None, place: Place) -> bool:
    """A round's city is in the searched place (unknown city: kept; the query was regional)."""
    if not round_city or place.country is None:
        return True
    other = country_of(round_city)
    return other is None or other == place.country


# =====================================================================================
# Dedupe
# =====================================================================================


def find_company(conn: sqlite3.Connection, name: str, domain: str | None) -> int | None:
    """An existing company with this domain, else this (normalised) name."""
    if domain:
        d = domain.lower().removeprefix("www.")
        row = conn.execute("SELECT id FROM companies WHERE lower(domain) IN (?, ?) ORDER BY id LIMIT 1", (d, "www." + d)).fetchone()
        if row:
            return int(row[0])
    row = conn.execute("SELECT id FROM companies WHERE normalized_name = ?", (db.normalize_text(name),)).fetchone()
    return int(row[0]) if row else None


def save_company(conn: sqlite3.Connection, name: str, domain: str | None) -> int:
    """The company row for a discovered startup: matched by domain first, then by name."""
    cid = find_company(conn, name, domain)
    if cid is not None:
        if domain and not db.get_company(conn, cid).domain:
            with db.transaction(conn):
                conn.execute("UPDATE companies SET domain = ? WHERE id = ?", (domain, cid))
        return cid
    return db.upsert_company(conn, name, domain=domain).id


__all__ = [
    "FundingRound", "NEWS_SITES", "Place", "USD_RATES", "YCCompany", "YCDirectory", "YCUnavailable", "batch_short",
    "country_of", "extract_rounds", "find_company", "funding_queries", "hq_from", "in_place", "parse_algolia_hits",
    "parse_algolia_opts", "parse_amount", "parse_company_page", "parse_location", "parse_stage", "published_date",
    "round_updates", "same_city", "save_company", "to_usd", "user_location", "verify_rounds", "yc_fallback_query", "yc_slug",
    "yc_updates",
]
