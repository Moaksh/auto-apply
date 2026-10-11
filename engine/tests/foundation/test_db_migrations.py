from __future__ import annotations

import re
import sqlite3

import pytest

from autoapply import db
from autoapply.enums import AnswerOrigin, AppState, Ats, BoardStatus, FieldType, JobSource
from autoapply.paths import schema_sql_path

EXPECTED_TABLES = {
    "schema_version", "meta", "profile", "never_guess", "preferences", "resume_variants", "stories",
    "answers", "companies", "jobs", "scores", "applications", "application_answers", "questions",
    "easy_apply", "runs", "events",
}


def tables(conn: sqlite3.Connection) -> set[str]:
    return {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")}


def test_fresh_migration_creates_all_tables(conn):
    assert EXPECTED_TABLES <= tables(conn)
    assert db.current_schema_version(conn) == db.SCHEMA_VERSION


def test_schema_sql_seeds_version_matching_engine():
    sql = schema_sql_path().read_text()
    seeded = re.findall(r"INSERT OR IGNORE INTO schema_version \(version\) VALUES \((\d+)\)", sql)
    assert seeded and max(int(v) for v in seeded) == db.SCHEMA_VERSION


def test_migrate_is_idempotent(conn):
    assert db.migrate(conn) == db.SCHEMA_VERSION
    assert db.migrate(conn) == db.SCHEMA_VERSION
    assert conn.execute("SELECT COUNT(*) FROM schema_version").fetchone()[0] == db.SCHEMA_VERSION
    assert conn.execute("SELECT COUNT(*) FROM preferences").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM profile").fetchone()[0] == 1


def test_pragmas(conn):
    assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    assert conn.execute("PRAGMA synchronous").fetchone()[0] == 2  # FULL


def test_foreign_keys_enforced(conn):
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO jobs(source, company_id, title, dedupe_key) VALUES ('greenhouse', 999, 't', 'k')"
        )


def test_newer_db_version_is_rejected(conn):
    conn.execute("INSERT INTO schema_version(version) VALUES (99)")
    with pytest.raises(db.DBError, match="newer"):
        db.migrate(conn)


def test_registered_migration_applies(conn, monkeypatch):
    monkeypatch.setattr(db, "SCHEMA_VERSION", 4)
    monkeypatch.setitem(db.MIGRATIONS, 4, "CREATE TABLE extra_test (id INTEGER PRIMARY KEY);")
    assert db.migrate(conn) == 4
    assert "extra_test" in tables(conn)


def test_missing_migration_errors(conn, monkeypatch):
    monkeypatch.setattr(db, "SCHEMA_VERSION", 5)
    with pytest.raises(db.DBError, match="no migration"):
        db.migrate(conn)


def test_readonly_connection_cannot_write(conn, autoapply_home):
    ro = db.connect(autoapply_home.db, readonly=True)
    try:
        assert ro.execute("SELECT COUNT(*) FROM preferences").fetchone()[0] == 1
        with pytest.raises(sqlite3.OperationalError):
            ro.execute("UPDATE preferences SET daily_cap = 1")
    finally:
        ro.close()


def test_reader_sees_committed_writes_during_wal(conn, autoapply_home):
    ro = db.connect(autoapply_home.db, readonly=True)
    try:
        db.upsert_company(conn, "Stripe")
        assert ro.execute("SELECT COUNT(*) FROM companies").fetchone()[0] == 1
    finally:
        ro.close()


def _check_list(sql: str, table: str, column: str) -> list[str]:
    """Extract the IN (...) list of the CHECK on ``table.column`` in schema.sql."""
    block = re.search(rf"CREATE TABLE IF NOT EXISTS {table} \((.*?)\n\);", sql, re.S)
    assert block, f"no table {table}"
    m = re.search(rf"CHECK \(\s*(?:{column} IS NULL OR )?{column} IN \(([^)]*)\)", block.group(1))
    assert m, f"no CHECK list for {table}.{column}"
    return re.findall(r"'([^']+)'", m.group(1))


@pytest.mark.parametrize(
    ("table", "column", "enum"),
    [("applications", "state", AppState), ("applications", "status", BoardStatus),
     ("application_answers", "origin", AnswerOrigin), ("questions", "field_type", FieldType),
     ("answers", "field_type", FieldType), ("jobs", "source", JobSource), ("jobs", "ats", Ats),
     ("companies", "ats", Ats)],
)
def test_schema_check_lists_match_enums(table, column, enum):
    assert set(_check_list(schema_sql_path().read_text(), table, column)) == {e.value for e in enum}


def test_check_constraints_reject_bad_enum(conn):
    co = db.upsert_company(conn, "Acme")
    job, _ = db.insert_job(conn, company_id=co.id, source="lever", title="SWE")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("UPDATE applications SET state = 'bogus' WHERE job_id = ?", (job.id,))
    with pytest.raises(sqlite3.IntegrityError):
        # board status only allowed when submitted
        conn.execute("UPDATE applications SET status = 'interview' WHERE job_id = ?", (job.id,))


def test_v1_database_upgrades_to_v2(tmp_path):
    """An existing v1 DB (no per-session limits) gains the columns with their defaults, keeping its data."""
    sql = schema_sql_path().read_text()
    v1 = "\n".join(
        line for line in sql.splitlines()
        if "searches_per_session" not in line and "jobs_per_session" not in line
        and "suggested_" not in line and "VALUES (2)" not in line and "VALUES (3)" not in line
    )
    c = sqlite3.connect(tmp_path / "v1.db")
    c.row_factory = sqlite3.Row
    c.executescript("BEGIN;\n" + v1 + "\nCOMMIT;")
    c.execute("UPDATE preferences SET daily_cap = 7")
    assert db.current_schema_version(c) == 1
    assert db.migrate(c) == db.SCHEMA_VERSION
    row = c.execute("SELECT daily_cap, searches_per_session, jobs_per_session FROM preferences").fetchone()
    assert (row[0], row[1], row[2]) == (7, 3, 30)
    c.close()
