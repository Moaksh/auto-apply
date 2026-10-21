"""The do-not-contact list (plan §C.5): an address or a whole domain.

Checked when drafting, when approving, and immediately before sending. Opt-outs can never be
removed through the protocol (only by deleting the database row by hand); everything else
(a hard bounce the user knows was a typo, a manual entry) can be undone.
"""

from __future__ import annotations

import sqlite3

from autoapply import db
from autoapply.enums import SuppressionReason
from autoapply.models import Suppression, now_ts


class SuppressionLocked(db.DBError):
    """An opt-out can't be undone."""

    code = "conflict"


def normalize_email(email: str | None) -> str | None:
    """``lower(trim(nfkc(email)))``; None for anything that is not ``local@domain.tld``."""
    import unicodedata

    if not email:
        return None
    s = unicodedata.normalize("NFKC", email).strip().strip("<>").lower()
    if s.startswith("mailto:"):
        s = s[7:].split("?", 1)[0]
    if s.count("@") != 1:
        return None
    local, domain = s.split("@")
    if not local or "." not in domain or domain.startswith(".") or domain.endswith(".") or " " in s:
        return None
    return s


def normalize_domain(domain: str | None) -> str | None:
    if not domain:
        return None
    d = domain.strip().lower().lstrip("@").removeprefix("www.").strip(".")
    return d if "." in d and " " not in d else None


def email_domain(email: str | None) -> str | None:
    norm = normalize_email(email)
    return norm.split("@", 1)[1] if norm else None


def check(conn: sqlite3.Connection, email: str | None) -> SuppressionReason | None:
    """Why ``email`` may not be contacted (its address or its domain is listed), else None."""
    norm = normalize_email(email)
    if norm is None:
        return None
    domain = norm.split("@", 1)[1]
    parts = domain.split(".")
    domains = [".".join(parts[i:]) for i in range(len(parts) - 1)]  # sub.acme.com also matches acme.com
    qmarks = ",".join("?" * len(domains))
    row = conn.execute(
        f"SELECT reason FROM suppression WHERE email_norm = ? OR domain IN ({qmarks}) "
        "ORDER BY CASE reason WHEN 'opt_out' THEN 0 ELSE 1 END LIMIT 1",
        (norm, *domains),
    ).fetchone()
    return SuppressionReason(row["reason"]) if row else None


def add(
    conn: sqlite3.Connection, *, email: str | None = None, domain: str | None = None,
    reason: SuppressionReason | str = SuppressionReason.USER, source: str | None = None,
) -> Suppression:
    """List an address or a domain. Re-listing keeps the strongest reason (an opt-out wins)."""
    reason = SuppressionReason(reason)
    norm, dom = normalize_email(email), normalize_domain(domain)
    if norm is None and dom is None:
        raise ValueError("give a valid email address or domain")
    if norm is not None and dom is not None:
        raise ValueError("give an email address or a domain, not both")
    col, val = ("email_norm", norm) if norm is not None else ("domain", dom)
    with db.transaction(conn):
        row = conn.execute(f"SELECT * FROM suppression WHERE {col} = ?", (val,)).fetchone()
        if row is None:
            cur = conn.execute(
                f"INSERT INTO suppression({col}, reason, source, created_at) VALUES (?, ?, ?, ?)",
                (val, reason.value, source, now_ts()),
            )
            sid = int(cur.lastrowid)
        else:
            sid = int(row["id"])
            if reason is SuppressionReason.OPT_OUT and row["reason"] != SuppressionReason.OPT_OUT.value:
                conn.execute("UPDATE suppression SET reason = ?, source = ? WHERE id = ?", (reason.value, source, sid))
        db.log_event(conn, "outreach", f"do-not-contact: {val} ({reason.value})", payload={"suppression_id": sid, "reason": reason.value})
    return get(conn, sid)


def remove(conn: sqlite3.Connection, *, email: str | None = None, domain: str | None = None) -> bool:
    """Take an entry off the list. Raises :class:`SuppressionLocked` for an opt-out."""
    norm, dom = normalize_email(email), normalize_domain(domain)
    if norm is None and dom is None:
        raise ValueError("give a valid email address or domain")
    col, val = ("email_norm", norm) if norm is not None else ("domain", dom)
    with db.transaction(conn):
        row = conn.execute(f"SELECT id, reason FROM suppression WHERE {col} = ?", (val,)).fetchone()
        if row is None:
            return False
        if row["reason"] == SuppressionReason.OPT_OUT.value:
            raise SuppressionLocked(f"{val} asked not to be contacted; that can't be undone")
        conn.execute("DELETE FROM suppression WHERE id = ?", (row["id"],))
        db.log_event(conn, "outreach", f"removed {val} from the do-not-contact list", actor="user")
    return True


def get(conn: sqlite3.Connection, suppression_id: int) -> Suppression:
    row = conn.execute("SELECT * FROM suppression WHERE id = ?", (suppression_id,)).fetchone()
    if row is None:
        raise db.NotFound(f"suppression {suppression_id} not found")
    return Suppression.from_row(row)  # type: ignore[return-value]


def list_all(conn: sqlite3.Connection) -> list[Suppression]:
    return [Suppression.from_row(r) for r in conn.execute("SELECT * FROM suppression ORDER BY created_at DESC")]  # type: ignore[misc]


__all__ = ["SuppressionLocked", "add", "check", "email_domain", "list_all", "normalize_domain", "normalize_email", "remove"]
