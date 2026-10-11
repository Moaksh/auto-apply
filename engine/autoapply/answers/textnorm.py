"""Text helpers shared by answer memory, guardrails and the resolver.

Everything here is deterministic and local (no tokens):

* :func:`normalize_question` — lowercase, strip punctuation / filler, collapse whitespace.
* :func:`question_intents` — coarse *intent* tags ("why_company", "salary", ...) used to make
  paraphrases ("Why us?" vs "Why do you want to work here?") land close together in the
  embedding space and to keep different intents apart.
* :func:`match_option` — map a free-text answer onto one of a select field's options
  (yes/no semantics, "decline to answer" variants, containment).
* :func:`extract_country` — find a country mentioned in a question / job location.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable, Sequence

# -------------------------------------------------------------------------------------
# normalisation
# -------------------------------------------------------------------------------------

#: Very common words that carry no meaning for question matching.
STOPWORDS: frozenset[str] = frozenset(
    """
    a an the and or of to in on at for with by from as is are was were be been being am
    do does did you your yours we our ours us i me my it its this that these those there
    here please kindly any if so than then can could would should will shall may might
    have has had about into over under up down out just also
    """.split()
)

_WS = re.compile(r"\s+")
_NON_ALNUM = re.compile(r"[^a-z0-9+#.$%/\- ]+")


def strip_accents(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c))


def normalize_question(text: str | None) -> str:
    """Canonical comparison form of a question: lowercase, no accents, no trailing
    "(required)" / asterisks, punctuation removed, whitespace collapsed."""
    if not text:
        return ""
    s = strip_accents(text).lower()
    s = re.sub(r"\((required|optional)\)", " ", s)
    s = s.replace("*", " ").replace("’", "'")
    s = _NON_ALNUM.sub(" ", s)
    s = re.sub(r"(?<![a-z0-9])[.\-/]+|[.\-/]+(?![a-z0-9])", " ", s)  # drop stray punctuation
    return _WS.sub(" ", s).strip()


def content_tokens(text: str | None) -> list[str]:
    """Normalized tokens with stopwords removed."""
    return [t for t in normalize_question(text).split() if t not in STOPWORDS]


# -------------------------------------------------------------------------------------
# intents (paraphrase anchors)
# -------------------------------------------------------------------------------------

#: (intent, regex) — first-class paraphrase anchors. A question may carry several.
_INTENT_RULES: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (name, re.compile(rx, re.I))
    for name, rx in (
        (
            "why_company",
            r"\bwhy\b.{0,40}\b(us|here|this company|our company|our team|our mission|join|work (here|for|at|with)|"
            r"interested in (working|joining)|excite[sd]? you about (us|our|working))\b"
            r"|\bwhat (draws|attracts|excites|interests) you (to|about) (us|our|this company|working|joining)"
            r"|\bwhy (do|would) you want to (work|join)"
            r"|\binterest(ed)? in (working (at|for|with)|joining) (us|our|the company|this company)"
            r"|\bmotivat\w* (you )?to (apply|join|work)"
            r"|^\s*why\s+(us|[a-z0-9&.\- ]{2,30})\s*\??\s*$",
        ),
        (
            "why_role",
            r"\bwhy\b.{0,40}\b(this (role|position|job|opportunity)|the (role|position))\b"
            r"|\binterest(s|ed)? you (in|about) (this|the) (role|position|job)"
            r"|\bwhat makes you (a )?(good|great|strong|ideal) (fit|candidate)",
        ),
        ("hear_about", r"\bhow did you (hear|learn|find out) about\b|\breferr(al|ed) source\b|\bwhere did you (hear|find)"),
        ("salary", r"\b(salary|compensation|remuneration|pay (range|expectation)|desired pay|ctc|wage|rate expectation|hourly rate)\b"),
        ("notice", r"\bnotice period\b|\bnotice\b.{0,20}\b(give|serve|required)"),
        ("start_date", r"\b(start date|earliest (start|date)|available to start|when can you start|date available|availability to start|how soon can you (start|join))\b"),
        ("sponsorship", r"\b(sponsor\w*|visa|h-?1b|immigration)\b"),
        ("work_auth", r"\b(authori[sz]ed|eligible|legally|right to work|work permit|permanent resident|green card|citizen\w*)\b"),
        ("relocation", r"\b(relocat\w*|willing to move|open to moving)\b"),
        ("years_experience", r"\b(how many )?years\b.{0,30}\b(experience|exp)\b|\bexperience\b.{0,20}\byears\b"),
        ("linkedin", r"\blinked ?in\b"),
        ("github", r"\bgit ?hub\b"),
        ("portfolio", r"\b(portfolio|personal (website|site)|website)\b"),
        ("cover_letter", r"\bcover letter\b"),
        ("strength", r"\b(greatest|biggest|key) strengths?\b"),
        ("weakness", r"\b(greatest|biggest) weakness(es)?\b|\barea(s)? (of|for) (improvement|growth)\b"),
        ("achievement", r"\b(proudest|greatest|most significant) (achievement|accomplishment)\b|\baccomplishment you are (most )?proud\b"),
        ("pitch", r"\b(tell us about yourself|introduce yourself|summary of (yourself|your background)|elevator pitch|about you)\b"),
        ("remote", r"\b(remote|hybrid|on-?site|in office|in-office)\b.{0,30}\b(work|comfortable|open|willing|prefer)"),
        ("gender", r"\bgender\b|\bsex\b"),
        ("race", r"\b(race|ethnicity|ethnic|hispanic|latin[oax])\b"),
        ("veteran", r"\bveteran\b|\bmilitary\b"),
        ("disability", r"\bdisabilit\w*\b|\bdisabled\b"),
        ("orientation", r"\bsexual orientation\b|\btransgender\b|\blgbtq?\w*\b"),
        ("attest", r"\b(certify|attest|acknowledge|affirm)\b|\bby (checking|signing|submitting)\b"),
        ("background_check", r"\b(background (check|screening|investigation)|drug (test|screen))\b"),
        ("name", r"^\s*(full |first |last |legal |preferred )?name\s*$"),
        ("email", r"^\s*(e-?mail)( address)?\s*$"),
        ("phone", r"^\s*(phone|mobile|cell)( number| no)?\s*$"),
    )
)


def question_intents(text: str | None) -> list[str]:
    """Intent tags for ``text`` (possibly empty), in rule order."""
    if not text:
        return []
    raw = strip_accents(text).strip()
    out = [name for name, rx in _INTENT_RULES if rx.search(raw)]
    # "why us" style questions are not about the role
    if "why_company" in out and "why_role" in out and re.search(r"\b(role|position)\b", raw, re.I) and not re.search(
        r"\b(company|us|here|team|mission)\b", raw, re.I
    ):
        out.remove("why_company")
    return out


#: Phrase -> replacement applied before tokenising for embeddings, so paraphrases share
#: tokens ("work here" ~ "join us" ~ "join our team").
_SYNONYMS: tuple[tuple[re.Pattern[str], str], ...] = tuple(
    (re.compile(rx, re.I), rep)
    for rx, rep in (
        (r"\b(join(ing)? (us|our team|the team)|work(ing)? (here|for us|with us|at our company))\b", " join company "),
        (r"\b(this|our|the) (company|organi[sz]ation|firm|team)\b", " company "),
        (r"\b(position|job|opening|opportunity)\b", " role "),
        (r"\b(compensation|remuneration|pay|ctc|wage)\b", " salary "),
        (r"\b(expectations?|expected|desired)\b", " expect "),
        (r"\b(authori[sz]ation|authori[sz]ed|eligible|eligibility)\b", " authorized "),
        (r"\b(sponsorship|sponsor(ed|ing)?)\b", " sponsor "),
        (r"\b(relocating|relocation|relocate)\b", " relocate "),
        (r"\b(motivates?|motivated|excites?|excited|draws?|attracts?|interests?|interested)\b", " interest "),
        (r"\b(want|wish|like)\b", " want "),
        (r"\b(years?|yrs?)\b", " years "),
    )
)


def canonical_text(text: str | None) -> str:
    """Synonym-folded, stopword-free text used for embeddings."""
    if not text:
        return ""
    s = strip_accents(text).lower()
    for rx, rep in _SYNONYMS:
        s = rx.sub(rep, s)
    return " ".join(t for t in normalize_question(s).split() if t not in STOPWORDS)


# -------------------------------------------------------------------------------------
# option matching
# -------------------------------------------------------------------------------------

_YES = re.compile(r"^\s*(y|yes|yeah|yep|true|i do|i am|i will|i can|i have|agree|i agree|accept|i accept|correct|affirmative|1)\b", re.I)
_NO = re.compile(r"^\s*(n|no|nope|false|i do not|i don't|i am not|i'm not|i will not|i won't|i cannot|i can't|disagree|decline|0)\b", re.I)
DECLINE_RX = re.compile(
    r"decline|prefer not|rather not|do not wish|don't wish|not wish to|choose not|not to (say|answer|disclose|self.?identify)"
    r"|wish not|i don't want to answer|undisclosed|not specified",
    re.I,
)


def yes_no(value: str | bool | None) -> bool | None:
    """Interpret ``value`` as yes/no (None when it's neither)."""
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    v = value.strip()
    if DECLINE_RX.search(v):
        return None
    if _NO.match(v):
        return False
    if _YES.match(v):
        return True
    return None


_BARE_YES_NO = frozenset({"yes", "no", "y", "n", "true", "false"})


def match_option(answer: str | bool | None, options: Sequence[str]) -> str | None:
    """The option (verbatim) that ``answer`` corresponds to, or None if ambiguous.

    Tries: exact (normalized) match, decline-variants, yes/no semantics, then a unique
    containment match in either direction.
    """
    if answer is None or not options:
        return None
    if isinstance(answer, bool):
        answer = "Yes" if answer else "No"
    a_norm = normalize_question(answer)
    norm_opts = [(o, normalize_question(o)) for o in options]
    for o, n in norm_opts:
        if n == a_norm:
            return o
    if DECLINE_RX.search(answer):
        dec = [o for o, _ in norm_opts if DECLINE_RX.search(o)]
        return dec[0] if dec else None
    yn = yes_no(answer)
    if yn is not None:
        cands = [o for o, _ in norm_opts if yes_no(o) is yn]
        if len(cands) == 1:
            return cands[0]
        if cands:
            # Several affirmative (or negative) options: only a bare "Yes"/"No" is a safe
            # pick ("Yes" over "Yes, I will require sponsorship"). "Yes - US Citizen" vs
            # "Yes - Green Card holder" is ambiguous -> None (never pick the shortest).
            bare = [o for o, n in norm_opts if o in cands and n in _BARE_YES_NO]
            return bare[0] if len(bare) == 1 else None
    if a_norm:
        contains = [o for o, n in norm_opts if n and (a_norm in n or n in a_norm)]
        if len(contains) == 1:
            return contains[0]
    return None


def decline_option(options: Sequence[str]) -> str | None:
    for o in options:
        if DECLINE_RX.search(o):
            return o
    return None


# -------------------------------------------------------------------------------------
# countries
# -------------------------------------------------------------------------------------

#: alias (lowercase) -> ISO-3166 alpha-2. Small on purpose: the markets people apply to.
COUNTRY_ALIASES: dict[str, str] = {
    "united states": "US", "united states of america": "US", "usa": "US", "u.s.": "US", "u.s.a.": "US", "us": "US",
    "america": "US", "united kingdom": "GB", "uk": "GB", "u.k.": "GB", "great britain": "GB", "britain": "GB",
    "england": "GB", "scotland": "GB", "canada": "CA", "india": "IN", "germany": "DE", "france": "FR",
    "netherlands": "NL", "the netherlands": "NL", "ireland": "IE", "spain": "ES", "portugal": "PT", "italy": "IT",
    "poland": "PL", "sweden": "SE", "norway": "NO", "denmark": "DK", "finland": "FI", "switzerland": "CH",
    "austria": "AT", "belgium": "BE", "australia": "AU", "new zealand": "NZ", "singapore": "SG", "japan": "JP",
    "south korea": "KR", "korea": "KR", "china": "CN", "hong kong": "HK", "israel": "IL", "brazil": "BR",
    "mexico": "MX", "argentina": "AR", "united arab emirates": "AE", "uae": "AE", "estonia": "EE",
    "european union": "EU", "eu": "EU",
}
#: A few big cities / states -> country, for job locations like "San Francisco, CA".
_LOCATION_HINTS: dict[str, str] = {
    "san francisco": "US", "new york": "US", "nyc": "US", "seattle": "US", "austin": "US", "boston": "US",
    "los angeles": "US", "chicago": "US", "denver": "US", "remote - us": "US", "remote, us": "US",
    "london": "GB", "manchester": "GB", "edinburgh": "GB", "toronto": "CA", "vancouver": "CA", "montreal": "CA",
    "bangalore": "IN", "bengaluru": "IN", "mumbai": "IN", "delhi": "IN", "new delhi": "IN", "gurgaon": "IN",
    "gurugram": "IN", "hyderabad": "IN", "pune": "IN", "chennai": "IN", "noida": "IN", "berlin": "DE",
    "munich": "DE", "paris": "FR", "amsterdam": "NL", "dublin": "IE", "sydney": "AU", "melbourne": "AU",
    "tokyo": "JP", "tel aviv": "IL", "zurich": "CH", "stockholm": "SE",
}
_CASE_SENSITIVE_ALIASES: dict[str, re.Pattern[str]] = {
    "us": re.compile(r"(?<![A-Za-z])U\.?S\.?(?![A-Za-z])"),
    "eu": re.compile(r"(?<![A-Za-z])E\.?U\.?(?![A-Za-z])"),
}
_US_STATES = {
    "al", "ak", "az", "ar", "ca", "co", "ct", "de", "fl", "ga", "hi", "id", "il", "in", "ia", "ks", "ky", "la", "me",
    "md", "ma", "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj", "nm", "ny", "nc", "nd", "oh", "ok", "or", "pa",
    "ri", "sc", "sd", "tn", "tx", "ut", "vt", "va", "wa", "wv", "wi", "wy", "dc",
}


def extract_country(text: str | None, *, location_mode: bool = False) -> str | None:
    """ISO-2 code of a country named in ``text`` (question or job location), else None.

    ``location_mode`` also understands city names and "City, ST" US-state suffixes.
    """
    if not text:
        return None
    s = " " + strip_accents(text).lower() + " "
    best: tuple[int, str] | None = None
    for alias, code in COUNTRY_ALIASES.items():
        if alias in _CASE_SENSITIVE_ALIASES:
            # "us" / "eu" are ordinary words in lowercase ("why us?"): require capitals.
            m = _CASE_SENSITIVE_ALIASES[alias].search(text)
        else:
            m = re.search(r"(?<![a-z])" + re.escape(alias) + r"(?![a-z])", s)
        if m and (best is None or len(alias) > best[0]):
            best = (len(alias), code)
    if best:
        return best[1]
    if location_mode:
        for city, code in _LOCATION_HINTS.items():
            if city in s:
                return code
        m = re.search(r",\s*([a-z]{2})\s*(?:,|$|\()", strip_accents(text).lower().strip() + " ")
        if m and m.group(1) in _US_STATES:
            return "US"
    return None


def unique(items: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(i for i in items if i))
