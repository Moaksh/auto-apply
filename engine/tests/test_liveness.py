"""Posting liveness: ATS APIs first, plain page GET second, unknown = open, 12h cache."""

from __future__ import annotations

import sqlite3
from collections.abc import Callable
from datetime import timedelta

import httpx
import pytest

from autoapply import db, liveness
from autoapply.enums import AppState, Ats
from autoapply.models import utcnow

Handler = Callable[[httpx.Request], httpx.Response]


@pytest.fixture(autouse=True)
def _liveness_on(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(liveness, "ENABLED", True)


def client(handler: Handler, seen: list[str] | None = None) -> httpx.AsyncClient:
    def wrapped(req: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(str(req.url))
        return handler(req)

    return httpx.AsyncClient(transport=httpx.MockTransport(wrapped), follow_redirects=True)


def make_job(conn: sqlite3.Connection, *, url: str, ats: Ats = Ats.OTHER, external_id: str | None = None,
             raw: dict | None = None, title: str = "Backend Engineer", company: str = "Acme"):
    co = db.upsert_company(conn, company)
    job, _ = db.insert_job(conn, company_id=co.id, source="manual", title=title, apply_url=url, ats=ats,
                           external_id=external_id, raw=raw)
    return job


OPEN_PAGE = "<html><body><h1>Backend Engineer</h1><p>Build things.</p><a>Apply for this job</a></body></html>"


# ---- ATS APIs ----------------------------------------------------------------------------


async def test_greenhouse_api_open(conn: sqlite3.Connection) -> None:
    job = make_job(conn, url="https://job-boards.greenhouse.io/acme/jobs/12345", ats=Ats.GREENHOUSE)
    seen: list[str] = []

    def h(req: httpx.Request) -> httpx.Response:
        assert req.url.host == "boards-api.greenhouse.io" and req.url.path == "/v1/boards/acme/jobs/12345"
        return httpx.Response(200, json={"id": 12345, "title": "Backend Engineer"})

    async with client(h, seen) as http:
        res = await liveness.check(job, http)
    assert res.status == liveness.OPEN and res.method == "api" and len(seen) == 1


async def test_greenhouse_api_404_is_closed(conn: sqlite3.Connection) -> None:
    job = make_job(conn, url="https://boards.greenhouse.io/acme/jobs/12345", ats=Ats.GREENHOUSE)
    async with client(lambda r: httpx.Response(404, json={"status": 404})) as http:
        res = await liveness.check(job, http)
    assert res.closed and res.method == "api"


async def test_greenhouse_from_stored_token_and_id(conn: sqlite3.Connection) -> None:
    job = make_job(conn, url="https://acme.com/careers/apply?gh_jid=777777", ats=Ats.GREENHOUSE, external_id="777777",
                   raw={"board_token": "acme"})
    seen: list[str] = []
    async with client(lambda r: httpx.Response(200, json={"id": 777777}), seen) as http:
        res = await liveness.check(job, http)
    assert res.status == liveness.OPEN and seen == ["https://boards-api.greenhouse.io/v1/boards/acme/jobs/777777"]


async def test_lever_api_open(conn: sqlite3.Connection) -> None:
    pid = "0b5a1c9e-1111-2222-3333-444455556666"
    job = make_job(conn, url=f"https://jobs.lever.co/acme/{pid}/apply", ats=Ats.LEVER)
    async with client(lambda r: httpx.Response(200, json={"id": pid, "text": "Backend Engineer"})) as http:
        res = await liveness.check(job, http)
    assert res.status == liveness.OPEN and res.method == "api"


async def test_lever_api_404_falls_through_to_the_page(conn: sqlite3.Connection) -> None:
    """A Lever API 404 is not trusted on its own: the page decides."""
    pid = "0b5a1c9e-1111-2222-3333-444455556666"
    job = make_job(conn, url=f"https://jobs.lever.co/acme/{pid}/apply", ats=Ats.LEVER)

    def live_page(req: httpx.Request) -> httpx.Response:
        return httpx.Response(404) if req.url.host == "api.lever.co" else httpx.Response(200, text=OPEN_PAGE)

    async with client(live_page) as http:
        assert (await liveness.check(job, http)).status == liveness.OPEN

    async with client(lambda r: httpx.Response(404, text="Not found")) as http:
        res = await liveness.check(job, http)
    assert res.closed and res.method == "page"


async def test_ashby_board_listing(conn: sqlite3.Connection) -> None:
    pid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    job = make_job(conn, url=f"https://jobs.ashbyhq.com/acme/{pid}/application", ats=Ats.ASHBY)
    async with client(lambda r: httpx.Response(200, json={"jobs": [{"id": pid, "isListed": True}]})) as http:
        assert (await liveness.check(job, http)).status == liveness.OPEN
    async with client(lambda r: httpx.Response(200, json={"jobs": [{"id": "other"}]})) as http:
        res = await liveness.check(job, http)
    assert res.closed and res.method == "api"
    async with client(lambda r: httpx.Response(200, json={"jobs": [{"id": pid, "isListed": False}]})) as http:
        assert (await liveness.check(job, http)).closed


async def test_ashby_board_unreadable_is_not_closed(conn: sqlite3.Connection) -> None:
    pid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    job = make_job(conn, url=f"https://jobs.ashbyhq.com/acme/{pid}", ats=Ats.ASHBY)
    # board API 404 (off for this org) -> page -> SPA shell with no signal -> unknown
    def h(req: httpx.Request) -> httpx.Response:
        if req.url.host == "api.ashbyhq.com":
            return httpx.Response(404)
        return httpx.Response(200, text="<html><body><div id=root></div></body></html>")

    async with client(h) as http:
        res = await liveness.check(job, http)
    assert res.status == liveness.UNKNOWN and not res.closed


# ---- page rung ---------------------------------------------------------------------------


@pytest.mark.parametrize("status,body,expected", [
    (200, OPEN_PAGE, liveness.OPEN),
    (404, "<html>Not Found</html>", liveness.CLOSED),
    (410, "", liveness.CLOSED),
    (200, "<html><body><h2>Sorry, this job is no longer accepting applications.</h2></body></html>", liveness.CLOSED),
    (200, "<p>This job has expired</p>", liveness.CLOSED),
    (200, "<div>We're sorry, the position has been filled.</div>", liveness.CLOSED),
    (200, "<div>Job not found</div>", liveness.CLOSED),
    (200, "<p>This position is no longer available</p>", liveness.CLOSED),
    # a future condition, not a closure
    (200, "<p>Applications are reviewed until the position has been filled.</p><a>Apply now</a>", liveness.OPEN),
    (200, "<p>This role is closed-loop control of robots.</p><a>Apply</a>", liveness.OPEN),
    # bot walls / server errors / empty pages: unknown, never closed
    (200, "<title>Just a moment...</title> Checking your browser", liveness.UNKNOWN),
    (503, "Service unavailable", liveness.UNKNOWN),
    (403, "Forbidden", liveness.UNKNOWN),
    (200, "<html><body><div id='app'></div></body></html>", liveness.UNKNOWN),
])
async def test_page_classification(conn: sqlite3.Connection, status: int, body: str, expected: str) -> None:
    job = make_job(conn, url="https://careers.acme.com/jobs/123456")
    async with client(lambda r: httpx.Response(status, text=body)) as http:
        res = await liveness.check(job, http)
    assert res.status == expected, res


async def test_redirect_to_generic_careers_page_is_closed(conn: sqlite3.Connection) -> None:
    job = make_job(conn, url="https://careers.acme.com/jobs/123456")

    def h(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/jobs/123456":
            return httpx.Response(301, headers={"Location": "https://careers.acme.com/careers/"})
        return httpx.Response(200, text="<h1>Join us</h1><p>See open roles. Apply today.</p>")

    async with client(h) as http:
        res = await liveness.check(job, http)
    assert res.closed and "generic" in res.reason


async def test_greenhouse_error_redirect_is_closed(conn: sqlite3.Connection) -> None:
    job = make_job(conn, url="https://careers.acme.com/apply/123456")

    def h(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/apply/123456":
            return httpx.Response(302, headers={"Location": "https://boards.greenhouse.io/acme?error=true"})
        return httpx.Response(200, text="<h1>Acme jobs</h1><a>Apply</a>")

    async with client(h) as http:
        assert (await liveness.check(job, http)).closed


async def test_redirect_elsewhere_is_unknown(conn: sqlite3.Connection) -> None:
    job = make_job(conn, url="https://careers.acme.com/jobs/123456")

    def h(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/jobs/123456":
            return httpx.Response(301, headers={"Location": "https://acme.wd1.myworkdayjobs.com/en-US/External/job/Backend_R1"})
        return httpx.Response(200, text="<h1>Backend</h1>")

    async with client(h) as http:
        assert (await liveness.check(job, http)).status == liveness.UNKNOWN


async def test_transport_error_is_unknown(conn: sqlite3.Connection) -> None:
    job = make_job(conn, url="https://careers.acme.com/jobs/123456")

    def h(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("timed out")

    async with client(h) as http:
        res = await liveness.check(job, http)
    assert res.status == liveness.UNKNOWN and not res.closed


async def test_linkedin_and_glassdoor_are_never_fetched(conn: sqlite3.Connection) -> None:
    seen: list[str] = []
    for i, url in enumerate(["https://www.linkedin.com/jobs/view/123456/", "https://www.glassdoor.co.in/job-listing/x-123456.htm"]):
        job = make_job(conn, url=url, title=f"Role {i}")
        async with client(lambda r: httpx.Response(404), seen) as http:
            res = await liveness.check(job, http)
        assert res.status == liveness.UNKNOWN
    assert seen == []


# ---- cache ---------------------------------------------------------------------------------


async def test_result_cached_for_12_hours(conn: sqlite3.Connection) -> None:
    job = make_job(conn, url="https://careers.acme.com/jobs/123456")
    seen: list[str] = []
    t0 = utcnow()
    async with client(lambda r: httpx.Response(200, text=OPEN_PAGE), seen) as http:
        first = await liveness.ensure(conn, job, http=http, now=t0)
        stored = db.get_job(conn, job.id).raw["liveness"]
        assert first.status == liveness.OPEN and stored["status"] == "open" and stored["checked_at"]
        again = await liveness.ensure(conn, db.get_job(conn, job.id), http=http, now=t0 + timedelta(hours=11))
        assert again.status == liveness.OPEN and len(seen) == 1
        await liveness.ensure(conn, db.get_job(conn, job.id), http=http, now=t0 + timedelta(hours=13))
    assert len(seen) == 2


async def test_disabled_does_nothing(conn: sqlite3.Connection, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(liveness, "ENABLED", False)
    job = make_job(conn, url="https://careers.acme.com/jobs/123456")
    seen: list[str] = []
    async with client(lambda r: httpx.Response(404), seen) as http:
        res = await liveness.ensure(conn, job, http=http)
    assert res.status == liveness.UNKNOWN and seen == [] and "liveness" not in db.get_job(conn, job.id).raw


async def test_ensure_many_is_bounded(conn: sqlite3.Connection) -> None:
    import asyncio

    jobs = [make_job(conn, url=f"https://careers.acme.com/jobs/10000{i}", title=f"Role {i}") for i in range(10)]
    live = 0
    peak = 0

    class Slow(httpx.AsyncBaseTransport):
        async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
            nonlocal live, peak
            live += 1
            peak = max(peak, live)
            await asyncio.sleep(0.01)
            live -= 1
            return httpx.Response(200 if request.url.path.endswith(("1", "3")) else 404, text=OPEN_PAGE)

    async with httpx.AsyncClient(transport=Slow()) as http:
        out = await liveness.ensure_many(conn, jobs, http=http, limit=4)
    assert peak <= 4 and len(out) == 10
    assert sum(r.closed for r in out.values()) == 8


# ---- prep gate -------------------------------------------------------------------------


async def test_prep_skips_closed_postings_before_harvest(conn: sqlite3.Connection, fake_llm, monkeypatch: pytest.MonkeyPatch) -> None:
    from autoapply import prep

    closed = make_job(conn, url="https://careers.acme.com/jobs/111111", title="Closed Role")
    live = make_job(conn, url="https://careers.acme.com/jobs/222222", title="Live Role", company="Beta")
    for j in (closed, live):
        app = db.get_application_by_job(conn, j.id)
        db.transition(conn, app.id, AppState.SCORED)
        db.transition(conn, app.id, AppState.QUEUED, reason="user_apply_anyway" if j is closed else "score 90")
    db.add_question(conn, canonical_question="Why us?", job_id=closed.id, field_type="text")

    def h(req: httpx.Request) -> httpx.Response:
        return httpx.Response(404) if req.url.path.endswith("111111") else httpx.Response(200, text=OPEN_PAGE)

    monkeypatch.setattr(liveness, "make_client", lambda: client(h))
    harvested: list[int] = []

    class Adapter:
        def can_handle(self, job) -> bool:
            return True

        async def harvest_questions(self, ctx):
            harvested.append(ctx.job.id)
            return []

    events: list[tuple[str, object]] = []

    async def emit(t: str, p: object) -> None:
        events.append((t, p))

    report = await prep.run_prep(conn, llm=fake_llm, adapters=[Adapter()], emit=emit)
    app = db.get_application_by_job(conn, closed.id)
    assert app.state is AppState.SKIPPED and app.state_reason == "posting_closed"
    assert report.closed_jobs == [closed.id] and harvested == [live.id]
    assert db.get_application_by_job(conn, live.id).state is AppState.QUEUED
    assert not any(closed.id in q.job_ids for q in db.list_questions(conn, status="open"))
    msgs = [r["message"] for r in conn.execute("SELECT message FROM events WHERE job_id = ? AND kind = 'prep'", (closed.id,))]
    assert any("which you queued yourself" in m for m in msgs)
