"""Company career pages + the company watchlist.

Owner: Workstream A (engine core).

:class:`CareersSource` visits user-supplied career-page URLs
(``preferences.career_page_urls`` and ``companies.careers_url`` of watched companies),
finds the ATS behind them and pulls postings from the ATS's public board API:

* the URL itself is an ATS board (``boards.greenhouse.io/x``, ``jobs.lever.co/x``,
  ``jobs.ashbyhq.com/x``) -> that board is fetched directly, no page load;
* otherwise the page HTML is scanned for ATS links, embed iframes / scripts
  (``boards.greenhouse.io/embed/job_board?for=x``, ``jobs.ashbyhq.com/x/embed``) and
  posting links; every distinct (ATS, board token) found is fetched via its source;
* links to ATSs without a public board API (Workday, unknown) are returned as postings
  with the anchor text as title, so the agentic adapter can take them.

Watchlist helpers: :func:`add_to_watchlist` (company + URL/token -> watched company row
with ATS and board token) and :func:`learn_board_tokens` (enrich companies from apply URLs
found by LinkedIn/Glassdoor without switching ``watch`` on).
"""

from __future__ import annotations

import asyncio
import logging
import re
import sqlite3
from collections.abc import Iterable
from urllib.parse import urljoin, urlsplit

import httpx

from autoapply.discovery import ashby as _ashby
from autoapply.discovery import greenhouse as _gh
from autoapply.discovery import lever as _lever
from autoapply.discovery.base import (
    USER_AGENT,
    DiscoveredJob,
    DiscoveryContext,
    detect_ats,
    extract_job_id,
    filter_jobs,
)
from autoapply.discovery.base import detect_ats as _detect_ats
from autoapply.enums import Ats, JobSource
from autoapply.models import Company

log = logging.getLogger("autoapply.discovery.careers")

__all__ = [
    "CareersSource",
    "add_to_watchlist",
    "detect_ats",
    "extract_job_id",
    "find_ats_boards",
    "learn_board_tokens",
]

_BOARD_FETCHERS = {
    Ats.GREENHOUSE: lambda http, tok, name: _gh.fetch_board(http, tok, company_name=name),
    Ats.LEVER: lambda http, tok, name: _lever.fetch_postings(http, tok, company_name=name),
    Ats.ASHBY: lambda http, tok, name: _ashby.fetch_job_board(http, tok, company_name=name),
}

_JOBISH = re.compile(r"/(jobs?|careers?|positions?|openings?|roles?|vacanc(y|ies))/", re.I)


def company_name_from_url(url: str) -> str:
    """``https://careers.acme-robotics.com/jobs`` -> ``Acme Robotics`` (best effort)."""
    host = (urlsplit(url).hostname or "").lower()
    if host.endswith(("oraclecloud.com", "myworkdayjobs.com", "smartrecruiters.com", "icims.com", "taleo.net")):
        host = host.split(".")[0] + ".example"  # multi-tenant ATS hosts: the tenant is the first label
    parts = [p for p in host.split(".") if p not in ("www", "careers", "jobs", "join", "work", "apply")]
    core = parts[-2] if len(parts) >= 2 else (parts[0] if parts else host)
    return " ".join(w.capitalize() for w in re.split(r"[-_]", core) if w) or host


def find_ats_boards(html: str, base_url: str) -> tuple[set[tuple[Ats, str]], list[tuple[str, str]]]:
    """Scan a career page. Returns ``(boards, other_links)`` where ``boards`` is the set of
    (ats, board_token) with a public API and ``other_links`` is ``[(url, anchor text)]`` for
    job links on ATSs we can't list (Workday) — deduped, in page order."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    boards: set[tuple[Ats, str]] = set()
    others: list[tuple[str, str]] = []
    seen: set[str] = set()

    def consider(url: str, text: str = "") -> None:
        if not url or url.startswith(("mailto:", "tel:", "javascript:", "#")):
            return
        absolute = urljoin(base_url, url)
        ats, token = _detect_ats(absolute)
        if ats in _BOARD_FETCHERS and token:
            boards.add((ats, token))
        elif ats is Ats.WORKDAY and absolute not in seen:
            title = " ".join(text.split())
            if title and _JOBISH.search(urlsplit(absolute).path + "/"):
                seen.add(absolute)
                others.append((absolute, title))

    for a in soup.find_all("a", href=True):
        consider(a["href"], a.get_text(" ", strip=True))
    for tag in soup.find_all(["iframe", "script"], src=True):
        consider(tag["src"])
    # Greenhouse embed snippet: <div id="grnhse_app"> + Grnhse.Settings / script with ?for=token
    for m in re.finditer(r"greenhouse\.io/embed/job_board(?:/js)?\?for=([A-Za-z0-9_.\-]+)", html):
        boards.add((Ats.GREENHOUSE, m.group(1)))
    for m in re.finditer(r"jobs\.ashbyhq\.com/([A-Za-z0-9_.\-]+)/embed", html):
        boards.add((Ats.ASHBY, m.group(1)))
    return boards, others


#: Posting-looking URL paths on JS-rendered career sites (Oracle HCM ``/job/123``, ``/jobs/slug``, ...).
_RENDERED_JOB_HREF = re.compile(r"/(jobs?|positions?|openings?|requisitions?|vacanc(?:y|ies)|postings?|job-details?)/[^/?#]+|[?&](job_?id|req_?id|jid)=", re.I)
#: A link worth one extra hop when the landing page lists no postings (``/explore-jobs``, ``/open-positions``).
_HOP_HREF = re.compile(r"explore-jobs|open-?(positions|roles|jobs)|all-jobs|search-?jobs|job-?search|/jobs/?$|/openings/?$", re.I)
_NOT_A_TITLE = re.compile(r"^(apply|view|save|share|back|next|previous|jobs?|careers?|search|learn more|read more)$", re.I)

_COLLECT_LINKS_JS = """
() => {
  const out = [], seen = new Set();
  for (const a of document.querySelectorAll('a[href]')) {
    const href = a.href;
    if (!href || seen.has(href)) continue;
    const text = (a.innerText || a.getAttribute('aria-label') || '').trim();
    seen.add(href);
    // Many sites leave the link itself empty: climb to the nearest ancestor that carries the card text.
    let card = a;
    for (let i = 0; i < 5 && card && (card.innerText || '').trim().length < 15; i++) card = card.parentElement;
    out.push({href, text, card: ((card && card.innerText) || '').trim().slice(0, 700)});
  }
  return out;
}
"""


_TITLE_KEYS = ("title", "jobtitle", "job_title", "name", "position", "role", "t")
_URL_KEYS = ("url", "applyurl", "apply_url", "absolute_url", "joburl", "job_url", "link", "href", "u")


def harvest_json_postings(payloads: list[object], limit: int = 120) -> list[tuple[str, str, str]]:
    """(url, title, card text) from a site's own JSON job feed (e.g. ``/api/jobs.json``).

    Finds the largest list of objects that each carry a link and a title-like string; key names vary
    wildly (some feeds use ``t``/``u``), so keys are matched loosely with a first-string fallback."""
    best: list[dict] = []

    def walk(node: object, depth: int = 0) -> None:
        nonlocal best
        if depth > 4:
            return
        if isinstance(node, list):
            dicts = [x for x in node if isinstance(x, dict)]
            if len(dicts) >= 2 and len(dicts) > len(best) and sum(_job_url(d) is not None for d in dicts) >= len(dicts) * 0.8:
                best = dicts
            for x in node[:50]:
                walk(x, depth + 1)
        elif isinstance(node, dict):
            for v in node.values():
                walk(v, depth + 1)

    for payload in payloads:
        walk(payload)
    out: list[tuple[str, str, str]] = []
    for d in best:
        url = _job_url(d)
        strings = [v.strip() for v in d.values() if isinstance(v, str) and v.strip() and not v.startswith(("http://", "https://"))]
        low = {k.lower(): v for k, v in d.items() if isinstance(v, str)}
        title = next((low[k].strip() for k in _TITLE_KEYS if k in low and 4 <= len(low[k].strip()) <= 140), "")
        title = title or next((s for s in strings if 4 <= len(s) <= 140), "")
        if url and title:
            out.append((url, title, " · ".join(dict.fromkeys(strings))[:700]))
        if len(out) >= limit:
            break
    return out


def _job_url(d: dict) -> str | None:
    low = {k.lower(): v for k, v in d.items() if isinstance(v, str)}
    for k in _URL_KEYS:
        v = low.get(k, "")
        if v.startswith(("http://", "https://")):
            return v
    return next((v for v in low.values() if v.startswith(("http://", "https://"))), None)


def pick_rendered_postings(rows: list[dict[str, str]], limit: int = 40) -> list[tuple[str, str, str]]:
    """(url, title, card text) for anchors that look like individual postings."""
    out: list[tuple[str, str, str]] = []
    seen: set[str] = set()
    for r in rows:
        href = r.get("href", "")
        if href in seen or not _RENDERED_JOB_HREF.search(href):
            continue
        # Title: the anchor's own text, else the first line of its card (many sites leave the link itself empty).
        lines = [ln.strip() for ln in ((r.get("text") or "") + "\n" + (r.get("card") or "")).splitlines() if ln.strip()]
        title = next((ln for ln in lines if 4 <= len(ln) <= 140 and not _NOT_A_TITLE.match(ln)), "")
        if not title:
            continue
        seen.add(href)
        out.append((href, title, r.get("card") or title))
        if len(out) >= limit:
            break
    return out


async def _json_found(grabs: list[asyncio.Task], payloads: list[object]) -> list[tuple[str, str, str]]:
    if grabs:
        await asyncio.gather(*grabs, return_exceptions=True)
    return harvest_json_postings(payloads)


async def render_postings(url: str, *, max_hops: int = 1, limit: int = 40) -> list[tuple[str, str, str]]:
    """Load a JS-rendered career page in headless Chromium (no login profile) and read its posting links.
    Follows at most ``max_hops`` "explore jobs"-style links when the landing page lists none."""
    from playwright.async_api import async_playwright

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)
        try:
            page = await (await browser.new_context(user_agent="Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/124 Safari/537.36")).new_page()

            payloads: list[object] = []
            grabs: list[asyncio.Task] = []

            async def grab(resp) -> None:  # type: ignore[no-untyped-def]
                try:
                    if resp.request.resource_type in ("xhr", "fetch") and "json" in (resp.headers.get("content-type") or ""):
                        payloads.append(await resp.json())
                except Exception:  # noqa: BLE001
                    pass

            page.on("response", lambda r: grabs.append(asyncio.ensure_future(grab(r))))

            async def load(u: str) -> list[dict[str, str]]:
                await page.goto(u, wait_until="domcontentloaded", timeout=45_000)
                try:
                    await page.wait_for_load_state("networkidle", timeout=12_000)
                except Exception:  # noqa: BLE001 - long-polling pages never go idle
                    pass
                for _ in range(3):  # lazy lists load as you scroll
                    await page.mouse.wheel(0, 2500)
                    await asyncio.sleep(1.0)
                return list(await page.evaluate(_COLLECT_LINKS_JS))

            rows = await load(url)
            found = pick_rendered_postings(rows, limit) or (await _json_found(grabs, payloads))
            hops = 0
            while not found and hops < max_hops:
                hop = next((r["href"] for r in rows if _HOP_HREF.search(r["href"]) and r["href"].rstrip("/") != page.url.rstrip("/")), None)
                if not hop:
                    break
                rows = await load(hop)
                found = pick_rendered_postings(rows, limit) or (await _json_found(grabs, payloads))
                hops += 1
            return found
        finally:
            await browser.close()


class CareersSource:
    """Implements :class:`autoapply.discovery.base.Source`."""

    name = JobSource.CAREERS

    def __init__(self, *, max_pages: int = 25) -> None:
        self.max_pages = max_pages

    def _targets(self, ctx: DiscoveryContext) -> list[tuple[str, str | None]]:
        """(url, known company name or None), deduped, watched companies first."""
        out: list[tuple[str, str | None]] = []
        seen: set[str] = set()
        for c in ctx.companies:
            if c.careers_url and c.careers_url not in seen:
                seen.add(c.careers_url)
                out.append((c.careers_url, c.name))
        for url in ctx.preferences.career_page_urls:
            if url and url not in seen:
                seen.add(url)
                out.append((url, None))
        return out[: self.max_pages]

    def _already_covered(self, ctx: DiscoveryContext) -> set[tuple[Ats, str]]:
        """Boards the dedicated GH/Lever/Ashby sources already fetch for the watchlist."""
        covered = set()
        enabled = ctx.preferences.sources_enabled
        for c in ctx.companies:
            if c.ats and c.board_token and enabled.get(str(Ats(c.ats).value), False):
                covered.add((Ats(c.ats), c.board_token))
        return covered

    async def scan_page(self, http: httpx.AsyncClient, url: str) -> tuple[set[tuple[Ats, str]], list[tuple[str, str]]]:
        ats, token = _detect_ats(url)
        if ats in _BOARD_FETCHERS and token:
            return {(ats, token)}, []
        resp = await http.get(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html"}, follow_redirects=True)
        resp.raise_for_status()
        final_url = str(resp.url)
        ats, token = _detect_ats(final_url)  # redirected straight onto an ATS board
        if ats in _BOARD_FETCHERS and token:
            return {(ats, token)}, []
        return find_ats_boards(resp.text, final_url)

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        covered = self._already_covered(ctx)
        fetched: set[tuple[Ats, str]] = set()
        out: list[DiscoveredJob] = []
        for url, known_name in self._targets(ctx):
            name = known_name or company_name_from_url(url)
            try:
                boards, others = await self.scan_page(ctx.http, url)
            except Exception as e:
                log.warning("career page %s failed: %s", url, e)
                ctx.errors[name] = str(e)
                continue
            page_jobs: list[DiscoveredJob] = []
            for ats, token in sorted(boards, key=lambda b: (b[0].value, b[1])):
                if (ats, token) in covered or (ats, token) in fetched:
                    continue
                fetched.add((ats, token))
                try:
                    jobs = await _BOARD_FETCHERS[ats](ctx.http, token, known_name)
                except Exception as e:
                    log.warning("board %s:%s (from %s) failed: %s", ats.value, token, url, e)
                    ctx.errors[f"{name} ({ats.value}:{token})"] = str(e)
                    continue
                for j in jobs:
                    j.source = JobSource.CAREERS
                    j.raw["careers_url"] = url
                    if not known_name and j.company_name == token:
                        j.company_name = name
                page_jobs.extend(jobs)
            for link, title in others:
                ats, token = _detect_ats(link)
                page_jobs.append(
                    DiscoveredJob(
                        source=JobSource.CAREERS, company_name=name, title=title, apply_url=link, source_url=url,
                        ats=ats, external_id=extract_job_id(link), board_token=token,
                        company_domain=urlsplit(url).hostname, raw={"careers_url": url},
                    )
                )
            if not page_jobs and not boards and not others:
                # Plain HTML shows no postings: most modern career sites render them with JavaScript.
                try:
                    rendered = await render_postings(url)
                except Exception as e:  # noqa: BLE001
                    log.warning("rendering career page %s failed: %s", url, e)
                    ctx.errors[name] = f"could not render the page: {e}"
                    continue
                for link, title, card in rendered:
                    ats, token = _detect_ats(link)
                    page_jobs.append(
                        DiscoveredJob(
                            source=JobSource.CAREERS, company_name=name, title=title, apply_url=link, source_url=url,
                            ats=ats, external_id=extract_job_id(link), board_token=token, description=card,
                            company_domain=urlsplit(url).hostname, raw={"careers_url": url, "via": "rendered"},
                        )
                    )
                if not rendered:
                    ctx.errors[name] = "no job postings found on the page (it may need a search/filter or login)"
            out.extend(filter_jobs(ctx, page_jobs))
        return out


# =====================================================================================
# Watchlist
# =====================================================================================


def add_to_watchlist(
    conn: sqlite3.Connection,
    name: str,
    url_or_token: str | None = None,
    *,
    ats: Ats | str | None = None,
    domain: str | None = None,
) -> Company:
    """Watch a company. ``url_or_token`` may be any ATS URL (board, posting or API), a
    career-page URL (stored as ``careers_url`` for :class:`CareersSource`), or a bare board
    token together with ``ats``."""
    from autoapply import db

    token: str | None = None
    careers_url: str | None = None
    detected = Ats.OTHER
    if url_or_token:
        if "://" in url_or_token:
            detected, token = _detect_ats(url_or_token)
            if detected is Ats.OTHER or (detected in _BOARD_FETCHERS and not token):
                careers_url = url_or_token
                domain = domain or urlsplit(url_or_token).hostname
        else:
            token = url_or_token.strip()
            if ats is None:
                raise ValueError("a bare board token needs ats= (greenhouse|lever|ashby)")
    final_ats = Ats(ats) if ats is not None else (detected if detected is not Ats.OTHER else None)
    return db.upsert_company(conn, name, ats=final_ats, board_token=token, careers_url=careers_url, domain=domain, watch=True)


def learn_board_tokens(conn: sqlite3.Connection, apply_urls: Iterable[tuple[str, str]]) -> list[Company]:
    """For ``(company name, apply URL)`` pairs (e.g. from LinkedIn listings), record the
    company's ATS + board token when it isn't known yet. Never sets ``watch``."""
    from autoapply import db

    updated: list[Company] = []
    for name, url in apply_urls:
        ats, token = _detect_ats(url)
        if ats is Ats.OTHER or not name:
            continue
        existing = db.get_company_by_name(conn, name)
        if existing and existing.ats and existing.board_token:
            continue
        updated.append(
            db.upsert_company(
                conn, name,
                ats=ats if not (existing and existing.ats) else None,
                board_token=token if token and not (existing and existing.board_token) else None,
            )
        )
    return updated
