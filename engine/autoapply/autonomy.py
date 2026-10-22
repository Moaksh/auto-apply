"""Earned autonomy: per application site (ATS) trust built in Review.

Owner decision #3 (docs/DESIGN_AWARD_VISION.md): Auto is *earned* per application site, and the
user can always choose any mode for anything (global, site, company, job), with no locks. This
module only measures and suggests; it never changes a mode. Accepting a suggestion is the app
sending ``update_preferences {per_ats_mode: {<ats>: "auto"}}``.

Everything is computed from existing tables:

* A **review decision** is a ``state`` event by the user leaving ``awaiting_review``:
  to ``submitting`` (an approval) or to ``skipped`` (a reject, ``reject``'s reason).
* An approval is **clean** when no answer of that application was edited in Review before it.
  Review edits are ``edit_application_answer`` (``user`` event with ``application_answer_id``;
  the answer's origin becomes ``user``). Answers typed in the Needs-You inbox also have origin
  ``user`` but are not edits of a prepared form, so they do not count.
* A reject with reason ``wrong_answers`` breaks the streak like an edit. Other reject reasons
  (not interested, company, other) are about the job, not the agent's work, and are neutral.

Rule: a site is **eligible** when its latest :data:`THRESHOLD` review decisions that judge the
agent's work (approvals and wrong-answer rejects) are all clean approvals, i.e. the current clean
streak is at least :data:`THRESHOLD` (so there are 0 wrong-answer rejects among the last 10).

Suggestion state lives in ``meta`` (:data:`META_KEY`): ``{ats: {"suggested_at", "clean_approvals",
"dismissed_at"}}``. The ``autonomy_suggestion`` event is emitted once per site, the first time a
site that is in Review (``Preferences.effective_mode(ats=...)``) becomes eligible.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from autoapply import db
from autoapply.config import Preferences
from autoapply.enums import Ats, Mode
from autoapply.models import AutonomyReport, AutonomySite, AutonomySuggestionPayload, now_ts, parse_ts

#: Clean approvals in a row (on one site) before Auto is offered for it.
THRESHOLD = 10

#: meta key holding the per-site suggestion state.
META_KEY = "autonomy_suggestions"

#: Reject reasons that mean "the agent's answers were wrong" (ReviewSkipReason.wrongAnswers).
WRONG_ANSWER_REASONS = frozenset({"wrong_answers"})


@dataclass(slots=True)
class _Stats:
    approved: int = 0
    approved_without_edits: int = 0
    edited: int = 0
    rejected_wrong_answers: int = 0
    clean_streak: int = 0
    since: str | None = None  # first approval of the current streak
    last_decision_at: str | None = None


def _norm_reason(reason: str | None) -> str:
    return (reason or "").strip().lower().replace(" ", "_").replace("-", "_")


def site_stats(conn: sqlite3.Connection) -> dict[Ats, _Stats]:
    """Review decisions per ATS, oldest first, folded into counts and the current clean streak."""
    edits: dict[int, list[int]] = {}
    for r in conn.execute(
        "SELECT id, application_id FROM events WHERE kind = 'user' AND application_id IS NOT NULL "
        "AND json_extract(payload, '$.application_answer_id') IS NOT NULL"
    ):
        edits.setdefault(int(r[1]), []).append(int(r[0]))
    rows = conn.execute(
        "SELECT e.id, e.ts, e.application_id, json_extract(e.payload, '$.to') AS to_state, "
        "json_extract(e.payload, '$.reason') AS reason, j.ats "
        "FROM events e JOIN applications a ON a.id = e.application_id JOIN jobs j ON j.id = a.job_id "
        "WHERE e.kind = 'state' AND e.actor = 'user' AND json_extract(e.payload, '$.from') = 'awaiting_review' "
        "AND json_extract(e.payload, '$.to') IN ('submitting', 'skipped') AND j.ats IS NOT NULL "
        "ORDER BY e.id"
    ).fetchall()
    out: dict[Ats, _Stats] = {}
    for r in rows:
        try:
            ats = Ats(r["ats"])
        except ValueError:
            continue
        s = out.setdefault(ats, _Stats())
        if r["to_state"] == "submitting":
            s.approved += 1
            s.last_decision_at = r["ts"]
            if any(eid < r["id"] for eid in edits.get(int(r["application_id"]), ())):
                s.edited += 1
                s.clean_streak, s.since = 0, None
            else:
                s.approved_without_edits += 1
                if s.clean_streak == 0:
                    s.since = r["ts"]
                s.clean_streak += 1
        elif _norm_reason(r["reason"]) in WRONG_ANSWER_REASONS:
            s.rejected_wrong_answers += 1
            s.last_decision_at = r["ts"]
            s.clean_streak, s.since = 0, None
    return out


def _state(conn: sqlite3.Connection) -> dict[str, dict[str, Any]]:
    raw = db.get_meta(conn, META_KEY, {})
    return raw if isinstance(raw, dict) else {}


def _ts(value: Any) -> datetime | None:
    return parse_ts(value) if value else None


def report(conn: sqlite3.Connection, prefs: Preferences | None = None) -> AutonomyReport:
    """``get_autonomy``: every site's trust stats and suggestion state (all ATS values, zeros included)."""
    prefs = prefs or db.get_preferences(conn)
    stats = site_stats(conn)
    state = _state(conn)
    sites: list[AutonomySite] = []
    for ats in Ats:
        s = stats.get(ats, _Stats())
        st = state.get(ats.value, {})
        mode = prefs.effective_mode(ats=ats)
        eligible = s.clean_streak >= THRESHOLD
        if mode is Mode.AUTO:
            suggestion = "none"
        elif st.get("dismissed_at"):
            suggestion = "dismissed"
        elif eligible:
            suggestion = "pending"
        else:
            suggestion = "none"
        sites.append(AutonomySite(
            ats=ats, mode=mode, mode_source="site" if ats in prefs.per_ats_mode else "global",
            approved=s.approved, approved_without_edits=s.approved_without_edits, edited=s.edited,
            rejected_wrong_answers=s.rejected_wrong_answers, clean_approvals=s.clean_streak,
            since=_ts(s.since), last_decision_at=_ts(s.last_decision_at), eligible=eligible,
            suggestion=suggestion, suggested_at=_ts(st.get("suggested_at")), dismissed_at=_ts(st.get("dismissed_at")),
        ))
    return AutonomyReport(threshold=THRESHOLD, sites=sites)


def new_suggestions(conn: sqlite3.Connection, prefs: Preferences | None = None) -> list[AutonomySuggestionPayload]:
    """Sites that just earned Auto while in Review and were never offered it. Records them in meta
    (``suggested_at``) so each site is offered once; returns the event payloads to emit."""
    rep = report(conn, prefs)
    state = _state(conn)
    out: list[AutonomySuggestionPayload] = []
    for site in rep.sites:
        if site.suggestion != "pending" or state.get(site.ats.value, {}).get("suggested_at"):
            continue
        state[site.ats.value] = {**state.get(site.ats.value, {}), "suggested_at": now_ts(),
                                 "clean_approvals": site.clean_approvals}
        out.append(AutonomySuggestionPayload(ats=site.ats, clean_approvals=site.clean_approvals,
                                             since=site.since or parse_ts(now_ts())))
    if out:
        db.set_meta(conn, META_KEY, state)
    return out


def dismiss(conn: sqlite3.Connection, ats: Ats) -> None:
    """"Not now": the site is not offered again (no event, no Settings prompt). Any mode can still be
    chosen by hand at any time. Idempotent."""
    state = _state(conn)
    entry = state.get(ats.value, {})
    if entry.get("dismissed_at"):
        return
    state[ats.value] = {**entry, "dismissed_at": now_ts()}
    if not entry.get("suggested_at"):
        state[ats.value]["suggested_at"] = state[ats.value]["dismissed_at"]  # never emit after a dismissal
    db.set_meta(conn, META_KEY, state)
