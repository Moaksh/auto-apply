"""Recruitee public offers API.

Owner: Workstream A (engine core).

``GET https://{slug}.recruitee.com/api/offers/`` -> ``{"offers": [{id, slug, title, status,
careers_url, careers_apply_url, company_name, department, location, city, country, locations[{city,
country, name}], remote, hybrid, on_site (booleans), description, requirements (HTML),
salary{min, max, period, currency}, employment_type_code, published_at, created_at}]}``. One request
returns every published offer with its full text, so there is no detail call.

Board token: ``"recruitee:{slug}"`` on a company with ``ats = 'other'``. Read-only; nothing is ever
submitted.
"""

from __future__ import annotations

from typing import Any

import httpx

from autoapply.discovery.base import (
    DiscoveredJob,
    annualize,
    fetch_json,
    html_to_text,
    infer_remote,
    parse_datetime,
    parse_salary_text,
)
from autoapply.enums import Ats, JobSource


def offers_url(slug: str) -> str:
    return f"https://{slug}.recruitee.com/api/offers/"


def _location(data: dict[str, Any]) -> str | None:
    names: list[str] = []
    for loc in data.get("locations") or []:
        if not isinstance(loc, dict):
            continue
        name = (loc.get("name") or "").strip()
        country = (loc.get("country") or "").strip()
        s = f"{name}, {country}" if name and country and country.lower() not in name.lower() else (name or country)
        if s and s not in names:
            names.append(s)
    if names:
        return " · ".join(names)
    flat = (data.get("location") or "").strip()
    if flat:
        return flat
    return ", ".join(p for p in ((data.get("city") or "").strip(), (data.get("country") or "").strip()) if p) or None


def _salary(sal: dict[str, Any] | None) -> tuple[int | None, int | None, str | None]:
    if not sal or (sal.get("min") is None and sal.get("max") is None):
        return None, None, None
    period = str(sal.get("period") or "year")

    def num(v: Any) -> int | None:
        try:
            return annualize(float(v), period) if v not in (None, "") else None
        except (TypeError, ValueError):
            return None

    return num(sal.get("min")), num(sal.get("max")), sal.get("currency") or None


def parse_recruitee_offer(data: dict[str, Any], *, slug: str, company_name: str | None = None) -> DiscoveredJob:
    title = (data.get("title") or "").strip()
    location = _location(data)
    explicit = "remote" if data.get("remote") else "hybrid" if data.get("hybrid") else "onsite" if data.get("on_site") else None
    parts = [html_to_text(data.get("description")), html_to_text(data.get("requirements"))]
    description = "\n\n".join(p for p in parts if p) or None
    lo, hi, cur = _salary(data.get("salary"))
    if lo is None and hi is None:
        lo, hi, cur = parse_salary_text(description)
    if lo is not None and hi is not None and lo > hi:
        lo, hi = hi, lo
    page = data.get("careers_url") or (f"https://{slug}.recruitee.com/o/{data['slug']}" if data.get("slug") else None)
    token = f"recruitee:{slug}"
    return DiscoveredJob(
        source=JobSource.CAREERS,
        company_name=(company_name or data.get("company_name") or slug).strip(),
        title=title,
        apply_url=data.get("careers_apply_url") or page,
        source_url=page,
        ats=Ats.OTHER,
        external_id=str(data.get("id")) if data.get("id") is not None else None,
        location=location,
        remote=infer_remote(location, title, explicit=explicit),
        salary_min=lo,
        salary_max=hi,
        salary_currency=cur,
        description=description,
        posted_at=parse_datetime(_iso(data.get("published_at") or data.get("created_at"))),
        board_token=token,
        raw={
            "board_token": token,
            "provider": "recruitee",
            "offer_slug": data.get("slug"),
            "department": data.get("department"),
            "employment_type": data.get("employment_type_code"),
        },
    )


def _iso(value: Any) -> Any:
    """``"2026-10-15 09:31:36 UTC"`` -> ``"2026-10-15T09:31:36+00:00"`` (Recruitee's timestamp style)."""
    if isinstance(value, str) and value.endswith(" UTC"):
        return value[:-4].replace(" ", "T") + "+00:00"
    return value


async def fetch_recruitee_board(http: httpx.AsyncClient, slug: str, *, company_name: str | None = None,
                                url: str | None = None) -> list[DiscoveredJob]:
    data = await fetch_json(http, url or offers_url(slug))
    offers = data.get("offers") if isinstance(data, dict) else None
    if not isinstance(offers, list):
        raise ValueError(f"recruitee board {slug!r}: unexpected response shape")
    return [
        parse_recruitee_offer(o, slug=slug, company_name=company_name)
        for o in offers
        if o.get("title") and (o.get("status") in (None, "published"))
    ]


__all__ = ["fetch_recruitee_board", "offers_url", "parse_recruitee_offer"]
