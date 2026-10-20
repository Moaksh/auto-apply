"""Starter watchlist: a fresh install watches verified ATS boards once."""

from autoapply import db
from autoapply.discovery.starter import META_SEEDED, STARTER_BOARDS, seed_starter_watchlist
from autoapply.enums import SuggestionStatus


def test_fresh_install_watches_starter_boards_once(conn):
    added = seed_starter_watchlist(conn)
    assert len(added) == len(STARTER_BOARDS)
    watched = db.list_companies(conn, watch_only=True)
    assert {c.name for c in watched} == {n for n, _, _ in STARTER_BOARDS}
    assert all(c.board_token for c in watched)
    row = conn.execute("SELECT status, source FROM company_suggestions WHERE company_name = 'Stripe'").fetchone()
    assert (row["status"], row["source"]) == (SuggestionStatus.AUTO.value, "starter")
    # Removing one later must not bring it back.
    db.upsert_company(conn, "Stripe", watch=False)
    assert seed_starter_watchlist(conn) == []
    assert "Stripe" not in {c.name for c in db.list_companies(conn, watch_only=True)}


def test_existing_watchlist_is_left_alone(conn):
    db.upsert_company(conn, "Acme", watch=True)
    assert seed_starter_watchlist(conn) == []
    assert db.get_meta(conn, META_SEEDED) is True
    assert [c.name for c in db.list_companies(conn, watch_only=True)] == ["Acme"]


def test_dismissed_company_is_skipped(conn):
    db.suggest_company(conn, "Stripe", url="x", source="test", status=SuggestionStatus.DISMISSED)
    added = seed_starter_watchlist(conn)
    assert "Stripe" not in added and len(added) == len(STARTER_BOARDS) - 1


async def test_first_discovery_seeds_an_empty_watchlist(conn, autoapply_home, monkeypatch):
    from autoapply.discovery import starter
    from autoapply.enums import JobSource
    from autoapply.llm.provider import FakeLLMProvider
    from autoapply.pipeline import Pipeline
    from tests.d_daemon.fakes import EventSink, FakeSource, fake_hooks

    monkeypatch.setattr(starter, "AUTO_SEED", True)
    monkeypatch.setattr(starter, "STARTER_BOARDS", STARTER_BOARDS[:2])
    hooks, _ = fake_hooks()
    p = Pipeline(conn, paths=autoapply_home, llm=FakeLLMProvider(default="ok"), sources=[FakeSource([], name=JobSource.GOOGLE)],
                 adapters=[], emit=EventSink(), hooks=hooks, is_paused=lambda: False)
    await p.discover()
    assert {c.name for c in db.list_companies(conn, watch_only=True)} == {n for n, _, _ in STARTER_BOARDS[:2]}
    await p.discover(round_=1)  # deeper passes never seed
    assert db.get_meta(conn, META_SEEDED) is True
