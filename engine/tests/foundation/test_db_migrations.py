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
    nxt = db.SCHEMA_VERSION + 1
    monkeypatch.setattr(db, "SCHEMA_VERSION", nxt)
    monkeypatch.setitem(db.MIGRATIONS, nxt, "CREATE TABLE extra_test (id INTEGER PRIMARY KEY);")
    assert db.migrate(conn) == nxt
    assert "extra_test" in tables(conn)


def test_missing_migration_errors(conn, monkeypatch):
    monkeypatch.setattr(db, "SCHEMA_VERSION", db.SCHEMA_VERSION + 1)
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
        and "suggested_" not in line and not any(f"VALUES ({v})" in line for v in range(2, db.SCHEMA_VERSION + 1))
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


def test_suggested_note_reaches_cluster(conn):
    co = db.upsert_company(conn, "Acme")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="Eng")
    q, _ = db.add_question(conn, canonical_question="Remote experience?", job_id=job.id,
                           suggested_answer="I ship async.", suggested_confidence=0.4,
                           suggested_note="Add whether your roles were remote.")
    cluster = db.get_cluster(conn, q.cluster_id)
    assert cluster.suggested_answer == "I ship async."
    assert cluster.suggested_note == "Add whether your roles were remote."


# ---- v10 (cold outreach) ------------------------------------------------------------------------

V10_TABLES = ("contacts", "contact_evidence", "domain_patterns", "outreach_threads", "outreach_messages", "suppression",
              "referrals", "prospects")


def _v9_schema_sql() -> str:
    """schema.sql as it was at v9: without the outreach block, the v10 preference columns and row."""
    sql = schema_sql_path().read_text()
    start = sql.rindex("-- =", 0, sql.index("-- Cold outreach (v10)"))
    end = sql.rindex("-- -", 0, sql.index("-- updated_at maintenance"))
    sql = sql[:start] + sql[end:]
    return "\n".join(line for line in sql.splitlines()
                     if "-- v10" not in line and "-- v12" not in line
                     and not any(f"VALUES ({v})" in line for v in range(10, db.SCHEMA_VERSION + 1)))


def _v10_schema_sql() -> str:
    """schema.sql as it was at v10: without the employer-replies block and the v11 row."""
    sql = schema_sql_path().read_text()
    start = sql.rindex("-- =", 0, sql.index("-- Employer replies (v11)"))
    end = sql.rindex("-- -", 0, sql.index("-- updated_at maintenance"))
    sql = sql[:start] + sql[end:]
    return "\n".join(line for line in sql.splitlines()
                     if "-- v12" not in line and not any(f"VALUES ({v})" in line for v in range(11, db.SCHEMA_VERSION + 1)))


def _v11_schema_sql() -> str:
    """schema.sql as it was at v11: without the v12 columns and row."""
    sql = schema_sql_path().read_text()
    return "\n".join(line for line in sql.splitlines()
                     if "-- v12" not in line and not any(f"VALUES ({v})" in line for v in range(12, db.SCHEMA_VERSION + 1)))


def test_v10_database_upgrades_to_v11(tmp_path, conn):
    c = db.connect(tmp_path / "v10.db")
    c.executescript("BEGIN;\n" + _v10_schema_sql() + "\nCOMMIT;")
    assert db.current_schema_version(c) == 10
    assert "application_replies" not in tables(c)
    c.execute("INSERT INTO companies(name, normalized_name, domain) VALUES ('Acme', 'acme', 'acme.com')")
    assert db.migrate(c) == db.SCHEMA_VERSION
    assert _shape(c, "application_replies") == _shape(conn, "application_replies")
    assert c.execute("SELECT domain FROM companies WHERE name = 'Acme'").fetchone()[0] == "acme.com"
    assert db.migrate(c) == db.SCHEMA_VERSION  # idempotent
    c.close()


def _shape(conn: sqlite3.Connection, table: str) -> tuple:
    # By name: ALTER TABLE appends columns, so their position differs from schema.sql (harmless).
    cols = sorted(tuple(r)[1:] for r in conn.execute(f"PRAGMA table_info({table})"))
    idx = sorted((r[1], r[2], r[4]) for r in conn.execute(f"PRAGMA index_list({table})") if not r[1].startswith("sqlite_autoindex"))
    idx_cols = sorted((name, tuple(r[2] for r in conn.execute(f"PRAGMA index_info({name})"))) for name, *_ in idx)
    return cols, idx, idx_cols


def test_v9_database_upgrades_to_v10_keeping_data(tmp_path):
    c = db.connect(tmp_path / "v9.db")
    c.executescript("BEGIN;\n" + _v9_schema_sql() + "\nCOMMIT;")
    assert db.current_schema_version(c) == 9
    assert not set(V10_TABLES) & tables(c)
    c.execute("UPDATE preferences SET daily_cap = 7, create_accounts = 0")
    c.execute("INSERT INTO companies(name, normalized_name, domain) VALUES ('Acme', 'acme', 'acme.com')")
    assert db.migrate(c) == db.SCHEMA_VERSION
    assert set(V10_TABLES) <= tables(c)
    prefs = db.get_preferences(c)
    assert (prefs.daily_cap, prefs.create_accounts) == (7, False)
    assert (prefs.outreach_auto_scout, prefs.outreach_auto_draft, prefs.outreach_daily_cap, prefs.outreach_followup_days,
            prefs.outreach_max_followups, prefs.outreach_send_window, prefs.outreach_weekdays_only,
            prefs.outreach_min_email_confidence, prefs.people_finder_visits_per_day) == (
        True, True, 10, 5, 1, ["09:30", "17:30"], True, 60, 6)
    assert c.execute("SELECT domain FROM companies WHERE name = 'Acme'").fetchone()[0] == "acme.com"
    assert db.migrate(c) == db.SCHEMA_VERSION  # idempotent
    c.close()


def test_v10_migration_matches_schema_sql(tmp_path, conn):
    """A database migrated from v9 has exactly the tables, columns and indexes schema.sql creates."""
    c = db.connect(tmp_path / "v9.db")
    c.executescript("BEGIN;\n" + _v9_schema_sql() + "\nCOMMIT;")
    db.migrate(c)
    for table in (*V10_TABLES, "preferences"):
        assert _shape(c, table) == _shape(conn, table), table
    c.close()


@pytest.mark.parametrize(
    ("table", "column", "enum_name"),
    [("contacts", "role_category", "RoleCategory"), ("contacts", "email_status", "EmailStatus"),
     ("contacts", "origin", "ContactOrigin"), ("contact_evidence", "kind", "EvidenceKind"),
     ("outreach_threads", "kind", "OutreachKind"), ("outreach_threads", "state", "ThreadState"),
     ("outreach_threads", "outcome", "ThreadOutcome"), ("outreach_messages", "state", "MessageState"),
     ("suppression", "reason", "SuppressionReason"), ("referrals", "basis", "ReferralBasis"),
     ("referrals", "state", "ReferralState"), ("prospects", "status", "ProspectStatus"),
     ("domain_patterns", "mx_provider", "MxProvider")],
)
def test_v10_check_lists_match_enums(table, column, enum_name):
    from autoapply import enums

    sql = schema_sql_path().read_text()
    block = re.search(rf"CREATE TABLE IF NOT EXISTS {table} \((.*?)\n\);", sql, re.S)
    assert block, table
    m = re.search(rf"CHECK \(\s*(?:{column} IS NULL OR )?{column} IN \(([^)]*)\)", block.group(1))
    assert m, f"{table}.{column}"
    assert set(re.findall(r"'([^']+)'", m.group(1))) == {e.value for e in getattr(enums, enum_name)}


# ---- v12 (outreach thread suggestion, employer reply read flag) ---------------------------------


def test_v11_database_upgrades_to_v12(tmp_path, conn):
    c = db.connect(tmp_path / "v11.db")
    c.executescript("BEGIN;\n" + _v11_schema_sql() + "\nCOMMIT;")
    assert db.current_schema_version(c) == 11
    assert "suggestion_state" not in {r[1] for r in c.execute("PRAGMA table_info(outreach_threads)")}
    assert "read_at" not in {r[1] for r in c.execute("PRAGMA table_info(application_replies)")}
    co = db.upsert_company(c, "Acme")
    job, _ = db.insert_job(c, company_id=co.id, source="lever", title="SWE")
    app = db.get_application_by_job(c, job.id)
    c.execute("INSERT INTO outreach_threads(kind, company_id, application_id, state) VALUES ('application', ?, ?, 'replied')",
              (co.id, app.id))
    for i, state in enumerate(("pending", "dismissed", "none")):
        c.execute("INSERT INTO application_replies(application_id, message_id, from_email, received_at, label, match_basis, "
                  "suggested_status, suggestion_state) VALUES (?, ?, 'hr@acme.com', '2026-10-01T00:00:00.000Z', 'other', 'domain', ?, ?)",
                  (app.id, f"<m{i}@acme.com>", "interview" if state != "none" else None, state))
    assert db.migrate(c) == db.SCHEMA_VERSION
    for table in ("outreach_threads", "application_replies"):
        assert _shape(c, table) == _shape(conn, table), table
    t = c.execute("SELECT suggested_status, suggestion_state, suggestion_decided_at FROM outreach_threads").fetchone()
    assert tuple(t) == (None, "none", None)
    reads = {r[0]: r[1] for r in c.execute("SELECT suggestion_state, read_at FROM application_replies")}
    # Rows already decided (or with nothing to decide) count as read; a pending one stays unread.
    assert reads["pending"] is None and reads["dismissed"] and reads["none"]
    assert db.compute_counts(c).application_replies_unread == 1  # unchanged by the upgrade
    assert db.migrate(c) == db.SCHEMA_VERSION  # idempotent
    c.close()


# ---- v13 (new installs start in Review; existing users keep their mode) -------------------------


def _v12_schema_sql() -> str:
    """schema.sql as it was at v12: ``preferences.mode`` defaulted to 'auto', no v13 row."""
    sql = schema_sql_path().read_text()
    old = "mode                        TEXT NOT NULL DEFAULT 'review' CHECK"
    assert old in sql
    sql = sql.replace(old, "mode                        TEXT NOT NULL DEFAULT 'auto' CHECK")
    return "\n".join(line for line in sql.splitlines()
                     if not any(f"VALUES ({v})" in line for v in range(13, db.SCHEMA_VERSION + 1)))


def test_fresh_install_defaults_to_review(conn):
    assert db.get_preferences(conn).mode.value == "review"
    assert conn.execute("SELECT mode FROM preferences").fetchone()[0] == "review"


@pytest.mark.parametrize("stored", ["auto", "review"])
def test_v12_database_upgrades_to_v13_keeping_the_mode(tmp_path, conn, stored):
    c = db.connect(tmp_path / "v12.db")
    c.executescript("BEGIN;\n" + _v12_schema_sql() + "\nCOMMIT;")
    assert db.current_schema_version(c) == 12
    c.execute("UPDATE preferences SET mode = ?, daily_cap = 7, per_ats_mode = ?, create_accounts = 0",
              (stored, '{"lever":"auto"}'))
    assert db.migrate(c) == db.SCHEMA_VERSION
    prefs = db.get_preferences(c)
    assert prefs.mode.value == stored  # an existing user's mode is never changed
    assert (prefs.daily_cap, {k.value: v.value for k, v in prefs.per_ats_mode.items()}, prefs.create_accounts) == (
        7, {"lever": "auto"}, False)
    assert _shape(c, "preferences") == _shape(conn, "preferences")  # column default is now 'review'
    assert db.migrate(c) == db.SCHEMA_VERSION  # idempotent
    c.close()


def test_v13_without_a_preferences_row_keeps_auto(tmp_path):
    """A v12 database whose row was never written behaves as it did (Auto), not as a new install."""
    c = db.connect(tmp_path / "v12.db")
    c.executescript("BEGIN;\n" + _v12_schema_sql() + "\nCOMMIT;")
    c.execute("DELETE FROM preferences")
    db.migrate(c)
    assert db.get_preferences(c).mode.value == "auto"
    c.close()
