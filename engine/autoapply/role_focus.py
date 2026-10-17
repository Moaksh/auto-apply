"""What the user's target roles *mean* for this candidate.

Roles are typed by people, not search engines: "Engineering" on a software/AI resume means
software engineering, not industrial, electrical or civil engineering, and searching the bare
word pulls in all of them. A :class:`RoleFocus` is the agent's reading of the roles against the
resume:

* ``searches``: concrete titles to search and match (specific roles are kept as typed; a vague
  one like "Engineering" becomes the candidate's own kind of titles),
* ``avoid``: title words of other disciplines (mechanical, civil, sales …) that the candidate's
  profile and roles never mention; a posting titled with one is skipped before any tokens,
* ``field``: one line naming the candidate's field, shown in the log.

The fast model interprets vague roles (only when the roles or profile change; cached in meta);
without it, or when every role is already specific, a local heuristic does the same job.
"""

from __future__ import annotations

import hashlib
import json
import logging
import sqlite3
from dataclasses import asdict, dataclass, field
from typing import Any

from autoapply import db
from autoapply.config import Preferences
from autoapply.models import Profile

log = logging.getLogger(__name__)

META_KEY = "role_focus"

#: A single one of these words says nothing about *which* job.
_VAGUE = {
    "engineering", "engineer", "engineers", "developer", "development", "dev", "tech", "technology", "technical",
    "software", "it", "data", "product", "design", "research", "science", "computer", "programming", "programmer",
    "manager", "management", "analyst", "consultant", "specialist", "associate", "coding", "ai", "ml",
}
_FILLER = {"jobs", "job", "role", "roles", "any", "fresher", "freshers", "graduate", "entry", "level", "remote",
           "intern", "internship", "position", "opening", "openings", "in", "a", "an", "the"}
#: Disciplines that share words like "engineer"/"analyst" with software roles but are different jobs.
DISCIPLINES = (
    "mechanical", "civil", "electrical", "electronics", "electronic", "chemical", "industrial", "structural",
    "mining", "petroleum", "aerospace", "aeronautical", "manufacturing", "process engineer", "hvac", "piping",
    "instrumentation", "automotive", "marine", "biomedical", "environmental", "production engineer",
    "maintenance", "construction", "plumbing", "geotechnical", "metallurgical", "textile", "agricultural",
    "mep", "site engineer", "quality control", "qc engineer", "sales engineer", "sales", "field service",
    "field engineer", "service engineer", "packaging", "rf engineer", "telecom", "network engineer", "pcb",
    "hardware", "mechatronics", "robotics technician", "nuclear", "power plant", "solar", "substation",
    "water", "transport", "highway", "estimation", "estimator", "draftsman", "cad", "autocad", "solidworks",
    "accountant", "accounting", "nurse", "teacher", "pharmacist", "lab technician", "warehouse", "driver",
    "telecaller", "customer support", "customer service", "call center", "bpo", "recruiter", "hr",
    "marketing", "content writer", "graphic designer", "civil site",
)

INTERPRET_PROMPT = (
    "INTERPRET TARGET ROLES. A job seeker typed these target roles: {roles}.\n"
    "Read them the way the candidate means them, given their resume:\n"
    "Headline: {headline}\nRecent titles: {titles}\nSkills: {skills}\nSummary: {summary}\n\n"
    "Return:\n"
    "- field: the candidate's field in a few words (e.g. 'software / AI engineering').\n"
    "- searches: 3-8 concrete job titles to search job sites with. Keep every specific typed role "
    "verbatim; replace a vague one (e.g. 'Engineering', 'Developer', 'Tech') with the specific titles "
    "this candidate would actually apply for. No seniority words, no company names.\n"
    "- avoid: up to 15 lowercase title words/phrases of other disciplines that share words with these "
    "roles but are not this candidate's field (e.g. 'mechanical', 'civil', 'sales'). Never list anything "
    "in the candidate's own titles, skills or typed roles."
)
INTERPRET_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["field", "searches", "avoid"],
    "properties": {
        "field": {"type": "string", "maxLength": 80},
        "searches": {"type": "array", "items": {"type": "string"}, "maxItems": 8},
        "avoid": {"type": "array", "items": {"type": "string"}, "maxItems": 15},
    },
}


@dataclass(slots=True)
class RoleFocus:
    key: str
    field: str | None
    searches: list[str]
    avoid: list[str] = field(default_factory=list)
    by_model: bool = False

    def summary(self) -> str:
        what = ", ".join(self.searches) or "(no roles)"
        return (f"{self.field}: " if self.field else "") + what


def is_vague(role: str) -> bool:
    """A role that names no particular job: one generic word ("Engineering", "Tech", "Developer")."""
    words = [w for w in db.normalize_text(role).split() if w not in _FILLER]
    return len(words) == 1 and words[0] in _VAGUE


def _key(prefs: Preferences, profile: Profile) -> str:
    data = [sorted(r.strip().lower() for r in prefs.roles), profile.headline, [w.title for w in profile.work_history[:4]],
            sorted(s.lower() for s in profile.skills[:30])]
    return hashlib.sha1(json.dumps(data, default=str).encode()).hexdigest()[:16]


def _own_text(prefs: Preferences, profile: Profile) -> str:
    """Everything that describes the candidate's own field (an avoid word must not appear here)."""
    parts = [*prefs.roles, profile.headline or "", *(w.title or "" for w in profile.work_history), *profile.skills,
             (profile.summary or "")[:1500]]
    return " " + db.normalize_text(" ".join(parts)) + " "


def _clean_avoid(words: list[str], own: str) -> list[str]:
    out: dict[str, None] = {}
    for w in words:
        n = db.normalize_text(w)
        if n and len(n) >= 2 and f" {n} " not in own and not any(f" {t} " in own for t in n.split() if len(t) > 3):
            out[n] = None
    return list(out)


def _dedupe(items: list[str]) -> list[str]:
    seen: dict[str, str] = {}
    for it in items:
        k = it.strip().lower()
        if k and k not in seen:
            seen[k] = it.strip()
    return list(seen.values())


def heuristic_focus(prefs: Preferences, profile: Profile) -> RoleFocus:
    from autoapply.prefs_suggest import _clean_title

    own_titles = _dedupe([t for t in (_clean_title(profile.headline or ""), *(_clean_title(w.title) for w in profile.work_history[:3] if w.title)) if t and len(t) <= 40 and not is_vague(t)])
    searches: list[str] = []
    for role in prefs.roles:
        if not role.strip():
            continue
        if is_vague(role) and own_titles:
            searches.extend(own_titles)
        else:
            searches.append(role.strip())
    own = _own_text(prefs, profile)
    return RoleFocus(key=_key(prefs, profile), field=None, searches=_dedupe(searches)[:8],
                     avoid=_clean_avoid(list(DISCIPLINES), own))


def current(conn: sqlite3.Connection, prefs: Preferences | None = None, profile: Profile | None = None) -> RoleFocus:
    """The cached interpretation when it matches the current roles + profile, else the heuristic one."""
    prefs = prefs or db.get_preferences(conn)
    profile = profile or db.get_profile(conn)
    key = _key(prefs, profile)
    cached = db.get_meta(conn, META_KEY, None)
    if isinstance(cached, dict) and cached.get("key") == key:
        try:
            return RoleFocus(**cached)
        except TypeError:
            pass
    return heuristic_focus(prefs, profile)


async def ensure(conn: sqlite3.Connection, llm: Any | None) -> tuple[RoleFocus, bool]:
    """Re-interpret the roles if they or the profile changed. Returns (focus, changed). The model is
    asked only when some role is vague; specific roles need no interpretation."""
    prefs, profile = db.get_preferences(conn), db.get_profile(conn)
    key = _key(prefs, profile)
    cached = db.get_meta(conn, META_KEY, None)
    if isinstance(cached, dict) and cached.get("key") == key:
        return current(conn, prefs, profile), False
    focus = heuristic_focus(prefs, profile)
    has_profile = bool(profile.headline or profile.work_history or profile.skills)
    if llm is not None and has_profile and any(is_vague(r) for r in prefs.roles):
        try:
            res = await llm.complete(
                INTERPRET_PROMPT.format(
                    roles=json.dumps(prefs.roles), headline=profile.headline or "-",
                    titles=", ".join(w.title for w in profile.work_history[:4]) or "-",
                    skills=", ".join(profile.skills[:25]) or "-", summary=(profile.summary or "-")[:600],
                ),
                schema=INTERPRET_SCHEMA, tier="fast", max_tokens=400,
                system="You interpret a job seeker's target roles. Never invent experience.",
            )
            data = res.data or {}
            specific = [r.strip() for r in prefs.roles if r.strip() and not is_vague(r)]
            got = [str(s).strip() for s in data.get("searches", []) if str(s).strip() and not is_vague(str(s))]
            if got:
                focus.searches = _dedupe([*specific, *got])[:8]
            focus.field = (str(data.get("field") or "").strip() or None)
            focus.avoid = _clean_avoid([*data.get("avoid", []), *DISCIPLINES], _own_text(prefs, profile))
            focus.by_model = True
        except Exception:  # noqa: BLE001 - interpretation is best-effort; the heuristic stands
            log.warning("role interpretation failed; using the resume titles", exc_info=True)
    db.set_meta(conn, META_KEY, asdict(focus))
    return focus, True


#: Title words shared by every discipline (never evidence that a title is in the candidate's field).
_GENERIC = {
    "engineer", "engineering", "engineers", "developer", "development", "manager", "management", "lead", "senior",
    "junior", "staff", "principal", "specialist", "analyst", "associate", "consultant", "architect", "intern", "head",
    "director", "applied", "system", "systems", "design", "designer", "technical", "program", "product", "of", "and",
}


def off_field(title: str, focus: RoleFocus) -> str | None:
    """The avoid word in ``title`` when the posting is another discipline's job, else None.

    A title that also names the candidate's own field ("Director of Software Engineering,
    Accounting", "ML Engineer, Hardware") is kept: losing a real match costs more than letting the
    scorer mark down a stray one."""
    tokens = db.normalize_text(title).split()
    t = " " + " ".join(tokens) + " "
    hit = next((w for w in focus.avoid if f" {w} " in t), None)
    if hit is None:
        return None
    own = {w for s in focus.searches for w in db.normalize_text(s).split() if w not in _GENERIC and len(w) > 1}
    if own & set(tokens):
        return None
    return hit


__all__ = ["DISCIPLINES", "RoleFocus", "current", "ensure", "heuristic_focus", "is_vague", "off_field"]
