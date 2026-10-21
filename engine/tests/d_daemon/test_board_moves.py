"""Board drag & drop commands: ``queue_application`` (drop on Queued) and ``mark_applied`` ("I applied myself")."""

from __future__ import annotations

from pathlib import Path

from autoapply import db
from autoapply.enums import AppState, BoardStatus
from autoapply.paths import Paths

from .fakes import FakeAdapter
from .test_daemon import _seed_app, build_daemon
from .test_guardrails import _cmd, _wait_for, sock_dir  # noqa: F401 - fixture


async def test_queue_application_from_skipped_and_discovered(autoapply_home: Paths, sock_dir: Path) -> None:  # noqa: F811
    conn = db.open_db(autoapply_home.db)
    adapter = FakeAdapter(conn)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    try:
        db.update_preferences(conn, {"mode": "review"})
        skipped = _seed_app(conn, [AppState.SCORED, AppState.SKIPPED], "Stripe", "SWE")
        r = await _cmd(d, "queue_application", {"application_id": skipped})
        assert r["type"] == "ack" and r["payload"]["result"]["started"], r
        await _wait_for(lambda: db.get_application(conn, skipped).state is AppState.AWAITING_REVIEW)
        assert adapter.filled == [skipped]

        assert (await _cmd(d, "pause_all"))["type"] == "ack"
        discovered = _seed_app(conn, [], "Ramp", "AI Engineer")
        res = (await _cmd(d, "queue_application", {"application_id": discovered}))["payload"]["result"]
        app = db.get_application(conn, discovered)
        assert res == {"state": "queued", "started": False} and app.state is AppState.QUEUED and app.state_reason == "user_queued"
    finally:
        await d.stop()


async def test_queue_application_refuses_easy_apply_and_submitted(autoapply_home: Paths, sock_dir: Path) -> None:  # noqa: F811
    conn = db.open_db(autoapply_home.db)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn)
    await d.start()
    try:
        app_id = _seed_app(conn, [AppState.SCORED], "Acme", "SWE")
        db.update_job(conn, db.get_application(conn, app_id).job_id, easy_apply=True)
        r = await _cmd(d, "queue_application", {"application_id": app_id})
        assert r["type"] == "error" and r["payload"]["code"] == "conflict" and "Easy Apply" in r["payload"]["message"]

        done = _seed_app(conn, [AppState.SCORED], "Globex", "SWE")
        db.mark_manually_applied(conn, db.get_application(conn, done).job_id)
        r = await _cmd(d, "queue_application", {"application_id": done})
        assert r["type"] == "error" and r["payload"]["code"] == "conflict"
    finally:
        await d.stop()


async def test_mark_applied_lands_in_the_chosen_column(autoapply_home: Paths, sock_dir: Path) -> None:  # noqa: F811
    conn = db.open_db(autoapply_home.db)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn)
    await d.start()
    try:
        app_id = _seed_app(conn, [AppState.SCORED, AppState.SKIPPED], "Stripe", "SWE")
        r = await _cmd(d, "mark_applied", {"application_id": app_id, "status": "interview"})
        assert r["type"] == "ack" and r["payload"]["result"]["status"] == "interview", r
        app = db.get_application(conn, app_id)
        assert app.state is AppState.SUBMITTED and app.status is BoardStatus.INTERVIEW and app.state_reason == "user_applied"
        assert app.mode.value == "manual"
        # once submitted it can't be marked again
        again = await _cmd(d, "mark_applied", {"application_id": app_id})
        assert again["type"] == "error" and again["payload"]["code"] == "conflict"
    finally:
        await d.stop()
