"""Source #2: contact lines in the job posting (``jobs.description``, already stored).

Low coverage (5-10% of postings) but very reliable: "Reach out to Jane Doe (jane@acme.com)",
"Recruiter: Ravi Kumar", "Hiring manager: Priya Shah". Phrase matches are taken directly;
the model may add people only if their names are on the page (``extract.verify_people``).
"""

from __future__ import annotations

import re

from autoapply.enums import EvidenceKind
from autoapply.llm.provider import LLMProvider, TokenUsage
from autoapply.outreach.sources.extract import Person, emails_in, extract_people, link_emails, snippet_around, verify_people

_NAME = r"([A-Z][a-zA-Z'’\-]+(?:\s+[A-Z]\.?)?(?:\s+[A-Z][a-zA-Z'’\-]+){1,2})"
_PHRASES: tuple[tuple[re.Pattern[str], str | None], ...] = (
    (re.compile(rf"\b(?i:recruiter|talent partner|recruiting contact)\s*[:\-–]\s*{_NAME}"), "Recruiter"),
    (re.compile(rf"\b(?i:hiring manager)\s*[:\-–]\s*{_NAME}"), "Hiring Manager"),
    (re.compile(rf"\b(?i:reach out to|contact|email|write to|get in touch with)\s+(?i:our recruiter\s+)?{_NAME}"), None),
    (re.compile(rf"{_NAME}\s*,\s*(?i:our\s+)?((?i:technical recruiter|recruiter|talent acquisition[\w ]*|hiring manager))"), "_group2"),
)
#: Only worth a model call when the posting talks about a person to contact.
_HINT = re.compile(r"reach out|recruiter|hiring manager|contact|questions\?|get in touch|@", re.I)


def phrase_people(text: str) -> list[Person]:
    found: list[Person] = []
    for rx, title in _PHRASES:
        for m in rx.finditer(text or ""):
            name = m.group(1).strip()
            t = m.group(2).strip().title() if title == "_group2" else title
            if any(p.name == name for p in found):
                continue
            found.append(Person(name=name, title=t, kind=EvidenceKind.JOB_POSTING, snippet=snippet_around(text, name)))
    # Phrase captures are page text by construction; verify anyway (titles are labels we add).
    ok = {n for n, _ in verify_people([{"name": p.name} for p in found], text)}
    return [p for p in found if p.name in ok]


async def from_posting(
    description: str | None, *, company: str, domain: str | None, url: str | None,
    llm: LLMProvider | None = None, usage: TokenUsage | None = None,
) -> tuple[list[Person], list[str]]:
    """(people, leftover emails on the company domain) from a posting's text."""
    text = description or ""
    if not text.strip():
        return [], []
    people = phrase_people(text)
    if llm is not None and _HINT.search(text):
        for name, title in await extract_people(llm, text, company=company, usage=usage):
            if not any(p.name == name for p in people):
                people.append(Person(name=name, title=title, kind=EvidenceKind.JOB_POSTING, snippet=snippet_around(text, name)))
    for p in people:
        p.url = url
    emails = emails_in(text, domain=domain) if domain else [e for e in emails_in(text)]
    left = link_emails(people, emails)
    return people, left


__all__ = ["from_posting", "phrase_people"]
