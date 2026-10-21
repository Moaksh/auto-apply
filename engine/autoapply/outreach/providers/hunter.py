"""Hunter.io (``api.hunter.io/v2``) with the user's own key.

* ``domain-search``: the domain's pattern plus published addresses (1 search credit);
* ``email-finder``: one person's address (1 search credit);
* ``email-verifier``: deliverability of an address (1 verification credit).

The free tier is about 25 searches and 50 verifications a month; the scout only calls Hunter
when the free sources left no usable address, and never past ``MONTHLY_SEARCHES``.
"""

from __future__ import annotations

import logging
import sqlite3

import httpx

from autoapply.outreach.providers.base import DomainResult, ProviderEmail, ProviderError, credits_used, spend_credit

log = logging.getLogger("autoapply.outreach.hunter")

API = "https://api.hunter.io/v2"
MONTHLY_SEARCHES = 25

#: Hunter's pattern templates -> ours (outreach.patterns.PATTERNS).
_PATTERNS = {
    "{first}.{last}": "first.last", "{first}": "first", "{f}{last}": "flast", "{first}{last}": "firstlast",
    "{first}_{last}": "first_last", "{first}{l}": "firstl", "{last}.{first}": "last.first", "{f}.{last}": "f.last",
    "{last}": "last",
}


def map_pattern(hunter_pattern: str | None) -> str | None:
    return _PATTERNS.get((hunter_pattern or "").strip())


class HunterProvider:
    name = "hunter"

    def __init__(self, api_key: str, http: httpx.AsyncClient, conn: sqlite3.Connection | None = None,
                 monthly_searches: int = MONTHLY_SEARCHES) -> None:
        self.api_key = api_key
        self.http = http
        self.conn = conn
        self.monthly_searches = monthly_searches

    def searches_left(self) -> int:
        if self.conn is None:
            return self.monthly_searches
        return max(0, self.monthly_searches - credits_used(self.conn, self.name))

    async def _get(self, path: str, **params: str) -> dict:
        try:
            r = await self.http.get(f"{API}/{path}", params={**params, "api_key": self.api_key}, timeout=20)
        except httpx.HTTPError as e:
            raise ProviderError(f"Hunter is unreachable: {e}") from e
        if r.status_code == 401:
            raise ProviderError("Hunter refused the API key")
        if r.status_code == 429:
            raise ProviderError("Hunter's monthly quota or rate limit is used up")
        if r.status_code >= 400:
            raise ProviderError(f"Hunter error {r.status_code}")
        try:
            return dict(r.json().get("data") or {})
        except ValueError as e:
            raise ProviderError("Hunter returned something unreadable") from e

    def _spend(self) -> None:
        if self.conn is not None:
            spend_credit(self.conn, self.name)

    async def check_key(self) -> bool:
        """``GET /account`` (free): is the key accepted?"""
        try:
            await self._get("account")
            return True
        except ProviderError:
            return False

    async def domain_search(self, domain: str) -> DomainResult:
        if self.searches_left() <= 0:
            raise ProviderError("this month's Hunter searches are used up")
        data = await self._get("domain-search", domain=domain, limit="10")
        self._spend()
        out = DomainResult(pattern=map_pattern(data.get("pattern")))
        for e in data.get("emails") or []:
            if not e.get("value"):
                continue
            src = (e.get("sources") or [{}])[0].get("uri") if e.get("sources") else None
            out.emails.append(ProviderEmail(
                email=str(e["value"]).lower(), first_name=e.get("first_name"), last_name=e.get("last_name"),
                position=e.get("position"), score=e.get("confidence"),
                status=((e.get("verification") or {}).get("status")), source_url=src,
            ))
        return out

    async def find(self, first: str, last: str, domain: str) -> ProviderEmail | None:
        if self.searches_left() <= 0:
            raise ProviderError("this month's Hunter searches are used up")
        data = await self._get("email-finder", domain=domain, first_name=first, last_name=last)
        self._spend()
        if not data.get("email"):
            return None
        return ProviderEmail(email=str(data["email"]).lower(), first_name=first, last_name=last, position=data.get("position"),
                             score=data.get("score"), status=((data.get("verification") or {}).get("status")))

    async def verify(self, email: str) -> str:
        data = await self._get("email-verifier", email=email)
        return str(data.get("status") or data.get("result") or "unknown")


__all__ = ["HunterProvider", "map_pattern"]
