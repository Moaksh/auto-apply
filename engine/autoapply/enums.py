"""Canonical enumerations shared by the DB (CHECK constraints), protocol and engine.

These values MUST match contract/schema.sql CHECK constraints and
contract/protocol.schema.json. tests/foundation verifies both.
"""

from __future__ import annotations

from enum import StrEnum


class AppState(StrEnum):
    """Agent state machine for an application (contract/protocol.md §State machine)."""

    DISCOVERED = "discovered"
    SCORED = "scored"
    SKIPPED = "skipped"
    QUEUED = "queued"
    PREPPING = "prepping"
    NEEDS_YOU = "needs_you"
    FILLING = "filling"
    AWAITING_REVIEW = "awaiting_review"
    SUBMITTING = "submitting"
    SUBMITTED = "submitted"
    FAILED = "failed"
    UNKNOWN_VERIFY = "unknown_verify"


class BoardStatus(StrEnum):
    """Manual post-apply board status (only once state == submitted)."""

    APPLIED = "applied"
    ASSESSMENT = "assessment"
    INTERVIEW = "interview"
    OFFER = "offer"
    REJECTED = "rejected"
    GHOSTED = "ghosted"


class Mode(StrEnum):
    AUTO = "auto"
    REVIEW = "review"


class ApplicationMode(StrEnum):
    """Effective mode recorded on an application. ``manual`` = Easy Apply done by the user."""

    AUTO = "auto"
    REVIEW = "review"
    MANUAL = "manual"


class Ats(StrEnum):
    GREENHOUSE = "greenhouse"
    LEVER = "lever"
    ASHBY = "ashby"
    WORKDAY = "workday"
    LINKEDIN_EASY_APPLY = "linkedin_easy_apply"
    OTHER = "other"


class JobSource(StrEnum):
    GREENHOUSE = "greenhouse"
    LEVER = "lever"
    ASHBY = "ashby"
    CAREERS = "careers"
    LINKEDIN = "linkedin"
    GLASSDOOR = "glassdoor"
    GOOGLE = "google"
    MANUAL = "manual"


class RemotePolicy(StrEnum):
    REMOTE = "remote"
    HYBRID = "hybrid"
    ONSITE = "onsite"


class Seniority(StrEnum):
    JUNIOR = "junior"
    MID = "mid"
    SENIOR = "senior"
    STAFF = "staff"
    PRINCIPAL = "principal"


class FieldType(StrEnum):
    TEXT = "text"
    TEXTAREA = "textarea"
    NUMBER = "number"
    BOOLEAN = "boolean"
    SELECT = "select"
    MULTISELECT = "multiselect"
    URL = "url"
    EMAIL = "email"
    PHONE = "phone"
    DATE = "date"
    FILE = "file"


class AnswerOrigin(StrEnum):
    """Provenance of an answer in the Q&A audit (UI: ProvenanceTag)."""

    PROFILE = "profile"
    NEVER_GUESS = "never_guess"
    CV = "cv"
    MEMORY = "memory"
    STORY = "story"
    GENERATED = "generated"
    USER = "user"


class AnswerSource(StrEnum):
    USER = "user"
    GENERATED = "generated"


class QuestionStatus(StrEnum):
    OPEN = "open"
    ANSWERED = "answered"
    SKIPPED = "skipped"


class QuestionReason(StrEnum):
    """Why a question was parked in the Needs-You inbox."""

    UNKNOWN = "unknown"
    NEVER_GUESS = "never_guess"
    LOW_CONFIDENCE = "low_confidence"
    CAPTCHA = "captcha"
    ALWAYS_ASK = "always_ask"


class QuestionKind(StrEnum):
    """What a Needs-You item asks of the user (``questions.kind``).

    ``question``: a value to write into an application field (answered with text, may be saved
    to memory). ``action``: the agent is blocked and the user must DO something (create an
    account / sign in, solve a CAPTCHA, finish a verification) and then retry or skip the jobs.
    Actions are never saved to answer memory and never clustered with questions."""

    QUESTION = "question"
    ACTION = "action"


class AskConfidence(StrEnum):
    STRICT = "strict"
    BALANCED = "balanced"
    LENIENT = "lenient"


class DaemonActivity(StrEnum):
    IDLE = "idle"
    DISCOVERING = "discovering"
    SCORING = "scoring"
    PREPPING = "prepping"
    APPLYING = "applying"


class RunKind(StrEnum):
    FULL = "full"
    DISCOVER = "discover"
    PREP = "prep"
    APPLY = "apply"


class RunTrigger(StrEnum):
    MANUAL = "manual"
    SCHEDULED = "scheduled"
    WAKE = "wake"
    CLI = "cli"


class RunOutcome(StrEnum):
    COMPLETED = "completed"
    PAUSED = "paused"
    FAILED = "failed"
    CAP_REACHED = "cap_reached"


class Actor(StrEnum):
    AGENT = "agent"
    USER = "user"
    SYSTEM = "system"


class LogLevel(StrEnum):
    DEBUG = "debug"
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


class CapKind(StrEnum):
    DAILY = "daily"
    COMPANY_COOLDOWN = "company_cooldown"
    LINKEDIN_BUDGET = "linkedin_budget"
    GLASSDOOR_BUDGET = "glassdoor_budget"
    GOOGLE_BUDGET = "google_budget"


class SuggestionStatus(StrEnum):
    """``company_suggestions.status``."""

    PENDING = "pending"      # waiting for the user's Add / Dismiss
    ACCEPTED = "accepted"    # the user added it to the watchlist
    DISMISSED = "dismissed"  # never suggest (or auto-watch) again
    AUTO = "auto"            # a verified ATS board the agent watched by itself


class SourceName(StrEnum):
    """Discovery sources whose connection status the UI shows."""

    LINKEDIN = "linkedin"
    GLASSDOOR = "glassdoor"
    GOOGLE = "google"
    GREENHOUSE = "greenhouse"
    LEVER = "lever"
    ASHBY = "ashby"
    CAREERS = "careers"


class ErrorCode(StrEnum):
    BAD_REQUEST = "bad_request"          # unparseable line / bad envelope
    UNSUPPORTED_VERSION = "unsupported_version"
    UNKNOWN_TYPE = "unknown_type"
    INVALID_PAYLOAD = "invalid_payload"
    NOT_FOUND = "not_found"
    ILLEGAL_TRANSITION = "illegal_transition"
    CONFLICT = "conflict"
    PAUSED = "paused"
    CAP_REACHED = "cap_reached"
    UNAVAILABLE = "unavailable"          # e.g. claude CLI not logged in, Chrome missing
    INTERNAL = "internal"
