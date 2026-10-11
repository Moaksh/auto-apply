from __future__ import annotations

from datetime import date

from autoapply.enums import Seniority
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import Profile
from autoapply.prefs_suggest import heuristic_preferences, seniority_for_years, suggest_preferences, years_from_history


def _profile(**kw) -> Profile:
    base = dict(
        headline="AI Engineer", location="Bengaluru, Karnataka, India", skills=["Python", "LLMs"],
        work_history=[
            {"company": "PlumHQ", "title": "AI Engineer", "start": "Jan 2024", "end": "Present"},
            {"company": "Onsurity", "title": "Software Engineer Intern", "start": "Jan 2023", "end": "Jul 2023"},
        ],
    )
    base.update(kw)
    return Profile.model_validate(base)


def test_seniority_bands():
    assert seniority_for_years(None) == []
    assert seniority_for_years(1) == [Seniority.JUNIOR]
    assert seniority_for_years(2.3) == [Seniority.JUNIOR, Seniority.MID]
    assert seniority_for_years(7) == [Seniority.SENIOR]
    assert seniority_for_years(20) == [Seniority.STAFF, Seniority.PRINCIPAL]


def test_years_from_history_counts_internships_half():
    y = years_from_history(_profile())
    full = (date.today() - date(2024, 1, 1)).days / 365.25
    intern = (date(2023, 7, 1) - date(2023, 1, 1)).days / 365.25 * 0.5
    assert abs(y - (full + intern)) < 0.1


def test_heuristic_prefers_stored_years_and_strips_levels():
    s = heuristic_preferences(_profile(years_experience=2.3,
                                       work_history=[{"company": "X", "title": "Senior Backend Engineer - Payments", "start": "2020"}]))
    assert s.years_experience == 2.3
    assert s.seniority == [Seniority.JUNIOR, Seniority.MID]
    assert s.roles == ["AI Engineer", "Backend Engineer"]
    assert s.locations == ["Bengaluru", "India"]


async def test_llm_roles_lead_and_failure_falls_back():
    llm = FakeLLMProvider(rules=[("SUGGEST TARGET ROLES", {"roles": ["ML Engineer", "Senior AI Engineer"]})])
    s = await suggest_preferences(_profile(), llm)
    assert s.roles[:2] == ["ML Engineer", "AI Engineer"]
    broken = FakeLLMProvider(rules=[])
    assert (await suggest_preferences(_profile(), broken)).roles[0] == "AI Engineer"
