"""Job-site accounts the agent creates for the user (Workday tenants, iCIMS, Taleo, ...).

Some application sites want an account before they show the form. When
``preferences.create_accounts`` is on and a mailbox is connected (``mail/imap_codes.py``), the
agent signs up with the mailbox address and a password generated here, confirms the email from
the mailbox, and carries on with the application. If the address is already registered, it resets
the password through the emailed link.

* Passwords: one random password per site, only ever in the macOS login Keychain (service
  ``AutoApply Accounts``, account = the site's host). The previous one is kept under
  ``<host> (previous)`` across a reset, so nothing is lost if a reset doesn't finish.
* Index: ``meta['site_accounts']`` = {host: {email, company, status, created_at, updated_at,
  job_id}} — what Settings lists. No secret is ever written to the database.
* Status: ``creating`` / ``resetting`` while the agent is at it, ``active`` once it signed up /
  signed in / reset, ``unconfirmed`` when it gave up half-way (the password is kept: the
  account may exist).
"""

from __future__ import annotations

import logging
import secrets
import string
import subprocess
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

from autoapply import db
from autoapply.models import utcnow

log = logging.getLogger("autoapply.site_accounts")

KEYCHAIN_SERVICE = "AutoApply Accounts"
META_KEY = "site_accounts"
PASSWORD_LENGTH = 20
#: Symbols nearly every password policy accepts (no quotes, angle brackets, spaces or backslashes).
_SYMBOLS = "!@#$%^*-_+="

STATUS_CREATING = "creating"
STATUS_RESETTING = "resetting"
STATUS_ACTIVE = "active"
STATUS_UNCONFIRMED = "unconfirmed"


class AccountError(Exception):
    pass


@dataclass(slots=True)
class SiteLogin:
    host: str
    email: str
    password: str
    #: a login stored earlier (sign in with it) vs one generated just now (sign up / reset with it)
    existing: bool


# ---- helpers --------------------------------------------------------------------------


def site_key(url: str) -> str:
    """The site an account belongs to: the page's host without ``www.`` (``acme.wd5.myworkdayjobs.com``)."""
    raw = (url or "").strip()
    host = (urlsplit(raw if "//" in raw else f"https://{raw}").hostname or "").lower()
    host = host.removeprefix("www.")
    if not host or "." not in host:
        raise AccountError(f"not a site address: {url!r}")
    return host


def generate_password(length: int = PASSWORD_LENGTH) -> str:
    """Random password with at least one upper, lower, digit and symbol (common site rules)."""
    pools = [string.ascii_uppercase, string.ascii_lowercase, string.digits, _SYMBOLS]
    alphabet = "".join(pools)
    chars = [secrets.choice(p) for p in pools] + [secrets.choice(alphabet) for _ in range(length - len(pools))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


# ---- Keychain ---------------------------------------------------------------------------


def _previous(host: str) -> str:
    return f"{host} (previous)"


def keychain_set(host: str, password: str) -> None:
    r = subprocess.run(["security", "add-generic-password", "-a", host, "-s", KEYCHAIN_SERVICE, "-l",
                        f"AutoApply: {host}", "-w", password, "-U"], capture_output=True, text=True, timeout=15)
    if r.returncode != 0:
        raise AccountError(f"could not save the password in the Keychain: {r.stderr.strip()}")


def keychain_get(host: str) -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-a", host, "-s", KEYCHAIN_SERVICE, "-w"],
                       capture_output=True, text=True, timeout=15)
    out = r.stdout.rstrip("\n")
    return out if r.returncode == 0 and out else None


def keychain_delete(host: str) -> None:
    subprocess.run(["security", "delete-generic-password", "-a", host, "-s", KEYCHAIN_SERVICE],
                   capture_output=True, text=True, timeout=15)


# ---- index ------------------------------------------------------------------------------


def _index(conn: Any) -> dict[str, dict[str, Any]]:
    data = db.get_meta(conn, META_KEY, None)
    return data if isinstance(data, dict) else {}


def _save_index(conn: Any, data: dict[str, dict[str, Any]]) -> None:
    db.set_meta(conn, META_KEY, data)


def list_accounts(conn: Any) -> list[dict[str, Any]]:
    """Every site account, newest first (no passwords)."""
    rows = [{"host": h, **v} for h, v in _index(conn).items()]
    return sorted(rows, key=lambda r: str(r.get("updated_at") or ""), reverse=True)


def get_account(conn: Any, host: str) -> dict[str, Any] | None:
    row = _index(conn).get(host)
    return {"host": host, **row} if row else None


def _put(conn: Any, host: str, **fields: Any) -> None:
    data = _index(conn)
    now = utcnow().isoformat()
    row = data.get(host) or {"created_at": now}
    row.update({k: v for k, v in fields.items() if v is not None})
    row["updated_at"] = now
    data[host] = row
    _save_index(conn, data)


# ---- what the agent uses -----------------------------------------------------------------


def mailbox_address(conn: Any) -> str | None:
    from autoapply.mail import imap_codes

    acc = imap_codes.account(conn)
    return acc["email"] if acc and acc.get("enabled", True) else None


def enabled(conn: Any) -> bool:
    """The agent may create accounts: the preference is on and a mailbox can receive the emails."""
    return bool(db.get_preferences(conn).create_accounts and mailbox_address(conn))


def begin(conn: Any, url: str, *, purpose: str, company: str | None = None, job_id: int | None = None) -> SiteLogin:
    """Credentials for signing up (``create``), signing in (``sign_in``) or resetting the password
    (``reset``) at ``url``'s site. A new password is saved in the Keychain BEFORE the agent types
    it, so a crash mid-way never loses a password a site may already have accepted."""
    if purpose not in {"create", "sign_in", "reset"}:
        raise AccountError(f"unknown purpose {purpose!r}")
    email = mailbox_address(conn)
    if not email:
        raise AccountError("no mailbox is connected")
    host = site_key(url)
    stored = keychain_get(host)
    known = get_account(conn, host)
    if purpose in {"create", "sign_in"} and stored and known:
        _put(conn, host, job_id=job_id)
        return SiteLogin(host, str(known.get("email") or email), stored, existing=True)
    if purpose == "sign_in":
        raise AccountError(f"no saved login for {host}: create an account, or reset the password if it already exists")
    password = generate_password()
    if purpose == "reset" and stored:
        keychain_set(_previous(host), stored)
    keychain_set(host, password)
    _put(conn, host, email=email, company=company, job_id=job_id,
         status=STATUS_RESETTING if purpose == "reset" else STATUS_CREATING)
    return SiteLogin(host, email, password, existing=False)


def finish(conn: Any, host: str, outcome: str) -> None:
    """``created`` / ``signed_in`` / ``reset`` → active; ``failed`` → unconfirmed (kept)."""
    if get_account(conn, host) is None:
        return
    if outcome in {"created", "signed_in", "reset"}:
        _put(conn, host, status=STATUS_ACTIVE)
        keychain_delete(_previous(host))
    else:
        _put(conn, host, status=STATUS_UNCONFIRMED)


def reveal(conn: Any, host: str) -> str | None:
    return keychain_get(host) if get_account(conn, host) else None


def delete(conn: Any, host: str) -> bool:
    data = _index(conn)
    existed = data.pop(host, None) is not None
    keychain_delete(host)
    keychain_delete(_previous(host))
    _save_index(conn, data)
    return existed


__all__ = [
    "AccountError", "KEYCHAIN_SERVICE", "META_KEY", "SiteLogin", "begin", "delete", "enabled", "finish", "generate_password",
    "get_account", "list_accounts", "mailbox_address", "reveal", "site_key",
]
