"""Source #3: the company's own pages, over plain HTTP (no browser, background-safe).

Fetches a handful of likely pages (``/team``, ``/about``, ``/leadership``, ``/company``,
``/contact``, ``/careers``, ``/press``, ``/.well-known/security.txt``) on the company domain
only, and reads:

* JSON-LD ``Person`` objects (name, jobTitle, email);
* published addresses (``mailto:`` and plain text) on the domain: people's addresses become
  pattern evidence, role mailboxes (careers@, jobs@) become ``role_mailbox`` contacts;
* names and titles from team-like pages through the model, kept only when on the page;
* the homepage ``meta description`` / ``og:description``: the "what they do" line drafts may cite;
* links to the company's GitHub org (used by :mod:`github_org`).
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from urllib.parse import urljoin, urlsplit

import httpx

from autoapply.enums import EvidenceKind
from autoapply.llm.provider import LLMProvider, TokenUsage
from autoapply.outreach import patterns
from autoapply.outreach.domains import USER_AGENT, registrable_domain
from autoapply.outreach.sources.extract import (
    Person,
    appears_in,
    emails_in,
    extract_people,
    link_emails,
    norm_text,
    page_text,
    snippet_around,
)

log = logging.getLogger("autoapply.outreach.sources.site_pages")

#: Paths tried, best first. ``/`` is always fetched (homepage meta + links).
PATHS: tuple[str, ...] = ("/", "/team", "/about", "/about-us", "/leadership", "/company", "/people", "/contact",
                          "/careers", "/press", "/.well-known/security.txt")
MAX_FETCHES = 9
#: Model extraction on at most this many people-like pages per company.
MAX_EXTRACT_PAGES = 3
_PEOPLE_PATH = re.compile(r"team|about|leadership|people|company|founders|management", re.I)
_GITHUB_ORG = re.compile(r"https?://(?:www\.)?github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/?(?:[\"'#?\s]|$)")


@dataclass(slots=True)
class SiteFindings:
    people: list[Person] = field(default_factory=list)
    role_mailboxes: list[tuple[str, str]] = field(default_factory=list)  # (email, url)
    samples: list[dict] = field(default_factory=list)  # pattern evidence {name, email, source, url}
    summary: str | None = None
    summary_url: str | None = None
    github_orgs: list[str] = field(default_factory=list)
    pages: list[str] = field(default_factory=list)


def jsonld_people(html: str) -> list[dict]:
    """``Person`` objects in JSON-LD (anywhere in @graph / lists / nested ``employee``)."""
    out: list[dict] = []
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
                t = d.get("@type")
                if t == "Person" or (isinstance(t, list) and "Person" in t):
                    out.append(d)
                for k in ("@graph", "employee", "employees", "founder", "founders", "member", "members", "author"):
                    if k in d:
                        stack.append(d[k])
    return out


def homepage_summary(html: str) -> str | None:
    """``og:description`` or ``meta name=description`` (company evidence for drafts)."""
    for rx in (r'<meta[^>]+property=["\']og:description["\'][^>]+content=["\']([^"\']{20,600})["\']',
               r'<meta[^>]+content=["\']([^"\']{20,600})["\'][^>]+property=["\']og:description["\']',
               r'<meta[^>]+name=["\']description["\'][^>]+content=["\']([^"\']{20,600})["\']',
               r'<meta[^>]+content=["\']([^"\']{20,600})["\'][^>]+name=["\']description["\']'):
        m = re.search(rx, html, re.I)
        if m:
            import html as _html

            return re.sub(r"\s+", " ", _html.unescape(m.group(1))).strip()
    return None


def security_txt_emails(text: str) -> list[str]:
    return [m.group(1).lower() for m in re.finditer(r"(?im)^\s*contact:\s*mailto:([^\s>]+)", text or "")]


def github_orgs(html: str) -> list[str]:
    skip = {"features", "about", "pricing", "login", "join", "orgs", "topics", "sponsors", "marketplace", "apps", "site"}
    out: list[str] = []
    for m in _GITHUB_ORG.finditer(html or ""):
        org = m.group(1)
        if org.lower() not in skip and org not in out:
            out.append(org)
    return out


def parse_page(url: str, html: str, domain: str) -> SiteFindings:
    """Everything except model extraction, from one fetched page (pure; fixture-tested)."""
    f = SiteFindings(pages=[url])
    is_txt = url.endswith(".txt")
    text = html if is_txt else page_text(html)
    tn = norm_text(text)
    if not is_txt:
        for d in jsonld_people(html):
            name = re.sub(r"\s+", " ", str(d.get("name") or "")).strip()
            if not name or not appears_in(name, tn) and not appears_in(name, norm_text(html)):
                continue
            title = d.get("jobTitle")
            title = str(title).strip() if isinstance(title, str) else None
            email = str(d.get("email") or "").removeprefix("mailto:").lower() or None
            if email and not email.endswith("@" + domain):
                email = None
            f.people.append(Person(name=name, title=title, email=email, url=url, kind=EvidenceKind.COMPANY_PAGE,
                                   snippet=snippet_around(text, name)))
        f.github_orgs = github_orgs(html)
        if urlsplit(url).path in ("", "/"):
            f.summary, f.summary_url = homepage_summary(html), url
    emails = security_txt_emails(html) if is_txt else emails_in(html, domain=domain)
    left = link_emails(f.people, [e for e in emails if e.endswith("@" + domain) or e.split("@")[1].endswith("." + domain)])
    for e in left:
        if patterns.is_role_mailbox(e):
            f.role_mailboxes.append((e, url))
    for p in f.people:
        if p.email:
            f.samples.append({"name": p.name, "email": p.email, "source": "company_page", "url": url})
    return f


async def fetch(http: httpx.AsyncClient, url: str, domain: str) -> tuple[str, str] | None:
    """(final url, body) when the page answered 2xx on the company's own domain."""
    try:
        r = await http.get(url, headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=15)
    except httpx.HTTPError as e:
        log.debug("site page %s: %s", url, e)
        return None
    if r.status_code >= 400:
        return None
    final = str(r.url)
    if registrable_domain(urlsplit(final).hostname) != registrable_domain(domain):
        return None  # redirected off the company's site
    ctype = r.headers.get("content-type", "")
    if "html" not in ctype and "text/plain" not in ctype and not url.endswith(".txt"):
        return None
    return final, r.text[:600_000]


async def from_site(
    http: httpx.AsyncClient, domain: str, *, company: str, llm: LLMProvider | None = None,
    usage: TokenUsage | None = None, max_fetches: int = MAX_FETCHES,
) -> SiteFindings:
    out = SiteFindings()
    seen: set[str] = set()
    extract_budget = MAX_EXTRACT_PAGES
    for path in PATHS[:max_fetches]:
        url = urljoin(f"https://{domain}", path)
        got = await fetch(http, url, domain)
        if got is None:
            continue
        final, body = got
        if final in seen:
            continue
        seen.add(final)
        f = parse_page(final, body, domain)
        out.pages.append(final)
        out.summary = out.summary or f.summary
        out.summary_url = out.summary_url or (f.summary_url if f.summary else None)
        out.github_orgs += [o for o in f.github_orgs if o not in out.github_orgs]
        out.role_mailboxes += [m for m in f.role_mailboxes if m[0] not in {x[0] for x in out.role_mailboxes}]
        people = list(f.people)
        if llm is not None and extract_budget > 0 and not final.endswith(".txt") and _PEOPLE_PATH.search(urlsplit(final).path):
            extract_budget -= 1
            text = page_text(body)
            for name, title in await extract_people(llm, text, company=company, usage=usage):
                if not any(p.name == name for p in people):
                    people.append(Person(name=name, title=title, url=final, kind=EvidenceKind.COMPANY_PAGE,
                                         snippet=snippet_around(text, name)))
            leftovers = [e for e in emails_in(body, domain=domain) if not any(p.email == e for p in people)]
            link_emails(people, leftovers)
        for p in people:
            if not any(q.name == p.name for q in out.people):
                out.people.append(p)
            if p.email and not any(s["email"] == p.email for s in out.samples):
                out.samples.append({"name": p.name, "email": p.email, "source": "company_page", "url": final})
    return out


__all__ = ["PATHS", "SiteFindings", "from_site", "github_orgs", "homepage_summary", "jsonld_people", "parse_page", "security_txt_emails"]
