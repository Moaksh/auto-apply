"""Glassdoor READ-ONLY listing browser (visible Chrome, human pace). Never applies.

Owner: Workstream D (daemon & LinkedIn).

Same safety model as LinkedIn (see :mod:`autoapply.discovery.linkedin`): navigate + read
only, never click, daily session budget (``Preferences.glassdoor_sessions_per_day``),
login-wall / CAPTCHA detection stops the session and asks the user to log in.

Glassdoor "Apply on employer site" links are same-site redirects
(``/partner/jobListing.htm?...``); when ``resolve_redirects`` is on, the source follows the
redirect with a plain navigation (a GET, no click) to learn the company ATS URL.
Glassdoor's own "Easy Apply" listings have no external ATS, so they go to the manual
Easy Apply list like LinkedIn's.
"""

from __future__ import annotations

import re
from urllib.parse import quote_plus, urljoin

from autoapply.config import Preferences
from autoapply.discovery.linkedin import (
    BrowserListingBase,
    JobDetail,
    ListingCard,
    _soup,
    any_mentions,
    clean_text,
    is_host,
    select_all,
    select_first,
    strip_query,
    strip_tracking,
    text_of,
    unwrap_redirect,
)
from autoapply.enums import Ats, CapKind, JobSource, RemotePolicy

# =====================================================================================
# Selector table (the ONLY place Glassdoor DOM knowledge lives)
# =====================================================================================

GLASSDOOR_SELECTORS: dict[str, list[str]] = {
    "search_card": [
        "li[data-test='jobListing']",
        "li.react-job-listing",
        "article[data-test='job-card']",
        "li[data-jobid]",
    ],
    "card_title": [
        "a[data-test='job-title']",
        "a[data-test='job-link']",
        "a.jobLink",
        "[class*='JobCard_jobTitle']",
    ],
    "card_link": [
        "a[data-test='job-title'][href]",
        "a[data-test='job-link'][href]",
        "a.jobLink[href]",
        "a[href*='job-listing']",
    ],
    "card_company": [
        "[data-test='employer-name']",
        "[data-test='employer-short-name']",
        "[class*='EmployerProfile_compactEmployerName']",
        "div.job-search-key-l2wjgv",
    ],
    "card_location": [
        "[data-test='emp-location']",
        "[data-test='location']",
        "[class*='JobCard_location']",
    ],
    "card_salary": [
        "[data-test='detailSalary']",
        "[class*='JobCard_salaryEstimate']",
    ],
    "card_easy_apply": [
        "[data-test='easyApply']",
        "[class*='JobCard_easyApply']",
        "[class*='easyApply']",
    ],
    "detail_title": [
        "[data-test='job-title']",
        "h1[id^='jd-job-title']",
        "[class*='JobDetails_jobTitle']",
        "h1",
    ],
    "detail_company": [
        "[data-test='employerName']",
        "[data-test='employer-name']",
        "[class*='EmployerProfile_employerName']",
    ],
    "detail_location": [
        "[data-test='location']",
        "[data-test='emp-location']",
        "[class*='JobDetails_location']",
    ],
    "detail_salary": [
        "[data-test='detailSalary']",
        "[class*='SalaryEstimate_salaryRange']",
    ],
    "detail_description": [
        "[class*='JobDetails_jobDescription']",
        "#JobDescriptionContainer",
        "[data-test='jobDescriptionContent']",
        "div.jobDescriptionContent",
    ],
    "detail_apply_button": [
        "[data-test='applyButton']",
        "[data-test='easyApply']",
        "button[class*='applyButton']",
        "a[class*='applyButton']",
    ],
    "detail_apply_link": [
        "a[data-test='applyButton'][href]",
        "a[class*='applyButton'][href]",
        "a[href*='/partner/jobListing.htm']",
    ],
    "login_wall": [
        "#LoginModal",
        "[data-test='authModalContainer']",
        "form[name='emailForm']",
        "#HardsellOverlay",
        "input#inlineUserEmail",
    ],
    "captcha": [
        "#px-captcha",
        "iframe[src*='captcha']",
        "#challenge-form",
        "div.cf-browser-verification",
        "#cf-challenge-running",
    ],
    "logged_in": [
        "[data-test='user-profile-dropdown']",
        "[data-test='profile-container']",
        "a[href*='/member/profile']",
        "button[aria-label*='profile' i]",
    ],
}

GLASSDOOR_EASY_APPLY_TEXT: tuple[str, ...] = ("easy apply", "easyapply")
GLASSDOOR_HOSTS: tuple[str, ...] = ("glassdoor.com", "glassdoor.co.in", "glassdoor.co.uk", "glassdoor.ca")
GLASSDOOR_BASE = "https://www.glassdoor.com"
GLASSDOOR_LOGIN_URL = "https://www.glassdoor.com/profile/login_input.htm"
GLASSDOOR_HOME_URL = "https://www.glassdoor.com/Job/index.htm"

_GD_JOB_ID = re.compile(r"(?:[?&]jl=|[?&]jobListingId=|_JV_KO|JV_IC\d+_KO\d+,\d+_KE\d+,\d+\.htm\?jl=)(\d{5,})")


def glassdoor_job_id(*values: str | None) -> str | None:
    for v in values:
        if not v:
            continue
        if v.isdigit():
            return v
        m = _GD_JOB_ID.search(v)
        if m:
            return m.group(1)
    return None


def parse_glassdoor_search(html: str, base_url: str = GLASSDOOR_BASE) -> list[ListingCard]:
    sel = GLASSDOOR_SELECTORS
    soup = _soup(html)
    out: list[ListingCard] = []
    for card in select_all(soup, sel["search_card"]):
        title = text_of(card, sel["card_title"])
        company = text_of(card, sel["card_company"])
        if company:
            company = re.sub(r"\s*\d(?:\.\d)?\s*★?$", "", company).strip() or company  # trailing rating
        if not title or not company:
            continue
        link = select_first(card, sel["card_link"])
        href = urljoin(base_url, str(link.get("href"))) if link is not None and link.get("href") else None
        job_id = glassdoor_job_id(str(card.get("data-jobid") or card.get("data-id") or ""), href)
        easy = any_mentions(card, sel["card_easy_apply"], GLASSDOOR_EASY_APPLY_TEXT) or (
            select_first(card, ["[data-test='easyApply']"]) is not None
        )
        detail_url = None
        if href:
            detail_url = strip_query(href) + (f"?jl={job_id}" if job_id else "")
        out.append(
            ListingCard(
                title=title, company=company, location=text_of(card, sel["card_location"]),
                detail_url=detail_url, external_id=job_id, easy_apply=easy,
                salary_text=text_of(card, sel["card_salary"]),
            )
        )
    return out


def parse_glassdoor_detail(html: str, base_url: str = GLASSDOOR_BASE) -> JobDetail:
    sel = GLASSDOOR_SELECTORS
    soup = _soup(html)
    easy = select_first(soup, ["[data-test='easyApply']"]) is not None or any_mentions(
        soup, sel["detail_apply_button"], GLASSDOOR_EASY_APPLY_TEXT
    )
    apply_url: str | None = None
    redirect: str | None = None
    if not easy:
        link = select_first(soup, sel["detail_apply_link"])
        if link is not None and link.get("href"):
            cand = unwrap_redirect(urljoin(base_url, str(link.get("href"))))
            if cand and is_host(cand, GLASSDOOR_HOSTS):
                redirect = cand
            elif cand:
                apply_url = strip_tracking(cand)
    desc_el = select_first(soup, sel["detail_description"])
    company = text_of(soup, sel["detail_company"])
    if company:
        company = re.sub(r"\s*\d(?:\.\d)?\s*★?$", "", company).strip() or company
    return JobDetail(
        title=text_of(soup, sel["detail_title"]), company=company,
        location=text_of(soup, sel["detail_location"]),
        description=clean_text(desc_el.get_text("\n")) if desc_el is not None else None,
        easy_apply=easy, apply_url=apply_url, apply_redirect=redirect,
        salary_text=text_of(soup, sel["detail_salary"]),
    )


GLASSDOOR_WINDOWS = ("1", "7", "30")  # fromAge in days


def glassdoor_search_url(prefs: Preferences, role: str, location: str, window: int = 0, page: int = 0) -> str:
    u = f"{GLASSDOOR_BASE}/Job/jobs.htm?sc.keyword={quote_plus(role)}&fromAge={GLASSDOOR_WINDOWS[min(window, len(GLASSDOOR_WINDOWS) - 1)]}"
    if location:
        u += f"&locKeyword={quote_plus(location)}"
    if set(prefs.remote_policy) == {RemotePolicy.REMOTE}:
        u += "&remoteWorkType=1"
    return u


def glassdoor_search_urls(prefs: Preferences) -> list[str]:
    from autoapply.discovery.planner import SearchPlanner

    return [glassdoor_search_url(prefs, r, loc) for r, loc in SearchPlanner.combos(prefs)]


class GlassdoorSource(BrowserListingBase):
    """Implements :class:`autoapply.discovery.base.Source` (read-only Glassdoor listings)."""

    name = JobSource.GLASSDOOR
    source_key = "glassdoor"
    display_name = "Glassdoor"
    cap_kind = CapKind.GLASSDOOR_BUDGET
    hosts = GLASSDOOR_HOSTS
    login_url = GLASSDOOR_LOGIN_URL
    home_url = GLASSDOOR_HOME_URL
    selectors = GLASSDOOR_SELECTORS
    login_url_markers = ("/profile/login", "/member/login")
    auth_cookies = (("at", "glassdoor."),)
    captcha_url_markers = ("captcha", "/challenge")
    captcha_title_markers = ("just a moment", "security check", "are you a robot")
    easy_apply_ats = Ats.OTHER

    def sessions_limit(self, prefs: Preferences) -> int:
        return prefs.glassdoor_sessions_per_day

    date_windows = GLASSDOOR_WINDOWS
    max_pages = 1  # Glassdoor's result paging is click-only; widening the date window reads further back

    def search_url(self, prefs: Preferences, role: str, location: str, window: int, page: int) -> str:
        return glassdoor_search_url(prefs, role, location, window, page)

    def parse_search(self, html: str, base_url: str) -> list[ListingCard]:
        return parse_glassdoor_search(html, base_url or GLASSDOOR_BASE)

    def parse_detail(self, html: str, base_url: str) -> JobDetail:
        return parse_glassdoor_detail(html, base_url or GLASSDOOR_BASE)


__all__ = [
    "GLASSDOOR_SELECTORS", "GlassdoorSource", "glassdoor_search_urls", "parse_glassdoor_detail",
    "parse_glassdoor_search",
]
