"""Workday public job board (CXS) API.

Owner: Workstream A (engine core).

Every Workday career site (``https://{tenant}.{instance}.myworkdayjobs.com[/{locale}]/{site}``) is
backed by a no-login JSON API on the same host:

* Listing: ``POST https://{tenant}.{instance}.myworkdayjobs.com/wday/cxs/{tenant}/{site}/jobs``
  with ``{"appliedFacets": {}, "limit": 20, "offset": N, "searchText": "..."}`` (20 is the
  largest page the API accepts) -> ``{"total", "jobPostings": [{title, externalPath,
  locationsText, postedOn ("Posted 3 Days Ago"), bulletFields [req id], remoteType?}]}``.
  ``total`` is clamped at 2000 on big tenants, so we search by the user's roles
  (``searchText``) instead of paging through the whole board.
* Detail: ``GET .../wday/cxs/{tenant}/{site}{externalPath}`` -> ``{"jobPostingInfo":
  {jobDescription (HTML), location, additionalLocations, startDate, timeType, remoteType?,
  jobReqId, externalUrl}}``. Fetched only for postings that pass the title filter.

The board token is ``"{tenant}.{instance}/{site}"`` (see :func:`base.split_workday_token`).
Endpoint shapes were checked against career-ops' ``providers/workday.mjs`` (MIT) and a live
board. Read-only; nothing is ever submitted (Workday applications go through the agentic adapter).
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import unquote

import httpx

from autoapply.discovery.base import (
    DiscoveredJob,
    fetch_json,
    html_to_text,
    infer_remote,
    parse_datetime,
    post_json,
    split_workday_token,
)
from autoapply.enums import Ats, JobSource

PAGE_SIZE = 20  # the CXS API rejects larger pages (HTTP 400)
#: Pages read per search term (role) / for an unfiltered read.
PAGES_PER_SEARCH = 3
PAGES_UNFILTERED = 5
#: Roles searched per company and run.
MAX_SEARCHES = 4

_POSTED = re.compile(r"posted\s+(\d+)(\+?)\s*days?", re.I)
_N_LOCATIONS = re.compile(r"^\d+\s+locations?$", re.I)


def endpoints(token: str) -> tuple[str, str]:
    """``(api_base, site_url)`` for a full token: ``https://h/wday/cxs/t/s`` and ``https://h/s``."""
    parts = split_workday_token(token)
    if parts is None:
        raise ValueError(f"workday board {token!r}: needs '{{tenant}}.{{instance}}/{{site}}'")
    host, tenant, site = parts
    return f"https://{host}/wday/cxs/{tenant}/{site}", f"https://{host}/{site}"


def parse_posted_on(label: str | None, *, now: datetime | None = None) -> datetime | None:
    """``"Posted Today"`` / ``"Posted Yesterday"`` / ``"Posted 3 Days Ago"`` -> a date; ``"30+ Days"`` -> None."""
    if not label:
        return None
    now = now or datetime.now(UTC)
    low = label.lower()
    if "today" in low:
        return now
    if "yesterday" in low:
        return now - timedelta(days=1)
    m = _POSTED.search(label)
    if not m or m.group(2):
        return None
    return now - timedelta(days=int(m.group(1)))


def _location_from_path(external_path: str) -> str | None:
    m = re.search(r"/job/([^/]+)/", external_path or "")
    if not m:
        return None
    return unquote(m.group(1)).replace("-", " ").strip() or None


def _req_id(data: dict[str, Any]) -> str | None:
    path = str(data.get("externalPath") or "")
    tail = path.rstrip("/").rsplit("/", 1)[-1]
    if "_" in tail:
        return tail.rsplit("_", 1)[-1] or None
    bullets = [str(b) for b in data.get("bulletFields") or [] if b]
    return bullets[0] if bullets else None


def parse_workday_job(data: dict[str, Any], *, token: str, company_name: str | None = None,
                      now: datetime | None = None) -> DiscoveredJob:
    """One element of ``jobPostings`` -> :class:`DiscoveredJob` (no description yet)."""
    _, site_url = endpoints(token)
    title = (data.get("title") or "").strip()
    path = str(data.get("externalPath") or "")
    loc_text = (data.get("locationsText") or "").strip()
    location = loc_text if loc_text and not _N_LOCATIONS.match(loc_text) else (_location_from_path(path) or loc_text or None)
    url = f"{site_url}{path}" if path else site_url
    remote_type = data.get("remoteType")
    return DiscoveredJob(
        source=JobSource.CAREERS,
        company_name=(company_name or token.split(".", 1)[0]).strip(),
        title=title,
        apply_url=url,
        source_url=url,
        ats=Ats.WORKDAY,
        external_id=_req_id(data),
        location=location,
        remote=infer_remote(location, title, explicit=remote_type),
        posted_at=parse_posted_on(data.get("postedOn"), now=now),
        board_token=token,
        raw={
            "board_token": token,
            "provider": "workday",
            "external_path": path,
            "locations_text": loc_text or None,
            "posted_on": data.get("postedOn"),
            "remote_type": remote_type,
        },
    )


def apply_detail(job: DiscoveredJob, detail: dict[str, Any]) -> DiscoveredJob:
    """Fill description / date / location / remote from a ``jobPostingInfo`` detail document."""
    info = detail.get("jobPostingInfo") if isinstance(detail, dict) else None
    if not isinstance(info, dict):
        return job
    job.description = html_to_text(info.get("jobDescription")) or job.description
    started = parse_datetime(info.get("startDate"))
    if started is not None:
        job.posted_at = started
    extra = [str(x) for x in info.get("additionalLocations") or [] if x]
    if info.get("location"):
        job.location = str(info["location"]).strip()
    remote_type = info.get("remoteType")
    job.remote = infer_remote(job.location, job.title, *extra, explicit=remote_type) or job.remote
    job.raw = {**job.raw, "additional_locations": extra, "time_type": info.get("timeType"),
               "remote_type": remote_type or job.raw.get("remote_type")}
    if info.get("jobReqId"):
        job.external_id = str(info["jobReqId"])
    return job


async def fetch_workday_board(
    http: httpx.AsyncClient,
    token: str,
    *,
    company_name: str | None = None,
    search_terms: Iterable[str] = (),
    pages_per_search: int = PAGES_PER_SEARCH,
    pages_unfiltered: int = PAGES_UNFILTERED,
) -> list[DiscoveredJob]:
    """Postings on one Workday board: one search per term (or the newest postings when there
    are no terms), deduped by posting path."""
    api, _ = endpoints(token)
    terms = [t.strip() for t in search_terms if t and t.strip()][:MAX_SEARCHES] or [""]
    out: dict[str, DiscoveredJob] = {}
    now = datetime.now(UTC)
    for term in terms:
        pages = pages_per_search if term else pages_unfiltered
        for page in range(max(1, pages)):
            body = {"appliedFacets": {}, "limit": PAGE_SIZE, "offset": page * PAGE_SIZE, "searchText": term}
            data = await post_json(http, f"{api}/jobs", body)
            postings = data.get("jobPostings") if isinstance(data, dict) else None
            if not isinstance(postings, list):
                raise ValueError(f"workday board {token!r}: unexpected response shape")
            for p in postings:
                path = p.get("externalPath")
                if path and p.get("title") and path not in out:
                    out[path] = parse_workday_job(p, token=token, company_name=company_name, now=now)
            total = data.get("total") if isinstance(data.get("total"), int) else None
            if len(postings) < PAGE_SIZE or (total is not None and (page + 1) * PAGE_SIZE >= total):
                break
    return list(out.values())


async def fetch_workday_detail(http: httpx.AsyncClient, token: str, job: DiscoveredJob) -> DiscoveredJob:
    api, _ = endpoints(token)
    path = job.raw.get("external_path")
    if not path:
        return job
    return apply_detail(job, await fetch_json(http, f"{api}{path}"))


__all__ = [
    "apply_detail",
    "endpoints",
    "fetch_workday_board",
    "fetch_workday_detail",
    "parse_posted_on",
    "parse_workday_job",
]
