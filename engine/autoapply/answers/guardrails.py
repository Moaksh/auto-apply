"""Guardrails: never-guess fields, confidence gate, caps/cooldown/pause before submit.

This is the module the apply runners import (scripted adapters, the agentic adapter and
the pipeline):

* :func:`classify_never_guess` — rules-based classifier: form question -> never-guess key
  (``config.NEVER_GUESS_KEYS`` plus the always-ask keys in :data:`ALWAYS_ASK_KEYS`).
* :class:`NeverGuessClassifier` — the same rules plus an LLM fallback for questions that
  *look* sensitive but match no rule.
* :func:`resolve_never_guess` — answer ONLY from the user's stored facts, else ``None``
  (=> the caller raises :class:`NeedsUser`). EEO questions default to "prefer not to say".
* :func:`passes_confidence`, :func:`matches_always_ask` — gates for generated answers.
* :func:`check_answers` — final audit of every (question, answer, origin, confidence) an
  adapter is about to submit; any violation blocks the submit.
* :func:`check_submit_allowed` — pause / daily cap / company cooldown right before
  ``db.begin_submit``.
"""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from autoapply import db
from autoapply.answers.textnorm import (
    DECLINE_RX,
    decline_option,
    extract_country,
    match_option,
    normalize_question,
    strip_accents,
    yes_no,
)
from autoapply.config import NEVER_GUESS_KEYS, NeverGuess, Preferences
from autoapply.enums import AnswerOrigin, CapKind, FieldType, QuestionReason
from autoapply.llm.provider import LLMError, LLMProvider
from autoapply.models import Application, FormQuestion, Job

# =====================================================================================
# NeedsUser — the single "ask the human" signal
# =====================================================================================


class NeedsUser(Exception):
    """Raised when a question must go to the Needs-You inbox instead of being answered."""

    def __init__(
        self,
        question: FormQuestion,
        reason: QuestionReason | str,
        *,
        never_guess_key: str | None = None,
        suggested_answer: str | None = None,
        confidence: float | None = None,
        detail: str | None = None,
        note: str | None = None,
    ) -> None:
        self.question = question
        self.reason = QuestionReason(reason)
        self.never_guess_key = never_guess_key
        self.suggested_answer = suggested_answer
        self.confidence = confidence
        self.detail = detail
        self.note = note
        super().__init__(f"needs user ({self.reason.value}): {question.label}" + (f" — {detail}" if detail else ""))

    def to_unresolved(self):  # -> apply.base.UnresolvedField (import lazily: no cycle)
        from autoapply.apply.base import UnresolvedField

        return UnresolvedField(
            question=self.question, reason=self.reason.value, never_guess_key=self.never_guess_key,
            suggested_answer=self.suggested_answer, confidence=self.confidence, note=self.note,
        )


def as_form_question(question: FormQuestion | str) -> FormQuestion:
    if isinstance(question, FormQuestion):
        return question
    label = str(question).strip()
    return FormQuestion(key=normalize_question(label)[:80] or "question", label=label)


# =====================================================================================
# Never-guess classification
# =====================================================================================

#: Sensitive keys that are NOT stored in ``never_guess``: always asked (or answered from a
#: user-written memory answer), never generated.
ALWAYS_ASK_KEYS: tuple[str, ...] = (
    "current_salary",
    "criminal_history",
    "security_clearance",
    "non_compete",
    "eeo_other",
    "age_confirmation",
    "unclassified_sensitive",  # LLM fallback failed on a sensitive-looking question (fail closed)
)
ALL_SENSITIVE_KEYS: tuple[str, ...] = tuple(k for k in NEVER_GUESS_KEYS if k != "eeo_policy") + ALWAYS_ASK_KEYS
EEO_KEYS = frozenset({"eeo_gender", "eeo_race", "eeo_veteran", "eeo_disability", "eeo_other"})


def _rx(p: str) -> re.Pattern[str]:
    return re.compile(p, re.I)


#: Ordered (key, pattern) rules. First match wins, so more specific rules come first.
_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    # EEO / demographics (before anything mentioning "status")
    ("eeo_other", _rx(r"\bsexual orientation\b|\btransgender\b|\bgender identity\b.*\b(lgbt|trans)|\blgbtq?\+?\b")),
    ("eeo_veteran", _rx(r"\bveteran\b|\b(military|armed forces) (service|status)\b|\bserved in the (military|armed forces)\b")),
    ("eeo_disability", _rx(r"\bdisabilit(y|ies)\b|\bdisabled\b|\bhandicap")),
    ("eeo_race", _rx(r"\brace\b|\bethnicit|\bethnic (background|origin|group)|\bhispanic\b|\blatin[oax]\b|\bracial\b")),
    ("eeo_gender", _rx(r"\bgender\b|\bsex\b(?! offender)|\bpronouns?\b")),
    # money
    ("current_salary", _rx(r"\b(current|present|last|previous|existing)\b.{0,25}\b(salary|compensation|ctc|pay|base|package|remuneration|earnings)\b")),
    ("salary_negotiable", _rx(r"\b(salary|compensation|ctc|pay)\b.{0,30}\bnegotiable\b|\bnegotiable\b.{0,30}\b(salary|compensation|ctc|pay)\b")),
    (
        "salary_expectation",
        _rx(
            r"\b(salary|compensation|remuneration|ctc|wage|pay range|desired pay|pay expectations?|rate expectations?|"
            r"hourly rate|day rate|total comp|base pay|ote)\b|\bexpected (pay|package)\b|\bhow much .{0,20}\b(paid|earn|make)\b"
        ),
    ),
    # immigration — "authorized ... without sponsorship" asks about authorisation; other
    # sponsorship *requirement* wording comes before generic authorisation
    ("work_auth", _rx(r"\b(authori[sz]ed|eligible|legally|right to work|able to work)\b.{0,60}\bwithout (visa |the need for |requiring |needing )?(employer )?sponsorship\b")),
    (
        "sponsorship",
        _rx(
            r"\b(require|need|request)\w*\b.{0,60}\b(sponsor\w*|visa|h-?1b|work permit support|immigration)\b"
            r"|\b(sponsor\w*|visa)\b.{0,40}\b(require|need)\w*\b|\bwill you .{0,30}\bsponsor"
            r"|\bvisa (status|type|sponsorship)\b|\bh-?1b\b|\bsponsorship\b(?!.{0,40}\bwithout\b)"
        ),
    ),
    (
        "work_auth",
        _rx(
            r"\b(legally )?(authori[sz]ed|eligible|permitted|entitled)\b.{0,30}\b(to )?work\b|\bright to work\b|\bwork (permit|authori[sz]ation)\b"
            r"|\bemployment (authori[sz]ation|eligibility)\b|\bcitizen(ship)?\b|\bpermanent resident\b|\bgreen card\b"
            r"|\blegally (able|allowed) to work\b|\bwork legally\b|\bwithout (visa )?sponsorship\b"
        ),
    ),
    # timing / logistics
    ("notice_period", _rx(r"\bnotice period\b|\bnotice\b.{0,30}\b(give|serve|current employer|required|days|weeks)\b|\bserving notice\b")),
    (
        "start_date",
        _rx(
            r"\bstart date\b|\bearliest (possible )?(start|date|availability)\b|\bavailable to (start|join|begin)\b|\bwhen (can|could|would) you (start|join|begin)\b"
            r"|\bdate (you are )?available\b|\bavailability (to|date)\b|\bhow soon (can|could) you (start|join)\b|\bjoining date\b"
        ),
    ),
    # relocation: "commute to the office" / "moving between teams" are NOT relocation
    (
        "relocation",
        _rx(
            r"\brelocat\w*\b|\b(willing|open|able|prepared|happy) to (move|moving) (to|for)\b"
            r"(?!\s+(a |an |another |different |other |new |the )?(team|teams|role|roles|department|position|group|project|function)s?\b)"
            r"|\b(move|moving) (to|cities|countries|country|states?) for (this|the) (role|job|position)\b"
        ),
    ),
    # legal attestations
    ("attest_background_check", _rx(r"\bbackground (check|screening|investigation|verification)\b|\bdrug (test|screen)|\bconsent to (a )?(criminal|reference|credit) check")),
    ("criminal_history", _rx(r"\bconvicted\b|\bfelony\b|\bmisdemeanou?r\b|\bcriminal (record|history|offen[cs]e)\b|\bpending criminal\b")),
    ("security_clearance", _rx(r"\bsecurity clearance\b|\b(active|current) clearance\b|\bts/sci\b")),
    ("non_compete", _rx(r"\bnon-?compete\b|\bnon-?solicit\w*\b|\brestrictive covenant")),
    ("age_confirmation", _rx(r"\b(at least|over|older than) (18|eighteen|21)\b|\b18 years (of age|or older)\b|\blegal age\b")),
    (
        "attest_accuracy",
        _rx(
            r"\b(certify|attest|affirm|declare|acknowledge|confirm)\b.{0,80}\b(true|accurate|complete|correct|truthful)\b"
            r"|\b(information|answers|statements)\b.{0,40}\b(true|accurate|complete|correct)\b.{0,40}\b(knowledge|belief)\b"
            r"|\belectronic signature\b|\be-?signature\b|\bsign(ature)? (below|here)\b|\bfalsif\w*\b"
        ),
    ),
)

#: Words that make a question *look* sensitive even when no rule matched (=> LLM fallback).
_SUSPICIOUS = _rx(
    r"\b(legal\w*|status|eligib\w*|visa|permit|consent|agree|compens\w*|identity|identify|background|country|"
    r"nationality|felony|convict\w*|clearance|citizen\w*|terms|policy|accommodat\w*|demographic|voluntary|self-identif\w*|"
    r"authori[sz]\w*|salary|pay|available|availability|notice|relocat\w*|military|ethnic\w*|religio\w*|marital|age)\b"
)


def classify_never_guess(question: FormQuestion | str) -> str | None:
    """Map a form question to a never-guess key (``config.NEVER_GUESS_KEYS`` or one of
    :data:`ALWAYS_ASK_KEYS`) or None.
    E.g. "Will you now or in the future require sponsorship?" -> "sponsorship"."""
    q = as_form_question(question)
    text = strip_accents(f"{q.label} {q.description or ''}").strip()
    if not text:
        return None
    for key, rx in _RULES:
        if rx.search(text):
            return key
    return None


def looks_sensitive(question: FormQuestion | str) -> bool:
    q = as_form_question(question)
    return bool(_SUSPICIOUS.search(f"{q.label} {q.description or ''} {' '.join(q.options)}"))


_CLASSIFY_SCHEMA = {
    "type": "object",
    "properties": {"key": {"type": ["string", "null"], "enum": [*(k for k in ALL_SENSITIVE_KEYS if k != "unclassified_sensitive"), None]}},
    "required": ["key"],
    "additionalProperties": False,
}


class NeverGuessClassifier:
    """Rules first; LLM fallback only for unmatched questions that look sensitive.

    LLM results are cached per normalized question text (per instance)."""

    def __init__(self, llm: LLMProvider | None = None) -> None:
        self.llm = llm
        self._cache: dict[str, str | None] = {}

    def classify(self, question: FormQuestion | str) -> str | None:
        return classify_never_guess(question)

    async def classify_async(self, question: FormQuestion | str) -> str | None:
        q = as_form_question(question)
        key = classify_never_guess(q)
        if key is not None or self.llm is None or not looks_sensitive(q):
            return key
        norm = normalize_question(q.label)
        if norm in self._cache:
            return self._cache[norm]
        prompt = (
            "NEVER-GUESS CLASSIFICATION. A job application form asks the question below. If it asks for one of "
            "these sensitive facts, return its key, else null.\n"
            "Keys: work_auth (legal right to work in a country), sponsorship (needs visa sponsorship), "
            "salary_expectation, salary_negotiable, current_salary, notice_period, start_date, relocation, "
            "eeo_gender, eeo_race, eeo_veteran, eeo_disability, eeo_other (other demographics), attest_accuracy "
            "(certify information is true / signature), attest_background_check, criminal_history, "
            "security_clearance, non_compete, age_confirmation.\n"
            f"Question: {q.label}\n"
            + (f"Help text: {q.description}\n" if q.description else "")
            + (f"Options: {q.options}\n" if q.options else "")
        )
        try:
            res = await self.llm.complete(prompt, system="You classify job application form fields.", tier="fast", schema=_CLASSIFY_SCHEMA, max_tokens=40)
            key = res.data.get("key") if isinstance(res.data, dict) else None
        except LLMError:
            # Fail closed: a sensitive-looking question we couldn't classify goes to the user.
            key = "unclassified_sensitive"
        self._cache[norm] = key
        return key


# =====================================================================================
# Resolving never-guess keys from stored facts ONLY
# =====================================================================================

_AUTHORIZED_STATUSES = {
    "citizen", "permanent_resident", "green_card", "authorized", "authorised", "work_permit", "work_visa",
    "visa_holder", "settled", "pre_settled", "eu_citizen", "ead", "opt", "stem_opt", "h1b", "h-1b", "tn", "l1", "o1",
    "yes", "true", "national", "resident",
}
_UNAUTHORIZED_STATUSES = {"requires_sponsorship", "needs_sponsorship", "not_authorized", "unauthorized", "no", "false", "none"}
_STATUS_LABELS = {
    "citizen": "Citizen", "permanent_resident": "Permanent resident", "green_card": "Permanent resident (green card)",
    "authorized": "Authorized to work", "requires_sponsorship": "Requires visa sponsorship",
    "needs_sponsorship": "Requires visa sponsorship", "not_authorized": "Not authorized to work",
}


def _status_key(s: str) -> str:
    return re.sub(r"[\s\-]+", "_", s.strip().lower())


def _lookup_country(work_auth: dict[str, str], country: str | None) -> str | None:
    if not work_auth:
        return None
    norm = {}
    for k, v in work_auth.items():
        code = k.upper() if len(k) == 2 else (extract_country(k) or k.upper())
        norm[code] = v
    if country:
        return norm.get(country.upper())
    # No country identified (e.g. "Remote", "Remote - EMEA", an unknown city): never assume
    # the single stored country applies — the question goes to the user.
    return None


def _bool_answer(value: bool | None, q: FormQuestion) -> str | None:
    if value is None:
        return None
    if q.options:
        return match_option(value, q.options)
    if q.field_type is FieldType.BOOLEAN:
        return "true" if value else "false"
    return "Yes" if value else "No"


def _text_answer(text: str | None, q: FormQuestion) -> str | None:
    if text is None or not str(text).strip():
        return None
    text = str(text).strip()
    if q.options:
        return match_option(text, q.options)
    if q.field_type is FieldType.NUMBER:
        n = parse_amount(text)
        return None if n is None else str(n)
    if q.field_type is FieldType.DATE:
        return text if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text) else None
    if q.field_type is FieldType.BOOLEAN:
        return _bool_answer(yes_no(text), q)
    return text


def parse_amount(text: str) -> int | None:
    """First money-ish number in ``text``: "$180k" -> 180000, "₹45L" -> 4500000, "1.2M" -> 1200000."""
    m = re.search(r"(\d[\d,]*(?:\.\d+)?)\s*(k|thousand|l|lakh|lakhs|lac|cr|crore|m|mn|million)?\b", text, re.I)
    if not m:
        return None
    num = float(m.group(1).replace(",", ""))
    mult = {"k": 1e3, "thousand": 1e3, "l": 1e5, "lakh": 1e5, "lakhs": 1e5, "lac": 1e5, "cr": 1e7, "crore": 1e7,
            "m": 1e6, "mn": 1e6, "million": 1e6}.get((m.group(2) or "").lower(), 1)
    return int(round(num * mult))


#: stored work_auth status -> words that identify the matching option on a status select
_STATUS_OPTION_RX: dict[str, re.Pattern[str]] = {
    "citizen": re.compile(r"(?<!non[- ])\bcitizen\b|\bnational\b", re.I),
    "national": re.compile(r"(?<!non[- ])\bcitizen\b|\bnational\b", re.I),
    "eu_citizen": re.compile(r"\beu\b.{0,20}\bcitizen|\beuropean\b", re.I),
    "permanent_resident": re.compile(r"\bpermanent resident\b|\bgreen card\b|\blawful permanent\b|\bindefinite leave\b", re.I),
    "green_card": re.compile(r"\bpermanent resident\b|\bgreen card\b|\blawful permanent\b", re.I),
    "h1b": re.compile(r"\bh-?1b\b", re.I),
    "h-1b": re.compile(r"\bh-?1b\b", re.I),
    "opt": re.compile(r"\bopt\b|\bf-?1\b", re.I),
    "stem_opt": re.compile(r"\bstem\b.{0,10}\bopt\b", re.I),
    "ead": re.compile(r"\bead\b|employment authori[sz]ation document", re.I),
    "tn": re.compile(r"\btn\b", re.I),
    "l1": re.compile(r"\bl-?1\b", re.I),
    "o1": re.compile(r"\bo-?1\b", re.I),
    "settled": re.compile(r"\bsettled status\b|\bindefinite leave\b", re.I),
    "pre_settled": re.compile(r"\bpre-?settled\b", re.I),
}
_ANY_STATUS_RX = re.compile(
    r"citizen|national|permanent resident|green card|h-?1b|\bopt\b|\bead\b|\bvisa\b|\bsettled\b|\bpermit\b|\bl-?1\b|\btn\b|\bo-?1\b",
    re.I,
)


def _status_option(status_key: str, options: list[str]) -> str | None:
    """The single option that names the stored status (e.g. green_card -> "Yes - Green Card holder")."""
    rx = _STATUS_OPTION_RX.get(status_key)
    if rx is None:
        return None
    hits = [o for o in options if rx.search(o)]
    return hits[0] if len(hits) == 1 else None


def _has_status_options(options: list[str]) -> bool:
    """More than one affirmative option describes a specific status -> a bare yes is ambiguous."""
    return sum(1 for o in options if _ANY_STATUS_RX.search(o) and yes_no(o) is not False) >= 2


def eeo_decline(q: FormQuestion) -> str:
    """The "prefer not to say" answer for an EEO question (an option when there are options)."""
    if q.options:
        opt = decline_option(q.options)
        if opt:
            return opt
    return "Prefer not to say" if not q.options else ""


def resolve_never_guess(
    key: str, never_guess: NeverGuess, question: FormQuestion | None = None, *, country: str | None = None
) -> str | None:
    """Answer text for a never-guess key from the user's facts, or None (=> ask user).
    Never infers a value that isn't stored. With ``question.options`` the answer is
    mapped onto an option verbatim (None when no option fits).

    ``country`` (ISO-2) disambiguates ``work_auth`` when the question names no country
    (pass the job's country)."""
    q = question or FormQuestion(key=key, label=key)
    ng = never_guess

    if key in EEO_KEYS:
        if ng.eeo_policy == "fill" and key != "eeo_other":
            val = ng.get(key)
            if val:
                ans = _text_answer(val, q)
                if ans:
                    return ans
        dec = eeo_decline(q)
        return dec or None

    if key == "work_auth":
        c = extract_country(f"{q.label} {q.description or ''}") or country
        status = _lookup_country(ng.work_auth, c)
        if status is None:
            return None
        sk = _status_key(status)
        if q.options:
            # Status-style selects ("Yes - US Citizen" / "Yes - Green Card holder" / ...):
            # map the stored status itself onto an option first. Several plausible options
            # and no unique status match -> ask (never pick one arbitrarily).
            by_status = _status_option(sk, q.options)
            if by_status is not None:
                return by_status
            if _has_status_options(q.options):
                return None
        label = q.label.lower()
        if re.search(r"\bcitizen", label) and not re.search(r"\b(or|and)\b.{0,30}\b(resident|authori|green card|visa)", label):
            authorized: bool | None = sk in {"citizen", "national", "eu_citizen"}
        elif "without" in label and "sponsor" in label:
            authorized = False if sk in _UNAUTHORIZED_STATUSES or "sponsor" in sk else (True if sk in _AUTHORIZED_STATUSES else None)
        elif sk in _UNAUTHORIZED_STATUSES or "sponsor" in sk:
            authorized = False
        elif sk in _AUTHORIZED_STATUSES:
            authorized = True
        else:
            authorized = None
        if q.options or q.field_type is FieldType.BOOLEAN:
            return _bool_answer(authorized, q)
        if yes_no_question(q.label):
            return None if authorized is None else ("Yes" if authorized else "No")
        return _STATUS_LABELS.get(sk, status)

    if key == "sponsorship":
        # A country-specific work_auth status (question country, else the job's country)
        # is authoritative; the global ``sponsorship`` text applies only when there is none.
        # If both exist and disagree, ask the user.
        c = extract_country(f"{q.label} {q.description or ''}") or country
        status = _lookup_country(ng.work_auth, c)
        derived: bool | None = None
        if status is not None:
            sk = _status_key(status)
            derived = True if ("sponsor" in sk or sk in _UNAUTHORIZED_STATUSES) else (
                False if sk in _AUTHORIZED_STATUSES else None)
        stated: bool | None = None
        s = (ng.sponsorship or "").strip()
        if s:
            low = s.lower()
            if re.search(r"\bnot (required|needed)\b|\bno\b|\bdon'?t (need|require)\b|\bdoes not\b|\bnone\b", low):
                stated = False
            elif re.search(r"\brequire|\bneed|\byes\b|h-?1b|visa", low):
                stated = True
        if status is not None:
            # Citizens / permanent residents of the job's country can never need sponsorship there:
            # that beats a general "Requires sponsorship" (meant for jobs abroad). Weaker statuses
            # ("authorized" on a visa) that disagree with the general answer still go to the user.
            definitive = _status_key(status) in {"citizen", "national", "permanent_resident", "green_card", "eu_citizen"}
            if derived is None or (not definitive and s and stated is not None and stated != derived):
                return None
            needs: bool | None = derived
        elif s:
            needs = stated
            if not q.options and q.field_type is not FieldType.BOOLEAN and not yes_no_question(q.label):
                return s
        else:
            return None
        if q.options or q.field_type is FieldType.BOOLEAN:
            return _bool_answer(needs, q)
        if yes_no_question(q.label):
            return None if needs is None else ("Yes" if needs else "No")
        return None if needs is None else ("Requires sponsorship" if needs else "Sponsorship not required")

    if key == "salary_negotiable":
        return _bool_answer(ng.salary_negotiable, q)

    if key in {"salary_expectation", "notice_period", "start_date"}:
        return _text_answer(ng.get(key), q)

    if key == "relocation":
        if ng.relocation is None:
            return None
        if q.options or q.field_type is FieldType.BOOLEAN or yes_no_question(q.label):
            val = {"yes": True, "no": False}.get(ng.relocation)  # case_by_case -> ask
            if val is None:
                if q.options:
                    opt = match_option("case by case", q.options) or match_option("depends", q.options)
                    return opt
                return None
            return _bool_answer(val, q) if (q.options or q.field_type is FieldType.BOOLEAN) else ("Yes" if val else "No")
        return {"yes": "Yes, open to relocation", "no": "No, not open to relocation",
                "case_by_case": "Open to relocation on a case-by-case basis"}[ng.relocation]

    if key in {"attest_accuracy", "attest_background_check"}:
        allowed = bool(ng.get(key))
        if not allowed:
            return None
        if q.options:
            return match_option(True, q.options) or match_option("I agree", q.options)
        if q.field_type is FieldType.BOOLEAN:
            return "true"
        if q.field_type in {FieldType.TEXT, FieldType.TEXTAREA} and re.search(r"signature|sign|full name", q.label, re.I):
            return None  # a typed signature is the user's to give
        return "Yes"

    return None  # ALWAYS_ASK_KEYS and unknown keys


def yes_no_question(label: str) -> bool:
    """Heuristic: is this phrased as a yes/no question?"""
    return bool(re.match(r"^\s*(are|do|does|will|would|have|has|can|could|is|did|were|was)\b", label.strip(), re.I))


# =====================================================================================
# Gates
# =====================================================================================


def passes_confidence(confidence: float | None, preferences: Preferences) -> bool:
    """True if a generated answer may be used without asking (>= preferences.confidence_threshold)."""
    if confidence is None:
        return False
    return float(confidence) >= preferences.confidence_threshold


def matches_always_ask(question: str, preferences: Preferences) -> bool:
    """True if the question matches a user 'always ask' pattern (regex, case-insensitive;
    an invalid regex is treated as a plain substring)."""
    for pat in preferences.always_ask_patterns:
        if not pat:
            continue
        try:
            if re.search(pat, question, re.I):
                return True
        except re.error:
            if pat.lower() in question.lower():
                return True
    return False


#: A *visible* challenge. The invisible reCAPTCHA v3 / Enterprise badge ("This site is
#: protected by reCAPTCHA", an ``iframe "reCAPTCHA"`` node) is on many forms and needs no
#: user action, so a bare "captcha"/"recaptcha"/"turnstile" mention is not a challenge.
_CAPTCHA_RX = re.compile(
    r"\bi'?m not a robot\b|\bi am not a robot\b|\bare you a robot\b|\bi am human\b|\bverify (that )?you are (a )?human\b"
    r"|\bhuman verification\b|\bpress (and|&) hold\b|cloudflare.{0,40}(checking|challenge)|\bchecking (if the site connection is secure|your browser)\b"
    r"|\bsecurity check to continue\b|recaptcha challenge|\bselect all (the )?(images|squares)\b|\bhcaptcha (security )?challenge\b"
    r"|\bsolve (the|this) (captcha|puzzle|challenge)\b|\bcomplete the (captcha|security check)\b|\benter the (characters|text) (you see|shown)\b"
    r"|\btype the (characters|text) (you see|shown|in the image)\b",
    re.I,
)


def detect_captcha(text: str | None) -> bool:
    """True if page text / an accessibility snapshot shows a visible CAPTCHA / bot challenge.
    The passive "protected by reCAPTCHA" badge does not count (the agent can still call
    ``report_captcha`` for anything this misses)."""
    return bool(text and _CAPTCHA_RX.search(text))


# =====================================================================================
# Pre-submit audit of answers
# =====================================================================================


@dataclass(slots=True)
class AnswerForCheck:
    question: FormQuestion
    answer: str
    origin: AnswerOrigin
    confidence: float | None = None
    never_guess_key: str | None = None


@dataclass(slots=True)
class AnswerViolation:
    question: str
    problem: str
    reason: QuestionReason


def check_answers(
    answers: Iterable[AnswerForCheck],
    never_guess: NeverGuess,
    preferences: Preferences,
    *,
    country: str | None = None,
) -> list[AnswerViolation]:
    """Every answer an adapter is about to submit, audited. Empty list == OK to submit.

    * never-guess questions must carry exactly the stored fact (origin never_guess) or a
      user-given answer (origin user); EEO answers must be the decline option unless the
      user opted to fill.
    * generated answers must pass the confidence gate.
    * always-ask questions must be user-answered.
    """
    out: list[AnswerViolation] = []
    for a in answers:
        q = a.question
        if q.field_type is FieldType.FILE:
            continue
        key = a.never_guess_key or classify_never_guess(q)
        if matches_always_ask(q.label, preferences) and a.origin is not AnswerOrigin.USER:
            out.append(AnswerViolation(q.label, "always-ask question was not answered by you", QuestionReason.ALWAYS_ASK))
            continue
        if key is not None:
            if a.origin is AnswerOrigin.USER:
                continue
            if key in ALWAYS_ASK_KEYS and a.origin is AnswerOrigin.MEMORY:
                continue  # a user-written memory answer (resolver only allows source=user)
            expected = resolve_never_guess(key, never_guess, q, country=country)
            if expected is None:
                out.append(AnswerViolation(q.label, f"never-guess field '{key}' has no stored value", QuestionReason.NEVER_GUESS))
            elif normalize_question(expected) != normalize_question(a.answer):
                out.append(
                    AnswerViolation(q.label, f"never-guess field '{key}' answered {a.answer!r}, stored fact says {expected!r}", QuestionReason.NEVER_GUESS)
                )
            continue
        if a.origin is AnswerOrigin.GENERATED and not passes_confidence(a.confidence, preferences):
            out.append(
                AnswerViolation(q.label, f"generated answer confidence {a.confidence} below {preferences.confidence_threshold}", QuestionReason.LOW_CONFIDENCE)
            )
    return out


# =====================================================================================
# Submit gate (pause / caps / cooldown)
# =====================================================================================


@dataclass(slots=True)
class SubmitCheck:
    allowed: bool
    cap: CapKind | None = None
    reason: str | None = None
    used: int | None = None
    limit: int | None = None
    resets_at: datetime | None = None
    extra: dict[str, object] = field(default_factory=dict)


def check_submit_allowed(
    conn: sqlite3.Connection,
    application: Application,
    job: Job,
    preferences: Preferences,
    *,
    paused: bool,
    now: datetime | None = None,
) -> SubmitCheck:
    """Final gate right before ``db.begin_submit``: pause, daily cap, company cooldown."""
    if paused:
        return SubmitCheck(False, reason="paused")
    # In-flight (``submitting``) and unverified attempts count: the click may have happened.
    used = db.attempts_used_today(conn, now)
    if used >= preferences.daily_cap:
        start = db.local_day_start(now)
        return SubmitCheck(
            False, cap=CapKind.DAILY, reason=f"daily cap reached ({used}/{preferences.daily_cap})",
            used=used, limit=preferences.daily_cap, resets_at=start + timedelta(days=1),
        )
    if db.company_in_cooldown(conn, job.company_id, preferences.per_company_cooldown_days, now):
        company = db.get_company(conn, job.company_id)
        resets = company.last_applied_at + timedelta(days=preferences.per_company_cooldown_days) if company.last_applied_at else None
        return SubmitCheck(
            False, cap=CapKind.COMPANY_COOLDOWN,
            reason=f"applied to {company.name} within {preferences.per_company_cooldown_days} days",
            resets_at=resets, extra={"company_id": job.company_id},
        )
    pending_at = db.company_attempt_at(
        conn, job.company_id, preferences.per_company_cooldown_days, now, exclude_application_id=application.id,
    )
    if pending_at is not None:
        company = db.get_company(conn, job.company_id)
        return SubmitCheck(
            False, cap=CapKind.COMPANY_COOLDOWN,
            reason=f"another application to {company.name} is unconfirmed",
            resets_at=pending_at + timedelta(days=preferences.per_company_cooldown_days),
            extra={"company_id": job.company_id, "unconfirmed": True},
        )
    return SubmitCheck(True)


__all__ = [
    "ALL_SENSITIVE_KEYS", "ALWAYS_ASK_KEYS", "AnswerForCheck", "AnswerViolation", "DECLINE_RX", "EEO_KEYS", "NeedsUser",
    "NeverGuessClassifier", "SubmitCheck", "as_form_question", "check_answers", "check_submit_allowed",
    "classify_never_guess", "detect_captcha", "eeo_decline", "looks_sensitive", "matches_always_ask", "parse_amount",
    "passes_confidence", "resolve_never_guess", "yes_no_question",
]
