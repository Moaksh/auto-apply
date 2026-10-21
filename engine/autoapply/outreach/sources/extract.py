"""Helpers shared by the contact sources: page text, email regex, and model-assisted people
extraction with the anti-hallucination check.

The model is a structured extractor only (``extract_people``): it returns names and titles,
never email addresses. A name (or title) that does not appear in the page text after
normalisation (accents stripped, lowercase, punctuation collapsed) is dropped. Emails come only
from :data:`EMAIL_RX` over the raw page and are linked to a person when the address matches
one of the name's patterns.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

from autoapply.answers.textnorm import strip_accents
from autoapply.enums import EvidenceKind
from autoapply.llm.provider import LLMProvider, TokenUsage
from autoapply.outreach import patterns

log = logging.getLogger("autoapply.outreach.sources")

EMAIL_RX = re.compile(r"(?<![\w.+-])([A-Za-z0-9][A-Za-z0-9._%+-]{0,63}@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24})(?![\w-])")
#: Addresses that are never a person or a mailbox worth writing to.
_JUNK_EMAIL = re.compile(r"(noreply|no-reply|donotreply|do-not-reply|example\.(com|org)|sentry|wixpress|@users\.noreply|"
                         r"\.(png|jpe?g|gif|svg|webp)$|^[0-9a-f]{16,}@)", re.I)
PAGE_TEXT_LIMIT = 8000

EXTRACT_SCHEMA = {
    "type": "object",
    "properties": {
        "people": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"name": {"type": "string"}, "title": {"type": ["string", "null"]}},
                "required": ["name"],
            },
        },
    },
    "required": ["people"],
}
EXTRACT_SYSTEM = (
    "You extract people who work at a company from a web page's text. Copy each person's full name and job title "
    "EXACTLY as written on the page. Never guess, complete or translate a name, never add people who are not on the "
    "page, never output email addresses. Return an empty list when the page names nobody."
)


@dataclass(slots=True)
class Person:
    """A person seen on a page (name/title verified against the page text)."""

    name: str
    title: str | None = None
    email: str | None = None
    url: str | None = None
    snippet: str | None = None
    kind: EvidenceKind = EvidenceKind.COMPANY_PAGE
    linkedin_url: str | None = None
    github_login: str | None = None
    location: str | None = None
    extra: dict = field(default_factory=dict)


def norm_text(text: str | None) -> str:
    s = strip_accents(text or "").lower()
    s = re.sub(r"[^a-z0-9+&]+", " ", s)
    return " " + re.sub(r"\s+", " ", s).strip() + " "


def appears_in(phrase: str | None, text_norm: str) -> bool:
    """``phrase`` occurs in the (already :func:`norm_text`'d) page text as whole words."""
    p = norm_text(phrase).strip()
    return bool(p) and f" {p} " in text_norm


def page_text(html: str) -> str:
    """Visible text of an HTML page (scripts / styles / nav chrome dropped)."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    for t in soup(["script", "style", "noscript", "svg", "template"]):
        t.decompose()
    text = soup.get_text("\n")
    return re.sub(r"\n\s*\n+", "\n", re.sub(r"[ \t\r\f\v]+", " ", text)).strip()


def emails_in(raw: str, *, domain: str | None = None) -> list[str]:
    """Email addresses in raw page source (``mailto:`` included), lowercased, junk dropped;
    with ``domain``, only addresses on it (or a subdomain)."""
    out: list[str] = []
    for m in EMAIL_RX.finditer(raw or ""):
        e = m.group(1).lower().rstrip(".")
        if _JUNK_EMAIL.search(e):
            continue
        if domain:
            d = e.rsplit("@", 1)[1]
            if not (d == domain or d.endswith("." + domain)):
                continue
        if e not in out:
            out.append(e)
    return out


def snippet_around(text: str, needle: str, width: int = 120) -> str:
    i = text.lower().find(needle.lower())
    if i < 0:
        return text[:width * 2]
    return text[max(0, i - width): i + len(needle) + width].strip()


def link_emails(people: list[Person], emails: list[str]) -> list[str]:
    """Give each person the address whose local part matches one of their name patterns.
    Returns the addresses left over (role mailboxes, or people not named on the page)."""
    left = list(emails)
    for p in people:
        if p.email:
            continue
        for e in list(left):
            if patterns.patterns_matching(p.name, e):
                p.email = e
                left.remove(e)
                break
    return left


_NAME_OK = re.compile(r"^[^\d@/:<>{}\[\]|]{3,80}$")


def plausible_name(name: str) -> bool:
    words = name.split()
    return bool(_NAME_OK.match(name)) and 2 <= len(words) <= 5 and all(w[:1].isupper() or len(w) <= 3 for w in words)


def verify_people(raw: list[dict], text: str) -> list[tuple[str, str | None]]:
    """Keep (name, title) pairs whose name appears word for word in ``text``; a title that is
    not on the page is cleared (the person stays)."""
    tn = norm_text(text)
    out: list[tuple[str, str | None]] = []
    for p in raw:
        name = re.sub(r"\s+", " ", str(p.get("name") or "")).strip()
        if not name or not plausible_name(name) or not appears_in(name, tn):
            if name:
                log.info("dropped extracted name not on the page: %r", name)
            continue
        title = re.sub(r"\s+", " ", str(p.get("title") or "")).strip() or None
        if title and not appears_in(title, tn):
            title = None
        if all(n != name for n, _ in out):
            out.append((name, title))
    return out


async def extract_people(llm: LLMProvider, text: str, *, company: str, usage: TokenUsage | None = None) -> list[tuple[str, str | None]]:
    """Model-assisted extraction of (name, title) from page text, verified against it."""
    if not text.strip():
        return []
    prompt = (f"COMPANY: {company}\n\nList the people the page says work at {company}, with their titles.\n\n"
              f"PAGE TEXT:\n{text[:PAGE_TEXT_LIMIT]}")
    try:
        res = await llm.complete(prompt, system=EXTRACT_SYSTEM, schema=EXTRACT_SCHEMA, tier="fast", max_tokens=1200)
    except Exception as e:  # noqa: BLE001 - extraction is best effort
        log.info("extract_people failed: %s", e)
        return []
    if usage is not None:
        usage.add(res.usage)
    return verify_people(list((res.data or {}).get("people") or []), text)


__all__ = [
    "EMAIL_RX", "Person", "appears_in", "emails_in", "extract_people", "link_emails", "norm_text", "page_text",
    "plausible_name", "snippet_around", "verify_people",
]
