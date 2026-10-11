"""Ashby public job board API.

Owner: Workstream A (engine core).

``GET https://api.ashbyhq.com/posting-api/job-board/{org}?includeCompensation=true`` ->
``{"apiVersion": "1", "jobs": [{id, title, department, team, employmentType, location,
secondaryLocations[{location, address}], isListed, isRemote, workplaceType
("OnSite"|"Remote"|"Hybrid"), address{postalAddress}, jobUrl, applyUrl, descriptionHtml,
descriptionPlain, publishedAt, compensation{compensationTierSummary,
summaryComponents[{compensationType, interval, currencyCode, minValue, maxValue}]}}]}``.

Unlisted postings (``isListed: false``) are skipped.
"""

from __future__ import annotations

from typing import Any

import httpx

from autoapply.discovery.base import (
    DiscoveredJob,
    DiscoveryContext,
    annualize,
    companies_for,
    fetch_json,
    gather_per_company,
    html_to_text,
    infer_remote,
    parse_datetime,
    parse_salary_text,
)
from autoapply.enums import Ats, JobSource
from autoapply.models import Company

ASHBY_API = "https://api.ashbyhq.com/posting-api/job-board"


def _salary(comp: dict[str, Any] | None) -> tuple[int | None, int | None, str | None]:
    if not comp:
        return None, None, None
    comps = list(comp.get("summaryComponents") or [])
    for tier in comp.get("compensationTiers") or []:
        comps.extend(tier.get("components") or [])
    salaries = [c for c in comps if c.get("compensationType") == "Salary" and (c.get("minValue") is not None or c.get("maxValue") is not None)]
    if salaries:
        lows, highs, cur = [], [], None
        for c in salaries:
            iv = (c.get("interval") or "1 YEAR").lower()
            if c.get("minValue") is not None:
                lows.append(annualize(float(c["minValue"]), iv))
            if c.get("maxValue") is not None:
                highs.append(annualize(float(c["maxValue"]), iv))
            cur = cur or c.get("currencyCode")
        return (min(lows) if lows else None), (max(highs) if highs else None), cur
    summary = comp.get("scrapeableCompensationSalarySummary") or comp.get("compensationTierSummary")
    return parse_salary_text(summary)


def parse_ashby_job(data: dict[str, Any], *, org: str, company_name: str | None = None) -> DiscoveredJob:
    title = (data.get("title") or "").strip()
    location = (data.get("location") or "").strip() or None
    secondary = [s.get("location") for s in data.get("secondaryLocations") or [] if s.get("location")]
    description = (data.get("descriptionPlain") or html_to_text(data.get("descriptionHtml")) or "").strip() or None
    lo, hi, cur = _salary(data.get("compensation"))
    workplace = data.get("workplaceType")
    remote = infer_remote(location, title, explicit=workplace)
    if remote is None and data.get("isRemote"):
        remote = infer_remote(explicit="remote")
    job_url = data.get("jobUrl")
    apply_url = data.get("applyUrl") or (f"{job_url.rstrip('/')}/application" if job_url else None)
    return DiscoveredJob(
        source=JobSource.ASHBY,
        company_name=(company_name or org).strip(),
        title=title,
        apply_url=apply_url,
        source_url=job_url or apply_url,
        ats=Ats.ASHBY,
        external_id=str(data.get("id")) if data.get("id") else None,
        location=location,
        remote=remote,
        salary_min=lo,
        salary_max=hi,
        salary_currency=cur,
        description=description,
        posted_at=parse_datetime(data.get("publishedAt")),
        board_token=org,
        raw={
            "board_token": org,
            "posting_id": data.get("id"),
            "job_url": job_url,
            "department": data.get("department"),
            "team": data.get("team"),
            "employment_type": data.get("employmentType"),
            "secondary_locations": secondary,
            "is_remote": data.get("isRemote"),
            "workplace_type": workplace,
            "compensation_summary": (data.get("compensation") or {}).get("compensationTierSummary"),
        },
    )


async def fetch_job_board(http: httpx.AsyncClient, org: str, *, company_name: str | None = None, api_base: str = ASHBY_API) -> list[DiscoveredJob]:
    data = await fetch_json(http, f"{api_base}/{org}", params={"includeCompensation": "true"})
    jobs = data.get("jobs") if isinstance(data, dict) else None
    if not isinstance(jobs, list):
        raise ValueError(f"ashby board {org!r}: unexpected response shape")
    return [
        parse_ashby_job(j, org=org, company_name=company_name)
        for j in jobs
        if j.get("title") and j.get("isListed", True)
    ]


class AshbySource:
    """Implements :class:`autoapply.discovery.base.Source` for watchlist companies whose
    ``ats == ashby`` and ``board_token`` is set."""

    name = JobSource.ASHBY

    def __init__(self, *, api_base: str = ASHBY_API, concurrency: int = 4) -> None:
        self.api_base = api_base
        self.concurrency = concurrency

    async def fetch_company(self, http: httpx.AsyncClient, company: Company) -> list[DiscoveredJob]:
        assert company.board_token
        return await fetch_job_board(http, company.board_token, company_name=company.name, api_base=self.api_base)

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        companies = companies_for(ctx, Ats.ASHBY)
        return await gather_per_company(
            ctx, companies, lambda c: self.fetch_company(ctx.http, c), concurrency=self.concurrency, source="ashby"
        )
