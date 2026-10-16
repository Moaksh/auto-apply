"""Google Jobs (READ-ONLY): the "Jobs" tab of Google Search aggregates postings from company career
sites, ATSs, LinkedIn, Glassdoor, Indeed and smaller boards.

One result page holds ~40 postings *with* their full description (inside ``<template>`` panes),
so unlike LinkedIn/Glassdoor no per-job detail page is opened: the only extra page visit per new
job is following its best "Apply on …" link to learn the real apply URL. No login is needed.

Google answers headless/automated traffic with a CAPTCHA ("/sorry/"), so this runs in the same
visible, human-paced Chrome window as the other sites; a CAPTCHA stops the session and asks you.
All DOM knowledge is in :data:`GOOGLE_SELECTORS` and the small parser below.
"""

from __future__ import annotations

import re
from datetime import timedelta
from urllib.parse import quote_plus, urljoin

from bs4 import NavigableString
from bs4.element import TemplateString

from autoapply.config import Preferences
from autoapply.discovery.linkedin import (
    BrowserListingBase,
    JobDetail,
    ListingCard,
    _soup,
    clean_text,
    is_host,
    strip_tracking,
)
from autoapply.enums import Ats, CapKind, JobSource
from autoapply.models import utcnow

GOOGLE_BASE = "https://www.google.com"
GOOGLE_HOSTS = ("google.com", "www.google.com", "google.co.in")
#: Google's posting-date chips, narrowest first.
GOOGLE_WINDOWS = ("today", "3days", "week", "month")
#: Sessions per day (no login, but Google rate-limits automated-looking traffic).
GOOGLE_SESSIONS_PER_DAY = 8

GOOGLE_SELECTORS: dict[str, list[str]] = {
    "job_pane": ["[data-encoded-docid][data-is-preview]"],
    "captcha": ["form#captcha-form", "#recaptcha", "div#infoDiv"],
    "login_wall": [],
}

#: Boards that only re-post (and often 404 or demand a sign-up): used only when nothing better exists.
_AGGREGATORS = re.compile(
    r"bebee|jooble|simplyhired|foundit|instahyre|getmereferred|hirist|startup jobs|talent\.com|jobrapido|adzuna|"
    r"learn4good|jora|ziprecruiter|careerjet|jobleads|whatjobs|trabajo|grabjobs|shine|timesjobs|apna|freshersworld|"
    r"jobsora|recruit\.net|expertini|jobted|neuvoo|monster|cutshort",
    re.I,
)
_BOARDS = re.compile(r"linkedin|glassdoor|indeed|naukri|wellfound|angellist|dice|built ?in", re.I)
_ATS_NAMES = re.compile(r"greenhouse|lever|ashby|workday|smartrecruiters|workable|icims|successfactors|taleo|jobvite|recruitee|teamtailor", re.I)
_AGO = re.compile(r"(\d+)\s*\+?\s*(minute|hour|day|week|month)s?\s+ago", re.I)
_MONEY = re.compile(r"[₹$€£]|\b(INR|USD|EUR|GBP|LPA|lakh|per (year|month|hour)|a year|an hour)\b", re.I)
_TEXT = (NavigableString, TemplateString)


def _apply_rank(label: str, company: str) -> int:
    """0 = the company's own site / an ATS, 1 = a major board, 2 = other, 3 = aggregator."""
    name = label.removeprefix("Apply on").strip().lower()
    co = company.lower()
    if _ATS_NAMES.search(name) or (co and (co[:12] in name or name[:12] in co)) or re.search(r"career|jobs \||\bjobs$", name):
        return 0
    if _BOARDS.search(name):
        return 1
    if _AGGREGATORS.search(name):
        return 3
    return 2


def parse_google_jobs(html: str, base_url: str = GOOGLE_BASE) -> list[ListingCard]:
    soup = _soup(html)
    cards: list[ListingCard] = []
    seen: set[str] = set()
    for pane in soup.select(GOOGLE_SELECTORS["job_pane"][0]):
        docid = pane.get("data-encoded-docid")
        if not docid or docid in seen:
            continue
        seen.add(docid)
        title = clean_text(pane.get("data-title"))
        if not title:
            continue
        # The visible card (title | company | location • via X | … | 2 days ago | Full-time) sits
        # next to the <template> that holds this pane.
        tmpl = pane.find_parent("template")
        wrap = tmpl.parent if tmpl is not None else None
        bits = [s.strip() for s in (wrap.find_all(string=True) if wrap else []) if s.strip() and not s.find_parent("template")]
        try:
            i = next(k for k, b in enumerate(bits) if b == title)
        except StopIteration:
            i = -1
        company = clean_text(bits[i + 1]) if 0 <= i < len(bits) - 1 else None
        loc_via = bits[i + 2] if 0 <= i < len(bits) - 2 else ""
        location, via = (loc_via.split("•", 1) + [""])[:2] if "•" in loc_via else (loc_via, "")
        location = clean_text(location)
        via = clean_text(re.sub(r"^\s*via\s+", "", via or "", flags=re.I))
        if not company:
            continue
        posted = next((b for b in bits if _AGO.search(b)), None)
        salary = next((b for b in bits[i + 3:] if _MONEY.search(b) and re.search(r"\d", b)), None) if i >= 0 else None

        options = []
        for a in pane.find_all("a", href=True):
            label = (a.get("title") or "").strip()
            if label.lower().startswith("apply on"):
                options.append((_apply_rank(label, company), label, urljoin(base_url, a["href"])))
        options.sort(key=lambda o: o[0])
        best = options[0] if options else None

        text = pane.get_text("\n", strip=True, types=_TEXT)
        if "Job description" in text:
            text = text[text.index("Job description") + len("Job description"):].strip()
        detail = JobDetail(
            title=title, company=company, location=location, description=text or None,
            apply_redirect=best[2] if best else None, salary_text=salary,
        )
        detail.workplace = "remote" if re.search(r"work from home|remote", " ".join(bits), re.I) else None
        cards.append(ListingCard(
            title=title, company=company, location=location, detail_url=None, external_id=f"g:{docid}",
            salary_text=salary, detail=detail,
            extra={"via": via, "posted": posted, "apply_label": best[1] if best else None,
                   "apply_rank": best[0] if best else None},
        ))
    return cards


def posted_from_ago(text: str | None):
    m = _AGO.search(text or "")
    if not m:
        return None
    n, unit = int(m.group(1)), m.group(2).lower()
    delta = {"minute": timedelta(minutes=n), "hour": timedelta(hours=n), "day": timedelta(days=n),
             "week": timedelta(weeks=n), "month": timedelta(days=30 * n)}[unit]
    return utcnow() - delta


def google_search_url(prefs: Preferences, role: str, location: str, window: int = 0, page: int = 0) -> str:
    q = f"{role} jobs" + (f" in {location}" if location else "")
    remote = {p.value if hasattr(p, "value") else p for p in prefs.remote_policy} == {"remote"}
    if remote:
        q += " remote"
    chip = GOOGLE_WINDOWS[min(window, len(GOOGLE_WINDOWS) - 1)]
    return f"{GOOGLE_BASE}/search?q={quote_plus(q)}&udm=8&hl=en&htichips=date_posted:{chip}"


class GoogleJobsSource(BrowserListingBase):
    """Implements :class:`autoapply.discovery.base.Source` (read-only Google Jobs listings)."""

    name = JobSource.GOOGLE
    source_key = "google"
    display_name = "Google Jobs"
    cap_kind = CapKind.GOOGLE_BUDGET
    hosts = GOOGLE_HOSTS
    login_url = GOOGLE_BASE
    home_url = GOOGLE_BASE
    selectors = GOOGLE_SELECTORS
    captcha_url_markers = ("/sorry/",)
    captcha_title_markers = ("unusual traffic",)
    easy_apply_ats = Ats.OTHER
    date_windows = GOOGLE_WINDOWS
    max_pages = 1
    tabs = 2
    prefilter_titles = True  # Google matches loosely; don't open apply links for unrelated titles

    def sessions_limit(self, prefs: Preferences) -> int:
        return GOOGLE_SESSIONS_PER_DAY

    def search_url(self, prefs: Preferences, role: str, location: str, window: int, page: int) -> str:
        return google_search_url(prefs, role, location, window, page)

    def parse_search(self, html: str, base_url: str) -> list[ListingCard]:
        return parse_google_jobs(html, base_url)

    def parse_detail(self, html: str, base_url: str) -> JobDetail:
        return JobDetail()  # never used: result cards carry the full posting

    def build_job(self, card: ListingCard, detail: JobDetail | None):
        job = super().build_job(card, detail)
        if job is None:
            return None
        meta = card.extra
        job.posted_at = posted_from_ago(meta.get("posted"))
        job.raw = {**(job.raw or {}), "via": meta.get("via"), "apply_label": meta.get("apply_label")}
        url = job.apply_url
        # A LinkedIn/Glassdoor/Indeed page is not an application form: list it for you to apply
        # manually (like Easy Apply) rather than handing a job board to the form filler.
        if url and (is_host(url, ("linkedin.com", "glassdoor.com", "glassdoor.co.in", "indeed.com", "naukri.com"))
                    or (meta.get("apply_rank") or 0) >= 3):
            job.source_url = strip_tracking(url)
            job.apply_url = None
            job.easy_apply = True
            job.ats = Ats.OTHER
        elif url is None:
            job.easy_apply = False
        return job


__all__ = ["GOOGLE_SELECTORS", "GoogleJobsSource", "google_search_url", "parse_google_jobs", "posted_from_ago"]
