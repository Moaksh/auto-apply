"""Scoring eval set. Offline tests run in the default suite; the live drift check is
``@pytest.mark.network`` and also needs ``AUTOAPPLY_SCORING_EVAL=1`` (see README.md)."""

from __future__ import annotations

import os

import pytest

from autoapply.db import normalize_text

from .harness import (
    BANDS,
    FAKE_DEALBREAKER_QUOTE,
    HALLUCINATED_EVIDENCE,
    accuracy,
    band_for,
    drift_report,
    live_provider,
    load_cases,
    run_all,
    scripted_provider,
)

CASES = load_cases()


def test_case_set_is_well_formed() -> None:
    assert 15 <= len(CASES) <= 25
    assert len({c.id for c in CASES}) == len(CASES)
    assert {c.band for c in CASES} == set(BANDS)  # every band is represented
    for c in CASES:
        jd = normalize_text(c.job.description)
        for d in c.dealbreakers:
            assert normalize_text(d["jd_quote"]) in jd, f"{c.id}: dealbreaker quote not in JD"
            assert normalize_text(d["keyword"]) in normalize_text(d["jd_quote"]), f"{c.id}: keyword not in quote"
        assert normalize_text(FAKE_DEALBREAKER_QUOTE) not in jd


@pytest.mark.parametrize(("score", "band"), [(100, "strong"), (80, "strong"), (79, "borderline"), (60, "borderline"),
                                             (59, "poor"), (0, "poor"), (None, None)])
def test_band_for(score: int | None, band: str | None) -> None:
    assert band_for(score) == band


async def test_offline_eval_with_scripted_fake() -> None:
    outcomes = await run_all(CASES, scripted_provider)
    report = drift_report(outcomes)
    assert accuracy(outcomes) == 1.0, report
    for o in outcomes:
        reqs = o.result.reasons["requirements"]
        assert o.result.error is None
        # Planted fake dealbreaker and hallucinated evidence are removed by the grounding guard.
        assert o.result.reasons["grounding"] == {"evidence_dropped": 1, "dealbreakers_dropped": 1}, o.case.id
        assert not any(r["evidence"] == HALLUCINATED_EVIDENCE for r in reqs)
        assert next(r for r in reqs if r["requirement"] == "Leadership")["status"] == "partial"
        assert next(r for r in reqs if r["requirement"] == "Core skill")["status"] == "met"
        # Exactly the labelled dealbreakers survive, each with its JD quote.
        assert o.dealbreakers_missed == [] and o.dealbreakers_extra == [], o.case.id
        assert sorted(r["jd_quote"] for r in reqs if r["dealbreaker"]) == sorted(d["jd_quote"] for d in o.case.dealbreakers)
    assert "band accuracy: " in report and "MISS" not in report


@pytest.mark.network
@pytest.mark.skipif(os.environ.get("AUTOAPPLY_SCORING_EVAL") != "1", reason="set AUTOAPPLY_SCORING_EVAL=1 to run the live model")
async def test_live_scoring_drift() -> None:
    llm = live_provider(os.environ.get("AUTOAPPLY_SCORING_EVAL_MODEL") or None)
    outcomes = await run_all(CASES, lambda _c: llm)
    print("\n" + drift_report(outcomes))
    floor = float(os.environ.get("AUTOAPPLY_SCORING_EVAL_MIN_ACCURACY", "0"))
    assert all(o.result.error is None for o in outcomes), [o.result.error for o in outcomes if o.result.error]
    assert accuracy(outcomes) >= floor
