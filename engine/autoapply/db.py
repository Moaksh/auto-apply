"""SQLite access layer: connections, migrations, repositories, state machine.

Rules (PLAN.md §2):
* The daemon is the ONLY writer. The Swift app opens the same file read-only (GRDB).
* Schema lives in contract/schema.sql and is applied by :func:`migrate`.
* Every application state change goes through :func:`transition`, which enforces
  ``models.ALLOWED_TRANSITIONS`` and appends an ``events`` row in the same transaction.
* ``submitting`` is written (and fsync'd: ``synchronous=FULL``) *before* the adapter clicks
  submit — use :func:`begin_submit`. On daemon start call :func:`recover_after_crash`:
  any application still in ``submitting`` becomes ``unknown_verify`` and is NEVER retried
  automatically (no double applies).

Connections use autocommit mode (``isolation_level=None``); group writes with
``with transaction(conn): ...`` (``BEGIN IMMEDIATE``; nested use joins the outer one).
Every repository function that writes opens its own transaction, so calling it inside an
outer ``transaction`` makes the whole block atomic.

A connection is not safe for concurrent use; the daemon should own one writer connection
(and may hand short-lived read connections to worker threads).
"""

from __future__ import annotations

import json
import re
import sqlite3
import unicodedata
from collections.abc import Iterable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import numpy as np

from autoapply import paths as _paths
from autoapply.config import NeverGuess, Preferences
from autoapply.enums import (
    Actor,
    AnswerOrigin,
    AnswerSource,
    AppState,
    ApplicationMode,
    Ats,
    BoardStatus,
    FieldType,
    JobSource,
    LogLevel,
    Mode,
    QuestionReason,
    QuestionStatus,
    RunKind,
    RunOutcome,
    RunTrigger,
)
from autoapply.models import (
    ACTIVE_STATES,
    ALLOWED_TRANSITIONS,
    MANUAL_SUBMIT_FROM,
    PROFILE_FIELDS,
    USER_ONLY_TRANSITIONS,
    Answer,
    Application,
    ApplicationAnswer,
    ApplicationStatePayload,
    ApplicationStatusPayload,
    CapsStatus,
    Company,
    Counts,
    DraftedAnswer,
    EasyApplyItem,
    EventRow,
    Job,
    JobSummary,
    Profile,
    Question,
    QuestionCluster,
    ResumeVariant,
    Run,
    RunInfo,
    RunStats,
    Score,
    Story,
    format_ts,
    new_id,
    now_ts,
    parse_ts,
    utcnow,
)

#: Must equal MAX(version) seeded by contract/schema.sql.
SCHEMA_VERSION = 6

#: Forward migrations: version -> SQL to go from (version-1) to version. Append-only.
#: Version 1 is the baseline created by contract/schema.sql itself.
MIGRATIONS: dict[int, str] = {
    2: """
ALTER TABLE preferences ADD COLUMN searches_per_session INTEGER NOT NULL DEFAULT 3 CHECK (searches_per_session BETWEEN 1 AND 10);
ALTER TABLE preferences ADD COLUMN jobs_per_session INTEGER NOT NULL DEFAULT 30 CHECK (jobs_per_session BETWEEN 1 AND 200);
""",
    3: """
ALTER TABLE questions ADD COLUMN suggested_answer TEXT;
ALTER TABLE questions ADD COLUMN suggested_confidence REAL;
""",
    4: """
ALTER TABLE questions ADD COLUMN suggested_note TEXT;
""",
    5: "python:_migrate_v5",
    6: "python:_migrate_v6",
}


def _migrate_v5(conn: sqlite3.Connection) -> None:
    """v5: jobs.source accepts 'google' (Google Jobs); scores.basis remembers what a score was
    computed against so a threshold-only change can reuse it. SQLite can't alter a CHECK, so
    jobs is rebuilt (the documented 12-step procedure, foreign keys off for the swap)."""
    conn.execute("PRAGMA foreign_keys = OFF")
    try:
        conn.execute("BEGIN")
        ddl = conn.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'jobs'").fetchone()[0]
        if "'google'" not in ddl:
            new_ddl = re.sub(r"^CREATE TABLE (IF NOT EXISTS )?\"?jobs\"?", "CREATE TABLE jobs_v5", ddl, count=1)
            new_ddl = new_ddl.replace("'glassdoor','manual'", "'glassdoor','google','manual'")
            if new_ddl == ddl or "'google'" not in new_ddl:
                raise DBError("v5 migration: unexpected jobs table definition")
            extras = [r[0] for r in conn.execute(
                "SELECT sql FROM sqlite_master WHERE tbl_name = 'jobs' AND type IN ('index', 'trigger') AND sql IS NOT NULL")]
            conn.execute(new_ddl)
            conn.execute("INSERT INTO jobs_v5 SELECT * FROM jobs")
            conn.execute("DROP TABLE jobs")
            conn.execute("ALTER TABLE jobs_v5 RENAME TO jobs")
            for sql in extras:
                conn.execute(sql)
        cols = {r[1] for r in conn.execute("PRAGMA table_info(scores)")}
        if "basis" not in cols:
            conn.execute("ALTER TABLE scores ADD COLUMN basis TEXT")
        bad = conn.execute("PRAGMA foreign_key_check").fetchall()
        if bad:
            raise DBError(f"v5 migration broke foreign keys: {bad[:3]}")
        conn.execute("INSERT INTO schema_version(version) VALUES (5)")
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    finally:
        conn.execute("PRAGMA foreign_keys = ON")


def _migrate_v6(conn: sqlite3.Connection) -> None:
    """v6: preferences.parallel_applications (how many applications are worked on at once).
    Idempotent: a DB built from a schema.sql that already has the column only gets the version row."""
    conn.execute("BEGIN")
    try:
        cols = {r[1] for r in conn.execute("PRAGMA table_info(preferences)")}
        if "parallel_applications" not in cols:
            conn.execute(
                "ALTER TABLE preferences ADD COLUMN parallel_applications INTEGER NOT NULL DEFAULT 3 "
                "CHECK (parallel_applications BETWEEN 1 AND 4)"
            )
        conn.execute("INSERT INTO schema_version(version) VALUES (6)")
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise


# =====================================================================================
# Errors
# =====================================================================================


class DBError(Exception):
    code = "internal"


class NotFound(DBError):
    code = "not_found"


class Conflict(DBError):
    code = "conflict"


class IllegalTransition(DBError):
    code = "illegal_transition"

    def __init__(self, application_id: int, frm: AppState | str | None, to: AppState | str, actor: Actor | str, why: str = ""):
        self.application_id = application_id
        self.from_state = AppState(frm) if frm is not None else None
        self.to_state = AppState(to)
        self.actor = Actor(actor)
        msg = f"application {application_id}: illegal transition {frm} -> {to} by {actor}"
        super().__init__(f"{msg} ({why})" if why else msg)


# =====================================================================================
# Connection / migrations
# =====================================================================================


def connect(path: Path | str | None = None, *, readonly: bool = False) -> sqlite3.Connection:
    """Open a connection with the contract pragmas (WAL, FKs, synchronous=FULL).

    ``path`` defaults to ``paths.get_paths().db``; ``":memory:"`` is allowed for tests.
    """
    if path is None:
        p = _paths.get_paths(create=True).db
    else:
        p = path
    if readonly:
        uri = f"file:{Path(p).as_posix()}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, isolation_level=None, check_same_thread=False, timeout=5.0)
    else:
        if str(p) != ":memory:":
            Path(p).parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(p), isolation_level=None, check_same_thread=False, timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA busy_timeout = 5000")
    if readonly:
        conn.execute("PRAGMA query_only = ON")
    else:
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA synchronous = FULL")
    return conn


def current_schema_version(conn: sqlite3.Connection) -> int:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
    ).fetchone()
    if row is None:
        return 0
    v = conn.execute("SELECT MAX(version) FROM schema_version").fetchone()[0]
    return int(v or 0)


def migrate(conn: sqlite3.Connection, schema_path: Path | str | None = None) -> int:
    """Bring the DB to :data:`SCHEMA_VERSION`. Idempotent. Returns the resulting version."""
    version = current_schema_version(conn)
    if version == 0:
        sql = Path(schema_path or _paths.schema_sql_path()).read_text(encoding="utf-8")
        # executescript() runs outside our explicit transactions; wrap for atomicity.
        conn.executescript("BEGIN;\n" + sql + "\nCOMMIT;")
        version = current_schema_version(conn)
    if version > SCHEMA_VERSION:
        raise DBError(f"database schema v{version} is newer than this engine (v{SCHEMA_VERSION})")
    while version < SCHEMA_VERSION:
        nxt = version + 1
        sql = MIGRATIONS.get(nxt)
        if sql is None:
            raise DBError(f"no migration registered for schema v{nxt}")
        if sql.startswith("python:"):
            globals()[sql.removeprefix("python:")](conn)
            version = nxt
            continue
        conn.executescript(
            "BEGIN;\n" + sql + f"\nINSERT INTO schema_version(version) VALUES ({nxt});\nCOMMIT;"
        )
        version = nxt
    return version


def open_db(path: Path | str | None = None) -> sqlite3.Connection:
    """connect() + migrate(). The usual entry point for the daemon / CLI / tests."""
    conn = connect(path)
    migrate(conn)
    return conn


@contextmanager
def transaction(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    """``BEGIN IMMEDIATE`` … ``COMMIT`` (rollback on error). Re-entrant: joins an open tx."""
    if conn.in_transaction:
        yield conn
        return
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    else:
        conn.execute("COMMIT")


# =====================================================================================
# Small helpers
# =====================================================================================


def _j(value: Any) -> str:
    """JSON-encode for a TEXT JSON column (pydantic models / enums handled)."""

    def default(o: Any) -> Any:
        if hasattr(o, "model_dump"):
            return o.model_dump(mode="json")
        if isinstance(o, datetime):
            return format_ts(o)
        if isinstance(o, (set, frozenset, tuple)):
            return list(o)
        raise TypeError(f"not JSON serializable: {type(o).__name__}")

    return json.dumps(value, ensure_ascii=False, default=default, separators=(",", ":"))


def _ts(value: datetime | str | None) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return format_ts(parse_ts(value))
    return format_ts(value)


def _one(conn: sqlite3.Connection, sql: str, params: Sequence[Any] = ()) -> sqlite3.Row | None:
    return conn.execute(sql, params).fetchone()


def _require(row: sqlite3.Row | None, what: str, key: Any) -> sqlite3.Row:
    if row is None:
        raise NotFound(f"{what} {key!r} not found")
    return row


def normalize_text(value: str | None) -> str:
    """Lowercase, strip accents/punctuation, collapse whitespace. Used for dedupe keys."""
    if not value:
        return ""
    s = unicodedata.normalize("NFKD", value)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


_TRACKING_PARAMS = re.compile(r"^(utm_.*|gh_src|source|ref|refid|trk|lever-source|lever-origin|src)$", re.I)


def normalize_url(url: str | None) -> str | None:
    """Canonical form of an apply URL for dedupe: scheme/host lowercased, no fragment,
    tracking params dropped, remaining params sorted, trailing slash removed."""
    if not url:
        return None
    parts = urlsplit(url.strip())
    if not parts.netloc:
        return url.strip() or None
    host = parts.netloc.lower()
    if host.startswith("www."):
        host = host[4:]
    query = urlencode(sorted((k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if not _TRACKING_PARAMS.match(k)))
    path = parts.path.rstrip("/") or "/"
    return urlunsplit(("https", host, path, query, ""))


def make_dedupe_key(company: str, title: str, location: str | None) -> str:
    """``normalized company|title|location`` (PLAN.md §5 Discovery)."""
    return "|".join((normalize_text(company), normalize_text(title), normalize_text(location)))


def pack_embedding(vec: Sequence[float] | np.ndarray) -> bytes:
    return np.asarray(vec, dtype="<f4").tobytes()


def unpack_embedding(blob: bytes | None) -> np.ndarray | None:
    if blob is None:
        return None
    return np.frombuffer(blob, dtype="<f4").copy()


def local_day_start(now: datetime | None = None) -> datetime:
    """Start of the current *local* day, as an aware datetime (for daily caps / 'today')."""
    now = (now or utcnow()).astimezone()
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


def _update_sql(table: str, fields: dict[str, Any], where: str) -> tuple[str, list[Any]]:
    cols = ", ".join(f"{k} = ?" for k in fields)
    return f"UPDATE {table} SET {cols} WHERE {where}", list(fields.values())


# =====================================================================================
# meta
# =====================================================================================


def get_meta(conn: sqlite3.Connection, key: str, default: Any = None) -> Any:
    row = _one(conn, "SELECT value FROM meta WHERE key = ?", (key,))
    return json.loads(row["value"]) if row else default


def set_meta(conn: sqlite3.Connection, key: str, value: Any) -> None:
    with transaction(conn):
        conn.execute(
            "INSERT INTO meta(key, value, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            (key, _j(value), now_ts()),
        )


def delete_meta(conn: sqlite3.Connection, key: str) -> None:
    with transaction(conn):
        conn.execute("DELETE FROM meta WHERE key = ?", (key,))


# Well-known meta keys.
META_PAUSED = "paused"
META_ONBOARDING = "onboarding"  # {"completed": bool, "step": int}
META_SOURCES = "sources"  # {source: {"connected": bool, "checked_at": ts, "detail": str}}


def source_sessions_key(source: str, day: datetime | None = None) -> str:
    return f"sessions_used:{source}:{local_day_start(day).date().isoformat()}"


def increment_source_sessions(conn: sqlite3.Connection, source: str) -> int:
    """Count one LinkedIn/Glassdoor browsing session for today; returns the new total."""
    key = source_sessions_key(source)
    with transaction(conn):
        n = int(get_meta(conn, key, 0)) + 1
        set_meta(conn, key, n)
    return n


def refund_source_session(conn: sqlite3.Connection, source: str) -> int:
    """Give back one session (a run that failed on our side must not burn the daily budget)."""
    key = source_sessions_key(source)
    with transaction(conn):
        n = max(0, int(get_meta(conn, key, 0)) - 1)
        set_meta(conn, key, n)
    return n


def reset_source_sessions(conn: sqlite3.Connection, source: str) -> None:
    with transaction(conn):
        set_meta(conn, source_sessions_key(source), 0)


def get_source_sessions(conn: sqlite3.Connection, source: str) -> int:
    return int(get_meta(conn, source_sessions_key(source), 0))


# =====================================================================================
# profile / never_guess / preferences
# =====================================================================================


_PROFILE_JSON = {"links", "work_history", "education", "skills", "extra"}


def get_profile(conn: sqlite3.Connection) -> Profile:
    row = _one(conn, "SELECT * FROM profile WHERE id = 1")
    if row is None:  # seeded by schema; recreate defensively
        with transaction(conn):
            conn.execute("INSERT OR IGNORE INTO profile(id) VALUES (1)")
        row = _one(conn, "SELECT * FROM profile WHERE id = 1")
    return Profile.from_row(row)  # type: ignore[return-value]


def update_profile(conn: sqlite3.Connection, patch: dict[str, Any]) -> Profile:
    """Apply a partial update (keys = Profile fields). Validates via the Profile model."""
    unknown = set(patch) - set(PROFILE_FIELDS)
    if unknown:
        raise ValueError(f"unknown profile fields: {sorted(unknown)}")
    merged = get_profile(conn).model_dump()
    merged.update(patch)
    validated = Profile.model_validate(merged)
    data = validated.model_dump(mode="json", include=set(patch))
    fields = {k: (_j(v) if k in _PROFILE_JSON else v) for k, v in data.items()}
    fields["updated_at"] = now_ts()
    with transaction(conn):
        sql, params = _update_sql("profile", fields, "id = 1")
        conn.execute(sql, params)
    return get_profile(conn)


def get_never_guess(conn: sqlite3.Connection) -> NeverGuess:
    rows = {r["key"]: json.loads(r["value"]) for r in conn.execute("SELECT key, value FROM never_guess")}
    return NeverGuess.from_rows(rows)


def set_never_guess(conn: sqlite3.Connection, values: dict[str, Any]) -> NeverGuess:
    """Upsert never-guess keys. A value of ``None`` deletes the row ("always ask me").

    The merged result is validated through :class:`NeverGuess` before anything is written.
    """
    unknown = set(values) - set(NeverGuess.model_fields)
    if unknown:
        raise ValueError(f"unknown never_guess keys: {sorted(unknown)}")
    current = {r["key"]: json.loads(r["value"]) for r in conn.execute("SELECT key, value FROM never_guess")}
    merged = {**current, **values}
    NeverGuess.from_rows(merged)  # validate
    ts = now_ts()
    with transaction(conn):
        for k, v in values.items():
            if v is None:
                conn.execute("DELETE FROM never_guess WHERE key = ?", (k,))
            else:
                conn.execute(
                    "INSERT INTO never_guess(key, value, updated_at) VALUES (?, ?, ?) "
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                    (k, _j(v), ts),
                )
    return get_never_guess(conn)


def save_never_guess(conn: sqlite3.Connection, ng: NeverGuess) -> NeverGuess:
    """Persist every field of ``ng`` (None fields are removed)."""
    return set_never_guess(conn, ng.to_rows())


_PREF_JSON = {
    "roles", "seniority", "locations", "remote_policy", "exclude_companies", "exclude_industries",
    "exclude_keywords", "per_ats_mode", "per_company_mode", "schedule", "nudge_days",
    "sources_enabled", "career_page_urls", "always_ask_patterns",
}
_PREF_BOOL = {"hide_without_salary"}


def get_preferences(conn: sqlite3.Connection) -> Preferences:
    row = _one(conn, "SELECT * FROM preferences WHERE id = 1")
    if row is None:
        with transaction(conn):
            conn.execute("INSERT OR IGNORE INTO preferences(id) VALUES (1)")
        row = _one(conn, "SELECT * FROM preferences WHERE id = 1")
    data = dict(row)
    data.pop("id", None)
    data.pop("updated_at", None)
    for k in _PREF_JSON:
        data[k] = json.loads(data[k])
    for k in _PREF_BOOL:
        data[k] = bool(data[k])
    return Preferences.model_validate(data)


def save_preferences(conn: sqlite3.Connection, prefs: Preferences) -> Preferences:
    data = prefs.model_dump(mode="json")
    fields = {k: (_j(v) if k in _PREF_JSON else (int(v) if k in _PREF_BOOL else v)) for k, v in data.items()}
    fields["updated_at"] = now_ts()
    with transaction(conn):
        conn.execute("INSERT OR IGNORE INTO preferences(id) VALUES (1)")
        sql, params = _update_sql("preferences", fields, "id = 1")
        conn.execute(sql, params)
    return get_preferences(conn)


def update_preferences(conn: sqlite3.Connection, patch: dict[str, Any]) -> Preferences:
    """Apply a partial preferences dict (validated) and persist."""
    with transaction(conn):
        return save_preferences(conn, get_preferences(conn).apply_patch(patch))


# =====================================================================================
# resume_variants
# =====================================================================================


def add_resume_variant(
    conn: sqlite3.Connection,
    *,
    label: str,
    file_path: str,
    tags: Iterable[str] = (),
    text: str | None = None,
    is_default: bool = False,
    replaces: int | None = None,
) -> ResumeVariant:
    """Insert a variant. ``replaces`` = id of the variant this new file supersedes
    (old row is disabled and points at the new one; version is incremented)."""
    ts = now_ts()
    with transaction(conn):
        version = 1
        if replaces is not None:
            old = _require(_one(conn, "SELECT * FROM resume_variants WHERE id = ?", (replaces,)), "resume_variant", replaces)
            version = int(old["version"]) + 1
            is_default = is_default or bool(old["is_default"])
        if is_default:
            conn.execute("UPDATE resume_variants SET is_default = 0, updated_at = ? WHERE is_default = 1", (ts,))
        cur = conn.execute(
            "INSERT INTO resume_variants(label, file_path, tags, text, is_default, version, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (label, file_path, _j(list(tags)), text, int(is_default), version, ts, ts),
        )
        new_id_ = int(cur.lastrowid)
        if replaces is not None:
            conn.execute(
                "UPDATE resume_variants SET replaced_by = ?, enabled = 0, updated_at = ? WHERE id = ?",
                (new_id_, ts, replaces),
            )
    return get_resume_variant(conn, new_id_)


def get_resume_variant(conn: sqlite3.Connection, variant_id: int) -> ResumeVariant:
    row = _require(_one(conn, "SELECT * FROM resume_variants WHERE id = ?", (variant_id,)), "resume_variant", variant_id)
    return ResumeVariant.from_row(row)  # type: ignore[return-value]


def list_resume_variants(conn: sqlite3.Connection, *, enabled_only: bool = False) -> list[ResumeVariant]:
    sql = "SELECT * FROM resume_variants"
    if enabled_only:
        sql += " WHERE enabled = 1 AND replaced_by IS NULL"
    sql += " ORDER BY is_default DESC, id"
    return [ResumeVariant.from_row(r) for r in conn.execute(sql)]  # type: ignore[misc]


def update_resume_variant(
    conn: sqlite3.Connection,
    variant_id: int,
    *,
    label: str | None = None,
    tags: Iterable[str] | None = None,
    text: str | None = None,
    enabled: bool | None = None,
    is_default: bool | None = None,
) -> ResumeVariant:
    ts = now_ts()
    fields: dict[str, Any] = {}
    if label is not None:
        fields["label"] = label
    if tags is not None:
        fields["tags"] = _j(list(tags))
    if text is not None:
        fields["text"] = text
    if enabled is not None:
        fields["enabled"] = int(enabled)
    if is_default is not None:
        fields["is_default"] = int(is_default)
    with transaction(conn):
        get_resume_variant(conn, variant_id)
        if is_default:
            conn.execute("UPDATE resume_variants SET is_default = 0, updated_at = ? WHERE is_default = 1 AND id <> ?", (ts, variant_id))
        if fields:
            fields["updated_at"] = ts
            sql, params = _update_sql("resume_variants", fields, "id = ?")
            conn.execute(sql, [*params, variant_id])
    return get_resume_variant(conn, variant_id)


def set_resume_embedding(conn: sqlite3.Connection, variant_id: int, vec: Sequence[float] | np.ndarray, model: str) -> None:
    with transaction(conn):
        conn.execute(
            "UPDATE resume_variants SET embedding = ?, embedding_model = ?, updated_at = ? WHERE id = ?",
            (pack_embedding(vec), model, now_ts(), variant_id),
        )


def get_resume_embedding(conn: sqlite3.Connection, variant_id: int) -> tuple[np.ndarray | None, str | None]:
    row = _require(_one(conn, "SELECT embedding, embedding_model FROM resume_variants WHERE id = ?", (variant_id,)), "resume_variant", variant_id)
    return unpack_embedding(row["embedding"]), row["embedding_model"]


# =====================================================================================
# stories
# =====================================================================================


def upsert_story(
    conn: sqlite3.Connection,
    *,
    title: str,
    situation: str = "",
    task: str = "",
    action: str = "",
    result: str = "",
    tags: Iterable[str] = (),
    id: int | None = None,
) -> Story:
    ts = now_ts()
    with transaction(conn):
        if id is None:
            cur = conn.execute(
                "INSERT INTO stories(title, situation, task, action, result, tags, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (title, situation, task, action, result, _j(list(tags)), ts, ts),
            )
            id = int(cur.lastrowid)
        else:
            get_story(conn, id)
            conn.execute(
                "UPDATE stories SET title = ?, situation = ?, task = ?, action = ?, result = ?, tags = ?, updated_at = ? WHERE id = ?",
                (title, situation, task, action, result, _j(list(tags)), ts, id),
            )
    return get_story(conn, id)


def get_story(conn: sqlite3.Connection, story_id: int) -> Story:
    return Story.from_row(_require(_one(conn, "SELECT * FROM stories WHERE id = ?", (story_id,)), "story", story_id))  # type: ignore[return-value]


def list_stories(conn: sqlite3.Connection) -> list[Story]:
    return [Story.from_row(r) for r in conn.execute("SELECT * FROM stories ORDER BY id")]  # type: ignore[misc]


def delete_story(conn: sqlite3.Connection, story_id: int) -> None:
    with transaction(conn):
        if conn.execute("DELETE FROM stories WHERE id = ?", (story_id,)).rowcount == 0:
            raise NotFound(f"story {story_id} not found")


def record_story_use(conn: sqlite3.Connection, story_id: int) -> None:
    with transaction(conn):
        conn.execute("UPDATE stories SET uses = uses + 1 WHERE id = ?", (story_id,))


# =====================================================================================
# answers (memory)
# =====================================================================================


def add_answer(
    conn: sqlite3.Connection,
    *,
    canonical_question: str,
    answer: str,
    field_type: FieldType | str = FieldType.TEXT,
    is_template: bool | None = None,
    source: AnswerSource | str = AnswerSource.USER,
    embedding: Sequence[float] | np.ndarray | None = None,
    embedding_model: str | None = None,
) -> Answer:
    """Insert, or update the existing answer with the same question (case-insensitive).

    ``is_template`` defaults to True when the answer contains ``{company}``/``{role}``.
    """
    if is_template is None:
        is_template = bool(re.search(r"\{(company|role)\}", answer))
    ts = now_ts()
    emb = pack_embedding(embedding) if embedding is not None else None
    with transaction(conn):
        existing = _one(conn, "SELECT id FROM answers WHERE canonical_question = ? COLLATE NOCASE", (canonical_question,))
        if existing:
            aid = int(existing["id"])
            conn.execute(
                "UPDATE answers SET answer = ?, field_type = ?, is_template = ?, source = ?, "
                "embedding = COALESCE(?, embedding), embedding_model = COALESCE(?, embedding_model), updated_at = ? WHERE id = ?",
                (answer, FieldType(field_type).value, int(is_template), AnswerSource(source).value, emb, embedding_model, ts, aid),
            )
        else:
            cur = conn.execute(
                "INSERT INTO answers(canonical_question, answer, field_type, is_template, embedding, embedding_model, source, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (canonical_question, answer, FieldType(field_type).value, int(is_template), emb, embedding_model, AnswerSource(source).value, ts, ts),
            )
            aid = int(cur.lastrowid)
    return get_answer(conn, aid)


def get_answer(conn: sqlite3.Connection, answer_id: int) -> Answer:
    return Answer.from_row(_require(_one(conn, "SELECT * FROM answers WHERE id = ?", (answer_id,)), "answer", answer_id))  # type: ignore[return-value]


def find_answer_by_question(conn: sqlite3.Connection, question: str) -> Answer | None:
    row = _one(conn, "SELECT * FROM answers WHERE canonical_question = ? COLLATE NOCASE", (question,))
    return Answer.from_row(row) if row else None  # type: ignore[return-value]


def list_answers(conn: sqlite3.Connection) -> list[Answer]:
    return [Answer.from_row(r) for r in conn.execute("SELECT * FROM answers ORDER BY uses DESC, id")]  # type: ignore[misc]


def update_answer(conn: sqlite3.Connection, answer_id: int, *, answer: str, canonical_question: str | None = None) -> Answer:
    ts = now_ts()
    with transaction(conn):
        get_answer(conn, answer_id)
        fields: dict[str, Any] = {
            "answer": answer,
            "is_template": int(bool(re.search(r"\{(company|role)\}", answer))),
            "source": AnswerSource.USER.value,
            "updated_at": ts,
        }
        if canonical_question is not None:
            fields["canonical_question"] = canonical_question
            fields["embedding"] = None  # stale; memory layer re-embeds
            fields["embedding_model"] = None
        sql, params = _update_sql("answers", fields, "id = ?")
        conn.execute(sql, [*params, answer_id])
    return get_answer(conn, answer_id)


def delete_answer(conn: sqlite3.Connection, answer_id: int) -> None:
    with transaction(conn):
        if conn.execute("DELETE FROM answers WHERE id = ?", (answer_id,)).rowcount == 0:
            raise NotFound(f"answer {answer_id} not found")


def record_answer_use(conn: sqlite3.Connection, answer_id: int) -> None:
    ts = now_ts()
    with transaction(conn):
        conn.execute("UPDATE answers SET uses = uses + 1, last_used_at = ? WHERE id = ?", (ts, answer_id))


def set_answer_embedding(conn: sqlite3.Connection, answer_id: int, vec: Sequence[float] | np.ndarray, model: str) -> None:
    with transaction(conn):
        conn.execute(
            "UPDATE answers SET embedding = ?, embedding_model = ? WHERE id = ?", (pack_embedding(vec), model, answer_id)
        )


def get_answer_embeddings(conn: sqlite3.Connection, model: str | None = None) -> list[tuple[int, np.ndarray]]:
    """(answer_id, vector) for answers that have an embedding (optionally from ``model``)."""
    sql = "SELECT id, embedding FROM answers WHERE embedding IS NOT NULL"
    params: tuple[Any, ...] = ()
    if model is not None:
        sql += " AND embedding_model = ?"
        params = (model,)
    return [(int(r["id"]), unpack_embedding(r["embedding"])) for r in conn.execute(sql, params)]  # type: ignore[misc]


# =====================================================================================
# companies
# =====================================================================================


def upsert_company(
    conn: sqlite3.Connection,
    name: str,
    *,
    domain: str | None = None,
    ats: Ats | str | None = None,
    board_token: str | None = None,
    careers_url: str | None = None,
    watch: bool | None = None,
) -> Company:
    """Insert by normalized name, or fill in/overwrite the non-None fields given."""
    norm = normalize_text(name)
    if not norm:
        raise ValueError("company name is empty")
    ts = now_ts()
    with transaction(conn):
        row = _one(conn, "SELECT id FROM companies WHERE normalized_name = ?", (norm,))
        if row is None:
            cur = conn.execute(
                "INSERT INTO companies(name, normalized_name, domain, ats, board_token, careers_url, watch, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (name.strip(), norm, domain, Ats(ats).value if ats else None, board_token, careers_url, int(bool(watch)), ts, ts),
            )
            cid = int(cur.lastrowid)
        else:
            cid = int(row["id"])
            fields: dict[str, Any] = {}
            if domain is not None:
                fields["domain"] = domain
            if ats is not None:
                fields["ats"] = Ats(ats).value
            if board_token is not None:
                fields["board_token"] = board_token
            if careers_url is not None:
                fields["careers_url"] = careers_url
            if watch is not None:
                fields["watch"] = int(watch)
            if fields:
                fields["updated_at"] = ts
                sql, params = _update_sql("companies", fields, "id = ?")
                conn.execute(sql, [*params, cid])
    return get_company(conn, cid)


def get_company(conn: sqlite3.Connection, company_id: int) -> Company:
    return Company.from_row(_require(_one(conn, "SELECT * FROM companies WHERE id = ?", (company_id,)), "company", company_id))  # type: ignore[return-value]


def get_company_by_name(conn: sqlite3.Connection, name: str) -> Company | None:
    row = _one(conn, "SELECT * FROM companies WHERE normalized_name = ?", (normalize_text(name),))
    return Company.from_row(row) if row else None  # type: ignore[return-value]


def list_companies(conn: sqlite3.Connection, *, watch_only: bool = False) -> list[Company]:
    sql = "SELECT * FROM companies" + (" WHERE watch = 1" if watch_only else "") + " ORDER BY name COLLATE NOCASE"
    return [Company.from_row(r) for r in conn.execute(sql)]  # type: ignore[misc]


def company_in_cooldown(conn: sqlite3.Connection, company_id: int, cooldown_days: int, now: datetime | None = None) -> bool:
    """True if we applied to this company within ``cooldown_days``."""
    row = _one(conn, "SELECT last_applied_at FROM companies WHERE id = ?", (company_id,))
    if row is None or row["last_applied_at"] is None or cooldown_days <= 0:
        return False
    last = parse_ts(row["last_applied_at"])
    return (now or utcnow()) - last < timedelta(days=cooldown_days)


# =====================================================================================
# jobs (+ the application row created with each job)
# =====================================================================================


def insert_job(
    conn: sqlite3.Connection,
    *,
    company_id: int,
    source: JobSource | str,
    title: str,
    location: str | None = None,
    apply_url: str | None = None,
    source_url: str | None = None,
    ats: Ats | str = Ats.OTHER,
    external_id: str | None = None,
    remote: str | None = None,
    salary_min: int | None = None,
    salary_max: int | None = None,
    salary_currency: str | None = None,
    description: str | None = None,
    posted_at: datetime | str | None = None,
    easy_apply: bool = False,
    raw: dict[str, Any] | None = None,
) -> tuple[Job, bool]:
    """Insert a discovered job unless it's a duplicate (dedupe_key or normalized apply URL).

    Returns ``(job, created)``. When created, an ``applications`` row in state
    ``discovered`` is inserted in the same transaction and a ``discover`` event logged.
    """
    company = get_company(conn, company_id)
    key = make_dedupe_key(company.name, title, location)
    url_norm = normalize_url(apply_url)
    ts = now_ts()
    with transaction(conn):
        dup = _one(conn, "SELECT id FROM jobs WHERE dedupe_key = ?", (key,))
        if dup is None and url_norm is not None:
            dup = _one(conn, "SELECT id FROM jobs WHERE apply_url_norm = ?", (url_norm,))
        if dup is not None:
            return get_job(conn, int(dup["id"])), False
        cur = conn.execute(
            "INSERT INTO jobs(source, source_url, apply_url, apply_url_norm, ats, external_id, company_id, title, location, remote, "
            "salary_min, salary_max, salary_currency, description, posted_at, discovered_at, easy_apply, raw, dedupe_key) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                JobSource(source).value, source_url, apply_url, url_norm, Ats(ats).value, external_id, company_id, title,
                location, remote, salary_min, salary_max, salary_currency, description, _ts(posted_at), ts,
                int(easy_apply), _j(raw or {}), key,
            ),
        )
        job_id = int(cur.lastrowid)
        app_cur = conn.execute(
            "INSERT INTO applications(job_id, state, state_updated_at, created_at, updated_at) VALUES (?, 'discovered', ?, ?, ?)",
            (job_id, ts, ts, ts),
        )
        log_event(
            conn, "discover", f"discovered {company.name} · {title}", job_id=job_id,
            application_id=int(app_cur.lastrowid), payload={"source": JobSource(source).value, "ats": Ats(ats).value},
        )
    return get_job(conn, job_id), True


def get_job(conn: sqlite3.Connection, job_id: int) -> Job:
    return Job.from_row(_require(_one(conn, "SELECT * FROM jobs WHERE id = ?", (job_id,)), "job", job_id))  # type: ignore[return-value]


def listing_already_stored(conn: sqlite3.Connection, source: str, external_id: str | None, detail_url: str | None) -> bool:
    """True when a LinkedIn/Glassdoor listing is already in ``jobs`` (so its detail page needn't be re-read)."""
    if not external_id and not detail_url:
        return False
    row = conn.execute(
        "SELECT 1 FROM jobs WHERE source = ? AND ((? IS NOT NULL AND external_id = ?) OR (? IS NOT NULL AND source_url = ?)) LIMIT 1",
        (source, external_id, external_id, detail_url, detail_url),
    ).fetchone()
    return row is not None


def find_job_by_apply_url(conn: sqlite3.Connection, apply_url: str) -> Job | None:
    norm = normalize_url(apply_url)
    row = _one(conn, "SELECT * FROM jobs WHERE apply_url_norm = ?", (norm,)) if norm else None
    return Job.from_row(row) if row else None  # type: ignore[return-value]


def list_jobs(
    conn: sqlite3.Connection,
    *,
    states: Iterable[AppState | str] | None = None,
    source: JobSource | str | None = None,
    limit: int | None = None,
) -> list[Job]:
    """Jobs (newest first), optionally filtered by their application state / source."""
    sql = "SELECT j.* FROM jobs j JOIN applications a ON a.job_id = j.id"
    where: list[str] = []
    params: list[Any] = []
    if states is not None:
        st = [AppState(s).value for s in states]
        where.append(f"a.state IN ({','.join('?' * len(st))})")
        params.extend(st)
    if source is not None:
        where.append("j.source = ?")
        params.append(JobSource(source).value)
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY j.discovered_at DESC, j.id DESC"
    if limit is not None:
        sql += " LIMIT ?"
        params.append(int(limit))
    return [Job.from_row(r) for r in conn.execute(sql, params)]  # type: ignore[misc]


def update_job(conn: sqlite3.Connection, job_id: int, **fields: Any) -> Job:
    """Update mutable job columns (description, salary_*, apply_url, ats, notes, raw, ...)."""
    allowed = {
        "source_url", "apply_url", "ats", "external_id", "location", "remote", "salary_min", "salary_max",
        "salary_currency", "description", "posted_at", "easy_apply", "notes", "raw", "mode_override",
    }
    bad = set(fields) - allowed
    if bad:
        raise ValueError(f"cannot update job fields: {sorted(bad)}")
    if "apply_url" in fields:
        fields["apply_url_norm"] = normalize_url(fields["apply_url"])
    if "raw" in fields:
        fields["raw"] = _j(fields["raw"])
    if "easy_apply" in fields:
        fields["easy_apply"] = int(bool(fields["easy_apply"]))
    if "posted_at" in fields:
        fields["posted_at"] = _ts(fields["posted_at"])
    for k in ("ats", "mode_override", "remote"):
        if k in fields and fields[k] is not None:
            fields[k] = str(getattr(fields[k], "value", fields[k]))
    with transaction(conn):
        get_job(conn, job_id)
        if fields:
            sql, params = _update_sql("jobs", fields, "id = ?")
            conn.execute(sql, [*params, job_id])
    return get_job(conn, job_id)


def set_job_mode_override(conn: sqlite3.Connection, job_id: int, mode: Mode | str | None) -> Job:
    return update_job(conn, job_id, mode_override=Mode(mode).value if mode else None)


def job_summary(conn: sqlite3.Connection, job_id: int) -> JobSummary:
    row = _require(
        _one(
            conn,
            "SELECT j.*, c.name AS company_name, a.id AS application_id FROM jobs j "
            "JOIN companies c ON c.id = j.company_id LEFT JOIN applications a ON a.job_id = j.id WHERE j.id = ?",
            (job_id,),
        ),
        "job", job_id,
    )
    return JobSummary(
        id=row["id"], application_id=row["application_id"], company_id=row["company_id"], company=row["company_name"],
        title=row["title"], location=row["location"], remote=row["remote"], source=row["source"], ats=row["ats"],
        apply_url=row["apply_url"], source_url=row["source_url"], easy_apply=bool(row["easy_apply"]),
        salary_min=row["salary_min"], salary_max=row["salary_max"], salary_currency=row["salary_currency"],
        discovered_at=row["discovered_at"],
    )


# =====================================================================================
# scores
# =====================================================================================


def upsert_score(
    conn: sqlite3.Connection,
    job_id: int,
    *,
    score: int | None,
    reasons: dict[str, Any] | None = None,
    skip_reason: str | None = None,
    model: str | None = None,
    tokens_in: int = 0,
    tokens_out: int = 0,
    basis: str | None = None,
) -> Score:
    ts = now_ts()
    with transaction(conn):
        conn.execute(
            "INSERT INTO scores(job_id, score, reasons, skip_reason, model, tokens_in, tokens_out, basis, scored_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(job_id) DO UPDATE SET score = excluded.score, reasons = excluded.reasons, skip_reason = excluded.skip_reason, "
            "model = excluded.model, tokens_in = excluded.tokens_in, tokens_out = excluded.tokens_out, basis = excluded.basis, "
            "scored_at = excluded.scored_at",
            (job_id, score, _j(reasons or {}), skip_reason, model, tokens_in, tokens_out, basis, ts),
        )
    return get_score(conn, job_id)  # type: ignore[return-value]


def get_score(conn: sqlite3.Connection, job_id: int) -> Score | None:
    row = _one(conn, "SELECT * FROM scores WHERE job_id = ?", (job_id,))
    return Score.from_row(row) if row else None  # type: ignore[return-value]


# =====================================================================================
# applications + STATE MACHINE
# =====================================================================================


@dataclass(frozen=True, slots=True)
class Transition:
    application_id: int
    job_id: int
    from_state: AppState
    to_state: AppState
    reason: str | None
    actor: Actor
    at: str

    def to_payload(self) -> ApplicationStatePayload:
        """The ``application_state`` event payload the daemon should broadcast."""
        return ApplicationStatePayload(
            application_id=self.application_id, job_id=self.job_id, from_state=self.from_state,
            to_state=self.to_state, reason=self.reason, actor=self.actor, at=self.at,
        )


def get_application(conn: sqlite3.Connection, application_id: int) -> Application:
    row = _require(_one(conn, "SELECT * FROM applications WHERE id = ?", (application_id,)), "application", application_id)
    return Application.from_row(row)  # type: ignore[return-value]


def get_application_by_job(conn: sqlite3.Connection, job_id: int) -> Application:
    row = _require(_one(conn, "SELECT * FROM applications WHERE job_id = ?", (job_id,)), "application for job", job_id)
    return Application.from_row(row)  # type: ignore[return-value]


def list_applications(
    conn: sqlite3.Connection,
    *,
    states: Iterable[AppState | str] | None = None,
    statuses: Iterable[BoardStatus | str] | None = None,
    limit: int | None = None,
) -> list[Application]:
    where: list[str] = []
    params: list[Any] = []
    if states is not None:
        st = [AppState(s).value for s in states]
        where.append(f"state IN ({','.join('?' * len(st))})")
        params.extend(st)
    if statuses is not None:
        ss = [BoardStatus(s).value for s in statuses]
        where.append(f"status IN ({','.join('?' * len(ss))})")
        params.extend(ss)
    sql = "SELECT * FROM applications" + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY state_updated_at, id"
    if limit is not None:
        sql += " LIMIT ?"
        params.append(int(limit))
    return [Application.from_row(r) for r in conn.execute(sql, params)]  # type: ignore[misc]


_APP_UPDATABLE = {
    "mode", "resume_variant_id", "resume_pick_score", "cover_letter_path", "screenshot_path",
    "confirmation_screenshot_path", "notes",
}


def update_application(conn: sqlite3.Connection, application_id: int, **fields: Any) -> Application:
    """Update non-state columns. State changes MUST use :func:`transition`."""
    bad = set(fields) - _APP_UPDATABLE
    if bad:
        raise ValueError(f"cannot update application fields via update_application: {sorted(bad)}")
    if "mode" in fields and fields["mode"] is not None:
        fields["mode"] = ApplicationMode(fields["mode"]).value
    with transaction(conn):
        get_application(conn, application_id)
        if fields:
            fields["updated_at"] = now_ts()
            sql, params = _update_sql("applications", fields, "id = ?")
            conn.execute(sql, [*params, application_id])
    return get_application(conn, application_id)


def add_application_tokens(conn: sqlite3.Connection, application_id: int, tokens_in: int, tokens_out: int) -> None:
    with transaction(conn):
        conn.execute(
            "UPDATE applications SET tokens_in = tokens_in + ?, tokens_out = tokens_out + ? WHERE id = ?",
            (int(tokens_in), int(tokens_out), application_id),
        )


def transition(
    conn: sqlite3.Connection,
    application_id: int,
    to_state: AppState | str,
    *,
    reason: str | None = None,
    actor: Actor | str = Actor.AGENT,
    expected_from: AppState | str | Iterable[AppState | str] | None = None,
    run_id: int | None = None,
) -> Transition:
    """Move an application to ``to_state`` if the state machine allows it.

    * Raises :class:`IllegalTransition` for edges not in ``ALLOWED_TRANSITIONS``, for
      user-only edges attempted by a non-user actor, or when ``expected_from`` doesn't match.
    * Writes the ``applications`` row and an ``events`` row (kind ``state``) atomically.
    * Entering ``submitted`` stamps ``submitted_at``, sets board status ``applied`` and the
      company's ``last_applied_at``.
    """
    to = AppState(to_state)
    actor = Actor(actor)
    with transaction(conn):
        row = _require(_one(conn, "SELECT id, job_id, state FROM applications WHERE id = ?", (application_id,)), "application", application_id)
        frm = AppState(row["state"])
        if expected_from is not None:
            exp = {AppState(expected_from)} if isinstance(expected_from, (str, AppState)) else {AppState(s) for s in expected_from}
            if frm not in exp:
                raise IllegalTransition(application_id, frm, to, actor, f"expected from {sorted(e.value for e in exp)}")
        if to not in ALLOWED_TRANSITIONS[frm]:
            raise IllegalTransition(application_id, frm, to, actor, "edge not allowed")
        if (frm, to) in USER_ONLY_TRANSITIONS and actor is not Actor.USER:
            raise IllegalTransition(application_id, frm, to, actor, "user-only transition")
        ts = now_ts()
        fields: dict[str, Any] = {"state": to.value, "state_reason": reason, "state_updated_at": ts, "updated_at": ts}
        if to is AppState.SUBMITTED:
            fields.update(submitted_at=ts, status=BoardStatus.APPLIED.value, status_updated_at=ts)
        sql, params = _update_sql("applications", fields, "id = ? AND state = ?")
        if conn.execute(sql, [*params, application_id, frm.value]).rowcount != 1:  # pragma: no cover - guarded by tx
            raise Conflict(f"application {application_id} changed concurrently")
        if to is AppState.SUBMITTED:
            conn.execute(
                "UPDATE companies SET last_applied_at = ?, updated_at = ? WHERE id = (SELECT company_id FROM jobs WHERE id = ?)",
                (ts, ts, row["job_id"]),
            )
        log_event(
            conn, "state", f"{frm.value} → {to.value}" + (f" ({reason})" if reason else ""),
            actor=actor, level=LogLevel.ERROR if to is AppState.FAILED else LogLevel.INFO,
            job_id=row["job_id"], application_id=application_id, run_id=run_id,
            payload={"from": frm.value, "to": to.value, "reason": reason},
        )
    return Transition(application_id, int(row["job_id"]), frm, to, reason, actor, ts)


def begin_submit(conn: sqlite3.Connection, application_id: int, *, actor: Actor | str = Actor.AGENT, run_id: int | None = None) -> Transition:
    """Durably record ``submitting`` BEFORE the submit click. Call guardrails (caps,
    cooldown, pause) first; only click submit after this returns."""
    return transition(
        conn, application_id, AppState.SUBMITTING, actor=actor, run_id=run_id,
        expected_from=(AppState.FILLING, AppState.AWAITING_REVIEW),
    )


def complete_submit(
    conn: sqlite3.Connection,
    application_id: int,
    *,
    confirmation_screenshot_path: str | None = None,
    run_id: int | None = None,
) -> Transition:
    """``submitting`` -> ``submitted`` once the confirmation page is verified."""
    with transaction(conn):
        if confirmation_screenshot_path is not None:
            update_application(conn, application_id, confirmation_screenshot_path=confirmation_screenshot_path)
        return transition(conn, application_id, AppState.SUBMITTED, expected_from=AppState.SUBMITTING, run_id=run_id)


@dataclass(slots=True)
class RecoveryReport:
    unknown_verify: list[Transition] = field(default_factory=list)  # were 'submitting'
    requeued: list[Transition] = field(default_factory=list)  # were 'prepping' / 'filling'


def recover_interrupted_submissions(conn: sqlite3.Connection) -> list[Transition]:
    """Every application left in ``submitting`` -> ``unknown_verify`` (never auto-retried)."""
    out: list[Transition] = []
    with transaction(conn):
        for r in conn.execute("SELECT id FROM applications WHERE state = 'submitting'").fetchall():
            out.append(
                transition(conn, int(r["id"]), AppState.UNKNOWN_VERIFY, reason="crash_during_submit", actor=Actor.SYSTEM)
            )
    return out


def recover_after_crash(conn: sqlite3.Connection) -> RecoveryReport:
    """Daemon start-up recovery.

    * ``submitting`` -> ``unknown_verify`` (the click may or may not have happened).
    * ``prepping`` / ``filling`` -> ``queued`` (nothing was submitted; safe to redo).
    """
    report = RecoveryReport()
    with transaction(conn):
        report.unknown_verify = recover_interrupted_submissions(conn)
        stale = [s.value for s in ACTIVE_STATES if s is not AppState.SUBMITTING]
        rows = conn.execute(
            f"SELECT id FROM applications WHERE state IN ({','.join('?' * len(stale))})", stale
        ).fetchall()
        for r in rows:
            report.requeued.append(
                transition(conn, int(r["id"]), AppState.QUEUED, reason="interrupted", actor=Actor.SYSTEM)
            )
    return report


def set_status(
    conn: sqlite3.Connection,
    application_id: int,
    status: BoardStatus | str,
    *,
    actor: Actor | str = Actor.USER,
) -> ApplicationStatusPayload:
    """Set the manual board status. Only valid once ``state == submitted``."""
    new = BoardStatus(status)
    actor = Actor(actor)
    with transaction(conn):
        app = get_application(conn, application_id)
        if app.state is not AppState.SUBMITTED:
            raise IllegalTransition(application_id, app.state, app.state, actor, f"board status requires submitted (is {app.state.value})")
        ts = now_ts()
        conn.execute(
            "UPDATE applications SET status = ?, status_updated_at = ?, updated_at = ? WHERE id = ?",
            (new.value, ts, ts, application_id),
        )
        log_event(
            conn, "status", f"status {app.status.value if app.status else None} → {new.value}", actor=actor,
            job_id=app.job_id, application_id=application_id,
            payload={"from": app.status.value if app.status else None, "to": new.value},
        )
    return ApplicationStatusPayload(
        application_id=application_id, job_id=app.job_id, previous_status=app.status, status=new, actor=actor, at=ts
    )


def mark_manually_applied(conn: sqlite3.Connection, job_id: int) -> Application:
    """Record that the USER applied manually (LinkedIn Easy Apply). Sets state ``submitted``
    with mode ``manual`` and board status ``applied``. Bypasses the agent edges on purpose."""
    with transaction(conn):
        app = get_application_by_job(conn, job_id)
        if app.state not in MANUAL_SUBMIT_FROM:
            raise IllegalTransition(app.id, app.state, AppState.SUBMITTED, Actor.USER, "manual apply not allowed from this state")
        ts = now_ts()
        conn.execute(
            "UPDATE applications SET state = 'submitted', state_reason = 'manual_easy_apply', state_updated_at = ?, mode = 'manual', "
            "submitted_at = ?, status = 'applied', status_updated_at = ?, updated_at = ? WHERE id = ?",
            (ts, ts, ts, ts, app.id),
        )
        conn.execute(
            "UPDATE companies SET last_applied_at = ?, updated_at = ? WHERE id = (SELECT company_id FROM jobs WHERE id = ?)",
            (ts, ts, job_id),
        )
        log_event(
            conn, "state", f"{app.state.value} → submitted (manual Easy Apply)", actor=Actor.USER, job_id=job_id,
            application_id=app.id, payload={"from": app.state.value, "to": "submitted", "reason": "manual_easy_apply"},
        )
    return get_application(conn, app.id)


def count_submitted_since(conn: sqlite3.Connection, since: datetime, *, include_manual: bool = False) -> int:
    sql = "SELECT COUNT(*) FROM applications WHERE submitted_at >= ?"
    if not include_manual:
        sql += " AND (mode IS NULL OR mode <> 'manual')"
    return int(conn.execute(sql, (format_ts(since),)).fetchone()[0])


def submitted_today(conn: sqlite3.Connection, now: datetime | None = None) -> int:
    """Agent submissions since local midnight (what the daily cap counts)."""
    return count_submitted_since(conn, local_day_start(now))


def unconfirmed_attempts_today(conn: sqlite3.Connection, now: datetime | None = None) -> int:
    """Agent submissions whose outcome is not known: in flight (``submitting``, any age) or
    ``unknown_verify`` since local midnight. The click may have happened, so they count toward
    the daily cap exactly like ``submitted`` rows."""
    since = format_ts(local_day_start(now))
    row = conn.execute(
        "SELECT COUNT(*) FROM applications WHERE (mode IS NULL OR mode <> 'manual') AND "
        "(state = 'submitting' OR (state = 'unknown_verify' AND state_updated_at >= ?))",
        (since,),
    ).fetchone()
    return int(row[0])


def attempts_used_today(conn: sqlite3.Connection, now: datetime | None = None) -> int:
    """What the daily cap counts: confirmed + in-flight + unverified agent submissions."""
    return submitted_today(conn, now) + unconfirmed_attempts_today(conn, now)


def company_attempt_at(
    conn: sqlite3.Connection, company_id: int, cooldown_days: int, now: datetime | None = None,
    *, exclude_application_id: int | None = None,
) -> datetime | None:
    """When an application to this company is in flight (``submitting``) or ended in
    ``unknown_verify`` within the cooldown window, return that time (else ``None``).

    ``companies.last_applied_at`` is only written on ``submitted``; an ambiguous submit must
    still block a second application to the same company."""
    if cooldown_days <= 0:
        return None
    since = format_ts((now or utcnow()) - timedelta(days=cooldown_days))
    row = conn.execute(
        "SELECT a.state_updated_at FROM applications a JOIN jobs j ON j.id = a.job_id "
        "WHERE j.company_id = ? AND a.id <> ? AND (a.state = 'submitting' OR "
        "(a.state = 'unknown_verify' AND a.state_updated_at >= ?)) "
        "ORDER BY a.state_updated_at DESC LIMIT 1",
        (company_id, -1 if exclude_application_id is None else exclude_application_id, since),
    ).fetchone()
    return parse_ts(row[0]) if row is not None and row[0] else None


def ghost_stale_applications(conn: sqlite3.Connection, ghost_after_days: int, now: datetime | None = None) -> list[ApplicationStatusPayload]:
    """Auto-move ``applied`` applications with no status change for N days to ``ghosted``."""
    cutoff = format_ts((now or utcnow()) - timedelta(days=ghost_after_days))
    out: list[ApplicationStatusPayload] = []
    with transaction(conn):
        rows = conn.execute(
            "SELECT id FROM applications WHERE state = 'submitted' AND status = 'applied' AND status_updated_at < ?", (cutoff,)
        ).fetchall()
        for r in rows:
            out.append(set_status(conn, int(r["id"]), BoardStatus.GHOSTED, actor=Actor.SYSTEM))
    return out


def due_nudges(conn: sqlite3.Connection, nudge_days: Sequence[int], now: datetime | None = None) -> list[tuple[Application, int]]:
    """(application, day) for ``applied`` applications that crossed their next nudge day."""
    now = now or utcnow()
    days = sorted(nudge_days)
    out: list[tuple[Application, int]] = []
    for r in conn.execute("SELECT * FROM applications WHERE state = 'submitted' AND status = 'applied'"):
        app: Application = Application.from_row(r)  # type: ignore[assignment]
        if app.nudges_sent >= len(days) or app.submitted_at is None:
            continue
        day = days[app.nudges_sent]
        if now - app.submitted_at >= timedelta(days=day):
            out.append((app, day))
    return out


def record_nudge_sent(conn: sqlite3.Connection, application_id: int) -> None:
    with transaction(conn):
        conn.execute("UPDATE applications SET nudges_sent = nudges_sent + 1 WHERE id = ?", (application_id,))


# =====================================================================================
# application_answers (Q&A audit)
# =====================================================================================


def add_application_answer(
    conn: sqlite3.Connection,
    application_id: int,
    *,
    question: str,
    answer: str,
    origin: AnswerOrigin | str,
    field_type: FieldType | str = FieldType.TEXT,
    confidence: float | None = None,
    field_key: str | None = None,
    origin_ref: str | None = None,
    bbox: dict[str, float] | None = None,
) -> ApplicationAnswer:
    ts = now_ts()
    with transaction(conn):
        cur = conn.execute(
            "INSERT INTO application_answers(application_id, field_key, question, answer, field_type, confidence, origin, origin_ref, bbox, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (application_id, field_key, question, answer, FieldType(field_type).value, confidence,
             AnswerOrigin(origin).value, origin_ref, _j(bbox) if bbox is not None else None, ts, ts),
        )
    return get_application_answer(conn, int(cur.lastrowid))


def get_application_answer(conn: sqlite3.Connection, answer_id: int) -> ApplicationAnswer:
    row = _require(_one(conn, "SELECT * FROM application_answers WHERE id = ?", (answer_id,)), "application_answer", answer_id)
    return ApplicationAnswer.from_row(row)  # type: ignore[return-value]


def delete_application_answers(
    conn: sqlite3.Connection,
    application_id: int,
    field_keys: Sequence[str],
    *,
    keep_origins: Sequence[AnswerOrigin | str] = (AnswerOrigin.USER,),
) -> int:
    """Delete an application's recorded answers for ``field_keys`` (e.g. ones the pre-submit
    audit rejected) so the next fill re-resolves them. Rows whose origin is in
    ``keep_origins`` (by default the user's own edits / inbox answers) are kept.
    Returns the number of rows removed."""
    keys = [k for k in dict.fromkeys(field_keys) if k]
    if not keys:
        return 0
    keep = [o.value if isinstance(o, AnswerOrigin) else str(o) for o in keep_origins]
    sql = (f"DELETE FROM application_answers WHERE application_id = ? AND field_key IN ({','.join('?' * len(keys))})")
    params: list[Any] = [application_id, *keys]
    if keep:
        sql += f" AND origin NOT IN ({','.join('?' * len(keep))})"
        params.extend(keep)
    with transaction(conn):
        cur = conn.execute(sql, params)
    return int(cur.rowcount)


def list_application_answers(conn: sqlite3.Connection, application_id: int) -> list[ApplicationAnswer]:
    return [
        ApplicationAnswer.from_row(r)  # type: ignore[misc]
        for r in conn.execute("SELECT * FROM application_answers WHERE application_id = ? ORDER BY id", (application_id,))
    ]


def edit_application_answer(conn: sqlite3.Connection, answer_id: int, answer: str) -> ApplicationAnswer:
    """User edit from the Review queue: origin becomes ``user``, confidence 1.0."""
    with transaction(conn):
        aa = get_application_answer(conn, answer_id)
        conn.execute(
            "UPDATE application_answers SET answer = ?, origin = 'user', confidence = 1.0, updated_at = ? WHERE id = ?",
            (answer, now_ts(), answer_id),
        )
        log_event(conn, "user", f"edited answer to {aa.question!r}", actor=Actor.USER, application_id=aa.application_id,
                  payload={"application_answer_id": answer_id})
    return get_application_answer(conn, answer_id)


# =====================================================================================
# questions (Needs-You inbox)
# =====================================================================================


def add_question(
    conn: sqlite3.Connection,
    *,
    canonical_question: str,
    job_id: int,
    cluster_id: str | None = None,
    field_type: FieldType | str = FieldType.TEXT,
    options: Iterable[str] = (),
    never_guess_key: str | None = None,
    reason: QuestionReason | str = QuestionReason.UNKNOWN,
    embedding: Sequence[float] | np.ndarray | None = None,
    embedding_model: str | None = None,
    suggested_answer: str | None = None,
    suggested_confidence: float | None = None,
    suggested_note: str | None = None,
) -> tuple[Question, bool]:
    """Park ``job_id`` on a question. If an OPEN question with the same text exists, the job
    is added to it (options unioned) and ``created`` is False. Otherwise a new row is created
    in ``cluster_id`` (a fresh cluster when None). Returns ``(question, created)``."""
    opts = list(dict.fromkeys(options))
    with transaction(conn):
        row = _one(conn, "SELECT * FROM questions WHERE canonical_question = ? COLLATE NOCASE AND status = 'open'", (canonical_question,))
        if row is not None:
            jobs = json.loads(row["job_ids"])
            if job_id not in jobs:
                jobs.append(job_id)
            merged = list(dict.fromkeys([*json.loads(row["options"]), *opts]))
            conn.execute("UPDATE questions SET job_ids = ?, options = ? WHERE id = ?", (_j(jobs), _j(merged), row["id"]))
            if suggested_answer and not row["suggested_answer"]:
                conn.execute("UPDATE questions SET suggested_answer = ?, suggested_confidence = ?, suggested_note = ? WHERE id = ?",
                             (suggested_answer, suggested_confidence, suggested_note or None, row["id"]))
            return get_question(conn, int(row["id"])), False
        cur = conn.execute(
            "INSERT INTO questions(canonical_question, cluster_id, job_ids, field_type, options, never_guess_key, reason, embedding, embedding_model, "
            "suggested_answer, suggested_confidence, suggested_note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (canonical_question, cluster_id or new_id(), _j([job_id]), FieldType(field_type).value, _j(opts), never_guess_key,
             QuestionReason(reason).value, pack_embedding(embedding) if embedding is not None else None, embedding_model,
             suggested_answer or None, suggested_confidence, suggested_note or None, now_ts()),
        )
    return get_question(conn, int(cur.lastrowid)), True


def get_question(conn: sqlite3.Connection, question_id: int) -> Question:
    return Question.from_row(_require(_one(conn, "SELECT * FROM questions WHERE id = ?", (question_id,)), "question", question_id))  # type: ignore[return-value]


def list_questions(
    conn: sqlite3.Connection, *, status: QuestionStatus | str | None = None, cluster_id: str | None = None
) -> list[Question]:
    where, params = [], []
    if status is not None:
        where.append("status = ?")
        params.append(QuestionStatus(status).value)
    if cluster_id is not None:
        where.append("cluster_id = ?")
        params.append(cluster_id)
    sql = "SELECT * FROM questions" + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY id"
    return [Question.from_row(r) for r in conn.execute(sql, params)]  # type: ignore[misc]


def get_question_embeddings(conn: sqlite3.Connection, *, status: QuestionStatus | str = QuestionStatus.OPEN) -> list[tuple[int, str, np.ndarray | None]]:
    """(question_id, cluster_id, vector|None) for clustering."""
    return [
        (int(r["id"]), r["cluster_id"], unpack_embedding(r["embedding"]))
        for r in conn.execute("SELECT id, cluster_id, embedding FROM questions WHERE status = ?", (QuestionStatus(status).value,))
    ]


def set_question_cluster(conn: sqlite3.Connection, question_id: int, cluster_id: str) -> None:
    with transaction(conn):
        conn.execute("UPDATE questions SET cluster_id = ? WHERE id = ?", (cluster_id, question_id))


def set_question_embedding(conn: sqlite3.Connection, question_id: int, vec: Sequence[float] | np.ndarray, model: str) -> None:
    with transaction(conn):
        conn.execute("UPDATE questions SET embedding = ?, embedding_model = ? WHERE id = ?", (pack_embedding(vec), model, question_id))


def _cluster_from_rows(conn: sqlite3.Connection, rows: list[Question]) -> QuestionCluster:
    rows = sorted(rows, key=lambda q: q.id)
    first = rows[0]
    job_ids = list(dict.fromkeys(j for q in rows for j in q.job_ids))
    options = list(dict.fromkeys(o for q in rows for o in q.options))
    companies: list[str] = []
    if job_ids:
        qmarks = ",".join("?" * len(job_ids))
        companies = [
            r[0] for r in conn.execute(
                f"SELECT DISTINCT c.name FROM jobs j JOIN companies c ON c.id = j.company_id WHERE j.id IN ({qmarks}) ORDER BY c.name",
                job_ids,
            )
        ]
    ng_key = next((q.never_guess_key for q in rows if q.never_guess_key), None)
    reason = QuestionReason.NEVER_GUESS if ng_key else first.reason
    return QuestionCluster(
        cluster_id=first.cluster_id, canonical_question=first.canonical_question, field_type=first.field_type,
        options=options, never_guess_key=ng_key, reason=reason, question_ids=[q.id for q in rows],
        variants=list(dict.fromkeys(q.canonical_question for q in rows)), job_ids=job_ids,
        job_count=len(job_ids), companies=companies, created_at=first.created_at,
        suggested_answer=next((q.suggested_answer for q in rows if q.suggested_answer), None),
        suggested_confidence=next((q.suggested_confidence for q in rows if q.suggested_answer), None),
        suggested_note=next((q.suggested_note for q in rows if q.suggested_answer), None),
    )


def list_open_clusters(conn: sqlite3.Connection) -> list[QuestionCluster]:
    """Open clusters sorted by impact (jobs unblocked) desc, then age."""
    by_cluster: dict[str, list[Question]] = {}
    for q in list_questions(conn, status=QuestionStatus.OPEN):
        by_cluster.setdefault(q.cluster_id, []).append(q)
    clusters = [_cluster_from_rows(conn, qs) for qs in by_cluster.values()]
    clusters.sort(key=lambda c: (-c.job_count, c.created_at))
    return clusters


def get_cluster(conn: sqlite3.Connection, cluster_id: str, *, open_only: bool = True) -> QuestionCluster | None:
    qs = list_questions(conn, cluster_id=cluster_id, status=QuestionStatus.OPEN if open_only else None)
    return _cluster_from_rows(conn, qs) if qs else None


def resolve_cluster(
    conn: sqlite3.Connection,
    cluster_id: str,
    *,
    status: QuestionStatus | str = QuestionStatus.ANSWERED,
    answer_text: str | None = None,
    answer_id: int | None = None,
) -> list[int]:
    """Mark every open question in the cluster answered/skipped. Returns the affected job ids.

    Does NOT move applications; the caller decides (e.g. needs_you -> queued for jobs that
    have no other open questions, see :func:`jobs_without_open_questions`).
    """
    st = QuestionStatus(status)
    if st is QuestionStatus.OPEN:
        raise ValueError("resolve_cluster status must be answered or skipped")
    with transaction(conn):
        qs = list_questions(conn, cluster_id=cluster_id, status=QuestionStatus.OPEN)
        if not qs:
            raise NotFound(f"open cluster {cluster_id!r} not found")
        ts = now_ts()
        conn.execute(
            "UPDATE questions SET status = ?, answer_text = ?, answer_id = ?, resolved_at = ? WHERE cluster_id = ? AND status = 'open'",
            (st.value, answer_text, answer_id, ts, cluster_id),
        )
        job_ids = list(dict.fromkeys(j for q in qs for j in q.job_ids))
        log_event(
            conn, "answer" if st is QuestionStatus.ANSWERED else "skip",
            f"{st.value} {qs[0].canonical_question!r} ({len(job_ids)} jobs)", actor=Actor.USER,
            payload={"cluster_id": cluster_id, "job_ids": job_ids, "answer_id": answer_id},
        )
    return job_ids


def jobs_with_open_questions(conn: sqlite3.Connection) -> set[int]:
    out: set[int] = set()
    for r in conn.execute("SELECT job_ids FROM questions WHERE status = 'open'"):
        out.update(json.loads(r["job_ids"]))
    return out


def jobs_without_open_questions(conn: sqlite3.Connection, job_ids: Iterable[int]) -> list[int]:
    blocked = jobs_with_open_questions(conn)
    return [j for j in job_ids if j not in blocked]


def remove_job_from_questions(conn: sqlite3.Connection, job_id: int) -> None:
    """Detach a job from open questions (e.g. it was skipped); empty questions are skipped."""
    with transaction(conn):
        for r in conn.execute("SELECT id, job_ids FROM questions WHERE status = 'open'").fetchall():
            jobs = json.loads(r["job_ids"])
            if job_id in jobs:
                jobs.remove(job_id)
                if jobs:
                    conn.execute("UPDATE questions SET job_ids = ? WHERE id = ?", (_j(jobs), r["id"]))
                else:
                    conn.execute(
                        "UPDATE questions SET job_ids = '[]', status = 'skipped', resolved_at = ? WHERE id = ?", (now_ts(), r["id"])
                    )


# =====================================================================================
# easy_apply
# =====================================================================================


def upsert_easy_apply(
    conn: sqlite3.Connection,
    job_id: int,
    *,
    url: str,
    drafted_answers: Iterable[DraftedAnswer | dict[str, Any]] = (),
    resume_variant_id: int | None = None,
) -> EasyApplyItem:
    drafts = [DraftedAnswer.model_validate(d) if isinstance(d, dict) else d for d in drafted_answers]
    ts = now_ts()
    with transaction(conn):
        conn.execute(
            "INSERT INTO easy_apply(job_id, url, drafted_answers, resume_variant_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(job_id) DO UPDATE SET url = excluded.url, drafted_answers = excluded.drafted_answers, "
            "resume_variant_id = excluded.resume_variant_id, updated_at = excluded.updated_at",
            (job_id, url, _j(drafts), resume_variant_id, ts, ts),
        )
    return get_easy_apply(conn, job_id)


def get_easy_apply(conn: sqlite3.Connection, job_id: int) -> EasyApplyItem:
    row = _require(_one(conn, "SELECT * FROM easy_apply WHERE job_id = ?", (job_id,)), "easy_apply for job", job_id)
    return EasyApplyItem.from_row(row)  # type: ignore[return-value]


def list_easy_apply(conn: sqlite3.Connection, *, include_done: bool = False, include_dismissed: bool = False) -> list[EasyApplyItem]:
    where = []
    if not include_done:
        where.append("done = 0")
    if not include_dismissed:
        where.append("dismissed = 0")
    sql = "SELECT * FROM easy_apply" + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY created_at DESC, id DESC"
    return [EasyApplyItem.from_row(r) for r in conn.execute(sql)]  # type: ignore[misc]


def _easy_apply_flag(conn: sqlite3.Connection, job_id: int, column: str) -> EasyApplyItem:
    with transaction(conn):
        get_easy_apply(conn, job_id)
        conn.execute(f"UPDATE easy_apply SET {column} = 1, updated_at = ? WHERE job_id = ?", (now_ts(), job_id))
    return get_easy_apply(conn, job_id)


def mark_easy_apply_opened(conn: sqlite3.Connection, job_id: int) -> EasyApplyItem:
    return _easy_apply_flag(conn, job_id, "opened")


def dismiss_easy_apply(conn: sqlite3.Connection, job_id: int) -> EasyApplyItem:
    return _easy_apply_flag(conn, job_id, "dismissed")


def mark_easy_apply_done(conn: sqlite3.Connection, job_id: int) -> Application:
    """User applied manually: flag done and record the application as submitted (manual)."""
    with transaction(conn):
        get_easy_apply(conn, job_id)
        ts = now_ts()
        conn.execute("UPDATE easy_apply SET done = 1, opened = 1, done_at = ?, updated_at = ? WHERE job_id = ?", (ts, ts, job_id))
        return mark_manually_applied(conn, job_id)


# =====================================================================================
# events (append-only)
# =====================================================================================


def log_event(
    conn: sqlite3.Connection,
    kind: str,
    message: str,
    *,
    actor: Actor | str = Actor.AGENT,
    level: LogLevel | str = LogLevel.INFO,
    job_id: int | None = None,
    application_id: int | None = None,
    run_id: int | None = None,
    payload: dict[str, Any] | None = None,
) -> int:
    with transaction(conn):
        cur = conn.execute(
            "INSERT INTO events(ts, kind, actor, level, run_id, job_id, application_id, message, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (now_ts(), kind, Actor(actor).value, LogLevel(level).value, run_id, job_id, application_id, message, _j(payload or {})),
        )
    return int(cur.lastrowid)


def list_events(
    conn: sqlite3.Connection,
    *,
    after_id: int | None = None,
    limit: int = 200,
    job_id: int | None = None,
    application_id: int | None = None,
    kinds: Iterable[str] | None = None,
) -> list[EventRow]:
    """Events in ascending id order (``after_id`` for incremental tailing)."""
    where, params = [], []
    if after_id is not None:
        where.append("id > ?")
        params.append(after_id)
    if job_id is not None:
        where.append("job_id = ?")
        params.append(job_id)
    if application_id is not None:
        where.append("application_id = ?")
        params.append(application_id)
    if kinds is not None:
        ks = list(kinds)
        where.append(f"kind IN ({','.join('?' * len(ks))})")
        params.extend(ks)
    sql = "SELECT * FROM events" + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY id LIMIT ?"
    params.append(int(limit))
    return [EventRow.from_row(r) for r in conn.execute(sql, params)]  # type: ignore[misc]


# =====================================================================================
# runs
# =====================================================================================


def start_run(conn: sqlite3.Connection, kind: RunKind | str, trigger: RunTrigger | str = RunTrigger.MANUAL) -> Run:
    uid = new_id()
    with transaction(conn):
        if _one(conn, "SELECT 1 FROM runs WHERE finished_at IS NULL") is not None:
            raise Conflict("a run is already in progress")
        cur = conn.execute(
            "INSERT INTO runs(run_uid, kind, trigger, started_at) VALUES (?, ?, ?, ?)",
            (uid, RunKind(kind).value, RunTrigger(trigger).value, now_ts()),
        )
        log_event(conn, "run", f"{RunKind(kind).value} run started ({RunTrigger(trigger).value})", actor=Actor.SYSTEM,
                  run_id=int(cur.lastrowid), payload={"run_uid": uid})
    return get_run(conn, uid)


def finish_run(
    conn: sqlite3.Connection,
    run_uid: str,
    *,
    outcome: RunOutcome | str = RunOutcome.COMPLETED,
    stats: RunStats | dict[str, int] | None = None,
    tokens_in: int = 0,
    tokens_out: int = 0,
) -> Run:
    st = stats if isinstance(stats, RunStats) else RunStats.model_validate(stats or {})
    with transaction(conn):
        run = get_run(conn, run_uid)
        conn.execute(
            "UPDATE runs SET finished_at = ?, outcome = ?, stats = ?, tokens_in = tokens_in + ?, tokens_out = tokens_out + ? WHERE id = ?",
            (now_ts(), RunOutcome(outcome).value, _j(st), tokens_in, tokens_out, run.id),
        )
        log_event(conn, "run", f"run finished: {RunOutcome(outcome).value}", actor=Actor.SYSTEM, run_id=run.id,
                  payload={"run_uid": run_uid, "stats": st.model_dump()})
    return get_run(conn, run_uid)


def get_run(conn: sqlite3.Connection, run_uid: str) -> Run:
    return Run.from_row(_require(_one(conn, "SELECT * FROM runs WHERE run_uid = ?", (run_uid,)), "run", run_uid))  # type: ignore[return-value]


def get_current_run(conn: sqlite3.Connection) -> Run | None:
    row = _one(conn, "SELECT * FROM runs WHERE finished_at IS NULL ORDER BY id DESC LIMIT 1")
    return Run.from_row(row) if row else None  # type: ignore[return-value]


def get_last_run(conn: sqlite3.Connection) -> Run | None:
    row = _one(conn, "SELECT * FROM runs WHERE finished_at IS NOT NULL ORDER BY id DESC LIMIT 1")
    return Run.from_row(row) if row else None  # type: ignore[return-value]


def abandon_unfinished_runs(conn: sqlite3.Connection) -> int:
    """Close runs left open by a crash (outcome ``failed``). Call at daemon start."""
    with transaction(conn):
        return conn.execute(
            "UPDATE runs SET finished_at = ?, outcome = 'failed' WHERE finished_at IS NULL", (now_ts(),)
        ).rowcount


def run_info(run: Run) -> RunInfo:
    return RunInfo(
        run_id=run.run_uid, kind=run.kind, trigger=run.trigger, started_at=run.started_at, finished_at=run.finished_at,
        outcome=run.outcome, stats=run.stats, tokens_in=run.tokens_in, tokens_out=run.tokens_out,
    )


# =====================================================================================
# Aggregates for snapshot
# =====================================================================================


def compute_counts(conn: sqlite3.Connection, now: datetime | None = None) -> Counts:
    day = format_ts(local_day_start(now))
    by_state = {r[0]: r[1] for r in conn.execute("SELECT state, COUNT(*) FROM applications GROUP BY state")}
    clusters = list_open_clusters(conn)
    return Counts(
        queued=by_state.get("queued", 0),
        needs_you_clusters=len(clusters),
        needs_you_jobs=len({j for c in clusters for j in c.job_ids}),
        awaiting_review=by_state.get("awaiting_review", 0),
        easy_apply_open=int(conn.execute("SELECT COUNT(*) FROM easy_apply WHERE done = 0 AND dismissed = 0").fetchone()[0]),
        unknown_verify=by_state.get("unknown_verify", 0),
        failed=by_state.get("failed", 0),
        submitted_today=int(conn.execute("SELECT COUNT(*) FROM applications WHERE submitted_at >= ?", (day,)).fetchone()[0]),
        discovered_today=int(conn.execute("SELECT COUNT(*) FROM jobs WHERE discovered_at >= ?", (day,)).fetchone()[0]),
        submitted_total=by_state.get("submitted", 0),
    )


def compute_caps(conn: sqlite3.Connection, prefs: Preferences | None = None, now: datetime | None = None) -> CapsStatus:
    prefs = prefs or get_preferences(conn)
    now = now or utcnow()
    cooling = 0
    if prefs.per_company_cooldown_days > 0:
        cutoff = format_ts(now - timedelta(days=prefs.per_company_cooldown_days))
        cooling = int(conn.execute("SELECT COUNT(*) FROM companies WHERE last_applied_at >= ?", (cutoff,)).fetchone()[0])
    return CapsStatus(
        daily_used=submitted_today(conn, now),
        daily_limit=prefs.daily_cap,
        companies_cooling_down=cooling,
        linkedin_sessions_used=get_source_sessions(conn, "linkedin"),
        linkedin_sessions_limit=prefs.linkedin_sessions_per_day,
        glassdoor_sessions_used=get_source_sessions(conn, "glassdoor"),
        glassdoor_sessions_limit=prefs.glassdoor_sessions_per_day,
    )
