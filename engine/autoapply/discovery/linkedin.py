"""LinkedIn READ-ONLY listing browser (visible Chrome, logged-in profile, human pace,
<= N sessions/day). Never applies; Easy Apply listings go to the easy_apply table.

Owner: Workstream D (daemon & LinkedIn).

Safety rules (PLAN.md decisions #3-#5, §7 risks):

* Only listing pages and job detail pages are *read* (``goto`` + ``content``). Nothing is
  ever clicked: not "Easy Apply", not "Apply", not "Save". The page wrappers below don't
  even expose a click method.
* Sessions run in the dedicated persistent Chrome profile, **visible** (``headless=False``),
  with randomized human-paced delays and incremental scrolling.
* A daily session budget (``Preferences.linkedin_sessions_per_day``, default 3) is tracked in
  the DB (``db.increment_source_sessions``); when spent the source emits ``cap_reached``.
* Login walls / CAPTCHAs / checkpoints stop the session immediately, mark the source
  disconnected (``source_status``) and emit an unsolicited ``error`` asking the user to log in.

This module also holds the shared machinery for Glassdoor (:mod:`autoapply.discovery.glassdoor`):
the browser seam, the human pacer, the selector-table driven parsers and
:class:`BrowserListingBase`. All CSS selectors live in ONE table per site
(:data:`LINKEDIN_SELECTORS`) so DOM changes are a one-line fix.
"""

from __future__ import annotations

import asyncio
import logging
import random
import re
import sqlite3
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import StrEnum
from pathlib import Path
from typing import Any, ClassVar, Literal, Protocol
from urllib.parse import parse_qs, quote_plus, unquote, urlencode, urljoin, urlsplit, urlunsplit

from bs4 import BeautifulSoup, Tag

from autoapply import db
from autoapply.config import Preferences
from autoapply.discovery.base import DiscoveredJob, DiscoveryContext
from autoapply.enums import Ats, CapKind, ErrorCode, JobSource, RemotePolicy, SourceName
from autoapply.models import (
    AgentStepPayload,
    CapReachedPayload,
    ErrorPayload,
    LogPayload,
    SourceStatus,
    SourceStatusPayload,
    StatePayload,
    format_ts,
    utcnow,
)

log = logging.getLogger("autoapply.discovery.linkedin")

MAX_PER_COMPANY_PER_SESSION = 3

EmitFn = Callable[[str, Any], Awaitable[None]]


async def _noop_emit(_type: str, _payload: Any) -> None:
    return None


# =====================================================================================
# Selector table (the ONLY place LinkedIn DOM knowledge lives)
# =====================================================================================

#: Each key maps to an ordered list of CSS selectors; the first one that matches wins.
#: ``*_text`` keys are case-insensitive substrings searched in element text / aria-labels.
LINKEDIN_SELECTORS: dict[str, list[str]] = {
    # --- search results page -------------------------------------------------------
    "search_card": [
        "li[data-occludable-job-id]",
        "div.job-card-container[data-job-id]",
        "li.jobs-search-results__list-item",
        "div.base-card[data-entity-urn]",
        "div.base-search-card",
    ],
    "card_title": [
        "a.job-card-list__title",
        "a.job-card-container__link",
        "h3.base-search-card__title",
        ".job-card-list__title",
    ],
    "card_link": [
        "a.job-card-list__title[href]",
        "a.job-card-container__link[href]",
        "a.base-card__full-link[href]",
        "a[href*='/jobs/view/']",
    ],
    "card_company": [
        ".job-card-container__primary-description",
        ".artdeco-entity-lockup__subtitle",
        "h4.base-search-card__subtitle",
        ".job-card-container__company-name",
    ],
    "card_location": [
        ".job-card-container__metadata-item",
        ".artdeco-entity-lockup__caption",
        "span.job-search-card__location",
    ],
    "card_salary": [
        ".job-card-container__metadata-item--salary",
        "span.job-search-card__salary-info",
    ],
    "card_easy_apply": [
        ".job-card-container__apply-method",
        "li.job-card-container__footer-item",
        ".job-card-container__footer-wrapper",
    ],
    # --- job detail page -----------------------------------------------------------
    "detail_title": [
        ".job-details-jobs-unified-top-card__job-title h1",
        "h1.t-24",
        "h1.top-card-layout__title",
        "h1",
    ],
    "detail_company": [
        ".job-details-jobs-unified-top-card__company-name a",
        ".job-details-jobs-unified-top-card__company-name",
        "a.topcard__org-name-link",
        ".topcard__flavor a",
    ],
    "detail_location": [
        ".job-details-jobs-unified-top-card__primary-description-container .tvm__text",
        ".job-details-jobs-unified-top-card__bullet",
        "span.topcard__flavor--bullet",
    ],
    "detail_description": [
        "#job-details",
        ".jobs-description__content",
        ".jobs-box__html-content",
        ".show-more-less-html__markup",
        ".description__text",
    ],
    "detail_salary": [
        ".job-details-jobs-unified-top-card__job-insight--highlight",
        ".salary.compensation__salary",
    ],
    "detail_workplace": [
        ".job-details-jobs-unified-top-card__workplace-type",
        ".job-details-preferences-and-skills__pill",
    ],
    "detail_apply_button": [
        "button.jobs-apply-button",
        "a.jobs-apply-button",
        "button.apply-button",
        "a.apply-button",
        "button[data-control-name='jobdetails_topcard_inapply']",
    ],
    #: Elements that may carry the off-site apply URL in the DOM (href / data-* / comment).
    "detail_apply_link": [
        "a.jobs-apply-button[href]",
        "a.apply-button[href]",
        "a[data-tracking-control-name*='apply-link'][href]",
        "a[data-tracking-control-name*='offsite'][href]",
        "code#applyUrl",
    ],
    # --- page-state detection ------------------------------------------------------
    "login_wall": [
        "form.login__form",
        "input#session_key",
        "input[name='session_key']",
        "input#username[name='session_key']",
        ".authwall-join-form",
        "form[action*='login-submit']",
        "section.authwall",
    ],
    "captcha": [
        "#captcha-internal",
        "iframe[src*='captcha']",
        "form[action*='checkpoint/challenge']",
        "#challenge",
        "div#arkose",
    ],
    "logged_in": [
        "nav.global-nav",
        "#global-nav",
        "img.global-nav__me-photo",
        "div.feed-identity-module",
    ],
}

#: Substrings (case-insensitive) that mark Easy Apply on cards / buttons.
LINKEDIN_EASY_APPLY_TEXT: tuple[str, ...] = ("easy apply",)
#: URL path fragments that indicate a login wall / security checkpoint.
LINKEDIN_LOGIN_URL_MARKERS: tuple[str, ...] = ("/login", "/authwall", "/uas/login", "/signup")
LINKEDIN_CAPTCHA_URL_MARKERS: tuple[str, ...] = ("/checkpoint/challenge", "/checkpoint/lg", "captcha")

LINKEDIN_HOSTS: tuple[str, ...] = ("linkedin.com",)
LINKEDIN_BASE = "https://www.linkedin.com"
LINKEDIN_LOGIN_URL = "https://www.linkedin.com/login"
LINKEDIN_FEED_URL = "https://www.linkedin.com/feed/"


# =====================================================================================
# Browser seam (no click method on purpose)
# =====================================================================================


class ListingPage(Protocol):
    """A browser tab that can only navigate, read and scroll. Never click."""

    @property
    def url(self) -> str: ...

    async def goto(self, url: str) -> None: ...

    async def content(self) -> str: ...

    async def scroll(self, pixels: int) -> None: ...

    async def close(self) -> None: ...


class ListingBrowser(Protocol):
    async def new_page(self) -> ListingPage: ...

    async def close(self) -> None: ...


BrowserFactory = Callable[[], Awaitable[ListingBrowser]]


class _PlaywrightPage:
    def __init__(self, page: Any) -> None:
        self._page = page

    @property
    def url(self) -> str:
        return str(self._page.url)

    async def goto(self, url: str) -> None:
        await self._page.goto(url, wait_until="domcontentloaded", timeout=45_000)
        try:
            await self._page.wait_for_load_state("networkidle", timeout=8_000)
        except Exception:  # noqa: BLE001 - long-polling pages never go idle; that's fine
            pass

    async def content(self) -> str:
        """Page HTML; a read that lands mid-navigation (redirects, Cloudflare checks) is retried."""
        last: Exception | None = None
        for _ in range(6):
            try:
                return str(await self._page.content())
            except Exception as e:  # noqa: BLE001
                if "navigating" not in str(e).lower() and "execution context was destroyed" not in str(e).lower():
                    raise
                last = e
                try:
                    await self._page.wait_for_load_state("domcontentloaded", timeout=5_000)
                except Exception:  # noqa: BLE001
                    pass
                await asyncio.sleep(1.0)
        assert last is not None
        raise last

    async def thumbnail(self) -> str | None:
        """Small JPEG of the viewport for the app's Live Agent view."""
        from autoapply.thumbs import thumb_from_bytes

        return thumb_from_bytes(await self._page.screenshot(type="jpeg", quality=60, timeout=3_000))

    async def scroll(self, pixels: int) -> None:
        await self._page.mouse.wheel(0, pixels)

    async def close(self) -> None:
        await self._page.close()


class PlaywrightListingBrowser:
    """Visible persistent-profile Chrome via Playwright (the real implementation).

    Uses the dedicated profile at ``Paths.chrome_profile`` (the user logged into
    LinkedIn/Glassdoor there once). Prefers installed Google Chrome (``channel="chrome"``)
    and falls back to Playwright's Chromium.
    """

    def __init__(self, profile_dir: Path, *, headless: bool = False) -> None:
        self.profile_dir = Path(profile_dir)
        self.headless = headless
        self._pw: Any = None
        self._ctx: Any = None
        self._claimed: set[int] = set()

    async def start(self) -> "PlaywrightListingBrowser":
        from playwright.async_api import async_playwright  # local import: heavy

        self.profile_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._pw = await async_playwright().start()
        kwargs: dict[str, Any] = {
            "user_data_dir": str(self.profile_dir),
            "headless": self.headless,
            "viewport": None,
            "args": ["--disable-blink-features=AutomationControlled"],
        }
        try:
            self._ctx = await self._pw.chromium.launch_persistent_context(channel="chrome", **kwargs)
        except Exception:  # noqa: BLE001 - Chrome not installed -> bundled Chromium
            self._ctx = await self._pw.chromium.launch_persistent_context(**kwargs)
        return self

    async def cookies(self) -> list[dict[str, Any]]:
        """All cookies of the persistent profile (the reliable "am I logged in" signal)."""
        return list(await self._ctx.cookies())

    async def new_page(self) -> ListingPage:
        """A tab of its own (searches run side by side); the window's initial blank tab is reused."""
        blank = [p for p in self._ctx.pages if p.url in ("about:blank", "") and id(p) not in self._claimed]
        page = blank[0] if blank else await self._ctx.new_page()
        self._claimed.add(id(page))
        return _PlaywrightPage(page)

    async def close(self) -> None:
        try:
            if self._ctx is not None:
                await self._ctx.close()
        finally:
            if self._pw is not None:
                await self._pw.stop()
            self._ctx = self._pw = None


class _SharedBrowser:
    """One persistent Chrome per profile directory. Chrome locks a profile, so two sites can only
    browse at the same time as tabs of the same window: each session takes a lease, opens its own
    tabs, and the window closes when the last lease is returned."""

    _pool: ClassVar[dict[str, "_SharedBrowser"]] = {}
    _guard: ClassVar[asyncio.Lock | None] = None

    def __init__(self, browser: PlaywrightListingBrowser) -> None:
        self.browser = browser
        self.leases = 0

    @classmethod
    async def lease(cls, profile_dir: Path, headless: bool) -> "_BrowserLease":
        if cls._guard is None:
            cls._guard = asyncio.Lock()
        key = str(Path(profile_dir).resolve())
        async with cls._guard:
            shared = cls._pool.get(key)
            if shared is None:
                shared = cls(await PlaywrightListingBrowser(profile_dir, headless=headless).start())
                cls._pool[key] = shared
            shared.leases += 1
        return _BrowserLease(shared, key)

    @classmethod
    async def release(cls, shared: "_SharedBrowser", key: str) -> None:
        assert cls._guard is not None
        async with cls._guard:
            shared.leases -= 1
            if shared.leases > 0:
                return
            cls._pool.pop(key, None)
        await shared.browser.close()


class _BrowserLease:
    def __init__(self, shared: _SharedBrowser, key: str) -> None:
        self._shared, self._key = shared, key
        self._pages: list[ListingPage] = []
        self._closed = False

    async def new_page(self) -> ListingPage:
        page = await self._shared.browser.new_page()
        self._pages.append(page)
        return page

    async def cookies(self) -> list[dict[str, Any]]:
        return await self._shared.browser.cookies()

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        for page in self._pages:
            try:
                await page.close()
            except Exception:  # noqa: BLE001 - the tab may already be gone
                pass
        await _SharedBrowser.release(self._shared, self._key)


def playwright_browser_factory(profile_dir: Path, *, headless: bool = False) -> BrowserFactory:
    async def factory() -> ListingBrowser:
        return await _SharedBrowser.lease(profile_dir, headless)  # type: ignore[return-value]

    return factory


# =====================================================================================
# Human pacing
# =====================================================================================


@dataclass(slots=True)
class HumanPacer:
    """Randomized delays + incremental scrolling. ``sleep``/``rng`` are injectable for tests."""

    rng: random.Random = field(default_factory=random.Random)
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep
    read_delay: tuple[float, float] = (3.0, 8.0)  # after a page load ("reading")
    between_jobs: tuple[float, float] = (4.0, 12.0)
    between_searches: tuple[float, float] = (8.0, 20.0)
    scroll_steps: tuple[int, int] = (3, 7)
    scroll_pixels: tuple[int, int] = (250, 700)
    scroll_pause: tuple[float, float] = (0.6, 2.2)
    total_slept: float = 0.0

    async def _wait(self, lo_hi: tuple[float, float]) -> None:
        d = self.rng.uniform(*lo_hi)
        self.total_slept += d
        await self.sleep(d)

    async def after_load(self) -> None:
        await self._wait(self.read_delay)

    async def between_job_pages(self) -> None:
        await self._wait(self.between_jobs)

    async def between_search_pages(self) -> None:
        await self._wait(self.between_searches)

    async def scroll(self, page: ListingPage) -> None:
        for _ in range(self.rng.randint(*self.scroll_steps)):
            await page.scroll(self.rng.randint(*self.scroll_pixels))
            await self._wait(self.scroll_pause)


# =====================================================================================
# Parsing helpers (pure; tested against fixture HTML)
# =====================================================================================


class PageState(StrEnum):
    OK = "ok"
    LOGIN_REQUIRED = "login_required"
    CAPTCHA = "captcha"


@dataclass(slots=True)
class ListingCard:
    """One search-result card."""

    title: str
    company: str
    location: str | None
    detail_url: str | None
    external_id: str | None
    easy_apply: bool = False
    salary_text: str | None = None
    detail: "JobDetail | None" = None  # set when the result page already holds the full posting
    extra: dict[str, Any] = field(default_factory=dict)  # per-site extras (e.g. Google's "via" board)


@dataclass(slots=True)
class JobDetail:
    """Fields read from a job detail page."""

    title: str | None = None
    company: str | None = None
    location: str | None = None
    description: str | None = None
    easy_apply: bool = False
    apply_url: str | None = None  # off-site (company ATS) URL when present in the DOM
    apply_redirect: str | None = None  # same-site redirect that resolves to the ATS URL
    salary_text: str | None = None
    workplace: str | None = None


def _soup(html: str) -> BeautifulSoup:
    return BeautifulSoup(html, "html.parser")


def select_first(root: BeautifulSoup | Tag, selectors: Sequence[str]) -> Tag | None:
    for sel in selectors:
        try:
            el = root.select_one(sel)
        except Exception:  # noqa: BLE001 - malformed selector in the table shouldn't crash a run
            log.warning("bad selector %r", sel)
            continue
        if el is not None:
            return el
    return None


def select_all(root: BeautifulSoup | Tag, selectors: Sequence[str]) -> list[Tag]:
    for sel in selectors:
        try:
            els = root.select(sel)
        except Exception:  # noqa: BLE001
            log.warning("bad selector %r", sel)
            continue
        if els:
            return list(els)
    return []


def clean_text(value: str | None) -> str | None:
    if value is None:
        return None
    s = re.sub(r"\s+", " ", value).strip()
    return s or None


def text_of(root: BeautifulSoup | Tag, selectors: Sequence[str]) -> str | None:
    el = select_first(root, selectors)
    return clean_text(el.get_text(" ")) if el is not None else None


def _element_mentions(el: Tag, needles: Sequence[str]) -> bool:
    hay = " ".join(
        [el.get_text(" ") or "", str(el.get("aria-label") or ""), str(el.get("data-test") or "")]
    ).lower()
    return any(n in hay for n in needles)


def any_mentions(root: BeautifulSoup | Tag, selectors: Sequence[str], needles: Sequence[str]) -> bool:
    for sel in selectors:
        try:
            els = root.select(sel)
        except Exception:  # noqa: BLE001
            continue
        if any(_element_mentions(e, needles) for e in els):
            return True
    return False


def detect_page_state(
    html: str,
    url: str | None,
    selectors: dict[str, list[str]],
    *,
    login_url_markers: Sequence[str] = (),
    captcha_url_markers: Sequence[str] = (),
    captcha_title_markers: Sequence[str] = (),
) -> PageState:
    """Login wall / CAPTCHA detection from the DOM and URL. CAPTCHA wins over login."""
    path = (urlsplit(url).path.lower() + "?" + urlsplit(url).query.lower()) if url else ""
    if any(m in path for m in captcha_url_markers):
        return PageState.CAPTCHA
    soup = _soup(html)
    title = (soup.title.get_text() if soup.title else "").lower()
    if any(m in title for m in captcha_title_markers):
        return PageState.CAPTCHA
    if select_first(soup, selectors.get("captcha", [])) is not None:
        return PageState.CAPTCHA
    if any(m in path for m in login_url_markers):
        return PageState.LOGIN_REQUIRED
    if select_first(soup, selectors.get("login_wall", [])) is not None:
        return PageState.LOGIN_REQUIRED
    return PageState.OK


def is_logged_in(html: str, url: str | None, selectors: dict[str, list[str]], **markers: Any) -> bool:
    if detect_page_state(html, url, selectors, **markers) is not PageState.OK:
        return False
    return select_first(_soup(html), selectors.get("logged_in", [])) is not None


def _host(url: str | None) -> str:
    if not url:
        return ""
    h = urlsplit(url).netloc.lower()
    return h[4:] if h.startswith("www.") else h


def is_host(url: str | None, hosts: Sequence[str]) -> bool:
    h = _host(url)
    return any(h == d or h.endswith("." + d) for d in hosts)


def strip_query(url: str) -> str:
    p = urlsplit(url)
    return urlunsplit((p.scheme or "https", p.netloc, p.path, "", ""))


def unwrap_redirect(url: str | None) -> str | None:
    """Unwrap ``…/redirect?url=<encoded>`` / ``externalApply…?url=`` style wrappers."""
    if not url:
        return None
    for _ in range(3):
        p = urlsplit(url)
        qs = parse_qs(p.query)
        inner = next((qs[k][0] for k in ("url", "dest", "target", "u") if k in qs and qs[k]), None)
        if inner and re.match(r"^https?%3A", inner, re.I):
            inner = unquote(inner)  # double-encoded
        if inner and re.match(r"^https?://", inner, re.I):
            url = inner
            continue
        break
    return url


_SALARY_RE = re.compile(
    r"(?P<cur>[$€£₹]|USD|EUR|GBP|INR|CA\$|A\$)?\s*(?P<lo>\d[\d,.]*)\s*(?P<lok>[kKmM])?"
    r"(?:\s*(?:/\s*(?:yr|year|hr|hour))?)?\s*(?:-|–|—|to)\s*"
    r"(?P<cur2>[$€£₹]|USD|EUR|GBP|INR|CA\$|A\$)?\s*(?P<hi>\d[\d,.]*)\s*(?P<hik>[kKmM])?"
    r"(?:\s*/\s*(?P<per>yr|year|hr|hour))?",
)
_CURRENCY = {"$": "USD", "€": "EUR", "£": "GBP", "₹": "INR", "CA$": "CAD", "A$": "AUD"}


def _amount(num: str, suffix: str | None) -> int | None:
    try:
        v = float(num.replace(",", ""))
    except ValueError:
        return None
    if suffix and suffix.lower() == "k":
        v *= 1_000
    elif suffix and suffix.lower() == "m":
        v *= 1_000_000
    return int(round(v))


def parse_salary(text: str | None) -> tuple[int | None, int | None, str | None]:
    """``"$120K - $160K (Employer est.)"`` -> (120000, 160000, "USD"). Hourly ranges are
    annualized (x2080). Unparseable -> (None, None, None)."""
    if not text:
        return None, None, None
    m = _SALARY_RE.search(text)
    if not m:
        return None, None, None
    lo = _amount(m.group("lo"), m.group("lok") or m.group("hik"))
    hi = _amount(m.group("hi"), m.group("hik"))
    cur_raw = m.group("cur") or m.group("cur2")
    currency = _CURRENCY.get(cur_raw, cur_raw) if cur_raw else None
    per = (m.group("per") or "").lower()
    if per in ("hr", "hour") or re.search(r"/\s*(hr|hour)|per hour", text, re.I):
        lo = lo * 2080 if lo is not None else None
        hi = hi * 2080 if hi is not None else None
    if lo is not None and hi is not None and lo > hi:
        lo, hi = hi, lo
    return lo, hi, currency


def detect_remote(*texts: str | None) -> RemotePolicy | None:
    hay = " ".join(t for t in texts if t).lower()
    if "remote" in hay:
        return RemotePolicy.REMOTE
    if "hybrid" in hay:
        return RemotePolicy.HYBRID
    if "on-site" in hay or "onsite" in hay or "on site" in hay:
        return RemotePolicy.ONSITE
    return None


def guess_ats(url: str | None) -> tuple[Ats, str | None]:
    """ATS + board token from an apply URL. Delegates to Workstream A's
    ``discovery.base.detect_ats``; falls back to a local pattern table while it's a stub."""
    if not url:
        return Ats.OTHER, None
    try:
        from autoapply.discovery.base import detect_ats

        return detect_ats(url)
    except NotImplementedError:
        pass
    except Exception:  # noqa: BLE001 - never let ATS detection break discovery
        log.debug("detect_ats failed for %s", url, exc_info=True)
    p = urlsplit(url)
    host = _host(url)
    parts = [s for s in p.path.split("/") if s]
    qs = parse_qs(p.query)
    if host.endswith("greenhouse.io"):
        if "for" in qs:
            return Ats.GREENHOUSE, qs["for"][0]
        return Ats.GREENHOUSE, parts[0] if parts and parts[0] not in ("embed",) else None
    if host.endswith("lever.co"):
        return Ats.LEVER, parts[0] if parts else None
    if host.endswith("ashbyhq.com"):
        return Ats.ASHBY, parts[0] if parts else None
    if "myworkdayjobs.com" in host or "workday" in host:
        return Ats.WORKDAY, None
    return Ats.OTHER, None


def _comment_url(el: Tag) -> str | None:
    """``<code id="applyUrl"><!--"https://…"--></code>`` (LinkedIn guest pages)."""
    raw = el.decode_contents()
    m = re.search(r"https?://[^\s\"'<>]+", raw)
    return m.group(0) if m else None


# =====================================================================================
# Source status bookkeeping (shared with the daemon)
# =====================================================================================


def load_source_statuses(conn: sqlite3.Connection) -> dict[str, dict[str, Any]]:
    data = db.get_meta(conn, db.META_SOURCES, {}) or {}
    return data if isinstance(data, dict) else {}


def record_source_status(
    conn: sqlite3.Connection, source: str, *, connected: bool, detail: str | None = None
) -> SourceStatus:
    """Persist login/session health for ``source`` in ``meta.sources``; returns the status."""
    with db.transaction(conn):
        data = load_source_statuses(conn)
        ts = utcnow()
        data[source] = {"connected": connected, "checked_at": format_ts(ts), "detail": detail}
        db.set_meta(conn, db.META_SOURCES, data)
        enabled = bool(db.get_preferences(conn).sources_enabled.get(source, False))
    return SourceStatus(source=SourceName(source), enabled=enabled, connected=connected, checked_at=ts, detail=detail)


def next_local_midnight(now: datetime | None = None) -> datetime:
    return db.local_day_start(now) + timedelta(days=1)


# =====================================================================================
# Shared visible-browser listing source
# =====================================================================================


class BrowserListingBase:
    """Base for LinkedIn / Glassdoor: one human-paced, read-only browsing session per call.

    Subclasses provide the selector table, URL builders and the card/detail parsers.
    """

    name: ClassVar[JobSource]
    source_key: ClassVar[str]
    display_name: ClassVar[str]
    cap_kind: ClassVar[CapKind]
    hosts: ClassVar[tuple[str, ...]]
    login_url: ClassVar[str]
    home_url: ClassVar[str]
    selectors: ClassVar[dict[str, list[str]]]
    login_url_markers: ClassVar[tuple[str, ...]] = ()
    #: (cookie name, domain substring) pairs that exist only for a signed-in session. Page markup
    #: changes constantly, so cookies are the primary login signal and the DOM only a fallback.
    auth_cookies: ClassVar[tuple[tuple[str, str], ...]] = ()
    captcha_url_markers: ClassVar[tuple[str, ...]] = ()
    captcha_title_markers: ClassVar[tuple[str, ...]] = ()
    easy_apply_ats: ClassVar[Ats] = Ats.OTHER
    #: Posting-date filters, narrowest first; the planner widens them as a search runs dry.
    date_windows: ClassVar[tuple[str, ...]] = ("",)
    #: Result pages read per date window before widening it.
    max_pages: ClassVar[int] = 1
    #: Tabs this site browses with at once (each runs a different search).
    tabs: ClassVar[int] = 2
    #: Skip result cards whose title matches none of the roles before spending a page visit.
    prefilter_titles: ClassVar[bool] = False

    def __init__(
        self,
        conn: sqlite3.Connection | None = None,
        *,
        emit: EmitFn | None = None,
        browser_factory: BrowserFactory | None = None,
        headless_browser_factory: BrowserFactory | None = None,
        profile_dir: Path | None = None,
        pacer: HumanPacer | None = None,
        max_searches: int | None = None,
        max_details: int | None = None,
        resolve_redirects: bool = True,
        is_paused: Callable[[], bool] | None = None,
    ) -> None:
        if browser_factory is None:
            if profile_dir is None:
                from autoapply.paths import get_paths

                profile_dir = get_paths().chrome_profile
            browser_factory = playwright_browser_factory(profile_dir)
            if headless_browser_factory is None:
                headless_browser_factory = playwright_browser_factory(profile_dir, headless=True)
        self.headless_browser_factory = headless_browser_factory
        self._conn = conn
        self.emit: EmitFn = emit or _noop_emit
        self.browser_factory = browser_factory
        self.pacer = pacer or HumanPacer()
        self.max_searches = max_searches
        self.max_details = max_details
        self.resolve_redirects = resolve_redirects
        self.is_paused = is_paused or (lambda: False)
        self.last_state: PageState | None = None
        self._step = 0

    @property
    def conn(self) -> sqlite3.Connection:
        """The daemon's writer connection. Constructed without one (CLI / introspection),
        the source opens the default DB lazily on first use."""
        if self._conn is None:
            self._conn = db.open_db()
        return self._conn

    # ---- per-site hooks ----------------------------------------------------------------

    def sessions_limit(self, prefs: Preferences) -> int:
        raise NotImplementedError

    def search_url(self, prefs: Preferences, role: str, location: str, window: int, page: int) -> str:
        raise NotImplementedError

    def build_search_urls(self, prefs: Preferences) -> list[str]:
        """First page, narrowest window, of every (role, location) search."""
        from autoapply.discovery.planner import SearchPlanner

        return [self.search_url(prefs, r, loc, 0, 0) for r, loc in SearchPlanner.combos(prefs)]

    def parse_search(self, html: str, base_url: str) -> list[ListingCard]:
        raise NotImplementedError

    def parse_detail(self, html: str, base_url: str) -> JobDetail:
        raise NotImplementedError

    # ---- shared ------------------------------------------------------------------------

    def page_state(self, html: str, url: str | None) -> PageState:
        return detect_page_state(
            html, url, self.selectors, login_url_markers=self.login_url_markers,
            captcha_url_markers=self.captcha_url_markers, captcha_title_markers=self.captcha_title_markers,
        )

    def logged_in(self, html: str, url: str | None) -> bool:
        return is_logged_in(
            html, url, self.selectors, login_url_markers=self.login_url_markers,
            captcha_url_markers=self.captcha_url_markers, captcha_title_markers=self.captcha_title_markers,
        )

    async def _log(self, message: str, level: str = "info") -> None:
        getattr(log, "warning" if level == "warning" else level, log.info)("%s: %s", self.source_key, message)
        try:
            await self.emit("log", LogPayload(level=level, message=message, logger=log.name, at=utcnow()))
        except Exception:  # noqa: BLE001
            log.debug("emit failed", exc_info=True)

    async def report_status(self, connected: bool, detail: str | None) -> SourceStatus:
        status = record_source_status(self.conn, self.source_key, connected=connected, detail=detail)
        await self.emit("source_status", SourceStatusPayload(source=status))
        return status

    async def _show(self, page: ListingPage, ctx: DiscoveryContext, action: str, detail: str | None = None) -> None:
        """Live Agent view: one step line plus a throttled thumbnail of the page being read."""
        self._step += 1
        thumb: str | None = None
        grab = getattr(page, "thumbnail", None)
        if grab is not None:
            try:
                thumb = await grab()
            except Exception:  # noqa: BLE001 - a missing preview never breaks discovery
                thumb = None
        try:
            await self.emit("agent_step", AgentStepPayload(
                application_id=0, job_id=0, run_id=ctx.run_id, index=self._step, action=action[:200],
                detail=detail, screenshot_thumb=thumb, at=utcnow(),
            ))
        except Exception:  # noqa: BLE001
            log.debug("agent_step emit failed", exc_info=True)

    async def _report_blocked(self, state: PageState) -> None:
        if state is PageState.CAPTCHA:
            detail = (f"{self.display_name} showed a security check to AutoApply's browser (your own browser is unaffected). "
                      "Press Reconnect and solve it in the window that opens.")
        else:
            detail = f"{self.display_name} logged AutoApply's browser out. Press Reconnect and log in again."
        await self.report_status(False, detail)
        await self.emit(
            "error",
            ErrorPayload(
                code=ErrorCode.UNAVAILABLE, message=detail,
                details={"source": self.source_key, "reason": state.value, "action": "onboarding_connect_source"},
            ),
        )

    def build_job(self, card: ListingCard, detail: JobDetail | None) -> DiscoveredJob | None:
        d = detail or JobDetail()
        title = clean_text(d.title) or card.title
        company = clean_text(d.company) or card.company
        if not title or not company:
            return None
        location = clean_text(d.location) or card.location
        easy = bool(card.easy_apply or d.easy_apply)
        apply_url = None if easy else d.apply_url
        if apply_url and is_host(apply_url, self.hosts):
            apply_url = None  # an on-site URL is not a company ATS
        ats, token = (self.easy_apply_ats, None) if easy else guess_ats(apply_url)
        smin, smax, scur = parse_salary(d.salary_text or card.salary_text)
        return DiscoveredJob(
            source=self.name, company_name=company, title=title, apply_url=apply_url,
            source_url=card.detail_url, ats=ats, external_id=card.external_id, location=location,
            remote=detect_remote(location, d.workplace, title), salary_min=smin, salary_max=smax,
            salary_currency=scur, description=d.description, easy_apply=easy, board_token=token,
            raw={"via": self.source_key, "card_easy_apply": card.easy_apply},
        )

    async def _resolve(self, page: ListingPage, href: str) -> str | None:
        """Follow a same-site apply redirect with a plain GET (no click) to get the ATS URL."""
        try:
            await page.goto(href)
        except Exception:  # noqa: BLE001
            log.debug("redirect resolution failed for %s", href, exc_info=True)
            return None
        final = page.url
        return None if is_host(final, self.hosts) else strip_tracking(final)

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        from autoapply.discovery.base import title_matches_roles
        from autoapply.discovery.planner import SearchPlanner

        prefs = ctx.preferences
        limit = self.sessions_limit(prefs)
        used = db.get_source_sessions(self.conn, self.source_key)
        if used >= limit:
            await self.emit(
                "cap_reached",
                CapReachedPayload(cap=self.cap_kind, used=used, limit=limit, resets_at=next_local_midnight()),
            )
            await self._log(f"{self.display_name} session budget spent ({used}/{limit}); skipping", "info")
            return []
        planner = SearchPlanner(self.conn, self.source_key, windows=len(self.date_windows), max_pages=self.max_pages)
        searches = planner.plan(prefs, self.max_searches or prefs.searches_per_session)
        if not searches:
            if not prefs.roles:
                await self._log(f"{self.display_name}: no roles in preferences; nothing to search", "info")
            else:
                await self._log(f"{self.display_name}: every search was read recently; resting until new postings appear", "info")
            return []

        jobs: list[DiscoveredJob] = []
        seen: set[str] = set()
        max_details = self.max_details or prefs.jobs_per_session
        budget = {"left": max_details, "already_seen": 0, "blocked": False}
        per_company: dict[str, int] = {}
        queue: asyncio.Queue = asyncio.Queue()
        for s in searches:
            queue.put_nowait(s)

        async def read_search(page: ListingPage, s: Any, tab: int) -> None:
            label = f"{s.role}" + (f" · {s.location}" if s.location else "")
            await self.emit("state", StatePayload(daemon="discovering", run_id=ctx.run_id,
                                                  message=f"{self.display_name} · {label}"))
            await page.goto(self.search_url(prefs, s.role, s.location, s.window, s.page))
            await self.pacer.after_load()
            await self._show(page, ctx, f"searching {self.display_name}: {label}")
            state = self.page_state(await page.content(), page.url)
            self.last_state = state
            if state is not PageState.OK:
                await self._report_blocked(state)
                budget["blocked"] = True
                return
            await self.pacer.scroll(page)
            cards = self.parse_search(await page.content(), page.url)
            new, complete = 0, True
            for card in cards:
                if self.is_paused() or budget["blocked"]:
                    complete = False
                    break
                key = card.external_id or card.detail_url or f"{card.company}|{card.title}|{card.location}"
                if key in seen:
                    continue
                seen.add(key)
                if self.prefilter_titles and not title_matches_roles(card.title, prefs.roles):
                    continue
                per_company[card.company] = per_company.get(card.company, 0) + 1
                if per_company[card.company] > MAX_PER_COMPANY_PER_SESSION:
                    continue  # one prolific poster (e.g. a staffing/gig company) must not crowd out everyone else
                if db.listing_already_stored(self.conn, self.source_key, card.external_id, card.detail_url):
                    budget["already_seen"] += 1  # stored from an earlier run: no page visit, no re-scoring, no tokens
                    continue
                detail = card.detail
                needs_visit = detail is None and bool(card.detail_url)
                needs_resolve = False
                if detail is not None:
                    needs_resolve = (detail.apply_url is None and bool(detail.apply_redirect) and self.resolve_redirects
                                     and not (card.easy_apply or detail.easy_apply))
                if (needs_visit or needs_resolve) and budget["left"] <= 0:
                    complete = False
                    break
                if needs_visit:
                    budget["left"] -= 1
                    await self._log(
                        f"{self.display_name}: reading job {max_details - budget['left']}/{max_details}: "
                        f"{card.title} · {card.company}")
                    await self.pacer.between_job_pages()
                    await page.goto(card.detail_url)
                    await self.pacer.after_load()
                    await self._show(page, ctx, f"reading {card.title}", detail=card.company)
                    html = await page.content()
                    state = self.page_state(html, page.url)
                    if state is not PageState.OK:
                        self.last_state = state
                        await self._report_blocked(state)
                        budget["blocked"] = True
                        complete = False
                        break
                    await self.pacer.scroll(page)
                    detail = self.parse_detail(await page.content(), page.url)
                    needs_resolve = (detail.apply_url is None and bool(detail.apply_redirect) and self.resolve_redirects
                                     and not (card.easy_apply or detail.easy_apply))
                elif needs_resolve:
                    budget["left"] -= 1
                    await self._log(f"{self.display_name}: opening apply link {max_details - budget['left']}/{max_details}: "
                                    f"{card.title} · {card.company}")
                    await self.pacer.between_job_pages()
                if needs_resolve and detail is not None and detail.apply_redirect:
                    detail.apply_url = await self._resolve(page, detail.apply_redirect)
                job = self.build_job(card, detail)
                if job is not None:
                    job.raw = {**(job.raw or {}), "search_key": s.key}
                    jobs.append(job)
                    new += 1
            planner.record(s, cards=len(cards), new=new, complete=complete)
            if cards:
                await self._log(f"{self.display_name} · {label}: {len(cards)} listings on the page, {new} new")

        async def worker(tab: int) -> None:
            page = await browser.new_page()
            first = True
            while not queue.empty() and not budget["blocked"] and not self.is_paused():
                s = queue.get_nowait()
                if not first:
                    await self.pacer.between_search_pages()
                first = False
                await read_search(page, s, tab)

        # Only a session that actually opened a page spends the daily budget (a browser that
        # cannot launch, e.g. the profile is locked by another Chrome, costs nothing).
        browser = await self.browser_factory()
        try:
            db.increment_source_sessions(self.conn, self.source_key)
            n_tabs = max(1, min(self.tabs, len(searches)))
            outcomes = await asyncio.gather(*(worker(t) for t in range(n_tabs)), return_exceptions=True)
            errors = [o for o in outcomes if isinstance(o, BaseException)]
            if errors:
                raise errors[0]
            if not budget["blocked"]:
                await self.report_status(True, f"{self.display_name} session valid")
        except Exception as e:  # noqa: BLE001 - keep what was read so far instead of losing the whole session
            if not jobs:
                db.refund_source_session(self.conn, self.source_key)  # our failure, not a spent session
                raise
            await self._log(f"{self.display_name}: stopped early ({e}); keeping {len(jobs)} listings already read", "warning")
        finally:
            try:
                await browser.close()
            except Exception:  # noqa: BLE001
                log.debug("browser close failed", exc_info=True)
        extra = f"; {budget['already_seen']} already seen, skipped" if budget["already_seen"] else ""
        await self._log(f"{self.display_name}: read {len(jobs)} new listings ({sum(j.easy_apply for j in jobs)} Easy Apply){extra}")
        return jobs

    async def check_session(self) -> SourceStatus:
        """Open the home page once and report whether the profile is logged in."""
        browser = await self.browser_factory()
        try:
            page = await browser.new_page()
            await page.goto(self.home_url)
            html = await page.content()
            if await self._authenticated(browser, (html, page.url)):
                return await self.report_status(True, f"{self.display_name} session valid")
            state = self.page_state(html, page.url)
            await self._report_blocked(state if state is not PageState.OK else PageState.LOGIN_REQUIRED)
            return SourceStatus(source=SourceName(self.source_key), connected=False, checked_at=utcnow())
        finally:
            await browser.close()

    async def _authenticated(self, browser: Any, snap: tuple[str, str | None] | None) -> bool:
        """Signed in = auth cookie present AND the page is not a login wall / checkpoint; otherwise
        fall back to the DOM check (used by tests / sites without a known cookie)."""
        if snap is None:
            return False
        html, url = snap
        getter = getattr(browser, "cookies", None)
        if self.auth_cookies and getter is not None:
            try:
                jar = await getter()
            except Exception:  # noqa: BLE001
                jar = []
            has_cookie = any(
                c.get("name") == name and dom in str(c.get("domain", "")) and c.get("value")
                for c in jar for name, dom in self.auth_cookies
            )
            if has_cookie:
                # A challenge page (Cloudflare "Just a moment…" in headless) is not a logout; only a
                # redirect to the login wall means the cookie is stale.
                path = urlsplit(url or "").path.lower()
                return not any(m in path for m in self.login_url_markers)
        return self.logged_in(html, url)

    async def _snapshot(self, page: ListingPage) -> tuple[str, str | None] | None | Literal["closed"]:
        """(html, url) of the page, ``None`` while it is mid-navigation (login redirects keep
        changing it) or ``"closed"`` when the user closed the window."""
        try:
            html = await page.content()
            return html, page.url
        except Exception as e:  # noqa: BLE001
            msg = str(e).lower()
            if any(m in msg for m in _PAGE_CLOSED_MARKERS):
                return "closed"
            if any(m in msg for m in _PAGE_NAVIGATING_MARKERS):
                return None
            log.debug("%s: page read failed: %s", self.source_key, e)
            return None

    async def _goto_tolerant(self, page: ListingPage, url: str) -> None:
        try:
            await page.goto(url)
        except Exception as e:  # noqa: BLE001 - a redirect can interrupt the first navigation
            if any(m in str(e).lower() for m in _PAGE_CLOSED_MARKERS):
                raise
            log.debug("%s: goto interrupted: %s", self.source_key, e)

    async def connect(self, *, timeout: float = 600.0, poll: float = 3.0, sleep: Callable[[float], Awaitable[None]] | None = None) -> bool:
        """Onboarding: open the visible window on the login page and wait (polling the DOM
        only) until the user has logged in. The user types their own credentials; nothing is
        stored by AutoApply. Page reads that fail mid-navigation are retried, and a closed
        window or a timeout is reported as an explicit failed status."""
        sleep = sleep or asyncio.sleep
        browser = await self.browser_factory()
        try:
            page = await browser.new_page()
            await self._goto_tolerant(page, self.login_url)
            await self.report_status(False, f"Waiting for you to log in to {self.display_name}…")
            waited = 0.0
            while waited <= timeout:
                snap = await self._snapshot(page)
                if snap == "closed":
                    await self.report_status(
                        False, f"The {self.display_name} login window was closed before login finished. Press Log in to try again.")
                    return False
                if await self._authenticated(browser, snap if snap != "closed" else None):
                    await self.report_status(True, f"{self.display_name} connected")
                    return True
                await sleep(poll)
                waited += poll
            await self.report_status(False, f"Timed out waiting for {self.display_name} login. Press Log in to try again.")
            return False
        finally:
            await browser.close()

    async def check_login(self, *, attempts: int = 5, sleep: Callable[[float], Awaitable[None]] | None = None) -> bool:
        """"Check now": look at the saved Chrome login in a background (headless) window, no login
        window. Records and returns whether the user is logged in."""
        sleep = sleep or asyncio.sleep
        try:
            browser = await (self.headless_browser_factory or self.browser_factory)()
        except Exception as e:  # noqa: BLE001 - e.g. the profile is locked by an open agent Chrome window
            log.info("%s: check_login could not open the browser: %s", self.source_key, e)
            await self.report_status(
                False, f"Couldn't check {self.display_name}: close the AutoApply Chrome window and try again.")
            return False
        try:
            page = await browser.new_page()
            await self._goto_tolerant(page, self.home_url)
            for _ in range(attempts):
                await sleep(2.0)
                snap = await self._snapshot(page)
                if await self._authenticated(browser, snap if snap != "closed" else None):
                    await self.report_status(True, f"{self.display_name} connected")
                    return True
            await self.report_status(False, f"Not logged in to {self.display_name}. Press Log in to sign in again.")
            return False
        finally:
            await browser.close()


_PAGE_NAVIGATING_MARKERS = ("navigating", "execution context was destroyed", "net::err_aborted", "frame was detached")
_PAGE_CLOSED_MARKERS = ("has been closed", "target closed", "page closed", "browser has been closed")


def strip_tracking(url: str) -> str:
    """Drop obvious tracking params but keep ATS-meaningful ones (e.g. ``gh_jid``, ``for``)."""
    p = urlsplit(url)
    if not p.query:
        return url
    kept = [
        (k, v) for k, vs in parse_qs(p.query, keep_blank_values=True).items() for v in vs
        if not re.match(r"^(utm_.*|ref|refid|trk.*|src|source|lever-source|gh_src|ccuid|jobpipeline|tracking.*)$", k, re.I)
    ]
    return urlunsplit((p.scheme, p.netloc, p.path, urlencode(kept), ""))


# =====================================================================================
# LinkedIn
# =====================================================================================

_LI_JOB_ID = re.compile(r"(?:/jobs/view/(?:[^/?#]*-)?|currentJobId=|jobPosting:)(\d{6,})")


def linkedin_job_id(*values: str | None) -> str | None:
    for v in values:
        if not v:
            continue
        if v.isdigit():
            return v
        m = _LI_JOB_ID.search(v)
        if m:
            return m.group(1)
    return None


def linkedin_job_url(job_id: str) -> str:
    return f"{LINKEDIN_BASE}/jobs/view/{job_id}/"


def parse_linkedin_search(html: str, base_url: str = LINKEDIN_BASE) -> list[ListingCard]:
    sel = LINKEDIN_SELECTORS
    soup = _soup(html)
    out: list[ListingCard] = []
    for card in select_all(soup, sel["search_card"]):
        title = text_of(card, sel["card_title"])
        company = text_of(card, sel["card_company"])
        if not title or not company:
            continue
        link = select_first(card, sel["card_link"])
        href = urljoin(base_url, str(link.get("href"))) if link is not None and link.get("href") else None
        job_id = linkedin_job_id(
            str(card.get("data-occludable-job-id") or ""), str(card.get("data-job-id") or ""),
            str(card.get("data-entity-urn") or ""), href,
        )
        detail_url = linkedin_job_url(job_id) if job_id else (strip_query(href) if href else None)
        out.append(
            ListingCard(
                title=title, company=company, location=text_of(card, sel["card_location"]),
                detail_url=detail_url, external_id=job_id,
                easy_apply=any_mentions(card, sel["card_easy_apply"], LINKEDIN_EASY_APPLY_TEXT),
                salary_text=text_of(card, sel["card_salary"]),
            )
        )
    return out


def parse_linkedin_detail(html: str, base_url: str = LINKEDIN_BASE) -> JobDetail:
    sel = LINKEDIN_SELECTORS
    soup = _soup(html)
    easy = any_mentions(soup, sel["detail_apply_button"], LINKEDIN_EASY_APPLY_TEXT)
    apply_url: str | None = None
    if not easy:
        for s in sel["detail_apply_link"]:
            try:
                el = soup.select_one(s)
            except Exception:  # noqa: BLE001
                continue
            if el is None:
                continue
            cand = _comment_url(el) if el.name == "code" else urljoin(base_url, str(el.get("href") or ""))
            cand = unwrap_redirect(cand)
            if cand and not is_host(cand, LINKEDIN_HOSTS):
                apply_url = strip_tracking(cand)
                break
    desc_el = select_first(soup, sel["detail_description"])
    description = clean_text(desc_el.get_text("\n")) if desc_el is not None else None
    return JobDetail(
        title=text_of(soup, sel["detail_title"]), company=text_of(soup, sel["detail_company"]),
        location=text_of(soup, sel["detail_location"]), description=description, easy_apply=easy,
        apply_url=apply_url, salary_text=text_of(soup, sel["detail_salary"]),
        workplace=text_of(soup, sel["detail_workplace"]),
    )


_LI_WORKPLACE = {RemotePolicy.ONSITE: "1", RemotePolicy.REMOTE: "2", RemotePolicy.HYBRID: "3"}


LINKEDIN_WINDOWS = ("r86400", "r604800", "r2592000")  # past 24h, week, month


def linkedin_search_url(prefs: Preferences, role: str, location: str, window: int = 0, page: int = 0) -> str:
    wt = ",".join(sorted(_LI_WORKPLACE[p] for p in prefs.remote_policy if p in _LI_WORKPLACE))
    u = f"{LINKEDIN_BASE}/jobs/search/?keywords={quote_plus(role)}&f_TPR={LINKEDIN_WINDOWS[min(window, len(LINKEDIN_WINDOWS) - 1)]}"
    if location:
        u += f"&location={quote_plus(location)}"
    if wt and len(wt.split(",")) < 3:
        u += f"&f_WT={quote_plus(wt)}"
    if page:
        u += f"&start={25 * page}"
    return u


def linkedin_search_urls(prefs: Preferences) -> list[str]:
    """One URL per (role, location), posted in the last 24h, workplace filter from prefs."""
    from autoapply.discovery.planner import SearchPlanner

    return [linkedin_search_url(prefs, r, loc) for r, loc in SearchPlanner.combos(prefs)]


class LinkedinSource(BrowserListingBase):
    """Implements :class:`autoapply.discovery.base.Source` (read-only LinkedIn listings)."""

    name = JobSource.LINKEDIN
    source_key = "linkedin"
    display_name = "LinkedIn"
    cap_kind = CapKind.LINKEDIN_BUDGET
    hosts = LINKEDIN_HOSTS
    login_url = LINKEDIN_LOGIN_URL
    home_url = LINKEDIN_FEED_URL
    selectors = LINKEDIN_SELECTORS
    login_url_markers = LINKEDIN_LOGIN_URL_MARKERS
    auth_cookies = (("li_at", "linkedin.com"),)
    captcha_url_markers = LINKEDIN_CAPTCHA_URL_MARKERS
    captcha_title_markers = ("security verification", "security check")
    easy_apply_ats = Ats.LINKEDIN_EASY_APPLY

    def sessions_limit(self, prefs: Preferences) -> int:
        return prefs.linkedin_sessions_per_day

    date_windows = LINKEDIN_WINDOWS
    max_pages = 3

    def search_url(self, prefs: Preferences, role: str, location: str, window: int, page: int) -> str:
        return linkedin_search_url(prefs, role, location, window, page)

    def parse_search(self, html: str, base_url: str) -> list[ListingCard]:
        return parse_linkedin_search(html, base_url or LINKEDIN_BASE)

    def parse_detail(self, html: str, base_url: str) -> JobDetail:
        return parse_linkedin_detail(html, base_url or LINKEDIN_BASE)


__all__ = [
    "BrowserListingBase", "HumanPacer", "JobDetail", "LINKEDIN_SELECTORS", "LinkedinSource", "ListingBrowser",
    "ListingCard", "ListingPage", "PageState", "PlaywrightListingBrowser", "detect_page_state", "guess_ats",
    "linkedin_search_urls", "parse_linkedin_detail", "parse_linkedin_search", "parse_salary", "record_source_status",
    "load_source_statuses", "unwrap_redirect",
]
