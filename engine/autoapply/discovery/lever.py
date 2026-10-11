"""Lever postings API.

Owner: Workstream A (engine core).

``GET https://api.lever.co/v0/postings/{company}?mode=json`` (EU tenants:
``api.eu.lever.co``; we store those board tokens as ``eu:{company}``) -> a JSON array of
``{id, text, hostedUrl, applyUrl, categories{location, allLocations, commitment, team,
department}, workplaceType, country, createdAt (epoch ms), descriptionPlain, lists[{text,
content}], additionalPlain, salaryRange{min, max, currency, interval}}``.

Lever has no public application-form API; the adapter harvests questions from the page.
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

LEVER_API = "https://api.lever.co/v0/postings"
LEVER_API_EU = "https://api.eu.lever.co/v0/postings"


def split_token(token: str) -> tuple[str, str]:
    """``"eu:acme"`` -> (EU API base, "acme"); ``"acme"`` -> (global API base, "acme")."""
    if token.startswith("eu:"):
        return LEVER_API_EU, token[3:]
    return LEVER_API, token


def _interval(raw: str | None) -> str:
    r = (raw or "").lower()
    if "hour" in r:
        return "hour"
    if "month" in r:
        return "month"
    if "week" in r:
        return "week"
    return "year"


def parse_lever_posting(data: dict[str, Any], *, token: str, company_name: str | None = None) -> DiscoveredJob:
    cats = data.get("categories") or {}
    title = (data.get("text") or "").strip()
    all_locs = [loc for loc in cats.get("allLocations") or [] if loc]
    location = (cats.get("location") or (all_locs[0] if all_locs else "") or "").strip() or None
    # Description: opening/description + bullet lists + closing, as plain text.
    parts: list[str] = []
    desc = data.get("descriptionPlain") or html_to_text(data.get("description"))
    if desc:
        parts.append(desc.strip())
    for lst in data.get("lists") or []:
        heading = (lst.get("text") or "").strip()
        body = html_to_text(f"<ul>{lst.get('content') or ''}</ul>")
        if heading or body:
            parts.append(f"{heading}\n{body}".strip())
    extra = data.get("additionalPlain") or html_to_text(data.get("additional"))
    if extra:
        parts.append(extra.strip())
    description = "\n\n".join(parts).replace("\xa0", " ").strip() or None

    sr = data.get("salaryRange") or {}
    if sr.get("min") is not None or sr.get("max") is not None:
        iv = _interval(sr.get("interval"))
        lo = annualize(float(sr["min"]), iv) if sr.get("min") is not None else None
        hi = annualize(float(sr["max"]), iv) if sr.get("max") is not None else None
        cur = sr.get("currency") or None
    else:
        lo, hi, cur = parse_salary_text(description)

    workplace = data.get("workplaceType")
    remote = infer_remote(location, title, explicit=workplace if workplace and workplace != "unspecified" else None)
    hosted = data.get("hostedUrl")
    apply_url = data.get("applyUrl") or (f"{hosted.rstrip('/')}/apply" if hosted else None)
    return DiscoveredJob(
        source=JobSource.LEVER,
        company_name=(company_name or token.removeprefix("eu:")).strip(),
        title=title,
        apply_url=apply_url,
        source_url=hosted or apply_url,
        ats=Ats.LEVER,
        external_id=str(data.get("id")) if data.get("id") else None,
        location=location,
        remote=remote,
        salary_min=lo,
        salary_max=hi,
        salary_currency=cur,
        description=description,
        posted_at=parse_datetime(data.get("createdAt")),
        board_token=token,
        raw={
            "board_token": token,
            "posting_id": data.get("id"),
            "hosted_url": hosted,
            "commitment": cats.get("commitment"),
            "team": cats.get("team"),
            "department": cats.get("department"),
            "all_locations": all_locs,
            "country": data.get("country"),
            "workplace_type": workplace,
        },
    )


async def fetch_postings(http: httpx.AsyncClient, token: str, *, company_name: str | None = None, api_base: str | None = None) -> list[DiscoveredJob]:
    base, slug = split_token(token)
    data = await fetch_json(http, f"{api_base or base}/{slug}", params={"mode": "json"})
    if not isinstance(data, list):
        raise ValueError(f"lever board {token!r}: unexpected response shape")
    return [parse_lever_posting(p, token=token, company_name=company_name) for p in data if p.get("text")]


class LeverSource:
    """Implements :class:`autoapply.discovery.base.Source` for watchlist companies whose
    ``ats == lever`` and ``board_token`` is set."""

    name = JobSource.LEVER

    def __init__(self, *, api_base: str | None = None, concurrency: int = 4) -> None:
        self.api_base = api_base
        self.concurrency = concurrency

    async def fetch_company(self, http: httpx.AsyncClient, company: Company) -> list[DiscoveredJob]:
        assert company.board_token
        return await fetch_postings(http, company.board_token, company_name=company.name, api_base=self.api_base)

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        companies = companies_for(ctx, Ats.LEVER)
        return await gather_per_company(
            ctx, companies, lambda c: self.fetch_company(ctx.http, c), concurrency=self.concurrency, source="lever"
        )
