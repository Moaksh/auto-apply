"""Add a job by link: turn any job URL into a ``jobs`` row the pipeline can apply to.

Owner: Workstream A (engine core).

:func:`fetch_job_meta` reads title / company / location / description from the page, best
effort and read-only:

1. Rippling boards (``ats.rippling.com/<board>/jobs/<uuid>``): their public JSON API, since
   the page itself is rendered client-side.
2. Any page with a schema.org ``JobPosting`` in JSON-LD (Greenhouse, Lever, Ashby, Workday
   and most career sites publish one).
3. ``og:title`` / ``<title>`` and the board slug or domain for the company.

Missing fields fall back to the URL; the user can pass ``title`` / ``company`` to override.
The agentic adapter reads the real form at apply time, so a rough title is fine.
"""

from __future__ import annotations

import html as _html
import json
import logging
import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

import httpx

from autoapply.discovery.base import detect_ats, html_to_text
from autoapply.enums import Ats

log = logging.getLogger(__name__)

USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36"
_RIPPLING_RE = re.compile(r"^/(?P<board>[^/]+)/jobs/(?P<id>[0-9a-f-]{36})", re.I)
_LD_RE = re.compile(r"<script[^>]*application/ld\+json[^>]*>(.*?)</script>", re.I | re.S)
_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.I | re.S)
_META_RE = re.compile(r"<meta\s+[^>]*>", re.I)
_ATTR_RE = re.compile(r'(\w[\w:-]*)\s*=\s*"([^"]*)"|(\w[\w:-]*)\s*=\s*\'([^\']*)\'')
#: Hosts whose first path segment is the company's board slug.
_SLUG_HOSTS = ("greenhouse.io", "lever.co", "ashbyhq.com", "rippling.com", "workable.com", "smartrecruiters.com",
               "recruitee.com", "breezy.hr", "bamboohr.com", "teamtailor.com", "personio.de", "personio.com")
_GENERIC_TITLES = {"careers", "jobs", "job application", "apply", "job details", "home"}


class InvalidJobUrl(ValueError):
    pass


@dataclass
class JobMeta:
    url: str
    title: str
    company: str
    location: str | None = None
    description: str | None = None
    ats: Ats = Ats.OTHER
    board_token: str | None = None
    external_id: str | None = None
    posted_at: str | None = None


def normalize_job_url(raw: str) -> str:
    url = (raw or "").strip()
    if url and "://" not in url:
        url = "https://" + url
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname or "." not in parts.hostname:
        raise InvalidJobUrl(f"not a job link: {raw!r}")
    host = parts.hostname.lower()
    if host.endswith("linkedin.com") or host.endswith("glassdoor.com") or host.endswith("glassdoor.co.in"):
        raise InvalidJobUrl("LinkedIn / Glassdoor links can't be applied to automatically; paste the company's own apply link")
    return url


def _clean(text: str | None) -> str | None:
    if not text:
        return None
    out = re.sub(r"\s+", " ", _html.unescape(text)).strip()
    return out or None


def _attrs(tag: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for m in _ATTR_RE.finditer(tag):
        key = (m.group(1) or m.group(3) or "").lower()
        out[key] = m.group(2) if m.group(1) else m.group(4)
    return out


def _meta(html: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for tag in _META_RE.findall(html):
        a = _attrs(tag)
        key = (a.get("property") or a.get("name") or "").lower()
        if key and "content" in a and key not in out:
            out[key] = a["content"]
    return out


def _walk_ld(node: Any) -> Any:
    if isinstance(node, list):
        for n in node:
            found = _walk_ld(n)
            if found is not None:
                return found
    elif isinstance(node, dict):
        kind = node.get("@type")
        if kind == "JobPosting" or (isinstance(kind, list) and "JobPosting" in kind):
            return node
        if "@graph" in node:
            return _walk_ld(node["@graph"])
    return None


def _ld_location(posting: dict[str, Any]) -> str | None:
    locs = posting.get("jobLocation")
    if isinstance(locs, dict):
        locs = [locs]
    names: list[str] = []
    for loc in locs or []:
        addr = loc.get("address") if isinstance(loc, dict) else None
        if isinstance(addr, dict):
            parts = [addr.get("addressLocality"), addr.get("addressRegion"), addr.get("addressCountry")]
            parts = [p.get("name") if isinstance(p, dict) else p for p in parts]
            name = ", ".join(str(p) for p in parts if p)
            if name:
                names.append(name)
        elif isinstance(addr, str):
            names.append(addr)
    if not names and posting.get("jobLocationType") == "TELECOMMUTE":
        return "Remote"
    return "; ".join(dict.fromkeys(names)) or None


def company_from_url(url: str) -> str:
    parts = urlsplit(url)
    host = (parts.hostname or "").lower().removeprefix("www.")
    segs = [s for s in parts.path.split("/") if s]
    if any(host == h or host.endswith("." + h) for h in _SLUG_HOSTS):
        sub = host.split(".")[0]
        if host.endswith(("workable.com", "recruitee.com", "breezy.hr", "bamboohr.com", "teamtailor.com",
                          "personio.de", "personio.com")) and sub not in ("apply", "jobs", "www"):
            slug = sub
        elif segs and segs[0] not in ("embed", "v1", "en-us", "en"):
            slug = segs[0]
        else:
            slug = sub
    elif ".myworkdayjobs.com" in host:
        slug = host.split(".")[0]
    else:
        labels = [x for x in host.split(".") if x not in ("careers", "jobs", "apply", "boards", "job-boards")]
        slug = labels[0] if labels else host
    slug = re.sub(r"[-_](careers?|jobs|inc|hq)$", "", slug, flags=re.I)
    return " ".join(w.capitalize() for w in re.split(r"[-_]+", slug) if w) or host


def parse_job_page(url: str, html: str) -> JobMeta:
    """Best-effort metadata from a job page's HTML (no network)."""
    ats, token = detect_ats(url)
    title = company = location = description = posted = None
    for block in _LD_RE.findall(html):
        try:
            posting = _walk_ld(json.loads(block.strip()))
        except ValueError:
            continue
        if posting is None:
            continue
        title = _clean(posting.get("title"))
        org = posting.get("hiringOrganization")
        company = _clean(org.get("name") if isinstance(org, dict) else org if isinstance(org, str) else None)
        location = _ld_location(posting)
        description = html_to_text(posting.get("description") or "") or None
        posted = posting.get("datePosted")
        break
    meta = _meta(html)
    if not title:
        title = _clean(meta.get("og:title")) or _clean((_TITLE_RE.search(html) or [None, None])[1])
        if title:
            # "Senior Engineer - Acme Careers" / "Acme | Senior Engineer": keep the job part.
            pieces = [p.strip() for p in re.split(r"\s[|–—-]\s", title) if p.strip()]
            if len(pieces) > 1:
                site = _clean(meta.get("og:site_name")) or company
                rest = [p for p in pieces if not site or site.lower() not in p.lower()] or pieces
                title = max(rest, key=len) if len(rest) > 1 and rest[0].lower() in _GENERIC_TITLES else rest[0]
        if title and title.lower() in _GENERIC_TITLES:
            title = None
    if not company:
        company = _clean(meta.get("og:site_name"))
    if not description:
        description = _clean(meta.get("og:description") or meta.get("description"))
    company = company or company_from_url(url)
    return JobMeta(url=url, title=title or f"Job at {company}", company=company, location=location,
                   description=description, ats=ats, board_token=token, posted_at=posted)


async def _rippling(client: httpx.AsyncClient, url: str) -> JobMeta | None:
    parts = urlsplit(url)
    if (parts.hostname or "").lower() != "ats.rippling.com":
        return None
    m = _RIPPLING_RE.match(parts.path)
    if not m:
        return None
    r = await client.get(f"https://ats.rippling.com/api/v2/board/{m['board']}/jobs/{m['id']}")
    r.raise_for_status()
    d = r.json()
    desc = "\n\n".join(html_to_text(v) for v in (d.get("description") or {}).values() if v)
    # companyName is the legal entity ("AlaanPay Technology FZCO"); the board slug ("alaan-careers")
    # is usually the brand, so prefer it when the legal name starts with it.
    brand = company_from_url(url)
    legal = (d.get("board") or {}).get("companyName") or d.get("companyName") or ""
    company = brand if not legal or legal.replace(" ", "").lower().startswith(brand.replace(" ", "").lower()) else legal
    return JobMeta(
        url=url, title=d.get("name") or f"Job at {company}", company=company,
        location="; ".join(d.get("workLocations") or []) or None, description=desc or None,
        ats=Ats.OTHER, board_token=m["board"], external_id=m["id"], posted_at=d.get("createdOn"),
    )


async def fetch_job_meta(url: str, *, http: httpx.AsyncClient | None = None) -> JobMeta:
    """Read the job page; never raises for network / parse problems (falls back to the URL)."""
    client = http or httpx.AsyncClient(timeout=15.0, follow_redirects=True, headers={"User-Agent": USER_AGENT})
    try:
        try:
            rip = await _rippling(client, url)
            if rip is not None:
                return rip
        except (httpx.HTTPError, ValueError) as exc:
            log.info("rippling api failed for %s: %s", url, exc)
        try:
            r = await client.get(url)
            r.raise_for_status()
            return parse_job_page(str(r.url), r.text)
        except httpx.HTTPError as exc:
            log.info("could not fetch %s: %s", url, exc)
            return parse_job_page(url, "")
    finally:
        if http is None:
            await client.aclose()
