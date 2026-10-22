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
    AutonomyReport,
    AutonomySite,
    CapsStatus,
    Counts,
    Envelope,
    Insights,
    JobSummary,
    OnboardingState,
    Progress,
    QuestionCluster,
    RequirementBlocker,
    RunInfo,
    RunStats,
    ScoreBand,
    ScoreCalibration,
    SkipBlockers,
    SkipReasonCount,
    SourceStatus,
    StatePayload,
    UpskillHint,
    UpskillHints,
    VariantInsights,
    VariantPerformance,
    make_command,
    make_event,
)
from autoapply.paths import CONTRACT_DIR

EXAMPLES_PATH: Path = CONTRACT_DIR / "protocol.examples.ndjson"

TS = "2026-10-10T09:00:00.000Z"
CMD = "c0000000000000000000000000000001"

_insights = Insights(
    computed_at=TS,
    calibration=ScoreCalibration(
        bands=[ScoreBand(label="70–79", min_score=70, max_score=79, applications=12, responses=4, interviews=2,
                         response_rate=4 / 12, interview_rate=2 / 12, enough_data=True),
               ScoreBand(label="80–89", min_score=80, max_score=89, applications=9, responses=3, interviews=2,
                         response_rate=3 / 9, interview_rate=2 / 9, enough_data=True)],
        min_band_sample=8, match_threshold=70, resolved=21, in_flight=5, unscored=1, verdict="flat",
        finding="Jobs scored 70–79 got replies about as often as 80–89 (33% vs 33%), so your threshold (70) may be "
                "higher than it needs to be."),
    skip_blockers=SkipBlockers(
        window_days=30, skipped=14,
        reasons=[SkipReasonCount(reason="below_threshold", label="Match score below your threshold (70)", count=9,
                                 examples=["ML Engineer · Acme"])],
        requirements=[RequirementBlocker(label="Kubernetes", kind="skill", count=4,
                                         wordings=["No Kubernetes experience"], examples=["SRE · Globex"])]),
    upskill=UpskillHints(window_days=90, jobs_considered=17, min_jobs=3,
                         hints=[UpskillHint(skill="Terraform", jobs=5, skipped=4, rejected=1, examples=["SRE · Globex"])],
                         note="Skills these jobs asked for that your profile doesn't mention."),
    variants=VariantInsights(
        variants=[VariantPerformance(resume_variant_id=1, label="Backend", applications=14, responses=5, interviews=3,
                                     response_rate=5 / 14, low_sample=False)],
        finding="Not enough data yet to compare resumes: each needs at least 10 applications."),
)

_autonomy = AutonomyReport(threshold=10, sites=[
    AutonomySite(ats="greenhouse", mode="review", mode_source="global", approved=13, approved_without_edits=12, edited=1,
                 clean_approvals=12, since="2026-10-01T09:00:00.000Z", last_decision_at=TS, eligible=True,
                 suggestion="pending", suggested_at=TS),
    AutonomySite(ats="workday", mode="review", mode_source="site", approved=3, approved_without_edits=1, edited=2,
                 rejected_wrong_answers=1, clean_approvals=0, last_decision_at=TS),
    AutonomySite(ats="lever", mode="auto", mode_source="site"),
])

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
    c("add_job_url", {"url": "https://jobs.lever.co/acme/0b5c-uuid", "title": None, "company": None, "apply_now": True})
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
    c("accept_company_suggestion", {"suggestion_id": 3})
    c("dismiss_company_suggestion", {"suggestion_id": 4})
    c("set_mail_account", {"email": "jane@gmail.com", "app_password": "abcd efgh ijkl mnop"})
    c("get_mail_account", {"test": False})
    c("suggest_preferences", {})
    c("get_insights", {"force": False, "summarize": False})
    c("clear_mail_account", {})
    c("list_site_accounts", {})
    c("reveal_site_account_password", {"host": "acme.wd5.myworkdayjobs.com"})
    c("delete_site_account", {"host": "acme.wd5.myworkdayjobs.com"})
    c("queue_application", {"application_id": 7, "apply_now": True})
    c("mark_applied", {"application_id": 7, "status": "interview"})
    c("onboarding_set_step", {"step": 3})
    c("onboarding_complete", {"run_prep": True})
    # cold outreach
    c("scout_contacts", {"application_id": 11, "purpose": "application"})
    c("add_contact", {"company_name": "Acme", "full_name": "Jane Doe", "email": "jane@acme.com", "title": "Senior Recruiter",
                      "relationship": "ex_colleague", "notes": "Met at PyCon", "share_ok": False})
    c("update_contact", {"id": 5, "title": "Head of Talent", "notes": None})
    c("delete_contact", {"id": 5, "suppress": True})
    c("delete_contacts", {"older_than_days": 180, "all": False, "suppress": False})
    c("delete_contacts", {"ids": [5, 6], "all": False, "suppress": True})
    c("import_contacts", {"file_path": "/Users/me/contacts.csv"})
    c("import_linkedin_connections", {"file_path": "/Users/me/Downloads/Basic_LinkedInDataExport/Connections.csv"})
    c("draft_outreach", {"contact_id": 5, "kind": "application", "application_id": 11, "instructions": "Mention Go."})
    c("edit_outreach_draft", {"message_id": 8, "subject": "Backend Engineer application – Asha Rao",
                              "body": "Hi Jane,\n\nI applied for the Backend Engineer role…", "confirm_claims": False})
    c("approve_outreach", {"message_ids": [8, 9], "include_followups": True, "send_anyway": [9]})
    c("cancel_outreach", {"message_ids": [8]})
    c("discard_outreach", {"thread_id": 3})
    c("resolve_outreach_unknown", {"message_id": 8, "sent": True})
    c("mark_reply_read", {"thread_id": 3})
    c("accept_outreach_suggestion", {"thread_id": 3})
    c("dismiss_outreach_suggestion", {"thread_id": 3})
    c("set_thread_outcome", {"thread_id": 3, "outcome": "positive", "close": True})
    c("suppress", {"email": "someone@acme.com", "reason": "user"})
    c("unsuppress", {"domain": "acme.com"})
    c("enable_sending", {"enabled": True})
    c("search_prospects", {"query": "Series B fintech", "location": "Bangalore"})
    c("add_prospect", {"company_name": "Acme", "url": "https://acme.com"})
    c("update_prospect", {"id": 2, "status": "shortlisted", "watch": True})
    c("update_prospect", {"id": 2, "watch": False})
    c("suggest_referrers", {"company_id": 1, "job_id": 11})
    c("add_referral", {"contact_id": 5, "basis": "alumni", "basis_detail": "IIT Madras"})
    c("draft_referral", {"id": 4})
    c("update_referral", {"id": 4, "state": "requested"})
    c("accept_reply_suggestion", {"reply_id": 4})
    c("dismiss_reply_suggestion", {"reply_id": 5})
    c("mark_application_reply_read", {"reply_id": 4})
    c("set_provider_key", {"provider": "hunter", "api_key": "hunter-key"})
    c("generate_interview_prep", {"application_id": 11, "force": False})
    c("get_interview_prep", {"application_id": 11})
    c("interview_debrief", {"application_id": 11, "notes": "Spoke with Priya (EM). Went deep on Kafka consumer lag; I froze on a sharding question."})
    c("draft_answer", {"cluster_id": "c-async", "job_id": 11, "instructions": "Make it shorter and mention my Kafka work.",
                       "current_answer": "I have worked remotely for three years across time zones."})
    c("get_autonomy", {})
    c("dismiss_autonomy_suggestion", {"ats": "greenhouse"})
    c("get_voice_profile", {})
    c("update_voice_profile", {"sign_off": "Thanks", "formality": "neutral", "max_words": 180,
                               "avoid_phrases": ["circling back"], "writing_sample": "Hi Ravi, quick one about the Go role."})

    # ---- events
    e("ack", {"ok": True, "result": {"application_ids": [11, 12]}}, reply_to=CMD)
    e("ack", {"ok": True, "result": None}, reply_to=CMD)
    e("ack", {"ok": True, "result": _insights.model_dump(mode="json")}, reply_to=CMD)
    e("ack", {"ok": True, "result": _autonomy.model_dump(mode="json")}, reply_to=CMD)
    e("error", {"code": "illegal_transition", "message": "application 13 is not awaiting review",
                "details": {"state": "queued"}, "application_id": 13}, reply_to=CMD)
    e("snapshot", {
        "protocol_version": 1, "daemon_version": "0.1.0", "state": _state.model_dump(mode="json"), "mode": "auto",
        "next_run_at": "2026-10-10T13:00:00.000Z", "current_run": _run.model_dump(mode="json"), "last_run": None,
        "counts": Counts(queued=12, needs_you_clusters=1, needs_you_jobs=2, submitted_today=9, suggestions_pending=2).model_dump(),
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
    e("cap_reached", {"cap": "outreach_daily", "used": 5, "limit": 5, "resets_at": "2026-10-11T00:00:00.000Z"})
    e("source_status", {"source": {"source": "linkedin", "enabled": True, "connected": False,
                                   "checked_at": TS, "detail": "Waiting for you to log in in Chrome…"}})
    e("nudge_due", {"application_id": 11, "job_id": 11, "day": 7, "company": "Stripe", "title": "Backend Engineer"})
    e("outreach_state", {"thread_id": 3, "message_id": 8, "entity": "message", "from_state": "scheduled",
                         "to_state": "sending", "reason": None, "at": TS})
    e("outreach_state", {"thread_id": 3, "entity": "thread", "from_state": "active", "to_state": "replied",
                         "reason": "reply: positive", "at": TS})
    e("outreach_reply", {"thread_id": 3, "message_id": 12, "contact_name": "Jane Doe", "company": "Acme", "label": "positive",
                         "snippet": "Thanks, I've passed your profile to the team.", "application_id": 11,
                         "suggested_status": "interview"})
    e("application_reply", {"reply_id": 4, "application_id": 11, "job_id": 11, "company": "Stripe", "title": "Backend Engineer",
                            "label": "interview_invite", "suggested_status": "interview", "ambiguous": False,
                            "from_email": "no-reply@us.greenhouse-mail.io", "from_name": "Stripe Recruiting",
                            "subject": "Stripe: next steps for Backend Engineer",
                            "snippet": "We'd love to schedule a call. Pick a time: https://calendly.com/stripe-recruiting",
                            "received_at": TS, "message_id": "<abc123@greenhouse-mail.io>"})
    e("scout_finished", {"company_id": 1, "purpose": "application", "application_id": 11, "found": 6, "with_email": 4,
                         "best_confidence": 95, "queued_google": True, "thread_id": 3})
    e("autonomy_suggestion", {"ats": "greenhouse", "clean_approvals": 10, "since": "2026-10-01T09:00:00.000Z"})
    e("log", {"level": "warning", "message": "selector timeout on step 5 · retried ok", "logger": "apply.lever",
              "job_id": 11, "application_id": 11, "at": TS})
    return out


def render() -> str:
    return "".join(env.to_line() for env in samples())


if __name__ == "__main__":  # pragma: no cover
    EXAMPLES_PATH.write_text(render(), encoding="utf-8")
    print(f"wrote {EXAMPLES_PATH}")
