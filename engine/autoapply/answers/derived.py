"""Answers derived from facts the user already gave (profile + never-guess facts + the job itself).

These questions used to land in the Needs-You inbox although the answer was already known:
"Country of residence" (profile location), "Location (City)", "How did you hear about this
job?" (where the agent found it), "Are you over 18?" (a working professional), "Is your
citizenship one of Cuba/Iran/…?" (the stored citizenship), marketing / talent-community opt-ins.

Rules are deterministic and only ever use stored facts; anything not covered returns None and
the normal resolver chain (never-guess / memory / generation / inbox) continues.
"""

from __future__ import annotations

import re
from typing import Any

from autoapply.answers.textnorm import match_option, normalize_question
from autoapply.config import NeverGuess
from autoapply.models import FormQuestion, Job, Profile

#: ISO-2 -> display name for the countries a stored fact / profile location can resolve to.
_COUNTRY_DISPLAY = {
    "IN": "India", "US": "United States", "GB": "United Kingdom", "CA": "Canada", "DE": "Germany", "FR": "France",
    "NL": "Netherlands", "IE": "Ireland", "SG": "Singapore", "AU": "Australia", "AE": "United Arab Emirates",
    "ES": "Spain", "IT": "Italy", "PL": "Poland", "SE": "Sweden", "CH": "Switzerland", "JP": "Japan", "BR": "Brazil",
    "MX": "Mexico", "PH": "Philippines", "PK": "Pakistan", "BD": "Bangladesh", "LK": "Sri Lanka", "NP": "Nepal",
}
_EMBARGOED = re.compile(r"\b(cuba|iran|north korea|dprk|syria|crimea|donetsk|luhansk|sudan|belarus|russia)\b", re.I)
_CITIZENSHIP_STATUSES = {"citizen", "national"}

_RESIDENCE_RX = re.compile(
    r"\bcountry of (residence|residency)\b|\b(current|which) country\b.*\b(live|reside|based|located)\b"
    r"|\bcountry (do )?you (currently )?(live|reside)\b|\bresident country\b|^country$|^current country$"
    r"|^country region$|^country or region$|\bin which country are you (currently )?(based|located)\b",
    re.I,
)
# Labels arrive normalized (lowercase, punctuation stripped): "Location (City)" -> "location city".
_CITY_RX = re.compile(r"^(location city|city|current city|current location city|city of residence|which city are you (based|located) in)$", re.I)
_CITIZENSHIP_RX = re.compile(r"\b(citizenship|nationality|passport (country|issuing country)|country of (citizenship|nationality|passport))\b", re.I)
_AGE_RX = re.compile(r"\b(over|at least|older than) (the age of )?18\b|\b18 years (of age|or older|old)\b|\blegal (working )?age\b", re.I)
_HEARD_RX = re.compile(r"\bhow did you (hear|learn|find out) about\b|\bwhere did you (hear|find|see|learn) (about )?(this|the|us)\b|\b(job )?source\b$|\breferral source\b", re.I)
_OPTIN_JOBS_RX = re.compile(r"\b(future (job )?opportunit|talent (community|network|pool)|future (roles|openings|positions)|similar (roles|jobs))\b", re.I)
_OPTIN_MARKETING_RX = re.compile(r"\b(stay up to date|keep me (informed|updated)|newsletter|marketing (emails|communications)|product updates|receive (news|updates|emails))\b", re.I)
_EMPLOYED_RX = re.compile(r"^are you currently employed\??$|\bcurrently employed\b", re.I)


def _home_country(profile: Profile) -> str | None:
    from autoapply.scoring import infer_countries

    codes = infer_countries(profile.location or "")[0]
    return next(iter(codes)) if len(codes) == 1 else None


def _citizenship(ng: NeverGuess) -> str | None:
    from autoapply.answers.textnorm import extract_country

    cits = []
    for k, v in (ng.work_auth or {}).items():
        if str(v).strip().lower().replace(" ", "_") in _CITIZENSHIP_STATUSES:
            cits.append(k.upper() if len(k) == 2 else (extract_country(k) or k))
    return cits[0] if len(cits) == 1 else None


def _display(code: str) -> str:
    return _COUNTRY_DISPLAY.get(code, code)


def _fit(value: str, q: FormQuestion) -> str | None:
    """The value as-is for free text, else the matching option (or None when none matches)."""
    if not q.options:
        return value
    return match_option(value, q.options)


def _first_fit(values: list[str], q: FormQuestion) -> str | None:
    for v in values:
        hit = _fit(v, q)
        if hit is not None:
            return hit
    return None


def _yes_no(yes: bool, q: FormQuestion) -> str | None:
    if q.options:
        return match_option(yes, q.options)
    return "Yes" if yes else "No"


def _heard_candidates(job: Job | None) -> list[str]:
    src = (getattr(job, "source", None) or "").lower() if job else ""
    if src == "linkedin":
        return ["LinkedIn", "Job board", "Online job board", "Other"]
    if src == "glassdoor":
        return ["Glassdoor", "Job board", "Online job board", "Other"]
    return ["Company website", "Company careers page", "Careers page", "Company Website", "Website", "Job board", "Other"]


def derived_answer(
    q: FormQuestion, *, profile: Profile, never_guess: NeverGuess, job: Job | None = None, kind: str = "facts",
) -> tuple[str, str] | None:
    """(answer, origin ref) for a question answerable from stored facts, else None.

    ``kind="facts"``: answers that follow from facts (residence, citizenship, sanctions screens, age);
    resolved before anything else. ``kind="defaults"``: sensible defaults ("how did you hear",
    opt-ins, currently employed) that the user's own saved answers (memory) must be able to override."""
    if kind == "defaults":
        return _defaults(q, profile=profile, job=job)
    label = normalize_question(q.label).replace("*", "").strip()
    full = f"{label} {normalize_question(q.description or '')}".strip()
    home = _home_country(profile)
    cit = _citizenship(never_guess)

    # Sanctions / embargo screens: "Is your citizenship (or residency) one of Cuba, Iran, …?"
    if _EMBARGOED.search(full) or any(_EMBARGOED.search(o) for o in q.options):
        about_res = bool(re.search(r"\bresiden", full))
        about_cit = bool(re.search(r"\bcitizen|national|passport", full)) or not about_res
        known = (not about_cit or cit) and (not about_res or home)
        risky = {c for c in (cit, home) if c} & {"CU", "IR", "KP", "SY", "SD", "BY", "RU"}
        if known and not risky:
            ans = _first_fit(["None of the above", "None of these apply", "Not applicable", "None"], q) if q.options else None
            ans = ans or _yes_no(False, q)
            return (ans, "derived:sanctions") if ans else None
        return None

    if _CITIZENSHIP_RX.search(label) and cit:
        ans = _fit(_display(cit), q)
        return (ans, "derived:citizenship") if ans else None

    if _RESIDENCE_RX.search(label) and home:
        ans = _fit(_display(home), q)
        return (ans, "derived:residence") if ans else None

    if _CITY_RX.search(label) and profile.location:
        city = profile.location.split(",")[0].strip()
        ans = _fit(city, q) if city else None
        return (ans, "derived:city") if ans else None

    if _AGE_RX.search(full) and (profile.work_history or profile.education or (profile.years_experience or 0) > 0):
        ans = _yes_no(True, q)
        return (ans, "derived:adult") if ans else None

    return None


_FOLLOW_UP_RX = re.compile(r"^if (you|your answer) (answered|selected|chose|picked|said|is)\b|^if (other|yes|no|applicable)\b.*\bspecify\b|^please specify( here)?$", re.I)


def _defaults(q: FormQuestion, *, profile: Profile, job: Job | None) -> tuple[str, str] | None:
    label = normalize_question(q.label).replace("*", "").strip()
    full = f"{label} {normalize_question(q.description or '')}".strip()
    # Conditional follow-ups ("If you answered Other, please specify") don't apply to our answer.
    if _FOLLOW_UP_RX.search(label) and not q.options:
        return "N/A", "derived:not_applicable"
    if _HEARD_RX.search(label):
        ans = _first_fit(_heard_candidates(job), q)
        return (ans, "derived:source") if ans else None

    if re.search(r"\bhow (should|would you like|do you prefer)( we| us)? (to )?(communicate|contact|reach)\b|\bpreferred (method of )?(communication|contact)\b", label):
        ans = _first_fit(["Email", "E-mail", "email"], q)
        return (ans, "derived:contact_email") if ans else None
    if _OPTIN_JOBS_RX.search(full):
        ans = _yes_no(True, q)
        return (ans, "derived:optin_jobs") if ans else None
    if _OPTIN_MARKETING_RX.search(full):
        ans = _yes_no(False, q)
        return (ans, "derived:optin_marketing") if ans else None

    if _EMPLOYED_RX.search(label) and profile.work_history:
        from autoapply.answers.resolver import _current_role

        r: Any = _current_role(profile)
        current = bool(r and (not r.end or str(r.end).strip().lower() in {"present", "current", "now", ""}))
        ans = _yes_no(current, q)
        return (ans, "derived:employed") if ans else None
    return None
