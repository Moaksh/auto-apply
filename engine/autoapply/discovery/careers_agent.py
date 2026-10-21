"""Career-page agents: read companies' own career sites for jobs, several sites at a time.

Targets are the watched companies with a ``careers_url`` and no readable ATS board (user-added,
or an accepted suggestion) plus ``preferences.career_page_urls``. One agent per site, at most
``concurrency`` (3) at once, each trying the cheapest thing that works:

1. the URL (or where it redirects) **is** a Greenhouse / Lever / Ashby board -> that board's
   public JSON reader, and the board is recorded on the company so the board source reads it
   from now on;
2. plain HTTP fetch of the page, then
   a. ATS boards embedded or linked in the page (iframes, scripts, links) -> their readers;
   b. ``JobPosting`` JSON-LD (schema.org; most career CMSs emit it);
   c. job-looking links (``/jobs/…``, ``/careers/…``, ``?gh_jid=`` …) with their anchor text;
3. a page with little static text (a JavaScript app) is rendered in headless Chromium and its
   posting links / JSON feeds are read (:func:`autoapply.discovery.careers.render_postings`);
4. only when all of that finds nothing on a page with real text, the LLM (fast tier) extracts
   the postings from the page text.

A content hash per site is kept in ``meta``: an unchanged page reuses the postings extracted last
time (no tokens, no re-render of a static page). Titles are filtered with the role focus
(:func:`autoapply.discovery.base.filter_jobs`). Every site's outcome is logged.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import sqlite3
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urljoin, urlsplit

import httpx

from autoapply import db
from autoapply.discovery.base import (
    USER_AGENT,
    DiscoveredJob,
    DiscoveryContext,
    detect_ats,
    extract_job_id,
    filter_jobs,
    html_to_text,
    infer_remote,
    parse_datetime,
)
from autoapply.discovery.boards import is_readable_board
from autoapply.discovery.careers import _BOARD_FETCHERS, company_name_from_url, find_ats_boards, pick_rendered_postings
from autoapply.enums import Ats, JobSource
from autoapply.models import LogPayload, utcnow

log = logging.getLogger("autoapply.discovery.careers_agent")

#: Sites read at the same time.
CONCURRENCY = 3
#: Sites per run (watched companies first).
MAX_SITES = 40
#: Static text shorter than this is a JavaScript shell: render it instead of asking the LLM.
MIN_TEXT_FOR_LLM = 400
#: Page text sent to the LLM (characters).
LLM_TEXT_CHARS = 12_000
#: Links offered to the LLM so it can return real posting URLs.
LLM_LINKS = 150
META_PREFIX = "careers_page:"

Renderer = Callable[[str], Awaitable[list[tuple[str, str, str]]]]

EXTRACT_PROMPT = (
    "EXTRACT JOB POSTINGS. Below is the text of a company's career page and the links on it. List every "
    "individual open job posting you can see: its exact title, the link to that posting (copy it from the "
    "LINKS list; use null if none fits) and its location if shown. Do not invent postings; ignore "
    "navigation, departments, blog posts and benefits. Return an empty list if the page lists no jobs.\n\n"
    "PAGE: {url}\n\nTEXT:\n{text}\n\nLINKS (text -> url):\n{links}"
)
EXTRACT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "jobs": {
            "type": "array",
            "maxItems": 100,
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "url": {"type": ["string", "null"]},
                    "location": {"type": ["string", "null"]},
                },
                "required": ["title"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["jobs"],
    "additionalProperties": False,
}


@dataclass(slots=True)
class Posting:
    title: str
    url: str | None = None
    location: str | None = None
    description: str | None = None
    posted_at: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {"title": self.title, "url": self.url, "location": self.location, "description": self.description,
                "posted_at": self.posted_at}


@dataclass(slots=True)
class SiteResult:
    url: str
    company: str
    method: str = "none"          # ats | embedded-ats | json-ld | links | rendered | llm | cached:<m> | none
    jobs: list[DiscoveredJob] = field(default_factory=list)
    kept: int = 0
    error: str | None = None
    tokens: int = 0


# =====================================================================================
# Pure extraction helpers
# =====================================================================================


def content_hash(html: str) -> str:
    """Hash of what a reader sees (text + link targets), ignoring scripts, nonces and styling."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    ld = [s.get_text() for s in soup.find_all("script", type="application/ld+json")]
    for tag in soup(["script", "style", "noscript", "svg", "meta", "link"]):
        tag.decompose()
    text = " ".join(soup.get_text(" ", strip=True).split())
    hrefs = sorted({a["href"] for a in soup.find_all("a", href=True)})
    blob = json.dumps([text, hrefs, ld], ensure_ascii=False)
    return hashlib.sha256(blob.encode()).hexdigest()


def _walk_jsonld(node: Any, out: list[dict[str, Any]], depth: int = 0) -> None:
    if depth > 6:
        return
    if isinstance(node, list):
        for x in node:
            _walk_jsonld(x, out, depth + 1)
    elif isinstance(node, dict):
        t = node.get("@type")
        types = t if isinstance(t, list) else [t]
        if "JobPosting" in types:
            out.append(node)
        for key in ("@graph", "itemListElement", "item", "mainEntity", "hasPart"):
            if key in node:
                _walk_jsonld(node[key], out, depth + 1)


def _ld_location(loc: Any) -> str | None:
    locs = loc if isinstance(loc, list) else [loc]
    parts: list[str] = []
    for one in locs:
        if not isinstance(one, dict):
            if isinstance(one, str) and one.strip():
                parts.append(one.strip())
            continue
        addr = one.get("address", one)
        if isinstance(addr, str):
            parts.append(addr)
            continue
        if isinstance(addr, dict):
            bits = [addr.get(k) for k in ("addressLocality", "addressRegion", "addressCountry")]
            bits = [b.get("name") if isinstance(b, dict) else b for b in bits]
            text = ", ".join(str(b) for b in bits if b)
            if text:
                parts.append(text)
    return "; ".join(dict.fromkeys(parts)) or None


def parse_jsonld_postings(html: str, base_url: str) -> list[Posting]:
    """``JobPosting`` objects in ``<script type="application/ld+json">`` blocks."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    found: list[dict[str, Any]] = []
    for s in soup.find_all("script", type="application/ld+json"):
        raw = s.string or s.get_text() or ""
        try:
            data = json.loads(raw.strip())
        except ValueError:
            continue
        _walk_jsonld(data, found)
    out: list[Posting] = []
    seen: set[tuple[str, str | None]] = set()
    for jp in found:
        title = " ".join(str(jp.get("title") or jp.get("name") or "").split())
        if not title:
            continue
        url = jp.get("url") or jp.get("sameAs")
        url = urljoin(base_url, url) if isinstance(url, str) and url else None
        key = (title.lower(), url)
        if key in seen:
            continue
        seen.add(key)
        loc = _ld_location(jp.get("jobLocation"))
        if not loc and str(jp.get("jobLocationType") or "").upper() == "TELECOMMUTE":
            loc = "Remote"
        desc = jp.get("description")
        out.append(Posting(title=title, url=url, location=loc,
                           description=html_to_text(desc, unescape_first=True) if isinstance(desc, str) else None,
                           posted_at=str(jp.get("datePosted")) if jp.get("datePosted") else None))
    return out


def link_postings(html: str, base_url: str, limit: int = 60) -> list[Posting]:
    """Anchors that look like individual postings (``/jobs/123-backend``, ``?gh_jid=``) with their text."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    rows: list[dict[str, str]] = []
    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        if href.startswith(("mailto:", "tel:", "javascript:", "#")):
            continue
        absolute = urljoin(base_url, href)
        if absolute.rstrip("/") == base_url.rstrip("/"):
            continue
        text = a.get_text("\n", strip=True)
        card = a
        for _ in range(4):
            if len(card.get_text(" ", strip=True)) >= 15 or card.parent is None:
                break
            card = card.parent
        rows.append({"href": absolute, "text": text, "card": card.get_text("\n", strip=True)[:700]})
    return [Posting(title=t, url=u) for u, t, _card in pick_rendered_postings(rows, limit)]


def page_links(html: str, base_url: str, limit: int = LLM_LINKS) -> list[tuple[str, str]]:
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    out: dict[str, str] = {}
    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        if href.startswith(("mailto:", "tel:", "javascript:", "#")):
            continue
        text = " ".join(a.get_text(" ", strip=True).split())[:120]
        if not text:
            continue
        out.setdefault(urljoin(base_url, href), text)
        if len(out) >= limit:
            break
    return [(u, t) for u, t in out.items()]


def page_text(html: str) -> str:
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "noscript", "svg", "head"]):
        tag.decompose()
    return html_to_text(str(soup))


# =====================================================================================
# The source
# =====================================================================================


class CareerPageAgent:
    """Implements :class:`autoapply.discovery.base.Source` for company career pages."""

    name = JobSource.CAREERS

    def __init__(
        self,
        conn: sqlite3.Connection | None = None,
        llm: Any = None,
        *,
        emit: Callable[[str, Any], Awaitable[None]] | None = None,
        renderer: Renderer | None = None,
        concurrency: int = CONCURRENCY,
        max_sites: int = MAX_SITES,
    ) -> None:
        self._conn = conn
        self.llm = llm
        self.emit = emit
        self.renderer = renderer
        self.concurrency = concurrency
        self.max_sites = max_sites
        self.results: list[SiteResult] = []

    # ---- targets ----------------------------------------------------------------------

    def targets(self, ctx: DiscoveryContext) -> list[tuple[str, str | None]]:
        """(url, company name or None): watched companies without a readable board, then the
        career pages listed in preferences; deduped."""
        out: list[tuple[str, str | None]] = []
        seen: set[str] = set()
        for c in ctx.companies:
            if not c.careers_url or c.careers_url in seen:
                continue
            if is_readable_board(c.ats, c.board_token):
                continue  # a board source (Greenhouse / Lever / Ashby / Workday / ...) already reads this company
            seen.add(c.careers_url)
            out.append((c.careers_url, c.name))
        for url in ctx.preferences.career_page_urls:
            if url and url not in seen:
                seen.add(url)
                out.append((url, None))
        return out[: self.max_sites]

    def _covered(self, ctx: DiscoveryContext) -> set[tuple[Ats, str]]:
        enabled = ctx.preferences.sources_enabled
        return {(Ats(c.ats), c.board_token) for c in ctx.companies
                if c.ats and c.board_token and Ats(c.ats) in _BOARD_FETCHERS and enabled.get(Ats(c.ats).value, True)}

    # ---- cache ------------------------------------------------------------------------

    def _cache_key(self, url: str) -> str:
        return META_PREFIX + hashlib.sha1(url.encode()).hexdigest()[:16]

    def _cache_get(self, url: str) -> dict[str, Any] | None:
        if self._conn is None:
            return None
        v = db.get_meta(self._conn, self._cache_key(url), None)
        return v if isinstance(v, dict) else None

    def _cache_put(self, url: str, digest: str, method: str, postings: list[Posting]) -> None:
        if self._conn is None:
            return
        db.set_meta(self._conn, self._cache_key(url), {
            "url": url, "hash": digest, "method": method, "checked_at": utcnow().isoformat(),
            "postings": [p.as_dict() for p in postings[:200]],
        })

    # ---- logging ----------------------------------------------------------------------

    async def _log(self, message: str, level: str = "info") -> None:
        getattr(log, "warning" if level == "warning" else "info")("%s", message)
        if self.emit is None:
            return
        try:
            await self.emit("log", LogPayload(level=level, message=message, logger=log.name, at=utcnow()))
        except Exception:  # noqa: BLE001
            log.debug("emit failed", exc_info=True)

    # ---- one site ---------------------------------------------------------------------

    def _learn_board(self, company: str | None, ats: Ats, token: str) -> None:
        """Remember the board on a known company so the board source reads it from now on."""
        if self._conn is None or not company:
            return
        try:
            existing = db.get_company_by_name(self._conn, company)
            if existing is not None and not existing.board_token:
                db.upsert_company(self._conn, company, ats=ats, board_token=token)
        except Exception:  # noqa: BLE001
            log.debug("could not record board for %s", company, exc_info=True)

    async def _boards(self, ctx: DiscoveryContext, res: SiteResult, boards: set[tuple[Ats, str]], known: str | None,
                      covered: set[tuple[Ats, str]], fetched: set[tuple[Ats, str]]) -> list[DiscoveredJob]:
        out: list[DiscoveredJob] = []
        for ats, token in sorted(boards, key=lambda b: (b[0].value, b[1])):
            if (ats, token) in covered or (ats, token) in fetched:
                continue
            fetched.add((ats, token))
            try:
                jobs = await _BOARD_FETCHERS[ats](ctx.http, token, known)
            except Exception as e:  # noqa: BLE001
                res.error = f"{ats.value} board {token!r} failed: {e}"
                continue
            for j in jobs:
                j.source = JobSource.CAREERS
                j.raw = {**(j.raw or {}), "careers_url": res.url, "via": res.method}
                if not known and j.company_name == token:
                    j.company_name = res.company
            out.extend(jobs)
        if len(boards) == 1:
            ats, token = next(iter(boards))
            self._learn_board(known, ats, token)
        return out

    def _postings_to_jobs(self, res: SiteResult, postings: list[Posting]) -> list[DiscoveredJob]:
        host = urlsplit(res.url).hostname
        out: list[DiscoveredJob] = []
        for p in postings:
            link = p.url or res.url
            ats, token = detect_ats(link)
            out.append(DiscoveredJob(
                source=JobSource.CAREERS, company_name=res.company, title=p.title, apply_url=link if p.url else None,
                source_url=res.url, ats=ats, external_id=extract_job_id(link) if p.url else None,
                board_token=token if ats in _BOARD_FETCHERS else None, location=p.location,
                remote=infer_remote(p.location, p.title), description=p.description,
                posted_at=parse_datetime(p.posted_at), company_domain=host,
                raw={"careers_url": res.url, "via": res.method},
            ))
        return out

    async def _llm_extract(self, url: str, html: str, res: SiteResult) -> list[Posting]:
        text = page_text(html)[:LLM_TEXT_CHARS]
        links = page_links(html, url)
        allowed = {u for u, _ in links}
        prompt = EXTRACT_PROMPT.format(url=url, text=text, links="\n".join(f"{t} -> {u}" for u, t in links) or "(none)")
        before = self.llm.usage.snapshot() if hasattr(self.llm, "usage") else None
        result = await self.llm.complete(
            prompt, schema=EXTRACT_SCHEMA, tier="fast", max_tokens=2000,
            system="You read career pages and list the job postings on them. Never invent postings.",
        )
        if before is not None:
            res.tokens = self.llm.usage.since(before).total_tokens
        out: list[Posting] = []
        for j in (result.data or {}).get("jobs", []):
            title = " ".join(str(j.get("title") or "").split())
            if not (3 <= len(title) <= 160):
                continue
            link = j.get("url")
            if link:
                link = urljoin(url, link)
                same_site = (urlsplit(link).hostname or "").endswith((urlsplit(url).hostname or "").removeprefix("www."))
                if link not in allowed and not same_site and detect_ats(link)[0] is Ats.OTHER:
                    link = None  # not a link on the page: don't trust a made-up URL
            out.append(Posting(title=title, url=link, location=j.get("location") or None))
        return out

    async def read_site(self, ctx: DiscoveryContext, url: str, known: str | None,
                        covered: set[tuple[Ats, str]], fetched: set[tuple[Ats, str]]) -> SiteResult:
        res = SiteResult(url=url, company=known or company_name_from_url(url))
        # 1. The URL is itself a readable board.
        ats, token = detect_ats(url)
        if ats in _BOARD_FETCHERS and token:
            res.method = "ats"
            res.jobs = await self._boards(ctx, res, {(ats, token)}, known, covered, fetched)
            return res
        # 2. Plain HTTP.
        resp = await ctx.http.get(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html"}, follow_redirects=True)
        resp.raise_for_status()
        final = str(resp.url)
        ats, token = detect_ats(final)
        if ats in _BOARD_FETCHERS and token:
            res.method = "ats"
            res.jobs = await self._boards(ctx, res, {(ats, token)}, known, covered, fetched)
            return res
        html = resp.text
        boards, others = find_ats_boards(html, final)
        if boards:
            res.method = "embedded-ats"
            res.jobs = await self._boards(ctx, res, boards, known, covered, fetched)
            if others:
                res.jobs += self._postings_to_jobs(res, [Posting(title=t, url=u) for u, t in others])
            return res
        digest = content_hash(html)
        cached = self._cache_get(url)
        if cached and cached.get("hash") == digest and cached.get("method") not in (None, "rendered"):
            res.method = f"cached:{cached['method']}"
            res.jobs = self._postings_to_jobs(res, [Posting(**p) for p in cached.get("postings") or []])
            return res
        postings: list[Posting] = parse_jsonld_postings(html, final)
        method = "json-ld"
        if not postings:
            postings = [Posting(title=t, url=u) for u, t in others] + link_postings(html, final)
            method = "links"
        text_len = len(page_text(html)) if not postings else 0
        if not postings and text_len < MIN_TEXT_FOR_LLM:
            rendered = await self._render(final, res)
            if rendered:
                postings, method = [Posting(title=t, url=u, description=c if c != t else None) for u, t, c in rendered], "rendered"
        if not postings and text_len >= MIN_TEXT_FOR_LLM and self.llm is not None:
            try:
                postings = await self._llm_extract(final, html, res)
                method = "llm"
            except Exception as e:  # noqa: BLE001
                res.error = f"could not extract postings with the LLM: {e}"
        res.method = method if postings else "none"
        if postings or method == "llm":
            self._cache_put(url, digest, method, postings)
        res.jobs = self._postings_to_jobs(res, postings)
        if not postings and not res.error:
            res.error = "no job postings found on the page (it may need a search/filter or login)"
        return res

    async def _render(self, url: str, res: SiteResult) -> list[tuple[str, str, str]]:
        renderer = self.renderer
        if renderer is None:
            from autoapply.discovery.careers import render_postings

            renderer = render_postings
        try:
            return await renderer(url)
        except Exception as e:  # noqa: BLE001
            res.error = f"could not render the page: {e}"
            return []

    # ---- discover ---------------------------------------------------------------------

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        targets = self.targets(ctx)
        if not targets:
            return []
        covered = self._covered(ctx)
        fetched: set[tuple[Ats, str]] = set()
        sem = asyncio.Semaphore(max(1, self.concurrency))

        async def agent(url: str, known: str | None) -> SiteResult:
            async with sem:
                try:
                    res = await self.read_site(ctx, url, known, covered, fetched)
                except (httpx.HTTPError, ValueError) as e:
                    res = SiteResult(url=url, company=known or company_name_from_url(url), error=str(e) or type(e).__name__)
                except Exception as e:  # noqa: BLE001 - one bad site never stops the others
                    log.warning("career page %s failed", url, exc_info=True)
                    res = SiteResult(url=url, company=known or company_name_from_url(url), error=str(e) or type(e).__name__)
            found = len(res.jobs)
            res.jobs = filter_jobs(ctx, res.jobs)
            res.kept = len(res.jobs)
            if res.error and not found:
                ctx.errors[res.company] = res.error
            tokens = f", {res.tokens} tokens" if res.tokens else ""
            problem = f" ({res.error})" if res.error and not found else ""
            await self._log(f"Career page · {res.company}: {found} posting(s), {res.kept} match your roles "
                            f"[{res.method}{tokens}]{problem}", "warning" if problem else "info")
            return res

        self.results = list(await asyncio.gather(*(agent(u, n) for u, n in targets)))
        return [j for r in self.results for j in r.jobs]


__all__ = [
    "CareerPageAgent",
    "EXTRACT_SCHEMA",
    "Posting",
    "SiteResult",
    "content_hash",
    "link_postings",
    "parse_jsonld_postings",
]
