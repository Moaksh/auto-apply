"""Warm intros from the user's own LinkedIn data export (``Connections.csv``).

The user downloads the file from LinkedIn themselves (Settings → Data privacy → Get a copy of
your data → Connections) and picks it in the app. AutoApply never opens linkedin.com: the
profile URLs in the file are stored as references for the user's own browser only.

* :func:`parse_connections` reads the CSV robustly: a byte-order mark, the free-text "Notes:"
  preamble LinkedIn puts before the header (found by content, not by a fixed offset), quoted
  cells with commas or newlines, header spelling variations, and the usually-empty Email
  Address column.
* :func:`company_key` / :class:`CompanyIndex` match the free-text Company column to the
  companies AutoApply cares about (watched companies, companies of active applications,
  prospects). Two tiers, both conservative:

  - *exact*: the names are equal once case, accents, punctuation, spacing and legal suffixes
    ("Pvt Ltd", "Private Limited", "Inc", "LLC", ...) are removed, after mapping well-known
    aliases ("TCS" = "Tata Consultancy Services", "Facebook" = "Meta");
  - *strong*: the sets of distinctive words are equal once generic filler ("Technologies",
    "Software", "Solutions", "India", ...) is also removed ("Razorpay Software Private
    Limited" = "Razorpay"). One extra distinctive word on either side means a different
    company ("Epic Games" is not "Epic Systems"); there is no substring matching ("Loop" is
    not "Loopio").

* :func:`import_connections` stores every row as the user's own contact (``origin = import``,
  ``share_ok = false``, so it never leaves the Mac), merges a newer export into the rows from
  an older one (by profile URL, then email, then name at the same company), skips anyone on the
  do-not-contact list, and creates one ``suggested`` referral per connection at a matched
  company (basis "We're connected on LinkedIn.") for the referral copilot. The user still does
  every LinkedIn step and sends everything themselves.

The tiered matching rule and the generic-word idea are adapted from career-ops'
``linkedin-join.mjs`` (MIT; see THIRD_PARTY_NOTICES.md).
"""

from __future__ import annotations

import csv
import io
import logging
import re
import sqlite3
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from autoapply import db
from autoapply.enums import Actor, ContactOrigin, EmailStatus, EvidenceKind, ReferralBasis, ReferralState
from autoapply.models import now_ts
from autoapply.outreach import contacts, referrals, suppression
from autoapply.outreach.contacts import NewEvidence

log = logging.getLogger("autoapply.outreach.linkedin_export")

#: What the referral copilot shows (and what a draft may state) for an imported connection.
BASIS_DETAIL = "We're connected on LinkedIn."
#: Stored on contacts we create; refreshed by a newer export (a note the user wrote is kept).
NOTE_PREFIX = "LinkedIn connection"
#: ``contacts.relationship`` has no "linkedin_connection" value; "other" plus the note says it.
RELATIONSHIP = "other"
MAX_FILE_BYTES = 20 * 1024 * 1024

# =====================================================================================
# CSV parsing
# =====================================================================================

#: Normalised header text -> field. Headers are compared lowercase with everything but letters
#: and digits removed ("Email Address" -> "emailaddress").
_HEADER_ALIASES: dict[str, str] = {
    "firstname": "first", "first": "first", "givenname": "first",
    "lastname": "last", "last": "last", "surname": "last", "familyname": "last",
    "name": "name", "fullname": "name",
    "url": "url", "profileurl": "url", "linkedinurl": "url", "linkedinprofile": "url", "profile": "url",
    "linkedin": "url",
    "emailaddress": "email", "email": "email", "emailaddresses": "email",
    "company": "company", "companyname": "company", "organization": "company", "organisation": "company",
    "employer": "company", "currentcompany": "company",
    "position": "position", "title": "position", "jobtitle": "position", "headline": "position",
    "connectedon": "connected", "connected": "connected", "connectiondate": "connected", "dateconnected": "connected",
}


@dataclass(slots=True, frozen=True)
class Connection:
    full_name: str
    first_name: str | None
    last_name: str | None
    linkedin_url: str | None
    email: str | None
    company: str | None
    position: str | None
    connected_on: str | None  # ISO date when it parsed, else None


@dataclass(slots=True)
class ParseResult:
    connections: list[Connection] = field(default_factory=list)
    header_found: bool = False
    skipped_no_name: int = 0


def _header_key(cell: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (cell or "").replace("﻿", "").lower())


def _header_map(row: list[str]) -> dict[str, int] | None:
    """Field -> column index if ``row`` is the header (it names a person and a company)."""
    idx: dict[str, int] = {}
    for i, cell in enumerate(row):
        f = _HEADER_ALIASES.get(_header_key(cell))
        if f and f not in idx:
            idx[f] = i
    if ("first" in idx or "name" in idx) and "company" in idx:
        return idx
    return None


def normalize_linkedin_url(url: str | None) -> str | None:
    """``https://www.linkedin.com/in/<slug>`` for a profile URL (no query, no trailing slash);
    other non-empty URLs are returned trimmed. Never fetched."""
    s = (url or "").strip()
    if not s:
        return None
    if not re.match(r"^[a-z]+://", s, re.I):
        s = "https://" + s
    try:
        parts = urlsplit(s)
    except ValueError:
        return None
    host = (parts.hostname or "").lower()
    if not host:
        return None
    path = re.sub(r"/+$", "", parts.path)
    if host == "linkedin.com" or host.endswith(".linkedin.com"):
        m = re.match(r"^/(in|pub)/([^/]+)", path, re.I)
        if m:
            return f"https://www.linkedin.com/{m.group(1).lower()}/{m.group(2).lower()}"
        return f"https://www.linkedin.com{path}"
    return f"{parts.scheme.lower()}://{host}{path}"


_MONTHS = {m: i for i, m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split(), start=1)}


def parse_connected_on(value: str | None) -> str | None:
    """LinkedIn's "03 Aug 2024" (or an ISO date) -> "2024-08-03"; anything else -> None."""
    s = (value or "").strip()
    if not s:
        return None
    try:
        if m := re.match(r"^(\d{4})-(\d{1,2})-(\d{1,2})$", s):
            return date(int(m[1]), int(m[2]), int(m[3])).isoformat()
        if m := re.match(r"^(\d{1,2})[\s-]+([A-Za-z]{3,})[\s-]+(\d{4})$", s):
            month = _MONTHS.get(m[2][:3].lower())
            return date(int(m[3]), month, int(m[1])).isoformat() if month else None
        if m := re.match(r"^([A-Za-z]{3,})\s+(\d{1,2}),?\s+(\d{4})$", s):
            month = _MONTHS.get(m[1][:3].lower())
            return date(int(m[3]), month, int(m[2])).isoformat() if month else None
    except ValueError:  # "31 Feb 2024"
        return None
    return None


def _clean(v: Any) -> str:
    return re.sub(r"\s+", " ", str(v or "").replace("﻿", "")).strip()


def parse_connections(text: str) -> ParseResult:
    """Parse the text of a ``Connections.csv`` export (see the module docstring)."""
    text = text.lstrip("﻿")
    out = ParseResult()
    rows = csv.reader(io.StringIO(text, newline=""))
    idx: dict[str, int] | None = None
    for row in rows:
        if idx is None:
            idx = _header_map(row)
            out.header_found = idx is not None
            continue
        if not row or all(not c.strip() for c in row):
            continue

        def get(f: str, row: list[str] = row) -> str:
            i = idx.get(f) if idx else None
            return _clean(row[i]) if i is not None and i < len(row) else ""

        first, last = get("first"), get("last")
        full = " ".join(p for p in (first, last) if p) or get("name")
        if not full:
            out.skipped_no_name += 1
            continue
        if not first and not last:
            parts = full.split()
            first, last = parts[0], (parts[-1] if len(parts) > 1 else "")
        email = suppression.normalize_email(get("email"))
        out.connections.append(Connection(
            full_name=full, first_name=first or None, last_name=last or None,
            linkedin_url=normalize_linkedin_url(get("url")), email=email,
            company=get("company") or None, position=get("position") or None,
            connected_on=parse_connected_on(get("connected")),
        ))
    return out


def read_connections(path: Path) -> ParseResult:
    """Read and parse an export from disk (UTF-8 with or without BOM, UTF-16, or Latin-1)."""
    data = path.read_bytes()
    if len(data) > MAX_FILE_BYTES:
        raise ValueError(f"{path.name} is larger than {MAX_FILE_BYTES // (1024 * 1024)} MB; is it a Connections.csv export?")
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        text = data.decode("utf-16")
    else:
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = data.decode("latin-1")
    return parse_connections(text)


# =====================================================================================
# Company matching
# =====================================================================================

#: Legal-form words: dropped everywhere before comparing.
_LEGAL = frozenset(
    """
    pvt private ltd limited llp llc inc incorporated corp corporation co company plc gmbh mbh ag kg sa sas sarl bv nv
    ab oy aps pte pty srl spa kk the opc
    """.split()
)
#: Generic filler: dropped for the "strong" tier only (the distinctive words must then be equal).
_GENERIC = frozenset(
    """
    technologies technology tech software softwares solutions solution services service systems system labs lab
    digital consulting consultancy consultants ventures enterprises enterprise group holdings holding global
    international worldwide india indian infotech infosystems it cloud ai network networks platforms platform
    studio studios innovations innovation and of
    """.split()
)

#: Well-known aliases (each group is one employer). Compared on the exact key.
_ALIAS_GROUPS: tuple[tuple[str, ...], ...] = (
    ("Tata Consultancy Services", "TCS"),
    ("Meta", "Meta Platforms", "Facebook"),
    ("Google", "Alphabet", "Google India"),
    ("Amazon", "Amazon Web Services", "AWS", "Amazon Development Centre", "Amazon Development Center"),
    ("Flipkart", "Flipkart Internet"),
    ("Paytm", "One97 Communications"),
    ("Swiggy", "Bundl Technologies"),
    ("Zomato", "Eternal"),
    ("Ola", "ANI Technologies", "Ola Cabs"),
    ("CRED", "Dreamplug Technologies"),
    ("BYJU'S", "BYJUS", "Think and Learn"),
    ("HCLTech", "HCL Technologies", "HCL"),
    ("Larsen & Toubro", "L&T"),
    ("IBM", "International Business Machines"),
    ("JPMorgan Chase", "JPMorgan Chase & Co", "JP Morgan", "J.P. Morgan", "JPMorgan"),
    ("PwC", "PricewaterhouseCoopers"),
    ("EY", "Ernst & Young"),
    ("Mahindra & Mahindra", "M&M"),
    ("PhonePe",),
    ("Microsoft", "Microsoft India", "Microsoft India Development Center"),
)


def _tokens(name: str | None) -> list[str]:
    base = re.sub(r"\([^)]*\)", " ", name or "")  # "Acme (via Agency)" -> "Acme"
    base = base.replace("&", " and ")
    return [t for t in db.normalize_text(base).split() if t]


def _raw_key(name: str | None) -> str:
    toks = [t for t in _tokens(name) if t not in _LEGAL]
    if toks and toks[-1] == "and":
        toks = toks[:-1]
    return "".join(toks)


_ALIASES: dict[str, str] = {}
for _group in _ALIAS_GROUPS:
    _canon = _raw_key(_group[0])
    for _alias in _group:
        _ALIASES[_raw_key(_alias)] = _canon


def company_key(name: str | None) -> str:
    """Exact-tier key: legal suffixes, case, accents, punctuation and spacing ignored; aliases mapped."""
    k = _raw_key(name)
    return _ALIASES.get(k, k)


def distinctive_tokens(name: str | None) -> frozenset[str]:
    """Strong-tier key: the words left after legal suffixes and generic filler are removed."""
    return frozenset(t for t in _tokens(name) if t not in _LEGAL and t not in _GENERIC)


def match_tier(a: str | None, b: str | None) -> str | None:
    """'exact' | 'strong' | None for two free-text company names."""
    ka, kb = company_key(a), company_key(b)
    if not ka or not kb:
        return None
    if ka == kb:
        return "exact"
    da, dbt = distinctive_tokens(a), distinctive_tokens(b)
    # Too little identity for the strong tier ("GE" vs "GE Digital"): exact only.
    if not da or da != dbt or max(len(t) for t in da) < 3:
        return None
    return "strong"


@dataclass(slots=True)
class Target:
    company_id: int
    name: str
    domain: str | None
    job_id: int | None  # most recent active application's job at this company
    why: str  # watched | application | prospect


class CompanyIndex:
    """The companies AutoApply cares about, indexed for :func:`match_tier`'s two tiers."""

    def __init__(self, targets: Iterable[Target]) -> None:
        self.targets = {t.company_id: t for t in targets}
        self._exact: dict[str, list[int]] = {}
        self._strong: dict[frozenset[str], list[int]] = {}
        for t in self.targets.values():
            k = company_key(t.name)
            if k:
                self._exact.setdefault(k, []).append(t.company_id)
            d = distinctive_tokens(t.name)
            if d and max(len(x) for x in d) >= 3:
                self._strong.setdefault(d, []).append(t.company_id)

    def match(self, company: str | None) -> Target | None:
        """The tracked company ``company`` names, or None (no match, or an ambiguous strong match)."""
        k = company_key(company)
        if not k:
            return None
        ids = self._exact.get(k)
        if ids:
            return self.targets[ids[0]]
        d = distinctive_tokens(company)
        ids = list(dict.fromkeys(self._strong.get(d, []))) if d else []
        return self.targets[ids[0]] if len(ids) == 1 else None


#: Application states that mean "AutoApply is working on / has sent this application".
_ACTIVE_STATES = ("queued", "prepping", "needs_you", "filling", "awaiting_review", "submitting", "submitted")


def targets_of_interest(conn: sqlite3.Connection) -> list[Target]:
    """Watched companies, companies of queued / awaiting-review / applied jobs (not rejected or
    ghosted), and prospects that were not dismissed."""
    found: dict[int, Target] = {}

    def put(cid: int, name: str, domain: str | None, why: str, job_id: int | None = None) -> None:
        t = found.get(cid)
        if t is None:
            found[cid] = Target(cid, name, domain, job_id, why)
        elif job_id is not None and t.job_id is None:
            t.job_id = job_id

    q = ",".join("?" * len(_ACTIVE_STATES))
    for r in conn.execute(
        f"SELECT c.id, c.name, c.domain, j.id AS job_id FROM applications a JOIN jobs j ON j.id = a.job_id "
        f"JOIN companies c ON c.id = j.company_id WHERE a.state IN ({q}) "
        "AND (a.status IS NULL OR a.status NOT IN ('rejected','ghosted')) ORDER BY a.state_updated_at DESC, a.id DESC",
        _ACTIVE_STATES,
    ):
        put(int(r["id"]), r["name"], r["domain"], "application", int(r["job_id"]))
    for r in conn.execute("SELECT id, name, domain FROM companies WHERE watch = 1"):
        put(int(r["id"]), r["name"], r["domain"], "watched")
    for r in conn.execute("SELECT c.id, c.name, c.domain FROM prospects p JOIN companies c ON c.id = p.company_id "
                          "WHERE p.status <> 'dismissed'"):
        put(int(r["id"]), r["name"], r["domain"], "prospect")
    return list(found.values())


# =====================================================================================
# Import
# =====================================================================================


@dataclass(slots=True)
class ImportReport:
    imported: int = 0
    merged: int = 0
    skipped: int = 0
    matched_companies: list[dict[str, Any]] = field(default_factory=list)
    referral_suggestions: int = 0

    def as_result(self) -> dict[str, Any]:
        return {"imported": self.imported, "merged": self.merged, "skipped": self.skipped,
                "matched_companies": self.matched_companies, "referral_suggestions": self.referral_suggestions}


def _note(c: Connection) -> str:
    parts = [NOTE_PREFIX]
    role = " at ".join(p for p in (c.position, c.company) if p)
    if role:
        parts.append(role)
    if c.connected_on:
        parts.append(f"connected {c.connected_on}")
    return " · ".join(parts)


def _domain_suppressed(conn: sqlite3.Connection, domain: str | None) -> bool:
    # The do-not-contact check works on addresses; any local part tests the domain (and its parents).
    return bool(domain) and suppression.check(conn, f"linkedin-import@{domain}") is not None


def _contacts_by_url(conn: sqlite3.Connection) -> dict[str, sqlite3.Row]:
    out: dict[str, sqlite3.Row] = {}
    for r in conn.execute("SELECT * FROM contacts WHERE linkedin_url IS NOT NULL ORDER BY id"):
        key = normalize_linkedin_url(r["linkedin_url"])
        if key and key not in out:
            out[key] = r
    return out


def _company_name(conn: sqlite3.Connection, company_id: int | None) -> str | None:
    if company_id is None:
        return None
    r = conn.execute("SELECT name FROM companies WHERE id = ?", (company_id,)).fetchone()
    return r["name"] if r else None


def _merge_existing(conn: sqlite3.Connection, row: sqlite3.Row, c: Connection, company_id: int | None) -> int:
    """A newer export updates the contact found by its profile URL: the newest title and employer
    win; a note we wrote is refreshed; an email is only filled in (a typed one is kept)."""
    cid = int(row["id"])
    upd: dict[str, Any] = {}
    if company_id is not None and row["company_id"] != company_id:
        upd["company_id"] = company_id
    elif company_id is None and row["company_id"] is not None and c.company:
        # Moved to a company AutoApply doesn't track: drop the stale employer.
        if match_tier(_company_name(conn, row["company_id"]), c.company) is None:
            upd["company_id"] = None
    if c.position and c.position != row["title"]:
        upd["title"] = c.position
        upd["role_category"] = contacts.classify_role(c.position, row["email_norm"]).value
    if not row["notes"] or str(row["notes"]).startswith(NOTE_PREFIX):
        if row["notes"] != _note(c):
            upd["notes"] = _note(c)
    if not row["relationship"]:
        upd["relationship"] = RELATIONSHIP
    if row["share_ok"]:
        upd["share_ok"] = 0  # LinkedIn data never leaves the Mac
    if c.email and not row["email_norm"]:
        if conn.execute("SELECT 1 FROM contacts WHERE email_norm = ?", (c.email,)).fetchone() is None:
            upd.update(email=c.email, email_norm=c.email, email_status=EmailStatus.USER.value)
    if upd:
        upd["updated_at"] = now_ts()
        sql, params = db._update_sql("contacts", upd, "id = ?")
        conn.execute(sql, [*params, cid])
    if "email_norm" in upd:
        contacts.add_evidence(conn, cid, NewEvidence(EvidenceKind.USER, "email", snippet="from your LinkedIn export"))
        contacts.recompute_confidence(conn, cid)
    return cid


def import_connections(conn: sqlite3.Connection, file_path: str | Path) -> ImportReport:
    """Import a ``Connections.csv`` export (see the module docstring). Re-importing a newer export
    merges into the existing rows; referral suggestions are created once per person and company."""
    path = Path(file_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"file not found: {path}")
    parsed = read_connections(path)
    if not parsed.header_found:
        raise ValueError(f"{path.name} doesn't look like a LinkedIn Connections export (no First Name / Company header)")
    report = ImportReport(skipped=parsed.skipped_no_name)
    index = CompanyIndex(targets_of_interest(conn))
    matched: dict[int, dict[str, Any]] = {}
    with db.transaction(conn):
        by_url = _contacts_by_url(conn)
        seen: set[str] = set()
        for c in parsed.connections:
            dedupe = c.linkedin_url or f"{db.normalize_text(c.full_name)}|{company_key(c.company)}"
            if dedupe in seen:  # the same person twice in one file
                continue
            seen.add(dedupe)
            existing = by_url.get(c.linkedin_url) if c.linkedin_url else None
            if (c.email and suppression.check(conn, c.email) is not None) or (
                    existing is not None and existing["email_norm"] and suppression.check(conn, existing["email_norm"]) is not None):
                report.skipped += 1  # on the do-not-contact list: not stored, never suggested
                continue
            target = index.match(c.company)
            company_id = target.company_id if target else None
            if existing is not None:
                cid = _merge_existing(conn, existing, c, company_id)
                report.merged += 1
            else:
                ev = [NewEvidence(EvidenceKind.USER, "name", snippet="from your LinkedIn export")]
                if c.email:
                    ev.append(NewEvidence(EvidenceKind.USER, "email", snippet="from your LinkedIn export"))
                res = contacts.upsert_contact(
                    conn, company_id=company_id, full_name=c.full_name, origin=ContactOrigin.IMPORT, email=c.email,
                    email_status=EmailStatus.USER if c.email else EmailStatus.NONE, title=c.position,
                    linkedin_url=c.linkedin_url, relationship=RELATIONSHIP, notes=_note(c), share_ok=False, evidence=ev,
                )
                cid = res.contact.id
                if res.created:
                    report.imported += 1
                else:
                    report.merged += 1
                    if res.contact.share_ok:
                        conn.execute("UPDATE contacts SET share_ok = 0 WHERE id = ?", (cid,))
                if c.linkedin_url:
                    row = conn.execute("SELECT * FROM contacts WHERE id = ?", (cid,)).fetchone()
                    by_url[c.linkedin_url] = row
            if target is None or _domain_suppressed(conn, target.domain):
                continue
            m = matched.setdefault(target.company_id, {"company_id": target.company_id, "name": target.name,
                                                        "why": target.why, "connections": 0})
            m["connections"] += 1
            evidence = " ".join(p for p in (
                "From your LinkedIn export:", " at ".join(x for x in (c.position, c.company) if x) or c.full_name,
                f"(connected {c.connected_on})" if c.connected_on else "") if p)
            _ref, created = referrals.add(
                conn, company_id=target.company_id, person_name=c.full_name, basis=ReferralBasis.USER,
                job_id=target.job_id, contact_id=cid, title=c.position, linkedin_url=c.linkedin_url,
                basis_detail=BASIS_DETAIL, evidence_snippet=evidence, state=ReferralState.SUGGESTED,
            )
            if created:
                report.referral_suggestions += 1
        report.matched_companies = sorted(matched.values(), key=lambda m: (-m["connections"], m["name"].lower()))
        db.log_event(
            conn, "user",
            f"imported LinkedIn connections from {path.name}: {report.imported} new, {report.merged} merged, "
            f"{len(report.matched_companies)} companies matched, {report.referral_suggestions} referral suggestions",
            actor=Actor.USER, payload={"imported": report.imported, "merged": report.merged, "skipped": report.skipped,
                                       "referral_suggestions": report.referral_suggestions},
        )
    return report


__all__ = [
    "BASIS_DETAIL", "CompanyIndex", "Connection", "ImportReport", "ParseResult", "Target", "company_key",
    "distinctive_tokens", "import_connections", "match_tier", "normalize_linkedin_url", "parse_connected_on",
    "parse_connections", "read_connections", "targets_of_interest",
]
