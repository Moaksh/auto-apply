"""The :class:`EmailProvider` protocol, provider keys in the Keychain, and monthly credit counting.

Keys live only in the macOS login Keychain (service ``AutoApply Providers``, account = the
provider name: ``hunter``, ``github``), never in the database. Credits used this month are
counted in ``meta`` (``provider_credits:<provider>:<YYYY-MM>``) so the free tier is not
overrun by accident.
"""

from __future__ import annotations

import sqlite3
import subprocess
from dataclasses import dataclass, field
from typing import Protocol

from autoapply import db
from autoapply.models import utcnow

KEYCHAIN_SERVICE = "AutoApply Providers"
PROVIDERS = ("hunter", "github")


class ProviderError(Exception):
    pass


@dataclass(slots=True)
class ProviderEmail:
    email: str
    first_name: str | None = None
    last_name: str | None = None
    position: str | None = None
    score: int | None = None
    status: str | None = None  # valid | invalid | accept_all | webmail | disposable | unknown
    source_url: str | None = None


@dataclass(slots=True)
class DomainResult:
    pattern: str | None = None  # in our vocabulary (patterns.PATTERNS)
    emails: list[ProviderEmail] = field(default_factory=list)


class EmailProvider(Protocol):
    name: str

    async def domain_search(self, domain: str) -> DomainResult: ...

    async def find(self, first: str, last: str, domain: str) -> ProviderEmail | None: ...

    async def verify(self, email: str) -> str: ...


# ---- Keychain ---------------------------------------------------------------------------


def keychain_set(provider: str, key: str) -> None:
    r = subprocess.run(["security", "add-generic-password", "-a", provider, "-s", KEYCHAIN_SERVICE, "-l",
                        f"AutoApply: {provider}", "-w", key.strip(), "-U"], capture_output=True, text=True, timeout=15)
    if r.returncode != 0:
        raise ProviderError(f"could not save the key in the Keychain: {r.stderr.strip()}")


def keychain_get(provider: str) -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-a", provider, "-s", KEYCHAIN_SERVICE, "-w"],
                       capture_output=True, text=True, timeout=15)
    out = r.stdout.strip()
    return out if r.returncode == 0 and out else None


def keychain_delete(provider: str) -> None:
    subprocess.run(["security", "delete-generic-password", "-a", provider, "-s", KEYCHAIN_SERVICE],
                   capture_output=True, text=True, timeout=15)


# ---- credits ------------------------------------------------------------------------------


def credits_key(provider: str) -> str:
    return f"provider_credits:{provider}:{utcnow().strftime('%Y-%m')}"


def credits_used(conn: sqlite3.Connection, provider: str) -> int:
    return int(db.get_meta(conn, credits_key(provider), 0) or 0)


def spend_credit(conn: sqlite3.Connection, provider: str, n: int = 1) -> int:
    key = credits_key(provider)
    with db.transaction(conn):
        used = int(db.get_meta(conn, key, 0) or 0) + n
        db.set_meta(conn, key, used)
    return used
