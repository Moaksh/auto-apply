"""Job-search preferences suggested from the parsed resume (roles, seniority, locations).

Onboarding pre-fills the Preferences step with these after a resume upload, and Settings offers
them on demand ("Fill from resume"). Nothing is saved here: the user reviews and saves.
"""

from __future__ import annotations

import logging
import re
from datetime import date
from typing import Any

from autoapply.enums import Seniority
from autoapply.models import Profile, SuggestedPreferences

log = logging.getLogger(__name__)

_LEVEL_WORDS = re.compile(
    r"\b(intern(ship)?|trainee|junior|jr\.?|senior|sr\.?|staff|principal|lead|head of|associate|graduate|i{1,3}|iv|[1-4])\b",
    re.I,
)
_MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], start=1)}

SUGGEST_PROMPT = (
    "SUGGEST TARGET ROLES. From this candidate's resume facts, list 3-5 job titles they would realistically "
    "search for next (plain market titles like 'AI Engineer', 'Backend Engineer'; no seniority words, no "
    "company names). Use only the facts.\n\nHeadline: {headline}\nRecent titles: {titles}\nSkills: {skills}\n"
    "Summary: {summary}"
)
SUGGEST_SCHEMA = {
    "type": "object",
    "properties": {"roles": {"type": "array", "items": {"type": "string"}, "maxItems": 5}},
    "required": ["roles"],
    "additionalProperties": False,
}


def seniority_for_years(years: float | None) -> list[Seniority]:
    """The level band(s) a candidate with ``years`` of experience applies to (adjacent bands overlap)."""
    if years is None:
        return []
    if years < 2:
        return [Seniority.JUNIOR]
    if years < 4:
        return [Seniority.JUNIOR, Seniority.MID]
    if years < 6:
        return [Seniority.MID, Seniority.SENIOR]
    if years < 9:
        return [Seniority.SENIOR]
    if years < 13:
        return [Seniority.SENIOR, Seniority.STAFF]
    return [Seniority.STAFF, Seniority.PRINCIPAL]


def _parse_date(s: str | None) -> date | None:
    if not s:
        return None
    t = s.strip().lower()
    if t in {"present", "current", "now", "ongoing", "today"}:
        return date.today()
    y = re.search(r"(19|20)\d{2}", t)
    if not y:
        return None
    m = next((n for k, n in _MONTHS.items() if k in t), None)
    if m is None and (mm := re.match(r"(\d{1,2})[/-]", t)):
        m = int(mm.group(1)) if 1 <= int(mm.group(1)) <= 12 else None
    return date(int(y.group(0)), m or 1, 1)


def years_from_history(profile: Profile) -> float | None:
    """Total non-overlapping time across work_history (internships count half)."""
    spans: list[tuple[date, date, float]] = []
    for r in profile.work_history:
        start, end = _parse_date(r.start), _parse_date(r.end) or (date.today() if r.start and not r.end else None)
        if start and end and end >= start:
            spans.append((start, end, 0.5 if re.search(r"\bintern", r.title or "", re.I) else 1.0))
    if not spans:
        return None
    spans.sort()
    total, cur_end = 0.0, None
    for s, e, w in spans:
        if cur_end and s < cur_end:
            s = cur_end
        if e > s:
            total += (e - s).days / 365.25 * w
        cur_end = max(cur_end or e, e)
    return round(total, 1)


def _clean_title(t: str) -> str:
    t = re.split(r"\s+[-–|@,]\s+|\s+at\s+", t.strip())[0]
    t = _LEVEL_WORDS.sub("", t)
    return re.sub(r"\s{2,}", " ", t).strip(" -–,/")


def _dedupe(items: list[str], limit: int) -> list[str]:
    seen: dict[str, str] = {}
    for it in items:
        k = it.lower().strip()
        if k and len(k) >= 3 and k not in seen:
            seen[k] = it.strip()
    return list(seen.values())[:limit]


def _locations(profile: Profile) -> list[str]:
    from autoapply.answers.derived import _COUNTRY_DISPLAY
    from autoapply.scoring import infer_countries

    loc = (profile.location or "").strip()
    if not loc:
        return []
    city = loc.split(",")[0].strip()
    codes = infer_countries(loc)[0]
    country = _COUNTRY_DISPLAY.get(next(iter(codes))) if len(codes) == 1 else None
    return _dedupe([x for x in (city, country) if x], 3)


def heuristic_preferences(profile: Profile) -> SuggestedPreferences:
    years = profile.years_experience if profile.years_experience is not None else years_from_history(profile)
    titles = [_clean_title(r.title) for r in profile.work_history[:3] if r.title]
    roles = _dedupe([_clean_title(profile.headline or ""), *titles], 4)
    return SuggestedPreferences(roles=roles, seniority=seniority_for_years(years), locations=_locations(profile),
                                years_experience=years)


async def suggest_preferences(profile: Profile, llm: Any | None) -> SuggestedPreferences:
    """Heuristic suggestion, with the role list sharpened by the fast model when one is available."""
    base = heuristic_preferences(profile)
    if llm is None or not (profile.headline or profile.work_history or profile.skills):
        return base
    try:
        res = await llm.complete(
            SUGGEST_PROMPT.format(
                headline=profile.headline or "-", titles=", ".join(r.title for r in profile.work_history[:4]) or "-",
                skills=", ".join(profile.skills[:25]) or "-", summary=(profile.summary or "-")[:600],
            ),
            schema=SUGGEST_SCHEMA, tier="fast", max_tokens=200,
            system="You suggest job-search titles for a candidate. Never invent experience.",
        )
        roles = [_clean_title(str(r)) for r in (res.data or {}).get("roles", []) if str(r).strip()]
        if roles:
            base.roles = _dedupe([*roles, *base.roles], 5)
    except Exception:  # noqa: BLE001 - suggestions are best-effort
        log.warning("role suggestion failed; using resume titles", exc_info=True)
    return base


__all__ = ["heuristic_preferences", "seniority_for_years", "suggest_preferences", "years_from_history"]
