"""Fixtures for workstream A tests: local ATS fixture server, seeded DB rows, scripted resolver.

Nothing here touches the network: board APIs are mocked with respx, ATS forms are local HTML
files served from 127.0.0.1, and every submit is restricted to localhost via
``AUTOAPPLY_SUBMIT_ALLOWED_HOSTS``.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
from dataclasses import dataclass, field
from email.parser import BytesParser
from email.policy import HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

import pytest

from autoapply import db
from autoapply.answers.guardrails import NeedsUser
from autoapply.enums import AnswerOrigin, AppState, Ats, JobSource, QuestionReason
from autoapply.models import FormQuestion

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "ats"

CONFIRM_PAGES = {
    "/greenhouse/confirmation": "<html><body><h1>Thank you for applying.</h1><p>Your application has been received.</p></body></html>",
    "/lever/thanks": "<html><body><h3>Application submitted!</h3><p>Thanks for applying to Acme Robotics.</p></body></html>",
}


def load_json(name: str) -> Any:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


# =====================================================================================
# Local fixture server
# =====================================================================================


@dataclass
class Submission:
    path: str
    fields: dict[str, list[str]]
    files: dict[str, tuple[str, bytes]]
    app_state_at_post: str | None = None


@dataclass
class FixtureServer:
    base_url: str = ""
    submissions: list[Submission] = field(default_factory=list)
    db_path: Path | None = None
    watch_application_id: int | None = None

    def url(self, path: str) -> str:
        return self.base_url + path

    def state_now(self) -> str | None:
        if self.db_path is None or self.watch_application_id is None:
            return None
        c = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        try:
            row = c.execute("SELECT state FROM applications WHERE id = ?", (self.watch_application_id,)).fetchone()
            return row[0] if row else None
        finally:
            c.close()


def _parse_body(ctype: str, body: bytes) -> tuple[dict[str, list[str]], dict[str, tuple[str, bytes]]]:
    fields: dict[str, list[str]] = {}
    files: dict[str, tuple[str, bytes]] = {}
    if ctype.startswith("multipart/form-data"):
        msg = BytesParser(policy=HTTP).parsebytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            filename = part.get_filename()
            payload = part.get_payload(decode=True) or b""
            if filename is not None:
                if filename:
                    files[name] = (filename, payload)
            else:
                fields.setdefault(name, []).append(payload.decode("utf-8"))
    else:
        for k, v in parse_qs(body.decode("utf-8"), keep_blank_values=True).items():
            fields[k] = v
    return fields, files


def _handler(server_state: FixtureServer) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args: Any) -> None:  # quiet
            pass

        def _send(self, code: int, body: str, ctype: str = "text/html; charset=utf-8", headers: dict[str, str] | None = None) -> None:
            data = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:  # noqa: N802
            path = urlsplit(self.path).path
            if path in CONFIRM_PAGES:
                return self._send(200, CONFIRM_PAGES[path])
            m = re.fullmatch(r"/(greenhouse|lever|ashby|captcha|careers_page)(?:/.*)?", path)
            if m and (FIXTURES / f"{m.group(1)}.html").exists() and not path.endswith(("/submit", "/apply")):
                return self._send(200, (FIXTURES / f"{m.group(1)}.html").read_text(encoding="utf-8"))
            self._send(404, "not found")

        def do_POST(self) -> None:  # noqa: N802
            parts = urlsplit(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            fields, files = _parse_body(self.headers.get("Content-Type", ""), body)
            server_state.submissions.append(Submission(parts.path, fields, files, server_state.state_now()))
            if parts.path == "/greenhouse/submit":
                return self._send(303, "", headers={"Location": "/greenhouse/confirmation"})
            if parts.path == "/lever/apply":
                return self._send(303, "", headers={"Location": "/lever/thanks"})
            if parts.path == "/ashby/submit":
                if "fail=1" in parts.query:
                    return self._send(422, json.dumps({"success": False}), "application/json")
                return self._send(200, json.dumps({"success": True}), "application/json")
            self._send(404, "not found")

    return Handler


@pytest.fixture
def ats_server() -> Any:
    state = FixtureServer()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _handler(state))
    state.base_url = f"http://127.0.0.1:{httpd.server_address[1]}"
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    try:
        yield state
    finally:
        httpd.shutdown()
        httpd.server_close()


@pytest.fixture(autouse=True)
def _submit_only_to_localhost(monkeypatch: pytest.MonkeyPatch) -> None:
    """Belt and braces: adapters refuse to click submit anywhere but the local server."""
    monkeypatch.setenv("AUTOAPPLY_SUBMIT_ALLOWED_HOSTS", "127.0.0.1,localhost")


# =====================================================================================
# Seeding helpers
# =====================================================================================

PROFILE = {
    "full_name": "Ada Lovelace",
    "first_name": "Ada",
    "last_name": "Lovelace",
    "email": "ada@example.com",
    "phone": "+1 415 555 0100",
    "location": "San Francisco, CA",
    "headline": "Backend engineer",
    "links": {"linkedin": "https://linkedin.com/in/ada", "github": "https://github.com/ada"},
    "work_history": [{"company": "Analytical Engines", "title": "Senior Backend Engineer", "start": "2021", "end": None}],
    "skills": ["Go", "Python", "Postgres", "Kafka"],
    "years_experience": 7,
}


NEVER_GUESS = {"sponsorship": "Not required", "relocation": "no", "work_auth": {"US": "authorized"}}


@pytest.fixture
def profile(conn: sqlite3.Connection) -> Any:
    db.set_never_guess(conn, NEVER_GUESS)
    return db.update_profile(conn, PROFILE)


@pytest.fixture
def resume(conn: sqlite3.Connection, autoapply_home: Any) -> Any:
    path = autoapply_home.resumes / "ada_resume.pdf"
    path.write_bytes(b"%PDF-1.4\n% fixture resume for tests\n%%EOF\n")
    return db.add_resume_variant(conn, label="Backend", file_path=str(path), tags=["backend"], is_default=True)


def seed_job(
    conn: sqlite3.Connection,
    *,
    ats: Ats,
    apply_url: str,
    title: str = "Backend Engineer",
    company: str = "Acme Robotics",
    state: AppState = AppState.QUEUED,
    description: str = "Build Go services.",
    location: str | None = "Remote (US)",
) -> tuple[Any, Any]:
    c = db.upsert_company(conn, company)
    job, _ = db.insert_job(conn, company_id=c.id, source=JobSource.MANUAL, title=title, apply_url=apply_url, ats=ats,
                           description=description, location=location)
    app = db.get_application_by_job(conn, job.id)
    path = {
        AppState.DISCOVERED: [],
        AppState.SCORED: [AppState.SCORED],
        AppState.QUEUED: [AppState.SCORED, AppState.QUEUED],
    }[state]
    for s in path:
        db.transition(conn, app.id, s)
    return job, db.get_application(conn, app.id)


# =====================================================================================
# Scripted resolver (stands in for B's AnswerResolver; same duck-typed interface)
# =====================================================================================


@dataclass
class Resolved:
    question: FormQuestion
    answer: str
    origin: AnswerOrigin
    confidence: float | None = None
    origin_ref: str | None = None
    action: str | None = None
    never_guess_key: str | None = None


class ScriptedResolver:
    """``rules``: (label regex, response). Response: ``(answer, origin, confidence)``,
    ``"skip"``, or ``("needs", reason, never_guess_key)``. Unmatched: optional -> skip,
    required -> NeedsUser(unknown)."""

    def __init__(self, conn: sqlite3.Connection, rules: list[tuple[str, Any]]) -> None:
        self.conn = conn
        self.rules = [(re.compile(p, re.I), r) for p, r in rules]
        self.asked: list[str] = []

    async def resolve(self, q: FormQuestion) -> Resolved:
        self.asked.append(q.label)
        for pat, r in self.rules:
            if pat.search(q.label):
                if r == "skip":
                    return Resolved(q, "", AnswerOrigin.GENERATED, action="skip")
                if isinstance(r, tuple) and r and r[0] == "needs":
                    raise NeedsUser(q, r[1], never_guess_key=r[2] if len(r) > 2 else None)
                answer, origin, conf = r
                return Resolved(q, answer, AnswerOrigin(origin), conf, origin_ref=f"test:{origin}")
        if not q.required:
            return Resolved(q, "", AnswerOrigin.GENERATED, action="skip")
        raise NeedsUser(q, QuestionReason.UNKNOWN)

    def record(self, application_id: int, resolved: Resolved, *, answer_override: str | None = None) -> None:
        db.add_application_answer(
            self.conn, application_id, question=resolved.question.label, answer=answer_override or resolved.answer,
            origin=resolved.origin, field_type=resolved.question.field_type, confidence=resolved.confidence,
            field_key=resolved.question.key, origin_ref=resolved.origin_ref,
        )


class EventSink:
    def __init__(self) -> None:
        self.events: list[tuple[str, Any]] = []

    async def __call__(self, type_: str, payload: Any) -> None:
        self.events.append((type_, payload))

    def of(self, type_: str) -> list[Any]:
        return [p for t, p in self.events if t == type_]

from tests.legacy_auto_mode import _fresh_db_starts_in_auto  # noqa: E402,F401  (autouse: fresh DBs start in Auto)
