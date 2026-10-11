"""One canonical example message per protocol type.

Rendered to contract/protocol.examples.ndjson (consumed by the Swift MessagesTests to prove
both sides agree). Regenerate with:

    uv run python -m tests.foundation.protocol_samples
"""

from __future__ import annotations

from pathlib import Path

from autoapply.config import Preferences
from autoapply.models import (
    AgentStepPayload,
    CapsStatus,
    Counts,
    Envelope,
    JobSummary,
    OnboardingState,
    Progress,
    QuestionCluster,
    RunInfo,
    RunStats,
    SourceStatus,
    StatePayload,
    make_command,
    make_event,
)
from autoapply.paths import CONTRACT_DIR

EXAMPLES_PATH: Path = CONTRACT_DIR / "protocol.examples.ndjson"

TS = "2026-10-10T09:00:00.000Z"
CMD = "c0000000000000000000000000000001"

_cluster = QuestionCluster(
    cluster_id="9f2c4b1e0d8a4c6b9e1f2a3b4c5d6e7f",
    canonical_question="Why do you want to work here?",
    field_type="textarea",
    question_ids=[1, 2],
    variants=["Why Stripe?", "What draws you to Ramp?"],
    job_ids=[11, 12],
    job_count=2,
    companies=["Ramp", "Stripe"],
    created_at=TS,
)
_run = RunInfo(run_id="a1b2c3d4e5f60718293a4b5c6d7e8f90", kind="full", trigger="scheduled", started_at=TS,
               stats=RunStats(discovered=40, scored=40, skipped=27, queued=12, submitted=9))
_state = StatePayload(daemon="applying", paused=False, run_id=_run.run_id, progress=Progress(done=3, total=12),
                      message="Filling Stripe · Backend Engineer", active_application_id=11, active_job_id=11)


def samples() -> list[Envelope]:
    out: list[Envelope] = []
    n = 0

    def cid() -> str:
        nonlocal n
        n += 1
        return f"{n:032x}"

    def c(type_: str, payload: dict | None = None) -> None:
        out.append(make_command(type_, payload or {}, id=cid()))

    def e(type_: str, payload, reply_to: str | None = None) -> None:
        out.append(make_event(type_, payload, reply_to=reply_to, id=cid()))

    # ---- commands
    c("hello", {"client": "app", "client_version": "0.1.0", "protocol_version": 1})
    c("ping")
    c("run_now", {"kind": "prep"})
    c("pause_all")
    c("resume")
    c("answer_question", {"cluster_id": _cluster.cluster_id, "answer": "I'm drawn to {company} because…",
                          "save_to_memory": True, "save_to_profile": False,
                          "per_job_answers": [{"job_id": 12, "answer": "Ramp-specific answer"}]})
    c("skip_question", {"cluster_id": _cluster.cluster_id, "reason": "not relevant"})
    c("approve", {"application_ids": [11, 12]})
    c("reject", {"application_id": 13, "reason": "wrong answers"})
    c("set_status", {"application_id": 11, "status": "interview"})
    c("update_preferences", {"preferences": {"match_threshold": 65, "per_ats_mode": {"lever": "review"},
                                             "schedule": ["09:00", "14:00"]}})
    c("update_never_guess", {"values": {"notice_period": "60 days", "work_auth": {"US": "requires_sponsorship"},
                                        "sponsorship": None}})
    c("update_profile", {"profile": {"full_name": "Moaksh Kakkar", "skills": ["go", "python"],
                                     "work_history": [{"company": "Plum", "title": "SWE"}]}})
    c("add_resume_variant", {"file_path": "/Users/me/Backend.pdf", "label": "Backend", "tags": ["backend", "go"],
                             "is_default": True})
    c("update_resume_variant", {"id": 2, "enabled": False})
    c("upsert_story", {"title": "Payments at scale", "situation": "S", "task": "T", "action": "A", "result": "R",
                       "tags": ["scale"]})
    c("delete_story", {"id": 3})
    c("update_answer", {"answer_id": 4, "answer": "3 years"})
    c("delete_answer", {"answer_id": 4})
    c("edit_application_answer", {"application_answer_id": 9, "answer": "2 months"})
    c("set_job_mode", {"job_id": 11, "mode": None})
    c("retry_application", {"application_id": 14})
    c("apply_anyway", {"application_id": 15})
    c("update_job_notes", {"job_id": 11, "notes": "Referred by Sam"})
    c("set_application_resume", {"application_id": 12, "resume_variant_id": 2})
    c("resolve_unknown", {"application_id": 15, "submitted": True})
    c("mark_easy_apply_done", {"job_id": 21})
    c("mark_easy_apply_opened", {"job_id": 21})
    c("dismiss_easy_apply", {"job_id": 22})
    c("open_agent_chrome", {"url": "https://www.linkedin.com/login"})
    c("onboarding_system_check")
    c("onboarding_parse_resume", {"file_path": "/Users/me/Backend.pdf", "label": "Backend"})
    c("onboarding_connect_source", {"source": "linkedin"})
    c("check_source_login", {"source": "glassdoor"})
    c("reset_source_cap", {"source": "linkedin"})
    c("set_mail_account", {"email": "jane@gmail.com", "app_password": "abcd efgh ijkl mnop"})
    c("get_mail_account", {"test": False})
    c("clear_mail_account", {})
    c("onboarding_set_step", {"step": 3})
    c("onboarding_complete", {"run_prep": True})

    # ---- events
    e("ack", {"ok": True, "result": {"application_ids": [11, 12]}}, reply_to=CMD)
    e("ack", {"ok": True, "result": None}, reply_to=CMD)
    e("error", {"code": "illegal_transition", "message": "application 13 is not awaiting review",
                "details": {"state": "queued"}, "application_id": 13}, reply_to=CMD)
    e("snapshot", {
        "protocol_version": 1, "daemon_version": "0.1.0", "state": _state.model_dump(mode="json"), "mode": "auto",
        "next_run_at": "2026-10-10T13:00:00.000Z", "current_run": _run.model_dump(mode="json"), "last_run": None,
        "counts": Counts(queued=12, needs_you_clusters=1, needs_you_jobs=2, submitted_today=9).model_dump(),
        "caps": CapsStatus(daily_used=9, daily_limit=15).model_dump(),
        "open_clusters": [_cluster.model_dump(mode="json")],
        "sources": [SourceStatus(source="linkedin", enabled=True, connected=True, checked_at=TS).model_dump(mode="json")],
        "onboarding": OnboardingState(completed=True, step=7).model_dump(),
        "preferences": Preferences().model_dump(mode="json"),
    }, reply_to=CMD)
    e("state", _state)
    e("state", {"daemon": "idle", "paused": True})
    e("run_started", {"run": _run.model_dump(mode="json")})
    e("run_finished", {"run": {**_run.model_dump(mode="json"), "finished_at": "2026-10-10T09:03:00.000Z",
                               "outcome": "completed", "tokens_in": 12000, "tokens_out": 3400}})
    e("job_discovered", {"job": JobSummary(id=11, application_id=11, company_id=1, company="Stripe",
                                           title="Backend Engineer, Payments", location="Remote (India)",
                                           remote="remote", source="greenhouse", ats="greenhouse",
                                           apply_url="https://boards.greenhouse.io/stripe/jobs/1",
                                           discovered_at=TS).model_dump(mode="json"), "run_id": _run.run_id})
    e("job_scored", {"job_id": 11, "application_id": 11, "score": 91,
                     "reasons": {"summary": "strong Go + payments", "factors": {"skills": 95, "seniority": 85}},
                     "skip_reason": None, "queued": True, "run_id": _run.run_id})
    e("application_state", {"application_id": 11, "job_id": 11, "from_state": "filling", "to_state": "submitting",
                            "reason": None, "actor": "agent", "at": TS})
    e("application_status", {"application_id": 11, "job_id": 11, "previous_status": "applied",
                             "status": "interview", "actor": "user", "at": TS})
    e("question_opened", {"cluster": _cluster.model_dump(mode="json")})
    e("question_resolved", {"cluster_id": _cluster.cluster_id, "status": "answered", "answer_id": 4,
                            "resumed_application_ids": [11, 12]})
    e("agent_step", AgentStepPayload(application_id=11, job_id=11, run_id=_run.run_id, index=3, total=7,
                                     action='answering "Years with Go"', detail="cv · 0.93", confidence=0.93,
                                     screenshot_thumb="/9j/4AAQSkZJRgABAQ==", at=TS))
    e("cap_reached", {"cap": "daily", "used": 15, "limit": 15, "resets_at": "2026-10-11T00:00:00.000Z"})
    e("source_status", {"source": {"source": "linkedin", "enabled": True, "connected": False,
                                   "checked_at": TS, "detail": "Waiting for you to log in in Chrome…"}})
    e("nudge_due", {"application_id": 11, "job_id": 11, "day": 7, "company": "Stripe", "title": "Backend Engineer"})
    e("log", {"level": "warning", "message": "selector timeout on step 5 · retried ok", "logger": "apply.lever",
              "job_id": 11, "application_id": 11, "at": TS})
    return out


def render() -> str:
    return "".join(env.to_line() for env in samples())


if __name__ == "__main__":  # pragma: no cover
    EXAMPLES_PATH.write_text(render(), encoding="utf-8")
    print(f"wrote {EXAMPLES_PATH}")
