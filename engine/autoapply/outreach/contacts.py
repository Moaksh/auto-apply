"""Contacts: CRUD, dedupe/merge, provenance, the email confidence score and role categories
(plan §B.5).

``email_confidence`` (0-100) comes from the strongest email evidence:

=================================================================  =====
Typed by the user, or we received a reply from the address           100
Published on a company-domain page, in the posting, or on GitHub     95
Provider says ``valid``                                               90
Published on a third-party page / Google snippet only                 80
Pattern inferred                                                      domain pattern confidence (<= 85), -10 if the name parse was ambiguous
Sent with no bounce within 72 h                                       +10, capped at 90
Hard bounce                                                           0
=================================================================  =====

Tiers: Verified >= 90, Likely 70-89, Guess 40-69, Unknown < 40.
"""

from __future__ import annotations

import logging
import re
import sqlite3
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any
from urllib.parse import urlsplit

from autoapply import db
from autoapply.enums import ContactOrigin, EmailStatus, EvidenceKind, RoleCategory, ScoutPurpose
from autoapply.models import Contact, ContactEvidence, format_ts, now_ts, utcnow
from autoapply.outreach import patterns
from autoapply.outreach.suppression import email_domain, normalize_email

log = logging.getLogger("autoapply.outreach.contacts")

#: Personal mail providers: a scraped address on one of these is never stored (we only want
#: business addresses); a user-typed one is fine.
FREE_MAIL_DOMAINS = frozenset(
    """
    gmail.com googlemail.com yahoo.com yahoo.co.in yahoo.in ymail.com rediffmail.com hotmail.com outlook.com live.com
    msn.com icloud.com me.com mac.com aol.com protonmail.com proton.me gmx.com gmx.de mail.com zoho.com zohomail.in
    yandex.com yandex.ru qq.com 163.com hey.com fastmail.com tutanota.com
    """.split()
)

SNIPPET_MAX = 280
#: Contacts found by the scout with no thread are deleted after this long (plan §D).
CONTACT_RETENTION_DAYS = 365
THREAD_RETENTION_DAYS = 730

TIER_VERIFIED, TIER_LIKELY, TIER_GUESS = 90, 70, 40


def tier(confidence: int) -> str:
    if confidence >= TIER_VERIFIED:
        return "verified"
    if confidence >= TIER_LIKELY:
        return "likely"
    if confidence >= TIER_GUESS:
        return "guess"
    return "unknown"


def is_free_mail(email: str | None) -> bool:
    d = email_domain(email)
    return bool(d and d in FREE_MAIL_DOMAINS)


def host_of(url: str | None) -> str:
    try:
        return (urlsplit(url or "").hostname or "").lower().removeprefix("www.")
    except ValueError:
        return ""


def on_domain(url: str | None, domain: str | None) -> bool:
    h = host_of(url)
    return bool(domain and h and (h == domain or h.endswith("." + domain)))


def snippet(text: str | None) -> str | None:
    if not text:
        return None
    s = re.sub(r"\s+", " ", text).strip()
    return s if len(s) <= SNIPPET_MAX else s[: SNIPPET_MAX - 1] + "…"


# =====================================================================================
# Role category (deterministic; the model only adds role_fit)
# =====================================================================================

_ROLE_RULES: tuple[tuple[RoleCategory, re.Pattern[str]], ...] = (
    (RoleCategory.FOUNDER, re.compile(r"\b(co-?founder|founder|ceo|chief executive)\b", re.I)),
    (RoleCategory.TALENT_LEAD, re.compile(r"\b(head of (talent|people|recruiting|hr)|talent (lead|director|manager)|"
                                          r"(director|vp|vice president),? (of )?(talent|people|recruiting)|people partner|"
                                          r"hr business partner|chief people)\b", re.I)),
    (RoleCategory.RECRUITER, re.compile(r"\b(recruit\w*|talent acquisition|sourcer|sourcing|talent partner|hiring partner|"
                                        r"campus hiring|ta (partner|specialist|lead))\b", re.I)),
    (RoleCategory.ENG_LEADER, re.compile(r"\b(cto|chief technology|vp,? (of )?engineering|vice president,? engineering|"
                                         r"head of (engineering|technology|platform|product engineering|data|ml|ai)|"
                                         r"director,? (of )?(engineering|software|technology))\b", re.I)),
    (RoleCategory.HIRING_MANAGER, re.compile(r"\b(hiring manager|engineering manager|software (development|engineering) manager|"
                                             r"manager,? (software|engineering)|team lead|tech(nical)? lead|sdm|em)\b", re.I)),
    (RoleCategory.ENGINEER, re.compile(r"\b(engineer|developer|sde|swe|programmer|architect|scientist|devops|sre)\b", re.I)),
)


def classify_role(title: str | None, email: str | None = None) -> RoleCategory:
    if email and patterns.is_role_mailbox(email):
        return RoleCategory.ROLE_MAILBOX
    t = title or ""
    for cat, rx in _ROLE_RULES:
        if rx.search(t):
            return cat
    return RoleCategory.OTHER


#: Ranking order per purpose (plan §A.1 step 2, §A.2 step 3).
PURPOSE_ORDER: dict[ScoutPurpose, tuple[RoleCategory, ...]] = {
    ScoutPurpose.APPLICATION: (RoleCategory.RECRUITER, RoleCategory.TALENT_LEAD, RoleCategory.HIRING_MANAGER,
                               RoleCategory.ENG_LEADER, RoleCategory.ENGINEER, RoleCategory.FOUNDER,
                               RoleCategory.ROLE_MAILBOX, RoleCategory.OTHER),
    ScoutPurpose.PROSPECT: (RoleCategory.ENG_LEADER, RoleCategory.HIRING_MANAGER, RoleCategory.FOUNDER,
                            RoleCategory.RECRUITER, RoleCategory.TALENT_LEAD, RoleCategory.ENGINEER,
                            RoleCategory.ROLE_MAILBOX, RoleCategory.OTHER),
    ScoutPurpose.REFERRAL: (RoleCategory.ENGINEER, RoleCategory.HIRING_MANAGER, RoleCategory.ENG_LEADER,
                            RoleCategory.RECRUITER, RoleCategory.TALENT_LEAD, RoleCategory.FOUNDER,
                            RoleCategory.ROLE_MAILBOX, RoleCategory.OTHER),
}


def rank_key(c: Contact, purpose: ScoutPurpose, *, from_posting: bool = False) -> tuple:
    """Sort key (ascending = best first): a recruiter named in the posting beats everyone for
    applications; then role order for the purpose, role fit, email confidence."""
    order = PURPOSE_ORDER[ScoutPurpose(purpose)]
    cat = order.index(c.role_category) if c.role_category in order else len(order)
    posting = 0 if (from_posting and purpose is ScoutPurpose.APPLICATION) else 1
    return (posting, cat, -(c.role_fit if c.role_fit is not None else 50), -c.email_confidence, c.id)


# =====================================================================================
# Confidence (pure)
# =====================================================================================


@dataclass(frozen=True, slots=True)
class EvidenceFact:
    """What :func:`score_email` needs from one ``field = 'email'`` evidence row."""

    kind: EvidenceKind
    url: str | None = None
    snippet: str | None = None


def score_email(
    evidence: Sequence[EvidenceFact],
    *,
    status: EmailStatus,
    company_domain: str | None,
    pattern_confidence: int | None = None,
    ambiguous: bool = False,
) -> tuple[int, EmailStatus]:
    """(confidence, basis status) from the evidence table. ``status`` carries the outcome
    states that override evidence: ``user``, ``replied``, ``bounced``, ``delivered``."""
    if status is EmailStatus.BOUNCED:
        return 0, EmailStatus.BOUNCED
    if status in (EmailStatus.USER, EmailStatus.REPLIED):
        return 100, status
    best, basis = 0, EmailStatus.NONE
    for e in evidence:
        if e.kind in (EvidenceKind.USER, EvidenceKind.REPLY):
            score, st = 100, EmailStatus.USER if e.kind is EvidenceKind.USER else EmailStatus.REPLIED
        elif e.kind in (EvidenceKind.JOB_POSTING, EvidenceKind.GITHUB):
            score, st = 95, EmailStatus.PUBLISHED
        elif e.kind is EvidenceKind.COMPANY_PAGE:
            score, st = (95 if on_domain(e.url, company_domain) or not e.url else 80), EmailStatus.PUBLISHED
        elif e.kind is EvidenceKind.PROVIDER:
            text = (e.snippet or "").lower()
            if re.search(r"\bvalid\b", text) and "invalid" not in text:
                score, st = 90, EmailStatus.PROVIDER_VERIFIED
            else:
                score, st = 70, EmailStatus.PATTERN
        elif e.kind in (EvidenceKind.GOOGLE_SERP, EvidenceKind.SHARED_LIBRARY):
            score, st = 80, EmailStatus.PUBLISHED
        elif e.kind is EvidenceKind.PATTERN:
            score = max(0, min(patterns.MAX_PATTERN_CONFIDENCE, pattern_confidence or 0) - (10 if ambiguous else 0))
            st = EmailStatus.PATTERN
        else:
            continue
        if score > best:
            best, basis = score, st
    if status is EmailStatus.DELIVERED and best < 90:
        best = min(90, best + 10)
    return best, basis


# =====================================================================================
# Rows
# =====================================================================================


@dataclass(slots=True)
class NewEvidence:
    kind: EvidenceKind
    field: str  # name | title | email
    url: str | None = None
    snippet: str | None = None
    provider: str | None = None


@dataclass(slots=True)
class UpsertResult:
    contact: Contact
    merged: bool
    created: bool = False
    rejected: str | None = None  # why the email was not stored (free mail, suppressed elsewhere)
    evidence_added: list[int] = field(default_factory=list)


def get_contact(conn: sqlite3.Connection, contact_id: int) -> Contact:
    row = conn.execute("SELECT * FROM contacts WHERE id = ?", (contact_id,)).fetchone()
    if row is None:
        raise db.NotFound(f"contact {contact_id} not found")
    return Contact.from_row(row)  # type: ignore[return-value]


def find_by_email(conn: sqlite3.Connection, email: str | None) -> Contact | None:
    norm = normalize_email(email)
    if norm is None:
        return None
    row = conn.execute("SELECT * FROM contacts WHERE email_norm = ?", (norm,)).fetchone()
    return Contact.from_row(row) if row else None  # type: ignore[return-value]


def list_contacts(conn: sqlite3.Connection, company_id: int | None = None) -> list[Contact]:
    sql, params = "SELECT * FROM contacts", []
    if company_id is not None:
        sql += " WHERE company_id = ?"
        params.append(company_id)
    return [Contact.from_row(r) for r in conn.execute(sql + " ORDER BY id", params)]  # type: ignore[misc]


def list_evidence(conn: sqlite3.Connection, contact_id: int) -> list[ContactEvidence]:
    return [ContactEvidence.from_row(r) for r in conn.execute(  # type: ignore[misc]
        "SELECT * FROM contact_evidence WHERE contact_id = ? ORDER BY observed_at DESC, id DESC", (contact_id,))]


def _find_by_name(conn: sqlite3.Connection, company_id: int | None, full_name: str) -> sqlite3.Row | None:
    if company_id is None:
        return None
    norm = db.normalize_text(full_name)
    for r in conn.execute("SELECT * FROM contacts WHERE company_id = ?", (company_id,)):
        if db.normalize_text(r["full_name"]) == norm:
            return r
    return None


def _split_name(full_name: str) -> tuple[str | None, str | None]:
    parts = full_name.split()
    if not parts:
        return None, None
    return parts[0], (parts[-1] if len(parts) > 1 else None)


_STATUS_STRENGTH = {
    EmailStatus.NONE: 0, EmailStatus.PATTERN: 1, EmailStatus.PROVIDER_VERIFIED: 2, EmailStatus.PUBLISHED: 3,
    EmailStatus.DELIVERED: 3, EmailStatus.USER: 5, EmailStatus.REPLIED: 5, EmailStatus.BOUNCED: -1,
}


def upsert_contact(
    conn: sqlite3.Connection,
    *,
    company_id: int | None,
    full_name: str,
    origin: ContactOrigin | str,
    email: str | None = None,
    email_status: EmailStatus | str = EmailStatus.NONE,
    title: str | None = None,
    linkedin_url: str | None = None,
    github_login: str | None = None,
    location: str | None = None,
    relationship: str | None = None,
    notes: str | None = None,
    share_ok: bool | None = None,
    evidence: Iterable[NewEvidence] = (),
    pattern_confidence: int | None = None,
    ambiguous: bool = False,
) -> UpsertResult:
    """Insert or merge a contact (dedupe by normalized email, else by name within the company).

    Scouted contacts never keep a free-mail address. A stronger email (published beats pattern)
    replaces a weaker one; a typed email always wins. Evidence rows are appended and the
    confidence recomputed."""
    origin = ContactOrigin(origin)
    status = EmailStatus(email_status)
    full_name = re.sub(r"\s+", " ", full_name or "").strip()
    if not full_name:
        raise ValueError("contact name is empty")
    norm = normalize_email(email)
    rejected: str | None = None
    if email and norm is None:
        rejected, email = "invalid address", None
    if norm and origin in (ContactOrigin.SCOUT, ContactOrigin.SHARED) and is_free_mail(norm):
        rejected, norm, email = "personal (free-mail) address", None, None
    if norm is None:
        status = EmailStatus.NONE
    ts = now_ts()
    with db.transaction(conn):
        row = conn.execute("SELECT * FROM contacts WHERE email_norm = ?", (norm,)).fetchone() if norm else None
        if row is None:
            row = _find_by_name(conn, company_id, full_name)
        created = row is None
        if row is None:
            first, last = _split_name(full_name)
            cur = conn.execute(
                "INSERT INTO contacts(company_id, full_name, first_name, last_name, title, role_category, email, email_norm, "
                "email_status, linkedin_url, github_login, location, origin, relationship, share_ok, notes, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (company_id, full_name, first, last, title, classify_role(title, norm).value, norm and email.strip(), norm,
                 status.value if norm else EmailStatus.NONE.value, linkedin_url, github_login, location, origin.value,
                 relationship, int(bool(share_ok)), notes, ts, ts),
            )
            cid = int(cur.lastrowid)
        else:
            cid = int(row["id"])
            upd: dict[str, Any] = {}
            if company_id is not None and row["company_id"] is None:
                upd["company_id"] = company_id
            if title and title != row["title"]:
                upd["title"] = title  # newest observation wins
                upd["role_category"] = classify_role(title, row["email_norm"]).value
            for col, val in (("linkedin_url", linkedin_url), ("github_login", github_login), ("location", location),
                             ("relationship", relationship), ("notes", notes)):
                if val and not row[col]:
                    upd[col] = val
            if share_ok is not None and origin is not ContactOrigin.SCOUT:
                upd["share_ok"] = int(share_ok)
            if norm and norm != row["email_norm"]:
                current = EmailStatus(row["email_status"])
                stronger = (origin in (ContactOrigin.USER, ContactOrigin.IMPORT) or not row["email_norm"]
                            or _STATUS_STRENGTH[status] > _STATUS_STRENGTH[current])
                taken = conn.execute("SELECT id FROM contacts WHERE email_norm = ? AND id <> ?", (norm, cid)).fetchone()
                if stronger and taken is None:
                    upd.update(email=email.strip(), email_norm=norm, email_status=status.value)  # type: ignore[union-attr]
            elif norm and _STATUS_STRENGTH[status] > _STATUS_STRENGTH[EmailStatus(row["email_status"])]:
                upd["email_status"] = status.value
            if upd:
                upd["updated_at"] = ts
                sql, params = db._update_sql("contacts", upd, "id = ?")
                conn.execute(sql, [*params, cid])
        added = [add_evidence(conn, cid, e) for e in evidence]
        recompute_confidence(conn, cid, pattern_confidence=pattern_confidence, ambiguous=ambiguous)
    return UpsertResult(get_contact(conn, cid), merged=not created, created=created, rejected=rejected, evidence_added=added)


def add_evidence(conn: sqlite3.Connection, contact_id: int, e: NewEvidence) -> int:
    """Append one observation (an identical kind/field/url row is refreshed, not duplicated)."""
    ts = now_ts()
    with db.transaction(conn):
        row = conn.execute(
            "SELECT id FROM contact_evidence WHERE contact_id = ? AND kind = ? AND field = ? AND COALESCE(url, '') = COALESCE(?, '')",
            (contact_id, EvidenceKind(e.kind).value, e.field, e.url),
        ).fetchone()
        if row is not None:
            conn.execute("UPDATE contact_evidence SET observed_at = ?, snippet = COALESCE(?, snippet) WHERE id = ?",
                         (ts, snippet(e.snippet), row["id"]))
            return int(row["id"])
        cur = conn.execute(
            "INSERT INTO contact_evidence(contact_id, kind, field, url, snippet, provider, observed_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (contact_id, EvidenceKind(e.kind).value, e.field, e.url, snippet(e.snippet), e.provider, ts),
        )
        return int(cur.lastrowid)


def _pattern_conf(conn: sqlite3.Connection, domain: str | None) -> int | None:
    if not domain:
        return None
    row = conn.execute("SELECT confidence FROM domain_patterns WHERE domain = ?", (domain,)).fetchone()
    return int(row["confidence"]) if row else None


def recompute_confidence(conn: sqlite3.Connection, contact_id: int, *, pattern_confidence: int | None = None,
                         ambiguous: bool | None = None) -> int:
    """Re-score the contact's email from its evidence; returns the new confidence."""
    with db.transaction(conn):
        c = get_contact(conn, contact_id)
        if not c.email_norm:
            conn.execute("UPDATE contacts SET email_confidence = 0, email_status = 'none' WHERE id = ?", (contact_id,))
            return 0
        rows = conn.execute("SELECT kind, url, snippet FROM contact_evidence WHERE contact_id = ? AND field = 'email'",
                            (contact_id,)).fetchall()
        ev = [EvidenceFact(EvidenceKind(r["kind"]), r["url"], r["snippet"]) for r in rows]
        company_domain = None
        if c.company_id is not None:
            r = conn.execute("SELECT domain FROM companies WHERE id = ?", (c.company_id,)).fetchone()
            company_domain = r["domain"] if r else None
        email_dom = c.email_norm.split("@", 1)[1]
        if ambiguous is None:
            ambiguous = any("ambiguous" in (r["snippet"] or "") for r in rows if r["kind"] == EvidenceKind.PATTERN.value)
        pconf = pattern_confidence if pattern_confidence is not None else _pattern_conf(conn, email_dom)
        score, basis = score_email(ev, status=c.email_status, company_domain=company_domain or email_dom,
                                   pattern_confidence=pconf, ambiguous=bool(ambiguous))
        status = c.email_status
        if status in (EmailStatus.NONE, EmailStatus.PATTERN, EmailStatus.PUBLISHED, EmailStatus.PROVIDER_VERIFIED):
            status = basis if basis is not EmailStatus.NONE else status
        conn.execute("UPDATE contacts SET email_confidence = ?, email_status = ?, updated_at = ? WHERE id = ?",
                     (score, status.value, now_ts(), contact_id))
    return score


def set_email_status(conn: sqlite3.Connection, contact_id: int, status: EmailStatus, *, evidence: NewEvidence | None = None) -> int:
    with db.transaction(conn):
        conn.execute("UPDATE contacts SET email_status = ?, updated_at = ? WHERE id = ?", (status.value, now_ts(), contact_id))
        if evidence is not None:
            add_evidence(conn, contact_id, evidence)
        return recompute_confidence(conn, contact_id)


_UPDATABLE = {"company_id", "full_name", "email", "title", "linkedin_url", "relationship", "notes", "share_ok"}


def update_contact(conn: sqlite3.Connection, contact_id: int, patch: dict[str, Any]) -> Contact:
    """User edit (only keys present). A typed email becomes status ``user`` (confidence 100)."""
    bad = set(patch) - _UPDATABLE
    if bad:
        raise ValueError(f"cannot update contact fields: {sorted(bad)}")
    with db.transaction(conn):
        c = get_contact(conn, contact_id)
        upd: dict[str, Any] = {}
        for k, v in patch.items():
            if k == "full_name":
                if not (v or "").strip():
                    raise ValueError("contact name is empty")
                upd["full_name"] = v.strip()
                upd["first_name"], upd["last_name"] = _split_name(v.strip())
            elif k == "email":
                norm = normalize_email(v) if v else None
                if v and norm is None:
                    raise ValueError(f"not an email address: {v!r}")
                if norm and conn.execute("SELECT 1 FROM contacts WHERE email_norm = ? AND id <> ?", (norm, contact_id)).fetchone():
                    raise db.Conflict(f"another contact already has {norm}")
                upd.update(email=v.strip() if v else None, email_norm=norm,
                           email_status=(EmailStatus.USER if norm else EmailStatus.NONE).value)
            elif k == "title":
                upd["title"] = v
                upd["role_category"] = classify_role(v, upd.get("email_norm", c.email_norm)).value
            elif k == "share_ok":
                upd["share_ok"] = int(bool(v))
            elif k == "company_id" and v is not None:
                db.get_company(conn, int(v))
                upd["company_id"] = int(v)
            else:
                upd[k] = v
        if upd:
            upd["updated_at"] = now_ts()
            sql, params = db._update_sql("contacts", upd, "id = ?")
            conn.execute(sql, [*params, contact_id])
        if "email" in patch and upd.get("email_norm"):
            add_evidence(conn, contact_id, NewEvidence(EvidenceKind.USER, "email", snippet="typed by you"))
        recompute_confidence(conn, contact_id)
    return get_contact(conn, contact_id)


def delete_contact(conn: sqlite3.Connection, contact_id: int, *, suppress: bool = True, log: bool = True) -> Contact:
    """Delete a contact (threads keep their history with ``contact_id`` NULL). With
    ``suppress`` the address goes on the do-not-contact list first."""
    from autoapply.enums import SuppressionReason
    from autoapply.outreach import suppression

    with db.transaction(conn):
        c = get_contact(conn, contact_id)
        if suppress and c.email_norm:
            suppression.add(conn, email=c.email_norm, reason=SuppressionReason.USER, source="deleted contact")
        conn.execute("DELETE FROM contacts WHERE id = ?", (contact_id,))
        if log:
            db.log_event(conn, "outreach", f"deleted contact {c.full_name}", actor="user", payload={"contact_id": contact_id})
    return c


def purge_expired(conn: sqlite3.Connection, now: datetime | None = None) -> tuple[int, int]:
    """Retention (plan §D): scouted contacts with no thread for 12 months, and closed threads
    after 24 months. Returns (contacts, threads) deleted. Contacts the user typed or imported stay."""
    now = now or utcnow()
    c_cut = format_ts(now - timedelta(days=CONTACT_RETENTION_DAYS))
    t_cut = format_ts(now - timedelta(days=THREAD_RETENTION_DAYS))
    with db.transaction(conn):
        threads = conn.execute(
            "DELETE FROM outreach_threads WHERE updated_at < ? AND state NOT IN ('draft','active')", (t_cut,)
        ).rowcount
        contacts = conn.execute(
            "DELETE FROM contacts WHERE origin IN ('scout','shared') AND updated_at < ? "
            "AND id NOT IN (SELECT contact_id FROM outreach_threads WHERE contact_id IS NOT NULL) "
            "AND id NOT IN (SELECT contact_id FROM referrals WHERE contact_id IS NOT NULL)",
            (c_cut,),
        ).rowcount
    return contacts, threads


def best_email_source_label(conn: sqlite3.Connection, contact: Contact) -> str:
    """Where we found the address, for the footer ("acme.com/team", "the Acme job posting", "GitHub")."""
    if contact.origin in (ContactOrigin.USER, ContactOrigin.IMPORT):
        return "a mutual contact"
    rows = conn.execute("SELECT kind, url FROM contact_evidence WHERE contact_id = ? AND field = 'email' ORDER BY observed_at DESC",
                        (contact.id,)).fetchall()
    order = [EvidenceKind.JOB_POSTING, EvidenceKind.COMPANY_PAGE, EvidenceKind.GITHUB, EvidenceKind.PROVIDER,
             EvidenceKind.GOOGLE_SERP, EvidenceKind.PATTERN]
    company = None
    if contact.company_id is not None:
        r = conn.execute("SELECT name, domain FROM companies WHERE id = ?", (contact.company_id,)).fetchone()
        company = r
    for kind in order:
        for r in rows:
            if r["kind"] != kind.value:
                continue
            if kind is EvidenceKind.JOB_POSTING:
                return f"the {company['name']} job posting" if company else "the job posting"
            if kind is EvidenceKind.COMPANY_PAGE and r["url"]:
                parts = urlsplit(r["url"])
                path = parts.path.rstrip("/")
                return host_of(r["url"]) + (path if path and len(path) < 30 else "")
            if kind is EvidenceKind.GITHUB:
                return "GitHub"
            if kind is EvidenceKind.GOOGLE_SERP:
                return "a public web page"
            if kind is EvidenceKind.PROVIDER:
                return "a public business directory"
            if kind is EvidenceKind.PATTERN:
                return f"the {company['name']} website" if company else "your company's website"
    return f"the {company['name']} website" if company else "a public web page"


__all__ = [
    "EvidenceFact", "FREE_MAIL_DOMAINS", "NewEvidence", "UpsertResult", "add_evidence", "best_email_source_label",
    "classify_role", "delete_contact", "find_by_email", "get_contact", "is_free_mail", "list_contacts", "list_evidence",
    "normalize_email", "purge_expired", "rank_key", "recompute_confidence", "score_email", "set_email_status", "tier",
    "update_contact", "upsert_contact",
]
