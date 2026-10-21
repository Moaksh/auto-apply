"""Writing voice for generated prose: make cover letters, outreach and long form answers sound
like a person (the user), not a model.

Three parts:

* **Voice profile** (:class:`~autoapply.models.VoiceProfile`, stored in ``meta``): preferred
  sign-off, formality, a length cap, phrases to avoid and an optional short sample of the
  user's own writing. Defaults suit an Indian job seeker writing in English: neutral
  formality, "Best regards".
* **Prompt guidance** (:func:`prompt_guidance`): a short style block appended to generation
  prompts. It is style only: the generators' grounding rules and fact checks are unchanged,
  and the writing sample is explicitly not a source of facts (anything taken from it fails the
  fact check like any other unsupported claim).
* **Linter** (:func:`lint` / :func:`polish`): deterministic "AI tells" rules that flag and,
  where safe, rewrite. Rewrites only remove filler or swap a word for a plainer one; each
  rewrite is checked to keep every number and proper noun (``_facts``) and is dropped (left
  as a flag) otherwise. :func:`polish` also re-runs the caller's fact check and keeps the
  original text if the rewrite would add an unsupported claim.

Rule ids: ``em_dash``, ``hope_well``, ``writing_to_express``, ``delve``, ``leverage``,
``passionate_about``, ``excited_to``, ``synergy``, ``cutting_edge``, ``fast_paced``,
``triple_adjectives``, ``exclamations``, ``generic_opener``, ``generic_closer``, ``sign_off``,
``ai_vocabulary``, ``avoid_phrase``, ``too_long``.

The banned-word and rule-of-three ideas are adapted from career-ops' ``voice-dna.template.md``
(MIT; see THIRD_PARTY_NOTICES.md).
"""

from __future__ import annotations

import logging
import re
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Literal

from pydantic import ValidationError

from autoapply import db
from autoapply.enums import Formality
from autoapply.models import VoiceProfile

log = logging.getLogger("autoapply.answers.voice")

META_VOICE_PROFILE = "voice_profile"
SAMPLE_CHARS_IN_PROMPT = 600

Kind = Literal["cover_letter", "email", "linkedin_note", "linkedin_dm", "answer"]
_SIGNED_KINDS = frozenset({"cover_letter", "email", "linkedin_dm"})

# =====================================================================================
# Profile storage
# =====================================================================================

_active: VoiceProfile | None = None


def load_profile(conn: sqlite3.Connection) -> VoiceProfile:
    """The stored profile, or the defaults (a damaged value is ignored, not fatal)."""
    raw = db.get_meta(conn, META_VOICE_PROFILE, None)
    if not isinstance(raw, dict):
        return VoiceProfile()
    try:
        return VoiceProfile.model_validate(raw)
    except ValidationError:
        log.warning("ignoring an invalid stored voice profile")
        return VoiceProfile()


def update_profile(conn: sqlite3.Connection, patch: dict[str, Any]) -> VoiceProfile:
    """Apply the keys present in ``patch`` (None resets a field to its default) and store."""
    current = load_profile(conn).model_dump(mode="json")
    defaults = VoiceProfile().model_dump(mode="json")
    for k, v in patch.items():
        if k not in defaults:
            raise ValueError(f"unknown voice profile field {k!r}")
        if isinstance(v, str):
            v = v.strip() or None
        if k == "avoid_phrases" and v is not None:
            v = list(dict.fromkeys(p.strip() for p in v if p and p.strip()))
        if k == "sign_off" and v is not None:
            v = v.rstrip(",").strip() or None
        current[k] = defaults[k] if v is None else getattr(v, "value", v)
    profile = VoiceProfile.model_validate(current)
    db.set_meta(conn, META_VOICE_PROFILE, profile.model_dump(mode="json"))
    set_active(profile)
    return profile


def set_active(profile: VoiceProfile | None) -> None:
    """The profile used by generators that have no database connection (the cover letter
    writer is called from the apply adapters). The daemon sets it at start and on update."""
    global _active
    _active = profile


def active() -> VoiceProfile:
    return _active or VoiceProfile()


# =====================================================================================
# Prompt guidance
# =====================================================================================

_TONE = {
    Formality.CASUAL: "Friendly and relaxed, like a message to a senior colleague you get on with. Contractions are fine.",
    Formality.NEUTRAL: "Plain and polite, like a capable professional writing to someone they respect. Contractions are fine.",
    Formality.FORMAL: "Courteous and formal, with full sentences and no contractions or slang.",
}

#: What the guidance tells the model to avoid (the linter's rules, in words).
_AVOID = (
    "em dashes (use commas or full stops), exclamation marks, \"I hope this email finds you well\", "
    "\"I am writing to express my interest\", \"delve\", \"leverage\" as a verb, \"passionate about\", "
    "\"excited to\", \"synergy\", \"cutting-edge\", \"fast-paced environment\", lists of three adjectives, "
    "and stock openers or closers such as \"Please do not hesitate to contact me\""
)


def prompt_guidance(profile: VoiceProfile | None = None, *, kind: Kind = "email") -> str:
    """Style block appended to a generation prompt. Style only: it never relaxes the fact rules."""
    p = profile or active()
    lines = [
        "WRITING VOICE (style only; every fact rule above still applies):",
        f"- Tone: {_TONE[p.formality]}",
        "- Sound like a real person: specific, direct, varied sentence length, no filler or hype.",
        f"- Avoid {_AVOID}.",
    ]
    if kind in _SIGNED_KINDS:
        lines.append(f"- Sign off with \"{p.sign_off},\" on its own line, then the name.")
    if kind in ("cover_letter", "email"):
        lines.append(f"- Keep it under {p.max_words} words.")
    if p.avoid_phrases:
        lines.append("- Never use these phrases: " + "; ".join(f"\"{x}\"" for x in p.avoid_phrases) + ".")
    if p.writing_sample:
        sample = re.sub(r"\s+", " ", p.writing_sample).strip()[:SAMPLE_CHARS_IN_PROMPT]
        lines.append("- Match the rhythm and word choice of this sample of the candidate's own writing. It is NOT a "
                     f"source of facts; take nothing from it but style: \"\"\"{sample}\"\"\"")
    return "\n".join(lines)


# =====================================================================================
# Linter
# =====================================================================================


@dataclass(slots=True, frozen=True)
class VoiceIssue:
    rule: str
    text: str  # what was found
    fixed: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {"rule": self.rule, "text": self.text, "fixed": self.fixed}


@dataclass(slots=True)
class VoiceResult:
    text: str
    issues: list[VoiceIssue] = field(default_factory=list)
    #: set by :func:`polish` when the caller's fact check rejected the rewrite
    reverted: bool = False

    @property
    def changed(self) -> list[VoiceIssue]:
        return [i for i in self.issues if i.fixed]

    @property
    def flagged(self) -> list[VoiceIssue]:
        return [i for i in self.issues if not i.fixed]

    def report(self) -> dict[str, Any]:
        """What the result records: ``{"changed": [...], "flagged": [...], "reverted": bool}``."""
        return {"changed": [i.as_dict() for i in self.changed], "flagged": [i.as_dict() for i in self.flagged],
                "reverted": self.reverted}


# ---- fact guard ---------------------------------------------------------------------------

#: Capitalised words that are not facts (greetings, sign-offs, pronouns).
_NEUTRAL_CAPS = frozenset(
    """
    i i'm i’m i've i’ve i'd i’d i'll i’ll dear hi hello hey thanks thank best regards kind warm warmest sincerely
    yours cheers many respectfully team hiring manager
    """.split()
)
_WORD_RX = re.compile(r"[A-Za-z0-9₹$€£][\w+#&'’%.-]*")


def _facts(text: str, extra_neutral: frozenset[str] = frozenset()) -> set[str]:
    """Numbers and non-sentence-initial capitalised words: what a rewrite must never lose."""
    out: set[str] = set()
    for sent in re.split(r"(?<=[.!?])\s+|\n+|[—–]", text):
        for i, m in enumerate(_WORD_RX.finditer(sent)):
            w = m.group(0).rstrip(".'’-")
            if not w:
                continue
            if re.search(r"\d", w):
                out.add(w.lower())
            elif i > 0 and w[0].isupper() and w.lower() not in _NEUTRAL_CAPS and w.lower() not in extra_neutral:
                out.add(w)
    return out


# ---- helpers ------------------------------------------------------------------------------


def _match_case(src: str, repl: str) -> str:
    return repl[:1].upper() + repl[1:] if src[:1].isupper() else repl


def _tidy(text: str) -> str:
    """Whitespace / punctuation left behind by a removal (never changes words or letter case)."""
    s = re.sub(r"(?<=\S) {2,}", " ", text)
    s = re.sub(r"(?<=\w) +([,.;:!?])", r"\1", s)
    s = re.sub(r",[ \t]*([,.;:!?])", r"\1", s)
    s = re.sub(r"[ \t]+\n", "\n", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


Rule = Callable[[str, VoiceProfile, str], tuple[str, list[VoiceIssue]]]


def _sub_rule(rule: str, pattern: str, repl: Callable[[re.Match[str], VoiceProfile], str] | None,
              flags: int = re.I) -> Rule:
    """A regex rule: ``repl`` None = flag only."""
    rx = re.compile(pattern, flags)

    def run(text: str, p: VoiceProfile, kind: str) -> tuple[str, list[VoiceIssue]]:
        found = [m.group(0).strip() for m in rx.finditer(text)]
        if not found:
            return text, []
        if repl is None:
            return text, [VoiceIssue(rule, f) for f in found]
        return rx.sub(lambda m: repl(m, p), text), [VoiceIssue(rule, f, True) for f in found]

    return run


def _contract(p: VoiceProfile, informal: str, formal: str) -> str:
    return formal if p.formality is Formality.FORMAL else informal


# ---- rules --------------------------------------------------------------------------------

_EM_DASH_RX = re.compile(r"\s*—\s*|(?<=\w)--(?=\w)|\s+--\s+")


def _em_dash(text: str, p: VoiceProfile, kind: str) -> tuple[str, list[VoiceIssue]]:
    # A line that is only a dash (a separator) is not prose.
    count = sum(len(_EM_DASH_RX.findall(line)) for line in text.split("\n") if line.strip() not in ("—", "--"))
    if count < 2:
        return text, []
    lines = []
    for line in text.split("\n"):
        if line.strip() in ("—", "--"):
            lines.append(line)
            continue
        # Keep number ranges ("2019—2021") as an en dash.
        line = re.sub(r"(?<=\d)\s*—\s*(?=\d)", "–", line)
        lines.append(_EM_DASH_RX.sub(", ", line))
    return "\n".join(lines), [VoiceIssue("em_dash", f"{count} em dashes", True)]


_hope_well = _sub_rule(
    "hope_well",
    r"(?:^|(?<=[\s,]))(?:I\s+)?hope\s+(?:this|my)\s+(?:e-?mail|message|note|letter)\s+finds\s+you\s+(?:well|in good health)[^.!?\n]*[.!?]?[ \t]*"
    r"|(?:^|(?<=[\s,]))I\s+hope\s+you(?:'re|’re|\s+are)\s+(?:doing\s+)?well[^.!?\n]*[.!?]?[ \t]*",
    lambda m, p: "",
)

_writing_to_express = _sub_rule(
    "writing_to_express",
    r"\bI(?:\s+am|'m|’m)\s+writing\s+to\s+(?:express|convey)\s+my\s+(?:(?:strong|keen|sincere|deep|great)\s+)?interest\s+in\b",
    lambda m, p: _contract(p, "I'm interested in", "I am interested in"),
)
_writing_to_apply = _sub_rule(
    "writing_to_express",
    r"\bI(?:\s+am|'m|’m)\s+writing\s+to\s+apply\s+for\b",
    lambda m, p: _contract(p, "I'd like to apply for", "I would like to apply for"),
)

_DELVE = {"delve": "dig", "delves": "digs", "delved": "dug", "delving": "digging"}
_delve = _sub_rule("delve", r"\b(delve|delves|delved|delving)\b",
                   lambda m, p: _match_case(m.group(1), _DELVE[m.group(1).lower()]))

_LEVERAGE = {"leveraged": "used", "leveraging": "using", "leverages": "uses"}
_leverage_forms = _sub_rule("leverage", r"\b(leveraged|leveraging|leverages)\b(?!\s+(?:ratio|buyout)s?\b)",
                            lambda m, p: _match_case(m.group(1), _LEVERAGE[m.group(1).lower()]))
_leverage_base = _sub_rule(
    "leverage",
    r"\b(to|can|could|will|would|should|must|I|we|you|they|and|help(?:ed)?\s+(?:me|us))\s+leverage\b",
    lambda m, p: m.group(1) + " use",
)

_passionate_fix = _sub_rule(
    "passionate_about",
    r"\b(I|we)(?:\s+am|\s+are|'m|’m|'re|’re)\s+(?:(?:very|deeply|truly|really|extremely|genuinely)\s+)?passionate\s+about\b",
    lambda m, p: f"{m.group(1)} care about",
)
_passionate_flag = _sub_rule("passionate_about", r"\bpassionate\s+about\b", None)

_excited_fix = _sub_rule(
    "excited_to",
    r"\bI(?:\s+am|'m|’m)\s+(?:(?:so|very|really|incredibly|truly|extremely|super)\s+)?excited\s+to\b",
    lambda m, p: _contract(p, "I'd like to", "I would like to"),
)
_excited_would = _sub_rule("excited_to", r"\b(would\s+be|I'd\s+be|I’d\s+be)\s+(?:(?:so|very|really)\s+)?excited\s+to\b",
                           lambda m, p: f"{m.group(1)} glad to")
_excited_flag = _sub_rule("excited_to", r"\bexcited\s+(?:to|about)\b", None)

_synergy = _sub_rule("synergy", r"\bsynerg(?:y|ies|istic|ize|ise|izing|ising)\b", None)
_cutting_edge = _sub_rule("cutting_edge", r"\b(?:cutting[- ]edge|state[- ]of[- ]the[- ]art|bleeding[- ]edge)\b",
                          lambda m, p: _match_case(m.group(0), "modern"))
_fast_paced = _sub_rule("fast_paced", r"\bfast[- ]paced\s+(?:work\s+|startup\s+)?(?:environment|setting|world)s?\b", None)

_ai_vocabulary = _sub_rule(
    "ai_vocabulary",
    r"\b(?:tapestry|realm|testament\s+to|game[- ]changer|unparalleled|seamlessly|in\s+today's\s+(?:fast[- ]paced|digital|competitive)\s+\w+)\b",
    None,
)

#: Puffery adjectives: a list of three of these is rewritten to the first two.
_PUFFERY = frozenset(
    """
    motivated passionate dedicated driven hardworking hard-working dynamic innovative creative collaborative enthusiastic
    reliable detail-oriented results-driven results-oriented proactive adaptable efficient diligent curious organized
    organised energetic self-motivated versatile committed eager ambitious dependable resourceful meticulous
    """.split()
)
_ADJ_SUFFIX = re.compile(r"(?:ive|ous|ful|ient|ent|ant|able|ible|ic|al|ed|ing|less|y)$")
_TRIPLE_RX = re.compile(r"\b([a-z][a-z-]+),\s+([a-z][a-z-]+),?\s+and\s+([a-z][a-z-]+)\b")


def _triple_adjectives(text: str, p: VoiceProfile, kind: str) -> tuple[str, list[VoiceIssue]]:
    issues: list[VoiceIssue] = []

    def repl(m: re.Match[str]) -> str:
        words = [w.lower() for w in m.groups()]
        if all(w in _PUFFERY for w in words):
            issues.append(VoiceIssue("triple_adjectives", m.group(0), True))
            return f"{m.group(1)} and {m.group(2)}"
        if all(w in _PUFFERY or _ADJ_SUFFIX.search(w) for w in words) and sum(w in _PUFFERY for w in words) >= 1:
            issues.append(VoiceIssue("triple_adjectives", m.group(0)))
        return m.group(0)

    return _TRIPLE_RX.sub(repl, text), issues


def _exclamations(text: str, p: VoiceProfile, kind: str) -> tuple[str, list[VoiceIssue]]:
    prose = re.sub(r"https?://\S+", " ", text)
    count = prose.count("!")
    if count <= (0 if p.formality is Formality.FORMAL else 1):
        return text, []
    out = re.sub(r"(?<!\S)(https?://\S+)|!+", lambda m: m.group(1) or ".", text)
    return out, [VoiceIssue("exclamations", f"{count} exclamation marks", True)]


_opener_flag = _sub_rule(
    "generic_opener",
    r"\bTo\s+whom\s+it\s+may\s+concern\b|\bMy\s+name\s+is\s+[^.,\n]{1,40}?\s+and\s+I(?:\s+am|'m|’m)\b"
    r"|\bI\s+came\s+across\s+(?:your|the)\s+(?:profile|posting|opening|job|role)\b|\bI(?:\s+am|'m|’m)\s+reaching\s+out\s+to\b",
    None,
)
_closer_fix = _sub_rule(
    "generic_closer",
    r"(?:^|(?<=[\s,]))(?:Please\s+(?:do\s+not|don't|don’t)\s+hesitate\s+to\s+(?:contact|reach\s+out\s+to|reach)\s+me"
    r"|Feel\s+free\s+to\s+(?:contact\s+me|reach\s+out)\s+if\s+you\s+have\s+any\s+(?:further\s+)?questions)[^.!?\n]*[.!?]?[ \t]*",
    lambda m, p: "",
)
_closer_flag = _sub_rule(
    "generic_closer",
    r"\bI\s+look\s+forward\s+to\s+the\s+opportunity\s+to\s+discuss\s+how\s+my\b|\bThank\s+you\s+for\s+considering\s+my\s+application\b",
    None,
)

_SIGN_OFF_LINE = re.compile(
    r"^(?:best|best regards|kind regards|warm regards|warmest regards|regards|sincerely|yours sincerely|yours truly|"
    r"yours faithfully|thanks|thank you|many thanks|thanks and regards|cheers|warmly|respectfully|with gratitude|"
    r"with regards|best wishes)\s*[,.!]?$",
    re.I,
)


def _sign_off(text: str, p: VoiceProfile, kind: str) -> tuple[str, list[VoiceIssue]]:
    if kind not in _SIGNED_KINDS:
        return text, []
    lines = text.split("\n")
    nonblank = [i for i, ln in enumerate(lines) if ln.strip()]
    want = p.sign_off.rstrip(",").strip()
    for i in reversed(nonblank[-3:]):
        cur = lines[i].strip()
        if _SIGN_OFF_LINE.match(cur):
            if cur.rstrip(",.!").strip().lower() == want.lower():
                return text, []
            lines[i] = f"{want},"
            return "\n".join(lines), [VoiceIssue("sign_off", cur, True)]
    return text, []


def _avoid_phrases(text: str, p: VoiceProfile, kind: str) -> tuple[str, list[VoiceIssue]]:
    low = text.lower()
    return text, [VoiceIssue("avoid_phrase", ph) for ph in p.avoid_phrases if ph.lower() in low]


def _too_long(text: str, p: VoiceProfile, kind: str) -> tuple[str, list[VoiceIssue]]:
    if kind not in ("cover_letter", "email"):
        return text, []
    n = len(text.split())
    return text, ([VoiceIssue("too_long", f"{n} words (your limit is {p.max_words})")] if n > p.max_words else [])


#: Order matters: rewrites first (phrase-level before word-level), then flags.
RULES: tuple[tuple[str, Rule], ...] = (
    ("hope_well", _hope_well),
    ("writing_to_express", _writing_to_express),
    ("writing_to_express", _writing_to_apply),
    ("generic_closer", _closer_fix),
    ("generic_closer", _closer_flag),
    ("generic_opener", _opener_flag),
    ("passionate_about", _passionate_fix),
    ("passionate_about", _passionate_flag),
    ("excited_to", _excited_fix),
    ("excited_to", _excited_would),
    ("excited_to", _excited_flag),
    ("delve", _delve),
    ("leverage", _leverage_forms),
    ("leverage", _leverage_base),
    ("synergy", _synergy),
    ("cutting_edge", _cutting_edge),
    ("fast_paced", _fast_paced),
    ("triple_adjectives", _triple_adjectives),
    ("ai_vocabulary", _ai_vocabulary),
    ("em_dash", _em_dash),
    ("exclamations", _exclamations),
    ("sign_off", _sign_off),
    ("avoid_phrase", _avoid_phrases),
    ("too_long", _too_long),
)


def lint(text: str, profile: VoiceProfile | None = None, *, kind: Kind = "email") -> VoiceResult:
    """Run every rule. A rewrite that would lose a number or proper noun is undone and kept
    as a flag; the rest of the text is never touched."""
    p = profile or active()
    neutral = frozenset(w.lower() for w in re.findall(r"[\w'’]+", p.sign_off))
    current = text or ""
    issues: list[VoiceIssue] = []
    for _rule_id, rule in RULES:
        new, found = rule(current, p, kind)
        if not found:
            continue
        if new != current:
            new = _tidy(new)
            if _facts(current, neutral) - _facts(new, neutral):
                issues += [VoiceIssue(i.rule, i.text, False) for i in found]  # unsafe: flag only
                continue
            current = new
        issues += found
    # Same finding reported once (a fix and its leftover flag can overlap).
    seen: set[tuple[str, str]] = set()
    uniq = []
    for i in issues:
        key = (i.rule, i.text.lower())
        if key in seen:
            continue
        seen.add(key)
        uniq.append(i)
    # A flag whose text the fix already removed ("passionate about" after "I care about") is noise.
    final = [i for i in uniq if i.fixed or i.rule in ("too_long", "em_dash", "exclamations")
             or i.text.lower() in current.lower()]
    return VoiceResult(text=current if any(i.fixed for i in final) else (text or ""), issues=final)


def polish(text: str, profile: VoiceProfile | None = None, *, kind: Kind = "email",
           verify: Callable[[str], list[str]] | None = None) -> VoiceResult:
    """:func:`lint`, then (with ``verify``, the caller's fact check) keep the original text if the
    rewrite would add an unsupported claim. Rewrites never change facts."""
    res = lint(text, profile, kind=kind)
    if verify is not None and res.text != text:
        before, after = set(verify(text)), set(verify(res.text))
        if after - before:
            return VoiceResult(text=text, issues=[VoiceIssue(i.rule, i.text, False) for i in res.issues], reverted=True)
    return res


__all__ = [
    "META_VOICE_PROFILE", "RULES", "VoiceIssue", "VoiceResult", "active", "lint", "load_profile", "polish",
    "prompt_guidance", "set_active", "update_profile",
]
