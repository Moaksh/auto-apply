"""IMAP helpers shared by the security-code reader (``imap_codes``) and the outreach mail
watcher (``outreach.mailwatch``): login, logout, text extraction, and a small read-only
mailbox wrapper.

Everything here is read-only: folders are selected with ``readonly=True`` and messages are
fetched with ``BODY.PEEK[]``, so nothing is ever marked as read.
"""

from __future__ import annotations

import email
import imaplib
import re
from email.message import Message
from typing import Protocol

IMAP_HOSTS = {"gmail.com": "imap.gmail.com", "googlemail.com": "imap.gmail.com", "outlook.com": "outlook.office365.com",
              "hotmail.com": "outlook.office365.com", "live.com": "outlook.office365.com", "yahoo.com": "imap.mail.yahoo.com",
              "icloud.com": "imap.mail.me.com", "me.com": "imap.mail.me.com"}
#: Gmail's Sent Mail folder (IMAP name).
GMAIL_SENT = '"[Gmail]/Sent Mail"'


class MailError(Exception):
    pass


def normalize_password(password: str) -> str:
    """App passwords are letters only; pasted copies often carry spaces, NBSPs or a newline."""
    return re.sub(r"\s+", "", password or "", flags=re.UNICODE).replace(" ", "")


def imap_host(address: str) -> str:
    domain = address.rsplit("@", 1)[-1].lower()
    return IMAP_HOSTS.get(domain, "imap.gmail.com")  # Google Workspace domains use Gmail's IMAP


def is_google_mailbox(address: str) -> bool:
    """Gmail or (presumably) Google Workspace: the only providers v1 sends through."""
    return imap_host(address) == "imap.gmail.com"


def _login(address: str, password: str) -> imaplib.IMAP4_SSL:
    try:
        m = imaplib.IMAP4_SSL(imap_host(address), 993, timeout=20)
        m.login(address, normalize_password(password))  # Google shows app passwords in groups of 4
        return m
    except imaplib.IMAP4.error as e:
        raise MailError("login refused: check the address and the app password (2-Step Verification must be on)") from e
    except OSError as e:
        raise MailError(f"could not reach the mail server: {e}") from e


def _logout(m: imaplib.IMAP4_SSL) -> None:
    try:
        m.logout()
    except Exception:  # noqa: BLE001
        pass


def _text(msg: Message) -> str:
    """Plain text of a message (text/plain and de-tagged text/html parts, no attachments)."""
    parts: list[str] = []
    for part in msg.walk() if msg.is_multipart() else [msg]:
        ctype = part.get_content_type()
        if ctype not in ("text/plain", "text/html") or part.get("Content-Disposition", "").startswith("attachment"):
            continue
        try:
            payload = part.get_payload(decode=True) or b""
            body = payload.decode(part.get_content_charset() or "utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            continue
        if ctype == "text/html":
            body = re.sub(r"<style.*?</style>|<script.*?</script>", " ", body, flags=re.S | re.I)
            body = re.sub(r"<[^>]+>", " ", body)
        parts.append(body)
    return re.sub(r"[ \t\r\f\v]+", " ", "\n".join(parts))


# ---- read-only mailbox seam (faked in tests) ---------------------------------------------


class Mailbox(Protocol):
    """What the outreach mail watcher needs from IMAP. Never writes, never marks as read."""

    def select(self, folder: str) -> bool: ...

    def search(self, criteria: str) -> list[bytes]: ...

    def fetch(self, uid: bytes) -> Message | None: ...

    def has_gmail_ext(self) -> bool: ...

    def close(self) -> None: ...


class ImapMailbox:
    """:class:`Mailbox` over ``imaplib`` (blocking; call from a worker thread)."""

    def __init__(self, address: str, password: str) -> None:
        self._m = _login(address, password)

    def select(self, folder: str) -> bool:
        typ, _ = self._m.select(folder, readonly=True)
        return typ == "OK"

    def search(self, criteria: str) -> list[bytes]:
        try:
            typ, data = self._m.search(None, criteria)
        except imaplib.IMAP4.error:
            return []
        return (data[0] or b"").split() if typ == "OK" and data else []

    def fetch(self, uid: bytes) -> Message | None:
        typ, data = self._m.fetch(uid, "(BODY.PEEK[])")
        if typ != "OK" or not data or not isinstance(data[0], tuple):
            return None
        return email.message_from_bytes(data[0][1])

    def message_id(self, uid: bytes) -> str | None:
        """Only the Message-ID header (cheap; lets a scan skip messages it has already seen)."""
        try:
            typ, data = self._m.fetch(uid, "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
        except imaplib.IMAP4.error:
            return None
        if typ != "OK" or not data or not isinstance(data[0], tuple):
            return None
        return (email.message_from_bytes(data[0][1]).get("Message-ID") or "").strip() or None

    def has_gmail_ext(self) -> bool:
        return "X-GM-EXT-1" in getattr(self._m, "capabilities", ())

    def close(self) -> None:
        _logout(self._m)
