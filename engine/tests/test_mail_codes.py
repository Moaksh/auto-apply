"""Security codes read from the mailbox (IMAP), tied to the job by company name and time."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from email.message import EmailMessage
from email.utils import format_datetime
from types import SimpleNamespace

import pytest

from autoapply import db
from autoapply.apply.email_code import wait_for_code
from autoapply.mail import imap_codes
from autoapply.mail.imap_codes import extract_code, find_code_once


def _mail(subject: str, body: str, when: datetime) -> bytes:
    m = EmailMessage()
    m["Subject"], m["From"], m["Date"] = subject, "no-reply@us.greenhouse-mail.io", format_datetime(when)
    m.set_content(body)
    return m.as_bytes()


class FakeImap:
    def __init__(self, messages: list[bytes]) -> None:
        self.messages = messages

    def select(self, *_a, **_k):  # noqa: ANN002, ANN003
        return "OK", [b""]

    def search(self, *_a):  # noqa: ANN002
        return "OK", [b" ".join(str(i + 1).encode() for i in range(len(self.messages)))]

    def fetch(self, mid, _what):  # noqa: ANN001
        return "OK", [(b"1", self.messages[int(mid) - 1])]

    def logout(self) -> None:
        pass


def test_extract_code_shapes() -> None:
    assert extract_code("Copy and paste this code into the security code field: aB3x9Kq2", 8) == "aB3x9Kq2"
    assert extract_code("Your verification code is 482913", 6) == "482913"
    assert extract_code("Thanks for applying to Acme", 8) is None


def test_only_the_jobs_company_and_recent_mail_count(monkeypatch: pytest.MonkeyPatch) -> None:
    now = datetime.now(UTC)
    msgs = [
        _mail("Security code for your application to Observe.AI", "Your code: OBS12345", now - timedelta(hours=3)),  # too old
        _mail("Security code for your application to Elastic", "Your code: ELA98765", now),  # other company
        _mail("Security code for your application to Observe.AI", "Your code: aB3x9Kq2", now),
    ]
    monkeypatch.setattr(imap_codes, "_login", lambda a, p: FakeImap(msgs))
    got = find_code_once("me@gmail.com", "pw", company="Observe.AI", sent_after=now - timedelta(seconds=30), length=8)
    assert got == "aB3x9Kq2"


async def test_mailbox_answers_without_an_inbox_question(conn, monkeypatch: pytest.MonkeyPatch) -> None:  # type: ignore[no-untyped-def]
    db.set_meta(conn, imap_codes.META_KEY, {"email": "me@gmail.com", "enabled": True})

    async def fake_poll(*_a, **_k):  # noqa: ANN002, ANN003
        return "aB3x9Kq2"

    monkeypatch.setattr(imap_codes, "poll_code", fake_poll)
    co = db.upsert_company(conn, "Observe.AI")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="AI Agent Engineer", apply_url="https://x.test/1")

    async def emit(*_a):  # noqa: ANN002
        return None

    code = await wait_for_code(SimpleNamespace(conn=conn, job=job, emit=emit), ats="Greenhouse", email="me@gmail.com",
                               length=8, timeout_s=5, poll_s=0.05)
    assert code == "aB3x9Kq2"
    assert not db.list_open_clusters(conn)  # nothing was asked


def test_imap_host_for_gmail_and_workspace() -> None:
    assert imap_codes.imap_host("a@gmail.com") == "imap.gmail.com"
    assert imap_codes.imap_host("a@company.com") == "imap.gmail.com"
    assert imap_codes.imap_host("a@outlook.com") == "outlook.office365.com"


def test_no_account_means_no_mail_poll(conn) -> None:  # type: ignore[no-untyped-def]
    assert asyncio.run(imap_codes.poll_code(conn, company="X", sent_after=datetime.now(UTC), length=8, timeout_s=0.1)) is None


def test_letter_only_mixed_case_code_on_its_own_line() -> None:
    body = "Copy and paste this code into the security code field on your application:\n\n  QwErTyUi \n\nIf you did not apply, ignore this email.\n"
    assert extract_code(body, 8) == "QwErTyUi"
    assert extract_code("Security reminder: Greenhou se application", 8) is None
