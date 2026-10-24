"""What the app shows while outreach works: a search's stage and progress in its meta row, the
Google work's status (running what, or why it waits: paused, the browser busy, today's limit,
Google's rest) in ``outreach_google_status``, and a ``scout_finished`` when the Google half of a
people search ends. No network, browser or real model."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import pytest
import respx

from autoapply import db
from autoapply.enums import ScoutPurpose
from autoapply.models import parse_ts, utcnow
from autoapply.outreach import prospects, scout
from autoapply.outreach.service import META_GOOGLE_STATUS
from autoapply.outreach.sources import google_people
from autoapply.paths import Paths
from tests.d_daemon.test_outreach import World, _browser, _Page
from tests.outreach_fakes import seed_profile


@pytest.fixture
async def world(autoapply_home: Paths):
    w = World(autoapply_home)
    seed_profile(w.conn)
    try:
        yield w
    finally:
        await w.daemon.stop()


def _status(world: World) -> dict[str, Any]:
    return db.get_meta(world.conn, META_GOOGLE_STATUS, None) or {}


@respx.mock
async def test_a_company_search_records_its_stages_then_finishes(world: World, monkeypatch: pytest.MonkeyPatch):
    page = _Page({"google.com/search": '<div><a href="https://news.example.com/l"><h3>List</h3></a><span>list</span></div>'})
    world.daemon.outreach._browser_factory = _browser(page)
    respx.get("https://news.example.com/l").respond(200, html="<p>Nothing here.</p>")
    world.llm.add_rule(r"Google queries", {"queries": ["fintech startups bangalore", "fintech companies bangalore"]})
    world.llm.add_rule(r"List the companies", {"companies": []})
    sid = (await world.ok("search_prospects", {"query": "fintech", "location": "Bangalore"}))["search_id"]
    assert prospects.get_search(world.conn, sid)["status"] == "queued"

    seen: list[tuple[Any, ...]] = []
    real = prospects.update_search

    def spy(conn, search_id, **fields):  # type: ignore[no-untyped-def]
        real(conn, search_id, **fields)
        s = prospects.get_search(conn, search_id)
        seen.append((s["status"], s.get("stage"), s.get("step"), s.get("steps"), _status(world).get("active")))

    monkeypatch.setattr(prospects, "update_search", spy)
    done = await world.daemon.outreach.run_google_work()
    assert done["searches"] == 1
    active = {"kind": "search", "search_id": sid}
    assert seen == [("running", "search", 1, 2, active), ("running", "search", 2, 2, active), ("running", "saving", None, None, active)]
    s = prospects.get_search(world.conn, sid)
    assert s["status"] == "done" and s["finished_at"] and s.get("stage") is None and s["found"] == 0
    assert _status(world)["state"] == "idle" and _status(world)["active"] is None


async def test_a_search_interrupted_mid_google_is_picked_up_again(world: World):
    sid = prospects.queue_search(world.conn, "devtools", None)
    prospects.update_search(world.conn, sid, status="running", stage="search", step=1, steps=3)
    assert [s["id"] for s in prospects.pending_searches(world.conn)] == [sid]
    # The YC half of a startup search runs over HTTP, never in the Google queue.
    yc = prospects.queue_startup_search(world.conn, {"country": "India"}, "India", yc_only=False, hiring_only=False, stages=[], limit=5)
    assert prospects.get_search(world.conn, yc)["stage"] == "yc"
    assert yc not in {s["id"] for s in prospects.pending_searches(world.conn)}
    prospects.finish_search(world.conn, sid, "done", 3)
    s = prospects.get_search(world.conn, sid)
    assert (s["status"], s["stage"], s["step"], s["found"]) == ("done", None, None, 3) and s["finished_at"]


async def test_why_queued_google_work_waits(world: World):
    out = world.daemon.outreach
    out.note_google_waiting(None)
    assert _status(world)["state"] == "idle"
    co = db.upsert_company(world.conn, "Acme", domain="acme.com")
    scout.queue_google(world.conn, co.id, ScoutPurpose.PROSPECT)

    out.note_google_waiting("browser_busy")
    st = _status(world)
    assert st["state"] == "waiting" and st["people"] == {"reason": "browser_busy", "resumes_at": None} and st["searches"] is None
    updated = st["updated_at"]
    out.note_google_waiting("browser_busy")
    assert _status(world)["updated_at"] == updated, "an unchanged status is not rewritten"

    out.note_google_waiting(None)
    assert _status(world)["people"]["reason"] == "next_turn"

    # Today's Google pages are used: it resumes at local midnight, whatever holds the browser.
    limit = db.get_preferences(world.conn).people_finder_visits_per_day
    for _ in range(limit):
        db.increment_source_sessions(world.conn, google_people.PEOPLE_KEY)
    out.note_google_waiting("browser_busy")
    lane = _status(world)["people"]
    assert lane["reason"] == "daily_limit"
    assert parse_ts(lane["resumes_at"]) == db.local_day_start(out.now()) + timedelta(days=1)

    prospects.queue_search(world.conn, "devtools", None)
    out.note_google_waiting(None)
    assert _status(world)["searches"] == {"reason": "next_turn", "resumes_at": None}

    rest = (utcnow() + timedelta(hours=2)).isoformat()
    db.set_meta(world.conn, google_people._REST_META, rest)
    out.note_google_waiting(None)
    st = _status(world)
    assert st["people"]["reason"] == "resting" == st["searches"]["reason"]
    assert abs(parse_ts(st["people"]["resumes_at"]) - parse_ts(rest)) < timedelta(milliseconds=1)

    db.set_meta(world.conn, google_people._REST_META, None)
    db.update_preferences(world.conn, {"people_finder_visits_per_day": 0})
    out.note_google_waiting(None)
    assert _status(world)["people"]["reason"] == "off"


async def test_the_idle_runner_records_paused_and_a_busy_browser(world: World, monkeypatch: pytest.MonkeyPatch):
    from autoapply.outreach import service

    monkeypatch.setattr(service, "AUTO_ENABLED", True)
    d = world.daemon
    co = db.upsert_company(world.conn, "Acme", domain="acme.com")
    scout.queue_google(world.conn, co.id, ScoutPurpose.PROSPECT)
    d.paused = True
    assert await d.outreach_google_if_idle() is False
    assert _status(world)["people"]["reason"] == "paused"
    d.paused = False
    async with d.pipeline.browser_lock:
        assert await d.outreach_google_if_idle() is False
    assert _status(world)["people"]["reason"] == "browser_busy"


async def test_the_google_half_of_a_people_search_reports_when_it_ends(world: World, monkeypatch: pytest.MonkeyPatch):
    out = world.daemon.outreach
    co = db.upsert_company(world.conn, "Acme", domain="acme.com")
    scout.queue_google(world.conn, co.id, ScoutPurpose.PROSPECT)
    out._browser_factory = _browser(_Page({}))
    during: list[dict[str, Any]] = []

    async def fake_scout_google(company_id, purpose, reader, *, job_id=None):  # type: ignore[no-untyped-def]
        during.append(_status(world))
        scout.pop_google(world.conn, company_id, ScoutPurpose(purpose).value)
        return scout.ScoutReport(company_id=company_id, purpose=ScoutPurpose(purpose))

    monkeypatch.setattr(out.scout, "scout_google", fake_scout_google)
    done = await out.run_google_work()
    assert done["scouts"] == 1
    assert during[0]["state"] == "running" and during[0]["active"] == {"kind": "people", "company_id": co.id}
    finished = [p for t, p in world.events if t == "scout_finished"]
    assert len(finished) == 1 and finished[0].company_id == co.id and finished[0].queued_google is False
    assert _status(world)["state"] == "idle"
