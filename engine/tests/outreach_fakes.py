"""Test doubles for cold outreach: an ``smtplib.SMTP`` double, a read-only IMAP mailbox, a DNS
resolver, and a seeded world. Nothing here touches the network."""

from __future__ import annotations

import email
import re
import smtplib
from email.message import Message
from pathlib import Path
from typing import Any

from autoapply import db
from autoapply.enums import AppState, Ats

FIXTURES = Path(__file__).parent / "fixtures" / "outreach"


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


def eml(name: str, **replace: str) -> Message:
    text = fixture(name)
    for k, v in replace.items():
        text = text.replace(k, v)
    return email.message_from_string(text)


class FakeSMTP:
    """Records every conversation. ``fail_at``: None | 'login' | 'rcpt' | 'data_refused' | 'data_drop'."""

    instances: list["FakeSMTP"] = []
    fail_at: str | None = None

    def __init__(self, host: str, port: int, timeout: float = 30) -> None:
        self.host, self.port = host, port
        self.calls: list[tuple] = []
        self.sent: list[bytes] = []
        FakeSMTP.instances.append(self)

    @classmethod
    def reset(cls, fail_at: str | None = None) -> None:
        cls.instances = []
        cls.fail_at = fail_at

    @classmethod
    def messages(cls) -> list[Message]:
        from email import policy

        return [email.message_from_bytes(b, policy=policy.default) for s in cls.instances for b in s.sent]

    @classmethod
    def rcpt_calls(cls) -> list[str]:
        return [c[1] for s in cls.instances for c in s.calls if c[0] == "rcpt"]

    def ehlo(self) -> None:
        self.calls.append(("ehlo",))

    def starttls(self, context: Any = None) -> None:
        self.calls.append(("starttls",))

    def login(self, user: str, password: str) -> None:
        self.calls.append(("login", user))
        if FakeSMTP.fail_at == "login":
            raise smtplib.SMTPAuthenticationError(535, b"bad credentials")

    def mail(self, sender: str) -> tuple[int, bytes]:
        self.calls.append(("mail", sender))
        return 250, b"OK"

    def rcpt(self, to: str) -> tuple[int, bytes]:
        self.calls.append(("rcpt", to))
        if FakeSMTP.fail_at == "rcpt":
            return 550, b"no such user"
        return 250, b"OK"

    def data(self, msg: bytes) -> tuple[int, bytes]:
        self.calls.append(("data",))
        if FakeSMTP.fail_at == "data_refused":
            raise smtplib.SMTPDataError(554, b"rejected")
        if FakeSMTP.fail_at == "data_drop":
            raise smtplib.SMTPServerDisconnected("connection lost")
        self.sent.append(msg)
        return 250, b"queued"

    def quit(self) -> None:
        self.calls.append(("quit",))

    def close(self) -> None:
        pass


class FakeMailbox:
    """``mail.common.Mailbox`` over in-memory folders. Read-only by construction."""

    def __init__(self, folders: dict[str, list[Message]] | None = None, *, gmail_ext: bool = True) -> None:
        self.folders: dict[str, list[Message]] = folders or {"INBOX": [], '"[Gmail]/Sent Mail"': []}
        self.gmail_ext = gmail_ext
        self.current: list[Message] = []
        self.searches: list[str] = []
        self.closed = False

    def select(self, folder: str) -> bool:
        if folder not in self.folders:
            return False
        self.current = self.folders[folder]
        return True

    def _match(self, msg: Message, criteria: str) -> bool:
        c = criteria
        m = re.search(r'OR HEADER In-Reply-To "([^"]+)" HEADER References "([^"]+)"', c)
        if m:
            mid = m.group(1)
            return mid in str(msg.get("In-Reply-To", "")) or mid in str(msg.get("References", ""))
        m = re.search(r'X-GM-RAW "rfc822msgid:([^"]+)"', c)
        if m:
            return m.group(1) in str(msg.get("Message-ID", ""))
        m = re.search(r'HEADER Message-ID "([^"]+)"', c)
        if m:
            return m.group(1) in str(msg.get("Message-ID", ""))
        froms = re.findall(r'FROM "([^"]+)"', c)
        if froms:
            return any(f.lower() in str(msg.get("From", "")).lower() for f in froms)
        return False

    def search(self, criteria: str) -> list[bytes]:
        self.searches.append(criteria)
        return [str(i).encode() for i, msg in enumerate(self.current) if self._match(msg, criteria)]

    def fetch(self, uid: bytes) -> Message | None:
        i = int(uid)
        return self.current[i] if 0 <= i < len(self.current) else None

    def has_gmail_ext(self) -> bool:
        return self.gmail_ext

    def close(self) -> None:
        self.closed = True


def resolver(mapping: dict[str, list[str]] | None = None):
    """Fake MX lookups: unknown domains have Google MX unless mapped."""
    mapping = mapping or {}

    def lookup(domain: str) -> list[str]:
        return mapping.get(domain, ["aspmx.l.google.com"])

    return lookup


def seed_submitted_application(conn, *, company: str = "Acme", title: str = "Backend Engineer", domain: str | None = "acme.com",
                               description: str = "Build payment systems in Go.") -> tuple[int, int, int]:
    """(company_id, job_id, application_id) for a submitted application."""
    co = db.upsert_company(conn, company, domain=domain)
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title=title, apply_url=f"https://boards.greenhouse.io/{company.lower()}/jobs/1",
                           ats=Ats.GREENHOUSE, description=description, location="Bengaluru")
    app = db.get_application_by_job(conn, job.id)
    for s in (AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.SUBMITTING, AppState.SUBMITTED):
        db.transition(conn, app.id, s)
    return co.id, job.id, app.id


def seed_profile(conn) -> None:
    db.update_profile(conn, {
        "full_name": "Asha Rao", "first_name": "Asha", "last_name": "Rao", "email": "asha@gmail.com", "headline": "Backend Engineer",
        "years_experience": 5, "skills": ["Go", "Kafka", "Postgres"],
        "work_history": [{"company": "Razorpay", "title": "Software Engineer", "highlights": ["Cut payment latency by 40%"]}],
        "education": [{"school": "IIT Madras", "degree": "B.Tech"}],
        "links": {"github": "https://github.com/asharao"},
    })


def connect_mailbox(conn, address: str = "asha@gmail.com", *, send_enabled: bool = True) -> None:
    from autoapply.mail import imap_codes

    db.set_meta(conn, imap_codes.META_KEY, {"email": address, "enabled": True, "send_enabled": send_enabled})


GOOD_DRAFT = {
    "subject": "Backend Engineer application – Asha Rao",
    "body": ("Hi Jane,\n\nI applied for the Backend Engineer role at Acme. At Razorpay I cut payment latency by 40% "
             "using Go and Kafka.\n\nWould you be able to pass my application to the hiring manager?\n\nBest,\nAsha Rao"),
    "story_ids": [],
}
FOLLOWUP_DRAFT = {"subject": "x", "body": "Hi Jane,\n\nJust following up on my note about the Backend Engineer role.\n\nBest,\nAsha Rao",
                  "story_ids": []}
