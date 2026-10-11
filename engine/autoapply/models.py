"""Typed models: DB rows + socket protocol messages + the application state machine.

This module is the Python side of the frozen contract:

* Row models mirror tables in contract/schema.sql (``Model.from_row(sqlite3.Row)``).
* Protocol payload models mirror contract/protocol.schema.json. That JSON file is
  GENERATED from this module: ``uv run python -m autoapply.models`` rewrites it, and
  tests/foundation/test_protocol.py fails if the committed file drifts.
* ``ALLOWED_TRANSITIONS`` is the state machine (enforced by ``autoapply.db.transition``).

Wire format: one JSON object per line (NDJSON), envelope
``{"v": 1, "id": "<uuid>", "type": "<name>", "payload": {...}}``; daemon replies also
carry ``"reply_to": "<command id>"``. See contract/protocol.md.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import UTC, datetime
from typing import Annotated, Any, ClassVar, Literal

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    PlainSerializer,
    ValidationError,
    WithJsonSchema,
)
from pydantic.json_schema import models_json_schema

from autoapply.config import NeverGuess, NeverGuessPatch, Preferences, PreferencesPatch
from autoapply.enums import (
    Actor,
    AnswerOrigin,
    AnswerSource,
    AppState,
    ApplicationMode,
    Ats,
    BoardStatus,
    CapKind,
    DaemonActivity,
    ErrorCode,
    FieldType,
    JobSource,
    LogLevel,
    Mode,
    QuestionReason,
    QuestionStatus,
    RemotePolicy,
    RunKind,
    RunOutcome,
    RunTrigger,
    SourceName,
)

PROTOCOL_VERSION = 1

# =====================================================================================
# Timestamps: ISO-8601 UTC, millisecond precision, 'Z' suffix (same format as the DB).
# =====================================================================================


def utcnow() -> datetime:
    return datetime.now(UTC)


def format_ts(dt: datetime) -> str:
    """Format as ``YYYY-MM-DDTHH:MM:SS.mmmZ``. Naive datetimes are assumed UTC."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    dt = dt.astimezone(UTC)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def now_ts() -> str:
    return format_ts(utcnow())


def parse_ts(value: Any) -> Any:
    """Parse ISO-8601 strings (with ``Z`` or offset, optional fraction) to aware UTC."""
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=UTC)
    if isinstance(value, str):
        s = value.strip()
        if s.endswith("Z") or s.endswith("z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        return dt if dt.tzinfo else dt.replace(tzinfo=UTC)
    return value


Timestamp = Annotated[
    datetime,
    BeforeValidator(parse_ts),
    PlainSerializer(format_ts, return_type=str, when_used="json"),
    WithJsonSchema({"type": "string", "format": "date-time"}),
]


def new_id() -> str:
    """Message / run / cluster id: uuid4 hex."""
    return uuid.uuid4().hex


# =====================================================================================
# State machine (contract/protocol.md §State machine)
# =====================================================================================

S = AppState

#: from_state -> set of allowed to_states (any actor unless listed in USER_ONLY_TRANSITIONS).
ALLOWED_TRANSITIONS: dict[AppState, frozenset[AppState]] = {
    S.DISCOVERED: frozenset({S.SCORED, S.SKIPPED, S.FAILED}),
    S.SCORED: frozenset({S.QUEUED, S.SKIPPED}),
    S.QUEUED: frozenset({S.PREPPING, S.FILLING, S.SKIPPED, S.FAILED}),
    S.PREPPING: frozenset({S.QUEUED, S.NEEDS_YOU, S.FILLING, S.SKIPPED, S.FAILED}),
    S.NEEDS_YOU: frozenset({S.QUEUED, S.SKIPPED, S.FAILED}),
    S.FILLING: frozenset({S.NEEDS_YOU, S.AWAITING_REVIEW, S.SUBMITTING, S.QUEUED, S.FAILED}),
    S.AWAITING_REVIEW: frozenset({S.SUBMITTING, S.SKIPPED, S.QUEUED}),
    S.SUBMITTING: frozenset({S.SUBMITTED, S.FAILED, S.UNKNOWN_VERIFY}),
    S.UNKNOWN_VERIFY: frozenset({S.SUBMITTED, S.FAILED}),
    S.FAILED: frozenset({S.QUEUED}),
    S.SKIPPED: frozenset({S.QUEUED}),
    S.SUBMITTED: frozenset(),
}

#: Transitions only a human may trigger (actor == "user"). The agent can never approve its
#: own review item, retry a failure, un-skip, or resolve an unknown_verify.
USER_ONLY_TRANSITIONS: frozenset[tuple[AppState, AppState]] = frozenset(
    {
        (S.AWAITING_REVIEW, S.SUBMITTING),  # approve
        (S.AWAITING_REVIEW, S.SKIPPED),  # reject
        (S.UNKNOWN_VERIFY, S.SUBMITTED),  # "yes, it went through"
        (S.UNKNOWN_VERIFY, S.FAILED),  # "no, it didn't"
        (S.FAILED, S.QUEUED),  # manual retry
        (S.SKIPPED, S.QUEUED),  # "apply anyway"
    }
)

#: States from which the user may record a manual (LinkedIn Easy Apply) application.
#: This is a separate path (``autoapply.db.mark_manually_applied``), not a normal edge.
MANUAL_SUBMIT_FROM: frozenset[AppState] = frozenset(
    {S.DISCOVERED, S.SCORED, S.SKIPPED, S.QUEUED, S.NEEDS_YOU}
)

TERMINAL_STATES: frozenset[AppState] = frozenset({S.SUBMITTED})
#: States in which an agent is actively working; a crash leaves these stale.
ACTIVE_STATES: frozenset[AppState] = frozenset({S.PREPPING, S.FILLING, S.SUBMITTING})


def is_allowed_transition(frm: AppState | str, to: AppState | str, actor: Actor | str = Actor.AGENT) -> bool:
    frm, to, actor = AppState(frm), AppState(to), Actor(actor)
    if to not in ALLOWED_TRANSITIONS[frm]:
        return False
    if (frm, to) in USER_ONLY_TRANSITIONS and actor is not Actor.USER:
        return False
    return True


# =====================================================================================
# Row models (contract/schema.sql)
# =====================================================================================


class RowModel(BaseModel):
    """Base for table mirrors. ``from_row`` decodes JSON/bool columns."""

    model_config = ConfigDict(extra="ignore", from_attributes=True)

    _json_fields: ClassVar[frozenset[str]] = frozenset()
    _bool_fields: ClassVar[frozenset[str]] = frozenset()

    @classmethod
    def from_row(cls, row: sqlite3.Row | dict[str, Any]) -> "RowModel":
        data = dict(row)
        for k in cls._json_fields:
            if k in data and isinstance(data[k], str):
                data[k] = json.loads(data[k])
        for k in cls._bool_fields:
            if k in data and data[k] is not None:
                data[k] = bool(data[k])
        return cls.model_validate(data)


class WorkHistoryItem(BaseModel):
    model_config = ConfigDict(extra="allow")
    company: str
    title: str
    start: str | None = None
    end: str | None = None
    location: str | None = None
    highlights: list[str] = Field(default_factory=list)


class EducationItem(BaseModel):
    model_config = ConfigDict(extra="allow")
    school: str
    degree: str | None = None
    field: str | None = None
    start: str | None = None
    end: str | None = None


class Profile(RowModel):
    _json_fields = frozenset({"links", "work_history", "education", "skills", "extra"})

    full_name: str | None = None
    first_name: str | None = None
    last_name: str | None = None
    email: str | None = None
    phone: str | None = None
    location: str | None = None
    headline: str | None = None
    summary: str | None = None
    links: dict[str, str] = Field(default_factory=dict)
    work_history: list[WorkHistoryItem] = Field(default_factory=list)
    education: list[EducationItem] = Field(default_factory=list)
    skills: list[str] = Field(default_factory=list)
    years_experience: float | None = None
    extra: dict[str, Any] = Field(default_factory=dict)
    raw_text: str | None = None
    updated_at: Timestamp | None = None


PROFILE_FIELDS: tuple[str, ...] = tuple(f for f in Profile.model_fields if f != "updated_at")


class ProfilePatch(BaseModel):
    """All-optional Profile for ``update_profile``; only keys present are applied."""

    model_config = ConfigDict(extra="forbid")
    full_name: str | None = None
    first_name: str | None = None
    last_name: str | None = None
    email: str | None = None
    phone: str | None = None
    location: str | None = None
    headline: str | None = None
    summary: str | None = None
    links: dict[str, str] | None = None
    work_history: list[WorkHistoryItem] | None = None
    education: list[EducationItem] | None = None
    skills: list[str] | None = None
    years_experience: float | None = None
    extra: dict[str, Any] | None = None


class ResumeVariant(RowModel):
    _json_fields = frozenset({"tags"})
    _bool_fields = frozenset({"is_default", "enabled"})

    id: int
    label: str
    file_path: str
    tags: list[str] = Field(default_factory=list)
    text: str | None = None
    embedding_model: str | None = None
    is_default: bool = False
    enabled: bool = True
    version: int = 1
    replaced_by: int | None = None
    created_at: Timestamp
    updated_at: Timestamp


class Story(RowModel):
    _json_fields = frozenset({"tags"})

    id: int
    title: str
    situation: str = ""
    task: str = ""
    action: str = ""
    result: str = ""
    tags: list[str] = Field(default_factory=list)
    uses: int = 0
    created_at: Timestamp
    updated_at: Timestamp


class Answer(RowModel):
    _bool_fields = frozenset({"is_template"})

    id: int
    canonical_question: str
    answer: str
    field_type: FieldType = FieldType.TEXT
    is_template: bool = False
    embedding_model: str | None = None
    source: AnswerSource = AnswerSource.USER
    uses: int = 0
    last_used_at: Timestamp | None = None
    created_at: Timestamp
    updated_at: Timestamp


class Company(RowModel):
    _bool_fields = frozenset({"watch"})

    id: int
    name: str
    normalized_name: str
    domain: str | None = None
    ats: Ats | None = None
    board_token: str | None = None
    careers_url: str | None = None
    watch: bool = False
    last_applied_at: Timestamp | None = None
    created_at: Timestamp
    updated_at: Timestamp


class Job(RowModel):
    _json_fields = frozenset({"raw"})
    _bool_fields = frozenset({"easy_apply"})

    id: int
    source: JobSource
    source_url: str | None = None
    apply_url: str | None = None
    apply_url_norm: str | None = None
    ats: Ats = Ats.OTHER
    external_id: str | None = None
    company_id: int
    title: str
    location: str | None = None
    remote: RemotePolicy | None = None
    salary_min: int | None = None
    salary_max: int | None = None
    salary_currency: str | None = None
    description: str | None = None
    posted_at: Timestamp | None = None
    discovered_at: Timestamp
    easy_apply: bool = False
    mode_override: Mode | None = None
    notes: str | None = None
    raw: dict[str, Any] = Field(default_factory=dict)
    dedupe_key: str


class Score(RowModel):
    _json_fields = frozenset({"reasons"})

    job_id: int
    score: int | None = None
    reasons: dict[str, Any] = Field(default_factory=dict)
    skip_reason: str | None = None
    model: str | None = None
    tokens_in: int = 0
    tokens_out: int = 0
    scored_at: Timestamp


class Application(RowModel):
    id: int
    job_id: int
    state: AppState
    state_reason: str | None = None
    state_updated_at: Timestamp
    mode: ApplicationMode | None = None
    resume_variant_id: int | None = None
    resume_pick_score: float | None = None
    cover_letter_path: str | None = None
    screenshot_path: str | None = None
    confirmation_screenshot_path: str | None = None
    submitted_at: Timestamp | None = None
    status: BoardStatus | None = None
    status_updated_at: Timestamp | None = None
    nudges_sent: int = 0
    tokens_in: int = 0
    tokens_out: int = 0
    notes: str | None = None
    created_at: Timestamp
    updated_at: Timestamp


class BBox(BaseModel):
    x: float
    y: float
    w: float
    h: float


class ApplicationAnswer(RowModel):
    _json_fields = frozenset({"bbox"})

    id: int
    application_id: int
    field_key: str | None = None
    question: str
    answer: str
    field_type: FieldType = FieldType.TEXT
    confidence: float | None = None
    origin: AnswerOrigin
    origin_ref: str | None = None
    bbox: BBox | None = None
    created_at: Timestamp
    updated_at: Timestamp


class Question(RowModel):
    _json_fields = frozenset({"job_ids", "options"})

    id: int
    canonical_question: str
    cluster_id: str
    job_ids: list[int] = Field(default_factory=list)
    field_type: FieldType = FieldType.TEXT
    options: list[str] = Field(default_factory=list)
    never_guess_key: str | None = None
    reason: QuestionReason = QuestionReason.UNKNOWN
    embedding_model: str | None = None
    status: QuestionStatus = QuestionStatus.OPEN
    answer_id: int | None = None
    answer_text: str | None = None
    suggested_answer: str | None = None
    suggested_confidence: float | None = None
    suggested_note: str | None = None
    created_at: Timestamp
    resolved_at: Timestamp | None = None


class DraftedAnswer(BaseModel):
    """One copy-paste row for the manual Easy Apply list."""

    model_config = ConfigDict(extra="forbid")
    question: str
    answer: str
    origin: AnswerOrigin = AnswerOrigin.GENERATED
    locked: bool = False
    ask_me: bool = False


class EasyApplyItem(RowModel):
    _json_fields = frozenset({"drafted_answers"})
    _bool_fields = frozenset({"opened", "done", "dismissed"})

    id: int
    job_id: int
    url: str
    drafted_answers: list[DraftedAnswer] = Field(default_factory=list)
    resume_variant_id: int | None = None
    opened: bool = False
    done: bool = False
    dismissed: bool = False
    done_at: Timestamp | None = None
    created_at: Timestamp
    updated_at: Timestamp


class RunStats(BaseModel):
    model_config = ConfigDict(extra="forbid")
    discovered: int = 0
    scored: int = 0
    skipped: int = 0
    queued: int = 0
    needs_you: int = 0
    awaiting_review: int = 0
    submitted: int = 0
    failed: int = 0


class Run(RowModel):
    _json_fields = frozenset({"stats"})

    id: int
    run_uid: str
    kind: RunKind
    trigger: RunTrigger = RunTrigger.MANUAL
    started_at: Timestamp
    finished_at: Timestamp | None = None
    outcome: RunOutcome | None = None
    stats: RunStats = Field(default_factory=RunStats)
    tokens_in: int = 0
    tokens_out: int = 0


class EventRow(RowModel):
    _json_fields = frozenset({"payload"})

    id: int
    ts: Timestamp
    kind: str
    actor: Actor = Actor.AGENT
    level: LogLevel = LogLevel.INFO
    run_id: int | None = None
    job_id: int | None = None
    application_id: int | None = None
    message: str
    payload: dict[str, Any] = Field(default_factory=dict)


# =====================================================================================
# Shared engine value types (used by discovery / prep / apply seams)
# =====================================================================================


class FormQuestion(BaseModel):
    """A question harvested from an application form (ATS API or browser scan)."""

    model_config = ConfigDict(extra="forbid")
    key: str = Field(description="Stable field id/name within the form.")
    label: str = Field(description="Question text as shown to the applicant.")
    field_type: FieldType = FieldType.TEXT
    required: bool = False
    options: list[str] = Field(default_factory=list)
    description: str | None = None
    max_length: int | None = None


# =====================================================================================
# Protocol: shared payload parts
# =====================================================================================


class _P(BaseModel):
    """Base for protocol payloads: strict (unknown keys rejected)."""

    model_config = ConfigDict(extra="forbid")


class Progress(_P):
    done: int = Field(ge=0)
    total: int = Field(ge=0)


class JobSummary(_P):
    id: int
    application_id: int | None = None
    company_id: int
    company: str
    title: str
    location: str | None = None
    remote: RemotePolicy | None = None
    source: JobSource
    ats: Ats
    apply_url: str | None = None
    source_url: str | None = None
    easy_apply: bool = False
    salary_min: int | None = None
    salary_max: int | None = None
    salary_currency: str | None = None
    discovered_at: Timestamp


class QuestionCluster(_P):
    """A Needs-You inbox cluster: semantically equivalent questions answered once."""

    cluster_id: str
    canonical_question: str
    field_type: FieldType = FieldType.TEXT
    options: list[str] = Field(default_factory=list, description="Union of options across the cluster.")
    never_guess_key: str | None = None
    reason: QuestionReason = QuestionReason.UNKNOWN
    question_ids: list[int] = Field(default_factory=list)
    variants: list[str] = Field(default_factory=list, description="Distinct wordings in the cluster.")
    job_ids: list[int] = Field(default_factory=list)
    job_count: int = 0
    companies: list[str] = Field(default_factory=list)
    created_at: Timestamp
    suggested_answer: str | None = Field(default=None, description="The agent's low-confidence draft, to accept or edit.")
    suggested_confidence: float | None = None
    suggested_note: str | None = Field(default=None, description="What the draft could not cover from the user's facts (shown beside it, never inside it).")


class RunInfo(_P):
    run_id: str
    kind: RunKind
    trigger: RunTrigger = RunTrigger.MANUAL
    started_at: Timestamp
    finished_at: Timestamp | None = None
    outcome: RunOutcome | None = None
    stats: RunStats = Field(default_factory=RunStats)
    tokens_in: int = 0
    tokens_out: int = 0


class Counts(_P):
    """Live counters for badges / hero. Derived from the DB at snapshot time."""

    queued: int = 0
    needs_you_clusters: int = 0
    needs_you_jobs: int = 0
    awaiting_review: int = 0
    easy_apply_open: int = 0
    unknown_verify: int = 0
    failed: int = 0
    submitted_today: int = 0
    discovered_today: int = 0
    submitted_total: int = 0


class CapsStatus(_P):
    daily_used: int = 0
    daily_limit: int = 0
    companies_cooling_down: int = 0
    linkedin_sessions_used: int = 0
    linkedin_sessions_limit: int = 0
    glassdoor_sessions_used: int = 0
    glassdoor_sessions_limit: int = 0


class SourceStatus(_P):
    source: SourceName
    enabled: bool = True
    connected: bool = False
    checked_at: Timestamp | None = None
    detail: str | None = None


class OnboardingState(_P):
    completed: bool = False
    step: int = Field(default=0, ge=0, le=7, description="0 = not started, 1..7 = onboarding step.")


class SystemCheckItem(_P):
    name: Literal["claude_cli", "uv", "node", "autoapplyd", "chrome"]
    ok: bool
    required: bool = True
    version: str | None = None
    detail: str | None = None
    fix_command: str | None = None


class SystemCheckResult(_P):
    """``ack.result`` for ``onboarding_system_check``."""

    items: list[SystemCheckItem]
    all_required_ok: bool


class ParseResumeResult(_P):
    """``ack.result`` for ``onboarding_parse_resume``."""

    resume_variant_id: int
    profile: Profile
    uncertain_fields: list[str] = Field(default_factory=list)


class PerJobAnswer(_P):
    job_id: int
    answer: str


# =====================================================================================
# Protocol: command payloads (app -> daemon)
# =====================================================================================


class HelloPayload(_P):
    client: Literal["app", "cli", "test"] = "app"
    client_version: str | None = None
    protocol_version: int = PROTOCOL_VERSION


class PingPayload(_P):
    pass


class RunNowPayload(_P):
    kind: RunKind = RunKind.FULL


class PauseAllPayload(_P):
    pass


class ResumePayload(_P):
    pass


class AnswerQuestionPayload(_P):
    cluster_id: str
    answer: str = Field(description="Answer text. May contain {company} / {role} tokens (template).")
    save_to_memory: bool = True
    save_to_profile: bool = Field(default=False, description="Never-guess clusters: write to never_guess instead.")
    per_job_answers: list[PerJobAnswer] = Field(
        default_factory=list, description="Per-job overrides ('Answer per job instead')."
    )


class SkipQuestionPayload(_P):
    cluster_id: str
    reason: str | None = None


class ApprovePayload(_P):
    application_ids: list[int] = Field(min_length=1)


class RejectPayload(_P):
    application_id: int
    reason: str


class SetStatusPayload(_P):
    application_id: int
    status: BoardStatus


class UpdatePreferencesPayload(_P):
    preferences: PreferencesPatch  # type: ignore[valid-type]


class UpdateNeverGuessPayload(_P):
    values: NeverGuessPatch  # type: ignore[valid-type]


class UpdateProfilePayload(_P):
    profile: ProfilePatch


class AddResumeVariantPayload(_P):
    file_path: str = Field(description="Absolute path to the PDF; the daemon copies it into <home>/resumes/.")
    label: str
    tags: list[str] = Field(default_factory=list)
    is_default: bool = False


class UpdateResumeVariantPayload(_P):
    id: int
    label: str | None = None
    tags: list[str] | None = None
    enabled: bool | None = None
    is_default: bool | None = None


class UpsertStoryPayload(_P):
    id: int | None = Field(default=None, description="Omit to create.")
    title: str
    situation: str = ""
    task: str = ""
    action: str = ""
    result: str = ""
    tags: list[str] = Field(default_factory=list)


class DeleteStoryPayload(_P):
    id: int


class UpdateAnswerPayload(_P):
    answer_id: int
    answer: str
    canonical_question: str | None = None


class DeleteAnswerPayload(_P):
    answer_id: int


class EditApplicationAnswerPayload(_P):
    application_answer_id: int
    answer: str


class SetJobModePayload(_P):
    job_id: int
    mode: Mode | None = Field(default=None, description="null = inherit.")


class RetryApplicationPayload(_P):
    application_id: int


class ApplyAnywayPayload(_P):
    """User override of a hard-filter / below-threshold skip: skipped -> queued (actor user)."""

    application_id: int


class UpdateJobNotesPayload(_P):
    job_id: int
    notes: str | None = Field(default=None, description="Free-form user notes; null or empty clears them.")


class SetApplicationResumePayload(_P):
    """Swap the resume an application will use (Review ↻). An application awaiting review is
    sent back to ``queued`` so the form is re-filled with the new file."""

    application_id: int
    resume_variant_id: int


class ResolveUnknownPayload(_P):
    application_id: int
    submitted: bool = Field(description="User verified whether the submission went through.")


class MarkEasyApplyDonePayload(_P):
    job_id: int


class MarkEasyApplyOpenedPayload(_P):
    job_id: int


class DismissEasyApplyPayload(_P):
    job_id: int


class OpenAgentChromePayload(_P):
    url: str | None = None


class OnboardingSystemCheckPayload(_P):
    pass


class OnboardingParseResumePayload(_P):
    file_path: str
    label: str | None = None


class OnboardingConnectSourcePayload(_P):
    source: Literal["linkedin", "glassdoor"]


class CheckSourceLoginPayload(_P):
    source: Literal["linkedin", "glassdoor"]


class SetMailAccountPayload(_P):
    email: str = Field(description="Mailbox the ATSs send security codes to (usually your application email).")
    app_password: str = Field(description="App password (Gmail: myaccount.google.com/apppasswords). Stored in the macOS Keychain only.")


class GetMailAccountPayload(_P):
    test: bool = Field(default=False, description="Also log in now to check the stored password still works.")


class ClearMailAccountPayload(_P):
    pass


class ResetSourceCapPayload(_P):
    source: Literal["linkedin", "glassdoor"]


class OnboardingSetStepPayload(_P):
    step: int = Field(ge=0, le=7)


class OnboardingCompletePayload(_P):
    run_prep: bool = False


COMMAND_PAYLOADS: dict[str, type[BaseModel]] = {
    "hello": HelloPayload,
    "ping": PingPayload,
    "run_now": RunNowPayload,
    "pause_all": PauseAllPayload,
    "resume": ResumePayload,
    "answer_question": AnswerQuestionPayload,
    "skip_question": SkipQuestionPayload,
    "approve": ApprovePayload,
    "reject": RejectPayload,
    "set_status": SetStatusPayload,
    "update_preferences": UpdatePreferencesPayload,
    "update_never_guess": UpdateNeverGuessPayload,
    "update_profile": UpdateProfilePayload,
    "add_resume_variant": AddResumeVariantPayload,
    "update_resume_variant": UpdateResumeVariantPayload,
    "upsert_story": UpsertStoryPayload,
    "delete_story": DeleteStoryPayload,
    "update_answer": UpdateAnswerPayload,
    "delete_answer": DeleteAnswerPayload,
    "edit_application_answer": EditApplicationAnswerPayload,
    "set_job_mode": SetJobModePayload,
    "retry_application": RetryApplicationPayload,
    "resolve_unknown": ResolveUnknownPayload,
    "apply_anyway": ApplyAnywayPayload,
    "update_job_notes": UpdateJobNotesPayload,
    "set_application_resume": SetApplicationResumePayload,
    "mark_easy_apply_done": MarkEasyApplyDonePayload,
    "mark_easy_apply_opened": MarkEasyApplyOpenedPayload,
    "dismiss_easy_apply": DismissEasyApplyPayload,
    "open_agent_chrome": OpenAgentChromePayload,
    "onboarding_system_check": OnboardingSystemCheckPayload,
    "onboarding_parse_resume": OnboardingParseResumePayload,
    "onboarding_connect_source": OnboardingConnectSourcePayload,
    "check_source_login": CheckSourceLoginPayload,
    "reset_source_cap": ResetSourceCapPayload,
    "set_mail_account": SetMailAccountPayload,
    "get_mail_account": GetMailAccountPayload,
    "clear_mail_account": ClearMailAccountPayload,
    "onboarding_set_step": OnboardingSetStepPayload,
    "onboarding_complete": OnboardingCompletePayload,
}


# =====================================================================================
# Protocol: event payloads (daemon -> app)
# =====================================================================================


class AckPayload(_P):
    """Success reply to a command (envelope carries ``reply_to``)."""

    ok: Literal[True] = True
    result: dict[str, Any] | None = Field(default=None, description="Command-specific result; see protocol.md.")


class ErrorPayload(_P):
    """Failure reply to a command (with ``reply_to``) or an unsolicited daemon error."""

    code: ErrorCode
    message: str
    details: dict[str, Any] | None = None
    job_id: int | None = None
    application_id: int | None = None


class StatePayload(_P):
    daemon: DaemonActivity
    paused: bool = False
    run_id: str | None = None
    progress: Progress | None = None
    message: str | None = Field(default=None, description="Human sentence for the hero / menu bar.")
    active_application_id: int | None = None
    active_job_id: int | None = None


class SnapshotPayload(_P):
    """Full live state. Sent as the reply to ``hello`` (and on demand)."""

    protocol_version: int = PROTOCOL_VERSION
    daemon_version: str
    state: StatePayload
    mode: Mode
    next_run_at: Timestamp | None = None
    current_run: RunInfo | None = None
    last_run: RunInfo | None = None
    counts: Counts = Field(default_factory=Counts)
    caps: CapsStatus = Field(default_factory=CapsStatus)
    open_clusters: list[QuestionCluster] = Field(default_factory=list)
    sources: list[SourceStatus] = Field(default_factory=list)
    onboarding: OnboardingState = Field(default_factory=OnboardingState)
    preferences: Preferences


class JobDiscoveredPayload(_P):
    job: JobSummary
    run_id: str | None = None


class JobScoredPayload(_P):
    job_id: int
    application_id: int
    score: int | None = Field(default=None, ge=0, le=100)
    reasons: dict[str, Any] = Field(default_factory=dict)
    skip_reason: str | None = None
    queued: bool = False
    run_id: str | None = None


class ApplicationStatePayload(_P):
    application_id: int
    job_id: int
    from_state: AppState | None = None
    to_state: AppState
    reason: str | None = None
    actor: Actor = Actor.AGENT
    at: Timestamp


class ApplicationStatusPayload(_P):
    """Manual board status changed (user drag-drop, auto-ghost, notification action)."""

    application_id: int
    job_id: int
    previous_status: BoardStatus | None = None
    status: BoardStatus
    actor: Actor = Actor.USER
    at: Timestamp


class QuestionOpenedPayload(_P):
    cluster: QuestionCluster


class QuestionResolvedPayload(_P):
    cluster_id: str
    status: Literal["answered", "skipped"]
    answer_id: int | None = None
    resumed_application_ids: list[int] = Field(default_factory=list)


class AgentStepPayload(_P):
    application_id: int
    job_id: int
    run_id: str | None = None
    index: int = Field(ge=0, description="0-based step index.")
    total: int | None = Field(default=None, ge=0)
    action: str = Field(description="Short verb phrase, e.g. 'answering \"Years with Go\"'.")
    detail: str | None = None
    confidence: float | None = Field(default=None, ge=0, le=1)
    screenshot_thumb: str | None = Field(default=None, description="Base64 JPEG, max 720px wide.")
    at: Timestamp


class CapReachedPayload(_P):
    cap: CapKind
    used: int
    limit: int
    resets_at: Timestamp | None = None
    company_id: int | None = None


class LogPayload(_P):
    level: LogLevel = LogLevel.INFO
    message: str
    logger: str | None = None
    job_id: int | None = None
    application_id: int | None = None
    at: Timestamp


class RunStartedPayload(_P):
    run: RunInfo


class RunFinishedPayload(_P):
    run: RunInfo


class SourceStatusPayload(_P):
    source: SourceStatus


class NudgeDuePayload(_P):
    application_id: int
    job_id: int
    day: int
    company: str
    title: str


EVENT_PAYLOADS: dict[str, type[BaseModel]] = {
    "ack": AckPayload,
    "error": ErrorPayload,
    "snapshot": SnapshotPayload,
    "state": StatePayload,
    "run_started": RunStartedPayload,
    "run_finished": RunFinishedPayload,
    "job_discovered": JobDiscoveredPayload,
    "job_scored": JobScoredPayload,
    "application_state": ApplicationStatePayload,
    "application_status": ApplicationStatusPayload,
    "question_opened": QuestionOpenedPayload,
    "question_resolved": QuestionResolvedPayload,
    "agent_step": AgentStepPayload,
    "cap_reached": CapReachedPayload,
    "source_status": SourceStatusPayload,
    "nudge_due": NudgeDuePayload,
    "log": LogPayload,
}

#: Events that are replies to a command and therefore MUST carry ``reply_to``.
#: (``snapshot`` carries it when it answers ``hello``; ``error`` when it answers a command.)
REPLY_EVENTS: frozenset[str] = frozenset({"ack"})


# =====================================================================================
# Envelope + codec
# =====================================================================================


class ProtocolError(Exception):
    """Raised when a line cannot be decoded into a valid message."""

    def __init__(self, code: ErrorCode, message: str, *, msg_id: str | None = None, details: dict | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.msg_id = msg_id
        self.details = details

    def to_event(self) -> "Envelope":
        return make_event(
            "error",
            ErrorPayload(code=self.code, message=self.message, details=self.details),
            reply_to=self.msg_id,
        )


class Envelope(BaseModel):
    """``{"v":1,"id":...,"type":...,"payload":{...},"reply_to"?:...}``"""

    model_config = ConfigDict(extra="forbid")

    v: Literal[1] = PROTOCOL_VERSION
    id: str = Field(default_factory=new_id, min_length=1)
    type: str = Field(min_length=1)
    reply_to: str | None = None
    payload: dict[str, Any] = Field(default_factory=dict)

    def typed_payload(self) -> BaseModel:
        """Validate ``payload`` against the model registered for ``type``."""
        model = COMMAND_PAYLOADS.get(self.type) or EVENT_PAYLOADS.get(self.type)
        if model is None:
            raise ProtocolError(ErrorCode.UNKNOWN_TYPE, f"unknown message type {self.type!r}", msg_id=self.id)
        try:
            return model.model_validate(self.payload)
        except ValidationError as e:
            raise ProtocolError(
                ErrorCode.INVALID_PAYLOAD,
                f"invalid payload for {self.type!r}",
                msg_id=self.id,
                details={"errors": json.loads(e.json(include_url=False))},
            ) from e

    def to_line(self) -> str:
        """Serialize as one NDJSON line (with trailing ``\\n``). ``reply_to`` omitted when null."""
        data = self.model_dump(mode="json")
        if data.get("reply_to") is None:
            data.pop("reply_to", None)
        return json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n"


def _payload_dict(payload: BaseModel | dict[str, Any] | None) -> dict[str, Any]:
    if payload is None:
        return {}
    if isinstance(payload, BaseModel):
        return payload.model_dump(mode="json")
    return dict(payload)


def make_command(type_: str, payload: BaseModel | dict[str, Any] | None = None, *, id: str | None = None) -> Envelope:
    if type_ not in COMMAND_PAYLOADS:
        raise ValueError(f"unknown command type {type_!r}")
    data = _payload_dict(payload)
    COMMAND_PAYLOADS[type_].model_validate(data)
    return Envelope(id=id or new_id(), type=type_, payload=data)


def make_event(
    type_: str,
    payload: BaseModel | dict[str, Any] | None = None,
    *,
    reply_to: str | None = None,
    id: str | None = None,
) -> Envelope:
    if type_ not in EVENT_PAYLOADS:
        raise ValueError(f"unknown event type {type_!r}")
    if type_ in REPLY_EVENTS and not reply_to:
        raise ValueError(f"{type_!r} events must carry reply_to")
    data = _payload_dict(payload)
    EVENT_PAYLOADS[type_].model_validate(data)
    return Envelope(id=id or new_id(), type=type_, reply_to=reply_to, payload=data)


def decode_line(line: str | bytes, *, expect: Literal["command", "event", "any"] = "any") -> tuple[Envelope, BaseModel]:
    """Parse one NDJSON line into (envelope, typed payload). Raises :class:`ProtocolError`."""
    if isinstance(line, bytes):
        try:
            line = line.decode("utf-8")
        except UnicodeDecodeError as e:
            raise ProtocolError(ErrorCode.BAD_REQUEST, "line is not valid UTF-8") from e
    try:
        raw = json.loads(line)
    except json.JSONDecodeError as e:
        raise ProtocolError(ErrorCode.BAD_REQUEST, f"invalid JSON: {e.msg}") from e
    if not isinstance(raw, dict):
        raise ProtocolError(ErrorCode.BAD_REQUEST, "message must be a JSON object")
    msg_id = raw.get("id") if isinstance(raw.get("id"), str) else None
    if raw.get("v") != PROTOCOL_VERSION:
        raise ProtocolError(
            ErrorCode.UNSUPPORTED_VERSION, f"unsupported protocol version {raw.get('v')!r}", msg_id=msg_id
        )
    missing = [k for k in ("id", "type", "payload") if k not in raw]
    if missing:
        raise ProtocolError(ErrorCode.BAD_REQUEST, f"envelope missing {missing}", msg_id=msg_id)
    try:
        env = Envelope.model_validate(raw)
    except ValidationError as e:
        raise ProtocolError(
            ErrorCode.BAD_REQUEST,
            "invalid envelope",
            msg_id=msg_id,
            details={"errors": json.loads(e.json(include_url=False))},
        ) from e
    registry: dict[str, type[BaseModel]]
    if expect == "command":
        registry = COMMAND_PAYLOADS
    elif expect == "event":
        registry = EVENT_PAYLOADS
    else:
        registry = {**COMMAND_PAYLOADS, **EVENT_PAYLOADS}
    if env.type not in registry:
        raise ProtocolError(ErrorCode.UNKNOWN_TYPE, f"unknown {expect} type {env.type!r}", msg_id=env.id)
    return env, env.typed_payload()


# =====================================================================================
# JSON Schema generation (contract/protocol.schema.json)
# =====================================================================================

_EXTRA_DEFS: tuple[type[BaseModel], ...] = (
    SystemCheckResult,
    ParseResumeResult,
    NeverGuess,
    Profile,
    FormQuestion,
)


def _collect_models(roots: list[type[BaseModel]]) -> dict[str, type[BaseModel]]:
    """All BaseModel classes reachable from ``roots`` through field annotations."""
    from typing import get_args

    found: dict[str, type[BaseModel]] = {}

    def visit(tp: Any) -> None:
        if isinstance(tp, type) and issubclass(tp, BaseModel):
            if tp.__name__ in found:
                return
            found[tp.__name__] = tp
            for f in tp.model_fields.values():
                visit(f.annotation)
            return
        for arg in get_args(tp):
            visit(arg)

    for r in roots:
        visit(r)
    return found


def _inject_factory_defaults(roots: list[type[BaseModel]], defs: dict[str, Any]) -> None:
    """pydantic omits ``default`` for ``default_factory`` fields; add the concrete value so
    other-language mirrors (Swift) can use the same defaults."""
    from pydantic import TypeAdapter

    for name, model in _collect_models(roots).items():
        props = defs.get(name, {}).get("properties", {})
        for fname, f in model.model_fields.items():
            if f.default_factory is not None and fname in props and "default" not in props[fname]:
                value = f.default_factory()  # type: ignore[call-arg]
                props[fname]["default"] = TypeAdapter(f.annotation).dump_python(value, mode="json")


def _title(type_: str) -> str:
    return "".join(p.capitalize() for p in type_.split("_"))


def build_protocol_schema() -> dict[str, Any]:
    """Build the protocol JSON Schema (draft 2020-12) from the registered payload models."""
    models: list[type[BaseModel]] = [*COMMAND_PAYLOADS.values(), *EVENT_PAYLOADS.values(), *_EXTRA_DEFS]
    seen: set[type[BaseModel]] = set()
    unique = [m for m in models if not (m in seen or seen.add(m))]
    _, top = models_json_schema([(m, "validation") for m in unique], ref_template="#/$defs/{model}")
    defs: dict[str, Any] = dict(sorted(top.get("$defs", {}).items()))
    _inject_factory_defaults(unique, defs)

    def envelope(kind: str, type_: str, payload_model: type[BaseModel]) -> dict[str, Any]:
        props: dict[str, Any] = {
            "v": {"const": PROTOCOL_VERSION},
            "id": {"type": "string", "minLength": 1},
            "type": {"const": type_},
            "payload": {"$ref": f"#/$defs/{payload_model.__name__}"},
        }
        required = ["v", "id", "type", "payload"]
        if kind == "Event":
            props["reply_to"] = {"type": "string", "minLength": 1}
            if type_ in REPLY_EVENTS:
                required.append("reply_to")
        return {
            "type": "object",
            "title": f"{kind}: {type_}",
            "properties": props,
            "required": required,
            "additionalProperties": False,
        }

    command_refs, event_refs = [], []
    for type_, model in COMMAND_PAYLOADS.items():
        name = f"Command{_title(type_)}"
        defs[name] = envelope("Command", type_, model)
        command_refs.append({"$ref": f"#/$defs/{name}"})
    for type_, model in EVENT_PAYLOADS.items():
        name = f"Event{_title(type_)}"
        defs[name] = envelope("Event", type_, model)
        event_refs.append({"$ref": f"#/$defs/{name}"})
    defs["Command"] = {"oneOf": command_refs}
    defs["Event"] = {"oneOf": event_refs}

    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://autoapply.local/contract/protocol.schema.json",
        "title": "AutoApply socket protocol",
        "description": (
            "NDJSON over <home>/autoapplyd.sock. GENERATED by `uv run python -m autoapply.models` "
            "from engine/autoapply/models.py - do not edit by hand. See contract/protocol.md."
        ),
        "x-protocol-version": PROTOCOL_VERSION,
        "x-command-types": list(COMMAND_PAYLOADS),
        "x-event-types": list(EVENT_PAYLOADS),
        "x-state-machine": {
            "states": [s.value for s in AppState],
            "transitions": {
                frm.value: sorted(t.value for t in tos) for frm, tos in ALLOWED_TRANSITIONS.items()
            },
            "user_only": sorted([f.value, t.value] for f, t in USER_ONLY_TRANSITIONS),
            "manual_submit_from": sorted(s.value for s in MANUAL_SUBMIT_FROM),
            "board_statuses": [s.value for s in BoardStatus],
        },
        "oneOf": [{"$ref": "#/$defs/Command"}, {"$ref": "#/$defs/Event"}],
        "$defs": defs,
    }


def render_protocol_schema() -> str:
    return json.dumps(build_protocol_schema(), indent=2, ensure_ascii=False) + "\n"


def write_protocol_schema(path: Any = None) -> str:
    from autoapply.paths import PROTOCOL_SCHEMA_PATH

    target = path or PROTOCOL_SCHEMA_PATH
    text = render_protocol_schema()
    with open(target, "w", encoding="utf-8") as f:
        f.write(text)
    return str(target)


if __name__ == "__main__":  # pragma: no cover
    print(f"wrote {write_protocol_schema()}")
