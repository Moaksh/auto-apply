"""Read-only smoke checks against live public boards. Deselected by default; run with
``uv run pytest tests/a_core -m network``. GET requests only; nothing is ever submitted."""

from __future__ import annotations

import httpx
import pytest

from autoapply.discovery.ashby import fetch_job_board
from autoapply.discovery.greenhouse import fetch_board, fetch_greenhouse_questions
from autoapply.discovery.lever import fetch_postings
from autoapply.enums import Ats

pytestmark = pytest.mark.network


async def test_live_greenhouse_board_and_questions() -> None:
    async with httpx.AsyncClient(timeout=30) as http:
        jobs = await fetch_board(http, "gitlab", company_name="GitLab")
        assert jobs and all(j.ats is Ats.GREENHOUSE and j.title and j.apply_url for j in jobs)
        assert any(j.description for j in jobs)
        qs = await fetch_greenhouse_questions(http, "gitlab", jobs[0].external_id)
        keys = {q.key for q in qs}
        assert {"first_name", "last_name", "email", "resume"} <= keys


async def test_live_lever_postings() -> None:
    async with httpx.AsyncClient(timeout=30) as http:
        jobs = await fetch_postings(http, "palantir", company_name="Palantir")
    assert jobs and all(j.ats is Ats.LEVER and j.apply_url and j.apply_url.endswith("/apply") for j in jobs)


async def test_live_ashby_board() -> None:
    async with httpx.AsyncClient(timeout=30) as http:
        jobs = await fetch_job_board(http, "ramp", company_name="Ramp")
    assert jobs and all(j.ats is Ats.ASHBY and j.apply_url for j in jobs)
    assert any(j.salary_min for j in jobs)
