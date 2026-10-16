"""Search planner for the browser job sites (LinkedIn, Glassdoor, Google Jobs).

Before: every run opened the same first result page of the same (role, location) searches, so a
second run only re-found listings it had already stored and came back empty. Now each search
keeps a cursor in ``meta`` (per source):

* ``window``: how far back the posting-date filter reaches (e.g. 24h -> week -> month),
* ``page``: the result page within that window.

After a search is read the cursor moves on: a page with no new listings advances to the next
page; an empty page (or the last page) widens the date window; when the widest window is
exhausted the search rests for a while (new postings appear) and starts over at 24h.

Plans interleave roles (one search per role before a second for any role), prefer searches
that have never run, then the ones that recently yielded new listings, then the stalest; and
they learn: per-search totals (``runs``, ``new``, ``matched``) are kept, so a search that keeps
producing matches is visited first and one that never does drifts to the back.
"""

from __future__ import annotations

import hashlib
import sqlite3
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from autoapply import db
from autoapply.config import Preferences
from autoapply.models import utcnow

#: How long an exhausted search rests before starting over at the narrowest window.
REST_HOURS = 12


@dataclass(slots=True, frozen=True)
class PlannedSearch:
    key: str            # stable id of the (role, location) search
    role: str
    location: str
    window: int         # index into the source's date windows
    page: int           # 0-based result page


def _key(role: str, location: str) -> str:
    raw = f"{role.strip().lower()}|{location.strip().lower()}"
    return hashlib.sha1(raw.encode()).hexdigest()[:12]


class SearchPlanner:
    def __init__(self, conn: sqlite3.Connection, source: str, *, windows: int, max_pages: int) -> None:
        self.conn = conn
        self.source = source
        self.windows = max(1, windows)
        self.max_pages = max(1, max_pages)
        self.meta_key = f"search_state:{source}"

    # ---- state ------------------------------------------------------------------------

    def _load(self) -> dict[str, dict[str, Any]]:
        return dict(db.get_meta(self.conn, self.meta_key, {}) or {})

    def _save(self, state: dict[str, dict[str, Any]]) -> None:
        db.set_meta(self.conn, self.meta_key, state)

    def reset(self) -> None:
        """Forget all cursors (e.g. roles/locations changed a lot, or the user asked)."""
        self._save({})

    # ---- planning ---------------------------------------------------------------------

    @staticmethod
    def combos(prefs: Preferences) -> list[tuple[str, str]]:
        roles = list(dict.fromkeys(r.strip() for r in prefs.roles if r.strip()))
        locations = list(dict.fromkeys(loc.strip() for loc in prefs.locations if loc.strip())) or [""]
        return [(r, loc) for r in roles for loc in locations]

    def plan(self, prefs: Preferences, n: int) -> list[PlannedSearch]:
        """Up to ``n`` searches for this run, spread across roles."""
        state = self._load()
        now = utcnow()
        candidates: list[tuple[tuple, PlannedSearch]] = []
        for idx, (role, loc) in enumerate(self.combos(prefs)):
            k = _key(role, loc)
            st = state.get(k) or {}
            rest = st.get("rest_until")
            if rest and str(rest) > now.isoformat():
                continue
            if rest:  # rest is over: start again at the narrowest window
                st = {**st, "window": 0, "page": 0, "rest_until": None}
                state[k] = st
            runs = int(st.get("runs", 0))
            yield_ = (int(st.get("matched", 0)) * 3 + int(st.get("new", 0))) / max(1, runs)
            # never run first; then best yield; then the one visited longest ago; then input order
            rank = (0 if runs == 0 else 1, -yield_, str(st.get("last_at") or ""), idx)
            candidates.append((rank, PlannedSearch(k, role, loc, int(st.get("window", 0)), int(st.get("page", 0)))))
        self._save(state)
        candidates.sort(key=lambda c: c[0])
        # Interleave roles: take the best search of each role in turn.
        by_role: dict[str, list[PlannedSearch]] = {}
        for _, s in candidates:
            by_role.setdefault(s.role.lower(), []).append(s)
        out: list[PlannedSearch] = []
        while len(out) < n and any(by_role.values()):
            for queue in by_role.values():
                if queue and len(out) < n:
                    out.append(queue.pop(0))
        return out

    # ---- learning ---------------------------------------------------------------------

    def record(self, s: PlannedSearch, *, cards: int, new: int, complete: bool) -> None:
        """Move the cursor after reading ``s``: ``cards`` listings on the page, ``new`` of them not
        stored before; ``complete`` = every card on the page was looked at (no budget cut-off)."""
        state = self._load()
        st = dict(state.get(s.key) or {})
        st.update(role=s.role, location=s.location)
        st["runs"] = int(st.get("runs", 0)) + 1
        st["new"] = int(st.get("new", 0)) + new
        st["last_new"] = new
        st["last_at"] = utcnow().isoformat()
        window, page = s.window, s.page
        if not complete:
            pass                      # budget ran out mid-page: read the rest of this page next time
        elif cards == 0:
            window, page = window + 1, 0
        else:
            page += 1
            if page >= self.max_pages:
                window, page = window + 1, 0
        if window >= self.windows:
            window, page = 0, 0
            st["rest_until"] = (utcnow() + timedelta(hours=REST_HOURS)).isoformat()
        st["window"], st["page"] = window, page
        state[s.key] = st
        self._save(state)

    def record_matches(self, key: str, matched: int) -> None:
        """Credit a search with jobs that went on to pass scoring (makes it rank higher)."""
        if matched <= 0:
            return
        state = self._load()
        if key in state:
            state[key]["matched"] = int(state[key].get("matched", 0)) + matched
            self._save(state)

    def summary(self) -> dict[str, dict[str, Any]]:
        return self._load()


__all__ = ["PlannedSearch", "REST_HOURS", "SearchPlanner"]
