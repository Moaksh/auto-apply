"""Source #5: Google result pages, read in the agent's visible Chrome at human pace.

Only Google's own result pages are ever opened. Results that point at LinkedIn are read for
their *titles* ("Jane Doe – Senior Recruiter – Acme | LinkedIn"); the profile URL is stored as
a reference and **never opened**: :class:`GoogleOnlyPage` refuses any navigation that is not a
Google search, and LinkedIn / Glassdoor in particular (the same hosts as
``apply.agentic.BLOCKED_HOSTS``).

Budget: ``db.increment_source_sessions(conn, key)`` per result page (``people_finder`` for
people and referrers, ``prospect_finder`` for company search), capped per day. A CAPTCHA
(``/sorry/``) stops Google reading for ``CAPTCHA_REST_HOURS``.
"""

from __future__ import annotations

import logging
import re
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from datetime import timedelta
from urllib.parse import quote_plus, urlsplit

from autoapply import db
from autoapply.discovery.company_finder import CAPTCHA_REST_HOURS, _unwrap_google
from autoapply.discovery.linkedin import BrowserFactory, HumanPacer, ListingPage, PageState, _soup, clean_text, detect_page_state
from autoapply.enums import EvidenceKind
from autoapply.models import utcnow
from autoapply.outreach import patterns
from autoapply.outreach.sources.extract import EMAIL_RX, Person, plausible_name

log = logging.getLogger("autoapply.outreach.sources.google")

GOOGLE_SEARCH = "https://www.google.com/search"
PEOPLE_KEY = "people_finder"
PROSPECT_KEY = "prospect_finder"
#: Daily result pages for company search (people use ``preferences.people_finder_visits_per_day``).
PROSPECT_VISITS_PER_DAY = 6
_REST_META = "google_reader_rest_until"
_CAPTCHA_SELECTORS = {"captcha": ["form#captcha-form", "#recaptcha"], "login_wall": []}
#: Never navigated to, whatever a result links to (mirrors apply.agentic.BLOCKED_HOSTS).
NEVER_OPEN = ("linkedin.com", "glassdoor.com", "glassdoor.co.uk", "glassdoor.co.in", "glassdoor.ca")


class NavigationRefused(Exception):
    """The outreach browser only opens Google result pages."""


def _host(url: str) -> str:
    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def is_google_search(url: str) -> bool:
    h = _host(url)
    return (h == "www.google.com" or h == "google.com" or re.fullmatch(r"(www\.)?google\.[a-z.]{2,6}", h) is not None) \
        and urlsplit(url).path in ("/search", "/sorry/index", "/sorry/")


class GoogleOnlyPage:
    """Wraps a browser tab: ``goto`` refuses anything but a Google search URL."""

    def __init__(self, page: ListingPage) -> None:
        self._page = page

    @property
    def url(self) -> str:
        return self._page.url

    async def goto(self, url: str) -> None:
        h = _host(url)
        if any(h == b or h.endswith("." + b) for b in NEVER_OPEN):
            raise NavigationRefused(f"refusing to open {h}: LinkedIn / Glassdoor are never automated")
        if not is_google_search(url):
            raise NavigationRefused(f"the outreach browser only opens Google result pages, not {url!r}")
        await self._page.goto(url)

    async def content(self) -> str:
        return await self._page.content()

    async def scroll(self, pixels: int) -> None:
        await self._page.scroll(pixels)

    async def close(self) -> None:
        await self._page.close()


def search_url(query: str) -> str:
    return f"{GOOGLE_SEARCH}?q={quote_plus(query)}&hl=en&num=20"


# ---- parsing (pure) ------------------------------------------------------------------------


@dataclass(slots=True)
class SerpHit:
    title: str
    url: str
    snippet: str


def parse_results(html: str) -> list[SerpHit]:
    """Organic results (title, unwrapped URL, snippet) in page order."""
    soup = _soup(html)
    out: list[SerpHit] = []
    seen: set[str] = set()
    for h3 in soup.find_all("h3"):
        a = h3.find_parent("a", href=True)
        if a is None:
            continue
        url = _unwrap_google(a["href"])
        if not url.startswith("http") or _host(url).endswith("google.com") or url in seen:
            continue
        seen.add(url)
        title = clean_text(h3.get_text(" ", strip=True)) or ""
        block = a
        for _ in range(4):  # climb to the result container to find the snippet text
            if block.parent is None:
                break
            block = block.parent
            if len(block.get_text(" ", strip=True)) > len(title) + 40:
                break
        text = clean_text(block.get_text(" ", strip=True)) or ""
        snippet = text.replace(title, "", 1).strip()
        out.append(SerpHit(title=title, url=url, snippet=snippet[:400]))
    return out


_NOT_NAME_WORDS = frozenset({"at", "jobs", "job", "careers", "hiring", "linkedin", "company", "the", "and", "&", "team", "inc"})
_LI_SEP = re.compile(r"\s+[-–—|·]\s+")


def parse_linkedin_title(title: str) -> tuple[str, str | None, str | None] | None:
    """``"Jane Doe – Senior Recruiter – Acme | LinkedIn"`` -> (name, title, company)."""
    t = re.sub(r"\s*\|\s*LinkedIn\s*$", "", title or "", flags=re.I).strip()
    t = re.sub(r"\s*[-–—]\s*LinkedIn\s*$", "", t, flags=re.I).strip()
    parts = [p.strip() for p in _LI_SEP.split(t) if p.strip()]
    if not parts:
        return None
    name = re.sub(r"\s*\(.*?\)\s*", " ", parts[0]).strip()  # "Jane Doe (She/Her)"
    name = re.sub(r",\s*(MBA|PhD|PHR|SHRM.*)$", "", name).strip()
    if not plausible_name(name) or {w.lower() for w in name.split()} & _NOT_NAME_WORDS:
        return None
    job = parts[1] if len(parts) > 1 else None
    company = parts[2] if len(parts) > 2 else None
    if job and " at " in job and not company:
        job, company = job.split(" at ", 1)
    return name, job, company


def is_linkedin_profile(url: str) -> bool:
    h = _host(url)
    return (h == "linkedin.com" or h.endswith(".linkedin.com")) and urlsplit(url).path.startswith("/in/")


def people_from_results(hits: list[SerpHit], company: str) -> list[Person]:
    """People from LinkedIn-titled results whose title or snippet names the company."""
    comp = re.sub(r"[^a-z0-9]", "", company.lower())
    out: list[Person] = []
    for h in hits:
        if not is_linkedin_profile(h.url):
            continue
        parsed = parse_linkedin_title(h.title)
        if parsed is None:
            continue
        name, job, at = parsed
        hay = re.sub(r"[^a-z0-9]", "", f"{h.title} {h.snippet}".lower())
        if comp and comp not in hay:
            continue
        if at and comp and comp not in re.sub(r"[^a-z0-9]", "", at.lower()):
            continue  # the title names a different (current) employer
        loc = None
        m = re.search(r"(?:Location|Lives in)\s*[:·]?\s*([A-Z][\w .,-]{2,40})", h.snippet)
        if m:
            loc = m.group(1).strip(" ·.")
        out.append(Person(name=name, title=job, url=h.url, linkedin_url=h.url.split("?")[0], kind=EvidenceKind.GOOGLE_SERP,
                          snippet=f"{h.title} — {h.snippet}"[:280], location=loc))
    return out


def email_samples_from_results(hits: list[SerpHit], domain: str) -> list[dict]:
    """(name, email) pairs from snippets of an ``"@domain"`` query: an address on the domain with
    a capitalised name right before it whose own pattern produces the address."""
    out: list[dict] = []
    for h in hits:
        text = f"{h.title} {h.snippet}"
        for m in EMAIL_RX.finditer(text):
            email = m.group(1).lower()
            if not email.endswith("@" + domain) or "noreply" in email:
                continue
            before = text[max(0, m.start() - 120): m.start()]
            # Only a name whose own pattern produces the address is paired with it.
            names = [n for n in re.findall(r"(?=([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,2}))", before)
                     if patterns.patterns_matching(n, email)]
            if names and not any(s["email"] == email for s in out):
                out.append({"name": names[-1], "email": email, "source": "google_serp", "url": h.url})
    return out


def find_official_site(hits: list[SerpHit], company: str) -> str | None:
    """First non-aggregator result whose title contains the company name (plan §B.2 step 3)."""
    from autoapply.outreach.domains import domain_from_url

    comp = company.lower()
    for h in hits:
        if comp in h.title.lower():
            d = domain_from_url(h.url)
            if d:
                return d
    return None


def people_queries(company: str, *, purpose: str, location: str | None, domain: str | None,
                   function: str | None = None) -> list[str]:
    loc = f' "{location}"' if location else ""
    q: list[str] = []
    if purpose == "prospect":
        q.append(f'site:linkedin.com/in "{company}" ("engineering manager" OR "head of engineering" OR "cto" OR "founder")')
        q.append(f'site:linkedin.com/in "{company}" ("talent acquisition" OR recruiter){loc}')
    else:
        q.append(f'site:linkedin.com/in "{company}" ("talent acquisition" OR recruiter){loc}')
        fn = f' "{function}"' if function else ""
        q.append(f'site:linkedin.com/in "{company}" ("engineering manager" OR "head of engineering"){fn}')
    if domain:
        q.append(f'"@{domain}" -noreply')
    return q


# ---- the reader ------------------------------------------------------------------------------


class GoogleReader:
    """Reads Google result pages within a daily budget; returns None once out of budget or
    after a CAPTCHA (which rests all outreach Google reading for ``CAPTCHA_REST_HOURS``)."""

    def __init__(
        self, conn: sqlite3.Connection, browser_factory: BrowserFactory, *, budget_key: str, limit: Callable[[], int],
        pacer: HumanPacer | None = None, is_paused: Callable[[], bool] | None = None,
    ) -> None:
        self.conn = conn
        self.browser_factory = browser_factory
        self.budget_key = budget_key
        self.limit = limit
        self.pacer = pacer or HumanPacer()
        self.is_paused = is_paused or (lambda: False)
        self._browser = None
        self._page: GoogleOnlyPage | None = None
        self.pages_read = 0
        self.captcha = False

    def resting(self) -> bool:
        rest = db.get_meta(self.conn, _REST_META, None)
        return bool(rest and str(rest) > utcnow().isoformat())

    def budget_left(self) -> int:
        return max(0, int(self.limit()) - db.get_source_sessions(self.conn, self.budget_key))

    def available(self) -> bool:
        return not self.resting() and self.budget_left() > 0 and not self.is_paused()

    async def read(self, query: str) -> list[SerpHit] | None:
        if not self.available() or self.captcha:
            return None
        if self._page is None:
            self._browser = await self.browser_factory()
            self._page = GoogleOnlyPage(await self._browser.new_page())
        elif self.pages_read:
            await self.pacer.between_search_pages()
        db.increment_source_sessions(self.conn, self.budget_key)
        await self._page.goto(search_url(query))
        await self.pacer.after_load()
        html = await self._page.content()
        if detect_page_state(html, self._page.url, _CAPTCHA_SELECTORS, captcha_url_markers=("/sorry/",),
                             captcha_title_markers=("unusual traffic",)) is PageState.CAPTCHA:
            self.captcha = True
            db.set_meta(self.conn, _REST_META, (utcnow() + timedelta(hours=CAPTCHA_REST_HOURS)).isoformat())
            log.warning("Google showed a security check; outreach searches rest for %d hours", CAPTCHA_REST_HOURS)
            return None
        await self.pacer.scroll(self._page)  # type: ignore[arg-type]
        self.pages_read += 1
        return parse_results(await self._page.content())

    async def close(self) -> None:
        if self._browser is not None:
            try:
                await self._browser.close()
            except Exception:  # noqa: BLE001
                log.debug("browser close failed", exc_info=True)
        self._browser, self._page = None, None


__all__ = [
    "GoogleOnlyPage", "GoogleReader", "NEVER_OPEN", "NavigationRefused", "PEOPLE_KEY", "PROSPECT_KEY", "SerpHit",
    "email_samples_from_results", "find_official_site", "is_google_search", "is_linkedin_profile", "parse_linkedin_title",
    "parse_results", "people_from_results", "people_queries", "search_url",
]
