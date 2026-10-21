"""Posting legitimacy: deterministic scam / risk signals for a job.

Signals (presented as facts about the posting, never as an accusation):

* ``asks_candidate_to_pay``: the candidate is asked to pay (registration / training / security
  deposit / processing fee, "registration charges", "refundable deposit", ...). Negated mentions
  ("we never charge any fee") don't count. The classic scam: such a job is hard-skipped at scoring.
* ``personal_email_contact``: the only contact address is a free webmail one (gmail, yahoo, ...).
* ``agency_unnamed_employer``: a recruiter / agency posting for an unnamed client.
* ``repeated_reposts``: the same title (same set of title words) at the same company listed as
  separate postings on different days, :data:`REPOST_MIN_LISTINGS`+ times within
  :data:`REPOST_WINDOW_DAYS`. (``jobs`` dedupes on company + title + location, so an identical
  re-listing collapses into one row; what is counted are rows whose location / URL spelling changed.)
* ``vague_description``: a very short description with no responsibilities / requirements.

Levels: ``high`` = a fee ask, personal-email-only contact, or two+ other signals; ``caution`` =
any one other signal; ``none`` otherwise.

Behaviour (wired in :mod:`autoapply.pipeline`): ``high`` never auto-submits (forced to Review,
reason ``risk_review``); ``caution`` is only logged and kept on the job; a fee ask found at
scoring time skips the job (``asks_candidate_to_pay``).

The result lives in ``jobs.raw["risk"]`` = ``{"level", "signals": [{"code", "detail"}], "checked_at"}``
and is computed once per job.

The signal set (candidate-paid fees, agency with no employer named, repost pattern with a minimum
span and title identity, JD vagueness) follows career-ops (``modes/oferta-signals/21-candidate-paid-fees.md``,
``10-agency-licensing-check.md``, ``detect-reposts.mjs``), MIT License, Copyright (c) 2026 Santiago
Fernandez de Valderrama. See THIRD_PARTY_NOTICES.md.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

from autoapply import db
from autoapply.models import Company, Job, format_ts, utcnow

NONE = "none"
CAUTION = "caution"
HIGH = "high"

RAW_KEY = "risk"

SIG_FEE = "asks_candidate_to_pay"
SIG_PERSONAL_EMAIL = "personal_email_contact"
SIG_AGENCY = "agency_unnamed_employer"
SIG_REPOST = "repeated_reposts"
SIG_VAGUE = "vague_description"

#: Skip reason (hard filter) for a posting that asks the candidate to pay.
SKIP_ASKS_TO_PAY = SIG_FEE
#: Review reason for a high-risk posting that would otherwise have been auto-submitted.
REVIEW_REASON = "risk_review"

REPOST_WINDOW_DAYS = 30
REPOST_MIN_LISTINGS = 3
VAGUE_MAX_CHARS = 350

LABELS = {
    SIG_FEE: "asks you to pay a fee",
    SIG_PERSONAL_EMAIL: "contact is a personal email address",
    SIG_AGENCY: "agency posting, employer not named",
    SIG_REPOST: "re-posted repeatedly",
    SIG_VAGUE: "very vague description",
}


@dataclass(slots=True)
class Risk:
    level: str = NONE
    signals: list[dict[str, str]] = field(default_factory=list)
    checked_at: str = ""

    @property
    def codes(self) -> list[str]:
        return [s["code"] for s in self.signals]

    @property
    def asks_to_pay(self) -> bool:
        return SIG_FEE in self.codes

    def to_dict(self) -> dict[str, Any]:
        return {"level": self.level, "signals": list(self.signals), "checked_at": self.checked_at}

    def summary(self) -> str:
        return "; ".join(
            f"{LABELS.get(s['code'], s['code'])}" + (f' ("{s["detail"]}")' if s.get("detail") else "") for s in self.signals
        )


# =====================================================================================
# Signals
# =====================================================================================

_FEE_NOUN = r"(?:fees?|charges?|amount|deposit|payment)"
#: A request that the candidate pays. Matched per sentence; a negation in the sentence cancels it.
FEE_PATTERNS: tuple[re.Pattern[str], ...] = tuple(re.compile(p, re.I) for p in (
    rf"\bregistration {_FEE_NOUN}",
    r"\b(?:training|onboarding|joining|processing|documentation|verification|enrol?ment|admission|kit|uniform|"
    r"interview|placement|application|security|background[- ]check|admin(?:istrative)?|id card|medical) "
    r"(?:fees?|charges?|deposit)\b",
    r"\b(?:refundable|security|caution) (?:deposit|amount|money)\b",
    rf"\b(?:pay|deposit|remit|transfer) (?:a |the |an )?(?:one[- ]time |small |nominal |minimal |refundable )?{_FEE_NOUN}\b",
    r"\b(?:candidates?|applicants?|you) (?:will )?(?:has|have|need|needs|must|should|are required|is required|will be required) "
    r"(?:to )?(?:pay|deposit) (?:a |an |the |some )?(?:fees?|charges?|money|amount|deposit|rs\.?|inr|usd|\$|₹|"
    r"for (?:the )?(?:training|registration|kit|uniform))",
    r"\b(?:fees?|charges?|deposit) of (?:rs\.?|inr|usd|\$|₹) ?\d",
    r"\b(?:rs\.?|inr|₹) ?\d[\d,]* (?:only )?(?:as |towards |for )?(?:registration|training|deposit|processing|security|joining)\b",
))
#: Negation / employer-pays wording that turns a fee mention into a reassurance.
_FEE_NEGATION = re.compile(
    r"\b(?:no|not|never|don'?t|doesn'?t|do not|does not|won'?t|will not|zero|without|nil|free of (?:cost|charge)|"
    r"(?:we|company|employer) (?:will )?(?:pay|bear|cover|reimburse)s?|reimburs\w*|beware|fraud\w*|scam\w*|"
    r"collect|collects|collecting|tenants?|customers?)\b",  # the job's duties, not a candidate fee
    re.I,
)

FREE_MAIL = frozenset({
    "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.in", "yahoo.in", "ymail.com", "rocketmail.com",
    "hotmail.com", "outlook.com", "live.com", "msn.com", "aol.com", "rediffmail.com", "rediff.com",
    "icloud.com", "me.com", "protonmail.com", "proton.me", "zoho.com", "mail.com", "gmx.com", "yandex.com",
})
_EMAIL = re.compile(r"\b[a-z0-9._%+-]+@([a-z0-9.-]+\.[a-z]{2,})\b", re.I)

#: An agency hiring for a client it doesn't name.
AGENCY_PATTERNS: tuple[re.Pattern[str], ...] = tuple(re.compile(p, re.I) for p in (
    r"\b(?:on behalf of|hiring for|recruiting for|looking for|for) our (?:esteemed |reputed |prestigious |leading )?client\b(?!s)",
    r"\b(?:hiring|recruiting|requirement|opening|openings|vacancy|vacancies) (?:for|with) one of our (?:\w+ )?clients\b",
    r"\bour client(?: company)? is (?:a|an|one)\b",
    r"\b(?:for|with|at|in) (?:a|an|one of the) (?:leading|reputed|reputable|top|well[- ]known|renowned|prestigious) "
    r"(?:mnc|multinational|client|company|organi[sz]ation|firm)s?\b",
    r"\b(?:confidential|undisclosed|unnamed) (?:client|company|employer|organi[sz]ation)\b",
))
_UNNAMED_COMPANY = frozenset({"confidential", "undisclosed", "company confidential", "hiring company", "anonymous", "private"})

_RESPONSIBILITIES = re.compile(
    r"\b(?:responsibilit\w*|requirements?|qualifications?|you will|you'll|what you'?ll do|duties|experience (?:in|with)|"
    r"skills?|must have|role involves|we are looking for|about the role|day[- ]to[- ]day)\b",
    re.I,
)


def _sentences(text: str) -> list[str]:
    return [s for s in re.split(r"(?<=[.!?])\s+|[\n;•]+", text) if s.strip()]


def fee_ask(text: str) -> str | None:
    """The phrase asking the candidate to pay, or None."""
    for sentence in _sentences(text):
        for pat in FEE_PATTERNS:
            m = pat.search(sentence)
            if m and not _FEE_NEGATION.search(sentence):
                return m.group(0).strip()
    return None


def personal_email_only(text: str) -> str | None:
    """A free-webmail address when no company-domain address is given."""
    domains = [(m.group(0), m.group(1).lower().rstrip(".")) for m in _EMAIL.finditer(text)]
    if not domains:
        return None
    personal = [addr for addr, d in domains if d in FREE_MAIL]
    if personal and len(personal) == len(domains):
        return personal[0]
    return None


def agency_unnamed(text: str, company_name: str) -> str | None:
    name = (company_name or "").strip().lower()
    if name in _UNNAMED_COMPANY:
        return f"company listed as '{company_name}'"
    for pat in AGENCY_PATTERNS:
        m = pat.search(text)
        if m:
            return m.group(0).strip()
    return None


def vague(description: str | None) -> str | None:
    d = (description or "").strip()
    if not d:
        return None  # no description fetched: unknown, not vague
    if len(d) < VAGUE_MAX_CHARS and not _RESPONSIBILITIES.search(d):
        return f"{len(d)} characters, no responsibilities listed"
    return None


def title_identity(title: str) -> frozenset[str]:
    """The set of title words (order / punctuation churn tolerated; a city or level word is not)."""
    return frozenset(w for w in re.findall(r"[a-z0-9+#]+", (title or "").lower()) if w not in ("the", "a", "an", "and", "of"))


def reposts(conn: sqlite3.Connection, job: Job, *, now: datetime | None = None) -> str | None:
    """Same title identity at the same company on separate postings within the window, seen on
    two+ distinct days (listings first seen in one sweep are sibling openings, not reposts)."""
    key = title_identity(job.title)
    if not key:
        return None
    since = format_ts((now or utcnow()) - timedelta(days=REPOST_WINDOW_DAYS))
    rows = conn.execute(
        "SELECT title, discovered_at FROM jobs WHERE company_id = ? AND discovered_at >= ?", (job.company_id, since),
    ).fetchall()
    days = set()
    n = 0
    for r in rows:
        if title_identity(r["title"]) == key:
            n += 1
            days.add(str(r["discovered_at"])[:10])
    if n >= REPOST_MIN_LISTINGS and len(days) >= 2:
        return f"{n} listings in {REPOST_WINDOW_DAYS} days"
    return None


# =====================================================================================
# Assessment
# =====================================================================================


def assess(conn: sqlite3.Connection, job: Job, company: Company | None = None, *, now: datetime | None = None) -> Risk:
    """Compute the risk of one job (pure apart from the repost query)."""
    company_name = company.name if company is not None else ""
    desc = job.description or ""
    text = f"{job.title}\n{desc}"
    signals: list[dict[str, str]] = []
    for code, detail in (
        (SIG_FEE, fee_ask(text)),
        (SIG_PERSONAL_EMAIL, personal_email_only(desc)),
        (SIG_AGENCY, agency_unnamed(text, company_name)),
        (SIG_REPOST, reposts(conn, job, now=now)),
        (SIG_VAGUE, vague(job.description)),
    ):
        if detail:
            signals.append({"code": code, "detail": detail[:160]})
    codes = {s["code"] for s in signals}
    soft = codes - {SIG_FEE, SIG_PERSONAL_EMAIL}
    if codes & {SIG_FEE, SIG_PERSONAL_EMAIL} or len(soft) >= 2:
        level = HIGH
    elif soft:
        level = CAUTION
    else:
        level = NONE
    return Risk(level=level, signals=signals, checked_at=format_ts(now or utcnow()))


def stored(job: Job) -> Risk | None:
    raw = job.raw if isinstance(job.raw, dict) else {}
    r = raw.get(RAW_KEY)
    if not isinstance(r, dict) or r.get("level") not in (NONE, CAUTION, HIGH):
        return None
    sigs = [s for s in r.get("signals") or [] if isinstance(s, dict) and s.get("code")]
    return Risk(level=r["level"], signals=sigs, checked_at=str(r.get("checked_at") or ""))


def ensure(conn: sqlite3.Connection, job: Job, company: Company | None = None, *, now: datetime | None = None) -> Risk:
    """The job's stored risk, computing and storing it (``jobs.raw["risk"]``) the first time."""
    have = stored(job)
    if have is not None:
        return have
    risk = assess(conn, job, company, now=now)
    fresh = db.get_job(conn, job.id)  # re-read: write onto the latest raw
    raw = dict(fresh.raw) if isinstance(fresh.raw, dict) else {}
    raw[RAW_KEY] = risk.to_dict()
    db.update_job(conn, job.id, raw=raw)
    return risk


def is_high(job: Job) -> bool:
    r = stored(job)
    return r is not None and r.level == HIGH
