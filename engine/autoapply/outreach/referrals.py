"""The LinkedIn referral copilot (plan §F.1). AutoApply NEVER opens LinkedIn.

* Finding referrers: Google result pages only (people-finder budget), with queries built from
  the user's own profile: alumni (``"{company}" "{school}"``), ex-colleagues
  (``"{company}" "{previous employer}"``), and the same function in the same city. A basis is
  kept only when the result's title / snippet contains the school or employer text, which is
  stored as evidence. The profile URL is a reference for the user's own browser.
* States: ``suggested → to_connect → requested → connected → asked → referred | declined |
  no_response`` plus ``dismissed`` (``models.REFERRAL_TRANSITIONS``). The user moves them; the
  mail watcher moves ``requested → connected`` from LinkedIn's "accepted your invitation" email.
* Drafts: a connection note (<= 300 characters) and a referral message (<= 120 words), both
  fact-checked like emails.
* Reminders: ``connected`` for over 2 days without ``asked`` -> "Ask {name} for a referral";
  ``requested`` for over 14 days -> ``no_response``.
"""

from __future__ import annotations

import logging
import re
import sqlite3
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta

from autoapply import db
from autoapply.enums import ReferralBasis, ReferralState
from autoapply.models import Profile, Referral, format_ts, is_allowed_referral_transition, now_ts, utcnow
from autoapply.outreach.sources.google_people import SerpHit, is_linkedin_profile, parse_linkedin_title

log = logging.getLogger("autoapply.outreach.referrals")

ASK_AFTER_DAYS = 2
NO_RESPONSE_AFTER_DAYS = 14
MAX_QUERIES = 4
#: With ``local`` the city query comes first and one more query is allowed.
MAX_LOCAL_QUERIES = 5
#: Suggested connection requests per day (advice shown in the UI, not enforced automation).
SUGGESTED_DAILY_REQUESTS = 5

_SENIOR_EXEC = re.compile(r"\b(ceo|cto|cfo|coo|chief|founder|president|vp|vice president)\b", re.I)


class IllegalReferralTransition(db.DBError):
    code = "illegal_transition"


def get(conn: sqlite3.Connection, referral_id: int) -> Referral:
    row = conn.execute("SELECT * FROM referrals WHERE id = ?", (referral_id,)).fetchone()
    if row is None:
        raise db.NotFound(f"referral {referral_id} not found")
    return Referral.from_row(row)  # type: ignore[return-value]


def list_for_company(conn: sqlite3.Connection, company_id: int) -> list[Referral]:
    return [Referral.from_row(r) for r in conn.execute("SELECT * FROM referrals WHERE company_id = ? ORDER BY id", (company_id,))]  # type: ignore[misc]


def transition(conn: sqlite3.Connection, referral_id: int, to: ReferralState, *, reason: str | None = None,
               actor: str = "system") -> Referral:
    with db.transaction(conn):
        r = get(conn, referral_id)
        if r.state is to:
            return r
        if not is_allowed_referral_transition(r.state, to):
            raise IllegalReferralTransition(f"referral {referral_id}: {r.state.value} -> {to.value} is not allowed")
        ts = now_ts()
        conn.execute("UPDATE referrals SET state = ?, state_updated_at = ? WHERE id = ?", (to.value, ts, referral_id))
        db.log_event(conn, "outreach", f"referral {r.person_name}: {r.state.value} → {to.value}" + (f" ({reason})" if reason else ""),
                     actor=actor, job_id=r.job_id, payload={"referral_id": referral_id, "from": r.state.value, "to": to.value})
    return get(conn, referral_id)


def update_texts(conn: sqlite3.Connection, referral_id: int, *, connect_note: str | None = None, referral_dm: str | None = None,
                 grounded: bool | None = None, unsupported: list[str] | None = None) -> Referral:
    fields: dict = {}
    if connect_note is not None:
        fields["connect_note"] = connect_note
    if referral_dm is not None:
        fields["referral_dm"] = referral_dm
    if grounded is not None:
        fields["grounded"] = int(grounded)
    if unsupported is not None:
        fields["unsupported_claims"] = db._j(unsupported)
    if fields:
        with db.transaction(conn):
            get(conn, referral_id)
            sql, params = db._update_sql("referrals", fields, "id = ?")
            conn.execute(sql, [*params, referral_id])
    return get(conn, referral_id)


def _name_key(name: str) -> str:
    return db.normalize_text(name)


def match_by_name(conn: sqlite3.Connection, name: str, *, states: Iterable[ReferralState]) -> list[Referral]:
    """Referrals in ``states`` whose person is ``name`` (case / accents / punctuation ignored)."""
    key = _name_key(name)
    vals = [s.value for s in states]
    rows = conn.execute(f"SELECT * FROM referrals WHERE state IN ({','.join('?' * len(vals))})", vals).fetchall()
    return [Referral.from_row(r) for r in rows if _name_key(r["person_name"]) == key]  # type: ignore[misc]


def add(
    conn: sqlite3.Connection, *, company_id: int, person_name: str, basis: ReferralBasis, job_id: int | None = None,
    contact_id: int | None = None, title: str | None = None, linkedin_url: str | None = None, basis_detail: str | None = None,
    evidence_url: str | None = None, evidence_snippet: str | None = None, state: ReferralState = ReferralState.SUGGESTED,
) -> tuple[Referral, bool]:
    """Insert a referral (dedupe by company + LinkedIn URL, else company + name). (row, created)."""
    name = re.sub(r"\s+", " ", person_name or "").strip()
    if not name:
        raise ValueError("person name is empty")
    with db.transaction(conn):
        row = None
        if linkedin_url:
            row = conn.execute("SELECT * FROM referrals WHERE company_id = ? AND linkedin_url = ?", (company_id, linkedin_url)).fetchone()
        if row is None:
            for r in conn.execute("SELECT * FROM referrals WHERE company_id = ?", (company_id,)):
                if _name_key(r["person_name"]) == _name_key(name):
                    row = r
                    break
        if row is not None:
            if contact_id and not row["contact_id"]:
                conn.execute("UPDATE referrals SET contact_id = ? WHERE id = ?", (contact_id, row["id"]))
            return get(conn, int(row["id"])), False
        ts = now_ts()
        cur = conn.execute(
            "INSERT INTO referrals(company_id, job_id, contact_id, person_name, title, linkedin_url, basis, basis_detail, "
            "evidence_url, evidence_snippet, state, state_updated_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (company_id, job_id, contact_id, name, title, linkedin_url, basis.value, basis_detail, evidence_url,
             (evidence_snippet or "")[:280] or None, state.value, ts, ts),
        )
    return get(conn, int(cur.lastrowid)), True


# ---- finding referrers (Google results only) -------------------------------------------------


@dataclass(slots=True, frozen=True)
class ReferrerQuery:
    query: str
    basis: ReferralBasis
    detail: str  # the school / employer / function text that must appear in the result


def referrer_queries(profile: Profile, company: str, *, function: str | None = None, city: str | None = None,
                     local: bool = False) -> list[ReferrerQuery]:
    """Queries from the user's own profile, most promising first (employer, school, function).
    ``local``: also people at the company in ``city`` (``site:linkedin.com/in "<company>" "<city>"``),
    asked first; startups near you are small, so the city alone is a useful basis."""
    out: list[ReferrerQuery] = []
    if local and city:
        out.append(ReferrerQuery(f'site:linkedin.com/in "{company}" "{city}"', ReferralBasis.SAME_CITY, city))
    for w in profile.work_history:
        emp = (w.company or "").strip()
        if emp and emp.lower() != company.lower():
            out.append(ReferrerQuery(f'site:linkedin.com/in "{company}" "{emp}"', ReferralBasis.EX_COLLEAGUE, emp))
    for e in profile.education:
        school = (e.school or "").strip()
        if school:
            out.append(ReferrerQuery(f'site:linkedin.com/in "{company}" "{school}"', ReferralBasis.ALUMNI, school))
    if function:
        loc = f' "{city}"' if city else ""
        out.append(ReferrerQuery(f'site:linkedin.com/in "{company}" "{function}"{loc}', ReferralBasis.SAME_FUNCTION, function))
    seen: set[str] = set()
    uniq = [q for q in out if not (q.query in seen or seen.add(q.query))]
    return uniq[:MAX_LOCAL_QUERIES if local and city else MAX_QUERIES]


@dataclass(slots=True)
class Candidate:
    name: str
    title: str | None
    linkedin_url: str
    basis: ReferralBasis
    detail: str
    snippet: str
    rank: tuple


def _squash(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def candidates_from_results(hits: list[SerpHit], q: ReferrerQuery, company: str) -> list[Candidate]:
    """People in LinkedIn-titled results who are at ``company`` and whose result text shows the basis."""
    out: list[Candidate] = []
    comp = _squash(company)
    for h in hits:
        if not is_linkedin_profile(h.url):
            continue
        parsed = parse_linkedin_title(h.title)
        if parsed is None:
            continue
        name, title, at = parsed
        text = f"{h.title} {h.snippet}"
        if comp not in _squash(text):
            continue
        if at and comp not in _squash(at):
            continue  # works somewhere else now
        if q.basis is not ReferralBasis.SAME_FUNCTION and _squash(q.detail) not in _squash(text):
            continue  # no evidence for the basis (school, employer, city): not kept
        basis_rank = {ReferralBasis.EX_COLLEAGUE: 0, ReferralBasis.ALUMNI: 1, ReferralBasis.SAME_CITY: 2,
                      ReferralBasis.SAME_FUNCTION: 3}.get(q.basis, 4)
        senior = 1 if title and _SENIOR_EXEC.search(title) else 0
        out.append(Candidate(name, title, h.url.split("?")[0], q.basis, q.detail, f"{h.title} — {h.snippet}"[:280], (basis_rank, senior)))
    return out


def basis_sentence(r: Referral, profile: Profile) -> str | None:
    """A fact-checkable statement of the shared basis, from the stored evidence."""
    if r.basis is ReferralBasis.ALUMNI and r.basis_detail:
        return f"We both studied at {r.basis_detail}."
    if r.basis is ReferralBasis.EX_COLLEAGUE and r.basis_detail:
        return f"We both worked at {r.basis_detail}."
    if r.basis is ReferralBasis.SAME_FUNCTION and r.basis_detail:
        return f"We both work in {r.basis_detail}."
    if r.basis is ReferralBasis.SAME_CITY and r.basis_detail:
        from autoapply.outreach.startups import parse_location, same_city

        mine = parse_location(profile.location).city if profile.location else None
        return f"We're both in {r.basis_detail}." if same_city(mine, r.basis_detail) else f"They work in {r.basis_detail}."
    return r.basis_detail


# ---- reminders -------------------------------------------------------------------------------


def due_reminders(conn: sqlite3.Connection, now: datetime | None = None) -> tuple[list[Referral], list[Referral]]:
    """(connected for over 2 days without asking, requested for over 14 days -> moved to no_response)."""
    now = now or utcnow()
    ask_cut = format_ts(now - timedelta(days=ASK_AFTER_DAYS))
    stale_cut = format_ts(now - timedelta(days=NO_RESPONSE_AFTER_DAYS))
    to_ask = [Referral.from_row(r) for r in conn.execute(  # type: ignore[misc]
        "SELECT * FROM referrals WHERE state = 'connected' AND state_updated_at < ?", (ask_cut,))]
    stale: list[Referral] = []
    for r in conn.execute("SELECT id FROM referrals WHERE state = 'requested' AND state_updated_at < ?", (stale_cut,)).fetchall():
        stale.append(transition(conn, int(r["id"]), ReferralState.NO_RESPONSE, reason=f"no answer in {NO_RESPONSE_AFTER_DAYS} days"))
    return to_ask, stale


def requests_this_week(conn: sqlite3.Connection, now: datetime | None = None) -> int:
    """Connection requests the user marked sent in the last 7 days (shown as pacing advice)."""
    since = format_ts((now or utcnow()) - timedelta(days=7))
    return int(conn.execute("SELECT COUNT(*) FROM events WHERE kind = 'outreach' AND ts >= ? AND message LIKE '%→ requested%'",
                            (since,)).fetchone()[0])


__all__ = [
    "Candidate", "IllegalReferralTransition", "ReferrerQuery", "add", "basis_sentence", "candidates_from_results",
    "due_reminders", "get", "list_for_company", "match_by_name", "referrer_queries", "requests_this_week", "transition",
    "update_texts",
]
