"""Grounded outreach drafts (plan §C.7), reusing the cover-letter fact check.

Sources a draft may draw on:

* ``allowed``: profile facts, stories, resume text, the job's title / description / location
  (application emails only), company name and domain, company evidence snippets (homepage
  description we fetched), the recipient's name and title, the referral basis (shared school /
  employer) when there is one;
* ``candidate`` (what may back a first-person claim): profile, stories, resume text, the
  company and role names, the recipient's name.

On top of :func:`answers.cover_letter.fact_check`, outreach-specific rules:

* nothing about the recipient beyond name / title / team unless an evidence snippet says it
  (no invented "loved your talk");
* a prospect email may not say "I applied";
* never claim someone referred the user unless a referral record says so;
* one ask per email.

One regeneration with feedback; if it is still unsupported the draft is saved with
``grounded = False`` and approval is blocked until the user edits it or confirms the claims.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

from autoapply.answers.cover_letter import fact_check
from autoapply.answers.resolver import profile_facts, story_text, trim
from autoapply.enums import DraftKind
from autoapply.llm.provider import LLMProvider, TokenUsage
from autoapply.models import Company, Job, Profile, Story

log = logging.getLogger("autoapply.outreach.drafts")

WORD_LIMITS: dict[DraftKind, int] = {
    DraftKind.APPLICATION_FOLLOWUP: 110,
    DraftKind.PROSPECT: 110,
    DraftKind.REFERRAL_EMAIL: 110,
    DraftKind.FOLLOWUP: 60,
    DraftKind.LINKEDIN_REFERRAL_DM: 120,
}
CONNECT_NOTE_CHARS = 300
SUBJECT_MAX_WORDS = 8

FOOTER_TEMPLATE = ("—\nI found your address on {source}. If you'd rather not hear from me, reply \"no thanks\" "
                   "and I won't email again.")

_SCHEMA = {
    "type": "object",
    "properties": {
        "subject": {"type": "string"},
        "body": {"type": "string"},
        "story_ids": {"type": "array", "items": {"type": "integer"}},
    },
    "required": ["body"],
}

SYSTEM = (
    "You write short, specific, honest emails for a job seeker, in their own voice. HARD RULES: every statement "
    "about the sender must come from the numbered FACTS or STORIES; never invent employers, titles, metrics, "
    "numbers, technologies, degrees or dates. Say nothing about the recipient beyond their name, title and team "
    "unless the COMPANY EVIDENCE states it. Exactly one clear ask. Plain text, no markdown, no links unless given, "
    "no placeholders, no flattery, no fake urgency. Greeting with the recipient's first name, then 2-3 short "
    "paragraphs, then a sign-off with the sender's name. Never write a footer or an unsubscribe line."
)

_KIND_BRIEF: dict[DraftKind, str] = {
    DraftKind.APPLICATION_FOLLOWUP: (
        "The sender has ALREADY APPLIED to the role below. Mention the role and that they applied, give the one or "
        "two most relevant facts, and ask whether the recipient could pass the application to the right person or "
        "spare 15 minutes."),
    DraftKind.PROSPECT: (
        "The sender has NOT applied anywhere at this company; do not say they applied. Say why this company (only "
        "from the COMPANY EVIDENCE), what the sender brings (only from FACTS / STORIES), and ask for a 15-minute "
        "chat or a pointer to the right person."),
    DraftKind.REFERRAL_EMAIL: (
        "Ask the recipient whether they would be willing to refer the sender for the role below. State the shared "
        "basis (REFERRAL BASIS) honestly; do not claim anyone already referred the sender."),
    DraftKind.FOLLOWUP: (
        "A brief, polite follow-up to the PREVIOUS EMAIL that got no reply. Add nothing new about the sender beyond "
        "one fact already given or in FACTS; restate the single ask; no guilt-tripping."),
    DraftKind.LINKEDIN_REFERRAL_DM: (
        "A LinkedIn message to a connection asking for a referral to the role below: the job link and req id if "
        "given, the sender's headline, one or two relevant facts, one ask."),
}


@dataclass(slots=True)
class DraftContext:
    kind: DraftKind
    profile: Profile
    stories: list[Story]
    company: Company
    recipient_name: str
    recipient_title: str | None = None
    job: Job | None = None
    company_evidence: list[str] = field(default_factory=list)
    referral_basis: str | None = None  # e.g. "both studied at IIT Madras"
    has_referral: bool = False  # a referral record says the sender was referred
    previous_subject: str | None = None
    previous_body: str | None = None
    instructions: str | None = None


@dataclass(slots=True)
class Draft:
    subject: str | None
    body: str
    story_ids: list[int] = field(default_factory=list)
    unsupported_claims: list[str] = field(default_factory=list)
    tokens_in: int = 0
    tokens_out: int = 0
    attempts: int = 1

    @property
    def grounded(self) -> bool:
        return not self.unsupported_claims


def footer(source_label: str) -> str:
    return FOOTER_TEMPLATE.format(source=source_label or "a public web page")


def full_body(body: str, footer_text: str | None) -> str:
    """What is actually sent: the user's text plus the footer (always)."""
    b = body.rstrip()
    return f"{b}\n\n{footer_text}" if footer_text else b


def first_name(full: str) -> str:
    parts = (full or "").split()
    return parts[0] if parts else ""


# ---- grounding --------------------------------------------------------------------------


def _job_lines(ctx: DraftContext) -> list[str]:
    if ctx.job is None:
        return []
    return [ctx.job.title, ctx.job.location or ""] + ([ctx.job.description or ""] if ctx.kind is not DraftKind.PROSPECT else [])


def allowed_sources(ctx: DraftContext) -> list[str]:
    p = ctx.profile
    return [
        *profile_facts(p), *(story_text(s) for s in ctx.stories), p.raw_text or "", *_job_lines(ctx),
        ctx.company.name, ctx.company.domain or "", *ctx.company_evidence, ctx.recipient_name, ctx.recipient_title or "",
        ctx.referral_basis or "", ctx.previous_body or "", *(p.links or {}).values(),
    ]


def candidate_sources(ctx: DraftContext) -> list[str]:
    p = ctx.profile
    return [
        *profile_facts(p), *(story_text(s) for s in ctx.stories), p.raw_text or "",
        ctx.job.title if ctx.job else "", ctx.company.name, ctx.company.domain or "", ctx.recipient_name,
        ctx.referral_basis or "", *(p.links or {}).values(),
    ]


_APPLIED_RX = re.compile(r"\bI(?:'ve|’ve| have)?\s+(?:just\s+|recently\s+|already\s+)?appl(?:ied|y)\b|\bmy application\b", re.I)
_REFERRED_RX = re.compile(r"\b(referred me|referred by|suggested (?:that )?I (?:reach out|contact|email|write)|"
                          r"recommended (?:that )?I (?:reach out|contact)|pointed me to you)\b", re.I)
_RECIPIENT_RX = re.compile(r"\byour (?:recent |great |excellent )?(talk|post|article|blog|podcast|tweet|paper|presentation|"
                           r"keynote|interview|book|newsletter|video|work on|project)\b", re.I)
_LINK_RX = re.compile(r"https?://\S+")


def outreach_violations(text: str, ctx: DraftContext) -> list[str]:
    """Outreach rules on top of the fact check (each a short explanation)."""
    out: list[str] = []
    if ctx.kind is DraftKind.PROSPECT and _APPLIED_RX.search(text):
        out.append("says you applied (this company has no application)")
    if not ctx.has_referral and _REFERRED_RX.search(text):
        out.append("claims someone referred you")
    evidence = " ".join(ctx.company_evidence).lower()
    for m in _RECIPIENT_RX.finditer(text):
        if m.group(1).lower() not in evidence:
            out.append(f"mentions their {m.group(1).lower()} (no source)")
    if text.count("?") > 1:
        out.append("more than one ask")
    allowed_links = {v.rstrip("/") for v in (ctx.profile.links or {}).values()}
    if ctx.job and ctx.job.apply_url:
        allowed_links.add(ctx.job.apply_url.rstrip("/"))
    for m in _LINK_RX.finditer(text):
        if m.group(0).rstrip("/.,)") not in allowed_links:
            out.append(f"link not from your profile: {m.group(0)}")
    return list(dict.fromkeys(out))


#: Sentence-initial words common in short emails that the cover-letter checker would read as
#: proper nouns ("Would you…", "Happy to…").
_EMAIL_COMMON = frozenset(
    """
    would could can will shall should might may do does did is are was were have has had any if let just quick hope
    happy glad following following-up circling bumping no yes not either both all each every one two three
    sure apologies sorry great good thank thanks cheers best regards hey hi hello dear re fwd ps p.s.
    """.split()
)


def check(text: str, ctx: DraftContext) -> list[str]:
    """Unsupported claims + rule violations of a draft (also used on the user's edits)."""
    body = _LINK_RX.sub(" ", text)  # links are checked by the rules, not as claims
    claims = [c for c in fact_check(body, allowed_sources(ctx), candidate_sources(ctx)) if c.lower().strip(".,!") not in _EMAIL_COMMON]
    return list(dict.fromkeys([*claims, *outreach_violations(text, ctx)]))


# ---- subject / limits ----------------------------------------------------------------------


def subject_ok(subject: str | None) -> bool:
    s = (subject or "").strip()
    return bool(s) and len(s.split()) <= SUBJECT_MAX_WORDS and not re.match(r"^(re|fwd?|fw)\s*:", s, re.I)


def fallback_subject(ctx: DraftContext) -> str:
    who = ctx.profile.full_name or "a candidate"
    if ctx.job is not None and ctx.kind is not DraftKind.PROSPECT:
        title = " ".join(ctx.job.title.split()[:4])
        return f"{title} application – {who}" if ctx.kind is DraftKind.APPLICATION_FOLLOWUP else f"Referral for {title} – {who}"
    head = " ".join((ctx.profile.headline or "Engineer").split()[:4])
    return f"{head} – {who}"


def reply_subject(previous: str | None) -> str:
    s = (previous or "").strip()
    return s if re.match(r"^re\s*:", s, re.I) else f"Re: {s}"


def clip_words(text: str, limit: int) -> str:
    words = list(re.finditer(r"\S+", text))
    if len(words) <= limit:
        return text.strip()
    cut = text[: words[limit - 1].end()]
    end = max(cut.rfind("."), cut.rfind("!"), cut.rfind("?"))
    if end > len(cut) // 2:
        cut = cut[: end + 1]
    return cut.strip()


# ---- generation ---------------------------------------------------------------------------


def _prompt(ctx: DraftContext, limit: int) -> str:
    facts = "\n".join(f"F{i + 1}. {f}" for i, f in enumerate(profile_facts(ctx.profile))) or "(no facts)"
    stories = "\n".join(story_text(s) for s in ctx.stories) or "(no stories)"
    links = ", ".join(f"{k}: {v}" for k, v in list((ctx.profile.links or {}).items())[:2]) or "(none)"
    parts = [
        f"TASK: {_KIND_BRIEF[ctx.kind]}",
        f"At most {limit} words in the body. Subject: at most {SUBJECT_MAX_WORDS} words, specific, never starting with Re: or Fwd:.",
        f"RECIPIENT: {ctx.recipient_name}" + (f", {ctx.recipient_title}" if ctx.recipient_title else "") + f" at {ctx.company.name}",
        f"SENDER: {ctx.profile.full_name or 'the candidate'}" + (f" — {ctx.profile.headline}" if ctx.profile.headline else ""),
        f"LINKS the sender may include (at most 2): {links}",
        f"FACTS about the sender:\n{facts}",
        f"STORIES:\n{stories}",
    ]
    if ctx.job is not None:
        jd = "" if ctx.kind is DraftKind.PROSPECT else f"\nJOB DESCRIPTION:\n{trim(ctx.job.description, 2500)}"
        parts.append(f"ROLE: {ctx.job.title}" + (f" ({ctx.job.location})" if ctx.job.location else "")
                     + (f"\nJOB LINK: {ctx.job.apply_url}" if ctx.job.apply_url else "") + jd)
    if ctx.company_evidence:
        parts.append("COMPANY EVIDENCE (the only things you may say about the company):\n" + "\n".join(f"- {e}" for e in ctx.company_evidence))
    if ctx.referral_basis:
        parts.append(f"REFERRAL BASIS: {ctx.referral_basis}")
    if ctx.previous_body:
        parts.append(f"PREVIOUS EMAIL (subject: {ctx.previous_subject}):\n{ctx.previous_body}")
    if ctx.instructions:
        parts.append(f"THE SENDER ASKS: {ctx.instructions.strip()[:500]}")
    parts.append("Return the subject, the body and the ids of the stories you used.")
    return "\n\n".join(parts)


async def generate(llm: LLMProvider, ctx: DraftContext, *, max_attempts: int = 2) -> Draft:
    """Draft one email (or LinkedIn message), fact-checked, with one regeneration on failure."""
    limit = WORD_LIMITS.get(ctx.kind, 110)
    base = _prompt(ctx, limit)
    usage = TokenUsage()
    prompt = base
    draft = Draft(subject=None, body="")
    for attempt in range(1, max_attempts + 1):
        res = await llm.complete(prompt, system=SYSTEM, schema=_SCHEMA, max_tokens=700)
        usage.add(res.usage)
        data = res.data or {}
        body = clip_words(str(data.get("body") or "").strip(), limit)
        valid = {s.id for s in ctx.stories}
        story_ids = [int(i) for i in data.get("story_ids") or [] if int(i) in valid]
        if ctx.kind is DraftKind.FOLLOWUP:
            subject: str | None = reply_subject(ctx.previous_subject)
        elif ctx.kind is DraftKind.LINKEDIN_REFERRAL_DM:
            subject = None
        else:
            subject = str(data.get("subject") or "").strip()
            subject = subject if subject_ok(subject) else fallback_subject(ctx)
        unsupported = check(body, ctx)
        draft = Draft(subject=subject, body=body, story_ids=story_ids, unsupported_claims=unsupported, attempts=attempt)
        if not unsupported:
            break
        prompt = (base + "\n\nYOUR PREVIOUS DRAFT had problems: " + "; ".join(unsupported)
                  + ". Rewrite it without them, using only the facts given.")
    draft.tokens_in, draft.tokens_out = usage.input_tokens, usage.output_tokens
    return draft


_NOTE_SCHEMA = {"type": "object", "properties": {"note": {"type": "string"}}, "required": ["note"]}


async def generate_connect_note(llm: LLMProvider, ctx: DraftContext) -> Draft:
    """A LinkedIn connection note (<= 300 characters): the shared basis plus one line on why."""
    facts = "\n".join(profile_facts(ctx.profile)[:8])
    prompt = (
        f"Write a LinkedIn connection note from {ctx.profile.full_name or 'the sender'} to {ctx.recipient_name}"
        + (f" ({ctx.recipient_title})" if ctx.recipient_title else "") + f" at {ctx.company.name}. "
        f"At most {CONNECT_NOTE_CHARS} characters. Mention the shared basis honestly"
        + (f" ({ctx.referral_basis})" if ctx.referral_basis else "") + " and one line on why "
        + (f"(interested in the {ctx.job.title} role)" if ctx.job else "") + ". Do not ask for a referral yet. "
        f"Only these facts about the sender:\n{facts}"
    )
    res = await llm.complete(prompt, system=SYSTEM, schema=_NOTE_SCHEMA, max_tokens=200, tier="fast")
    note = re.sub(r"\s+", " ", str((res.data or {}).get("note") or "")).strip()
    if len(note) > CONNECT_NOTE_CHARS:
        note = note[:CONNECT_NOTE_CHARS].rsplit(" ", 1)[0].rstrip(",;:") + "…"
        note = note[:CONNECT_NOTE_CHARS]
    unsupported = check(note, ctx)
    return Draft(subject=None, body=note, unsupported_claims=unsupported, tokens_in=res.usage.input_tokens,
                 tokens_out=res.usage.output_tokens)


__all__ = [
    "CONNECT_NOTE_CHARS", "Draft", "DraftContext", "WORD_LIMITS", "allowed_sources", "candidate_sources", "check",
    "clip_words", "fallback_subject", "first_name", "footer", "full_body", "generate", "generate_connect_note",
    "outreach_violations", "reply_subject", "subject_ok",
]
