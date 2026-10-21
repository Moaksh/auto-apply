"""Issue #2: uploads go through the browser tool's output dir, a busy Chrome profile is swapped
for a spare one, and "browser unavailable" never reaches Needs You."""

from __future__ import annotations

import json
import os
import socket
from pathlib import Path

import pytest

from autoapply import db
from autoapply.apply.agentic import AgentToolbox, AgenticAdapter, ToolGate, _profile_in_use, browser_id
from autoapply.enums import AppState, Ats, Mode, QuestionReason
from autoapply.llm.provider import FakeLLMProvider

from .conftest import make_ctx, make_job, seed_profile


@pytest.fixture
def world(conn, autoapply_home, emit, tmp_path):
    seed_profile(conn)
    resume = tmp_path / "resumes" / "Ada_Lovelace.pdf"
    resume.parent.mkdir()
    resume.write_bytes(b"%PDF fake")
    v = db.add_resume_variant(conn, label="Backend", file_path=str(resume), tags=["backend"])
    job, app = make_job(conn, ats=Ats.OTHER, state=AppState.FILLING, apply_url="https://careers.example.com/jobs/1")
    db.update_application(conn, app.id, resume_variant_id=v.id)
    ctx = make_ctx(conn, app.id, FakeLLMProvider(default="ok"), autoapply_home, emit)
    out = tmp_path / "screenshots" / str(app.id)
    out.mkdir(parents=True)
    return {"ctx": ctx, "resume": resume, "out": out, "conn": conn, "app": app}


async def test_resume_is_staged_inside_the_output_dir(world):
    tb = AgentToolbox(world["ctx"], ToolGate(), phase="fill", output_dir=world["out"], mode=Mode.REVIEW)
    data = json.loads((await tb.pick_resume({}))["content"][0]["text"])
    staged = Path(data["file_path"])
    assert staged.parent == (world["out"] / "uploads").resolve() and staged.name == "Ada_Lovelace.pdf"
    assert staged.read_bytes() == world["resume"].read_bytes()
    up = browser_id("browser_file_upload")
    assert tb.gate.check(up, {"paths": [str(staged)]}, "a").allowed
    assert tb.resume_path == str(world["resume"])  # the record keeps the library file


async def test_browser_lock_is_not_a_user_task(world):
    tb = AgentToolbox(world["ctx"], ToolGate(), phase="fill", output_dir=world["out"], mode=Mode.REVIEW)
    out = await tb.ask_user({"question": "Browser unavailable (the Chrome profile is locked by another instance)",
                             "kind": "action", "reason": QuestionReason.UNKNOWN.value})
    assert "internal browser problem" in out["content"][0]["text"]
    assert not tb.unresolved and tb.browser_down


def test_profile_in_use_reads_the_singleton_lock(tmp_path):
    p = tmp_path / "prof"
    p.mkdir()
    assert not _profile_in_use(p)
    os.symlink(f"{socket.gethostname()}-{os.getpid()}", p / "SingletonLock")
    assert _profile_in_use(p)
    (p / "SingletonLock").unlink()
    os.symlink(f"{socket.gethostname()}-999999", p / "SingletonLock")  # dead pid: stale
    assert not _profile_in_use(p)


def test_busy_profile_falls_back_to_a_spare(tmp_path):
    base = tmp_path / "chrome-profile"
    (base / "Default").mkdir(parents=True)
    (base / "Default" / "Cookies").write_bytes(b"c")
    os.symlink(f"{socket.gethostname()}-{os.getpid()}", base / "SingletonLock")
    adapter = AgenticAdapter(chrome_profile_dir=base)
    alt = adapter.profile_dir()
    assert alt.name == "chrome-profile-alt1" and (alt / "Default" / "Cookies").exists()
    assert not (alt / "SingletonLock").exists()


async def test_glitch_items_are_retried_once(world, autoapply_home):
    from tests.d_daemon.fakes import EventSink, FakeSource, fake_hooks

    from autoapply.enums import JobSource
    from autoapply.pipeline import Pipeline

    conn, app = world["conn"], world["app"]
    job_id = db.get_application(conn, app.id).job_id
    db.transition(conn, app.id, AppState.NEEDS_YOU, reason="unresolved_questions")
    db.add_question(conn, canonical_question="The browser can't read the resume file. The upload tool only allows files "
                    "under the screenshots folder", job_id=job_id, kind="action")
    hooks, _ = fake_hooks()
    p = Pipeline(conn, paths=autoapply_home, llm=FakeLLMProvider(default="ok"), sources=[FakeSource([], name=JobSource.GOOGLE)],
                 adapters=[], emit=EventSink(), hooks=hooks, is_paused=lambda: False)
    assert await p.retry_app_glitches() == 1
    assert db.get_application(conn, app.id).state is AppState.QUEUED
    assert await p.retry_app_glitches() == 0
