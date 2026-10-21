"""SmartRecruiters public postings API.

Owner: Workstream A (engine core).

* Listing: ``GET https://api.smartrecruiters.com/v1/companies/{id}/postings?limit=100&offset=N[&q=...]``
  -> ``{"offset", "limit", "totalFound", "content": [{id, name, refNumber, company{identifier, name},
  releasedDate, location{city, region, country, remote, hybrid, fullLocation}, department{label},
  typeOfEmployment{label}, experienceLevel{label}}]}``. An unknown company answers 200 with
  ``totalFound: 0``.
* Detail: ``GET .../postings/{postingId}`` -> adds ``postingUrl``, ``applyUrl`` and
  ``jobAd.sections`` (companyDescription, jobDescription, qualifications, additionalInformation,
  each ``{title, text (HTML)}``). Fetched only for postings that pass the title filter.

Board token: ``"smartrecruiters:{companyIdentifier}"`` on a company with ``ats = 'other'``.
Read-only; no auth; nothing is ever posted.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from typing import Any

import httpx

from autoapply.discovery.base import (
    DiscoveredJob,
    fetch_json,
    html_to_text,
    infer_remote,
    parse_datetime,
    parse_salary_text,
)
from autoapply.enums import Ats, JobSource

SR_API = "https://api.smartrecruiters.com/v1/companies"
SR_JOBS = "https://jobs.smartrecruiters.com"
PAGE_SIZE = 100
PAGES_PER_SEARCH = 2
PAGES_UNFILTERED = 5
MAX_SEARCHES = 4


def posting_url(company_id: str, posting_id: str, title: str = "") -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return f"{SR_JOBS}/{company_id}/{posting_id}" + (f"-{slug}" if slug else "")


def _location(loc: dict[str, Any]) -> str | None:
    full = (loc.get("fullLocation") or "").strip()
    if not full:
        full = ", ".join(str(p).strip() for p in (loc.get("city"), loc.get("region"), loc.get("country")) if p and str(p).strip())
    return full or None


def parse_smartrecruiters_posting(data: dict[str, Any], *, slug: str, company_name: str | None = None) -> DiscoveredJob:
    title = (data.get("name") or "").strip()
    loc = data.get("location") or {}
    location = _location(loc)
    explicit = "remote" if loc.get("remote") else "hybrid" if loc.get("hybrid") else None
    remote = infer_remote(location, title, explicit=explicit)
    pid = str(data.get("id")) if data.get("id") is not None else None
    company = data.get("company") or {}
    url = data.get("postingUrl") or (posting_url(company.get("identifier") or slug, pid, title) if pid else None)
    token = f"smartrecruiters:{slug}"
    return DiscoveredJob(
        source=JobSource.CAREERS,
        company_name=(company_name or company.get("name") or slug).strip(),
        title=title,
        apply_url=data.get("applyUrl") or url,
        source_url=url,
        ats=Ats.OTHER,
        external_id=pid,
        location=location,
        remote=remote,
        posted_at=parse_datetime(data.get("releasedDate")),
        board_token=token,
        raw={
            "board_token": token,
            "provider": "smartrecruiters",
            "posting_id": pid,
            "ref_number": data.get("refNumber"),
            "department": (data.get("department") or {}).get("label"),
            "employment_type": (data.get("typeOfEmployment") or {}).get("label"),
            "experience_level": (data.get("experienceLevel") or {}).get("label"),
        },
    )


def apply_detail(job: DiscoveredJob, detail: dict[str, Any]) -> DiscoveredJob:
    """Fill the description (job ad sections) and the canonical URLs from a posting detail."""
    if not isinstance(detail, dict):
        return job
    sections = ((detail.get("jobAd") or {}).get("sections") or {})
    parts: list[str] = []
    for key in ("jobDescription", "qualifications", "additionalInformation", "companyDescription"):
        sec = sections.get(key) or {}
        text = html_to_text(sec.get("text"))
        if text:
            heading = (sec.get("title") or "").strip()
            parts.append(f"{heading}\n{text}".strip() if heading else text)
    if parts:
        job.description = "\n\n".join(parts)
        if job.salary_min is None and job.salary_max is None:
            job.salary_min, job.salary_max, job.salary_currency = parse_salary_text(job.description)
    if detail.get("postingUrl"):
        job.source_url = detail["postingUrl"]
        job.apply_url = detail["postingUrl"]
    return job


async def fetch_smartrecruiters_board(
    http: httpx.AsyncClient,
    slug: str,
    *,
    company_name: str | None = None,
    search_terms: Iterable[str] = (),
    pages_per_search: int = PAGES_PER_SEARCH,
    pages_unfiltered: int = PAGES_UNFILTERED,
    api_base: str = SR_API,
) -> list[DiscoveredJob]:
    terms = [t.strip() for t in search_terms if t and t.strip()][:MAX_SEARCHES] or [""]
    out: dict[str, DiscoveredJob] = {}
    for term in terms:
        pages = pages_per_search if term else pages_unfiltered
        for page in range(max(1, pages)):
            params: dict[str, Any] = {"limit": PAGE_SIZE, "offset": page * PAGE_SIZE}
            if term:
                params["q"] = term
            data = await fetch_json(http, f"{api_base}/{slug}/postings", params=params)
            content = data.get("content") if isinstance(data, dict) else None
            if not isinstance(content, list):
                raise ValueError(f"smartrecruiters board {slug!r}: unexpected response shape")
            for p in content:
                pid = str(p.get("id") or "")
                if pid and p.get("name") and pid not in out:
                    out[pid] = parse_smartrecruiters_posting(p, slug=slug, company_name=company_name)
            total = data.get("totalFound") if isinstance(data.get("totalFound"), int) else None
            if len(content) < PAGE_SIZE or (total is not None and (page + 1) * PAGE_SIZE >= total):
                break
    return list(out.values())


async def fetch_smartrecruiters_detail(http: httpx.AsyncClient, slug: str, job: DiscoveredJob,
                                       *, api_base: str = SR_API) -> DiscoveredJob:
    if not job.external_id:
        return job
    return apply_detail(job, await fetch_json(http, f"{api_base}/{slug}/postings/{job.external_id}"))


__all__ = [
    "apply_detail",
    "fetch_smartrecruiters_board",
    "fetch_smartrecruiters_detail",
    "parse_smartrecruiters_posting",
    "posting_url",
]
