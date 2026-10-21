"""Company finder: grow the watchlist by searching Google for public ATS boards.

Each run reads a couple of Google result pages for queries like
``site:boards.greenhouse.io "Backend Engineer" Bengaluru`` (also ``job-boards.greenhouse.io``,
``jobs.lever.co``, ``jobs.ashbyhq.com``, ``myworkdayjobs.com``, ``jobs.smartrecruiters.com``,
``apply.workable.com``, ``recruitee.com``), turns the result links into ``(ats, board_token)``,
verifies every new board through its free public JSON API (the same readers the board sources
use) and counts the open roles that match the user's roles (:mod:`autoapply.role_focus`):

* a verified board with matching roles is watched (status ``auto`` in ``company_suggestions`` so
  the user can undo it) while the watchlist is under ``MAX_WATCHED_COMPANIES``; past the cap it
  is a pending suggestion. Its matching jobs are returned right away, so this run sees them;
* a board with no matching roles is remembered (``checked``) and not re-verified for a month;
* a company the user dismissed is skipped.

Google is read in the agent's visible Chrome window (Google blocks headless browsers) through the
shared Playwright browser, at human pace. A query keeps a cursor in ``meta`` (result page, last
run) so each run covers new queries/pages, and Google visits are capped per day. A CAPTCHA
(``/sorry/``) stops the step for the rest of the day; nothing else is affected.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import re
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, quote_plus, urlsplit

from autoapply import db
from autoapply.discovery.base import DiscoveredJob, DiscoveryContext, detect_ats, split_provider_token, wanted_title
from autoapply.discovery.boards import is_readable_board, read_board
from autoapply.discovery.linkedin import (
    BrowserFactory,
    EmitFn,
    HumanPacer,
    ListingPage,
    PageState,
    _noop_emit,
    _soup,
    clean_text,
    detect_page_state,
    playwright_browser_factory,
)
from autoapply.discovery.suggestions import board_url
from autoapply.enums import Ats, SuggestionStatus
from autoapply.models import LogPayload, utcnow

log = logging.getLogger("autoapply.discovery.company_finder")

FINDER_KEY = "company_finder"
META_STATE = "company_finder_state"
GOOGLE_SEARCH = "https://www.google.com/search"
#: Google result pages the finder may open per day (on top of Google Jobs' own sessions).
FINDER_VISITS_PER_DAY = 6
#: Result pages read per run.
QUERIES_PER_RUN = 2
#: Result pages read per query before it rests.
PAGES_PER_QUERY = 3
#: A fully read query rests this long (boards change slowly).
QUERY_REST_DAYS = 7
#: A board with no matching roles is not re-verified for this long.
RECHECK_DAYS = 30
#: After a CAPTCHA the finder stays away from Google this long.
CAPTCHA_REST_HOURS = 12
#: The watchlist size the agent fills by itself (same as ``pipeline.MAX_WATCHED_COMPANIES``).
MAX_WATCHED = 150

#: (ats, ``site:`` host) pairs searched, in rotation.
ATS_SITES: tuple[tuple[Ats, str], ...] = (
    (Ats.GREENHOUSE, "boards.greenhouse.io"),
    (Ats.GREENHOUSE, "job-boards.greenhouse.io"),
    (Ats.LEVER, "jobs.lever.co"),
    (Ats.ASHBY, "jobs.ashbyhq.com"),
    # Boards read by :mod:`autoapply.discovery.boards` (the token says which provider).
    (Ats.WORKDAY, "myworkdayjobs.com"),
    (Ats.OTHER, "jobs.smartrecruiters.com"),
    (Ats.OTHER, "apply.workable.com"),
    (Ats.OTHER, "recruitee.com"),
)
#: ATSs whose boards are always readable given a token; Workday / ``other`` depend on the token
#: (:func:`autoapply.discovery.boards.is_readable_board`).
READERS = (Ats.GREENHOUSE, Ats.LEVER, Ats.ASHBY)
_CAPTCHA_SELECTORS = {"captcha": ["form#captcha-form", "#recaptcha"], "login_wall": []}


@dataclass(slots=True, frozen=True)
class FinderQuery:
    key: str
    role: str
    location: str
    ats: Ats
    site: str
    page: int = 0

    @property
    def text(self) -> str:
        q = f'site:{self.site} "{self.role}"'
        return q + (f" {self.location}" if self.location else "")

    def url(self) -> str:
        start = f"&start={self.page * 10}" if self.page else ""
        return f"{GOOGLE_SEARCH}?q={quote_plus(self.text)}&hl=en{start}"


@dataclass(slots=True)
class BoardHit:
    ats: Ats
    token: str
    title: str = ""   # Google result title (often names the company)
    query: str = ""


@dataclass(slots=True)
class FinderReport:
    queries: int = 0
    boards_found: int = 0
    watched: list[str] = field(default_factory=list)
    suggested: list[str] = field(default_factory=list)
    no_match: int = 0
    failed: int = 0
    captcha: bool = False


# =====================================================================================
# Pure helpers (tested directly)
# =====================================================================================


def _qkey(role: str, location: str, site: str) -> str:
    return hashlib.sha1(f"{role.strip().lower()}|{location.strip().lower()}|{site}".encode()).hexdigest()[:12]


def plan_queries(roles: list[str], locations: list[str], state: dict[str, Any], n: int, *, remote_only: bool = False) -> list[FinderQuery]:
    """Up to ``n`` queries for this run: never-run first, then the least recently run; rested
    queries are skipped. Roles and ATS sites are interleaved so one run spreads out."""
    roles = list(dict.fromkeys(r.strip() for r in roles if r and r.strip()))
    locs = list(dict.fromkeys(loc.strip() for loc in locations if loc and loc.strip()))
    if remote_only and not any("remote" in loc.lower() for loc in locs):
        locs = [*locs, "remote"]
    locs = locs or [""]
    queries = state.get("queries", {})
    now = utcnow().isoformat()
    ranked: list[tuple[tuple, FinderQuery]] = []
    idx = 0
    for li, loc in enumerate(locs):
        for si, (ats, site) in enumerate(ATS_SITES):
            for ri, role in enumerate(roles):
                k = _qkey(role, loc, site)
                st = queries.get(k) or {}
                rest = st.get("rest_until")
                if rest and str(rest) > now:
                    continue
                page = int(st.get("page", 0)) if not rest else 0
                runs = int(st.get("runs", 0))
                # never run first; then interleave by (role, site, location) round; then stalest
                rank = (0 if runs == 0 else 1, str(st.get("last_at") or ""), ri + si + li, idx)
                ranked.append((rank, FinderQuery(k, role, loc, ats, site, page)))
                idx += 1
    ranked.sort(key=lambda r: r[0])
    return [q for _, q in ranked[:n]]


def _unwrap_google(href: str) -> str:
    """``/url?q=https://…&sa=U`` -> ``https://…`` (Google's result redirect)."""
    parts = urlsplit(href)
    if parts.path == "/url" or parts.path.endswith("/url"):
        qs = parse_qs(parts.query)
        for key in ("q", "url"):
            if qs.get(key) and qs[key][0].startswith("http"):
                return qs[key][0]
    return href


def parse_board_results(html: str, query: str = "") -> list[BoardHit]:
    """Distinct readable ATS boards linked from a Google result page, in page order."""
    soup = _soup(html)
    out: dict[tuple[Ats, str], BoardHit] = {}
    for a in soup.find_all("a", href=True):
        url = _unwrap_google(a["href"])
        if not url.startswith("http"):
            continue
        ats, token = detect_ats(url)
        if not token or not is_readable_board(ats, token):
            continue
        key = (ats, token.lower())
        if key in out:
            continue
        h3 = a.find("h3")
        title = clean_text(h3.get_text(" ", strip=True) if h3 else a.get_text(" ", strip=True)) or ""
        out[key] = BoardHit(ats=ats, token=token, title=title, query=query)
    return list(out.values())


_TITLE_PATTERNS = (
    re.compile(r"^job application for .+? at (?P<c>.+)$", re.I),       # Greenhouse posting
    re.compile(r"^(?:jobs|careers|current openings|open positions) at (?P<c>.+)$", re.I),
    re.compile(r"^.+? @ (?P<c>.+)$"),                                   # Ashby posting "Role @ Acme"
    re.compile(r"^(?P<c>.+?) (?:jobs|careers)$", re.I),                 # "Acme Jobs"
    re.compile(r"^(?P<c>[^-–|]+?) [-–] .+$"),                           # Lever "Acme - Role"
)


def company_name_for(hit: BoardHit, jobs: list[DiscoveredJob]) -> str:
    """The company's display name: the board's own name, then the Google title, then the token."""
    token = hit.token.removeprefix("eu:")
    if (prov := split_provider_token(token)) is not None:
        token = prov[1]  # "workable:acme" -> "acme"
    elif "/" in token:
        token = token.split(".", 1)[0]  # Workday "acme.wd5/External" -> "acme"
    for j in jobs:  # Greenhouse returns ``company_name``; the others echo the token
        name = (j.company_name or "").strip()
        if name and name.lower() != token.lower():
            return name
    title = re.sub(r"\s*[|·]\s*.*$", "", hit.title or "").strip()
    for pat in _TITLE_PATTERNS:
        m = pat.match(title)
        if m:
            name = m.group("c").strip(" -–|")
            if 2 <= len(name) <= 60:
                return name
    return " ".join(w.capitalize() for w in re.split(r"[-_.]", token) if w) or token


# =====================================================================================
# The step
# =====================================================================================


class CompanyFinder:
    """A discovery step (``Source`` shaped) that finds companies' public ATS boards on Google.

    Runs with Google Jobs (``enabled_key = "google"``); ``sources_enabled["company_finder"] = false``
    turns it off on its own. Only the normal pass searches (deeper rounds return nothing)."""

    name = FINDER_KEY
    enabled_key = "google"

    def __init__(
        self,
        conn: sqlite3.Connection | None = None,
        *,
        emit: EmitFn | None = None,
        browser_factory: BrowserFactory | None = None,
        profile_dir: Path | None = None,
        pacer: HumanPacer | None = None,
        is_paused: Callable[[], bool] | None = None,
        queries_per_run: int = QUERIES_PER_RUN,
        visits_per_day: int = FINDER_VISITS_PER_DAY,
        max_watched: int = MAX_WATCHED,
        verify_concurrency: int = 4,
    ) -> None:
        if browser_factory is None:
            if profile_dir is None:
                from autoapply.paths import get_paths

                profile_dir = get_paths().chrome_profile
            browser_factory = playwright_browser_factory(profile_dir)  # visible: Google blocks headless
        # Private name on purpose: the pipeline's deeper rounds re-run sources with ``browser_factory``.
        self._browser_factory = browser_factory
        self._conn = conn
        self.emit: EmitFn = emit or _noop_emit
        self.pacer = pacer or HumanPacer()
        self.is_paused = is_paused or (lambda: False)
        self.queries_per_run = queries_per_run
        self.visits_per_day = visits_per_day
        self.max_watched = max_watched
        self.verify_concurrency = verify_concurrency
        self.last_report: FinderReport | None = None

    @property
    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            self._conn = db.open_db()
        return self._conn

    # ---- state ------------------------------------------------------------------------

    def _state(self) -> dict[str, Any]:
        st = db.get_meta(self.conn, META_STATE, {}) or {}
        return st if isinstance(st, dict) else {}

    def _save(self, st: dict[str, Any]) -> None:
        db.set_meta(self.conn, META_STATE, st)

    async def _log(self, message: str, level: str = "info") -> None:
        getattr(log, "warning" if level == "warning" else "info")("%s", message)
        try:
            await self.emit("log", LogPayload(level=level, message=message, logger=log.name, at=utcnow()))
        except Exception:  # noqa: BLE001
            log.debug("emit failed", exc_info=True)

    # ---- discover ---------------------------------------------------------------------

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        if ctx.round > 0 or not ctx.preferences.sources_enabled.get(FINDER_KEY, True):
            return []
        roles = list(ctx.preferences.roles)
        if not roles:
            return []
        st = self._state()
        now = utcnow()
        rest = st.get("rest_until")
        if rest and str(rest) > now.isoformat():
            return []
        used = db.get_source_sessions(self.conn, FINDER_KEY)
        budget = max(0, self.visits_per_day - used)
        if budget <= 0:
            await self._log(f"Company finder: today's Google searches are used up ({used}/{self.visits_per_day})")
            return []
        remote_only = {getattr(p, "value", p) for p in ctx.preferences.remote_policy} == {"remote"}
        queries = plan_queries(roles, list(ctx.preferences.locations), st, min(self.queries_per_run, budget), remote_only=remote_only)
        if not queries:
            return []

        report = FinderReport()
        self.last_report = report
        hits = await self._search(queries, st, report, ctx)
        jobs = await self._verify(ctx, hits, st, report)
        self._save(st)
        parts = [f"{report.queries} Google search(es)", f"{report.boards_found} new board(s)"]
        if report.watched:
            parts.append(f"watching {len(report.watched)}: {', '.join(report.watched[:6])}")
        if report.suggested:
            parts.append(f"suggested {len(report.suggested)}: {', '.join(report.suggested[:6])}")
        if report.no_match:
            parts.append(f"{report.no_match} without matching roles")
        await self._log("Company finder: " + "; ".join(parts))
        return jobs

    async def _search(self, queries: list[FinderQuery], st: dict[str, Any], report: FinderReport, ctx: DiscoveryContext) -> list[BoardHit]:
        hits: list[BoardHit] = []
        qstate: dict[str, Any] = st.setdefault("queries", {})
        browser = await self._browser_factory()
        try:
            page: ListingPage = await browser.new_page()
            for i, q in enumerate(queries):
                if self.is_paused():
                    break
                if i:
                    await self.pacer.between_search_pages()
                db.increment_source_sessions(self.conn, FINDER_KEY)
                await page.goto(q.url())
                await self.pacer.after_load()
                html = await page.content()
                if detect_page_state(html, page.url, _CAPTCHA_SELECTORS, captcha_url_markers=("/sorry/",),
                                     captcha_title_markers=("unusual traffic",)) is PageState.CAPTCHA:
                    report.captcha = True
                    st["rest_until"] = (utcnow() + timedelta(hours=CAPTCHA_REST_HOURS)).isoformat()
                    await self._log("Company finder: Google showed a security check; skipping the company search "
                                    f"for {CAPTCHA_REST_HOURS} hours", "warning")
                    break
                await self.pacer.scroll(page)
                found = parse_board_results(await page.content(), q.text)
                report.queries += 1
                hits.extend(found)
                qs = dict(qstate.get(q.key) or {})
                qs.update(role=q.role, location=q.location, site=q.site, runs=int(qs.get("runs", 0)) + 1,
                          last_at=utcnow().isoformat(), found=int(qs.get("found", 0)) + len(found), rest_until=None)
                if not found or q.page + 1 >= PAGES_PER_QUERY:
                    qs["page"] = 0
                    qs["rest_until"] = (utcnow() + timedelta(days=QUERY_REST_DAYS)).isoformat()
                else:
                    qs["page"] = q.page + 1
                qstate[q.key] = qs
        finally:
            try:
                await browser.close()
            except Exception:  # noqa: BLE001
                log.debug("browser close failed", exc_info=True)
        return hits

    def _known(self, ats: Ats, token: str) -> Any:
        if ats is Ats.OTHER:  # provider-prefixed token ("workable:acme"); the row's ats may be NULL
            return self.conn.execute(
                "SELECT id, name, watch FROM companies WHERE (ats IS NULL OR ats = 'other') AND lower(board_token) = lower(?)",
                (token,),
            ).fetchone()
        return self.conn.execute(
            "SELECT id, name, watch FROM companies WHERE ats = ? AND lower(board_token) = lower(?)", (ats.value, token)
        ).fetchone()

    def _room(self) -> bool:
        return len(db.list_companies(self.conn, watch_only=True)) < self.max_watched

    async def _verify(self, ctx: DiscoveryContext, hits: list[BoardHit], st: dict[str, Any], report: FinderReport) -> list[DiscoveredJob]:
        checked: dict[str, str] = st.setdefault("checked", {})
        cutoff = (utcnow() - timedelta(days=RECHECK_DAYS)).isoformat()
        todo: list[BoardHit] = []
        seen: set[str] = set()
        for h in hits:
            k = f"{h.ats.value}:{h.token.lower()}"
            if k in seen:
                continue
            seen.add(k)
            known = self._known(h.ats, h.token)
            if known is not None and known["watch"]:
                continue
            if str(checked.get(k) or "") > cutoff:
                continue
            todo.append(h)
        report.boards_found = len(todo)
        sem = asyncio.Semaphore(max(1, self.verify_concurrency))

        async def fetch(h: BoardHit) -> tuple[BoardHit, list[DiscoveredJob] | None]:
            async with sem:
                try:
                    return h, await read_board(ctx.http, h.ats, h.token, None)
                except Exception as e:  # noqa: BLE001 - a dead board is just not a suggestion
                    log.info("company finder: board %s:%s did not verify: %s", h.ats.value, h.token, e)
                    return h, None

        out: list[DiscoveredJob] = []
        for h, jobs in await asyncio.gather(*(fetch(h) for h in todo)):
            k = f"{h.ats.value}:{h.token.lower()}"
            checked[k] = utcnow().isoformat()
            if jobs is None:
                report.failed += 1
                continue
            matching = [j for j in jobs if wanted_title(ctx, j.title)]
            if not matching:
                report.no_match += 1
                continue
            known = self._known(h.ats, h.token)
            name = known["name"] if known is not None else company_name_for(h, jobs)
            if db.company_dismissed(self.conn, name):
                continue
            existing = db.get_company_by_name(self.conn, name)
            if existing is not None and existing.watch:
                continue
            for j in matching:
                j.company_name = name
                j.raw = {**(j.raw or {}), "found_by": FINDER_KEY}
            common = dict(url=board_url(h.ats, h.token), source=FINDER_KEY, ats=h.ats, board_token=h.token,
                          found_via=h.query or None, sample_title=matching[0].title, matching_roles=len(matching),
                          open_roles=len(jobs), verified=True)
            if self._room():
                company = db.upsert_company(self.conn, name, ats=h.ats, board_token=h.token, watch=True)
                db.suggest_company(self.conn, name, status=SuggestionStatus.AUTO, company_id=company.id, **common)
                report.watched.append(name)
                limit = ctx.limit_per_company
                out.extend(matching[:limit] if limit is not None else matching)
            elif db.suggest_company(self.conn, name, **common) is not None:
                report.suggested.append(name)
        return out


__all__ = [
    "ATS_SITES",
    "BoardHit",
    "CompanyFinder",
    "FINDER_KEY",
    "FinderQuery",
    "company_name_for",
    "parse_board_results",
    "plan_queries",
]
