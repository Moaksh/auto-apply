"""A company's email domain (plan §B.2), its MX provider, and its stored address pattern.

Resolution order (only domains with MX records are kept):

1. a non-ATS host in ``companies.careers_url`` or the job's ``apply_url``;
2. the company website linked from the ATS posting / board page (JSON-LD
   ``hiringOrganization.sameAs`` / ``url``, or the board's own "website" link);
3. one Google query, done later by the Google step (``sources.google_people.find_official_site``).

The MX lookup (``dnspython``) tells whether the domain can receive mail at all and who hosts it
(Google / Microsoft / other). We never connect to the mail server: no ``RCPT`` probing.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import sqlite3
from collections.abc import Callable
from datetime import timedelta
from typing import Any
from urllib.parse import urljoin, urlsplit

import httpx

from autoapply import db
from autoapply.enums import MxProvider
from autoapply.models import Company, DomainPattern, Job, format_ts, now_ts, parse_ts, utcnow
from autoapply.outreach import patterns

log = logging.getLogger("autoapply.outreach.domains")

USER_AGENT = "AutoApply/0.1 (personal job search assistant; read-only)"
MX_RECHECK_DAYS = 30
MAX_SAMPLES = 60

#: Hosts that are never a company's own domain (ATSs, job boards, social sites, search).
AGGREGATOR_HOSTS: tuple[str, ...] = (
    "greenhouse.io", "lever.co", "ashbyhq.com", "myworkdayjobs.com", "workday.com", "myworkdaysite.com", "linkedin.com",
    "glassdoor.com", "glassdoor.co.in", "glassdoor.co.uk", "indeed.com", "naukri.com", "google.com", "googleusercontent.com",
    "smartrecruiters.com", "workable.com", "icims.com", "taleo.net", "oraclecloud.com", "jobvite.com", "bamboohr.com",
    "breezy.hr", "recruitee.com", "wellfound.com", "angel.co", "instahyre.com", "cutshort.io", "ycombinator.com",
    "crunchbase.com", "builtin.com", "x.com", "twitter.com", "facebook.com", "instagram.com", "youtube.com", "github.com",
    "github.io", "medium.com", "wikipedia.org", "tracxn.com", "zoominfo.com", "rocketreach.co", "apollo.io", "hunter.io",
    "keka.com", "darwinbox.in", "freshteam.com", "zohorecruit.com", "teamtailor.com", "personio.de", "rippling.com",
    "dover.com", "gem.com", "hire.lever.co", "apply.workable.com", "successfactors.com", "sap.com",
)
#: Second-level public suffixes where the registrable domain has three labels.
_TWO_PART_SUFFIXES = frozenset({"co.in", "co.uk", "com.au", "co.jp", "com.br", "com.sg", "co.nz", "org.uk", "ac.uk", "net.in",
                                "org.in", "firm.in", "gen.in", "ind.in", "com.mx", "co.za", "com.cn", "co.id", "com.my"})

MxResolver = Callable[[str], list[str]]  # domain -> MX host names (blocking); [] = no MX


def registrable_domain(host: str | None) -> str | None:
    """``careers.eu.acme.co.in`` -> ``acme.co.in`` (good enough for company sites)."""
    h = (host or "").lower().strip(".").removeprefix("www.")
    if not h or "." not in h or re.fullmatch(r"[\d.]+", h):
        return None
    labels = h.split(".")
    n = 3 if ".".join(labels[-2:]) in _TWO_PART_SUFFIXES and len(labels) >= 3 else 2
    return ".".join(labels[-n:])


def is_aggregator(host: str | None) -> bool:
    h = (host or "").lower().removeprefix("www.")
    return any(h == a or h.endswith("." + a) for a in AGGREGATOR_HOSTS)


def domain_from_url(url: str | None) -> str | None:
    """The company domain behind a URL, or None for an ATS / job board / social host."""
    if not url:
        return None
    try:
        host = urlsplit(url if "//" in url else f"https://{url}").hostname
    except ValueError:
        return None
    if not host or is_aggregator(host):
        return None
    return registrable_domain(host)


def _jsonld_objects(html: str) -> list[Any]:
    out: list[Any] = []
    for m in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', html, re.S | re.I):
        try:
            data = json.loads(m.group(1).strip())
        except (json.JSONDecodeError, ValueError):
            continue
        stack = [data]
        while stack:
            d = stack.pop()
            if isinstance(d, list):
                stack.extend(d)
            elif isinstance(d, dict):
                out.append(d)
                if "@graph" in d:
                    stack.append(d["@graph"])
    return out


def website_from_posting(html: str, base_url: str = "") -> str | None:
    """Company domain linked from an ATS posting / board page (JSON-LD first, then a link
    labelled as the company's website / home, then the logo link)."""
    for obj in _jsonld_objects(html):
        org = obj.get("hiringOrganization") if isinstance(obj, dict) else None
        if isinstance(org, dict):
            for key in ("sameAs", "url"):
                vals = org.get(key)
                for v in vals if isinstance(vals, list) else [vals]:
                    d = domain_from_url(v) if isinstance(v, str) else None
                    if d:
                        return d
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    candidates: list[str] = []
    for a in soup.find_all("a", href=True):
        text = (a.get_text(" ", strip=True) or "").lower()
        label = " ".join(str(a.get(k) or "") for k in ("aria-label", "title", "class")).lower()
        href = urljoin(base_url, a["href"])
        if re.search(r"\b(website|home ?page|company site|visit)\b", text + " " + label) or (a.find("img") and "logo" in (label + str(a.find("img"))).lower()):
            candidates.append(href)
    for href in candidates:
        d = domain_from_url(href)
        if d:
            return d
    return None


async def resolve_domain(conn: sqlite3.Connection, company: Company, *, job: Job | None, http: httpx.AsyncClient) -> str | None:
    """Find (and store in ``companies.domain``) the company's own domain from what we already
    know, without Google. Returns None when only the Google step can tell."""
    if company.domain:
        return company.domain
    found: str | None = None
    for url in (company.careers_url, job.apply_url if job else None, job.source_url if job else None):
        found = domain_from_url(url)
        if found:
            break
    if found is None and job is not None and job.apply_url:
        try:
            r = await http.get(job.apply_url, headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=20)
            if r.status_code < 400:
                found = website_from_posting(r.text, str(r.url))
                final = domain_from_url(str(r.url))
                found = found or final
        except httpx.HTTPError as e:
            log.info("domain: could not read %s: %s", job.apply_url, e)
    if found:
        db.upsert_company(conn, company.name, domain=found)
    return found


# ---- MX --------------------------------------------------------------------------------


def dns_mx_hosts(domain: str) -> list[str]:
    """MX hosts of ``domain`` via dnspython ([] when the domain has none / does not exist)."""
    import dns.exception
    import dns.resolver

    try:
        answers = dns.resolver.resolve(domain, "MX", lifetime=8.0)
    except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer, dns.resolver.NoNameservers):
        return []
    except dns.exception.Timeout:
        raise
    return [str(r.exchange).rstrip(".").lower() for r in answers]


def classify_mx(hosts: list[str]) -> MxProvider:
    if not hosts or all(h in ("", ".") for h in hosts):
        return MxProvider.NONE
    joined = " ".join(hosts)
    if re.search(r"(google\.com|googlemail\.com)$|aspmx|google", joined):
        return MxProvider.GOOGLE
    if re.search(r"outlook\.com|protection\.outlook|microsoft", joined):
        return MxProvider.MICROSOFT
    return MxProvider.OTHER


async def check_mx(conn: sqlite3.Connection, domain: str, resolver: MxResolver, *, company_id: int | None = None) -> MxProvider | None:
    """MX provider of ``domain`` (cached ``MX_RECHECK_DAYS`` in ``domain_patterns``). None when
    the lookup itself failed (network): callers keep going rather than reject the domain."""
    row = get_pattern(conn, domain)
    if row and row.mx_provider and row.checked_at and utcnow() - row.checked_at < timedelta(days=MX_RECHECK_DAYS):
        return row.mx_provider
    try:
        hosts = await asyncio.to_thread(resolver, domain)
    except Exception as e:  # noqa: BLE001 - DNS trouble is not "no MX"
        log.info("MX lookup for %s failed: %s", domain, e)
        return row.mx_provider if row else None
    provider = classify_mx(hosts)
    _ensure_row(conn, domain, company_id)
    with db.transaction(conn):
        conn.execute("UPDATE domain_patterns SET mx_provider = ?, checked_at = ? WHERE domain = ?", (provider.value, now_ts(), domain))
    return provider


# ---- patterns ----------------------------------------------------------------------------


def get_pattern(conn: sqlite3.Connection, domain: str) -> DomainPattern | None:
    row = conn.execute("SELECT * FROM domain_patterns WHERE domain = ?", (domain.lower(),)).fetchone()
    return DomainPattern.from_row(row) if row else None  # type: ignore[return-value]


def _ensure_row(conn: sqlite3.Connection, domain: str, company_id: int | None) -> None:
    with db.transaction(conn):
        conn.execute("INSERT OR IGNORE INTO domain_patterns(domain, company_id) VALUES (?, ?)", (domain.lower(), company_id))
        if company_id is not None:
            conn.execute("UPDATE domain_patterns SET company_id = COALESCE(company_id, ?) WHERE domain = ?", (company_id, domain.lower()))


def add_samples(conn: sqlite3.Connection, domain: str, samples: list[dict[str, Any]], *, company_id: int | None = None,
                small_company: bool = False) -> patterns.PatternInference:
    """Merge (name, email) evidence for the domain and re-infer its pattern. Each sample is
    ``{name, email, source, url}``; addresses off the domain and role mailboxes are ignored."""
    domain = domain.lower()
    _ensure_row(conn, domain, company_id)
    with db.transaction(conn):
        row = get_pattern(conn, domain)
        current = list(row.samples) if row else []
        seen = {str(s.get("email", "")).lower() for s in current}
        for s in samples:
            email = str(s.get("email") or "").lower()
            if not email.endswith("@" + domain) or email in seen or patterns.is_role_mailbox(email) or not s.get("name"):
                continue
            seen.add(email)
            current.append({"name": s["name"], "email": email, "source": s.get("source"), "url": s.get("url")})
        current = current[-MAX_SAMPLES:]
        inf = patterns.infer_pattern([(s["name"], s["email"]) for s in current], small_company=small_company)
        bounces = row.bounces if row else 0
        conf = max(0, inf.confidence - patterns.BOUNCE_PENALTY * bounces)
        pattern = inf.pattern
        if row and row.pattern and row.pattern != inf.pattern and inf.supporting == 0:
            pattern = row.pattern  # a demoted / chosen pattern stands until real evidence arrives
        conn.execute("UPDATE domain_patterns SET samples = ?, pattern = ?, confidence = ? WHERE domain = ?",
                     (db._j(current), pattern, conf, domain))
    return patterns.PatternInference(pattern, conf, inf.supporting, inf.contradicting)


def register_bounce(conn: sqlite3.Connection, domain: str) -> DomainPattern | None:
    """A hard bounce on a pattern-guessed address: -20 confidence; after two, the next-best
    pattern is promoted (callers re-check drafts that used the old one)."""
    row = get_pattern(conn, domain)
    if row is None:
        return None
    with db.transaction(conn):
        bounces = row.bounces + 1
        conf = max(0, row.confidence - patterns.BOUNCE_PENALTY)
        pattern = row.pattern
        if bounces >= patterns.BOUNCES_BEFORE_DEMOTION and row.pattern:
            pattern = patterns.next_best_pattern([(s["name"], s["email"]) for s in row.samples], row.pattern)
            bounces, conf = 0, patterns.NO_EVIDENCE_CONFIDENCE
        conn.execute("UPDATE domain_patterns SET bounces = ?, confidence = ?, pattern = ? WHERE domain = ?",
                     (bounces, conf, pattern, domain.lower()))
    return get_pattern(conn, domain)


def mx_is_fresh(row: DomainPattern | None) -> bool:
    return bool(row and row.checked_at and utcnow() - parse_ts(format_ts(row.checked_at)) < timedelta(days=MX_RECHECK_DAYS))


__all__ = [
    "AGGREGATOR_HOSTS", "MxResolver", "add_samples", "check_mx", "classify_mx", "dns_mx_hosts", "domain_from_url",
    "get_pattern", "is_aggregator", "register_bounce", "registrable_domain", "resolve_domain", "website_from_posting",
]
