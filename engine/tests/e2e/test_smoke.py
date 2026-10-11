"""End-to-end smoke: autoapplyd over a real Unix socket, with the REAL pipeline and the real
workstream A/B/D code wired together. No network, no real LLM, no real submission.

* ``AUTOAPPLY_HOME`` is a temp dir; the LLM is a :class:`FakeLLMProvider` (scoring + answer
  generation scripted by prompt shape).
* Discovery runs the real :class:`GreenhouseSource` against mocked board JSON (respx; any
  un-mocked httpx request fails the test, so nothing leaves the machine).
* Applying runs the real scripted Greenhouse adapter in headless Chromium against the local
  fixture form (``tests/fixtures/ats/greenhouse.html``) served from 127.0.0.1. Submits are
  restricted to localhost via ``AUTOAPPLY_SUBMIT_ALLOWED_HOSTS``; the "submit" is a POST to the
  local fixture server ("fake mode").

Journey (PLAN.md milestones M2 + M3):

1. ``hello`` -> snapshot; onboarding-style config via socket commands.
2. ``run_now{full}``: discover 3 jobs -> score (one hard-filtered) -> prep -> apply.
   Acme fills cleanly and stops at ``awaiting_review`` (Review mode). Bolt has a question the
   agent can't answer confidently: it parks in ``needs_you`` and a ``question_opened`` arrives.
3. ``approve`` Acme -> ``submitting`` (committed before the POST) -> ``submitted``.
4. ``answer_question`` -> ``question_resolved`` + Bolt ``needs_you -> queued``.
5. ``run_now{apply}`` -> Bolt ``awaiting_review`` using the user's answer; ``approve`` ->
   ``submitted`` and the POSTed form carries the user's answer.
"""

from __future__ import annotations

import asyncio
import copy
import io
import json
import re
import shutil
import tempfile
import threading
from collections.abc import AsyncIterator, Callable
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Any

import httpx
import pytest
import respx

from autoapply import db
from autoapply.apply.base import close_all_sessions
from autoapply.apply.greenhouse import GreenhouseAdapter
from autoapply.daemon import Daemon
from autoapply.discovery.careers import add_to_watchlist
from autoapply.discovery.greenhouse import GreenhouseSource
from autoapply.enums import AppState, Ats
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import SystemCheckItem, SystemCheckResult, decode_line, make_command
from autoapply.paths import Paths
from autoapply.scheduler import Caffeinate
from tests.a_core.conftest import NEVER_GUESS, PROFILE, FixtureServer, _handler, load_json


FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "ats"
GH_API = "https://boards-api.greenhouse.io/v1/boards"
USER_WHY = "I want to build reliable robots at {company}."


# =====================================================================================
# Fixtures
# =====================================================================================


@pytest.fixture
def ats_server() -> Any:
    state = FixtureServer()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _handler(state))
    state.base_url = f"http://127.0.0.1:{httpd.server_address[1]}"
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        yield state
    finally:
        httpd.shutdown()
        httpd.server_close()


@pytest.fixture
def sock_dir() -> Any:
    d = tempfile.mkdtemp(prefix="aae", dir="/tmp")  # AF_UNIX paths max out at 104 bytes on macOS
    yield Path(d)
    shutil.rmtree(d, ignore_errors=True)


@pytest.fixture(autouse=True)
def _localhost_only(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AUTOAPPLY_SUBMIT_ALLOWED_HOSTS", "127.0.0.1,localhost")
    monkeypatch.setenv("AUTOAPPLY_LLM_PROVIDER", "fake")  # belt and braces: never the Agent SDK


class LocalGreenhouseAdapter(GreenhouseAdapter):
    """The real scripted Greenhouse adapter, except the form is opened at the job's own
    (local fixture) URL instead of the hosted job-boards.greenhouse.io page."""

    def form_url(self, ctx: Any) -> str:  # type: ignore[override]
        url = ctx.job.apply_url or ""
        assert url.startswith("http://127.0.0.1"), f"refusing non-local form url {url!r}"
        return url


def board_json(base_url: str, token: str, company: str, jobs: list[tuple[int, str]]) -> dict[str, Any]:
    template = load_json("greenhouse_board.json")["jobs"][0]
    out = []
    for job_id, title in jobs:
        j = copy.deepcopy(template)
        j.update(id=job_id, title=title, company_name=company, absolute_url=f"{base_url}/greenhouse/{token}/{job_id}")
        out.append(j)
    return {"jobs": out, "meta": {"total": len(out)}}


def questions_json(job_id: int) -> dict[str, Any]:
    q = load_json("greenhouse_job_questions.json")
    q["id"] = job_id
    return q


def fake_llm() -> FakeLLMProvider:
    """Scoring: echo every job with score 90. Generation: confident for Acme's role, not for
    Bolt's "why us" (so it parks). Anything else: a plain grounded text answer."""

    def respond(prompt: str, system: str | None, schema: dict[str, Any] | None) -> Any:
        if schema and "results" in (schema.get("properties") or {}) and "jobs:\n" in prompt:
            jobs = json.loads(prompt[prompt.index("jobs:\n") + 6:])
            return {"results": [{"job_id": j["job_id"], "score": 90, "summary": "strong fit",
                                 "factors": {"skills": 90, "seniority": 90, "role": 90, "domain": 90}, "concerns": []}
                                for j in jobs]}
        if prompt.startswith("GENERATE ANSWER"):
            if "How did you hear" in prompt:
                return {"answer": "Company website", "confidence": 0.95, "grounded": True, "story_ids": []}
            if "Why do you want" in prompt and "Role: Platform Engineer" in prompt:
                return {"answer": "Not sure.", "confidence": 0.3, "grounded": False, "story_ids": []}
            return {"answer": "I have built Go and Kafka systems and want to apply that to warehouse robots.",
                    "confidence": 0.9, "grounded": True, "story_ids": []}
        if schema is not None:
            props = schema.get("properties") or {}
            # Generic structured fallback (classifiers / checks): conservative "no".
            return {k: (False if v.get("type") == "boolean" else "" if v.get("type") == "string" else
                        0 if v.get("type") in ("number", "integer") else [] if v.get("type") == "array" else {})
                    for k, v in props.items()}
        return "OK"

    return FakeLLMProvider(default=respond)


def minimal_pdf() -> bytes:
    from pypdf import PdfWriter

    w = PdfWriter()
    w.add_blank_page(width=612, height=792)
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


# =====================================================================================
# Socket client
# =====================================================================================


class Client:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader, self.writer = reader, writer
        self.events: list[dict[str, Any]] = []

    @classmethod
    async def open(cls, path: Path) -> "Client":
        r, w = await asyncio.open_unix_connection(str(path), limit=16 * 1024 * 1024)
        return cls(r, w)

    async def recv(self, timeout: float) -> dict[str, Any]:
        line = await asyncio.wait_for(self.reader.readline(), timeout)
        assert line, "daemon closed the connection"
        decode_line(line, expect="event")  # every message is a valid protocol event
        msg = json.loads(line)
        self.events.append(msg)
        return msg

    async def until(self, pred: Callable[[dict[str, Any]], bool], timeout: float = 30.0) -> dict[str, Any]:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            left = deadline - loop.time()
            if left <= 0:
                tail = [(m["type"], m.get("payload")) for m in self.events[-15:]]
                raise AssertionError(f"timed out waiting for event; last events: {tail}")
            msg = await self.recv(left)
            if pred(msg):
                return msg

    async def request(self, type_: str, payload: dict[str, Any] | None = None, timeout: float = 30.0) -> dict[str, Any]:
        env = make_command(type_, payload or {})
        self.writer.write(env.to_line().encode())
        await self.writer.drain()
        reply = await self.until(lambda m: m.get("reply_to") == env.id, timeout)
        assert reply["type"] in ("ack", "snapshot"), f"{type_} failed: {reply}"
        return reply

    def of(self, type_: str) -> list[dict[str, Any]]:
        return [m["payload"] for m in self.events if m["type"] == type_]

    def transitions(self, application_id: int) -> list[str]:
        return [p["to_state"] for p in self.of("application_state") if p["application_id"] == application_id]

    async def close(self) -> None:
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except Exception:  # noqa: BLE001
            pass


def state_is(app_id: int, state: str) -> Callable[[dict[str, Any]], bool]:
    return lambda m: m["type"] == "application_state" and m["payload"]["application_id"] == app_id \
        and m["payload"]["to_state"] == state


# =====================================================================================
# The journey
# =====================================================================================


@pytest.fixture
async def daemon(autoapply_home: Paths, sock_dir: Path, ats_server: FixtureServer) -> AsyncIterator[Daemon]:
    conn = db.open_db(autoapply_home.db)
    # The watchlist has no socket command yet (CLI: `autoapply watch add`); seed it before start.
    add_to_watchlist(conn, "Acme Robotics", "acme", ats=Ats.GREENHOUSE)
    add_to_watchlist(conn, "Bolt Labs", "bolt", ats=Ats.GREENHOUSE)
    conn.close()
    d = Daemon(
        autoapply_home, llm=fake_llm(), sources=[GreenhouseSource()], adapters=[LocalGreenhouseAdapter()],
        socket_path=sock_dir / "d.sock", enable_scheduler=False, enable_maintenance=False,
        caffeinate_factory=lambda: Caffeinate([]),
        system_check=lambda: SystemCheckResult(items=[SystemCheckItem(name="autoapplyd", ok=True)], all_required_ok=True),
        chrome_launcher=lambda profile, url: None,
    )
    await d.start()
    try:
        yield d
    finally:
        await d.stop()
        await close_all_sessions()


@pytest.fixture
def boards(ats_server: FixtureServer) -> Any:
    with respx.mock(assert_all_called=False, assert_all_mocked=True) as router:
        router.get(url__regex=rf"{re.escape(GH_API)}/acme/jobs(\?.*)?$").respond(
            json=board_json(ats_server.base_url, "acme", "Acme Robotics", [(5001, "Backend Engineer")]))
        router.get(url__regex=rf"{re.escape(GH_API)}/bolt/jobs(\?.*)?$").respond(
            json=board_json(ats_server.base_url, "bolt", "Bolt Labs",
                            [(6001, "Platform Engineer"), (6002, "Crypto Backend Engineer")]))
        for jid in (5001, 6001, 6002):
            router.get(url__regex=rf"{re.escape(GH_API)}/(acme|bolt)/jobs/{jid}(\?.*)?$").respond(json=questions_json(jid))
        yield router


async def test_full_journey_over_socket(daemon: Daemon, boards: Any, ats_server: FixtureServer,
                                        autoapply_home: Paths) -> None:
    c = await Client.open(daemon.socket_path)
    try:
        await _journey(c, daemon, ats_server, autoapply_home)
    finally:
        await c.close()


async def _journey(c: Client, daemon: Daemon, ats_server: FixtureServer, home: Paths) -> None:
    # ---- 1. connect + configure (what onboarding does) --------------------------------------
    snap = await c.request("hello", {"client": "test", "protocol_version": 1})
    assert snap["type"] == "snapshot" and snap["payload"]["state"]["daemon"] == "idle"

    await c.request("update_profile", {"profile": PROFILE})
    await c.request("update_never_guess", {"values": NEVER_GUESS})
    prefs = await c.request("update_preferences", {"preferences": {
        "mode": "review", "roles": ["Backend Engineer", "Platform Engineer"], "exclude_keywords": ["crypto"],
        "match_threshold": 70,
    }})
    assert prefs["payload"]["result"]["preferences"]["mode"] == "review"
    pdf = home.home / "ada.pdf"
    pdf.write_bytes(minimal_pdf())
    added = await c.request("add_resume_variant", {"file_path": str(pdf), "label": "Backend", "tags": ["backend"],
                                                   "is_default": True})
    assert added["payload"]["result"]["resume_variant_id"]

    # ---- 2. full run: discover -> score -> prep -> apply -------------------------------------
    ack = await c.request("run_now", {"kind": "full"})
    run_id = ack["payload"]["result"]["run_id"]
    finished = await c.until(lambda m: m["type"] == "run_finished", timeout=150)
    assert finished["payload"]["run"]["run_id"] == run_id, finished
    assert finished["payload"]["run"]["outcome"] == "completed", finished

    discovered = {p["job"]["title"]: p["job"] for p in c.of("job_discovered")}
    assert set(discovered) == {"Backend Engineer", "Platform Engineer", "Crypto Backend Engineer"}

    conn = db.open_db(home.db)
    try:
        apps = {t: db.get_application_by_job(conn, j["id"]) for t, j in discovered.items()}
        acme, bolt, crypto = apps["Backend Engineer"], apps["Platform Engineer"], apps["Crypto Backend Engineer"]

        assert crypto.state is AppState.SKIPPED and (crypto.state_reason or "").startswith("excluded_keyword"), crypto
        scored = {p["job_id"]: p for p in c.of("job_scored")}
        assert scored[discovered["Backend Engineer"]["id"]]["score"] == 90

        open_q = [(cl.canonical_question, cl.reason.value, cl.job_ids) for cl in db.list_open_clusters(conn)]
        assert acme.state is AppState.AWAITING_REVIEW, (acme.state_reason, c.transitions(acme.id), open_q)
        assert "filling" in c.transitions(acme.id) and c.transitions(acme.id)[-1] == "awaiting_review"
        assert bolt.state is AppState.NEEDS_YOU, (bolt, c.transitions(bolt.id))
        assert ats_server.submissions == [], "Review mode: nothing may be sent before approval"

        opened = [p["cluster"] for p in c.of("question_opened") if discovered["Platform Engineer"]["id"] in p["cluster"]["job_ids"]]
        assert opened, c.of("question_opened")
        why = next(cl for cl in opened if "why do you want" in cl["canonical_question"].lower())
        assert why["reason"] == "low_confidence"

        # ---- 3. approve Acme -> submitting (durable) -> submitted ---------------------------
        ats_server.db_path, ats_server.watch_application_id = home.db, acme.id
        await c.request("approve", {"application_ids": [acme.id]})
        await c.until(state_is(acme.id, "submitted"), timeout=90)
        assert c.transitions(acme.id)[-2:] == ["submitting", "submitted"]
        [sub] = ats_server.submissions
        assert sub.path == "/greenhouse/submit"
        assert sub.app_state_at_post == "submitting", "submitting must be committed before the click"
        assert sub.fields["first_name"] == ["Ada"] and sub.fields["question_1003"] == ["0"]
        assert db.get_application(conn, acme.id).state is AppState.SUBMITTED

        # ---- 4. answer the parked question -> Bolt re-queued --------------------------------
        reply = await c.request("answer_question", {"cluster_id": why["cluster_id"], "answer": USER_WHY,
                                                    "save_to_memory": True})
        assert bolt.id in reply["payload"]["result"]["resumed_application_ids"]
        await c.until(state_is(bolt.id, "queued"))
        assert any(p["cluster_id"] == why["cluster_id"] and p["status"] == "answered" for p in c.of("question_resolved"))
        assert db.get_application(conn, bolt.id).state is AppState.QUEUED

        # ---- 5. apply run -> Bolt awaiting review with the user's answer -> approve ----------
        await c.request("run_now", {"kind": "apply"})
        await c.until(lambda m: m["type"] == "run_finished", timeout=120)
        assert db.get_application(conn, bolt.id).state is AppState.AWAITING_REVIEW, c.transitions(bolt.id)
        answers = {a.field_key: a for a in db.list_application_answers(conn, bolt.id)}
        assert answers["question_1002"].answer == "I want to build reliable robots at Bolt Labs."

        ats_server.watch_application_id = bolt.id
        await c.request("approve", {"application_ids": [bolt.id]})
        await c.until(state_is(bolt.id, "submitted"), timeout=90)
        assert len(ats_server.submissions) == 2
        last = ats_server.submissions[-1]
        assert last.app_state_at_post == "submitting"
        assert last.fields["question_1002"] == ["I want to build reliable robots at Bolt Labs."]

        # Board status + cap accounting are visible to a fresh client.
        c2 = await Client.open(daemon.socket_path)
        try:
            snap2 = await c2.request("hello", {"client": "test", "protocol_version": 1})
            assert snap2["payload"]["caps"]["daily_used"] == 2
        finally:
            await c2.close()
    finally:
        conn.close()


async def test_respx_blocks_unmocked_network(boards: Any) -> None:
    """Guard for the smoke test itself: an un-mocked host raises instead of going out."""
    async with httpx.AsyncClient() as client:
        with pytest.raises(Exception):  # noqa: B017 - respx raises AllMockedAssertionError
            await client.get("https://example.com/")


# =====================================================================================
# The real autoapplyd process (entry point, socket permissions, graceful shutdown)
# =====================================================================================


async def test_autoapplyd_process_lifecycle() -> None:
    """Spawn ``python -m autoapply.daemon`` (what the LaunchAgent runs) on a temp home with the
    fake LLM; talk to it over its socket; SIGTERM shuts it down and removes the socket. No run
    is started, so nothing can reach the network or a browser."""
    import os
    import signal
    import stat
    import sys

    home = Path(tempfile.mkdtemp(prefix="aap", dir="/tmp"))
    env = {**os.environ, "AUTOAPPLY_HOME": str(home), "AUTOAPPLY_LLM_PROVIDER": "fake"}
    proc = await asyncio.create_subprocess_exec(
        sys.executable, "-m", "autoapply.daemon", "--home", str(home), "--no-scheduler",
        env=env, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
    )
    sock = home / "autoapplyd.sock"
    try:
        for _ in range(200):
            if sock.exists():
                break
            if proc.returncode is not None:
                raise AssertionError(f"autoapplyd exited early: {(await proc.stderr.read()).decode()[-2000:]}")  # type: ignore[union-attr]
            await asyncio.sleep(0.05)
        assert sock.exists(), "socket never appeared"
        assert stat.S_IMODE(os.stat(sock).st_mode) == 0o600
        c = await Client.open(sock)
        try:
            snap = await c.request("hello", {"client": "test", "protocol_version": 1})
            assert snap["payload"]["onboarding"]["completed"] is False
            await c.request("ping")
            prefs = await c.request("update_preferences", {"preferences": {"daily_cap": 5}})
            assert prefs["payload"]["result"]["preferences"]["daily_cap"] == 5
            await c.request("pause_all")
            await c.until(lambda m: m["type"] == "state" and m["payload"]["paused"] is True)
            await c.request("resume")
        finally:
            await c.close()
        proc.send_signal(signal.SIGTERM)
        assert await asyncio.wait_for(proc.wait(), 15) == 0
        assert not sock.exists(), "socket removed on shutdown"
    finally:
        if proc.returncode is None:
            proc.kill()
            await proc.wait()
        shutil.rmtree(home, ignore_errors=True)
