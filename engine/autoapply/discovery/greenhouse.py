"""Greenhouse public board API.

Owner: Workstream A (engine core).

* Listing: ``GET https://boards-api.greenhouse.io/v1/boards/{token}/jobs?content=true``
  -> ``{"jobs": [{id, title, absolute_url, location{name}, content (entity-escaped HTML),
  updated_at, first_published, company_name, departments, offices, metadata}], "meta": {...}}``
* Per-job form: ``GET .../jobs/{id}?questions=true&pay_transparency=true`` -> adds
  ``questions``, ``location_questions``, ``compliance`` (EEOC), ``demographic_questions``
  and ``pay_input_ranges``. Used by the apply adapter / Prep pass, never by listing.

Read-only; no auth; nothing is ever posted.
"""

from __future__ import annotations

import re
from typing import Any

import httpx

from autoapply.discovery.base import (
    DiscoveredJob,
    DiscoveryContext,
    companies_for,
    fetch_json,
    gather_per_company,
    html_to_text,
    infer_remote,
    parse_datetime,
    parse_salary_text,
)
from autoapply.enums import Ats, FieldType, JobSource
from autoapply.models import Company, FormQuestion

GREENHOUSE_API = "https://boards-api.greenhouse.io/v1/boards"
GREENHOUSE_HOSTED = "https://job-boards.greenhouse.io"


def hosted_job_url(token: str, job_id: str | int) -> str:
    """The Greenhouse-hosted posting/application page (works even when the company's
    ``absolute_url`` points at its own careers site)."""
    return f"{GREENHOUSE_HOSTED}/{token}/jobs/{job_id}"


def embed_application_url(token: str, job_id: str | int) -> str:
    """The bare Greenhouse application form (what company career pages load in an iframe).

    Unlike :func:`hosted_job_url`, this never redirects to the company's own site — boards
    with a custom careers URL 302 the hosted page there, leaving the form inside an iframe.
    """
    return f"{GREENHOUSE_HOSTED}/embed/job_app?for={token}&token={job_id}"


def _salary_from_pay_ranges(ranges: list[dict[str, Any]] | None) -> tuple[int | None, int | None, str | None]:
    if not ranges:
        return None, None, None
    lows = [r.get("min_cents") for r in ranges if r.get("min_cents") is not None]
    highs = [r.get("max_cents") for r in ranges if r.get("max_cents") is not None]
    cur = next((r.get("currency_type") for r in ranges if r.get("currency_type")), None)
    lo = int(min(lows) // 100) if lows else None
    hi = int(max(highs) // 100) if highs else None
    return lo, hi, cur


def parse_greenhouse_job(data: dict[str, Any], *, token: str, company_name: str | None = None) -> DiscoveredJob:
    """One element of the board ``jobs`` array (or a job detail) -> :class:`DiscoveredJob`."""
    title = (data.get("title") or "").strip()
    location = ((data.get("location") or {}).get("name") or "").strip() or None
    description = html_to_text(data.get("content"), unescape_first=True) or None
    lo, hi, cur = _salary_from_pay_ranges(data.get("pay_input_ranges"))
    if lo is None and hi is None:
        lo, hi, cur = parse_salary_text(description)
    offices = [o.get("name") for o in data.get("offices") or [] if o.get("name")]
    departments = [d.get("name") for d in data.get("departments") or [] if d.get("name")]
    job_id = str(data.get("id")) if data.get("id") is not None else None
    absolute_url = data.get("absolute_url") or (hosted_job_url(token, job_id) if job_id else None)
    return DiscoveredJob(
        source=JobSource.GREENHOUSE,
        company_name=(company_name or data.get("company_name") or token).strip(),
        title=title,
        apply_url=absolute_url,
        source_url=absolute_url,
        ats=Ats.GREENHOUSE,
        external_id=job_id,
        location=location,
        remote=infer_remote(location, title),
        salary_min=lo,
        salary_max=hi,
        salary_currency=cur,
        description=description,
        posted_at=parse_datetime(data.get("first_published") or data.get("updated_at")),
        board_token=token,
        raw={
            "board_token": token,
            "job_id": job_id,
            "internal_job_id": data.get("internal_job_id"),
            "requisition_id": data.get("requisition_id"),
            "hosted_url": hosted_job_url(token, job_id) if job_id else None,
            "departments": departments,
            "offices": offices,
            "updated_at": data.get("updated_at"),
        },
    )


async def fetch_board(
    http: httpx.AsyncClient, token: str, *, company_name: str | None = None, api_base: str = GREENHOUSE_API
) -> list[DiscoveredJob]:
    data = await fetch_json(http, f"{api_base}/{token}/jobs", params={"content": "true"})
    jobs = data.get("jobs") if isinstance(data, dict) else None
    if not isinstance(jobs, list):
        raise ValueError(f"greenhouse board {token!r}: unexpected response shape")
    return [parse_greenhouse_job(j, token=token, company_name=company_name) for j in jobs if j.get("title")]


# ---- application form questions -------------------------------------------------------

_GH_TYPE = {
    "input_text": FieldType.TEXT,
    "textarea": FieldType.TEXTAREA,
    "input_file": FieldType.FILE,
    "multi_value_single_select": FieldType.SELECT,
    "multi_value_multi_select": FieldType.MULTISELECT,
    "input_hidden": None,
}


def _refine_text_type(name: str, label: str, ft: FieldType) -> FieldType:
    if ft is not FieldType.TEXT:
        return ft
    s = f"{name} {label}".lower()
    if "email" in s:
        return FieldType.EMAIL
    if "phone" in s:
        return FieldType.PHONE
    if re.search(r"linkedin|github|website|portfolio|url\b", s):
        return FieldType.URL
    return ft


def _question_from_fields(q: dict[str, Any], *, key_prefix: str = "") -> FormQuestion | None:
    fields = [f for f in q.get("fields") or [] if _GH_TYPE.get(f.get("type"), FieldType.TEXT) is not None]
    if not fields:
        return None
    primary = fields[0]
    label = html_to_text(q.get("label") or primary.get("name") or "", unescape_first=True) or primary.get("name", "")
    ft = _GH_TYPE.get(primary.get("type"), FieldType.TEXT) or FieldType.TEXT
    name = f"{key_prefix}{primary.get('name')}"
    options = [str(v.get("label")) for v in primary.get("values") or [] if v.get("label") is not None]
    if ft is FieldType.SELECT and sorted(o.lower() for o in options) == ["no", "yes"]:
        pass  # keep SELECT with options; adapters handle yes/no
    description = html_to_text(q.get("description"), unescape_first=True) or None
    return FormQuestion(
        key=name,
        label=label,
        field_type=_refine_text_type(name, label, ft),
        required=bool(q.get("required")),
        options=options,
        description=description,
    )


def parse_greenhouse_questions(data: dict[str, Any]) -> list[FormQuestion]:
    """Job detail (``?questions=true``) -> every form question, in page order:
    standard + custom questions, location questions, EEOC compliance, demographics."""
    out: list[FormQuestion] = []
    for q in (data.get("questions") or []) + (data.get("location_questions") or []):
        fq = _question_from_fields(q)
        if fq:
            out.append(fq)
    for block in data.get("compliance") or []:
        for q in block.get("questions") or []:
            fq = _question_from_fields(q)
            if fq:
                out.append(fq)
    demo = data.get("demographic_questions") or {}
    for q in demo.get("questions") or [] if isinstance(demo, dict) else []:
        opts = [str(o.get("label")) for o in q.get("answer_options") or [] if o.get("label")]
        qtype = q.get("type") or "multi_value_single_select"
        out.append(
            FormQuestion(
                key=f"demographic_{q.get('id')}",
                label=html_to_text(q.get("label") or "", unescape_first=True),
                field_type=FieldType.MULTISELECT if "multi_select" in qtype else FieldType.SELECT,
                required=bool(q.get("required")),
                options=opts,
            )
        )
    return out


async def fetch_greenhouse_questions(
    http: httpx.AsyncClient, token: str, job_id: str | int, *, api_base: str = GREENHOUSE_API
) -> list[FormQuestion]:
    data = await fetch_json(http, f"{api_base}/{token}/jobs/{job_id}", params={"questions": "true", "pay_transparency": "true"})
    if not isinstance(data, dict):
        raise ValueError("greenhouse job detail: unexpected response shape")
    return parse_greenhouse_questions(data)


class GreenhouseSource:
    """Implements :class:`autoapply.discovery.base.Source` for watchlist companies whose
    ``ats == greenhouse`` and ``board_token`` is set."""

    name = JobSource.GREENHOUSE

    def __init__(self, *, api_base: str = GREENHOUSE_API, concurrency: int = 4) -> None:
        self.api_base = api_base
        self.concurrency = concurrency

    async def fetch_company(self, http: httpx.AsyncClient, company: Company) -> list[DiscoveredJob]:
        assert company.board_token
        return await fetch_board(http, company.board_token, company_name=company.name, api_base=self.api_base)

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        companies = companies_for(ctx, Ats.GREENHOUSE)
        return await gather_per_company(
            ctx, companies, lambda c: self.fetch_company(ctx.http, c), concurrency=self.concurrency, source="greenhouse"
        )
