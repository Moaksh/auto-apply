"""Source #4: the company's GitHub org (public REST API; no browser).

* ``GET /orgs/{org}``: the org must point at the company (``blog`` / ``email`` on the company
  domain, or its name equals the company's) before anything from it is used.
* ``GET /orgs/{org}/public_members`` + ``GET /users/{login}``: engineers and managers who made
  their membership public (name, company, blog, public email).
* ``GET /orgs/{org}/repos`` + ``GET /repos/{org}/{repo}/commits``: commit author emails on the
  company domain (``noreply`` dropped). The best free pattern evidence there is.

Unauthenticated the API allows 60 requests an hour, so a scout spends at most
``MAX_REQUESTS``. An optional personal access token (Keychain, ``AutoApply Providers`` /
``github``) raises that to 5,000.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

import httpx

from autoapply.enums import EvidenceKind
from autoapply.outreach.domains import USER_AGENT, registrable_domain
from autoapply.outreach.sources.extract import Person, plausible_name

log = logging.getLogger("autoapply.outreach.sources.github")

API = "https://api.github.com"
MAX_REQUESTS = 14
MAX_MEMBERS = 6
MAX_REPOS = 3


@dataclass(slots=True)
class GithubFindings:
    org: str | None = None
    people: list[Person] = field(default_factory=list)
    samples: list[dict] = field(default_factory=list)  # {name, email, source, url}
    requests: int = 0


class _Budget:
    def __init__(self, http: httpx.AsyncClient, token: str | None, limit: int) -> None:
        self.http, self.limit, self.used = http, limit, 0
        self.headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
        if token:
            self.headers["Authorization"] = f"Bearer {token}"

    async def get(self, path: str, **params: object) -> object | None:
        if self.used >= self.limit:
            return None
        self.used += 1
        try:
            r = await self.http.get(API + path, params=params or None, headers=self.headers, timeout=15)
        except httpx.HTTPError as e:
            log.info("github %s: %s", path, e)
            return None
        if r.status_code != 200:
            if r.status_code in (403, 429):
                self.used = self.limit  # rate-limited: stop for this scout
            return None
        try:
            return r.json()
        except ValueError:
            return None


def org_candidates(domain: str, company: str, hints: list[str]) -> list[str]:
    label = domain.split(".")[0]
    slug = re.sub(r"[^a-z0-9-]+", "", company.lower().replace(" ", "-")).strip("-")
    out: list[str] = []
    for c in [*hints, label, slug, slug.replace("-", "")]:
        if c and c.lower() not in (o.lower() for o in out):
            out.append(c)
    return out[:4]


def org_matches(org: dict, domain: str, company: str) -> bool:
    blog = str(org.get("blog") or "")
    email = str(org.get("email") or "").lower()
    if blog and registrable_domain(re.sub(r"^https?://", "", blog).split("/")[0]) == registrable_domain(domain):
        return True
    if email.endswith("@" + domain):
        return True
    name = re.sub(r"[^a-z0-9]", "", str(org.get("name") or "").lower())
    return bool(name) and name == re.sub(r"[^a-z0-9]", "", company.lower())


def commit_samples(commits: list, domain: str, repo_url: str) -> list[dict]:
    """(name, email) of commit authors on the company domain (pure; fixture-tested)."""
    out: list[dict] = []
    for c in commits or []:
        a = ((c or {}).get("commit") or {}).get("author") or {}
        email = str(a.get("email") or "").lower()
        name = re.sub(r"\s+", " ", str(a.get("name") or "")).strip()
        if not email.endswith("@" + domain) or "noreply" in email or not name or " " not in name:
            continue
        if any(s["email"] == email for s in out):
            continue
        out.append({"name": name, "email": email, "source": "github", "url": repo_url})
    return out


async def from_github(http: httpx.AsyncClient, *, domain: str, company: str, hints: list[str] | None = None,
                      token: str | None = None, max_requests: int = MAX_REQUESTS) -> GithubFindings:
    out = GithubFindings()
    api = _Budget(http, token, max_requests)
    org: dict | None = None
    for cand in org_candidates(domain, company, hints or []):
        data = await api.get(f"/orgs/{cand}")
        if isinstance(data, dict) and org_matches(data, domain, company):
            org = data
            out.org = str(data.get("login") or cand)
            break
    if org is None or out.org is None:
        out.requests = api.used
        return out
    repos = await api.get(f"/orgs/{out.org}/repos", sort="pushed", per_page=MAX_REPOS * 2, type="public")
    for repo in [r for r in (repos if isinstance(repos, list) else []) if not r.get("fork")][:MAX_REPOS]:
        name = repo.get("name")
        commits = await api.get(f"/repos/{out.org}/{name}/commits", per_page=50)
        for s in commit_samples(commits if isinstance(commits, list) else [], domain, f"https://github.com/{out.org}/{name}"):
            if not any(x["email"] == s["email"] for x in out.samples):
                out.samples.append(s)
    members = await api.get(f"/orgs/{out.org}/public_members", per_page=30)
    for m in (members if isinstance(members, list) else [])[:MAX_MEMBERS]:
        login = m.get("login")
        user = await api.get(f"/users/{login}")
        if not isinstance(user, dict):
            continue
        name = re.sub(r"\s+", " ", str(user.get("name") or "")).strip()
        if not name or not plausible_name(name):
            continue
        email = str(user.get("email") or "").lower() or None
        if email and not email.endswith("@" + domain):
            email = None
        bio = str(user.get("bio") or "")
        out.people.append(Person(name=name, title=None, email=email, url=f"https://github.com/{login}", kind=EvidenceKind.GITHUB,
                                 github_login=login, location=user.get("location"), snippet=bio[:200] or None))
    # Commit authors are people at the company too (engineers), with a published address.
    for s in out.samples:
        if not any(p.email == s["email"] or p.name == s["name"] for p in out.people):
            out.people.append(Person(name=s["name"], email=s["email"], url=s["url"], kind=EvidenceKind.GITHUB,
                                     snippet=f"commit author in {s['url'].removeprefix('https://github.com/')}"))
    out.requests = api.used
    return out


__all__ = ["GithubFindings", "commit_samples", "from_github", "org_candidates", "org_matches"]
