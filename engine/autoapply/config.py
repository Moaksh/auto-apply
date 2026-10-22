"""User preferences and never-guess facts (pydantic).

The DB (``preferences`` single row, ``never_guess`` key/value table) is the store; these
models are the typed view. Defaults here MUST equal the column defaults in
contract/schema.sql (tests/foundation/test_config.py checks this).

Persist/load through :mod:`autoapply.db` (``get_preferences`` / ``save_preferences`` /
``get_never_guess`` / ``set_never_guess``). Mutations from the app arrive as
``update_preferences`` / ``update_never_guess`` socket commands.
"""

from __future__ import annotations

import re
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, create_model, field_validator

from autoapply.enums import AskConfidence, Ats, Mode, RemotePolicy, Seniority

_HHMM = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")

#: Confidence threshold for generated answers; below this the agent asks the user.
ASK_CONFIDENCE_THRESHOLDS: dict[AskConfidence, float] = {
    AskConfidence.STRICT: 0.90,
    AskConfidence.BALANCED: 0.75,
    AskConfidence.LENIENT: 0.60,
}


def _default_sources() -> dict[str, bool]:
    return {
        "greenhouse": True,
        "lever": True,
        "ashby": True,
        "careers": True,
        "linkedin": False,
        "glassdoor": False,
        "google": True,
    }


class Preferences(BaseModel):
    """Job-search preferences. Field names == ``preferences`` table columns."""

    model_config = ConfigDict(extra="forbid", use_enum_values=False)

    roles: list[str] = Field(default_factory=list, description="Target role titles, e.g. 'Backend Engineer'.")
    seniority: list[Seniority] = Field(default_factory=list)
    locations: list[str] = Field(default_factory=list, description="Cities / countries.")
    remote_policy: list[RemotePolicy] = Field(
        default_factory=lambda: [RemotePolicy.REMOTE, RemotePolicy.HYBRID]
    )
    work_auth_summary: str | None = Field(default=None, description="Free text, e.g. 'India citizen; needs US sponsorship'.")
    salary_floor: int | None = Field(default=None, ge=0, description="Annual, in salary_currency.")
    salary_currency: str = "USD"
    hide_without_salary: bool = False
    exclude_companies: list[str] = Field(default_factory=list)
    exclude_industries: list[str] = Field(default_factory=list)
    exclude_keywords: list[str] = Field(default_factory=list)
    daily_cap: int = Field(default=15, ge=0)
    per_company_cooldown_days: int = Field(default=30, ge=0)
    match_threshold: int = Field(default=70, ge=0, le=100)
    mode: Mode = Field(
        default=Mode.REVIEW,
        description="Global mode. New installs start in Review (schema v13); Auto is offered per application "
                    "site once it is earned (autonomy.py) and the user can pick any mode at any level at any time.",
    )
    per_ats_mode: dict[Ats, Mode] = Field(
        default_factory=lambda: {Ats.WORKDAY: Mode.REVIEW},
        description="Per-ATS mode override. Missing ATS = inherit global mode.",
    )
    per_company_mode: dict[str, Mode] = Field(
        default_factory=dict, description="company_id (as string) -> mode override."
    )
    schedule: list[str] = Field(
        default_factory=lambda: ["09:00", "13:00", "18:00"], description="Local run times, HH:MM."
    )
    ask_confidence: AskConfidence = AskConfidence.BALANCED
    ghost_after_days: int = Field(default=21, gt=0)
    nudge_days: list[int] = Field(default_factory=lambda: [7, 14])
    linkedin_sessions_per_day: int = Field(default=3, ge=0)
    glassdoor_sessions_per_day: int = Field(default=3, ge=0)
    searches_per_session: int = Field(default=3, ge=1, le=10, description="Search result pages read per LinkedIn/Glassdoor session.")
    jobs_per_session: int = Field(default=30, ge=1, le=200, description="Job detail pages read per LinkedIn/Glassdoor session.")
    parallel_applications: int = Field(
        default=3, ge=1, le=4, description="Applications prepped / filled at the same time (one agent + browser each)."
    )
    create_accounts: bool = Field(
        default=True,
        description="Let the agent create (or reset the password of) an account on job sites that require one, "
                    "using the connected mailbox for verification emails. Passwords live in the macOS Keychain.",
    )
    sources_enabled: dict[str, bool] = Field(default_factory=_default_sources)
    # ---- cold outreach (v10) ------------------------------------------------------------
    outreach_auto_scout: bool = Field(
        default=True, description="Look for people to email at a company after each submitted application (30-day cache per company).",
    )
    outreach_auto_draft: bool = Field(
        default=True, description="Draft an email for the best contact after a scout. Drafts are never sent without approval.",
    )
    outreach_daily_cap: int = Field(default=10, ge=0, le=40, description="New email threads per day (follow-ups count toward 2x this).")
    outreach_followup_days: int = Field(default=5, ge=1, le=30, description="Business days without a reply before the one follow-up.")
    outreach_max_followups: int = Field(default=1, ge=0, le=2)
    outreach_send_window: list[str] = Field(
        default_factory=lambda: ["09:30", "17:30"], description="Local [start, end] HH:MM; emails are only sent inside it.",
    )
    outreach_weekdays_only: bool = True
    outreach_min_email_confidence: int = Field(
        default=60, ge=0, le=100, description="Emails below this confidence need 'Send anyway' per contact.",
    )
    people_finder_visits_per_day: int = Field(
        default=6, ge=0, le=30, description="Google result pages read per day to find people (never LinkedIn itself).",
    )
    career_page_urls: list[str] = Field(default_factory=list)
    always_ask_patterns: list[str] = Field(
        default_factory=list, description="Regexes; matching form questions always go to the inbox."
    )

    @field_validator("schedule")
    @classmethod
    def _validate_schedule(cls, v: list[str]) -> list[str]:
        for t in v:
            if not _HHMM.match(t):
                raise ValueError(f"schedule entries must be HH:MM (24h), got {t!r}")
        return sorted(set(v))

    @field_validator("outreach_send_window")
    @classmethod
    def _validate_window(cls, v: list[str]) -> list[str]:
        if len(v) != 2 or not all(_HHMM.match(t) for t in v):
            raise ValueError("outreach_send_window must be [start, end] as HH:MM (24h)")
        if v[0] >= v[1]:
            raise ValueError("outreach_send_window must start before it ends")
        return v

    @field_validator("nudge_days")
    @classmethod
    def _validate_nudges(cls, v: list[int]) -> list[int]:
        if any(d <= 0 for d in v):
            raise ValueError("nudge_days must be positive")
        return sorted(set(v))

    # ---- derived helpers -------------------------------------------------------------

    @property
    def confidence_threshold(self) -> float:
        return ASK_CONFIDENCE_THRESHOLDS[self.ask_confidence]

    def effective_mode(
        self,
        ats: Ats | str | None = None,
        company_id: int | None = None,
        job_override: Mode | str | None = None,
    ) -> Mode:
        """Resolve mode with precedence job > company > ATS > global."""
        if job_override:
            return Mode(job_override)
        if company_id is not None and str(company_id) in self.per_company_mode:
            return Mode(self.per_company_mode[str(company_id)])
        if ats is not None:
            try:
                ats_key = Ats(ats)
            except ValueError:
                ats_key = None
            if ats_key is not None and ats_key in self.per_ats_mode:
                return Mode(self.per_ats_mode[ats_key])
        return Mode(self.mode)

    def apply_patch(self, patch: dict[str, Any]) -> "Preferences":
        """Return a new validated Preferences with ``patch`` (partial dict) applied."""
        unknown = set(patch) - set(type(self).model_fields)
        if unknown:
            raise ValueError(f"unknown preference fields: {sorted(unknown)}")
        data = self.model_dump(mode="json")
        data.update({k: v for k, v in patch.items()})
        return type(self).model_validate(data)


class NeverGuess(BaseModel):
    """Facts the agent never guesses. ``None`` means "always ask me".

    Each field is one row in the ``never_guess`` table (key = field name, value = JSON).
    """

    model_config = ConfigDict(extra="forbid")

    work_auth: dict[str, str] = Field(
        default_factory=dict,
        description="Country (ISO-3166 alpha-2 or name) -> status, e.g. {'US': 'requires_sponsorship', 'IN': 'citizen'}.",
    )
    sponsorship: str | None = Field(default=None, description="e.g. 'Requires sponsorship (H-1B)' / 'Not required'.")
    salary_expectation: str | None = Field(default=None, description="Free text, e.g. '₹45L'.")
    salary_negotiable: bool | None = None
    notice_period: str | None = Field(default=None, description="e.g. '60 days'.")
    start_date: str | None = Field(default=None, description="Free text or ISO date.")
    relocation: str | None = Field(default=None, description="'yes' | 'case_by_case' | 'no'.")
    eeo_policy: str = Field(default="decline", description="'decline' (decline to answer) | 'fill'.")
    eeo_gender: str | None = None
    eeo_race: str | None = None
    eeo_veteran: str | None = None
    eeo_disability: str | None = None
    attest_accuracy: bool = Field(default=False, description="Agent may confirm 'information is accurate'.")
    attest_background_check: bool = Field(default=False, description="Agent may accept background checks.")

    @field_validator("relocation")
    @classmethod
    def _validate_relocation(cls, v: str | None) -> str | None:
        if v is not None and v not in {"yes", "case_by_case", "no"}:
            raise ValueError("relocation must be yes|case_by_case|no")
        return v

    @field_validator("eeo_policy")
    @classmethod
    def _validate_eeo(cls, v: str) -> str:
        if v not in {"decline", "fill"}:
            raise ValueError("eeo_policy must be decline|fill")
        return v

    def to_rows(self) -> dict[str, Any]:
        """key -> JSON-able value, for every field (None included)."""
        return self.model_dump(mode="json")

    @classmethod
    def from_rows(cls, rows: dict[str, Any]) -> "NeverGuess":
        """Build from ``never_guess`` rows; unknown keys are ignored (forward compat)."""
        known = {k: v for k, v in rows.items() if k in cls.model_fields}
        # JSON null for a field with a non-null default -> use the default.
        cleaned = {
            k: v for k, v in known.items() if v is not None or cls.model_fields[k].default is None
        }
        return cls.model_validate(cleaned)

    def get(self, key: str) -> Any:
        """Value for a never-guess key, or None. Unknown keys return None."""
        return getattr(self, key, None) if key in type(self).model_fields else None


NEVER_GUESS_KEYS: tuple[str, ...] = tuple(NeverGuess.model_fields)


def _partial(model: type[BaseModel], name: str) -> type[BaseModel]:
    fields: dict[str, Any] = {}
    for fname, f in model.model_fields.items():
        fields[fname] = (f.annotation | None, Field(default=None, description=f.description))
    return create_model(name, __config__=ConfigDict(extra="forbid"), **fields)  # type: ignore[call-overload]


#: All-optional versions used by the ``update_preferences`` / ``update_never_guess`` commands.
#: Only keys present in the payload are applied (``model_dump(exclude_unset=True)``).
PreferencesPatch = _partial(Preferences, "PreferencesPatch")
NeverGuessPatch = _partial(NeverGuess, "NeverGuessPatch")
