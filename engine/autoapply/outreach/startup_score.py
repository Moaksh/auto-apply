"""The startup score (0-100) and the rank it makes with the fit score. Pure and deterministic.

Six components, each with a plain-English reason (``Component.reason``):

============================  =====  ==========================================================
component                      max   points
============================  =====  ==========================================================
funding recency                 25   last round <=3 months ago 25, <=6 20, <=12 13, <=24 6, older 0
round stage / size              20   Series A 20, seed 17, Series B 16, pre-seed 12, Series C 11,
                                     D+ / other 6; no stage but an amount: <$1M 10, <$5M 15,
                                     <$25M 18, <$100M 12, more 6
investors                       15   2+ well-known 15, 1 well-known 10, only others 3
YC backing                      15   a YC batch in the last 3 years 15, older 10
team size                       10   10-200 people 10, 1-9 6, 201-500 6, more 2
open roles for you              15   3+ matching roles 15, 1-2 12; hiring but none match 6;
                                     YC says hiring (roles unknown) 9; roles known, none 3;
                                     YC says not hiring 0
============================  =====  ==========================================================

Fresh money tends to mean hiring, Series A/seed teams hire generalists and still answer cold
email, and a matching open role is the strongest signal of all. A component whose input is
unknown scores 0 and is marked ``known = False``: missing data lowers ``confidence`` (the share
of the 100 points whose input is known) and never gets a guessed value.

Rank: ``round(0.6 * startup + 0.4 * fit)``; the fit alone when nothing is known about the
company (confidence 0); the startup score alone when the fit was never rated.

``NOTABLE_INVESTORS`` is a heuristic: a short, hand-picked list of widely known investors and
accelerators per region. Missing from it says nothing bad about an investor.
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from datetime import date

from autoapply.enums import FundingStage
from autoapply.models import CompanyFacts

#: Hand-picked, well-known investors and accelerators (a heuristic, see the module docstring).
NOTABLE_INVESTORS: dict[str, tuple[str, ...]] = {
    "India": (
        "Peak XV", "Sequoia Capital India", "Accel", "Lightspeed", "Elevation Capital", "Matrix Partners", "Z47",
        "Blume Ventures", "Kalaari Capital", "Nexus Venture Partners", "Chiratae Ventures", "Stellaris Venture Partners",
        "India Quotient", "3one4 Capital", "Info Edge Ventures", "Lightbox", "Speciale Invest", "Together Fund",
        "Arkam Ventures", "Fireside Ventures", "Prime Venture Partners", "Antler",
    ),
    "*": (
        "Y Combinator", "Sequoia", "Andreessen Horowitz", "a16z", "Accel", "Benchmark", "Index Ventures", "Lightspeed",
        "General Catalyst", "Greylock", "Kleiner Perkins", "Founders Fund", "Khosla Ventures", "Insight Partners",
        "Tiger Global", "SoftBank", "Google Ventures", "Bessemer", "First Round", "Techstars", "500 Global", "Balderton",
        "Atomico", "Northzone", "LocalGlobe", "Seedcamp", "Entrepreneur First", "Coatue", "Thrive Capital", "Redpoint",
        "Felicis", "Union Square Ventures", "SV Angel", "Prosus",
    ),
}

STAGE_LABEL: dict[FundingStage, str] = {
    FundingStage.PRE_SEED: "pre-seed", FundingStage.SEED: "seed", FundingStage.SERIES_A: "Series A",
    FundingStage.SERIES_B: "Series B", FundingStage.SERIES_C: "Series C", FundingStage.SERIES_D_PLUS: "Series D+",
    FundingStage.OTHER: "funding",
}
_STAGE_POINTS: dict[FundingStage, int] = {
    FundingStage.SERIES_A: 20, FundingStage.SEED: 17, FundingStage.SERIES_B: 16, FundingStage.PRE_SEED: 12,
    FundingStage.SERIES_C: 11, FundingStage.SERIES_D_PLUS: 6, FundingStage.OTHER: 6,
}
_BATCH = re.compile(r"^([WSXF])(\d{2})$")
_BATCH_MONTH = {"W": 1, "X": 4, "S": 6, "F": 9}
_BATCH_SEASON = {"W": "Winter", "X": "Spring", "S": "Summer", "F": "Fall"}

FIT_WEIGHT = 0.4


@dataclass(slots=True)
class Component:
    key: str
    label: str
    points: int
    max: int
    reason: str
    known: bool


@dataclass(slots=True)
class StartupScore:
    score: int
    confidence: int
    components: list[Component]

    def reasons(self) -> list[dict]:
        return [asdict(c) for c in self.components]


# ---- formatting -----------------------------------------------------------------------------


def _num(v: float) -> str:
    s = f"{v:.1f}".rstrip("0").rstrip(".")
    return s


def money(amount: float | None, currency: str | None, usd: float | None = None) -> str | None:
    """'$4M', '₹35 crore (~$4.2M)', '€3M (~$3.2M)'."""
    def usd_text(v: float) -> str:
        if v >= 1e9:
            return f"${_num(v / 1e9)}B"
        if v >= 1e6:
            return f"${_num(v / 1e6)}M"
        if v >= 1e3:
            return f"${_num(v / 1e3)}K"
        return f"${int(v)}"

    if amount is None:
        return usd_text(usd) if usd is not None else None
    cur = (currency or "USD").upper()
    if cur == "USD":
        return usd_text(amount)
    if cur == "INR":
        base = f"₹{_num(amount / 1e7)} crore" if amount >= 1e7 else f"₹{_num(amount / 1e5)} lakh"
    else:
        sym = {"EUR": "€", "GBP": "£"}.get(cur)
        if amount >= 1e6:
            base = f"{sym}{_num(amount / 1e6)}M" if sym else f"{_num(amount / 1e6)}M {cur}"
        else:
            base = f"{sym}{_num(amount / 1e3)}K" if sym else f"{_num(amount / 1e3)}K {cur}"
    return f"{base} (~{usd_text(usd)})" if usd is not None else base


def batch_date(batch: str | None) -> date | None:
    m = _BATCH.match((batch or "").strip().upper())
    return date(2000 + int(m.group(2)), _BATCH_MONTH[m.group(1)], 1) if m else None


def batch_label(batch: str | None) -> str | None:
    m = _BATCH.match((batch or "").strip().upper())
    return f"{_BATCH_SEASON[m.group(1)]} 20{m.group(2)}" if m else None


def _months_between(earlier: date, later: date) -> int:
    return max(0, (later.year - earlier.year) * 12 + (later.month - earlier.month) - (1 if later.day < earlier.day else 0))


def _ago(months: int) -> str:
    if months <= 0:
        return "this month"
    if months == 1:
        return "a month ago"
    if months < 24:
        return f"{months} months ago"
    return f"{months // 12} years ago"


def _parse_date(s: str | None) -> date | None:
    if not s:
        return None
    m = re.match(r"^(\d{4})-(\d{2})(?:-(\d{2}))?", s)
    if not m:
        return None
    try:
        return date(int(m.group(1)), int(m.group(2)), int(m.group(3) or 1))
    except ValueError:
        return None


def _norm(s: str) -> str:
    return " " + re.sub(r"[^a-z0-9]+", " ", s.lower()).strip() + " "


def notable_investors(investors: list[str], region: str | None) -> list[str]:
    """The investors in ``investors`` that are on the curated list for ``region`` (or the global one)."""
    names = [*NOTABLE_INVESTORS.get(region or "", ()), *NOTABLE_INVESTORS["*"]]
    out: list[str] = []
    for inv in investors:
        n = _norm(inv)
        if any(_norm(x) in n for x in names) and inv not in out:
            out.append(inv)
    return out


def _article(word: str) -> str:
    """'a' or 'an' as the word is spoken ("an $8M", "an 11", "a seed", "a Series A")."""
    w = word.lstrip("$₹€£")
    if re.match(r"(8|11|18)(\D|$)", w) or re.match(r"8\d", w):
        return "an"
    return "an" if w[:1].lower() in "aeio" else "a"


def _join(names: list[str]) -> str:
    if len(names) <= 1:
        return "".join(names)
    return ", ".join(names[:-1]) + " and " + names[-1]


# ---- components -----------------------------------------------------------------------------


def _recency(f: CompanyFacts | None, today: date) -> Component:
    d = _parse_date(f.last_round_date) if f else None
    if d is None:
        return Component("recency", "Fresh funding", 0, 25, "I haven't found a dated funding round", False)
    months = _months_between(d, today)
    pts = 25 if months <= 3 else 20 if months <= 6 else 13 if months <= 12 else 6 if months <= 24 else 0
    amount = money(f.last_round_amount, f.last_round_currency, f.last_round_usd) if f else None
    stage = STAGE_LABEL.get(f.last_round_stage) if f and f.last_round_stage else None
    if amount and stage and stage != "funding":
        if amount.startswith("$"):
            what = f"{_article(amount)} {amount} {stage} round"
        else:
            what = f"{amount} in {_article(stage)} {stage} round"
    elif amount:
        what = amount
    elif stage and stage != "funding":
        what = f"{_article(stage)} {stage} round"
    else:
        what = "money"
    return Component("recency", "Fresh funding", pts, 25, f"Raised {what} {_ago(months)}", True)


def _stage(f: CompanyFacts | None) -> Component:
    if f and f.last_round_stage:
        pts = _STAGE_POINTS[f.last_round_stage]
        amount = money(f.last_round_amount, f.last_round_currency, f.last_round_usd)
        label = STAGE_LABEL[f.last_round_stage]
        reason = f"Last round: {label}" + (f" ({amount})" if amount else "")
        return Component("stage", "Round", pts, 20, reason[0].upper() + reason[1:], True)
    if f and f.last_round_usd is not None:
        usd = f.last_round_usd
        pts = 10 if usd < 1e6 else 15 if usd < 5e6 else 18 if usd < 25e6 else 12 if usd < 100e6 else 6
        return Component("stage", "Round", pts, 20, f"Last round: {money(f.last_round_amount, f.last_round_currency, usd)}", True)
    return Component("stage", "Round", 0, 20, "Round size and stage not known", False)


def _investors(f: CompanyFacts | None, region: str | None) -> Component:
    invs = list(f.investors) if f else []
    if not invs:
        return Component("investors", "Investors", 0, 15, "Investors not known", False)
    notable = notable_investors(invs, region)
    if len(notable) >= 2:
        return Component("investors", "Investors", 15, 15, f"Backed by {_join(notable[:3])}", True)
    if notable:
        return Component("investors", "Investors", 10, 15, f"Backed by {notable[0]}", True)
    return Component("investors", "Investors", 3, 15, f"Backed by {_join(invs[:3])}", True)


def _yc(f: CompanyFacts | None, today: date) -> Component:
    batch = f.yc_batch if f else None
    start = batch_date(batch)
    if not batch or start is None:
        return Component("yc", "Y Combinator", 0, 15, "No YC batch on record", False)
    pts = 15 if _months_between(start, today) <= 36 else 10
    return Component("yc", "Y Combinator", pts, 15, f"YC {batch.upper()}", True)


def _team(f: CompanyFacts | None) -> Component:
    n = f.team_size if f else None
    if n is None or n <= 0:
        return Component("team", "Team size", 0, 10, "Team size not known", False)
    if 10 <= n <= 200:
        return Component("team", "Team size", 10, 10, f"Team of {n}: small enough that founders still read email", True)
    if n < 10:
        return Component("team", "Team size", 6, 10, f"Team of {n}: very early, hiring is often founder-led", True)
    if n <= 500:
        return Component("team", "Team size", 6, 10, f"Team of {n}", True)
    return Component("team", "Team size", 2, 10, f"Team of {n}: a large company, cold email reaches fewer decision makers", True)


def _roles(f: CompanyFacts | None, matching_roles: int | None) -> Component:
    hiring = f.is_hiring if f else None
    if matching_roles is not None and matching_roles >= 3:
        return Component("roles", "Open roles for you", 15, 15, f"{matching_roles} open roles match yours", True)
    if matching_roles is not None and matching_roles >= 1:
        return Component("roles", "Open roles for you", 12, 15,
                         "1 open role matches yours" if matching_roles == 1 else f"{matching_roles} open roles match yours", True)
    if hiring is True and matching_roles == 0:
        return Component("roles", "Open roles for you", 6, 15, "Hiring, but no open role matches yours yet", True)
    if hiring is True:
        return Component("roles", "Open roles for you", 9, 15, "Listed as hiring on YC's directory", True)
    if hiring is False:
        return Component("roles", "Open roles for you", 0, 15, "Not hiring right now, per YC's directory", True)
    if matching_roles == 0:
        return Component("roles", "Open roles for you", 3, 15, "No open role matches yours right now", True)
    return Component("roles", "Open roles for you", 0, 15, "Open roles not known", False)


def score_startup(facts: CompanyFacts | None, *, matching_roles: int | None, today: date, region: str | None = None) -> StartupScore:
    comps = [_recency(facts, today), _stage(facts), _investors(facts, region or (facts.hq_country if facts else None)),
             _yc(facts, today), _team(facts), _roles(facts, matching_roles)]
    score = max(0, min(100, sum(c.points for c in comps)))
    confidence = sum(c.max for c in comps if c.known)
    return StartupScore(score, confidence, comps)


def rank(startup: StartupScore | None, fit_score: int | None) -> int | None:
    """The prospects list order: startup score and fit together (see the module docstring)."""
    if startup is None or startup.confidence == 0:
        return fit_score
    if fit_score is None:
        return startup.score
    return max(0, min(100, round((1 - FIT_WEIGHT) * startup.score + FIT_WEIGHT * fit_score)))


__all__ = ["Component", "NOTABLE_INVESTORS", "STAGE_LABEL", "StartupScore", "batch_date", "batch_label", "money",
           "notable_investors", "rank", "score_startup"]
