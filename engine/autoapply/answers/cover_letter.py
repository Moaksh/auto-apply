"""Cover letters generated ONLY from profile + story bank + JD (no invented facts).

Generation is grounded (the prompt contains nothing but numbered facts, stories and the
JD) and followed by a deterministic **fact check** (:func:`fact_check`): every number,
year, percentage, proper noun / technology and employer-like phrase in the letter must
appear in the allowed corpus (profile + stories + JD + company name) as whole words;
claims in first-person sentences must be backed by the candidate's own facts (profile +
stories + company/role name), never by the JD alone. Unsupported claims
trigger one regeneration with feedback; if claims are still unsupported the letter is
returned with ``grounded=False`` and callers must not use it (the agentic tool refuses).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from autoapply.answers.resolver import profile_facts, story_text, trim
from autoapply.answers.textnorm import strip_accents
from autoapply.llm.provider import LLMProvider, TokenUsage
from autoapply.models import Company, Job, Profile, Story


@dataclass(slots=True)
class CoverLetter:
    text: str
    path: Path | None
    story_ids: list[int]
    tokens_in: int = 0
    tokens_out: int = 0
    #: claims the fact check could not find in profile / stories / JD
    unsupported_claims: list[str] = field(default_factory=list)
    grounded: bool = True
    attempts: int = 1


# -------------------------------------------------------------------------------------
# fact check
# -------------------------------------------------------------------------------------

#: Capitalised words that are normal in a letter and are not claims.
_COMMON_CAPS = frozenset(
    """
    i i'm i've i'd i'll dear hello hi hiring manager team sincerely regards best kind warm thank thanks yours
    the a an and but or so yet for in on at to of with as by from this that these those my our your their its
    it we you he she they me us them there here when while after before during since because although though
    however moreover additionally furthermore also today currently recently previously finally first second
    third last next please sir madam mr mrs ms dr recruiter recruiting talent acquisition hr people
    january february march april may june july august september october november december
    monday tuesday wednesday thursday friday saturday sunday what why how where who which
    looking excited eager thrilled happy glad keen delighted grateful confident certain sure
    as at over across throughout through having being given working building leading
    """.split()
)

_NUM_RX = re.compile(r"(?<![\w.])(\$|€|£|₹)?\d[\d,]*(?:\.\d+)?\s*(%|x|k|m|b|\+|million|billion|thousand|years?|months?|weeks?)?(?![\w])", re.I)
_CAP_RX = re.compile(r"\b([A-Z][\w+#.\-]*[\w+#]|[A-Z])(?:\s+(?:[A-Z][\w+#.\-]*[\w+#]|of|and|&)){0,4}")
_TECH_RX = re.compile(r"\b\w*[+#]\w*|\b[a-z]+[A-Z]\w*\b")  # C++, C#, camelCase (gRPC, iOS, macOS)


def _corpus_norm(text: str) -> str:
    s = strip_accents(text).lower()
    s = re.sub(r"[^a-z0-9+#%.$€£₹ ]+", " ", s)
    return " " + re.sub(r"\s+", " ", s) + " "


def _num_key(token: str) -> str:
    return re.sub(r"[,\s]", "", token.lower())


def extract_claims(text: str) -> list[str]:
    """Claim-like tokens: numbers (with units), proper nouns / technologies."""
    claims: list[str] = []
    for m in _NUM_RX.finditer(text):
        claims.append(m.group(0).strip())
    # proper-noun phrases, ignoring sentence-initial common words
    for sent in re.split(r"(?<=[.!?])\s+|\n+", text):
        for m in _CAP_RX.finditer(sent):
            phrase = m.group(0).strip(" .-")
            words = [w for w in re.split(r"\s+", phrase) if w]
            # drop leading/trailing common words ("Dear Stripe" -> "Stripe", "I" -> "")
            while words and words[0].lower().strip(".,'’") in _COMMON_CAPS:
                words = words[1:]
            while words and words[-1].lower() in {"of", "and", "&"} | _COMMON_CAPS:
                words = words[:-1]
            if words:
                claims.append(" ".join(words))
    claims.extend(m.group(0) for m in _TECH_RX.finditer(text))
    return list(dict.fromkeys(c for c in claims if c))


_FIRST_PERSON_RX = re.compile(r"(?<![\w'’])(I|I'm|I’m|I've|I’ve|I'd|I’d|I'll|I’ll|my|My|me|myself)(?![\w'’])")


def _tokens(text: str) -> set[str]:
    norm = _corpus_norm(text)
    norm = re.sub(r"\.(?=\s)|(?<=\s)\.", " ", norm)  # sentence dots are not part of a word
    return {t for t in norm.split() if t}


def _word_supported(word: str, tokens: set[str]) -> bool:
    w = re.sub(r"['’]s$", "", word)  # possessive: "Stripe's" -> "Stripe"
    parts = [p for p in _tokens(w) if p]
    if not parts:
        return True
    for p in parts:
        variants = {p, p.rstrip("."), p[:-1] if p.endswith("s") and len(p) > 3 else p, p + "s"}
        if not variants & tokens:
            return False
    return True


def _numbers(sources: list[str]) -> tuple[set[str], set[str]]:
    nums = {_num_key(m.group(0)) for m in _NUM_RX.finditer("\n".join(sources))}
    return nums, {re.sub(r"\D", "", n) for n in nums}


def _check_claims(claims: list[str], sources: list[str]) -> list[str]:
    tokens = _tokens("\n".join(sources))
    corpus_nums, corpus_digits = _numbers(sources)
    unsupported: list[str] = []
    for claim in claims:
        if re.match(r"^[\d$€£₹]", claim):
            key = _num_key(claim)
            digits = re.sub(r"\D", "", claim)
            if key in corpus_nums or (digits and digits in corpus_digits and not re.search(r"%|x|k|m|b|million|billion", key)):
                continue
            unsupported.append(claim)
            continue
        words = [w for w in re.split(r"\s+", claim) if w.lower() not in {"of", "and", "&"}]
        if all(_word_supported(w, tokens) for w in words):
            continue
        unsupported.append(claim)
    return unsupported


def fact_check(text: str, allowed_sources: list[str], candidate_sources: list[str] | None = None) -> list[str]:
    """Claims in ``text`` that do not appear in any allowed source (case-insensitive).

    Words are matched as whole tokens ("Rust" is not supported by "trust", "Java" not by
    "JavaScript"); multi-word proper nouns pass if every significant word appears; numbers
    must appear verbatim (ignoring thousands separators / spacing).

    With ``candidate_sources`` (profile + stories + company/role name), claims made in a
    first-person sentence ("I bring 5+ years of Kubernetes") must be supported by the
    candidate's own facts — the job description cannot vouch for the candidate."""
    unsupported: list[str] = []
    for sent in re.split(r"(?<=[.!?])\s+|\n+", text):
        if not sent.strip():
            continue
        sources = candidate_sources if (candidate_sources is not None and _FIRST_PERSON_RX.search(sent)) else allowed_sources
        unsupported += _check_claims(extract_claims(sent), sources)
    return list(dict.fromkeys(unsupported))


# -------------------------------------------------------------------------------------
# generation
# -------------------------------------------------------------------------------------

_SCHEMA = {
    "type": "object",
    "properties": {
        "text": {"type": "string"},
        "story_ids": {"type": "array", "items": {"type": "integer"}},
    },
    "required": ["text", "story_ids"],
    "additionalProperties": False,
}

SYSTEM = (
    "You write short, specific cover letters. HARD RULE: every statement about the candidate must come from the "
    "numbered FACTS or the STORIES given. Do not invent employers, titles, metrics, numbers, technologies, degrees, "
    "or dates. You may reference the company and role using the job description. No placeholders, no clichés, "
    "no 'I am writing to apply'. First person, plain text, no markdown. Format: a greeting line, then 3 short "
    "paragraphs separated by blank lines, then a sign-off line and the candidate's name on its own line."
)


def candidate_sources(profile: Profile, stories: list[Story], job: Job, company: Company) -> list[str]:
    """What may back a first-person claim: the candidate's facts plus the names of the
    company and the role (so "I'd love to join Stripe as a Backend Engineer" passes)."""
    return [
        *profile_facts(profile),
        *(story_text(s) for s in stories),
        profile.raw_text or "",
        job.title,
        company.name,
        company.domain or "",
    ]


def allowed_sources(profile: Profile, stories: list[Story], job: Job, company: Company) -> list[str]:
    return [
        *profile_facts(profile),
        *(story_text(s) for s in stories),
        profile.raw_text or "",
        job.title,
        job.description or "",
        job.location or "",
        company.name,
        company.domain or "",
    ]


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", strip_accents(s).lower()).strip("-")[:60] or "letter"


async def generate_cover_letter(
    llm: LLMProvider,
    *,
    profile: Profile,
    stories: list[Story],
    job: Job,
    company: Company,
    out_dir: Path | None = None,
    max_words: int = 250,
    max_attempts: int = 2,
) -> CoverLetter:
    """Generate (and optionally write to ``out_dir``) a cover letter for ``job``."""
    facts = profile_facts(profile)
    fact_lines = "\n".join(f"F{i + 1}. {f}" for i, f in enumerate(facts)) or "(no facts)"
    story_lines = "\n".join(story_text(s) for s in stories) or "(no stories)"
    sources = allowed_sources(profile, stories, job, company)
    own_sources = candidate_sources(profile, stories, job, company)
    base_prompt = (
        f"COVER LETTER for the role \"{job.title}\" at {company.name}.\n"
        f"At most {max_words} words. Address it to the {company.name} hiring team. Sign with the candidate's name"
        + (f" ({profile.full_name})" if profile.full_name else "") + ".\n\n"
        f"FACTS about the candidate:\n{fact_lines}\n\nSTORIES:\n{story_lines}\n\n"
        f"JOB DESCRIPTION:\n{trim(job.description, 4000)}\n\n"
        "Return the letter text and the ids of the stories you used."
    )
    usage = TokenUsage()
    prompt = base_prompt
    text, story_ids, unsupported = "", [], []
    attempts = 0
    for attempts in range(1, max_attempts + 1):
        res = await llm.complete(prompt, system=SYSTEM, schema=_SCHEMA, max_tokens=900)
        usage.add(res.usage)
        text = _clip_words(str(res.data["text"]).strip(), max_words)
        valid = {s.id for s in stories}
        story_ids = [int(i) for i in res.data.get("story_ids", []) if int(i) in valid]
        unsupported = fact_check(text, sources, own_sources)
        if not unsupported:
            break
        prompt = (
            base_prompt
            + "\n\nYOUR PREVIOUS DRAFT contained claims that are NOT in the facts: "
            + "; ".join(unsupported)
            + ". Rewrite without them, using only the facts."
        )
    letter = CoverLetter(
        text=text, path=None, story_ids=story_ids, tokens_in=usage.input_tokens, tokens_out=usage.output_tokens,
        unsupported_claims=unsupported, grounded=not unsupported, attempts=attempts,
    )
    if out_dir is not None and letter.grounded:
        out_dir.mkdir(parents=True, exist_ok=True)
        # The recruiter sees this file name: "<Name> - Cover Letter - <Company>.txt" (one folder per job).
        who = (profile.full_name or "Cover Letter").strip()
        safe = lambda s: re.sub(r"[^\w .&-]+", "", s).strip()[:60]  # noqa: E731
        path = out_dir / str(job.id) / f"{safe(who)} - Cover Letter - {safe(company.name)}.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text + "\n", encoding="utf-8")
        letter.path = path
    return letter


_SIGN_OFF = re.compile(r"\n\s*(sincerely|best regards|kind regards|regards|thank you|thanks|warm regards|yours (truly|sincerely))\b.*$", re.I | re.S)


def _clip_words(text: str, max_words: int) -> str:
    """Trim to ``max_words`` keeping paragraphs (the old version re-joined words with single spaces,
    flattening the letter into one block) and keeping the sign-off."""
    words = list(re.finditer(r"\S+", text))
    if len(words) <= max_words:
        return text
    m = _SIGN_OFF.search(text)
    sign_off = text[m.start():].strip() if m else ""
    body = text[: m.start()] if m else text
    budget = max(1, max_words - len(sign_off.split()))
    body_words = list(re.finditer(r"\S+", body))
    if len(body_words) > budget:
        body = body[: body_words[budget - 1].end()]
        end = max(body.rfind("."), body.rfind("!"), body.rfind("?"))
        if end > len(body) // 2:
            body = body[: end + 1]
    return body.rstrip() + ("\n\n" + sign_off if sign_off else "")
