"""``company_facts`` (schema v14): what public sources say about a company.

Facts come from YC's public directory and from funding news (``outreach/startups.py``). Each
stored fact names its source in ``sources[fact] = {url, quote?, observed_at}``; a fact nobody
published stays NULL. A newer funding round replaces an older one; an older one never
overwrites a newer one. Nothing here touches the network.
"""

from __future__ import annotations

import sqlite3
from typing import Any

from autoapply import db
from autoapply.models import CompanyFacts, now_ts

#: Columns a caller may set (everything but the key, ``sources`` and ``updated_at``).
FACT_COLUMNS: tuple[str, ...] = (
    "hq_city", "hq_country", "yc_batch", "yc_url", "yc_status", "industry", "last_round_stage", "last_round_amount",
    "last_round_currency", "last_round_usd", "last_round_date", "total_raised_usd", "investors", "team_size", "is_hiring",
    "open_roles", "founders",
)
#: The facts of one funding round: replaced together, and only by a round at least as recent.
ROUND_COLUMNS: frozenset[str] = frozenset({
    "last_round_stage", "last_round_amount", "last_round_currency", "last_round_usd", "last_round_date", "investors",
})
_JSON = frozenset({"investors", "founders"})


def get(conn: sqlite3.Connection, company_id: int) -> CompanyFacts | None:
    row = conn.execute("SELECT * FROM company_facts WHERE company_id = ?", (company_id,)).fetchone()
    return CompanyFacts.from_row(row) if row else None  # type: ignore[return-value]


def source(url: str | None, quote: str | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"url": url, "observed_at": now_ts()}
    if quote:
        out["quote"] = quote[:400]
    return out


def _is_newer_round(current: CompanyFacts | None, new_date: str | None) -> bool:
    if current is None or not current.last_round_date:
        return True
    if not new_date:
        return False  # an undated round never replaces a dated one
    return new_date >= current.last_round_date


def upsert(conn: sqlite3.Connection, company_id: int, updates: dict[str, Any], sources: dict[str, dict[str, Any]]) -> CompanyFacts:
    """Merge ``updates`` (None values are ignored) and their ``sources`` into the company's row."""
    unknown = set(updates) - set(FACT_COLUMNS)
    if unknown:
        raise ValueError(f"unknown company facts: {sorted(unknown)}")
    with db.transaction(conn):
        cur = get(conn, company_id)
        vals = {k: v for k, v in updates.items() if v is not None and v != []}
        if ROUND_COLUMNS & set(vals) and not _is_newer_round(cur, vals.get("last_round_date")):
            vals = {k: v for k, v in vals.items() if k not in ROUND_COLUMNS}
        srcs = dict(cur.sources if cur else {})
        for k, s in sources.items():
            if k in vals or k not in FACT_COLUMNS:
                srcs[k] = s
        if cur is None:
            conn.execute("INSERT INTO company_facts(company_id, updated_at) VALUES (?, ?)", (company_id, now_ts()))
        fields: dict[str, Any] = {k: (db._j(v) if k in _JSON else (int(v) if isinstance(v, bool) else v)) for k, v in vals.items()}
        fields["sources"] = db._j(srcs)
        fields["updated_at"] = now_ts()
        sql, params = db._update_sql("company_facts", fields, "company_id = ?")
        conn.execute(sql, [*params, company_id])
    out = get(conn, company_id)
    assert out is not None
    return out


__all__ = ["FACT_COLUMNS", "ROUND_COLUMNS", "get", "source", "upsert"]
