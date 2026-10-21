"""Security codes straight from the user's mailbox over IMAP (Gmail + app password).

* Credentials: the address lives in ``meta`` (``mail_account``); the app password lives in the
  macOS login Keychain (service ``AutoApply Mail``), read with the ``security`` tool. Nothing
  else leaves the Mac: the connection goes directly to the mail provider.
* Only messages that arrived after Submit was clicked are looked at, and a code is only taken
  from a message that names the company (subject or body): the code always matches the job.
"""

from __future__ import annotations

import asyncio
import email
import logging
import re
import subprocess
import time
from datetime import UTC, datetime, timedelta
from email.header import decode_header, make_header
from email.message import Message
from email.utils import parsedate_to_datetime
from typing import Any

# Shared with the outreach mail watcher; re-exported here for existing callers.
from autoapply.mail.common import (  # noqa: F401
    IMAP_HOSTS,
    MailError,
    _login,
    _logout,
    _text,
    imap_host,
    normalize_password,
)

log = logging.getLogger("autoapply.mail")

KEYCHAIN_SERVICE = "AutoApply Mail"
META_KEY = "mail_account"


# ---- credentials -----------------------------------------------------------------------


def keychain_set(address: str, password: str) -> None:
    r = subprocess.run(["security", "add-generic-password", "-a", address, "-s", KEYCHAIN_SERVICE, "-w",
                        normalize_password(password), "-U"],
                       capture_output=True, text=True, timeout=15)
    if r.returncode != 0:
        raise MailError(f"could not save the password in the Keychain: {r.stderr.strip()}")


def keychain_get(address: str) -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-a", address, "-s", KEYCHAIN_SERVICE, "-w"],
                       capture_output=True, text=True, timeout=15)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    out = r.stdout.rstrip("\n")
    # `security -w` prints the secret as hex when it contains non-printable bytes (a pasted newline…).
    if len(out) % 2 == 0 and re.fullmatch(r"[0-9a-f]+", out) and len(out) > 20:
        try:
            out = bytes.fromhex(out).decode("utf-8")
        except ValueError:
            pass
    return normalize_password(out)


def keychain_delete(address: str) -> None:
    subprocess.run(["security", "delete-generic-password", "-a", address, "-s", KEYCHAIN_SERVICE],
                   capture_output=True, text=True, timeout=15)


def account(conn: Any) -> dict[str, Any] | None:
    from autoapply import db

    a = db.get_meta(conn, META_KEY, None)
    return a if isinstance(a, dict) and a.get("email") else None


# ---- IMAP ------------------------------------------------------------------------------


def test_login(address: str, password: str) -> None:
    m = _login(address, password)
    try:
        m.select("INBOX", readonly=True)
    finally:
        _logout(m)


def extract_code(text: str, length: int | None) -> str | None:
    """The code from a "security / verification code" email: a token of the expected length
    (letters and digits) appearing after the word "code"."""
    if not text:
        return None
    n = f"{{{length}}}" if length else "{6,10}"
    # Greenhouse (and most ATSs) put the code alone on its own line: take that first.
    for line in text.splitlines():
        tok = line.strip()
        if re.fullmatch(rf"[A-Za-z0-9]{n}", tok) and _looks_like_code(tok):
            return tok
    after = re.split(r"\bcode\b", text, maxsplit=1, flags=re.I)
    zones = [after[1][:600]] if len(after) > 1 else []
    zones.append(text)
    for zone in zones:
        for m in re.finditer(rf"(?<![A-Za-z0-9])([A-Za-z0-9]{n})(?![A-Za-z0-9])", zone):
            tok = m.group(1)
            if _looks_like_code(tok):
                return tok
    return None


def _looks_like_code(tok: str) -> bool:
    """Digits, ALL CAPS, or mixed case beyond a capital first letter ("AbCdEfGh") — not a word."""
    if any(c.isdigit() for c in tok):
        return True
    if tok.isupper():
        return True
    return any(c.isupper() for c in tok[1:]) and any(c.islower() for c in tok)


def find_code_once(address: str, password: str, *, company: str, sent_after: datetime, length: int | None) -> str | None:
    m = _login(address, password)
    try:
        m.select("INBOX", readonly=True)
        since = (sent_after - timedelta(days=1)).strftime("%d-%b-%Y")
        typ, data = m.search(None, f'(SINCE "{since}")')
        ids = (data[0] or b"").split()[-30:] if typ == "OK" else []
        company_l = company.lower()
        for mid in reversed(ids):
            typ, msg_data = m.fetch(mid, "(RFC822)")
            if typ != "OK" or not msg_data or not isinstance(msg_data[0], tuple):
                continue
            msg = email.message_from_bytes(msg_data[0][1])
            try:
                when = parsedate_to_datetime(msg.get("Date"))
                when = when if when.tzinfo else when.replace(tzinfo=UTC)
            except Exception:  # noqa: BLE001
                continue
            if when < sent_after - timedelta(seconds=90):
                continue
            subject = str(make_header(decode_header(msg.get("Subject", ""))))
            body = _text(msg)
            hay = f"{subject}\n{body}"
            if "code" not in hay.lower() or company_l not in hay.lower():
                continue
            code = extract_code(hay, length)
            if code:
                return code
        return None
    finally:
        _logout(m)


async def poll_code(conn: Any, *, company: str, sent_after: datetime, length: int | None, timeout_s: float = 120.0,
                    every_s: float = 8.0) -> str | None:
    """Poll the configured mailbox for the job's code (None when no account / not found in time)."""
    acc = account(conn)
    if not acc or not acc.get("enabled", True):
        return None
    password = await asyncio.to_thread(keychain_get, acc["email"])
    if not password:
        return None
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            code = await asyncio.to_thread(find_code_once, acc["email"], password, company=company,
                                           sent_after=sent_after, length=length)
        except MailError as e:
            log.warning("mailbox check failed: %s", e)
            return None
        except Exception:  # noqa: BLE001
            log.warning("mailbox check failed", exc_info=True)
            return None
        if code:
            return code
        await asyncio.sleep(every_s)
    return None


# ---- account emails (sign-up confirmation / password reset) -----------------------------

#: Words a confirm / activate / reset link (or its anchor text) carries.
_ACTION_LINK_RX = re.compile(r"verif|confirm|activat|validat|reset|password|passwd|register|registration|sign[-_ ]?up|"
                             r"token|magic|login|log[-_ ]?in|otp", re.I)
_SKIP_LINK_RX = re.compile(r"unsubscribe|privacy|terms|help|support|facebook|twitter|linkedin\.com|instagram|youtube|"
                           r"\.(png|jpe?g|gif|svg|css)(\?|$)|mailto:", re.I)
_HREF_RX = re.compile(r"""<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>""", re.I | re.S)
_URL_RX = re.compile(r"https?://[^\s<>\"')\]]+", re.I)


def _html_parts(msg: Message) -> list[str]:
    out: list[str] = []
    for part in msg.walk() if msg.is_multipart() else [msg]:
        if part.get_content_type() != "text/html":
            continue
        try:
            out.append((part.get_payload(decode=True) or b"").decode(part.get_content_charset() or "utf-8", errors="replace"))
        except Exception:  # noqa: BLE001
            continue
    return out


def extract_action_link(msg: Message, text: str) -> str | None:
    """The confirm / activate / reset link of an account email: an http(s) link whose URL or
    anchor text reads like one (never unsubscribe / social / image links)."""
    import html as _html

    candidates: list[tuple[str, str]] = []
    for body in _html_parts(msg):
        for href, anchor in _HREF_RX.findall(body):
            candidates.append((_html.unescape(href.strip()), re.sub(r"<[^>]+>", " ", anchor)))
    candidates += [(u.rstrip(".,;"), "") for u in _URL_RX.findall(text)]
    for url, anchor in candidates:
        if not url.lower().startswith(("http://", "https://")) or _SKIP_LINK_RX.search(url):
            continue
        if _ACTION_LINK_RX.search(url) or _ACTION_LINK_RX.search(anchor):
            return url
    return None


def _matches(hay: str, sender: str, terms: list[str]) -> bool:
    low = f"{sender}\n{hay}".lower()
    return any(t and t.lower() in low for t in terms)


def find_account_mail_once(address: str, password: str, *, terms: list[str], sent_after: datetime, want: str,
                           length: int | None = None) -> str | None:
    """Newest message since ``sent_after`` that mentions one of ``terms`` (the site / company,
    in the sender, subject or body) and carries what is wanted: a ``code`` or a ``link``."""
    m = _login(address, password)
    try:
        m.select("INBOX", readonly=True)
        since = (sent_after - timedelta(days=1)).strftime("%d-%b-%Y")
        typ, data = m.search(None, f'(SINCE "{since}")')
        ids = (data[0] or b"").split()[-30:] if typ == "OK" else []
        for mid in reversed(ids):
            typ, msg_data = m.fetch(mid, "(RFC822)")
            if typ != "OK" or not msg_data or not isinstance(msg_data[0], tuple):
                continue
            msg = email.message_from_bytes(msg_data[0][1])
            try:
                when = parsedate_to_datetime(msg.get("Date"))
                when = when if when.tzinfo else when.replace(tzinfo=UTC)
            except Exception:  # noqa: BLE001
                continue
            if when < sent_after - timedelta(seconds=90):
                continue
            subject = str(make_header(decode_header(msg.get("Subject", ""))))
            sender = str(make_header(decode_header(msg.get("From", ""))))
            body = _text(msg)
            hay = f"{subject}\n{body}"
            if not _matches(hay, sender, terms):
                continue
            found = extract_action_link(msg, body) if want == "link" else (extract_code(hay, length) if "code" in hay.lower() else None)
            if found:
                return found
        return None
    finally:
        _logout(m)


async def poll_account_mail(conn: Any, *, terms: list[str], sent_after: datetime, want: str, length: int | None = None,
                            timeout_s: float = 120.0, every_s: float = 8.0) -> str | None:
    """Poll the connected mailbox for a sign-up / reset email (None: no mailbox or nothing in time)."""
    acc = account(conn)
    if not acc or not acc.get("enabled", True):
        return None
    password = await asyncio.to_thread(keychain_get, acc["email"])
    if not password:
        return None
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            found = await asyncio.to_thread(find_account_mail_once, acc["email"], password, terms=terms,
                                            sent_after=sent_after, want=want, length=length)
        except MailError as e:
            log.warning("mailbox check failed: %s", e)
            return None
        except Exception:  # noqa: BLE001
            log.warning("mailbox check failed", exc_info=True)
            return None
        if found:
            return found
        await asyncio.sleep(every_s)
    return None
