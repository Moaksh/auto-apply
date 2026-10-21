"""Company suggestions collected while browsing (Google Jobs, LinkedIn, Glassdoor apply links).

Every listing a browser source reads points somewhere: a public ATS board (Greenhouse / Lever /
Ashby) or a company's own career site. Companies that are not on the watchlist become
*suggestions* (``company_suggestions``) the user can Add or Dismiss in Settings ▸ Sources:

* an ATS board we can read is watched automatically while there is room
  (``MAX_WATCHED_COMPANIES``), recorded as status ``auto`` so it can be undone; past the cap it
  becomes a pending suggestion;
* a readable board also covers Workday (when the URL names the career site), SmartRecruiters,
  Workable and Recruitee (:mod:`autoapply.discovery.boards`);
* a plain career page (or an ATS without a public reader, e.g. iCIMS / Taleo) is
  never watched by itself: it is only suggested, with the guessed career-page URL that the
  career-page agents (:mod:`autoapply.discovery.careers_agent`) read once accepted;
* a company the user dismissed is never suggested or watched automatically again.

Everything here is best effort: :func:`note_listing` never raises into the pipeline.
"""

from __future__ import annotations

import logging
import re
import sqlite3
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from autoapply import db
from autoapply.discovery.base import DiscoveredJob, detect_ats, split_provider_token, split_workday_token
from autoapply.discovery.boards import is_readable_board
from autoapply.enums import Ats, SuggestionStatus
from autoapply.models import Company, CompanySuggestion

log = logging.getLogger("autoapply.discovery.suggestions")

#: Sources whose listings point at other companies' sites (the ones worth learning from).
BROWSER_SOURCES = frozenset({"linkedin", "glassdoor", "google"})
#: ATSs with a public board reader (``discovery.greenhouse`` / ``lever`` / ``ashby``). Workday and the
#: provider-prefixed ``other`` boards are readable too, depending on the token: see
#: :func:`autoapply.discovery.boards.is_readable_board`.
READABLE_ATS = (Ats.GREENHOUSE, Ats.LEVER, Ats.ASHBY)

#: Job boards / aggregators: an apply link there says nothing about the company's own site.
_BOARD_HOSTS = (
    "linkedin.com", "glassdoor.com", "glassdoor.co.in", "indeed.com", "naukri.com", "google.com", "wellfound.com",
    "angel.co", "dice.com", "builtin.com", "ziprecruiter.com", "monster.com", "simplyhired.com", "jooble.org",
    "bebee.com", "foundit.in", "instahyre.com", "cutshort.io", "hirist.tech", "hirist.com", "iimjobs.com", "talent.com",
    "careerjet.com", "adzuna.com", "jobrapido.com", "shine.com", "timesjobs.com", "apna.co", "lensa.com",
    "jobleads.com", "whatjobs.com", "learn4good.com", "jora.com", "expertini.com", "recruit.net", "jobted.com",
    "neuvoo.com", "jobsora.com", "grabjobs.co", "freshersworld.com", "getmereferred.com", "remoteok.com",
    "weworkremotely.com", "remotive.com", "himalayas.app", "otta.com", "welcometothejungle.com", "workatastartup.com",
    "ycombinator.com", "levels.fyi", "teal.com", "jobgether.com", "jobright.ai", "uplers.com", "turing.com",
)
_JOBISH_SEG = re.compile(r"^(careers?|jobs?|join(-us)?|work-with-us|opportunities|openings|positions|vacancies|en-us|en)$", re.I)


def _host(url: str) -> str:
    h = (urlsplit(url).hostname or "").lower()
    return h[4:] if h.startswith("www.") else h


def is_job_board(url: str | None) -> bool:
    h = _host(url or "")
    return not h or any(h == d or h.endswith("." + d) for d in _BOARD_HOSTS)


def careers_url_for(apply_url: str | None) -> str | None:
    """Best guess at the career-page URL behind a job's apply link (None for job boards).

    ``https://careers.acme.com/jobs/123-backend`` -> ``https://careers.acme.com/jobs``;
    ``https://jobs.smartrecruiters.com/Acme/7431-eng`` -> ``https://jobs.smartrecruiters.com/Acme``;
    ``https://acme.wd5.myworkdayjobs.com/en-US/External/job/X`` -> ``…/en-US/External``.
    """
    if not apply_url or is_job_board(apply_url):
        return None
    parts = urlsplit(apply_url)
    if parts.scheme not in ("http", "https"):
        return None
    host = (parts.hostname or "").lower()
    segs = [s for s in parts.path.split("/") if s]

    def build(path_segs: list[str]) -> str:
        return urlunsplit((parts.scheme, parts.netloc, "/" + "/".join(path_segs) if path_segs else "/", "", ""))

    # Multi-tenant ATS hosts: the tenant lives in the first path segment(s).
    if host in ("jobs.smartrecruiters.com", "careers.smartrecruiters.com", "jobs.jobvite.com", "apply.workable.com"):
        return build(segs[:1]) if segs else None
    if host.endswith((".myworkdayjobs.com", ".myworkdaysite.com")):
        if "job" in segs:
            return build(segs[: segs.index("job")])
        return build(segs[:2])
    if host.endswith((".icims.com", ".teamtailor.com")):
        return build(["jobs"])
    if host.endswith((".recruitee.com", ".bamboohr.com", ".breezy.hr", ".personio.de", ".personio.com")):
        return build(["careers"] if host.endswith(".bamboohr.com") else [])
    # A company's own site: keep the path up to the last "jobs"/"careers"-like segment.
    keep: list[str] = []
    for i, s in enumerate(segs[:4]):
        if _JOBISH_SEG.match(s):
            keep = segs[: i + 1]
    # Otherwise the site root (``careers.acme.com``); the career-page agent follows one
    # "open positions" link from there when the landing page lists nothing.
    return build(keep)


def board_url(ats: Ats, token: str) -> str:
    """Public board page for an ATS token (what the user sees in the suggestion)."""
    if ats is Ats.GREENHOUSE:
        return f"https://job-boards.greenhouse.io/{token}"
    if ats is Ats.LEVER:
        return f"https://jobs.eu.lever.co/{token[3:]}" if token.startswith("eu:") else f"https://jobs.lever.co/{token}"
    if ats is Ats.ASHBY:
        return f"https://jobs.ashbyhq.com/{token}"
    if ats is Ats.WORKDAY and (wd := split_workday_token(token)):
        return f"https://{wd[0]}/{wd[2]}"
    if (prov := split_provider_token(token)) is not None:
        provider, slug = prov
        if provider == "smartrecruiters":
            return f"https://jobs.smartrecruiters.com/{slug}"
        if provider == "workable":
            return f"https://apply.workable.com/{slug}/"
        if provider == "recruitee":
            return f"https://{slug}.recruitee.com/"
    return token


def board_enrichment(conn: sqlite3.Connection, dj: DiscoveredJob, *, room: bool) -> tuple[dict[str, Any], bool]:
    """Company fields to learn from a listing, and whether the agent watches the company by itself.

    A browser listing that links to a readable ATS board watches the company (free JSON every later
    run) while there is ``room`` under the watchlist cap, unless the user dismissed it."""
    enrich: dict[str, Any] = {}
    if dj.board_token and is_readable_board(dj.ats, dj.board_token):
        enrich = {"ats": dj.ats, "board_token": dj.board_token}
    auto = False
    if enrich and str(getattr(dj.source, "value", dj.source)) in BROWSER_SOURCES and room:
        existing = db.get_company_by_name(conn, dj.company_name)
        if not (existing and existing.watch) and not db.company_dismissed(conn, dj.company_name):
            enrich["watch"] = True
            auto = True
    return enrich, auto


def note_listing(
    conn: sqlite3.Connection, dj: DiscoveredJob, *, company: Company | None = None, created: bool = True, auto_watched: bool = False
) -> CompanySuggestion | None:
    """Record what a browser listing taught us about its company (see the module doc). Never raises."""
    try:
        return _note_listing(conn, dj, company=company, created=created, auto_watched=auto_watched)
    except Exception:  # noqa: BLE001 - a suggestion is never worth failing discovery over
        log.debug("could not record a suggestion for %s", dj.company_name, exc_info=True)
        return None


def _note_listing(
    conn: sqlite3.Connection, dj: DiscoveredJob, *, company: Company | None, created: bool, auto_watched: bool
) -> CompanySuggestion | None:
    source = str(getattr(dj.source, "value", dj.source))
    if source not in BROWSER_SOURCES or not dj.company_name:
        return None
    ats, token = dj.ats, dj.board_token
    if dj.apply_url and (ats is Ats.OTHER or not token):
        d_ats, d_tok = detect_ats(dj.apply_url)
        ats = ats if ats is not Ats.OTHER else d_ats
        token = token or d_tok
    via = f"{dj.title} ({source})"
    if auto_watched and is_readable_board(ats, token):
        return db.suggest_company(
            conn, dj.company_name, url=board_url(ats, token), source=source, ats=ats, board_token=token, found_via=via,
            sample_title=dj.title, add_matching=1 if created else 0, status=SuggestionStatus.AUTO,
            company_id=company.id if company else None,
        )
    if company is not None and company.watch:
        if created:  # keep the count of an auto-added company's roles current
            existing = db.get_company_suggestion_by_name(conn, dj.company_name)
            if existing is not None and existing.status is SuggestionStatus.AUTO:
                db.suggest_company(conn, dj.company_name, url=existing.url, source=existing.source, add_matching=1,
                                   status=SuggestionStatus.AUTO)
        return None
    if is_readable_board(ats, token):
        # Readable board but no room left on the watchlist: let the user decide.
        return db.suggest_company(
            conn, dj.company_name, url=board_url(ats, token), source=source, ats=ats, board_token=token, found_via=via,
            sample_title=dj.title, add_matching=1 if created else 0,
        )
    if company is not None and company.careers_url:
        return None  # the user already gave us its career page
    url = careers_url_for(dj.apply_url)
    if not url:
        return None
    return db.suggest_company(
        conn, dj.company_name, url=url, source=source, ats=ats if ats is not Ats.OTHER else None, board_token=token,
        found_via=via, sample_title=dj.title, add_matching=1 if created else 0,
    )


__all__ = [
    "BROWSER_SOURCES",
    "READABLE_ATS",
    "board_enrichment",
    "board_url",
    "careers_url_for",
    "is_job_board",
    "note_listing",
]
