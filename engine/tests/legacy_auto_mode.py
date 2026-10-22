"""Fresh test databases start in Auto, as a new install did before schema v13.

Since v13 a new install starts in Review (owner decision #3: earned autonomy). The pipeline,
runner and agent suites were written against the old default and exercise the Auto submit path
on a fresh DB, so their conftests use this autouse fixture: right after a *fresh* DB is created,
``preferences.mode`` is set to 'auto'. Upgraded DBs and the real default are untouched; tests of
the default itself live in tests/foundation and tests/test_autonomy.py, which do not use it.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from pathlib import Path

import pytest

from autoapply import db


@pytest.fixture(autouse=True)
def _fresh_db_starts_in_auto(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    real = db.migrate

    def migrate(conn: sqlite3.Connection, schema_path: Path | str | None = None) -> int:
        fresh = db.current_schema_version(conn) == 0
        version = real(conn, schema_path)
        if fresh:
            conn.execute("UPDATE preferences SET mode = 'auto' WHERE id = 1")
        return version

    monkeypatch.setattr(db, "migrate", migrate)
    yield
