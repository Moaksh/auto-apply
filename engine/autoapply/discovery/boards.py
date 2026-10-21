"""Public ATS boards beyond Greenhouse / Lever / Ashby: Workday, SmartRecruiters, Workable, Recruitee.

Owner: Workstream A (engine core).

Every board here is a free, no-login JSON API (see each provider module). How a watched company
names its board, without any schema change (``companies.ats`` has a CHECK constraint):

==================  ===========  ======================================================
provider            ``ats``      ``board_token``
==================  ===========  ======================================================
Workday             ``workday``  ``"{tenant}.{instance}/{site}"`` (``"nvidia.wd5/NVIDIAExternalCareerSite"``)
SmartRecruiters     ``other``    ``"smartrecruiters:{companyIdentifier}"``
Workable            ``other``    ``"workable:{account slug}"``
Recruitee           ``other``    ``"recruitee:{subdomain}"``
==================  ===========  ======================================================

(``ats`` may also be NULL for the prefixed tokens: :func:`base.persist_discovered` never stores
``other``.) :func:`base.detect_ats` produces exactly these tokens from apply / board URLs, so a
Google Jobs listing that points at such a board can auto-watch the company like a Greenhouse one.

* :func:`board_provider` / :func:`is_readable_board` — does ``(ats, token)`` name a board we can read
  (Greenhouse / Lever / Ashby included)?
* :func:`read_board` — every posting on one board (used by the company finder to verify a board).
* :class:`WorkdaySource`, :class:`SmartRecruitersSource`, :class:`WorkableSource`,
  :class:`RecruiteeSource` — discovery sources for watched companies. They run with the career-page
  toggle (``enabled_key = "careers"``) and label their jobs ``source = careers`` (``jobs.source``'s
  CHECK has no value per provider). Postings that pass the title filter get their description from
  the board's detail endpoint (Workday / SmartRecruiters / Workable; Recruitee lists it inline).
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Iterable
from typing import Any

import httpx

from autoapply.discovery import recruitee as _recruitee
from autoapply.discovery import smartrecruiters as _sr
from autoapply.discovery import workable as _workable
from autoapply.discovery import workday as _workday
from autoapply.discovery.base import (
    DiscoveredJob,
    DiscoveryContext,
    gather_per_company,
    split_provider_token,
    split_workday_token,
    wanted_title,
)
from autoapply.enums import Ats
from autoapply.models import Company

log = logging.getLogger("autoapply.discovery.boards")

#: Providers read here (on top of greenhouse / lever / ashby).
PROVIDERS = ("workday", "smartrecruiters", "workable", "recruitee")
_CORE = {Ats.GREENHOUSE: "greenhouse", Ats.LEVER: "lever", Ats.ASHBY: "ashby"}
#: Detail requests per company and run (only for postings that passed the title filter).
DETAIL_LIMIT = 20


def _ats(value: Any) -> Ats | None:
    try:
        return Ats(value) if value else None
    except ValueError:
        return None


def board_provider(ats: Ats | str | None, token: str | None) -> str | None:
    """The reader for ``(ats, board_token)``: ``greenhouse`` / ``lever`` / ``ashby`` / ``workday`` /
    ``smartrecruiters`` / ``workable`` / ``recruitee``, or None (no public board we can read)."""
    if not token:
        return None
    a = _ats(ats)
    if a in _CORE:
        return _CORE[a]
    if a is Ats.WORKDAY:
        return "workday" if split_workday_token(token) else None
    if a in (None, Ats.OTHER):
        parsed = split_provider_token(token)
        return parsed[0] if parsed else None
    return None


def is_readable_board(ats: Ats | str | None, token: str | None) -> bool:
    return board_provider(ats, token) is not None


def _slug(token: str) -> str:
    parsed = split_provider_token(token)
    return parsed[1] if parsed else token


async def read_board(
    http: httpx.AsyncClient,
    ats: Ats | str | None,
    token: str,
    company_name: str | None = None,
    *,
    search_terms: Iterable[str] = (),
) -> list[DiscoveredJob]:
    """Postings on one public board (raises for an unreadable token or a failing board)."""
    provider = board_provider(ats, token)
    if provider == "workday":
        return await _workday.fetch_workday_board(http, token, company_name=company_name, search_terms=search_terms)
    if provider == "smartrecruiters":
        return await _sr.fetch_smartrecruiters_board(http, _slug(token), company_name=company_name, search_terms=search_terms)
    if provider == "workable":
        return await _workable.fetch_workable_board(http, _slug(token), company_name=company_name)
    if provider == "recruitee":
        return await _recruitee.fetch_recruitee_board(http, _slug(token), company_name=company_name)
    if provider is not None:
        from autoapply.discovery.careers import _BOARD_FETCHERS

        return await _BOARD_FETCHERS[Ats(provider)](http, token, company_name)
    raise ValueError(f"no public board reader for {getattr(ats, 'value', ats)!r} / {token!r}")


async def _detail(http: httpx.AsyncClient, provider: str, token: str, job: DiscoveredJob) -> DiscoveredJob:
    if provider == "workday":
        return await _workday.fetch_workday_detail(http, token, job)
    if provider == "smartrecruiters":
        return await _sr.fetch_smartrecruiters_detail(http, _slug(token), job)
    if provider == "workable":
        return await _workable.fetch_workable_detail(http, _slug(token), job)
    return job


async def fill_details(http: httpx.AsyncClient, provider: str, token: str, jobs: list[DiscoveredJob],
                       *, limit: int = DETAIL_LIMIT, concurrency: int = 4) -> list[DiscoveredJob]:
    """Fetch the detail document of the first ``limit`` jobs; a failing detail keeps the listing as is."""
    sem = asyncio.Semaphore(max(1, concurrency))

    async def one(job: DiscoveredJob) -> None:
        async with sem:
            try:
                await _detail(http, provider, token, job)
            except Exception as e:  # noqa: BLE001 - the listing is still worth keeping
                log.debug("%s detail failed for %s: %s", provider, job.source_url, e)

    await asyncio.gather(*(one(j) for j in jobs[: max(0, limit)]))
    return jobs


class PublicBoardSource:
    """Implements :class:`autoapply.discovery.base.Source` for watched companies on one provider.

    ``name`` is the provider (a plain string: ``jobs.source`` has no value for it, so the jobs
    themselves say ``careers``); the source follows the ``careers`` toggle."""

    provider = ""
    enabled_key = "careers"

    def __init__(self, *, concurrency: int = 4, detail_limit: int = DETAIL_LIMIT) -> None:
        self.name = self.provider
        self.concurrency = concurrency
        self.detail_limit = detail_limit

    def companies(self, ctx: DiscoveryContext) -> list[Company]:
        return [c for c in ctx.companies if board_provider(c.ats, c.board_token) == self.provider]

    async def fetch_company(self, ctx: DiscoveryContext, company: Company) -> list[DiscoveredJob]:
        assert company.board_token
        roles = list(ctx.preferences.roles) if ctx.filter_roles else []
        jobs = await read_board(ctx.http, company.ats, company.board_token, company.name, search_terms=roles)
        jobs = [j for j in jobs if wanted_title(ctx, j.title)]
        if ctx.limit_per_company is not None:
            jobs = jobs[: ctx.limit_per_company]
        return await fill_details(ctx.http, self.provider, company.board_token, jobs, limit=self.detail_limit)

    async def discover(self, ctx: DiscoveryContext) -> list[DiscoveredJob]:
        return await gather_per_company(
            ctx, self.companies(ctx), lambda c: self.fetch_company(ctx, c), concurrency=self.concurrency, source=self.provider
        )


class WorkdaySource(PublicBoardSource):
    provider = "workday"


class SmartRecruitersSource(PublicBoardSource):
    provider = "smartrecruiters"


class WorkableSource(PublicBoardSource):
    provider = "workable"


class RecruiteeSource(PublicBoardSource):
    provider = "recruitee"


#: The sources ``daemon.default_sources`` registers.
BOARD_SOURCES = (WorkdaySource, SmartRecruitersSource, WorkableSource, RecruiteeSource)

__all__ = [
    "BOARD_SOURCES",
    "PROVIDERS",
    "PublicBoardSource",
    "RecruiteeSource",
    "SmartRecruitersSource",
    "WorkableSource",
    "WorkdaySource",
    "board_provider",
    "fill_details",
    "is_readable_board",
    "read_board",
]
