from __future__ import annotations

import pytest
from pydantic import ValidationError

from autoapply import db
from autoapply.config import (
    NEVER_GUESS_KEYS,
    NeverGuess,
    NeverGuessPatch,
    Preferences,
    PreferencesPatch,
)
from autoapply.enums import AskConfidence, Ats, Mode, RemotePolicy


def test_preference_defaults_from_plan():
    p = Preferences()
    assert p.match_threshold == 70
    assert p.per_company_cooldown_days == 30
    assert p.mode is Mode.REVIEW  # v13: new installs start in Review (earned autonomy)
    assert p.schedule == ["09:00", "13:00", "18:00"]
    assert p.ghost_after_days == 21
    assert p.nudge_days == [7, 14]
    assert p.daily_cap == 15
    assert p.per_ats_mode == {Ats.WORKDAY: Mode.REVIEW}  # PLAN §7: default Workday to Review
    assert p.remote_policy == [RemotePolicy.REMOTE, RemotePolicy.HYBRID]
    assert p.ask_confidence is AskConfidence.BALANCED
    assert p.confidence_threshold == 0.75
    assert p.sources_enabled["linkedin"] is False and p.sources_enabled["greenhouse"] is True


def test_model_defaults_equal_schema_column_defaults(conn):
    """Fresh DB row (schema.sql defaults) must equal Preferences() defaults."""
    assert db.get_preferences(conn) == Preferences()


def test_never_guess_defaults_on_fresh_db(conn):
    assert db.get_never_guess(conn) == NeverGuess()


def test_effective_mode_precedence():
    p = Preferences(mode=Mode.AUTO, per_ats_mode={Ats.GREENHOUSE: Mode.REVIEW}, per_company_mode={"7": Mode.AUTO})
    assert p.effective_mode() is Mode.AUTO
    assert p.effective_mode(ats="greenhouse") is Mode.REVIEW
    assert p.effective_mode(ats="workday") is Mode.AUTO  # override dict replaced the default
    assert p.effective_mode(ats="greenhouse", company_id=7) is Mode.AUTO
    assert p.effective_mode(ats="greenhouse", company_id=7, job_override="review") is Mode.REVIEW
    assert p.effective_mode(ats="not-an-ats") is Mode.AUTO


@pytest.mark.parametrize("bad", [["9:00"], ["24:00"], ["12:60"], ["noon"]])
def test_schedule_validation(bad):
    with pytest.raises(ValidationError):
        Preferences(schedule=bad)


def test_schedule_sorted_and_deduped():
    assert Preferences(schedule=["18:00", "09:00", "18:00"]).schedule == ["09:00", "18:00"]


def test_bounds():
    with pytest.raises(ValidationError):
        Preferences(match_threshold=-1)
    with pytest.raises(ValidationError):
        Preferences(ghost_after_days=0)
    with pytest.raises(ValidationError):
        Preferences(nudge_days=[0])
    with pytest.raises(ValidationError):
        Preferences(unknown=1)


def test_apply_patch():
    p = Preferences().apply_patch({"daily_cap": 5, "mode": "review"})
    assert p.daily_cap == 5 and p.mode is Mode.REVIEW and p.match_threshold == 70
    with pytest.raises(ValueError):
        Preferences().apply_patch({"nope": 1})


def test_patch_models_are_all_optional():
    assert PreferencesPatch().model_dump(exclude_unset=True) == {}
    assert PreferencesPatch(match_threshold=60).model_dump(exclude_unset=True) == {"match_threshold": 60}
    assert set(PreferencesPatch.model_fields) == set(Preferences.model_fields)
    assert set(NeverGuessPatch.model_fields) == set(NeverGuess.model_fields)
    with pytest.raises(ValidationError):
        PreferencesPatch(bogus=1)


def test_never_guess_rows_roundtrip():
    ng = NeverGuess(sponsorship="Requires H-1B", work_auth={"US": "requires_sponsorship"}, relocation="no")
    rows = ng.to_rows()
    assert set(rows) == set(NEVER_GUESS_KEYS)
    assert NeverGuess.from_rows(rows) == ng
    # forward compat: unknown keys ignored; null for non-null-default fields -> default
    assert NeverGuess.from_rows({"future_key": 1, "eeo_policy": None}).eeo_policy == "decline"
    assert ng.get("sponsorship") == "Requires H-1B" and ng.get("nope") is None


def test_never_guess_validation():
    with pytest.raises(ValidationError):
        NeverGuess(relocation="sometimes")
    with pytest.raises(ValidationError):
        NeverGuess(eeo_policy="maybe")
