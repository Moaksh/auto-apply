"""Re-check skipped jobs when what they were judged against changes.

A job skipped for "match 58 < 70" or "seniority: staff" is only wrong to keep skipped once the
user changes the threshold, roles, seniority, locations, salary floor, exclusions or profile.
Each score is stored with a fingerprint (``scores.basis``) of everything except the threshold:

* threshold lowered, nothing else changed -> skipped jobs whose stored score now passes are put
  back to ``discovered`` and re-use that score: no page visit, no tokens.
* anything else changed -> recent skipped jobs (any scoring/filter reason) go back to
  ``discovered``; the next scoring pass re-judges them (a fresh LLM score).

Never reconsidered: the user's own skips (``user_*``), jobs without an apply link, duplicates,
daily-cap / cooldown deferrals, and jobs older than :data:`RECONSIDER_DAYS`.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import timedelta

from autoapply import db
from autoapply.config import Preferences
from autoapply.enums import Actor, AppState
from autoapply.models import Profile, format_ts, utcnow

RECONSIDER_DAYS = 30
BASIS_META = "scoring_basis_seen"
THRESHOLD_META = "scoring_threshold_seen"
#: Skip reasons that depend on preferences/profile (prefix match).
RECONSIDERABLE = (
    "below_threshold", "seniority_mismatch", "location_mismatch", "remote_policy", "salary_below_floor",
    "missing_salary", "excluded_keyword", "excluded_company", "excluded_industry", "role", "title",
    "work_auth", "no_sponsorship", "unscored",
)


def scoring_basis(profile: Profile, prefs: Preferences) -> str:
    """Fingerprint of everything a score depends on, except the threshold."""
    data = {
        "roles": sorted(r.lower().strip() for r in prefs.roles),
        "seniority": sorted(str(getattr(s, "value", s)) for s in prefs.seniority),
        "locations": sorted(loc.lower().strip() for loc in prefs.locations),
        "remote": sorted(str(getattr(p, "value", p)) for p in prefs.remote_policy),
        "salary": [prefs.salary_floor, prefs.salary_currency, prefs.hide_without_salary],
        "exclude": [sorted(prefs.exclude_companies), sorted(prefs.exclude_industries), sorted(prefs.exclude_keywords)],
        "work_auth": prefs.work_auth_summary,
        "years": profile.years_experience,
        "headline": profile.headline,
        "skills": sorted(s.lower() for s in profile.skills),
        "titles": [r.title for r in profile.work_history],
        "resume": hashlib.sha1((profile.raw_text or "").encode()).hexdigest()[:10] if getattr(profile, "raw_text", None) else None,
    }
    return hashlib.sha1(json.dumps(data, sort_keys=True, default=str).encode()).hexdigest()[:16]


def _reconsiderable(reason: str | None) -> bool:
    r = (reason or "").strip()
    return bool(r) and not r.startswith("user") and r.startswith(RECONSIDERABLE)


def reconsider(conn: sqlite3.Connection) -> tuple[int, str | None]:
    """Reopen skipped jobs affected by a settings/profile change. Returns (count, why) — why is a
    short human sentence for the log, or None when nothing changed."""
    prefs = db.get_preferences(conn)
    profile = db.get_profile(conn)
    basis = scoring_basis(profile, prefs)
    last_basis = db.get_meta(conn, BASIS_META, None)
    last_threshold = db.get_meta(conn, THRESHOLD_META, None)
    db.set_meta(conn, BASIS_META, basis)
    db.set_meta(conn, THRESHOLD_META, prefs.match_threshold)
    if last_basis is None:  # first run with this feature: remember, don't reshuffle history
        return 0, None
    basis_changed = basis != last_basis
    lowered = last_threshold is not None and prefs.match_threshold < int(last_threshold)
    if not basis_changed and not lowered:
        return 0, None
    cutoff = format_ts(utcnow() - timedelta(days=RECONSIDER_DAYS))
    rows = conn.execute(
        "SELECT a.id, a.state_reason, s.score, s.skip_reason, s.basis, a.job_id FROM applications a "
        "JOIN jobs j ON j.id = a.job_id LEFT JOIN scores s ON s.job_id = a.job_id "
        "WHERE a.state = 'skipped' AND j.discovered_at >= ?",
        (cutoff,),
    ).fetchall()
    n = 0
    for app_id, state_reason, score, skip_reason, row_basis, job_id in rows:
        reason = state_reason or skip_reason
        if not _reconsiderable(reason):
            continue
        if not basis_changed:
            # Threshold-only change: only jobs whose stored score now clears the bar.
            if not (str(reason).startswith("below_threshold") and score is not None and score >= prefs.match_threshold):
                continue
            if row_basis is None:  # scored before fingerprints existed, under these same settings
                conn.execute("UPDATE scores SET basis = ? WHERE job_id = ?", (basis, job_id))
        db.transition(conn, app_id, AppState.DISCOVERED, reason="reconsider: settings changed", actor=Actor.AGENT)
        n += 1
    why = "your preferences or profile changed" if basis_changed else f"the match threshold was lowered to {prefs.match_threshold}"
    return n, why


__all__ = ["RECONSIDER_DAYS", "reconsider", "scoring_basis"]
