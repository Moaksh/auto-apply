"""Prospecting (plan §A.2, §A.3): companies to contact without an application.

Company search: the model turns the user's query ("Series B fintech in Bangalore") into 3-4
Google queries, read in the agent Chrome within the ``prospect_finder`` daily budget. Each
result page is fetched over HTTP; the model extracts ``{company, url, evidence_quote}`` and a
company is dropped unless its name appears in the page text. Each company is enriched (domain,
homepage description, ATS board and matching roles) and scored for fit (0-100 with reasons),
then stored as a ``suggested`` prospect. Dismissed companies are never suggested again.

Also seeded without searching: watched companies with no matching open role.

Guardrails (:func:`blocked_reason`): at most 2 people per company at once, one active
(sent) prospect thread per company, a 60-day cooldown after a thread closes unanswered, never
an excluded company, and a company with an application gets an application follow-up instead.
"""

from __future__ import annotations

import logging
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any
from urllib.parse import urlsplit

import httpx

from autoapply import db
from autoapply.config import Preferences
from autoapply.enums import ProspectStatus
from autoapply.llm.provider import LLMProvider, TokenUsage
from autoapply.models import Profile, Prospect, format_ts, new_id, now_ts, utcnow
from autoapply.outreach.domains import USER_AGENT, domain_from_url, is_aggregator
from autoapply.outreach.sources.extract import appears_in, norm_text
from autoapply.outreach.sources.site_pages import homepage_summary

log = logging.getLogger("autoapply.outreach.prospects")

COOLDOWN_DAYS = 60
MAX_PEOPLE_PER_COMPANY = 2
MAX_RESULT_PAGES_PER_QUERY = 3
MAX_COMPANIES_PER_SEARCH = 15
META_SEARCHES = "outreach_prospect_searches"

QUERIES_SCHEMA = {"type": "object", "properties": {"queries": {"type": "array", "items": {"type": "string"}, "maxItems": 4}},
                  "required": ["queries"]}
COMPANIES_SCHEMA = {
    "type": "object",
    "properties": {"companies": {"type": "array", "items": {
        "type": "object",
        "properties": {"company": {"type": "string"}, "url": {"type": ["string", "null"]}, "evidence_quote": {"type": ["string", "null"]}},
        "required": ["company"]}}},
    "required": ["companies"],
}
FIT_SCHEMA = {
    "type": "object",
    "properties": {"score": {"type": "integer", "minimum": 0, "maximum": 100}, "summary": {"type": "string"},
                   "factors": {"type": "object", "additionalProperties": {"type": "integer"}}},
    "required": ["score", "summary"],
}


# ---- search queue (meta) ------------------------------------------------------------------


def queue_search(conn: sqlite3.Connection, query: str, location: str | None) -> str:
    sid = new_id()
    items = list(db.get_meta(conn, META_SEARCHES, []) or [])
    items.append({"id": sid, "query": query.strip(), "location": (location or "").strip() or None, "status": "queued",
                  "created_at": now_ts(), "found": 0})
    db.set_meta(conn, META_SEARCHES, items[-30:])
    return sid


def queue_startup_search(conn: sqlite3.Connection, place: dict[str, str | None], label: str, *, yc_only: bool, hiring_only: bool,
                         stages: list[str], limit: int) -> str:
    """A "startups near you" search: YC's directory now (HTTP), funding news on Google later."""
    sid = new_id()
    items = list(db.get_meta(conn, META_SEARCHES, []) or [])
    items.append({"id": sid, "kind": "startups", "query": f"Startups in {label}", "location": label, "place": place,
                  "yc_only": yc_only, "hiring_only": hiring_only, "stages": stages, "limit": limit,
                  "status": "running", "created_at": now_ts(), "found": 0})
    db.set_meta(conn, META_SEARCHES, items[-30:])
    return sid


def get_search(conn: sqlite3.Connection, sid: str) -> dict[str, Any] | None:
    return next((s for s in (db.get_meta(conn, META_SEARCHES, []) or []) if s.get("id") == sid), None)


def update_search(conn: sqlite3.Connection, sid: str, **fields: Any) -> None:
    items = list(db.get_meta(conn, META_SEARCHES, []) or [])
    for s in items:
        if s.get("id") == sid:
            s.update(fields)
    db.set_meta(conn, META_SEARCHES, items)


def pending_searches(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    return [s for s in (db.get_meta(conn, META_SEARCHES, []) or []) if s.get("status") == "queued"]


def finish_search(conn: sqlite3.Connection, sid: str, status: str, found: int) -> None:
    items = list(db.get_meta(conn, META_SEARCHES, []) or [])
    for s in items:
        if s.get("id") == sid:
            s.update(status=status, found=int(s.get("found") or 0) + found if s.get("kind") == "startups" else found,
                     finished_at=now_ts())
    db.set_meta(conn, META_SEARCHES, items)


# ---- model tasks ---------------------------------------------------------------------------


def fallback_queries(query: str, location: str | None) -> list[str]:
    loc = f" {location}" if location else ""
    return [f'"{query}"{loc} startups', f"{query} companies{loc} 2026", f"site:ycombinator.com/companies {query}{loc}"]


async def prospect_queries(llm: LLMProvider | None, query: str, location: str | None, prefs: Preferences,
                           usage: TokenUsage | None = None) -> list[str]:
    if llm is None:
        return fallback_queries(query, location)
    prompt = (f"Turn this company search into 3-4 Google queries that find LISTS or DIRECTORIES of such companies "
              f"(articles, ycombinator.com/companies, funding news). Search: {query!r}"
              + (f" Location: {location!r}." if location else "") + f" The user looks for roles: {', '.join(prefs.roles) or 'any'}.")
    try:
        res = await llm.complete(prompt, schema=QUERIES_SCHEMA, tier="fast", max_tokens=300)
    except Exception as e:  # noqa: BLE001
        log.info("prospect_queries failed: %s", e)
        return fallback_queries(query, location)
    if usage is not None:
        usage.add(res.usage)
    qs = [q.strip() for q in (res.data or {}).get("queries") or [] if isinstance(q, str) and q.strip()]
    return qs[:4] or fallback_queries(query, location)


@dataclass(slots=True)
class FoundCompany:
    name: str
    url: str | None
    evidence: str | None
    source_url: str


def verify_companies(raw: list[dict], text: str, source_url: str) -> list[FoundCompany]:
    """Keep companies whose name is in the page text; an evidence quote not on the page is cleared."""
    tn = norm_text(text)
    out: list[FoundCompany] = []
    for c in raw:
        name = re.sub(r"\s+", " ", str(c.get("company") or "")).strip()
        if not name or len(name) > 60 or not appears_in(name, tn):
            if name:
                log.info("dropped extracted company not on the page: %r", name)
            continue
        quote = str(c.get("evidence_quote") or "").strip() or None
        if quote and not appears_in(quote, tn):
            quote = None
        url = str(c.get("url") or "").strip() or None
        if url and (not url.startswith("http") or is_aggregator(urlsplit(url).hostname)):
            url = None
        if not any(f.name.lower() == name.lower() for f in out):
            out.append(FoundCompany(name, url, quote, source_url))
    return out


async def extract_companies(llm: LLMProvider, text: str, source_url: str, usage: TokenUsage | None = None) -> list[FoundCompany]:
    prompt = ("List the companies this page describes (not publishers, investors or job boards), each with its website "
              "if the page gives it and a short quote from the page about it. Copy names exactly.\n\nPAGE TEXT:\n" + text[:8000])
    try:
        res = await llm.complete(prompt, schema=COMPANIES_SCHEMA, tier="fast", max_tokens=1500)
    except Exception as e:  # noqa: BLE001
        log.info("extract_companies failed: %s", e)
        return []
    if usage is not None:
        usage.add(res.usage)
    return verify_companies(list((res.data or {}).get("companies") or []), text, source_url)


async def prospect_fit(llm: LLMProvider | None, *, company: str, summary: str | None, matching_roles: int | None,
                       profile: Profile, prefs: Preferences, usage: TokenUsage | None = None) -> tuple[int | None, dict[str, Any]]:
    if llm is None:
        return None, {}
    facts = "; ".join(filter(None, [profile.headline, profile.summary, ", ".join(profile.skills[:15])]))
    prompt = (f"Rate 0-100 how good a target {company} is for this job seeker to contact (not apply).\n"
              f"COMPANY: {company}. What they do: {summary or 'unknown'}. Open roles matching the user: {matching_roles if matching_roles is not None else 'unknown'}.\n"
              f"SEEKER: {facts}. Wants roles: {', '.join(prefs.roles) or 'any'}; locations: {', '.join(prefs.locations) or 'any'}.\n"
              "Give a one-sentence summary of why, and factor scores (domain, stack, stage) 0-100.")
    try:
        res = await llm.complete(prompt, schema=FIT_SCHEMA, tier="fast", max_tokens=300)
    except Exception as e:  # noqa: BLE001
        log.info("prospect_fit failed: %s", e)
        return None, {}
    if usage is not None:
        usage.add(res.usage)
    d = res.data or {}
    return int(d.get("score", 0)), {"summary": d.get("summary"), "factors": d.get("factors") or {}}


# ---- enrichment ------------------------------------------------------------------------------


@dataclass(slots=True)
class Enrichment:
    domain: str | None = None
    summary: str | None = None
    summary_url: str | None = None
    ats: str | None = None
    board_token: str | None = None
    matching_roles: int | None = None
    open_roles: int | None = None
    extra: dict[str, Any] = field(default_factory=dict)


def _matches_roles(title: str, roles: list[str]) -> bool:
    t = title.lower()
    for r in roles:
        words = [w for w in re.split(r"\W+", r.lower()) if len(w) > 2]
        if words and all(w in t for w in words):
            return True
    return False


async def enrich(http: httpx.AsyncClient, *, url: str | None, prefs: Preferences) -> Enrichment:
    """Domain, homepage description, ATS board and matching-role count (HTTP only)."""
    from autoapply.discovery.careers import _BOARD_FETCHERS, find_ats_boards

    out = Enrichment(domain=domain_from_url(url))
    if out.domain is None:
        return out
    home = f"https://{out.domain}/"
    try:
        r = await http.get(home, headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=15)
    except httpx.HTTPError as e:
        log.info("prospect homepage %s: %s", home, e)
        return out
    if r.status_code >= 400:
        return out
    out.summary, out.summary_url = homepage_summary(r.text), str(r.url)
    try:
        boards, _links = find_ats_boards(r.text, str(r.url))
    except Exception:  # noqa: BLE001
        boards = set()
    for ats, token in sorted(boards, key=lambda b: (b[0].value, b[1])):
        if ats in _BOARD_FETCHERS and token:
            try:
                jobs = await _BOARD_FETCHERS[ats](http, token, None)
            except Exception as e:  # noqa: BLE001
                log.info("prospect board %s:%s: %s", ats.value, token, e)
                continue
            out.ats, out.board_token = ats.value, token
            out.open_roles = len(jobs)
            out.matching_roles = sum(1 for j in jobs if _matches_roles(j.title, prefs.roles)) if prefs.roles else None
            break
    return out


# ---- rows ------------------------------------------------------------------------------------


def get(conn: sqlite3.Connection, prospect_id: int) -> Prospect:
    row = conn.execute("SELECT * FROM prospects WHERE id = ?", (prospect_id,)).fetchone()
    if row is None:
        raise db.NotFound(f"prospect {prospect_id} not found")
    return Prospect.from_row(row)  # type: ignore[return-value]


def get_by_company(conn: sqlite3.Connection, company_id: int) -> Prospect | None:
    row = conn.execute("SELECT * FROM prospects WHERE company_id = ?", (company_id,)).fetchone()
    return Prospect.from_row(row) if row else None  # type: ignore[return-value]


def excluded(prefs: Preferences, name: str) -> bool:
    n = db.normalize_text(name)
    return any(db.normalize_text(x) == n for x in prefs.exclude_companies)


def upsert(conn: sqlite3.Connection, company_id: int, *, status: ProspectStatus | None = None, fit_score: int | None = None,
           fit_reasons: dict | None = None, summary: str | None = None, summary_url: str | None = None,
           matching_roles: int | None = None, found_via: str | None = None, search_query: str | None = None) -> Prospect | None:
    """Insert or refresh a prospect. None when the user dismissed this company."""
    ts = now_ts()
    with db.transaction(conn):
        cur = get_by_company(conn, company_id)
        if cur is None:
            c = conn.execute(
                "INSERT INTO prospects(company_id, status, fit_score, fit_reasons, summary, summary_url, matching_roles, found_via, "
                "search_query, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (company_id, (status or ProspectStatus.SUGGESTED).value, fit_score, db._j(fit_reasons or {}), summary, summary_url,
                 matching_roles, found_via, search_query, ts, ts))
            return rescore(conn, company_id) or get(conn, int(c.lastrowid))
        if cur.status is ProspectStatus.DISMISSED and status is not ProspectStatus.SHORTLISTED:
            return None
        fields: dict[str, Any] = {"updated_at": ts}
        for k, v in (("fit_score", fit_score), ("summary", summary), ("summary_url", summary_url),
                     ("matching_roles", matching_roles), ("found_via", found_via), ("search_query", search_query)):
            if v is not None:
                fields[k] = v
        if fit_reasons:
            fields["fit_reasons"] = db._j(fit_reasons)
        if status is not None:
            fields["status"] = status.value
        sql, params = db._update_sql("prospects", fields, "id = ?")
        conn.execute(sql, [*params, cur.id])
    return rescore(conn, company_id) or get(conn, cur.id)


def rescore(conn: sqlite3.Connection, company_id: int, *, today: date | None = None) -> Prospect | None:
    """Recompute the prospect's startup score and rank from ``company_facts`` and its fit
    (``outreach/startup_score.py``). None when the company has no prospect row."""
    from autoapply.outreach import facts, startup_score

    p = get_by_company(conn, company_id)
    if p is None:
        return None
    f = facts.get(conn, company_id)
    s = startup_score.score_startup(f, matching_roles=p.matching_roles, today=today or utcnow().date())
    rank = startup_score.rank(s, p.fit_score)
    with db.transaction(conn):
        conn.execute("UPDATE prospects SET startup_score = ?, startup_confidence = ?, startup_reasons = ?, rank_score = ? "
                     "WHERE id = ?", (s.score if s.confidence else None, s.confidence, db._j(s.reasons() if s.confidence else []),
                                      rank, p.id))
    return get(conn, p.id)


def ranked(conn: sqlite3.Connection, *, limit: int | None = None) -> list[Prospect]:
    """Prospects still open (suggested / shortlisted), best rank first."""
    rows = conn.execute(
        "SELECT * FROM prospects WHERE status IN ('suggested','shortlisted') "
        "ORDER BY rank_score IS NULL, rank_score DESC, fit_score IS NULL, fit_score DESC, id" + (f" LIMIT {int(limit)}" if limit else ""))
    return [Prospect.from_row(r) for r in rows]  # type: ignore[misc]


def set_status(conn: sqlite3.Connection, prospect_id: int, status: ProspectStatus) -> Prospect:
    with db.transaction(conn):
        p = get(conn, prospect_id)
        conn.execute("UPDATE prospects SET status = ?, updated_at = ? WHERE id = ?", (status.value, now_ts(), prospect_id))
        db.log_event(conn, "outreach", f"prospect {db.get_company(conn, p.company_id).name}: {p.status.value} → {status.value}",
                     actor="user", payload={"prospect_id": prospect_id})
    return get(conn, prospect_id)


def start_cooldown(conn: sqlite3.Connection, company_id: int, now: datetime | None = None) -> None:
    until = format_ts((now or utcnow()) + timedelta(days=COOLDOWN_DAYS))
    with db.transaction(conn):
        if get_by_company(conn, company_id) is None:
            upsert(conn, company_id, found_via="thread")
        conn.execute("UPDATE prospects SET cooldown_until = ?, updated_at = ? WHERE company_id = ?", (until, now_ts(), company_id))


def has_application(conn: sqlite3.Connection, company_id: int) -> int | None:
    """Id of an application the user has at the company (submitted), else None."""
    row = conn.execute(
        "SELECT a.id FROM applications a JOIN jobs j ON j.id = a.job_id WHERE j.company_id = ? AND a.state = 'submitted' "
        "ORDER BY a.submitted_at DESC LIMIT 1", (company_id,)).fetchone()
    return int(row[0]) if row else None


def blocked_reason(conn: sqlite3.Connection, company_id: int, prefs: Preferences, *, contact_id: int | None = None,
                   now: datetime | None = None) -> str | None:
    """Why a new prospect thread can't be drafted for this company, else None."""
    company = db.get_company(conn, company_id)
    if excluded(prefs, company.name):
        return f"{company.name} is on your excluded companies"
    if has_application(conn, company_id) is not None:
        return f"you applied to {company.name}: use an application follow-up instead"
    p = get_by_company(conn, company_id)
    if p is not None and p.cooldown_until and p.cooldown_until > (now or utcnow()):
        return f"{company.name} is cooling down until {p.cooldown_until.date().isoformat()} (no reply last time)"
    rows = conn.execute("SELECT contact_id, state FROM outreach_threads WHERE company_id = ? AND kind = 'prospect' "
                        "AND state IN ('draft','active')", (company_id,)).fetchall()
    others = [r for r in rows if r["contact_id"] != contact_id]
    if len(others) >= MAX_PEOPLE_PER_COMPANY:
        return f"already reaching {MAX_PEOPLE_PER_COMPANY} people at {company.name}"
    if any(r["state"] == "active" for r in others):
        return f"a prospect email to {company.name} is already out; wait for it"
    return None


def seed_from_watchlist(conn: sqlite3.Connection, now: datetime | None = None) -> int:
    """Watched companies with no job worth applying to in the last 30 days become prospects."""
    since = format_ts((now or utcnow()) - timedelta(days=30))
    rows = conn.execute(
        "SELECT c.id FROM companies c WHERE c.watch = 1 AND c.id NOT IN (SELECT company_id FROM prospects) "
        "AND NOT EXISTS (SELECT 1 FROM jobs j JOIN applications a ON a.job_id = j.id WHERE j.company_id = c.id "
        "AND j.discovered_at >= ? AND a.state NOT IN ('skipped','discovered'))", (since,)).fetchall()
    n = 0
    for r in rows:
        if upsert(conn, int(r["id"]), found_via="watchlist") is not None:
            n += 1
    return n


__all__ = [
    "COOLDOWN_DAYS", "Enrichment", "FoundCompany", "blocked_reason", "enrich", "extract_companies", "fallback_queries",
    "finish_search", "get", "get_by_company", "get_search", "queue_startup_search", "update_search", "has_application", "pending_searches", "prospect_fit", "prospect_queries",
    "queue_search", "ranked", "rescore", "seed_from_watchlist", "set_status", "start_cooldown", "upsert", "verify_companies",
]
