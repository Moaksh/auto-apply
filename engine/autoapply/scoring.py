"""Scoring: hard filters first, then an LLM match score 0-100 (batched) for survivors.

Owner: Workstream A (engine core).

* :func:`hard_filter` — cheap, deterministic, no LLM. Returns an explicit skip reason
  (see the ``SKIP_*`` constants / ``<kind>:<detail>`` strings) or None.
* :func:`score_jobs` — batched LLM scoring with a strict JSON schema; applies
  ``preferences.match_threshold`` (``below_threshold``).
* :func:`score_pending` — the whole step for a run: loads ``discovered`` applications,
  filters, scores, persists ``scores`` rows and walks the state machine
  (``discovered -> skipped`` | ``discovered -> scored -> queued|skipped``), emitting
  ``job_scored`` events. Pipeline (D) and the CLI both call it.

Skip reasons (stored in ``scores.skip_reason`` and as the transition reason):
``excluded_company``, ``excluded_keyword:<kw>``, ``excluded_industry:<industry>``,
``seniority_mismatch:<level>``, ``remote_policy:<policy>``, ``location_mismatch``,
``work_auth:no_sponsorship``, ``salary_below_floor``, ``missing_salary``,
``company_cooldown``, ``daily_cap_reached`` (deferral — see :data:`DEFERRAL_REASONS`),
``below_threshold``.
"""

from __future__ import annotations

import json
import logging
import re
import sqlite3
from collections.abc import Awaitable, Callable, Iterable
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from autoapply.config import NeverGuess, Preferences
from autoapply.discovery.base import infer_remote
from autoapply.enums import AppState, RemotePolicy, Seniority
from autoapply.llm.provider import LLMError, LLMProvider
from autoapply.models import Company, JobScoredPayload, Job, Profile

log = logging.getLogger("autoapply.scoring")

SKIP_EXCLUDED_COMPANY = "excluded_company"
SKIP_LOCATION = "location_mismatch"
SKIP_NO_SPONSORSHIP = "work_auth:no_sponsorship"
SKIP_SALARY = "salary_below_floor"
SKIP_MISSING_SALARY = "missing_salary"
SKIP_COOLDOWN = "company_cooldown"
SKIP_DAILY_CAP = "daily_cap_reached"
SKIP_BELOW_THRESHOLD = "below_threshold"
SKIP_OFF_FIELD = "role_off_field"

#: Reasons that mean "not now" rather than "never": the caller should leave the application
#: where it is (``discovered``) instead of skipping it.
DEFERRAL_REASONS: frozenset[str] = frozenset({SKIP_DAILY_CAP})


def is_deferral(reason: str | None) -> bool:
    return reason in DEFERRAL_REASONS


@dataclass(slots=True)
class ScoreResult:
    job_id: int
    score: int | None  # None when skipped by a hard filter (or on error)
    reasons: dict[str, Any] = field(default_factory=dict)  # {"summary": str, "factors": {name: 0..100}, "concerns": [..]}
    skip_reason: str | None = None  # e.g. "below_threshold", "excluded_keyword:crypto", "company_cooldown"
    tokens_in: int = 0
    tokens_out: int = 0
    model: str | None = None
    error: str | None = None  # LLM failure: application stays ``discovered`` and is retried next run


# =====================================================================================
# Text helpers
# =====================================================================================


def _norm(text: str | None) -> str:
    from autoapply.db import normalize_text

    return normalize_text(text)


def _has_phrase(haystack_norm: str, phrase: str) -> bool:
    p = _norm(phrase)
    return bool(p) and re.search(rf"(?<![a-z0-9]){re.escape(p)}(?![a-z0-9])", haystack_norm) is not None


# ---- geography ----------------------------------------------------------------------

_US_STATES = (
    "alabama alaska arizona arkansas california colorado connecticut delaware florida georgia hawaii idaho illinois "
    "indiana iowa kansas kentucky louisiana maine maryland massachusetts michigan minnesota mississippi missouri "
    "montana nebraska nevada ohio oklahoma oregon pennsylvania tennessee texas utah vermont virginia washington "
    "wisconsin wyoming"
).split() + ["new hampshire", "new jersey", "new mexico", "new york", "north carolina", "north dakota",
             "rhode island", "south carolina", "south dakota", "west virginia", "district of columbia"]
_US_STATE_CODES = (
    "AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA "
    "RI SC SD TN TX UT VT VA WA WV WI WY DC"
).split()

COUNTRY_ALIASES: dict[str, list[str]] = {
    "US": ["united states", "united states of america", "usa", "us", "u s", "u s a", "america",
           "san francisco", "sf", "bay area", "nyc", "seattle", "austin", "boston", "chicago", "los angeles",
           "denver", "atlanta", "miami", "portland", "san jose", "palo alto", "mountain view", "menlo park",
           "sunnyvale", "brooklyn", "philadelphia", "pittsburgh", "dallas", "houston", "san diego", *_US_STATES],
    "CA": ["canada", "toronto", "vancouver", "montreal", "ottawa", "calgary", "waterloo", "ontario", "quebec", "british columbia"],
    "GB": ["united kingdom", "uk", "u k", "great britain", "britain", "england", "scotland", "wales", "london",
           "manchester", "edinburgh", "cambridge uk", "bristol"],
    "IE": ["ireland", "dublin", "cork"],
    "IN": ["india", "bangalore", "bengaluru", "mumbai", "bombay", "delhi", "new delhi", "ncr", "gurgaon", "gurugram",
           "noida", "hyderabad", "pune", "chennai", "kolkata", "ahmedabad", "karnataka", "maharashtra", "telangana"],
    "DE": ["germany", "deutschland", "berlin", "munich", "munchen", "hamburg", "frankfurt", "cologne"],
    "FR": ["france", "paris", "lyon"],
    "NL": ["netherlands", "the netherlands", "holland", "amsterdam", "rotterdam", "utrecht"],
    "ES": ["spain", "madrid", "barcelona"],
    "PT": ["portugal", "lisbon", "porto"],
    "IT": ["italy", "milan", "rome"],
    "PL": ["poland", "warsaw", "krakow"],
    "SE": ["sweden", "stockholm"],
    "DK": ["denmark", "copenhagen"],
    "NO": ["norway", "oslo"],
    "FI": ["finland", "helsinki"],
    "CH": ["switzerland", "zurich", "geneva"],
    "AT": ["austria", "vienna"],
    "BE": ["belgium", "brussels"],
    "SG": ["singapore"],
    "AU": ["australia", "sydney", "melbourne", "brisbane"],
    "NZ": ["new zealand", "auckland"],
    "JP": ["japan", "tokyo"],
    "KR": ["south korea", "korea", "seoul"],
    "BR": ["brazil", "brasil", "sao paulo"],
    "MX": ["mexico", "mexico city"],
    "AR": ["argentina", "buenos aires"],
    "IL": ["israel", "tel aviv"],
    "AE": ["united arab emirates", "uae", "dubai", "abu dhabi"],
}
# More countries (+ a few hub cities) so jobs abroad are recognised as abroad; an unrecognised
# location is treated as "unknown" and passes the location filter, so gaps here leak jobs through.
_MORE_COUNTRIES: dict[str, list[str]] = {
    "RS": ["serbia", "belgrade", "novi sad"], "PH": ["philippines", "manila", "taguig", "makati", "cebu", "quezon city"],
    "CZ": ["czech republic", "czechia", "prague", "brno"], "SK": ["slovakia", "bratislava"], "HU": ["hungary", "budapest"],
    "RO": ["romania", "bucharest", "cluj"], "BG": ["bulgaria", "sofia"], "GR": ["greece", "athens"], "HR": ["croatia", "zagreb"],
    "SI": ["slovenia", "ljubljana"], "UA": ["ukraine", "kyiv", "kiev", "lviv"], "EE": ["estonia", "tallinn"],
    "LV": ["latvia", "riga"], "LT": ["lithuania", "vilnius"], "LU": ["luxembourg"], "TR": ["turkey", "turkiye", "istanbul", "ankara"],
    "CY": ["cyprus", "limassol"], "MT": ["malta"], "IS": ["iceland", "reykjavik"],
    "CN": ["china", "beijing", "shanghai", "shenzhen", "hangzhou"], "HK": ["hong kong"], "TW": ["taiwan", "taipei"],
    "MY": ["malaysia", "kuala lumpur"], "TH": ["thailand", "bangkok"], "VN": ["vietnam", "ho chi minh", "hanoi"],
    "ID": ["indonesia", "jakarta"], "PK": ["pakistan", "karachi", "lahore", "islamabad"], "BD": ["bangladesh", "dhaka"],
    "LK": ["sri lanka", "colombo"], "NP": ["nepal", "kathmandu"],
    "SA": ["saudi arabia", "riyadh", "jeddah"], "QA": ["qatar", "doha"], "KW": ["kuwait"], "BH": ["bahrain"], "OM": ["oman"],
    "EG": ["egypt", "cairo"], "MA": ["morocco", "casablanca"], "NG": ["nigeria", "lagos"], "KE": ["kenya", "nairobi"],
    "ZA": ["south africa", "cape town", "johannesburg"], "GH": ["ghana", "accra"],
    "CO": ["colombia", "bogota", "medellin"], "CL": ["chile", "santiago"], "PE": ["peru", "lima"], "UY": ["uruguay", "montevideo"],
    "CR": ["costa rica", "san jose costa rica"],
}
for _code, _names in _MORE_COUNTRIES.items():
    COUNTRY_ALIASES.setdefault(_code, []).extend(_names)
COUNTRY_ALIASES["IN"].extend([
    "coimbatore", "kochi", "cochin", "trivandrum", "thiruvananthapuram", "jaipur", "indore", "chandigarh", "mohali",
    "nagpur", "lucknow", "bhubaneswar", "vizag", "visakhapatnam", "mysore", "mysuru", "gujarat", "kerala", "tamil nadu",
    "uttar pradesh", "haryana", "west bengal", "andhra pradesh", "rajasthan", "punjab india", "goa",
])
_EU = {"IE", "DE", "FR", "NL", "ES", "PT", "IT", "PL", "SE", "DK", "FI", "AT", "BE"}
REGION_ALIASES: dict[str, set[str]] = {
    "europe": _EU | {"GB", "CH", "NO"},
    "emea": _EU | {"GB", "CH", "NO", "IL", "AE"},
    "eu": _EU,
    "apac": {"IN", "SG", "AU", "NZ", "JP", "KR"},
    "asia": {"IN", "SG", "JP", "KR"},
    "north america": {"US", "CA", "MX"},
    "americas": {"US", "CA", "MX", "BR", "AR"},
    "latam": {"MX", "BR", "AR"},
    "latin america": {"MX", "BR", "AR"},
}
_GLOBAL = re.compile(r"\b(anywhere|worldwide|global(ly)?|international|any location)\b", re.I)
_CITY_SYNONYMS = [{"bangalore", "bengaluru"}, {"gurgaon", "gurugram"}, {"bombay", "mumbai"}, {"new york", "nyc"},
                  {"san francisco", "sf"}, {"delhi", "new delhi", "ncr"}, {"munich", "munchen"}]
_STATE_CODE_RE = re.compile(r",\s*(" + "|".join(_US_STATE_CODES) + r")\b")


def infer_countries(text: str | None) -> tuple[set[str], bool]:
    """``(ISO country codes mentioned, is_global)`` for a location string."""
    if not text:
        return set(), False
    is_global = bool(_GLOBAL.search(text))
    n = _norm(text)
    found: set[str] = set()
    for code, aliases in COUNTRY_ALIASES.items():
        if any(_has_phrase(n, a) for a in aliases):
            found.add(code)
    for region, codes in REGION_ALIASES.items():
        if _has_phrase(n, region):
            found |= codes
    if _STATE_CODE_RE.search(text):
        found.add("US")
    return found, is_global


def _city_variants(loc_norm: str) -> set[str]:
    for group in _CITY_SYNONYMS:
        if loc_norm in group:
            return set(group)
    return {loc_norm}


#: Country *names* (no cities): a user location equal to one of these means "anywhere in it".
COUNTRY_NAMES: dict[str, set[str]] = {
    "US": {"united states", "united states of america", "usa", "us", "u s", "u s a", "america"},
    "CA": {"canada"}, "GB": {"united kingdom", "uk", "u k", "great britain", "britain", "england", "scotland", "wales"},
    "IE": {"ireland"}, "IN": {"india"}, "DE": {"germany", "deutschland"}, "FR": {"france"},
    "NL": {"netherlands", "the netherlands", "holland"}, "ES": {"spain"}, "PT": {"portugal"}, "IT": {"italy"},
    "PL": {"poland"}, "SE": {"sweden"}, "DK": {"denmark"}, "NO": {"norway"}, "FI": {"finland"},
    "CH": {"switzerland"}, "AT": {"austria"}, "BE": {"belgium"}, "SG": {"singapore"}, "AU": {"australia"},
    "NZ": {"new zealand"}, "JP": {"japan"}, "KR": {"south korea", "korea"}, "BR": {"brazil", "brasil"},
    "MX": {"mexico"}, "AR": {"argentina"}, "IL": {"israel"}, "AE": {"united arab emirates", "uae"},
}


def _is_country_or_region(user_loc: str) -> bool:
    n = _norm(user_loc)
    return any(n in names for names in COUNTRY_NAMES.values()) or n in REGION_ALIASES


def location_matches(job_location: str, user_location: str) -> bool:
    """User location (city / country / region) vs one job location string."""
    jn = _norm(job_location)
    un = _norm(user_location)
    if not un:
        return True
    if any(_has_phrase(jn, v) for v in _city_variants(un)):
        return True
    if _is_country_or_region(user_location):
        user_c, _ = infer_countries(user_location)
        job_c, _ = infer_countries(job_location)
        return bool(user_c & job_c)
    return False


def job_locations(job: Job) -> list[str]:
    locs = [job.location] if job.location else []
    raw = job.raw or {}
    for key in ("secondary_locations", "all_locations", "offices"):
        for v in raw.get(key) or []:
            if isinstance(v, str) and v and v not in locs:
                locs.append(v)
    return locs


# ---- seniority ----------------------------------------------------------------------

_SEN_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("intern", re.compile(r"\b(intern|internship|co ?op|apprentice(ship)?|working student)\b")),
    ("executive", re.compile(r"\b(vp|vice president|director|head of|chief|cto|ceo|cfo|svp|evp)\b")),
    (Seniority.PRINCIPAL.value, re.compile(r"\b(principal|distinguished|fellow)\b")),
    (Seniority.STAFF.value, re.compile(r"\bstaff\b")),
    (Seniority.SENIOR.value, re.compile(r"\b(senior|sr)\b")),
    (Seniority.JUNIOR.value, re.compile(r"\b(junior|jr|entry level|graduate|new grad|associate)\b")),
]


def infer_seniority(title: str) -> str | None:
    """Seniority level implied by a title: a :class:`Seniority` value, ``intern``,
    ``executive`` or None (no signal, e.g. plain "Backend Engineer")."""
    t = _norm(title)
    for level, pat in _SEN_PATTERNS:
        if pat.search(t):
            return level
    if re.search(r"\b(engineer|developer|scientist|analyst) (i|1)\b", t):
        return Seniority.JUNIOR.value
    if re.search(r"\b(engineer|developer|scientist|analyst) (ii|2)\b", t):
        return Seniority.MID.value
    return None


def _seniority_reason(title: str, wanted: Iterable[Seniority]) -> str | None:
    wanted_vals = {Seniority(s).value for s in wanted}
    if not wanted_vals:
        return None
    level = infer_seniority(title)
    if level is None:
        return None
    if level == "executive":
        return None if Seniority.PRINCIPAL.value in wanted_vals else "seniority_mismatch:executive"
    if level not in wanted_vals:
        return f"seniority_mismatch:{level}"
    return None


# ---- industries / sponsorship -------------------------------------------------------

INDUSTRY_SYNONYMS: dict[str, list[str]] = {
    "crypto": ["crypto", "cryptocurrency", "blockchain", "web3", "defi", "nft", "bitcoin", "ethereum"],
    "gambling": ["gambling", "casino", "betting", "sportsbook", "igaming", "wagering"],
    "defense": ["defense", "defence", "military", "weapons", "munitions"],
    "tobacco": ["tobacco", "vaping", "nicotine"],
    "adtech": ["adtech", "ad tech", "advertising technology", "programmatic advertising"],
    "oil and gas": ["oil and gas", "petroleum", "upstream oil"],
}

_NEG = r"(?:unable|not able|cannot|can ?not|can't|will not|won't|do not|does not|don't|are not able|is not able)"
# Every alternative contains the sponsorship noun/verb itself, so a refusal of something
# else ("we do not offer relocation") next to an OFFER of sponsorship never matches.
_NO_SPONSOR_RE = re.compile(
    rf"\b{_NEG}\s+(?:to\s+)?(?:currently\s+)?(?:offer|provide|support)\s+(?:any\s+)?"
    r"(?:(?:h-?1b|visa|immigration|work|employment|employer)\s+)*(?:visa\s+)?sponsor(?:ship|ing)?\b"
    rf"|\b{_NEG}\s+(?:to\s+)?(?:currently\s+)?sponsor\b"
    r"|\bwithout\s+(?:the\s+need\s+for\s+)?(?:current\s+or\s+future\s+)?(?:(?:visa|employer|immigration|work)\s+)?sponsorship"
    r"|\bno\s+(?:(?:visa|immigration|h-?1b)\s+)?sponsorship"
    r"|\bsponsorship\s+(?:is\s+|will\s+)?not\s+(?:be\s+)?(?:available|offered|provided|possible)"
    r"|\bnot\s+(?:eligible|able)\s+to\s+sponsor",
    re.I,
)


def jd_refuses_sponsorship(text: str | None) -> bool:
    """True when the job description explicitly refuses visa sponsorship."""
    if not text:
        return False
    return _NO_SPONSOR_RE.search(text) is not None


def _needs_sponsorship_for(countries: set[str], never_guess: NeverGuess, preferences: Preferences) -> bool:
    """True only when the stored facts say the user needs sponsorship in (one of) the
    job's countries. Unknown -> False (the never-guess question gets asked at apply time)."""
    def requires(status: str) -> bool:
        s = status.lower()
        return ("sponsor" in s or "visa" in s or "requires" in s) and not re.search(r"\b(not|no|without)\b.*(sponsor|required)", s)

    wa = {k.strip().upper(): v for k, v in (never_guess.work_auth or {}).items()}
    if countries:
        statuses = []
        for c in countries:
            st = wa.get(c)
            if st is None:
                for k, v in wa.items():  # keys may be country names
                    kc, _ = infer_countries(k)
                    if c in kc:
                        st = v
                        break
            if st is not None:
                statuses.append(st)
        if statuses:
            return all(requires(s) for s in statuses)
    if never_guess.sponsorship and requires(never_guess.sponsorship):
        return True
    summary = preferences.work_auth_summary or ""
    if summary and re.search(r"(needs?|requires?)\s+(\w+\s+){0,3}sponsorship", summary, re.I):
        mentioned, _ = infer_countries(summary)
        return not countries or not mentioned or bool(mentioned & countries)
    return False


# =====================================================================================
# Hard filters
# =====================================================================================


def hard_filter(
    conn: sqlite3.Connection,
    job: Job,
    company: Company,
    preferences: Preferences,
    *,
    never_guess: NeverGuess | None = None,
    now: datetime | None = None,
    check_daily_cap: bool = False,
) -> str | None:
    """Return a skip reason if the job fails a hard filter (excludes, seniority keywords,
    location/remote, work auth, salary floor, cooldown, optionally the daily cap), else None.
    No LLM calls."""
    from autoapply import db

    p = preferences
    company_n = _norm(company.name)
    desc = job.description or ""
    text_n = _norm(f"{job.title}\n{desc}")

    # 1. excluded companies
    for ex in p.exclude_companies:
        exn = _norm(ex)
        if exn and (exn == company_n or _has_phrase(company_n, exn)):
            return SKIP_EXCLUDED_COMPANY

    # 2. excluded keywords (title + description)
    for kw in p.exclude_keywords:
        if kw.strip() and _has_phrase(text_n, kw):
            return f"excluded_keyword:{kw.strip().lower()}"

    # 2b. another discipline's job ("Electrical Engineer" for a software resume that targets "Engineering")
    from autoapply.role_focus import current as role_focus, off_field

    hit = off_field(job.title, role_focus(conn, p))
    if hit:
        return f"{SKIP_OFF_FIELD}:{hit}"

    # 3. excluded industries (synonym-expanded; title + description + company name)
    hay = f"{company_n} {text_n}"
    for ind in p.exclude_industries:
        key = _norm(ind)
        terms = INDUSTRY_SYNONYMS.get(key, [ind])
        if any(_has_phrase(hay, t) for t in terms):
            return f"excluded_industry:{ind.strip().lower()}"

    # 4. seniority keywords in the title
    reason = _seniority_reason(job.title, p.seniority)
    if reason:
        return reason

    # 5. remote policy + location (profile location = country fallback when none are set)
    reason = _location_reason(job, p, home=db.get_profile(conn).location)
    if reason:
        return reason

    # 6. work authorisation (JD explicitly refuses sponsorship and the user needs it)
    if jd_refuses_sponsorship(desc):
        ng = never_guess if never_guess is not None else db.get_never_guess(conn)
        countries: set[str] = set()
        for loc in job_locations(job):
            countries |= infer_countries(loc)[0]
        if _needs_sponsorship_for(countries, ng, p):
            return SKIP_NO_SPONSORSHIP

    # 7. salary floor
    if p.salary_floor is not None:
        top = job.salary_max if job.salary_max is not None else job.salary_min
        same_currency = job.salary_currency is None or job.salary_currency.upper() == p.salary_currency.upper()
        if top is not None and same_currency and top < p.salary_floor:
            return SKIP_SALARY
    if p.hide_without_salary and job.salary_min is None and job.salary_max is None:
        return SKIP_MISSING_SALARY

    # 8. per-company cooldown
    if db.company_in_cooldown(conn, company.id, p.per_company_cooldown_days, now):
        return SKIP_COOLDOWN

    # 9. daily cap (deferral, opt-in)
    if check_daily_cap and db.submitted_today(conn, now) >= p.daily_cap:
        return SKIP_DAILY_CAP
    return None


def _location_reason(job: Job, p: Preferences, home: str | None = None) -> str | None:
    """``home`` (the profile location) stands in when no preferred locations are set: then only the
    country is enforced, so a Bangalore-based user isn't sent US-only onsite or "Remote - US" roles."""
    locs = job_locations(job)
    policy = RemotePolicy(job.remote) if job.remote else infer_remote(*(locs or [None]), job.title)
    allowed = set(p.remote_policy)
    if policy is not None and allowed and policy not in allowed:
        return f"remote_policy:{policy.value}"
    user_locs = [loc for loc in p.locations if _norm(loc) not in ("", "remote", "anywhere", "worldwide")]
    if not user_locs and home and locs:
        home_c = infer_countries(home)[0]
        if home_c:
            job_c: set[str] = set()
            any_global = False
            for loc in locs:
                c, g = infer_countries(loc)
                job_c |= c
                any_global = any_global or g
            if any_global or not job_c or job_c & home_c:
                return None
            return SKIP_LOCATION
    if not user_locs or not locs:
        return None
    if policy is RemotePolicy.REMOTE:
        user_c: set[str] = set()
        for ul in user_locs:
            user_c |= infer_countries(ul)[0]
        job_c: set[str] = set()
        any_global = False
        for loc in locs:
            c, g = infer_countries(loc)
            job_c |= c
            any_global = any_global or g
        if any_global or not job_c or not user_c:
            return None
        return None if job_c & user_c else SKIP_LOCATION
    if any(location_matches(loc, ul) for loc in locs for ul in user_locs):
        return None
    return SKIP_LOCATION


# =====================================================================================
# LLM scoring
# =====================================================================================

SCORE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["results"],
    "properties": {
        "results": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["job_id", "score", "summary", "factors"],
                "properties": {
                    "job_id": {"type": "integer"},
                    "score": {"type": "integer", "minimum": 0, "maximum": 100},
                    "summary": {"type": "string", "maxLength": 400},
                    "factors": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["skills", "seniority", "role", "domain"],
                        "properties": {
                            k: {"type": "integer", "minimum": 0, "maximum": 100}
                            for k in ("skills", "seniority", "role", "domain")
                        },
                    },
                    "concerns": {"type": "array", "items": {"type": "string", "maxLength": 200}, "maxItems": 5},
                },
            },
        }
    },
}

SCORE_SYSTEM = (
    "You are a meticulous, honest technical recruiter. Score how well each job matches the "
    "candidate on a 0-100 scale (90+ exceptional fit, 70-89 strong, 50-69 partial, <50 poor). "
    "Judge only from the candidate profile and the job text given; never assume skills that are "
    "not stated. Factors are 0-100: skills (required skills overlap), seniority (level fit), role "
    "(target-role fit), domain (industry/product familiarity). Read the target roles as the candidate "
    "means them given their background: a job in a different discipline that merely shares a word "
    "(e.g. electrical, industrial or sales engineering for a software/AI candidate) is a poor fit, "
    "under 30, whatever its title. Return one result per job_id."
)


def _profile_brief(profile: Profile, preferences: Preferences) -> dict[str, Any]:
    return {
        "headline": profile.headline,
        "summary": (profile.summary or "")[:1200] or None,
        "years_experience": profile.years_experience,
        "skills": profile.skills[:60],
        "recent_roles": [
            {"title": w.title, "company": w.company, "start": w.start, "end": w.end, "highlights": w.highlights[:3]}
            for w in profile.work_history[:4]
        ],
        "education": [{"school": e.school, "degree": e.degree, "field": e.field} for e in profile.education[:2]],
        "target_roles": preferences.roles,
        "target_seniority": [Seniority(s).value for s in preferences.seniority],
    }


def build_score_prompt(profile: Profile, preferences: Preferences, batch: list[tuple[Job, Company]], *, max_desc_chars: int = 3000) -> str:
    jobs = []
    for job, company in batch:
        jobs.append(
            {
                "job_id": job.id,
                "company": company.name,
                "title": job.title,
                "location": job.location,
                "remote": job.remote.value if job.remote else None,
                "salary": [job.salary_min, job.salary_max, job.salary_currency] if (job.salary_min or job.salary_max) else None,
                "description": (job.description or "")[:max_desc_chars],
            }
        )
    return (
        "Candidate profile:\n" + json.dumps(_profile_brief(profile, preferences), ensure_ascii=False)
        + f"\n\nScore these {len(jobs)} jobs:\n" + json.dumps(jobs, ensure_ascii=False)
    )


async def score_jobs(
    llm: LLMProvider,
    *,
    profile: Profile,
    preferences: Preferences,
    jobs: list[tuple[Job, Company]],
    batch_size: int = 8,
    max_desc_chars: int = 3000,
) -> list[ScoreResult]:
    """LLM match scores for jobs that survived hard filters. Applies
    ``preferences.match_threshold`` (score < threshold -> skip_reason 'below_threshold').

    Batches of ``batch_size`` jobs share one call; a batch that fails or omits jobs is
    retried job-by-job once. Jobs that still fail get ``score=None`` and ``error`` set.
    Results are returned in input order.
    """
    results: dict[int, ScoreResult] = {}

    async def run_batch(batch: list[tuple[Job, Company]], *, allow_split: bool) -> None:
        prompt = build_score_prompt(profile, preferences, batch, max_desc_chars=max_desc_chars)
        try:
            res = await llm.complete(prompt, system=SCORE_SYSTEM, schema=SCORE_SCHEMA, max_tokens=300 + 220 * len(batch))
        except LLMError as e:
            if allow_split and len(batch) > 1:
                for item in batch:
                    await run_batch([item], allow_split=False)
                return
            for job, _ in batch:
                results[job.id] = ScoreResult(job_id=job.id, score=None, error=f"llm: {e}")
            return
        ids = {job.id for job, _ in batch}
        got: dict[int, dict[str, Any]] = {}
        for r in (res.data or {}).get("results", []):
            if r.get("job_id") in ids and r["job_id"] not in got:
                got[r["job_id"]] = r
        missing = [item for item in batch if item[0].id not in got]
        n = max(1, len(got))
        tin, tout = res.usage.input_tokens, res.usage.output_tokens
        for i, (jid, r) in enumerate(got.items()):
            score = max(0, min(100, int(r["score"])))
            results[jid] = ScoreResult(
                job_id=jid,
                score=score,
                reasons={"summary": r.get("summary", ""), "factors": r.get("factors", {}), "concerns": r.get("concerns", [])},
                skip_reason=SKIP_BELOW_THRESHOLD if score < preferences.match_threshold else None,
                tokens_in=tin // n + (tin % n if i == 0 else 0),
                tokens_out=tout // n + (tout % n if i == 0 else 0),
                model=res.model,
            )
        if missing:
            if allow_split and len(batch) > 1:
                for item in missing:
                    await run_batch([item], allow_split=False)
            else:
                for job, _ in missing:
                    results[job.id] = ScoreResult(job_id=job.id, score=None, error="llm: job missing from response")

    size = max(1, batch_size)
    for i in range(0, len(jobs), size):
        await run_batch(jobs[i : i + size], allow_split=True)
    return [results[job.id] for job, _ in jobs]


# =====================================================================================
# The scoring step of a run
# =====================================================================================

EmitFn = Callable[[str, Any], Awaitable[None]]


@dataclass(slots=True)
class ScoringReport:
    results: list[ScoreResult] = field(default_factory=list)
    queued: list[int] = field(default_factory=list)  # application ids
    skipped: list[int] = field(default_factory=list)
    deferred: list[int] = field(default_factory=list)
    errors: list[int] = field(default_factory=list)
    tokens_in: int = 0
    tokens_out: int = 0


async def score_pending(
    conn: sqlite3.Connection,
    llm: LLMProvider,
    *,
    application_ids: list[int] | None = None,
    emit: EmitFn | None = None,
    run_id: str | None = None,
    batch_size: int = 8,
    now: datetime | None = None,
) -> ScoringReport:
    """Score every ``discovered`` application (or the given ids that are ``discovered``)."""
    from autoapply import db

    prefs = db.get_preferences(conn)
    profile = db.get_profile(conn)
    never_guess = db.get_never_guess(conn)
    run_db_id = db.get_run(conn, run_id).id if run_id else None
    apps = db.list_applications(conn, states=[AppState.DISCOVERED])
    if application_ids is not None:
        wanted = set(application_ids)
        apps = [a for a in apps if a.id in wanted]
    report = ScoringReport()

    async def _emit(payload: JobScoredPayload) -> None:
        if emit is None:
            return
        try:
            await emit("job_scored", payload)
        except Exception:  # an observer must never break scoring
            log.exception("emit job_scored failed")

    survivors: list[tuple[Job, Company]] = []
    app_by_job: dict[int, int] = {}
    for app in apps:
        job = db.get_job(conn, app.job_id)
        company = db.get_company(conn, job.company_id)
        reason = hard_filter(conn, job, company, prefs, never_guess=never_guess, now=now)
        if reason is None:
            survivors.append((job, company))
            app_by_job[job.id] = app.id
            continue
        if is_deferral(reason):
            report.deferred.append(app.id)
            continue
        db.upsert_score(conn, job.id, score=None, reasons={"hard_filter": reason}, skip_reason=reason)
        db.transition(conn, app.id, AppState.SKIPPED, reason=reason, expected_from=AppState.DISCOVERED, run_id=run_db_id)
        report.skipped.append(app.id)
        report.results.append(ScoreResult(job_id=job.id, score=None, reasons={"hard_filter": reason}, skip_reason=reason))
        await _emit(JobScoredPayload(job_id=job.id, application_id=app.id, score=None, reasons={"hard_filter": reason},
                                     skip_reason=reason, queued=False, run_id=run_id))

    if survivors:
        scored = await score_jobs(llm, profile=profile, preferences=prefs, jobs=survivors, batch_size=batch_size)
        for res in scored:
            app_id = app_by_job[res.job_id]
            report.results.append(res)
            report.tokens_in += res.tokens_in
            report.tokens_out += res.tokens_out
            if res.error is not None:
                report.errors.append(app_id)
                db.log_event(conn, "score", f"scoring failed: {res.error}", level="warning", job_id=res.job_id,
                             application_id=app_id, run_id=run_db_id)
                continue
            db.upsert_score(conn, res.job_id, score=res.score, reasons=res.reasons, skip_reason=res.skip_reason,
                            model=res.model, tokens_in=res.tokens_in, tokens_out=res.tokens_out)
            with db.transaction(conn):
                db.transition(conn, app_id, AppState.SCORED, reason=f"score {res.score}", expected_from=AppState.DISCOVERED, run_id=run_db_id)
                if res.skip_reason:
                    db.transition(conn, app_id, AppState.SKIPPED, reason=res.skip_reason, run_id=run_db_id)
                else:
                    db.transition(conn, app_id, AppState.QUEUED, reason=f"score {res.score}", run_id=run_db_id)
            db.add_application_tokens(conn, app_id, res.tokens_in, res.tokens_out)
            (report.skipped if res.skip_reason else report.queued).append(app_id)
            await _emit(JobScoredPayload(job_id=res.job_id, application_id=app_id, score=res.score, reasons=res.reasons,
                                         skip_reason=res.skip_reason, queued=res.skip_reason is None, run_id=run_id))
    return report
