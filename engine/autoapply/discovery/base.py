"""Discovery seam: every job source implements :class:`Source`.

Owner: Workstream A (engine core).

A source returns :class:`DiscoveredJob` values; the pipeline (not the source) persists them
via ``autoapply.db.upsert_company`` + ``autoapply.db.insert_job`` (which dedupes) — see
:func:`persist_discovered`, which does exactly that and also teaches the company watchlist the
ATS / board token found in apply URLs.
Sources must never apply, log in, or submit anything.

Shared helpers used by the public-board sources (greenhouse / lever / ashby / careers):

* :func:`detect_ats` — infer ``(ats, board_token)`` from an apply / board URL.
* :func:`html_to_text`, :func:`parse_salary_text`, :func:`infer_remote` — normalisation.
* :func:`title_matches_roles` — light, lenient pre-filter so a 500-job board doesn't flood
  the DB with postings unrelated to the user's target roles.
* :func:`fetch_json` — GET with bounded retries on 429/5xx.
* :func:`gather_per_company` — run one coroutine per watchlist company with bounded
  concurrency; a failing company is logged and skipped, never raised.
"""

from __future__ import annotations

import asyncio
import html as _html
import logging
import re
import sqlite3
from collections.abc import Awaitable, Callable, Iterable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any, Protocol, runtime_checkable
from urllib.parse import parse_qs, urlsplit

import httpx

from autoapply.config import Preferences
from autoapply.enums import Ats, JobSource, RemotePolicy
from autoapply.models import Company, Job

log = logging.getLogger("autoapply.discovery")

USER_AGENT = "AutoApply/0.1 (personal job search; read-only)"


@dataclass(slots=True)
class DiscoveredJob:
    """A posting as found by a source, before persistence."""

    source: JobSource
    company_name: str
    title: str
    apply_url: str | None = None
    source_url: str | None = None
    ats: Ats = Ats.OTHER
    external_id: str | None = None
    location: str | None = None
    remote: RemotePolicy | None = None
    salary_min: int | None = None
    salary_max: int | None = None
    salary_currency: str | None = None
    description: str | None = None  # plain text
    posted_at: datetime | None = None
    easy_apply: bool = False
    company_domain: str | None = None
    board_token: str | None = None  # lets the pipeline enrich the company watchlist
    raw: dict[str, Any] = field(default_factory=dict)

    def dedupe_key(self) -> str:
        """Same key ``db.insert_job`` dedupes on (normalized company|title|location)."""
        from autoapply.db import make_dedupe_key

        return make_dedupe_key(self.company_name, self.title, self.location)


@dataclass(slots=True)
class DiscoveryContext:
    """Everything a source needs for one discovery pass."""

    preferences: Preferences
    companies: list[Company]  # watchlist (companies.watch = 1)
    http: httpx.AsyncClient
    run_id: str | None = None
    limit_per_company: int | None = None
    #: 0 = the normal pass; 1, 2… = deeper passes that use the next batch of search URLs.
    round: int = 0
    #: Drop postings whose title matches none of ``preferences.roles`` (no-op when roles is
    #: empty). Hard filters + LLM scoring still run on everything that is kept.
    filter_roles: bool = True
    #: Per-company failures from the last pass (``company name -> error``), filled by sources.
    errors: dict[str, str] = field(default_factory=dict)


@runtime_checkable
class Source(Protocol):
    """A discovery source (greenhouse, lever, ashby, careers, linkedin, glassdoor)."""

    name: JobSource

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        """Return postings from this source for the watchlist / preferences in ``ctx``.

        Implementations must be resilient: a failing company is logged and skipped, not
        raised, so one bad board doesn't abort the run.
        """
        ...


# =====================================================================================
# ATS detection
# =====================================================================================

_GH_HOSTS = ("boards.greenhouse.io", "job-boards.greenhouse.io", "job-boards.eu.greenhouse.io", "boards.eu.greenhouse.io")
_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]*$")
_RESERVED_GH = {"embed", "v1", "boards", "jobs"}


def _seg(path: str) -> list[str]:
    return [s for s in path.split("/") if s]


def _token(value: str | None) -> str | None:
    if value and _TOKEN_RE.match(value):
        return value
    return None


def detect_ats(url: str | None) -> tuple[Ats, str | None]:
    """Infer ``(ats, board_token)`` from an apply / board URL.

    Examples::

        https://boards.greenhouse.io/stripe/jobs/123          -> (greenhouse, "stripe")
        https://job-boards.greenhouse.io/embed/job_app?for=x  -> (greenhouse, "x")
        https://boards-api.greenhouse.io/v1/boards/x/jobs     -> (greenhouse, "x")
        https://stripe.com/jobs/listing?gh_jid=123            -> (greenhouse, None)
        https://jobs.lever.co/acme/<uuid>/apply               -> (lever, "acme")
        https://jobs.eu.lever.co/acme/<uuid>                  -> (lever, "eu:acme")
        https://jobs.ashbyhq.com/ramp/<uuid>/application      -> (ashby, "ramp")
        https://nvidia.wd5.myworkdayjobs.com/en-US/Ext/job/.. -> (workday, "nvidia")
        anything else                                         -> (other, None)
    """
    if not url:
        return Ats.OTHER, None
    try:
        parts = urlsplit(url.strip())
    except ValueError:
        return Ats.OTHER, None
    host = (parts.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    segs = _seg(parts.path)
    query = parse_qs(parts.query)

    # ---- Greenhouse ------------------------------------------------------------------
    if host in ("boards-api.greenhouse.io", "api.greenhouse.io"):
        # /v1/boards/{token}/...
        if len(segs) >= 3 and segs[0] == "v1" and segs[1] == "boards":
            return Ats.GREENHOUSE, _token(segs[2])
        return Ats.GREENHOUSE, None
    if host in _GH_HOSTS or host.endswith(".greenhouse.io"):
        if segs[:1] == ["embed"]:
            return Ats.GREENHOUSE, _token((query.get("for") or [None])[0])
        if segs and segs[0] not in _RESERVED_GH:
            return Ats.GREENHOUSE, _token(segs[0])
        return Ats.GREENHOUSE, _token((query.get("for") or [None])[0])
    if "gh_jid" in query:
        return Ats.GREENHOUSE, None

    # ---- Lever -----------------------------------------------------------------------
    if host in ("jobs.lever.co", "jobs.eu.lever.co"):
        tok = _token(segs[0]) if segs else None
        if tok and host == "jobs.eu.lever.co":
            tok = f"eu:{tok}"
        return Ats.LEVER, tok
    if host in ("api.lever.co", "api.eu.lever.co"):
        # /v0/postings/{company}
        if len(segs) >= 3 and segs[0] == "v0" and segs[1] == "postings":
            tok = _token(segs[2])
            if tok and host == "api.eu.lever.co":
                tok = f"eu:{tok}"
            return Ats.LEVER, tok
        return Ats.LEVER, None
    if "lever-source" in query or "lever-origin" in query:
        return Ats.LEVER, None

    # ---- Ashby -----------------------------------------------------------------------
    if host == "jobs.ashbyhq.com":
        return Ats.ASHBY, _token(segs[0]) if segs else None
    if host == "api.ashbyhq.com":
        # /posting-api/job-board/{org}
        if len(segs) >= 3 and segs[0] == "posting-api" and segs[1] == "job-board":
            return Ats.ASHBY, _token(segs[2])
        return Ats.ASHBY, None
    if "ashby_jid" in query:
        return Ats.ASHBY, None

    # ---- Workday ---------------------------------------------------------------------
    if host.endswith(".myworkdayjobs.com") or host.endswith(".myworkdaysite.com") or host.endswith(".workday.com"):
        tenant = host.split(".")[0]
        if host.endswith(".myworkdaysite.com") and segs[:1] == ["recruiting"] and len(segs) >= 2:
            tenant = segs[1]
        return Ats.WORKDAY, _token(tenant)

    return Ats.OTHER, None


def extract_job_id(url: str | None) -> str | None:
    """The ATS posting id embedded in a job URL, when recognisable."""
    if not url:
        return None
    parts = urlsplit(url)
    segs = _seg(parts.path)
    query = parse_qs(parts.query)
    for key in ("gh_jid", "ashby_jid", "token"):
        if query.get(key):
            return query[key][0]
    ats, _ = detect_ats(url)
    if ats is Ats.GREENHOUSE and "jobs" in segs:
        i = segs.index("jobs")
        if i + 1 < len(segs):
            return segs[i + 1]
    if ats in (Ats.LEVER, Ats.ASHBY) and len(segs) >= 2:
        return segs[1]
    return None


# =====================================================================================
# Normalisation helpers
# =====================================================================================


def html_to_text(markup: str | None, *, unescape_first: bool = False) -> str:
    """HTML -> readable plain text (block elements become line breaks).

    ``unescape_first`` handles Greenhouse's ``content`` which is entity-escaped HTML
    (``&lt;p&gt;...``).
    """
    if not markup:
        return ""
    if unescape_first:
        markup = _html.unescape(markup)
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(markup, "html.parser")
    for br in soup.find_all("br"):
        br.replace_with("\n")
    for li in soup.find_all("li"):
        li.insert_before("\n• ")
    for tag in soup.find_all(["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "tr", "section"]):
        tag.insert_after("\n")
    text = soup.get_text()
    text = text.replace("\xa0", " ")
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


_CURRENCY_SYMBOLS = {"$": "USD", "US$": "USD", "€": "EUR", "£": "GBP", "₹": "INR", "C$": "CAD", "CA$": "CAD", "A$": "AUD", "S$": "SGD"}
_CURRENCY_CODES = {"USD", "EUR", "GBP", "INR", "CAD", "AUD", "SGD", "CHF", "JPY", "SEK", "NOK", "DKK", "PLN", "BRL", "MXN", "NZD", "ILS"}
_NUM = r"\d{1,3}(?:[,.\s]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"
_SALARY_RE = re.compile(
    r"(?P<cur1>US\$|C\$|CA\$|A\$|S\$|[$€£₹]|\b(?:" + "|".join(_CURRENCY_CODES) + r")\b)?\s*"
    r"(?P<lo>" + _NUM + r")\s*(?P<lomult>[kKmM]|L|lakhs?|LPA)?\b"
    r"\s*(?:-|–|—|to)\s*"
    r"(?P<cur2>US\$|C\$|CA\$|A\$|S\$|[$€£₹]|\b(?:" + "|".join(_CURRENCY_CODES) + r")\b)?\s*"
    r"(?P<hi>" + _NUM + r")\s*(?P<himult>[kKmM]|L|lakhs?|LPA)?\b"
    r"(?:\s*(?P<cur3>" + "|".join(_CURRENCY_CODES) + r")\b)?"
    r"(?P<tail>[^\n]{0,30})",
)
_HOURLY = re.compile(r"(per|an|/|a)\s*(hour|hr)\b|hourly", re.I)
_MONTHLY = re.compile(r"(per|a|/)\s*month\b|monthly", re.I)


def _to_number(raw: str, mult: str | None) -> float:
    s = raw.replace(" ", "")
    # "120,000" / "120.000" thousands separators vs decimal "211.4"
    if re.fullmatch(r"\d{1,3}(?:[,.]\d{3})+", s):
        s = re.sub(r"[,.]", "", s)
    else:
        s = s.replace(",", "")
    value = float(s)
    m = (mult or "").lower()
    if m == "k":
        value *= 1_000
    elif m == "m":
        value *= 1_000_000
    elif m in ("l", "lakh", "lakhs", "lpa"):
        value *= 100_000
    return value


def annualize(amount: float | None, interval: str | None) -> int | None:
    """Convert an hourly / monthly figure to annual (2080 h, 12 months)."""
    if amount is None:
        return None
    iv = (interval or "year").lower()
    if "hour" in iv:
        return int(round(amount * 2080))
    if "month" in iv:
        return int(round(amount * 12))
    if "week" in iv:
        return int(round(amount * 52))
    return int(round(amount))


def parse_salary_text(text: str | None) -> tuple[int | None, int | None, str | None]:
    """Find the first salary *range* in free text -> ``(annual_min, annual_max, currency)``.

    Handles ``$120,000 - $150,000``, ``$211.4K – $290.6K``, ``USD 120k-150k``,
    ``€60.000 - €80.000``, ``₹30L - ₹45L``, ``$55 - $70 per hour`` (annualised).
    Bare number ranges without a currency or a k/L multiplier are ignored (they are far
    more often years of experience than pay).
    """
    if not text:
        return None, None, None
    for m in _SALARY_RE.finditer(text):
        cur_raw = m.group("cur1") or m.group("cur2") or m.group("cur3")
        mult = m.group("lomult") or m.group("himult")
        if not cur_raw and not mult:
            continue
        try:
            lo = _to_number(m.group("lo"), m.group("lomult") or m.group("himult"))
            hi = _to_number(m.group("hi"), m.group("himult") or m.group("lomult"))
        except ValueError:
            continue
        tail = m.group("tail") or ""
        interval = "hour" if _HOURLY.search(tail) else "month" if _MONTHLY.search(tail) else "year"
        lo_a, hi_a = annualize(lo, interval), annualize(hi, interval)
        if lo_a is None or hi_a is None or hi_a < lo_a:
            continue
        if interval == "year" and hi_a < 1_000:  # "3-5 years" style false positive with a stray symbol
            continue
        currency = None
        if cur_raw:
            currency = _CURRENCY_SYMBOLS.get(cur_raw, cur_raw.upper())
        elif (mult or "").lower() in ("l", "lakh", "lakhs", "lpa"):
            currency = "INR"
        return lo_a, hi_a, currency
    return None, None, None


_REMOTE_RE = re.compile(r"\b(remote|work from home|wfh|distributed|anywhere)\b", re.I)
_HYBRID_RE = re.compile(r"\bhybrid\b", re.I)
_ONSITE_RE = re.compile(r"\b(on[- ]?site|in[- ]office|in[- ]person)\b", re.I)


def infer_remote(*texts: str | None, explicit: str | None = None) -> RemotePolicy | None:
    """Remote policy from an explicit ATS value (``remote``/``Hybrid``/``on-site``/``OnSite``)
    or, failing that, from location / title strings. Description bodies should NOT be passed
    (they mention "remote" in benefits boilerplate)."""
    if explicit:
        e = explicit.strip().lower().replace("_", "-")
        if e in ("remote", "fully-remote", "fullyremote"):
            return RemotePolicy.REMOTE
        if e == "hybrid":
            return RemotePolicy.HYBRID
        if e in ("on-site", "onsite", "on site", "in-office", "office"):
            return RemotePolicy.ONSITE
    joined = " ".join(t for t in texts if t)
    if not joined:
        return None
    if _HYBRID_RE.search(joined):
        return RemotePolicy.HYBRID
    if _REMOTE_RE.search(joined):
        return RemotePolicy.REMOTE
    if _ONSITE_RE.search(joined):
        return RemotePolicy.ONSITE
    return None


def parse_datetime(value: Any) -> datetime | None:
    """ISO-8601 string or epoch milliseconds -> aware UTC datetime (None if unparsable)."""
    if value is None or value == "":
        return None
    try:
        if isinstance(value, (int, float)):
            secs = value / 1000 if value > 10_000_000_000 else value
            return datetime.fromtimestamp(secs, tz=UTC)
        s = str(value).strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        return dt if dt.tzinfo else dt.replace(tzinfo=UTC)
    except (ValueError, OverflowError, OSError):
        return None


# ---- role pre-filter ----------------------------------------------------------------

_ROLE_STOP = {"a", "an", "the", "of", "and", "or", "for", "to", "in", "at", "with", "i", "ii", "iii", "iv"}
_ROLE_SYNONYMS: dict[str, set[str]] = {
    "engineer": {"engineer", "engineering", "developer", "dev", "swe", "programmer"},
    "developer": {"engineer", "engineering", "developer", "dev", "swe", "programmer"},
    "backend": {"backend", "back", "server", "platform", "infrastructure"},
    "frontend": {"frontend", "front", "ui", "web"},
    "fullstack": {"fullstack", "full", "stack"},
    "ml": {"ml", "machine", "learning", "ai"},
    "manager": {"manager", "management", "lead", "head"},
    "scientist": {"scientist", "science", "research", "researcher"},
    "sre": {"sre", "reliability", "devops", "infrastructure"},
    "devops": {"devops", "sre", "reliability", "infrastructure", "platform"},
}
# Seniority words never decide a role match (handled by scoring's seniority filter).
_ROLE_IGNORE = {"senior", "sr", "junior", "jr", "staff", "principal", "lead", "mid", "level", "entry"}


def _role_tokens(text: str) -> list[str]:
    from autoapply.db import normalize_text

    norm = normalize_text(text).replace("back end", "backend").replace("front end", "frontend")
    norm = norm.replace("full stack", "fullstack").replace("machine learning", "ml")
    return [t for t in norm.split() if t not in _ROLE_STOP]


def title_matches_roles(title: str, roles: Iterable[str]) -> bool:
    """Lenient match of a posting title against target roles.

    A role matches when every one of its significant words (seniority words ignored) appears
    in the title, either literally or via a small synonym table ("Backend Engineer" matches
    "Senior Software Engineer, Backend" and "Back End Developer"). Empty ``roles`` matches all.
    """
    roles = [r for r in roles if r and r.strip()]
    if not roles:
        return True
    title_tokens = set(_role_tokens(title))
    for role in roles:
        needed = [t for t in _role_tokens(role) if t not in _ROLE_IGNORE]
        if not needed:
            return True
        if all(t in title_tokens or (_ROLE_SYNONYMS.get(t, set()) & title_tokens) for t in needed):
            return True
    return False


# =====================================================================================
# HTTP + per-company fan-out
# =====================================================================================


class DiscoveryHTTPError(Exception):
    """A board request failed after retries (status or transport)."""


async def fetch_json(
    http: httpx.AsyncClient,
    url: str,
    *,
    params: dict[str, Any] | None = None,
    retries: int = 2,
    backoff: float = 0.5,
) -> Any:
    """GET ``url`` and decode JSON, retrying 429/5xx/transport errors with backoff.
    404 raises immediately (board token wrong / board removed)."""
    last: Exception | None = None
    for attempt in range(retries + 1):
        try:
            resp = await http.get(url, params=params, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        except httpx.TransportError as e:
            last = e
        else:
            if resp.status_code == 200:
                try:
                    return resp.json()
                except ValueError as e:
                    raise DiscoveryHTTPError(f"GET {url}: invalid JSON") from e
            if resp.status_code in (429, 500, 502, 503, 504):
                last = DiscoveryHTTPError(f"GET {url}: HTTP {resp.status_code}")
            else:
                raise DiscoveryHTTPError(f"GET {url}: HTTP {resp.status_code}")
        if attempt < retries:
            await asyncio.sleep(backoff * (2**attempt))
    raise DiscoveryHTTPError(str(last)) from last


def companies_for(ctx: DiscoveryContext, ats: Ats) -> list[Company]:
    """Watchlist companies on ``ats`` that have a board token."""
    out = []
    for c in ctx.companies:
        if c.ats is not None and Ats(c.ats) is ats and c.board_token:
            out.append(c)
    return out


async def gather_per_company(
    ctx: DiscoveryContext,
    companies: list[Company],
    fetch: Callable[[Company], Awaitable[list[DiscoveredJob]]],
    *,
    concurrency: int = 4,
    source: str = "",
) -> list[DiscoveredJob]:
    """Run ``fetch`` per company (bounded concurrency). Failures are logged, recorded in
    ``ctx.errors`` and skipped. Applies ``limit_per_company`` and the role pre-filter."""
    sem = asyncio.Semaphore(max(1, concurrency))

    async def one(company: Company) -> list[DiscoveredJob]:
        async with sem:
            try:
                jobs = await fetch(company)
            except Exception as e:  # resilient by contract
                log.warning("%s discovery failed for %s: %s", source or "board", company.name, e)
                ctx.errors[company.name] = str(e)
                return []
        return filter_jobs(ctx, jobs)

    results = await asyncio.gather(*(one(c) for c in companies))
    return [j for batch in results for j in batch]


def filter_jobs(ctx: DiscoveryContext, jobs: list[DiscoveredJob]) -> list[DiscoveredJob]:
    if ctx.filter_roles and ctx.preferences.roles:
        jobs = [j for j in jobs if title_matches_roles(j.title, ctx.preferences.roles)]
    if ctx.limit_per_company is not None:
        jobs = jobs[: ctx.limit_per_company]
    return jobs


# =====================================================================================
# Persistence helper (used by the pipeline and the CLI)
# =====================================================================================


def persist_discovered(conn: sqlite3.Connection, jobs: Iterable[DiscoveredJob]) -> list[tuple[Job, bool]]:
    """Upsert each job's company and insert the job (deduped by ``db.insert_job``).

    Returns ``(job, created)`` per input. The company's ATS / board token is learned from
    the posting (watchlist enrichment) but ``watch`` is never switched on automatically.
    """
    from autoapply import db

    out: list[tuple[Job, bool]] = []
    for dj in jobs:
        ats, token = dj.ats, dj.board_token
        if (ats is Ats.OTHER or token is None) and dj.apply_url:
            d_ats, d_tok = detect_ats(dj.apply_url)
            if ats is Ats.OTHER:
                ats = d_ats
            token = token or d_tok
        existing = db.get_company_by_name(conn, dj.company_name)
        company = db.upsert_company(
            conn,
            dj.company_name,
            domain=dj.company_domain if not (existing and existing.domain) else None,
            ats=ats if ats not in (Ats.OTHER, Ats.LINKEDIN_EASY_APPLY) and not (existing and existing.ats) else None,
            board_token=token if not (existing and existing.board_token) else None,
        )
        job, created = db.insert_job(
            conn,
            company_id=company.id,
            source=dj.source,
            title=dj.title,
            location=dj.location,
            apply_url=dj.apply_url,
            source_url=dj.source_url,
            ats=dj.ats if dj.ats is not Ats.OTHER else ats,
            external_id=dj.external_id,
            remote=dj.remote.value if dj.remote else None,
            salary_min=dj.salary_min,
            salary_max=dj.salary_max,
            salary_currency=dj.salary_currency,
            description=dj.description,
            posted_at=dj.posted_at,
            easy_apply=dj.easy_apply,
            raw=dj.raw,
        )
        out.append((job, created))
    return out
