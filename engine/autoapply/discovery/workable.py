"""Workable public jobs API.

Owner: Workstream A (engine core).

* Listing: ``POST https://apply.workable.com/api/v3/accounts/{slug}/jobs`` with
  ``{"query": "", "location": [], "department": [], "worktype": [], "remote": []}`` (plus
  ``"token": nextPage`` for the next page of 10) -> ``{"total", "nextPage"?, "results": [{id,
  shortcode, title, remote, workplace ("remote"|"hybrid"|"on_site"), location{city, region,
  country}, locations[...], published, type, department[]}]}``. An unknown account answers
  ``{"total": 0, "results": []}``.
* Detail: ``GET https://apply.workable.com/api/v2/accounts/{slug}/jobs/{shortcode}`` -> the same
  fields plus ``description``, ``requirements`` and ``benefits`` (HTML). Fetched only for postings
  that pass the title filter.

Posting page: ``https://apply.workable.com/{slug}/j/{shortcode}/`` (form at ``.../apply/``).
Board token: ``"workable:{slug}"`` on a company with ``ats = 'other'``. Read-only; nothing is
ever submitted.
"""

from __future__ import annotations

from typing import Any

import httpx

from autoapply.discovery.base import (
    DiscoveredJob,
    fetch_json,
    html_to_text,
    infer_remote,
    parse_datetime,
    parse_salary_text,
    post_json,
)
from autoapply.enums import Ats, JobSource

WORKABLE = "https://apply.workable.com"
MAX_PAGES = 15  # 10 postings per page


def job_url(slug: str, shortcode: str) -> str:
    return f"{WORKABLE}/{slug}/j/{shortcode}/"


def _location(data: dict[str, Any]) -> str | None:
    def fmt(loc: dict[str, Any]) -> str:
        return ", ".join(str(p).strip() for p in (loc.get("city"), loc.get("region"), loc.get("country")) if p and str(p).strip())

    names: list[str] = []
    for loc in [data.get("location") or {}, *(data.get("locations") or [])]:
        s = fmt(loc) if isinstance(loc, dict) else ""
        if s and s not in names:
            names.append(s)
    return " · ".join(names) or None


def parse_workable_job(data: dict[str, Any], *, slug: str, company_name: str | None = None) -> DiscoveredJob:
    title = (data.get("title") or "").strip()
    location = _location(data)
    workplace = data.get("workplace")
    explicit = workplace or ("remote" if data.get("remote") else None)
    shortcode = str(data.get("shortcode") or "")
    url = job_url(slug, shortcode) if shortcode else f"{WORKABLE}/{slug}/"
    token = f"workable:{slug}"
    return DiscoveredJob(
        source=JobSource.CAREERS,
        company_name=(company_name or slug).strip(),
        title=title,
        apply_url=url,
        source_url=url,
        ats=Ats.OTHER,
        external_id=shortcode or None,
        location=location,
        remote=infer_remote(location, title, explicit=explicit),
        posted_at=parse_datetime(data.get("published")),
        board_token=token,
        raw={
            "board_token": token,
            "provider": "workable",
            "shortcode": shortcode or None,
            "workplace": workplace,
            "employment_type": data.get("type"),
            "department": data.get("department"),
        },
    )


def apply_detail(job: DiscoveredJob, detail: dict[str, Any]) -> DiscoveredJob:
    if not isinstance(detail, dict):
        return job
    parts = [html_to_text(detail.get(k)) for k in ("description", "requirements", "benefits")]
    text = "\n\n".join(p for p in parts if p)
    if text:
        job.description = text
        if job.salary_min is None and job.salary_max is None:
            job.salary_min, job.salary_max, job.salary_currency = parse_salary_text(text)
    return job


async def fetch_workable_board(
    http: httpx.AsyncClient, slug: str, *, company_name: str | None = None, max_pages: int = MAX_PAGES, base: str = WORKABLE
) -> list[DiscoveredJob]:
    out: dict[str, DiscoveredJob] = {}
    body: dict[str, Any] = {"query": "", "location": [], "department": [], "worktype": [], "remote": []}
    for _ in range(max(1, max_pages)):
        data = await post_json(http, f"{base}/api/v3/accounts/{slug}/jobs", body)
        results = data.get("results") if isinstance(data, dict) else None
        if not isinstance(results, list):
            raise ValueError(f"workable account {slug!r}: unexpected response shape")
        for r in results:
            key = str(r.get("shortcode") or r.get("id") or "")
            if key and r.get("title") and key not in out:
                out[key] = parse_workable_job(r, slug=slug, company_name=company_name)
        nxt = data.get("nextPage")
        if not nxt or not results:
            break
        body = {**body, "token": nxt}
    return list(out.values())


async def fetch_workable_detail(http: httpx.AsyncClient, slug: str, job: DiscoveredJob, *, base: str = WORKABLE) -> DiscoveredJob:
    if not job.external_id:
        return job
    return apply_detail(job, await fetch_json(http, f"{base}/api/v2/accounts/{slug}/jobs/{job.external_id}"))


__all__ = ["apply_detail", "fetch_workable_board", "fetch_workable_detail", "job_url", "parse_workable_job"]
