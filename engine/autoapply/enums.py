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
    OUTREACH_DAILY = "outreach_daily"  # cold email: new threads per day (sends move to the next day)


class SuggestionStatus(StrEnum):
    """``company_suggestions.status``."""

    PENDING = "pending"      # waiting for the user's Add / Dismiss
    ACCEPTED = "accepted"    # the user added it to the watchlist
    DISMISSED = "dismissed"  # never suggest (or auto-watch) again
    AUTO = "auto"            # a verified ATS board the agent watched by itself


# ---- cold outreach (schema v10) ----------------------------------------------------------


class OutreachKind(StrEnum):
    """``outreach_threads.kind``: why the thread exists."""

    APPLICATION = "application"        # follow-up on a submitted application (mode a)
    PROSPECT = "prospect"              # prospecting a company with no application (mode b)
    REFERRAL_EMAIL = "referral_email"  # asking a would-be referrer by email


class DraftKind(StrEnum):
    """What a drafted text is for (prompt + word limit per kind)."""

    APPLICATION_FOLLOWUP = "application_followup"
    PROSPECT = "prospect"
    FOLLOWUP = "followup"
    LINKEDIN_CONNECT_NOTE = "linkedin_connect_note"
    LINKEDIN_REFERRAL_DM = "linkedin_referral_dm"
    REFERRAL_EMAIL = "referral_email"


class ThreadState(StrEnum):
    DRAFT = "draft"            # nothing sent yet
    ACTIVE = "active"          # at least one message sent, waiting
    REPLIED = "replied"
    BOUNCED = "bounced"
    OPTED_OUT = "opted_out"
    CLOSED = "closed"          # the user closed it (outcome recorded)
    CANCELLED = "cancelled"    # discarded before anything was sent


class MessageState(StrEnum):
    """``outreach_messages.state`` (transitions: ``models.MESSAGE_TRANSITIONS``)."""

    DRAFT = "draft"
    APPROVED = "approved"
    SCHEDULED = "scheduled"
    SENDING = "sending"        # committed (synchronous=FULL) before the SMTP conversation
    SENT = "sent"
    FAILED = "failed"          # refused before DATA: definitely not sent
    UNKNOWN = "unknown"        # crash / timeout during DATA: maybe sent, never resent automatically
    CANCELLED = "cancelled"
    RECEIVED = "received"      # inbound (a reply, a bounce, an auto-reply)


class ThreadOutcome(StrEnum):
    POSITIVE = "positive"
    REFERRED = "referred"
    NOT_INTERESTED = "not_interested"
    QUESTION = "question"
    OTHER = "other"


class ReplyLabel(StrEnum):
    """Classification of an inbound message (``outreach_messages.classification``)."""

    POSITIVE = "positive"
    REFERRED = "referred"
    NOT_INTERESTED = "not_interested"
    OPT_OUT = "opt_out"
    QUESTION = "question"
    OTHER = "other"
    OOO = "ooo"                # auto-reply: does not count as a reply
    BOUNCE = "bounce"


class ApplicationReplyLabel(StrEnum):
    """Classification of an employer / ATS email about a submitted application
    (``application_replies.label``). Every label counts as "heard back" for auto-ghosting."""

    INTERVIEW_INVITE = "interview_invite"  # suggests board status interview
    ASSESSMENT = "assessment"              # suggests assessment
    REJECTION = "rejection"                # suggests rejected
    OFFER = "offer"                        # suggests offer
    RECEIVED_ACK = "received_ack"          # "we received your application": no suggestion
    OTHER = "other"


class ReplySuggestionState(StrEnum):
    """``application_replies.suggestion_state``: a suggested board move is never applied by itself."""

    NONE = "none"          # nothing to suggest (acknowledgement, other, ambiguous, or already in that status)
    PENDING = "pending"    # waiting for the user's Accept / Dismiss
    ACCEPTED = "accepted"
    DISMISSED = "dismissed"


class RoleCategory(StrEnum):
    RECRUITER = "recruiter"
    TALENT_LEAD = "talent_lead"
    HIRING_MANAGER = "hiring_manager"
    ENG_LEADER = "eng_leader"
    ENGINEER = "engineer"
    FOUNDER = "founder"
    ROLE_MAILBOX = "role_mailbox"
    OTHER = "other"


class EmailStatus(StrEnum):
    NONE = "none"
    PATTERN = "pattern"
    PUBLISHED = "published"
    PROVIDER_VERIFIED = "provider_verified"
    USER = "user"
    DELIVERED = "delivered"    # sent, no bounce within 72 h
    REPLIED = "replied"
    BOUNCED = "bounced"


class ContactOrigin(StrEnum):
    SCOUT = "scout"
    USER = "user"
    IMPORT = "import"
    SHARED = "shared"


class Formality(StrEnum):
    """Writing-voice formality for generated text (answers/voice.py)."""

    CASUAL = "casual"
    NEUTRAL = "neutral"
    FORMAL = "formal"


class Relationship(StrEnum):
    FRIEND = "friend"
    EX_COLLEAGUE = "ex_colleague"
    ALUMNI = "alumni"
    MET = "met"
    OTHER = "other"


class EvidenceKind(StrEnum):
    USER = "user"
    JOB_POSTING = "job_posting"
    COMPANY_PAGE = "company_page"
    GITHUB = "github"
    GOOGLE_SERP = "google_serp"
    PATTERN = "pattern"
    PROVIDER = "provider"
    SHARED_LIBRARY = "shared_library"
    REPLY = "reply"
    BOUNCE = "bounce"


class SuppressionReason(StrEnum):
    OPT_OUT = "opt_out"        # can never be undone in the UI
    HARD_BOUNCE = "hard_bounce"
    USER = "user"
    SHARED_REMOVAL = "shared_removal"
    COMPLAINT = "complaint"


class ScoutPurpose(StrEnum):
    APPLICATION = "application"
    PROSPECT = "prospect"
    REFERRAL = "referral"


class ReferralState(StrEnum):
    """Referral copilot (the user does every LinkedIn step; transitions: ``models.REFERRAL_TRANSITIONS``)."""

    SUGGESTED = "suggested"
    TO_CONNECT = "to_connect"
    REQUESTED = "requested"
    CONNECTED = "connected"
    ASKED = "asked"
    REFERRED = "referred"
    DECLINED = "declined"
    NO_RESPONSE = "no_response"
    DISMISSED = "dismissed"


class ReferralBasis(StrEnum):
    ALUMNI = "alumni"
    EX_COLLEAGUE = "ex_colleague"
    SAME_FUNCTION = "same_function"
    USER = "user"
    OTHER = "other"


class ProspectStatus(StrEnum):
    SUGGESTED = "suggested"
    SHORTLISTED = "shortlisted"
    CONTACTED = "contacted"
    DISMISSED = "dismissed"


class MxProvider(StrEnum):
    GOOGLE = "google"
    MICROSOFT = "microsoft"
    OTHER = "other"
    NONE = "none"


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
