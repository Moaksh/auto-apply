"""Sending cold-outreach email from the user's own Gmail / Google Workspace mailbox.

* Transport: ``smtp.gmail.com:587`` + STARTTLS, logging in with the same app password the
  security-code reader uses (macOS Keychain, ``imap_codes.keychain_get``). Gmail files
  SMTP-sent mail in Sent Mail by itself, so the user's mailbox shows the whole conversation.
* Format: ``text/plain; charset=utf-8`` only. No HTML, no tracking pixels, no link rewriting,
  no attachments, no bulk headers (``List-Unsubscribe`` makes one-to-one mail look like marketing).
* Phases: everything up to and including ``RCPT TO`` is checked before ``DATA``. A refusal
  there (or an explicit refusal of the data) raises :class:`SendRefused`: the message was
  definitely not sent. A dropped connection or timeout during ``DATA`` raises
  :class:`SendUnknown`: it may have been sent, so callers record ``unknown`` and never retry.
* Never used to probe addresses: there is no ``VRFY`` and no ``RCPT`` without a message.

Blocking: call through ``asyncio.to_thread``.
"""

from __future__ import annotations

import logging
import smtplib
import ssl
from collections.abc import Callable
from email import policy
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid
from typing import Any

from autoapply.mail.common import normalize_password

log = logging.getLogger("autoapply.mail.smtp")

SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 587
TIMEOUT_S = 30.0

SmtpFactory = Callable[..., Any]  # smtplib.SMTP-compatible (host, port, timeout=...)


class SendRefused(Exception):
    """The server refused before (or explicitly at) DATA: the email was NOT sent."""


class SendUnknown(Exception):
    """The connection broke during DATA: the email may or may not have been sent."""


def make_message_id(mailbox: str) -> str:
    """``<…@mailbox-domain>``: stored before sending, used for threading and the Sent Mail check."""
    return make_msgid(domain=mailbox.rsplit("@", 1)[-1].lower())


def compose(
    *,
    from_name: str | None,
    from_addr: str,
    to: str,
    subject: str,
    body: str,
    message_id: str,
    in_reply_to: str | None = None,
    references: list[str] | None = None,
) -> EmailMessage:
    """A plain-text message. ``in_reply_to`` / ``references`` make a follow-up a reply in the
    same conversation (Gmail threads on these plus the ``Re:`` subject)."""
    msg = EmailMessage(policy=policy.SMTP)
    msg["From"] = formataddr((from_name, from_addr)) if from_name else from_addr
    msg["To"] = to
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = message_id
    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to
        msg["References"] = " ".join(dict.fromkeys([*(references or []), in_reply_to]))
    msg.set_content(body, subtype="plain", charset="utf-8")
    return msg


def _connect(address: str, password: str, smtp_factory: SmtpFactory) -> Any:
    try:
        smtp = smtp_factory(SMTP_HOST, SMTP_PORT, timeout=TIMEOUT_S)
    except (OSError, smtplib.SMTPException) as e:
        raise SendRefused(f"could not reach {SMTP_HOST}: {e}") from e
    try:
        smtp.ehlo()
        smtp.starttls(context=ssl.create_default_context())
        smtp.ehlo()
        smtp.login(address, normalize_password(password))
    except smtplib.SMTPAuthenticationError as e:
        _quit(smtp)
        raise SendRefused("Gmail refused the login: check the app password (Workspace admins can disable app passwords)") from e
    except (OSError, smtplib.SMTPException) as e:
        _quit(smtp)
        raise SendRefused(f"could not start a secure session with {SMTP_HOST}: {e}") from e
    return smtp


def _quit(smtp: Any) -> None:
    try:
        smtp.quit()
    except Exception:  # noqa: BLE001
        try:
            smtp.close()
        except Exception:  # noqa: BLE001
            pass


def send(address: str, password: str, msg: EmailMessage, *, smtp_factory: SmtpFactory = smtplib.SMTP) -> None:
    """Send ``msg`` from ``address``. Raises :class:`SendRefused` or :class:`SendUnknown`."""
    smtp = _connect(address, password, smtp_factory)
    to = str(msg["To"])
    try:
        try:
            code, resp = smtp.mail(address)
            if code != 250:
                raise SendRefused(f"sender refused: {code} {resp!r}")
            code, resp = smtp.rcpt(to)
            if code not in (250, 251):
                raise SendRefused(f"recipient refused: {code} {resp!r}")
        except SendRefused:
            raise
        except (OSError, smtplib.SMTPException) as e:
            raise SendRefused(f"refused before sending: {e}") from e
        try:
            smtp.data(msg.as_bytes(policy=policy.SMTP))
        except smtplib.SMTPDataError as e:  # an explicit refusal of this message
            raise SendRefused(f"message refused: {e.smtp_code} {e.smtp_error!r}") from e
        except (OSError, smtplib.SMTPException) as e:
            raise SendUnknown(f"connection lost while sending: {e}") from e
    finally:
        _quit(smtp)


def send_test_email(address: str, password: str, *, from_name: str | None = None, smtp_factory: SmtpFactory = smtplib.SMTP) -> str:
    """Send a short test email to ``address`` itself; returns its Message-ID."""
    mid = make_message_id(address)
    msg = compose(
        from_name=from_name, from_addr=address, to=address, subject="AutoApply test email",
        body=("This is a test from AutoApply. Sending works.\n\n"
              "Cold emails are only ever sent after you approve them, a few per day, inside your send window."),
        message_id=mid,
    )
    send(address, password, msg, smtp_factory=smtp_factory)
    return mid


__all__ = ["SendRefused", "SendUnknown", "compose", "make_message_id", "send", "send_test_email"]
