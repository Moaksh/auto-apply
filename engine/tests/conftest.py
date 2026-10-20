"""Shared pytest fixtures for ALL engine test suites (READ-ONLY for workstreams).

* ``autoapply_home`` — isolated AUTOAPPLY_HOME (tmp dir) with the tree created.
* ``conn``          — migrated SQLite connection on a temp file DB (WAL, FKs on).
* ``fake_llm``      — a fresh :class:`FakeLLMProvider` (never the real SDK).

Network is never needed: tests marked ``@pytest.mark.network`` are deselected by default.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from pathlib import Path

import pytest

from autoapply import db
from autoapply.llm.provider import FakeLLMProvider
from autoapply.paths import Paths, get_paths


@pytest.fixture(autouse=True)
def _no_starter_watchlist(monkeypatch: pytest.MonkeyPatch) -> None:
    """Pipelines start on the fixtures' own watchlist, not the shipped starter boards."""
    from autoapply.discovery import starter

    monkeypatch.setattr(starter, "AUTO_SEED", False)


@pytest.fixture
def autoapply_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Paths:
    home = tmp_path / "AutoApplyHome"
    monkeypatch.setenv("AUTOAPPLY_HOME", str(home))
    return get_paths(create=True)


@pytest.fixture
def conn(autoapply_home: Paths) -> Iterator[sqlite3.Connection]:
    c = db.open_db(autoapply_home.db)
    try:
        yield c
    finally:
        c.close()


@pytest.fixture
def fake_llm() -> FakeLLMProvider:
    return FakeLLMProvider()
