"""Add a job by link: page metadata parsing and the ``add_job_url`` daemon command."""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from autoapply import db, manual_job
from autoapply.enums import AppState, Ats
from autoapply.manual_job import InvalidJobUrl, JobMeta, company_from_url, fetch_job_meta, normalize_job_url, parse_job_page
from autoapply.paths import Paths

from .fakes import FakeAdapter
from .test_daemon import _seed_app, build_daemon
from .test_guardrails import _cmd, _wait_for, sock_dir  # noqa: F401 - fixture

LD_PAGE = """<html><head><title>Careers</title>
<script type="application/ld+json">{"@context": "https://schema.org", "@type": "JobPosting",
 "title": "Backend Engineer", "hiringOrganization": {"@type": "Organization", "name": "Acme"},
 "jobLocation": {"@type": "Place", "address": {"addressLocality": "Bengaluru", "addressCountry": "IN"}},
 "description": "<p>Build <b>APIs</b></p>", "datePosted": "2026-10-01"}</script></head></html>"""


def test_parse_json_ld_posting() -> None:
    meta = parse_job_page("https://jobs.lever.co/acme/123", LD_PAGE)
    assert (meta.title, meta.company, meta.location) == ("Backend Engineer", "Acme", "Bengaluru, IN")
    assert meta.ats is Ats.LEVER and meta.board_token == "acme"
    assert "APIs" in (meta.description or "")


def test_parse_falls_back_to_title_and_url() -> None:
    page = '<html><head><meta property="og:site_name" content="Zeta"><title>ML Engineer | Zeta</title></head></html>'
    meta = parse_job_page("https://careers.zeta.tech/jobs/42", page)
    assert (meta.title, meta.company) == ("ML Engineer", "Zeta")
    empty = parse_job_page("https://careers.zeta.tech/jobs/42", "")
    assert empty.company == "Zeta" and empty.title == "Job at Zeta"


def test_company_from_url() -> None:
    assert company_from_url("https://ats.rippling.com/alaan-careers/jobs/x") == "Alaan"
    assert company_from_url("https://jobs.ashbyhq.com/ramp/abc") == "Ramp"
    assert company_from_url("https://nvidia.wd5.myworkdayjobs.com/en-US/External/job/1") == "Nvidia"


def test_normalize_job_url() -> None:
    assert normalize_job_url(" jobs.lever.co/acme/1 ") == "https://jobs.lever.co/acme/1"
    for bad in ("", "not a url", "ftp://x.com/a", "https://www.linkedin.com/jobs/view/1"):
        with pytest.raises(InvalidJobUrl):
            normalize_job_url(bad)


async def test_rippling_uses_public_api() -> None:
    uid = "187d971b-6e4d-4cf7-bc10-e2be2dc2f917"

    def handler(req: httpx.Request) -> httpx.Response:
        assert req.url.path == f"/api/v2/board/alaan-careers/jobs/{uid}"
        return httpx.Response(200, json={
            "uuid": uid, "name": "AI Engineer", "workLocations": ["Bengaluru, India"], "createdOn": "2026-09-09",
            "description": {"role": "<p>Ship LLM features</p>"}, "board": {"companyName": "AlaanPay Technology FZCO"},
        })

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        meta = await fetch_job_meta(f"https://ats.rippling.com/alaan-careers/jobs/{uid}/apply?step=application", http=http)
    assert (meta.title, meta.company, meta.location, meta.external_id) == ("AI Engineer", "Alaan", "Bengaluru, India", uid)


async def test_fetch_never_raises_on_network_error() -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        meta = await fetch_job_meta("https://boards.greenhouse.io/stripe/jobs/1", http=http)
    assert meta.company == "Stripe" and meta.ats is Ats.GREENHOUSE


@pytest.fixture
def fake_meta(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    seen: list[str] = []

    async def fake(url: str, **_: object) -> JobMeta:
        seen.append(url)
        return JobMeta(url=url, title="AI Engineer", company="Alaan", location="Bengaluru, India", ats=Ats.OTHER)

    monkeypatch.setattr(manual_job, "fetch_job_meta", fake)
    return seen


async def test_add_job_url_queues_and_fills(autoapply_home: Paths, sock_dir: Path, fake_meta: list[str]) -> None:  # noqa: F811
    conn = db.open_db(autoapply_home.db)
    adapter = FakeAdapter(conn)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    try:
        db.update_preferences(conn, {"mode": "review"})
        r = await _cmd(d, "add_job_url", {"url": "ats.rippling.com/alaan-careers/jobs/1", "company": "Alaan Pay"})
        assert r["type"] == "ack", r
        res = r["payload"]["result"]
        assert res["created"] and res["started"] and res["company"] == "Alaan Pay" and res["title"] == "AI Engineer"
        app_id = res["application_id"]
        # Review mode: filled, then parked for the user's approval; never submitted.
        await _wait_for(lambda: db.get_application(conn, app_id).state is AppState.AWAITING_REVIEW)
        assert adapter.filled == [app_id] and adapter.submitted == []
        job = db.get_job(conn, res["job_id"])
        assert job.source.value == "manual" and job.apply_url == "https://ats.rippling.com/alaan-careers/jobs/1"

        # The same link again: no duplicate, no second fill.
        again = (await _cmd(d, "add_job_url", {"url": "https://ats.rippling.com/alaan-careers/jobs/1"}))["payload"]["result"]
        assert again["job_id"] == res["job_id"] and not again["created"] and not again["started"]
        assert fake_meta == ["https://ats.rippling.com/alaan-careers/jobs/1"]
    finally:
        await d.stop()


async def test_add_job_url_requeues_skipped_and_respects_pause(autoapply_home: Paths, sock_dir: Path, fake_meta: list[str]) -> None:  # noqa: F811
    conn = db.open_db(autoapply_home.db)
    adapter = FakeAdapter(conn)
    d = build_daemon(autoapply_home, sock_dir / "d.sock", conn=conn, adapter=adapter)
    await d.start()
    try:
        app_id = _seed_app(conn, [AppState.SCORED, AppState.SKIPPED], "Stripe", "SWE")
        url = db.get_job(conn, db.get_application(conn, app_id).job_id).apply_url
        assert (await _cmd(d, "pause_all"))["type"] == "ack"
        res = (await _cmd(d, "add_job_url", {"url": url}))["payload"]["result"]
        assert res["application_id"] == app_id and res["state"] == "queued" and not res["started"]
        assert db.get_application(conn, app_id).state_reason == "user_added_link"
        assert adapter.filled == [] and fake_meta == []
    finally:
        await d.stop()


async def test_add_job_url_rejects_linkedin(autoapply_home: Paths, sock_dir: Path) -> None:  # noqa: F811
    d = build_daemon(autoapply_home, sock_dir / "d.sock")
    await d.start()
    try:
        r = await _cmd(d, "add_job_url", {"url": "https://www.linkedin.com/jobs/view/123"})
        assert r["type"] == "error" and r["payload"]["code"] == "invalid_payload"
        assert "LinkedIn" in r["payload"]["message"]
    finally:
        await d.stop()

