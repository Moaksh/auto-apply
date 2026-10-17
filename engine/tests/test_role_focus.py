"""The agent reads vague roles ("Engineering") through the resume and drops other disciplines."""

from __future__ import annotations

import sqlite3

from autoapply import db, role_focus
from autoapply.llm.provider import FakeLLMProvider
from autoapply.role_focus import heuristic_focus, is_vague, off_field
from autoapply.scoring import hard_filter


def _software_profile(conn: sqlite3.Connection) -> None:
    db.update_profile(conn, {
        "headline": "AI Engineer", "skills": ["Python", "LLMs", "FastAPI", "PyTorch"],
        "work_history": [{"title": "AI Engineer", "company": "Plum"}, {"title": "Software Engineer Intern", "company": "X"}],
    })


def test_vague_roles() -> None:
    assert is_vague("Engineering") and is_vague("Tech jobs") and is_vague("Developer")
    assert not is_vague("AI engineer") and not is_vague("Product Manager") and not is_vague("Data Scientist")


def test_heuristic_reads_engineering_through_the_resume(conn: sqlite3.Connection) -> None:
    _software_profile(conn)
    db.update_preferences(conn, {"roles": ["AI engineer", "Engineering"]})
    f = heuristic_focus(db.get_preferences(conn), db.get_profile(conn))
    assert f.searches[0] == "AI engineer" and "Engineering" not in f.searches
    assert any("Software Engineer" in s for s in f.searches)
    assert "electrical" in f.avoid and "industrial" in f.avoid and "python" not in f.avoid
    assert off_field("Electrical Engineer - Substations", f) == "electrical"
    assert off_field("Industrial Engineering Manager", f) == "industrial"
    assert off_field("Senior AI Engineer", f) is None
    assert off_field("AI Engineer, Hardware Acceleration", f) is None  # names the candidate's field
    assert off_field("Director of Software Engineering - Accounting & Post Trading", f) is None
    assert off_field("Manufacturing Engineering Manager", f) == "manufacturing"


def test_own_field_is_never_avoided(conn: sqlite3.Connection) -> None:
    db.update_profile(conn, {"headline": "Electrical Engineer", "skills": ["AutoCAD", "substation design"]})
    db.update_preferences(conn, {"roles": ["Engineering"]})
    f = heuristic_focus(db.get_preferences(conn), db.get_profile(conn))
    assert "electrical" not in f.avoid and "autocad" not in f.avoid
    assert off_field("Electrical Design Engineer", f) is None


async def test_model_interprets_once_and_caches(conn: sqlite3.Connection) -> None:
    _software_profile(conn)
    db.update_preferences(conn, {"roles": ["AI engineer", "Engineering"]})
    llm = FakeLLMProvider(rules=[(r"INTERPRET TARGET ROLES", {
        "field": "software / AI engineering", "searches": ["ML Engineer", "Backend Engineer", "Engineering"],
        "avoid": ["Mechanical", "python"]})])
    f, changed = await role_focus.ensure(conn, llm)
    assert changed and f.by_model and f.field == "software / AI engineering"
    assert f.searches == ["AI engineer", "ML Engineer", "Backend Engineer"]   # typed role kept, vague one dropped
    assert "mechanical" in f.avoid and "python" not in f.avoid                # never the candidate's own skills
    again, changed = await role_focus.ensure(conn, llm)
    assert not changed and again.searches == f.searches and len(llm.calls) == 1
    # specific roles only: no model call at all
    db.update_preferences(conn, {"roles": ["AI engineer"]})
    f2, changed = await role_focus.ensure(conn, llm)
    assert changed and f2.searches == ["AI engineer"] and len(llm.calls) == 1


def test_hard_filter_skips_other_disciplines(conn: sqlite3.Connection) -> None:
    _software_profile(conn)
    db.update_preferences(conn, {"roles": ["Engineering"], "locations": []})
    co = db.upsert_company(conn, "Bayer")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="Electrical Engineer", apply_url="https://x.io/1")
    assert hard_filter(conn, job, co, db.get_preferences(conn)) == "role_off_field:electrical"
    ok, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="AI Engineer", apply_url="https://x.io/2")
    assert hard_filter(conn, ok, co, db.get_preferences(conn)) is None
