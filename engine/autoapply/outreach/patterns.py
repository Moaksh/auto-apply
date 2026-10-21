"""Email address patterns of a domain (pure; plan §B.4).

Evidence is every (name, email) pair seen on the domain: GitHub commit authors, company pages,
job postings, provider results. For each pair we find the patterns that produce the email's
local part from the name, then pick the pattern with the most confirmations:

    conf = clamp(50 + 12*k - 15*m, 0, 85)

where ``k`` samples support the winner and ``m`` contradict it. With no samples the guess is
``first.last`` (``first`` for small startups) at 25. Role mailboxes (careers@, jobs@, ...) are
never evidence.

Indian names often have a single given name, initials, or a long surname, so a name is parsed
several ways (first + last token, first + middle, an initial as the surname, an initial first);
when more than one parse is plausible the guess is marked ambiguous (-10 in contact confidence).
"""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from autoapply.answers.textnorm import strip_accents

#: Candidate patterns, most common first (ties are broken in this order).
PATTERNS: tuple[str, ...] = ("first.last", "first", "flast", "firstlast", "first_last", "firstl", "last.first", "f.last", "last")
DEFAULT_PATTERN = "first.last"
SMALL_COMPANY_PATTERN = "first"
NO_EVIDENCE_CONFIDENCE = 25
MAX_PATTERN_CONFIDENCE = 85
#: Bounces on pattern-guessed addresses before the next-best pattern is promoted.
BOUNCES_BEFORE_DEMOTION = 2
BOUNCE_PENALTY = 20

#: Local parts that are mailboxes, not people (never pattern evidence).
ROLE_MAILBOXES = frozenset(
    """
    careers career jobs job hr recruiting recruitment talent hiring people info hello contact team admin
    support help sales press media pr security privacy legal billing office mail marketing noreply no-reply
    notifications team-hr apply applications humanresources work joinus join
    """.split()
)

_HONORIFICS = frozenset({"mr", "mrs", "ms", "dr", "prof", "sri", "shri", "smt", "jr", "sr", "ii", "iii", "phd"})


@dataclass(frozen=True, slots=True)
class NameParse:
    first: str
    last: str


@dataclass(frozen=True, slots=True)
class PatternInference:
    pattern: str
    confidence: int
    supporting: int  # k
    contradicting: int  # m


def _clean_token(t: str) -> str:
    return re.sub(r"[^a-z]", "", strip_accents(t).lower())


def name_tokens(full_name: str) -> list[str]:
    """Lowercase ASCII tokens of a person's name, honorifics dropped ("Dr. R. Karthik" -> ["r", "karthik"])."""
    raw = re.split(r"[\s.\-_,']+", full_name or "")
    toks = [_clean_token(t) for t in raw]
    return [t for t in toks if t and t not in _HONORIFICS]


def name_parses(full_name: str) -> list[NameParse]:
    """Plausible (first, last) readings of a name, most likely first."""
    toks = name_tokens(full_name)
    if not toks:
        return []
    if len(toks) == 1:
        return [NameParse(toks[0], "")]
    out: list[NameParse] = []

    def add(first: str, last: str) -> None:
        p = NameParse(first, last)
        if p not in out:
            out.append(p)

    initials_first = len(toks[0]) == 1
    initials_last = len(toks[-1]) == 1
    if initials_first and not initials_last:
        # "R Karthik" / "R. K. Karthik": the long token is the given name.
        add(toks[-1], toks[0])
        add(toks[0], toks[-1])
    else:
        add(toks[0], toks[-1])
        if len(toks) > 2:
            add(toks[0], toks[1])          # "Venkata Subramanian Iyer" -> venkata.subramanian
            add(toks[0], "".join(toks[1:]))  # compound surname
    return out


def render(pattern: str, first: str, last: str) -> str | None:
    """Local part for ``pattern`` (None when the name lacks a part the pattern needs)."""
    f, l = first, last  # noqa: E741
    needs_last = pattern not in ("first",)
    if not f or (needs_last and not l):
        return None
    return {
        "first.last": f"{f}.{l}",
        "first": f,
        "flast": f"{f[0]}{l}",
        "firstlast": f"{f}{l}",
        "first_last": f"{f}_{l}",
        "firstl": f"{f}{l[:1]}",
        "last.first": f"{l}.{f}",
        "f.last": f"{f[0]}.{l}",
        "last": l,
    }.get(pattern)


def local_part(email: str) -> str:
    return (email or "").rsplit("@", 1)[0].lower()


def is_role_mailbox(email: str) -> bool:
    lp = re.sub(r"[^a-z\-]", "", local_part(email).split("+", 1)[0])
    return lp in ROLE_MAILBOXES


def patterns_matching(full_name: str, email: str) -> set[str]:
    """Patterns that produce ``email``'s local part from ``full_name`` (any parse)."""
    lp = local_part(email).split("+", 1)[0]
    if not lp or is_role_mailbox(email):
        return set()
    out: set[str] = set()
    for p in name_parses(full_name):
        for pat in PATTERNS:
            if render(pat, p.first, p.last) == lp:
                out.add(pat)
    return out


def infer_pattern(samples: Iterable[tuple[str, str]], *, small_company: bool = False) -> PatternInference:
    """Best pattern for a domain from (name, email) samples (role mailboxes ignored).

    A sample that matches no pattern counts against every candidate (it contradicts them);
    a sample matching several patterns (e.g. single-token names match both ``first`` and
    nothing else) supports each of them."""
    matches: list[set[str]] = []
    for name, email in samples:
        if is_role_mailbox(email):
            continue
        matches.append(patterns_matching(name, email))
    if not matches:
        pat = SMALL_COMPANY_PATTERN if small_company else DEFAULT_PATTERN
        return PatternInference(pat, NO_EVIDENCE_CONFIDENCE, 0, 0)
    support = Counter(p for m in matches for p in m)
    if not support:
        pat = SMALL_COMPANY_PATTERN if small_company else DEFAULT_PATTERN
        return PatternInference(pat, max(0, NO_EVIDENCE_CONFIDENCE - 15 * len(matches)), 0, len(matches))
    best = max(PATTERNS, key=lambda p: (support.get(p, 0), -PATTERNS.index(p)))
    k = support[best]
    m = sum(1 for s in matches if best not in s)
    return PatternInference(best, pattern_confidence(k, m), k, m)


def pattern_confidence(k: int, m: int) -> int:
    return max(0, min(MAX_PATTERN_CONFIDENCE, 50 + 12 * k - 15 * m))


def guess_email(full_name: str, domain: str, pattern: str) -> tuple[str | None, bool]:
    """(address, ambiguous) for a named person under ``pattern``. Ambiguous when the name
    has more than one plausible parse that yields different addresses."""
    parses = name_parses(full_name)
    locals_ = [lp for lp in (render(pattern, p.first, p.last) for p in parses) if lp]
    if not locals_:
        return None, False
    return f"{locals_[0]}@{domain.lower()}", len(set(locals_)) > 1


def next_best_pattern(samples: Sequence[tuple[str, str]], current: str) -> str:
    """The runner-up pattern (after ``current`` bounced too often)."""
    support = Counter(p for name, email in samples for p in patterns_matching(name, email))
    ranked = sorted((p for p in PATTERNS if p != current), key=lambda p: (-support.get(p, 0), PATTERNS.index(p)))
    return ranked[0]


__all__ = [
    "PATTERNS", "NameParse", "PatternInference", "guess_email", "infer_pattern", "is_role_mailbox",
    "name_parses", "name_tokens", "next_best_pattern", "pattern_confidence", "patterns_matching", "render",
]
