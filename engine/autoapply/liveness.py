"""Posting liveness: is a queued job's posting still open?

Checked cheaply before prep (question harvesting) and before applying, so agent runs and
tokens are not spent on closed postings. Zero LLM tokens and never a browser:

1. **ATS API** (authoritative where the provider allows it):

   * Greenhouse: ``GET boards-api.greenhouse.io/v1/boards/{token}/jobs/{id}``; 200 = open, 404 = closed.
   * Lever: ``GET api.lever.co/v0/postings/{slug}/{id}``; 200 = open. A 404 is NOT trusted (the
     Lever API is known to 404 some live postings), so it falls through to the page check.
   * Ashby: ``GET api.ashbyhq.com/posting-api/job-board/{org}`` (board level); the job listed = open,
     a readable board without it (or ``isListed: false``) = closed.

2. **Page**: a plain HTTP GET of ``apply_url`` (follow redirects, short timeout), read for closed
   signals: 404/410, a Greenhouse-style ``?error=true`` redirect, a redirect that drops the job id
   and lands on a generic careers/jobs page, or a closure sentence ("no longer accepting
   applications", "this job has expired", "position has been filled", "job not found", ...).

Conservative by design: anything unclear is ``unknown`` and counts as **open**; a job is only
ever skipped on a definitive closed signal. LinkedIn / Glassdoor are never fetched
(``apply.agentic.BLOCKED_HOSTS``).

Results are cached on the job (``jobs.raw["liveness"]``, with ``checked_at``) and re-checked at
most every :data:`RECHECK_AFTER`.

The closure phrase list, the conditional-clause guard ("... until the position has been filled"
is a live posting) and the "Lever API 404 is not authoritative" / Ashby board-level rules are
adapted from career-ops (``liveness-core.mjs`` / ``liveness-api.mjs``), MIT License,
Copyright (c) 2026 Santiago Fernandez de Valderrama. See THIRD_PARTY_NOTICES.md.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import sqlite3
import unicodedata
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx

from autoapply import db
from autoapply.enums import Ats
from autoapply.models import Job, format_ts, parse_ts, utcnow

log = logging.getLogger("autoapply.liveness")

OPEN = "open"
CLOSED = "closed"
UNKNOWN = "unknown"

#: Skip reason for a queued job whose posting has closed.
SKIP_POSTING_CLOSED = "posting_closed"
#: Key in ``jobs.raw`` holding the last result.
RAW_KEY = "liveness"
#: A job is re-checked at most this often.
RECHECK_AFTER = timedelta(hours=12)
#: How many checks run at once.
CONCURRENCY = 4
TIMEOUT_S = 10.0
#: Page bytes read at most (the closure banner is near the top).
MAX_BYTES = 1_000_000

#: Off switch (``AUTOAPPLY_LIVENESS=0``); the test suite turns it off by default (no network).
ENABLED = os.environ.get("AUTOAPPLY_LIVENESS", "1").strip().lower() not in ("0", "false", "no", "off")

USER_AGENT = "AutoApply/0.1 (personal job search assistant; read-only)"

GREENHOUSE_API = "https://boards-api.greenhouse.io/v1/boards"
LEVER_API = "https://api.lever.co/v0/postings"
LEVER_API_EU = "https://api.eu.lever.co/v0/postings"
ASHBY_API = "https://api.ashbyhq.com/posting-api/job-board"


@dataclass(slots=True)
class Liveness:
    status: str  # open | closed | unknown
    reason: str = ""
    method: str = ""  # api | page | none
    checked_at: str = ""

    @property
    def closed(self) -> bool:
        return self.status == CLOSED

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def make_client() -> httpx.AsyncClient:
    """The HTTP client used when the caller passes none (tests monkeypatch this)."""
    return httpx.AsyncClient(
        timeout=TIMEOUT_S, follow_redirects=True,
        headers={"User-Agent": USER_AGENT, "Accept-Language": "en"},
    )


# =====================================================================================
# Hosts
# =====================================================================================


def _blocked_hosts() -> tuple[str, ...]:
    try:
        from autoapply.apply.agentic import BLOCKED_HOSTS

        return tuple(BLOCKED_HOSTS)
    except Exception:  # noqa: BLE001 - keep the guard even if that module fails to import
        return ("linkedin.com", "glassdoor.com", "glassdoor.co.uk", "glassdoor.co.in", "glassdoor.ca")


def is_blocked(url: str | None) -> bool:
    host = (urlsplit(url or "").hostname or "").lower()
    return any(host == h or host.endswith("." + h) for h in _blocked_hosts())


# =====================================================================================
# ATS API rung
# =====================================================================================


def _ats_target(job: Job) -> tuple[str, dict[str, str]] | None:
    """(provider, parts) for a Greenhouse / Lever / Ashby posting, from the stored ids or the URL."""
    raw = job.raw if isinstance(job.raw, dict) else {}
    token = str(raw.get("board_token") or "").strip()
    ext = str(job.external_id or raw.get("posting_id") or "").strip()
    for url in (job.apply_url, job.source_url):
        if not url:
            continue
        parts = urlsplit(url)
        host = (parts.hostname or "").lower()
        path = [p for p in parts.path.split("/") if p]
        if host.endswith("greenhouse.io"):
            q = parse_qs(parts.query)
            if path[:2] == ["embed", "job_app"] and q.get("for") and q.get("token"):
                return "greenhouse", {"token": q["for"][0], "id": q["token"][0]}
            if len(path) >= 3 and path[1] == "jobs" and path[2].isdigit():
                return "greenhouse", {"token": path[0], "id": path[2]}
        if host in ("jobs.lever.co", "jobs.eu.lever.co") and len(path) >= 2:
            slug = ("eu:" if host.startswith("jobs.eu.") else "") + path[0]
            return "lever", {"token": slug, "id": path[1]}
        if host == "jobs.ashbyhq.com" and len(path) >= 2:
            return "ashby", {"token": path[0], "id": path[1]}
    if token and ext:
        ats = str(getattr(job.ats, "value", job.ats))
        if ats == Ats.GREENHOUSE.value and ext.isdigit():
            return "greenhouse", {"token": token, "id": ext}
        if ats == Ats.LEVER.value:
            return "lever", {"token": token, "id": ext}
        if ats == Ats.ASHBY.value:
            return "ashby", {"token": token, "id": ext}
    return None


async def _get_json(http: httpx.AsyncClient, url: str, params: dict[str, str] | None = None) -> tuple[int, Any]:
    resp = await http.get(url, params=params, headers={"Accept": "application/json"})
    if resp.status_code != 200:
        return resp.status_code, None
    try:
        return 200, resp.json()
    except ValueError:
        return 200, None


async def check_api(http: httpx.AsyncClient, provider: str, parts: dict[str, str]) -> Liveness | None:
    """Ask the ATS's public API. ``None`` = inconclusive (fall through to the page check)."""
    token, jid = parts["token"], parts["id"]
    if provider == "greenhouse":
        status, data = await _get_json(http, f"{GREENHOUSE_API}/{token}/jobs/{jid}")
        if status in (404, 410):
            return Liveness(CLOSED, f"Greenhouse API: job {jid} not on board {token} (HTTP {status})", "api")
        if status == 200 and isinstance(data, dict) and str(data.get("id", jid)) == jid:
            return Liveness(OPEN, "Greenhouse API lists the job", "api")
        return None
    if provider == "lever":
        base, slug = (LEVER_API_EU, token[3:]) if token.startswith("eu:") else (LEVER_API, token)
        status, data = await _get_json(http, f"{base}/{slug}/{jid}")
        if status == 200 and isinstance(data, dict) and (data.get("id") in (None, jid)):
            return Liveness(OPEN, "Lever API lists the posting", "api")
        return None  # a Lever API 404 is not authoritative: the page decides
    if provider == "ashby":
        status, data = await _get_json(http, f"{ASHBY_API}/{token}")
        jobs = data.get("jobs") if isinstance(data, dict) else None
        if status != 200 or not isinstance(jobs, list):
            return None  # board API off / unreadable: says nothing about this posting
        hit = next((j for j in jobs if isinstance(j, dict) and str(j.get("id")) == jid), None)
        if hit is not None and hit.get("isListed") is not False:
            return Liveness(OPEN, "Ashby board lists the posting", "api")
        return Liveness(CLOSED, f"Ashby board {token} no longer lists posting {jid}", "api")
    return None


# =====================================================================================
# Page rung
# =====================================================================================

_TAGS = re.compile(r"<(script|style|noscript|template)\b.*?</\1\s*>", re.I | re.S)
_TAG = re.compile(r"<[^>]+>")
_BLOCK_TAG = re.compile(r"<\s*/?\s*(p|div|br|li|h[1-6]|section|article|header|footer|tr|ul|ol|main)\b[^>]*>", re.I)


def page_text(html: str) -> str:
    """Visible-ish text, with line breaks kept at block boundaries, in a normalised alphabet
    (ASCII quotes, no diacritics, one character per whitespace run)."""
    import html as _html

    t = _TAGS.sub(" ", html or "")
    t = _BLOCK_TAG.sub("\n", t)
    t = _html.unescape(_TAG.sub(" ", t))
    t = re.sub(r"[‘’ʼ′´`]", "'", t)
    t = re.sub(r"[“”″]", '"', t)
    t = "".join(c for c in unicodedata.normalize("NFD", t) if not unicodedata.combining(c))
    return re.sub(r"\s+", lambda m: "\n" if "\n" in m.group(0) else " ", t).strip()


_JOB_NOUN = r"(?:job|jobs|position|role|posting|opening|vacancy|requisition|listing)"

#: A sentence about THIS posting being closed. Checked against the page text.
CLOSED_PATTERNS: tuple[re.Pattern[str], ...] = tuple(re.compile(p, re.I) for p in (
    r"\bno longer accepting applications\b",
    r"\bnot accepting applications\b",
    r"\bjob (?:is )?no longer available\b",
    r"\bjob\b.{0,40}?\bno longer open\b",
    r"\bthis (?:job|position|role|posting|vacancy|opening)(?: listing)? (?:is )?no longer (?:available|open|active|accepting)\b",
    rf"\b{_JOB_NOUN}\b.{{0,60}}?(?<!application )(?<!form )has been filled\b(?! out)",
    r"\b(?:position|vacancy|role|job) (?:is|has been) (?:already |now )?filled\b(?! out| in| with| by)",
    r"\bthis job has expired\b",
    r"\bjob posting has expired\b",
    r"\bthis (?:job|position|role|posting|vacancy|listing)(?: posting)? (?:has )?expired\b",
    r"\bthis (?:job|role|position|vacancy)(?: listing| posting)? (?:is|has been) closed\b(?!-)",
    r"\bjob (?:listing |posting |opening )?not found\b",
    r"\b(?:job|position|posting) you are looking for (?:is no longer|has been (?:removed|closed|filled)|no longer exists|does not exist|doesn't exist)",
    r"\bthe page you are looking for (?:doesn't|does not|no longer) exist",
    r"\bapplications? (?:(?:have|are|is) )?(?:now )?closed\b(?!-)",
    r"\b(?:job|posting|position|vacancy) (?:has been|was) (?:removed|taken down|deleted|closed)\b",
    r"\bhiring (?:for this (?:job|role|position) )?(?:has been|is) closed\b",
))

#: A time / condition word opening the clause makes a closure phrase a future condition,
#: not a closure: "applications accepted until the position has been filled".
_CONDITION = re.compile(r"\b(?:until|till|once|when|whenever|after|before|unless|if|whether|as soon as)\b", re.I)

#: Anti-bot walls: never read as closed.
BOT_PATTERNS: tuple[re.Pattern[str], ...] = tuple(re.compile(p, re.I) for p in (
    r"just a moment", r"checking your browser", r"verify you are (?:a |not a )?human",
    r"enable javascript and cookies to continue", r"attention required", r"\bcf-ray\b", r"\bray id\b",
))

#: Final-URL paths that are a generic careers / jobs index, not a posting.
_GENERIC_PATH = re.compile(
    r"^/?(?:[a-z]{2}(?:-[a-z]{2})?/)?(?:(?:about/)?(?:careers?|jobs?|join(?:-us)?|open-positions|openings|positions|"
    r"vacancies|work-with-us|search|search-jobs|job-search)/?){0,2}$",
    re.I,
)
_JOB_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d{5,}", re.I)
_APPLY = re.compile(r"\b(?:apply|submit (?:your )?application|start application)\b", re.I)


def _job_id_token(url: str) -> str | None:
    found = _JOB_ID.findall(url or "")
    return found[-1].lower() if found else None


def _stated_closure(text: str) -> str | None:
    """The first closure phrase not opened by a time / condition word in its own clause."""
    flat = text.replace("\n", " ")
    for pat in CLOSED_PATTERNS:
        for m in pat.finditer(flat):
            before = text[: m.start()]
            clause = re.split(r"[.!?;:|•·\n]", before)[-1]
            words = clause.split()[-10:]
            if _CONDITION.search(" ".join(words)):
                continue
            return m.group(0)
    return None


def classify_page(*, status: int, requested_url: str, final_url: str, html: str) -> Liveness:
    """Classify a fetched page. Pure; ``unknown`` whenever the signal is not definitive."""
    if status in (404, 410):
        return Liveness(CLOSED, f"HTTP {status}", "page")
    text = page_text(html)
    if any(p.search(text) for p in BOT_PATTERNS):
        return Liveness(UNKNOWN, "anti-bot page", "page")
    if status >= 400:
        return Liveness(UNKNOWN, f"HTTP {status}", "page")
    final = final_url or requested_url
    if re.search(r"[?&]error=true\b", final, re.I):
        return Liveness(CLOSED, f"redirected to {final}", "page")
    hit = _stated_closure(text)
    if hit:
        return Liveness(CLOSED, f'page says "{hit}"', "page")
    jid = _job_id_token(requested_url)
    if jid and final and jid not in final.lower():
        fp = urlsplit(final)
        if _GENERIC_PATH.match(fp.path or "/"):
            return Liveness(CLOSED, f"redirected to the generic page {final}", "page")
        return Liveness(UNKNOWN, f"redirected to {final}", "page")
    if _APPLY.search(text):
        return Liveness(OPEN, "page loads with an apply control", "page")
    return Liveness(UNKNOWN, "page gave no clear signal", "page")


async def check_page(http: httpx.AsyncClient, url: str) -> Liveness:
    async with http.stream("GET", url) as resp:
        buf = bytearray()
        async for chunk in resp.aiter_bytes():
            buf.extend(chunk)
            if len(buf) >= MAX_BYTES:
                break
        final = str(resp.url)
        if is_blocked(final):
            return Liveness(UNKNOWN, "redirected to a blocked host", "page")
        html = buf.decode(resp.encoding or "utf-8", errors="replace")
        return classify_page(status=resp.status_code, requested_url=url, final_url=final, html=html)


# =====================================================================================
# Entry points
# =====================================================================================


async def check(job: Job, http: httpx.AsyncClient) -> Liveness:
    """API first, page second. Never raises; any failure is ``unknown`` (= open)."""
    result: Liveness | None = None
    try:
        target = _ats_target(job)
        if target is not None:
            result = await check_api(http, *target)
        if result is None:
            url = job.apply_url
            if not url or not url.lower().startswith(("http://", "https://")):
                result = Liveness(UNKNOWN, "no apply link to check", "none")
            elif is_blocked(url):
                result = Liveness(UNKNOWN, "LinkedIn/Glassdoor are never checked", "none")
            else:
                result = await check_page(http, url)
    except (httpx.HTTPError, asyncio.TimeoutError) as e:
        result = Liveness(UNKNOWN, f"check failed: {type(e).__name__}", result.method if result else "page")
    except Exception as e:  # noqa: BLE001 - liveness must never break prep / apply
        log.warning("liveness check for job %s failed", job.id, exc_info=True)
        result = Liveness(UNKNOWN, f"check failed: {type(e).__name__}", "none")
    return result


def cached(job: Job, now: datetime | None = None) -> Liveness | None:
    """The stored result if it is younger than :data:`RECHECK_AFTER`."""
    raw = job.raw if isinstance(job.raw, dict) else {}
    c = raw.get(RAW_KEY)
    if not isinstance(c, dict) or not c.get("checked_at"):
        return None
    try:
        at = parse_ts(c["checked_at"])
    except Exception:  # noqa: BLE001
        return None
    if not isinstance(at, datetime) or (now or utcnow()) - at >= RECHECK_AFTER:
        return None
    return Liveness(str(c.get("status") or UNKNOWN), str(c.get("reason") or ""), str(c.get("method") or ""), str(c["checked_at"]))


def _store(conn: sqlite3.Connection, job_id: int, res: Liveness) -> None:
    # Re-read right before writing (no await in between): other writers may have touched raw.
    job = db.get_job(conn, job_id)
    raw = dict(job.raw) if isinstance(job.raw, dict) else {}
    raw[RAW_KEY] = res.to_dict()
    db.update_job(conn, job_id, raw=raw)


async def ensure(
    conn: sqlite3.Connection, job: Job, *, http: httpx.AsyncClient | None = None, now: datetime | None = None,
) -> Liveness:
    """Cached check of one job (at most one network check per job per :data:`RECHECK_AFTER`)."""
    if not ENABLED:
        return Liveness(UNKNOWN, "liveness checks are off", "none")
    hit = cached(job, now)
    if hit is not None:
        return hit
    own = http is None
    client = http or make_client()
    try:
        res = await check(job, client)
    finally:
        if own:
            await client.aclose()
    res.checked_at = format_ts(now or utcnow())
    try:
        _store(conn, job.id, res)
    except db.NotFound:
        pass
    if res.status == CLOSED:
        log.info("job %s posting closed: %s", job.id, res.reason)
    return res


async def ensure_many(
    conn: sqlite3.Connection, jobs: Iterable[Job], *, http: httpx.AsyncClient | None = None,
    limit: int = CONCURRENCY, now: datetime | None = None,
) -> dict[int, Liveness]:
    """Check several jobs concurrently (at most ``limit`` at once). ``{job_id: result}``."""
    jobs = list(jobs)
    if not ENABLED or not jobs:
        return {j.id: Liveness(UNKNOWN, "liveness checks are off", "none") for j in jobs}
    own = http is None
    client = http or make_client()
    sem = asyncio.Semaphore(max(1, limit))

    async def one(job: Job) -> tuple[int, Liveness]:
        async with sem:
            return job.id, await ensure(conn, job, http=client, now=now)

    try:
        return dict(await asyncio.gather(*(one(j) for j in jobs)))
    finally:
        if own:
            await client.aclose()


def closed_message(title: str, company: str, res: Liveness, *, user_queued: bool) -> str:
    who = f"{title} · {company}"
    if user_queued:
        return f"Skipped {who}, which you queued yourself: the posting has closed ({res.reason}), so it can't be applied to"
    return f"Skipped {who}: the posting has closed ({res.reason})"
