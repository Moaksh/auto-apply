"""autoapplyd over a real Unix socket: hello/snapshot, commands, broadcast, malformed input."""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sqlite3
import stat
import tempfile
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest

from autoapply import db
from autoapply.daemon import Daemon, DaemonAlreadyRunning, heuristic_profile, main as daemon_main
from autoapply.enums import AppState, Ats, RunKind
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import (
    COMMAND_PAYLOADS,
    SystemCheckItem,
    SystemCheckResult,
    decode_line,
    make_command,
)
from autoapply.paths import Paths
from autoapply.scheduler import Caffeinate

from .fakes import FakeAdapter, FakeSource, fake_hooks, gh_job


class Conn:
    """A protocol client over the Unix socket."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader, self.writer = reader, writer

    @classmethod
    async def open(cls, path: Path) -> "Conn":
        r, w = await asyncio.open_unix_connection(str(path), limit=16 * 1024 * 1024)
        return cls(r, w)

    async def send_raw(self, data: bytes) -> None:
        self.writer.write(data)
        await self.writer.drain()

    async def send(self, type_: str, payload: dict[str, Any] | None = None, *, id: str | None = None) -> str:
        env = make_command(type_, payload or {}, id=id)
        await self.send_raw(env.to_line().encode())
        return env.id

    async def recv(self, timeout: float = 3.0) -> dict[str, Any]:
        line = await asyncio.wait_for(self.reader.readline(), timeout)
        assert line, "connection closed"
        decode_line(line, expect="event")  # every daemon message is a valid protocol event
        return json.loads(line)

    async def recv_until(self, pred: Any, timeout: float = 3.0) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        seen: list[dict[str, Any]] = []
        while True:
            msg = await self.recv(timeout)
            seen.append(msg)
            if pred(msg):
                return msg, seen

    async def request(self, type_: str, payload: dict[str, Any] | None = None) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        cid = await self.send(type_, payload)
        return await self.recv_until(lambda m: m.get("reply_to") == cid)

    async def close(self) -> None:
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except Exception:  # noqa: BLE001
            pass


@pytest.fixture
def sock_dir() -> Any:
    # AF_UNIX paths are limited to 104 bytes on macOS; pytest tmp dirs are too long.
    d = tempfile.mkdtemp(prefix="aad", dir="/tmp")
    yield Path(d)
    shutil.rmtree(d, ignore_errors=True)


def build_daemon(paths: Paths, sock: Path, conn: sqlite3.Connection | None = None, **kw: Any) -> Daemon:
    adapter = kw.pop("adapter", None)
    hooks, _ = fake_hooks()
    defaults: dict[str, Any] = dict(
        llm=FakeLLMProvider(default="ok"), sources=kw.pop("sources", []), adapters=[adapter] if adapter else [],
        hooks=hooks, socket_path=sock, enable_scheduler=False, enable_maintenance=False,
        caffeinate_factory=lambda: Caffeinate([]),
        system_check=lambda: SystemCheckResult(items=[SystemCheckItem(name="autoapplyd", ok=True)], all_required_ok=True),
        chrome_launcher=lambda profile, url: None,
    )
    defaults.update(kw)
    return Daemon(paths, conn=conn, **defaults)


@pytest.fixture
async def daemon(autoapply_home: Paths, sock_dir: Path) -> AsyncIterator[Daemon]:
    d = build_daemon(autoapply_home, sock_dir / "d.sock")
    await d.start()
    try:
        yield d
    finally:
        await d.stop()


async def client(d: Daemon) -> Conn:
    return await Conn.open(d.socket_path)


# ---- transport ----------------------------------------------------------------------


async def test_hello_snapshot_round_trip(daemon: Daemon) -> None:
    c = await client(daemon)
    cid = await c.send("hello", {"client": "test", "protocol_version": 1})
    msg = await c.recv()
    assert msg["type"] == "snapshot" and msg["reply_to"] == cid
    snap = msg["payload"]
    assert snap["protocol_version"] == 1 and snap["daemon_version"]
    assert snap["state"] == {"daemon": "idle", "paused": False, "run_id": None, "progress": None, "message": None,
                             "active_application_id": None, "active_job_id": None}
    assert snap["mode"] == "auto" and snap["preferences"]["daily_cap"] == 15
    assert snap["caps"]["daily_limit"] == 15 and snap["caps"]["linkedin_sessions_limit"] == 3
    assert {s["source"] for s in snap["sources"]} == {"linkedin", "glassdoor", "greenhouse", "lever", "ashby", "careers"}
    assert snap["onboarding"] == {"completed": False, "step": 0}
    await c.close()


async def test_socket_permissions_and_lock(daemon: Daemon, autoapply_home: Paths, sock_dir: Path) -> None:
    mode = stat.S_IMODE(os.stat(daemon.socket_path).st_mode)
    assert mode == 0o600
    other = build_daemon(autoapply_home, sock_dir / "other.sock")
    with pytest.raises(DaemonAlreadyRunning):
        await other.start()
    assert not (sock_dir / "other.sock").exists()


async def test_ping_and_ack_shape(daemon: Daemon) -> None:
    c = await client(daemon)
    cid = await c.send("ping")
    msg = await c.recv()
    assert msg == {"v": 1, "id": msg["id"], "type": "ack", "reply_to": cid, "payload": {"ok": True, "result": None}}
    await c.close()


async def test_malformed_input(daemon: Daemon) -> None:
    c = await client(daemon)
    await c.send_raw(b"this is not json\n")
    m = await c.recv()
    assert m["type"] == "error" and m["payload"]["code"] == "bad_request" and "reply_to" not in m
    await c.send_raw(b'{"v":2,"id":"x1","type":"ping","payload":{}}\n')
    m = await c.recv()
    assert m["payload"]["code"] == "unsupported_version" and m["reply_to"] == "x1"
    await c.send_raw(b'{"v":1,"id":"x2","type":"launch_rockets","payload":{}}\n')
    m = await c.recv()
    assert m["payload"]["code"] == "unknown_type" and m["reply_to"] == "x2"
    await c.send_raw(b'{"v":1,"id":"x3","type":"snapshot","payload":{}}\n')  # an event type as command
    assert (await c.recv())["payload"]["code"] == "unknown_type"
    await c.send_raw(b'{"v":1,"id":"x4","type":"approve","payload":{"application_ids":[]}}\n')
    m = await c.recv()
    assert m["payload"]["code"] == "invalid_payload" and m["payload"]["details"]["errors"]
    await c.send_raw(b'{"v":1,"id":"x5","type":"ping","payload":{"extra":1}}\n')
    assert (await c.recv())["payload"]["code"] == "invalid_payload"
    await c.send_raw(b'[1,2,3]\n\n')
    assert (await c.recv())["payload"]["code"] == "bad_request"
    # connection is still usable afterwards
    _, _ = await c.request("ping")
    await c.close()


async def test_oversized_line_is_rejected_but_connection_survives(daemon: Daemon) -> None:
    c = await client(daemon)
    await c.send_raw(b'{"v":1,"id":"big","type":"ping","payload":{"x":"' + b"a" * (8 * 1024 * 1024 + 10) + b'"}}\n')
    m = await c.recv(timeout=10)
    assert m["type"] == "error" and m["payload"]["code"] == "bad_request"
    reply, _ = await c.request("ping")
    assert reply["type"] == "ack"
    await c.close()


async def test_broadcast_to_two_clients_after_reply(daemon: Daemon) -> None:
    a, b = await client(daemon), await client(daemon)
    await a.request("hello", {"client": "app"})
    await b.request("hello", {"client": "cli"})
    cid = await a.send("pause_all")
    first = await a.recv()
    assert first["type"] == "ack" and first["reply_to"] == cid  # reply precedes side effects
    st_a = await a.recv()
    st_b = await b.recv()
    for st in (st_a, st_b):
        assert st["type"] == "state" and st["payload"]["paused"] is True and "reply_to" not in st
    # paused persists and blocks run_now
    reply, _ = await b.request("run_now", {"kind": "full"})
    assert reply["type"] == "error" and reply["payload"]["code"] == "paused"
    reply, _ = await b.request("hello", {})
    assert reply["payload"]["state"]["paused"] is True
    await a.request("resume")
    st = await b.recv()
    assert st["type"] == "state" and st["payload"]["paused"] is False
    await a.close()
    await b.close()


async def test_client_disconnect_is_harmless(daemon: Daemon) -> None:
    a = await client(daemon)
    await a.request("hello")
    await a.close()
    await asyncio.sleep(0.05)
    b = await client(daemon)
    reply, _ = await b.request("pause_all")
    assert reply["type"] == "ack"
    await b.close()


async def test_every_command_has_a_handler(daemon: Daemon) -> None:
    for name in COMMAND_PAYLOADS:
        assert hasattr(daemon, f"_cmd_{name}"), name


# ---- commands with side effects ------------------------------------------------------


def _seed_app(conn: sqlite3.Connection, state_path: list[AppState], company: str = "Stripe", title: str = "SWE") -> int:
    co = db.upsert_company(conn, company)
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title=title, apply_url=f"https://boards.greenhouse.io/{company.lower()}/jobs/{title}", ats=Ats.GREENHOUSE)
    app = db.get_application_by_job(conn, job.id)
    for s in state_path:
        db.transition(conn, app.id, s)
    return app.id


async def test_run_now_conflict_and_run_events(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    adapter = FakeAdapter(conn)
    gate = asyncio.Event()
    src = FakeSource([gh_job("Stripe", "Backend Engineer", 1)])
    orig = src.discover

    async def slow_discover(ctx: Any) -> Any:
        await gate.wait()
        return await orig(ctx)

    src.discover = slow_discover  # type: ignore[method-assign]
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter, sources=[src])
    await d.start()
    try:
        c = await client(d)
        await c.request("hello")
        reply, _ = await c.request("run_now", {"kind": "full"})
        assert reply["type"] == "ack" and reply["payload"]["result"]["run_id"]
        run_id = reply["payload"]["result"]["run_id"]
        started = await c.recv()
        assert started["type"] == "run_started" and started["payload"]["run"]["run_id"] == run_id
        reply2, _ = await c.request("run_now", {})
        assert reply2["type"] == "error" and reply2["payload"]["code"] == "conflict"
        snap, _ = await c.request("hello")
        assert snap["payload"]["current_run"]["run_id"] == run_id
        gate.set()
        finished, seen = await c.recv_until(lambda m: m["type"] == "run_finished", timeout=5)
        types = [m["type"] for m in seen]
        assert "job_discovered" in types and "job_scored" in types and "application_state" in types
        assert finished["payload"]["run"]["outcome"] == "completed"
        assert finished["payload"]["run"]["stats"]["submitted"] == 1
        assert adapter.submitted
        await c.close()
    finally:
        await d.stop()
    assert d.lock.held is False


async def test_approve_submits_in_background(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    adapter = FakeAdapter(conn)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    try:
        app_id = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.AWAITING_REVIEW])
        c = await client(d)
        reply, _ = await c.request("approve", {"application_ids": [app_id]})
        assert reply["type"] == "ack" and reply["payload"]["result"] == {"application_ids": [app_id]}
        ev = await c.recv()
        assert ev["type"] == "application_state" and ev["payload"]["to_state"] == "submitting" and ev["payload"]["actor"] == "user"
        done, _ = await c.recv_until(lambda m: m["type"] == "application_state" and m["payload"]["to_state"] == "submitted")
        assert db.get_application(conn, app_id).state is AppState.SUBMITTED
        assert adapter.state_at_submit == [AppState.SUBMITTING] and adapter.approved_flags == [True]
        # approving again is an illegal transition
        reply, _ = await c.request("approve", {"application_ids": [app_id]})
        assert reply["payload"]["code"] == "illegal_transition" and reply["payload"]["application_id"] == app_id
        await c.close()
    finally:
        await d.stop()


async def test_approve_respects_daily_cap(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=FakeAdapter(conn))
    await d.start()
    try:
        db.update_preferences(conn, {"daily_cap": 1})
        a1 = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.AWAITING_REVIEW], "A", "x")
        a2 = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.AWAITING_REVIEW], "B", "y")
        c = await client(d)
        reply, seen = await c.request("approve", {"application_ids": [a1, a2]})
        assert reply["type"] == "error" and reply["payload"]["code"] == "cap_reached"
        assert reply["payload"]["application_id"] == a2
        cap, _ = await c.recv_until(lambda m: m["type"] == "cap_reached")
        assert cap["payload"]["cap"] == "daily"
        # nothing changed: all-or-nothing
        assert {db.get_application(conn, a).state for a in (a1, a2)} == {AppState.AWAITING_REVIEW}
        await c.close()
    finally:
        await d.stop()


async def test_reject_retry_resolve_unknown_and_status(daemon: Daemon) -> None:
    conn = daemon.conn
    rev = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.AWAITING_REVIEW], "A", "r")
    unk = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.SUBMITTING, AppState.UNKNOWN_VERIFY], "B", "u")
    fail = _seed_app(conn, [AppState.FAILED], "C", "f")
    c = await client(daemon)
    reply, _ = await c.request("reject", {"application_id": rev, "reason": "not a fit"})
    assert reply["type"] == "ack"
    ev = await c.recv()
    assert ev["payload"]["to_state"] == "skipped" and ev["payload"]["actor"] == "user" and ev["payload"]["reason"] == "not a fit"
    reply, _ = await c.request("resolve_unknown", {"application_id": unk, "submitted": True})
    assert reply["type"] == "ack" and db.get_application(conn, unk).state is AppState.SUBMITTED
    await c.recv()
    reply, _ = await c.request("retry_application", {"application_id": fail})
    assert reply["type"] == "ack" and db.get_application(conn, fail).state is AppState.QUEUED
    await c.recv()
    reply, _ = await c.request("set_status", {"application_id": unk, "status": "interview"})
    assert reply["type"] == "ack"
    st = await c.recv()
    assert st["type"] == "application_status" and st["payload"]["previous_status"] == "applied" and st["payload"]["status"] == "interview"
    reply, _ = await c.request("set_status", {"application_id": fail, "status": "interview"})
    assert reply["payload"]["code"] == "illegal_transition"
    reply, _ = await c.request("reject", {"application_id": 9999, "reason": "x"})
    assert reply["payload"]["code"] == "not_found"
    await c.close()


async def test_answer_question_resumes_parked_jobs(daemon: Daemon) -> None:
    conn = daemon.conn
    a1 = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.PREPPING, AppState.NEEDS_YOU], "A", "one")
    a2 = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.PREPPING, AppState.NEEDS_YOU], "B", "two")
    j1, j2 = db.get_application(conn, a1).job_id, db.get_application(conn, a2).job_id
    q, _ = db.add_question(conn, canonical_question="Why us?", job_id=j1)
    db.add_question(conn, canonical_question="Why us?", job_id=j2)
    db.add_question(conn, canonical_question="Notice period?", job_id=j2, never_guess_key="notice_period")
    c = await client(daemon)
    reply, _ = await c.request("answer_question", {"cluster_id": q.cluster_id, "answer": "I love {company}", "save_to_memory": True})
    assert reply["type"] == "ack"
    res = reply["payload"]["result"]
    assert res["resumed_application_ids"] == [a1] and res["answer_id"]
    msgs = [await c.recv(), await c.recv()]
    # protocol.md §5: question_resolved first, then application_state (needs_you -> queued)
    assert msgs[0]["type"] == "question_resolved" and msgs[0]["payload"]["resumed_application_ids"] == [a1]
    assert msgs[1]["type"] == "application_state" and msgs[1]["payload"]["to_state"] == "queued"
    assert db.get_answer(conn, res["answer_id"]).is_template
    assert db.get_application(conn, a2).state is AppState.NEEDS_YOU  # still blocked by notice period
    # never-guess cluster saved to profile
    ng_cluster = db.list_open_clusters(conn)[0]
    reply, _ = await c.request("answer_question", {"cluster_id": ng_cluster.cluster_id, "answer": "60 days", "save_to_profile": True})
    assert reply["payload"]["result"]["resumed_application_ids"] == [a2] and reply["payload"]["result"]["answer_id"] is None
    assert db.get_never_guess(conn).notice_period == "60 days"
    reply, _ = await c.request("answer_question", {"cluster_id": ng_cluster.cluster_id, "answer": "x"})
    assert reply["payload"]["code"] == "not_found"
    await c.close()


async def test_skip_question_skips_jobs(daemon: Daemon) -> None:
    conn = daemon.conn
    a1 = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.PREPPING, AppState.NEEDS_YOU], "A", "one")
    q, _ = db.add_question(conn, canonical_question="Security clearance?", job_id=db.get_application(conn, a1).job_id)
    c = await client(daemon)
    reply, _ = await c.request("skip_question", {"cluster_id": q.cluster_id, "reason": "no clearance"})
    assert reply["payload"]["result"] == {"skipped_application_ids": [a1]}
    assert db.get_application(conn, a1).state is AppState.SKIPPED
    await c.close()


async def test_preferences_profile_never_guess_and_validation(daemon: Daemon) -> None:
    c = await client(daemon)
    reply, _ = await c.request("update_preferences", {"preferences": {"daily_cap": 5, "schedule": ["08:00", "20:00"]}})
    assert reply["payload"]["result"]["preferences"]["daily_cap"] == 5
    assert daemon.scheduler is not None and daemon.scheduler.schedule == ["08:00", "20:00"]
    reply, _ = await c.request("update_preferences", {"preferences": {"daily_cap": None}})
    assert reply["payload"]["code"] == "invalid_payload"
    reply, _ = await c.request("update_preferences", {"preferences": {"match_threshold": 50}})
    assert reply["payload"]["result"]["preferences"]["daily_cap"] == 5  # untouched keys kept
    await c.send_raw(b'{"v":1,"id":"bad","type":"update_preferences","payload":{"preferences":{"schedule":["25:00"]}}}\n')
    assert (await c.recv())["payload"]["code"] == "invalid_payload"
    reply, _ = await c.request("update_never_guess", {"values": {"sponsorship": "Not required", "relocation": "yes"}})
    assert reply["payload"]["result"]["never_guess"]["sponsorship"] == "Not required"
    reply, _ = await c.request("update_never_guess", {"values": {"sponsorship": None}})
    assert reply["payload"]["result"]["never_guess"]["sponsorship"] is None
    reply, _ = await c.request("update_profile", {"profile": {"full_name": "Ada Lovelace", "skills": ["python"]}})
    assert reply["payload"]["result"]["profile"]["full_name"] == "Ada Lovelace"
    reply, _ = await c.request("upsert_story", {"title": "Scaled payments", "result": "3x"})
    sid = reply["payload"]["result"]["story_id"]
    assert (await c.request("delete_story", {"id": sid}))[0]["type"] == "ack"
    assert (await c.request("delete_story", {"id": sid}))[0]["payload"]["code"] == "not_found"
    await c.close()


async def test_resume_and_onboarding_commands(daemon: Daemon, tmp_path: Path) -> None:
    resume = tmp_path / "Ada Resume.txt"
    resume.write_text("Ada Lovelace\nada@example.com\n+44 20 7946 0958\nlinkedin.com/in/ada\nEngineer at Analytical Engines\n")
    assert isinstance(daemon.llm, FakeLLMProvider)
    daemon.llm.add_rule("Extract the candidate", {
        "profile": {"full_name": "Ada Lovelace", "email": "ada@example.com", "skills": ["math"], "years_experience": 8, "headline": None},
        "uncertain_fields": ["years_experience"],
    })
    c = await client(daemon)
    reply, _ = await c.request("onboarding_parse_resume", {"file_path": str(resume)})
    res = reply["payload"]["result"]
    assert res["profile"]["full_name"] == "Ada Lovelace" and res["profile"]["skills"] == ["math"]
    assert res["uncertain_fields"] == ["years_experience"]
    v = db.get_resume_variant(daemon.conn, res["resume_variant_id"])
    assert v.is_default and Path(v.file_path).parent == daemon.paths.resumes and v.text and "Ada" in v.text
    reply, _ = await c.request("add_resume_variant", {"file_path": str(resume), "label": "Backend", "tags": ["go"]})
    vid = reply["payload"]["result"]["resume_variant_id"]
    assert (await c.request("update_resume_variant", {"id": vid, "enabled": False}))[0]["type"] == "ack"
    reply, _ = await c.request("add_resume_variant", {"file_path": "/nope/missing.pdf", "label": "x"})
    assert reply["payload"]["code"] == "not_found"
    reply, _ = await c.request("onboarding_system_check")
    assert reply["payload"]["result"]["all_required_ok"] is True
    assert (await c.request("onboarding_set_step", {"step": 3}))[0]["type"] == "ack"
    snap, _ = await c.request("hello")
    assert snap["payload"]["onboarding"] == {"completed": False, "step": 3}
    reply, _ = await c.request("onboarding_complete", {"run_prep": False})
    assert reply["payload"]["result"] == {"run_id": None}
    snap, _ = await c.request("hello")
    assert snap["payload"]["onboarding"] == {"completed": True, "step": 7}
    assert (await c.request("open_agent_chrome", {"url": "https://example.com"}))[0]["type"] == "ack"
    await c.close()


def test_heuristic_profile() -> None:
    patch, uncertain = heuristic_profile("Ada Lovelace\nada@example.com | +1 415 555 0100\ngithub.com/ada\n")
    assert patch["full_name"] == "Ada Lovelace" and patch["email"] == "ada@example.com"
    assert patch["phone"].startswith("+1") and patch["links"] == {"github": "https://github.com/ada"}
    assert "full_name" in uncertain and "work_history" in uncertain and "email" not in uncertain


async def test_easy_apply_commands(daemon: Daemon) -> None:
    conn = daemon.conn
    co = db.upsert_company(conn, "Razorpay")
    job, _ = db.insert_job(conn, company_id=co.id, source="linkedin", title="SDE", easy_apply=True, ats=Ats.LINKEDIN_EASY_APPLY,
                           source_url="https://www.linkedin.com/jobs/view/1/")
    db.upsert_easy_apply(conn, job.id, url="https://www.linkedin.com/jobs/view/1/")
    c = await client(daemon)
    assert (await c.request("mark_easy_apply_opened", {"job_id": job.id}))[0]["type"] == "ack"
    reply, _ = await c.request("mark_easy_apply_done", {"job_id": job.id})
    app_id = reply["payload"]["result"]["application_id"]
    ev = await c.recv()
    assert ev["payload"] | {"at": None} == {"application_id": app_id, "job_id": job.id, "from_state": "discovered",
                                            "to_state": "submitted", "reason": "manual_easy_apply", "actor": "user", "at": None}
    app = db.get_application(conn, app_id)
    assert app.mode == "manual" and app.status.value == "applied"
    assert (await c.request("dismiss_easy_apply", {"job_id": 424242}))[0]["payload"]["code"] == "not_found"
    reply, _ = await c.request("set_job_mode", {"job_id": job.id, "mode": "review"})
    assert reply["type"] == "ack" and db.get_job(conn, job.id).mode_override == "review"
    await c.close()


async def test_connect_source_emits_status(autoapply_home: Paths, sock_dir: Path) -> None:
    class StubSource:
        async def connect(self) -> bool:
            return True

    d = build_daemon(autoapply_home, sock_dir / "d.sock", source_factory=lambda name: StubSource())
    await d.start()
    try:
        c = await client(d)
        reply, _ = await c.request("onboarding_connect_source", {"source": "linkedin"})
        assert reply["type"] == "ack"
        st, _ = await c.recv_until(lambda m: m["type"] == "source_status")
        assert st["payload"]["source"]["source"] == "linkedin" and st["payload"]["source"]["connected"] is True
        assert db.get_preferences(d.conn).sources_enabled["linkedin"] is True
        snap, _ = await c.request("hello")
        li = next(s for s in snap["payload"]["sources"] if s["source"] == "linkedin")
        assert li["connected"] is True and li["enabled"] is True
        await c.close()
    finally:
        await d.stop()


async def test_startup_recovery_broadcast_and_unknown_verify(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    sub = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.FILLING, AppState.SUBMITTING], "A", "s")
    fill = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.FILLING], "B", "f")
    db.start_run(conn, RunKind.FULL)
    conn.close()  # crash

    d = build_daemon(autoapply_home, sock_dir / "d.sock")
    await d.start()
    try:
        assert db.get_application(d.conn, sub).state is AppState.UNKNOWN_VERIFY
        assert db.get_application(d.conn, sub).state_reason == "crash_during_submit"
        assert db.get_application(d.conn, fill).state is AppState.QUEUED
        assert db.get_current_run(d.conn) is None
        c = await client(d)
        snap, _ = await c.request("hello")
        assert snap["payload"]["counts"]["unknown_verify"] == 1 and snap["payload"]["counts"]["queued"] == 1
        await c.close()
    finally:
        await d.stop()


async def test_handle_without_socket(autoapply_home: Paths) -> None:
    d = build_daemon(autoapply_home, Path("/tmp/unused.sock"))
    replies = await d.handle(make_command("ping", {}))
    assert [r.type for r in replies] == ["ack"]
    replies = await d.handle(make_command("hello", {}))
    assert replies[0].type == "snapshot" and replies[0].reply_to
    snap = d.build_snapshot()
    assert snap.state.daemon.value == "idle"
    await d.stop()


async def test_stop_cleans_up(autoapply_home: Paths, sock_dir: Path) -> None:
    d = build_daemon(autoapply_home, sock_dir / "d.sock")
    await d.start()
    c = await client(d)
    await c.request("hello")
    await d.stop()
    assert not (sock_dir / "d.sock").exists() and not d.lock.held
    assert await c.reader.read() == b""  # server closed the connection
    # can start again after a clean stop
    d2 = build_daemon(autoapply_home, sock_dir / "d.sock")
    await d2.start()
    await d2.stop()


def test_main_exits_cleanly_when_already_running(autoapply_home: Paths) -> None:
    from autoapply.daemon import InstanceLock, LOCK_FILENAME

    lock = InstanceLock(autoapply_home.home / LOCK_FILENAME)
    lock.acquire()
    try:
        daemon_main(["--home", str(autoapply_home.home), "--no-scheduler"])  # returns, doesn't raise
    finally:
        lock.release()
        import logging

        root = logging.getLogger("autoapply")
        for h in list(root.handlers):
            root.removeHandler(h)
            h.close()
    log_line = (autoapply_home.daemon_log).read_text().strip().splitlines()[-1]
    assert json.loads(log_line)["msg"].endswith("exiting")


async def test_answer_and_skip_fallback_without_prep(daemon: Daemon, monkeypatch: pytest.MonkeyPatch) -> None:
    """While B's prep.answer_cluster/skip_cluster are unavailable the daemon still works."""
    from autoapply import prep

    def nie(*a: Any, **k: Any) -> Any:
        raise NotImplementedError

    monkeypatch.setattr(prep, "answer_cluster", nie)
    monkeypatch.setattr(prep, "skip_cluster", nie)
    conn = daemon.conn
    a1 = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.PREPPING, AppState.NEEDS_YOU], "A", "one")
    a2 = _seed_app(conn, [AppState.SCORED, AppState.QUEUED, AppState.PREPPING, AppState.NEEDS_YOU], "B", "two")
    q1, _ = db.add_question(conn, canonical_question="Why us?", job_id=db.get_application(conn, a1).job_id)
    q2, _ = db.add_question(conn, canonical_question="Clearance?", job_id=db.get_application(conn, a2).job_id)
    c = await client(daemon)
    reply, _ = await c.request("answer_question", {"cluster_id": q1.cluster_id, "answer": "Mission", "save_to_memory": False,
                                                   "per_job_answers": [{"job_id": db.get_application(conn, a1).job_id, "answer": "Because A"}]})
    assert reply["payload"]["result"] == {"answer_id": None, "resumed_application_ids": [a1]}
    assert [x.answer for x in db.list_application_answers(conn, a1)] == ["Because A"]
    reply, _ = await c.request("skip_question", {"cluster_id": q2.cluster_id})
    assert reply["payload"]["result"] == {"skipped_application_ids": [a2]}
    await c.close()


async def test_stop_during_active_run_requeues_and_closes_run(autoapply_home: Paths, sock_dir: Path) -> None:
    conn = db.open_db(autoapply_home.db)
    filling = asyncio.Event()
    adapter = FakeAdapter(conn)

    async def hanging_fill(ctx: Any) -> Any:
        filling.set()
        await asyncio.sleep(60)

    adapter.fill = hanging_fill  # type: ignore[method-assign]
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter,
                     sources=[FakeSource([gh_job("Stripe", "Backend Engineer", 1)])])
    await d.start()
    c = await client(d)
    reply, _ = await c.request("run_now", {"kind": "full"})
    run_id = reply["payload"]["result"]["run_id"]
    await asyncio.wait_for(filling.wait(), 5)
    app = db.list_applications(conn)[0]
    assert app.state is AppState.FILLING
    await d.stop()
    assert db.get_application(conn, app.id).state is AppState.QUEUED  # nothing was submitted
    run = db.get_run(conn, run_id)
    assert run.finished_at is not None and run.outcome.value == "failed"
    assert not (sock_dir / "d.sock").exists()
    await c.close()
    conn.close()


async def test_reset_source_cap_zeroes_counter_and_updates_ui(autoapply_home: Paths, sock_dir: Path) -> None:
    d = build_daemon(autoapply_home, sock_dir / "d.sock")
    await d.start()
    try:
        for _ in range(3):
            db.increment_source_sessions(d.conn, "linkedin")
        c = await client(d)
        reply, _ = await c.request("reset_source_cap", {"source": "linkedin"})
        assert reply["type"] == "ack"
        ev, _ = await c.recv_until(lambda m: m["type"] == "cap_reached")
        assert ev["payload"]["cap"] == "linkedin_budget" and ev["payload"]["used"] == 0
        assert db.get_source_sessions(d.conn, "linkedin") == 0
        await c.close()
    finally:
        await d.stop()
