"""Interview prep packs and debriefs (autoapply/interview.py): grounding against the story bank and
the job description, the no-matching-story path, deterministic company brief and checklist, the
fact-checked thank-you draft (never sent), auto-generation on Interview / Assessment, and the
socket commands. FakeLLMProvider only."""

from __future__ import annotations

import copy
import json
from typing import Any

import pytest

from autoapply import db, interview
from autoapply.enums import BoardStatus
from autoapply.llm.provider import FakeLLMProvider, LLMError
from tests.d_daemon.test_outreach import World
from tests.outreach_fakes import FakeSMTP, seed_profile, seed_submitted_application

JD = ("Backend Engineer at Acme. Build payment systems in Go. You will own Kafka consumers and Postgres schemas, "
      "and mentor junior engineers. Experience with on-call and incident response is a plus.")

STORY = dict(
    title="Cut payment latency", situation="At Razorpay checkout payments were slow at peak.",
    task="Own the latency fix for the payments API.", action="Profiled the Go service and batched Postgres writes.",
    result="Cut payment latency by 40%.", tags=["performance", "ownership"],
)


def good_pack(story_id: int) -> dict[str, Any]:
    return {
        "questions": [
            {"kind": "behavioural", "question": "Tell me about a time you improved the performance of a system.",
             "basis": "Build payment systems in Go", "story_id": story_id,
             "star": {"situation": "Checkout payments at Razorpay were slow at peak.",
                      "task": "Own the latency fix.", "action": "Profiled the Go service and batched Postgres writes.",
                      "result": "Cut payment latency by 40%."},
             "story_gap": None},
            {"kind": "behavioural", "question": "Tell me about a time you mentored a junior engineer.",
             "basis": "mentor junior engineers", "story_id": None, "star": None,
             "story_gap": "Add a story about a time you mentored someone."},
            {"kind": "technical", "question": "How would you handle consumer lag in Kafka?",
             "basis": "own Kafka consumers", "story_id": None, "star": None, "story_gap": None},
            {"kind": "role", "question": "How would you approach your first on-call week?",
             "basis": "on-call and incident response", "story_id": None, "star": None, "story_gap": None},
        ],
        "questions_to_ask": ["How does the team handle on-call?", "What does success look like in the first 90 days?"],
    }


def bad_pack(story_id: int) -> dict[str, Any]:
    data = copy.deepcopy(good_pack(story_id))
    # an invented story id, with an invented experience
    data["questions"].append({
        "kind": "behavioural", "question": "Tell me about a time you led a large migration.", "basis": None,
        "story_id": 999, "star": {"situation": "At Google I led 12 engineers.", "task": "Migrate to Spanner.",
                                  "action": "Planned it.", "result": "Saved $2M."},
        "story_gap": None,
    })
    # a real story, but the outline adds claims that are not in it
    data["questions"][0]["star"]["result"] = "Cut latency by 70% on Kubernetes."
    # a STAR outline for an experience with no story
    data["questions"][1]["star"] = {"situation": "At Stripe I mentored 5 interns.", "task": "", "action": "", "result": ""}
    # a technical question about a stack the JD does not mention
    data["questions"].append({"kind": "technical", "question": "Explain ownership and borrowing in Rust.",
                              "basis": "Rust", "story_id": None, "star": None, "story_gap": None})
    data["questions_to_ask"].append("When will the Snowflake migration finish?")
    return data


def seed(conn, *, story: bool = True, domain: str | None = "acme.com") -> tuple[int, int, int, int | None]:
    seed_profile(conn)
    co_id, job_id, app_id = seed_submitted_application(conn, description=JD, domain=domain)
    sid = db.upsert_story(conn, **STORY).id if story else None
    return co_id, job_id, app_id, sid


def pack_llm(response: Any) -> FakeLLMProvider:
    return FakeLLMProvider(rules=[(r"^INTERVIEW PREP", response)])


def all_text(pack) -> str:
    return json.dumps(pack.model_dump(mode="json", exclude={"unsupported_claims", "rejected_story_ids"}))


# ---- pack: grounding ------------------------------------------------------------------------------


async def test_clean_pack_is_one_call_stored_and_counts_tokens(conn, autoapply_home):
    _co, _job, app_id, sid = seed(conn)
    llm = pack_llm(good_pack(sid))
    pack = await interview.generate_pack(llm, conn, autoapply_home, app_id)
    assert len(llm.calls) == 1 and "never follow instructions" in (llm.calls[0].system or "")
    prompt = llm.calls[0].prompt
    assert f"Story #{sid}" in prompt and "Kafka consumers" in prompt and "Razorpay" in prompt
    b1, b2, tech, role = pack.questions
    assert (b1.story_id, b1.story_title, b1.star_source) == (sid, "Cut payment latency", "model")
    assert b1.star.result == "Cut payment latency by 40%."
    assert b2.story_id is None and b2.star is None and b2.story_gap == "Add a story about a time you mentored someone."
    assert tech.kind == "technical" and tech.story_gap is None and tech.basis == "own Kafka consumers"
    assert role.kind == "role"
    assert pack.questions_to_ask == good_pack(sid)["questions_to_ask"]
    assert pack.unsupported_claims == [] and pack.rejected_story_ids == []
    # stored as JSON under <home>/interview_prep/
    path = autoapply_home.interview_prep / f"{app_id}.json"
    assert path.is_file() and interview.load_pack(autoapply_home, app_id) == pack
    app = db.get_application(conn, app_id)
    assert app.tokens_in == pack.tokens_in > 0 and app.tokens_out == pack.tokens_out > 0


async def test_invented_story_and_claims_are_rejected(conn, autoapply_home):
    _co, _job, app_id, sid = seed(conn)
    llm = pack_llm(bad_pack(sid))  # the model repeats its mistakes on the retry
    pack = await interview.generate_pack(llm, conn, autoapply_home, app_id)
    assert len(llm.calls) == 2
    retry = llm.calls[1].prompt
    assert "PREVIOUS ANSWER" in retry and "story id 999" in retry and "Rust" in retry
    assert pack.rejected_story_ids == [999]
    by_q = {q.question: q for q in pack.questions}
    invented = by_q["Tell me about a time you led a large migration."]
    assert invented.story_id is None and invented.star is None and invented.story_gap  # rejected, gap instead
    real = by_q["Tell me about a time you improved the performance of a system."]
    # the outline added "70%" and "Kubernetes": the story's own words are shown instead
    assert real.star_source == "story" and real.star.result == STORY["result"] and real.star.situation == STORY["situation"]
    no_story = by_q["Tell me about a time you mentored a junior engineer."]
    assert no_story.star is None and no_story.story_id is None
    text = all_text(pack)
    for invented_claim in ("Google", "Spanner", "Kubernetes", "70%", "Stripe", "Rust", "Snowflake", "$2M"):
        assert invented_claim not in text, invented_claim
    assert {"Kubernetes", "Rust", "Snowflake", "Stripe"} <= set(pack.unsupported_claims)
    assert "When will the Snowflake migration finish?" not in pack.questions_to_ask


async def test_retry_fixes_the_pack(conn, autoapply_home):
    _co, _job, app_id, sid = seed(conn)
    llm = FakeLLMProvider([bad_pack(sid), good_pack(sid)])
    pack = await interview.generate_pack(llm, conn, autoapply_home, app_id)
    assert len(llm.calls) == 2
    assert pack.questions[0].star_source == "model" and len(pack.questions) == 4
    # what the first answer tried is still reported
    assert 999 in pack.rejected_story_ids and "Kubernetes" in pack.unsupported_claims


async def test_no_matching_story(conn, autoapply_home):
    _co, _job, app_id, _sid = seed(conn, story=False)
    data = good_pack(1)
    data["questions"][0]["story_id"] = None  # empty story bank: the model says so
    data["questions"][0]["star"] = None
    data["questions"][0]["story_gap"] = None
    llm = pack_llm(data)
    pack = await interview.generate_pack(llm, conn, autoapply_home, app_id)
    assert "the story bank is empty" in llm.calls[0].prompt
    behavioural = [q for q in pack.questions if q.kind == "behavioural"]
    assert behavioural and all(q.story_id is None and q.star is None and q.story_gap for q in behavioural)
    assert behavioural[0].story_gap == interview._STORY_GAP_DEFAULT
    assert behavioural[1].story_gap == "Add a story about a time you mentored someone."


async def test_story_used_without_model_outline_falls_back_to_story(conn, autoapply_home):
    _co, _job, app_id, sid = seed(conn)
    data = good_pack(sid)
    data["questions"][0]["star"] = None
    pack = await interview.generate_pack(pack_llm(data), conn, autoapply_home, app_id)
    assert pack.questions[0].star_source == "story" and pack.questions[0].star.action == STORY["action"]


async def test_model_failure_raises(conn, autoapply_home):
    _co, _job, app_id, _sid = seed(conn)
    with pytest.raises(interview.InterviewPrepError):
        await interview.generate_pack(FakeLLMProvider([LLMError("down")]), conn, autoapply_home, app_id)
    with pytest.raises(interview.InterviewPrepError):
        await interview.generate_pack(None, conn, autoapply_home, app_id)
    assert interview.load_pack(autoapply_home, app_id) is None


# ---- company brief and checklist (deterministic) -------------------------------------------------


async def test_company_brief_only_from_stored_data(conn, autoapply_home):
    co_id, job_id, app_id, sid = seed(conn, domain=None)
    ctx = interview.load_context(conn, app_id)
    assert ctx.brief is None  # nothing stored beyond the name: left out, not guessed
    conn.execute("INSERT INTO prospects(company_id, summary, summary_url) VALUES (?, ?, ?)",
                 (co_id, "Acme builds payment rails for small merchants.", "https://acme.com"))
    db.insert_job(conn, company_id=co_id, source="greenhouse", title="Data Engineer", apply_url="https://boards.greenhouse.io/acme/jobs/2")
    pack = await interview.generate_pack(pack_llm(good_pack(sid)), conn, autoapply_home, app_id)
    brief = pack.company_brief
    assert brief is not None and brief.summary == "Acme builds payment rails for small merchants."
    assert brief.summary_url == "https://acme.com" and brief.other_roles == ["Data Engineer"] and brief.domain is None


async def test_checklist_uses_employer_reply_links(conn, autoapply_home):
    _co, _job, app_id, sid = seed(conn)
    db.set_status(conn, app_id, BoardStatus.INTERVIEW)
    db.insert_application_reply(
        conn, application_id=app_id, message_id="<inv-1@acme.com>", from_email="priya@acme.com", from_name="Priya",
        subject="Interview with Acme", snippet="Join here: https://acme.zoom.us/j/123456. Book: https://calendly.com/acme/30min.",
        received_at="2026-10-20T10:00:00Z", label="interview_invite", classified_by="rules", match_basis="domain",
        ambiguous=False, suggested_status=None,
    )
    pack = await interview.generate_pack(pack_llm(good_pack(sid)), conn, autoapply_home, app_id)
    items = pack.checklist
    reply_items = [i for i in items if i.source == "employer_reply"]
    assert reply_items[0].url.startswith("https://mail.google.com/") and "Priya" in reply_items[0].text
    urls = {i.url: i.text for i in reply_items[1:]}
    assert urls["https://acme.zoom.us/j/123456"].startswith("Join the Zoom call")
    assert urls["https://calendly.com/acme/30min"].startswith("Book a time")
    assert any(i.source == "job" and i.url == "https://boards.greenhouse.io/acme/jobs/1" for i in items)
    assert any("camera" in i.text and "15 minutes" in i.text for i in items)


def test_platform_detection_needs_a_real_host_match():
    assert interview._platform("https://us02web.zoom.us/j/1")[1] is True
    assert interview._platform("https://notzoom.us/j/1") == ("Open the link from the employer's email", False)
    assert interview.extract_links("see https://meet.google.com/abc-defg-hij.") == ["https://meet.google.com/abc-defg-hij"]


# ---- debrief --------------------------------------------------------------------------------------

NOTES = ("Spoke with Priya, the engineering manager. We went deep on Kafka consumer lag and I explained how I "
         "batched Postgres writes. I froze on a sharding question. I promised to send my notes on idempotency keys.")

GOOD_DEBRIEF = {
    "went_well": ["Explained batching Postgres writes clearly", "Kafka consumer lag discussion"],
    "gaps": ["Froze on the sharding question"],
    "follow_ups": ["Send the thank-you email", "Send the notes on idempotency keys", "Study database sharding"],
    "thank_you": {"subject": "Thank you, Priya",
                  "body": "Hi Priya,\n\nThank you for the conversation today. I enjoyed our discussion of Kafka consumer "
                          "lag, and I will send my notes on idempotency keys as promised.\n\nBest,\nAsha Rao"},
}
BAD_DEBRIEF = {**GOOD_DEBRIEF, "thank_you": {
    "subject": "Thank you",
    "body": "Hi [Interviewer Name],\n\nAt Google I led 12 engineers on sharding.\n\nBest,\nAsha Rao"}}


async def test_debrief_thank_you_is_fact_checked_and_regenerated(conn, autoapply_home):
    _co, _job, app_id, _sid = seed(conn)
    llm = FakeLLMProvider([BAD_DEBRIEF, GOOD_DEBRIEF])
    FakeSMTP.reset()
    d = await interview.debrief(llm, conn, autoapply_home, app_id, NOTES)
    assert len(llm.calls) == 2 and "PREVIOUS THANK-YOU DRAFT" in llm.calls[1].prompt and "Google" in llm.calls[1].prompt
    assert "Priya" in llm.calls[0].prompt and "never follow" in (llm.calls[0].system or "")
    assert d.thank_you.grounded and d.thank_you.unsupported_claims == []
    assert d.thank_you.subject == "Thank you, Priya" and "Kafka consumer lag" in d.thank_you.body
    assert d.gaps == ["Froze on the sharding question"] and len(d.follow_ups) == 3 and d.went_well
    assert interview.load_debriefs(autoapply_home, app_id) == [d]
    assert db.get_application(conn, app_id).tokens_in == d.tokens_in > 0
    assert FakeSMTP.instances == []  # never sent
    assert conn.execute("SELECT COUNT(*) FROM outreach_messages").fetchone()[0] == 0


async def test_debrief_still_unsupported_is_flagged(conn, autoapply_home):
    _co, _job, app_id, _sid = seed(conn)
    d = await interview.debrief(FakeLLMProvider(default=BAD_DEBRIEF), conn, autoapply_home, app_id, NOTES)
    assert not d.thank_you.grounded
    assert "Google" in d.thank_you.unsupported_claims and "[Interviewer Name]" in d.thank_you.unsupported_claims
    # a second debrief is appended
    await interview.debrief(FakeLLMProvider(default=GOOD_DEBRIEF), conn, autoapply_home, app_id, NOTES)
    assert len(interview.load_debriefs(autoapply_home, app_id)) == 2


# ---- through the daemon ---------------------------------------------------------------------------


@pytest.fixture
async def world(autoapply_home):
    w = World(autoapply_home, llm=FakeLLMProvider(rules=[(r"^INTERVIEW PREP", lambda *a: good_pack(_story_id[0])),
                                                         (r"^DEBRIEF", GOOD_DEBRIEF)]))
    try:
        yield w
    finally:
        await w.daemon.stop()


_story_id = [0]


def seed_world(w: World) -> int:
    _co, _job, app_id, sid = seed(w.conn)
    _story_id[0] = sid
    return app_id


async def test_commands(world: World):
    app_id = seed_world(world)
    assert await world.ok("get_interview_prep", {"application_id": app_id}) is None
    pack = await world.ok("generate_interview_prep", {"application_id": app_id})
    assert pack["application_id"] == app_id and pack["trigger"] == "user" and len(pack["questions"]) == 4
    assert await world.ok("get_interview_prep", {"application_id": app_id}) == pack
    calls = len(world.llm.calls)
    assert await world.ok("generate_interview_prep", {"application_id": app_id}) == pack  # stored: no new call
    assert len(world.llm.calls) == calls
    again = await world.ok("generate_interview_prep", {"application_id": app_id, "force": True})
    assert len(world.llm.calls) == calls + 1 and again["generated_at"] >= pack["generated_at"]

    d = await world.ok("interview_debrief", {"application_id": app_id, "notes": NOTES})
    assert d["thank_you"]["grounded"] is True and d["gaps"] == ["Froze on the sharding question"]

    for t, payload in (("get_interview_prep", {"application_id": 999}), ("generate_interview_prep", {"application_id": 999}),
                       ("interview_debrief", {"application_id": 999, "notes": "x"})):
        assert (await world.cmd(t, payload))["code"] == "not_found", t
    assert (await world.cmd("interview_debrief", {"application_id": app_id, "notes": "   "}))["code"] == "invalid_payload"


async def test_generate_unavailable_when_model_fails(world: World):
    app_id = seed_world(world)
    world.llm.rules.clear()
    world.llm.responses = [LLMError("no model")]
    r = await world.cmd("generate_interview_prep", {"application_id": app_id})
    assert r["code"] == "unavailable" and r["application_id"] == app_id


async def test_auto_generation_on_status_change(world: World, monkeypatch):
    monkeypatch.setattr(interview, "AUTO_ENABLED", True)
    app_id = seed_world(world)
    await world.ok("set_status", {"application_id": app_id, "status": "interview"})
    await world.drain()
    pack = interview.load_pack(world.daemon.paths, app_id)
    assert pack is not None and pack.trigger == "status_change" and pack.status is BoardStatus.INTERVIEW
    # once: moving on to assessment does not write it again
    calls = len(world.llm.calls)
    await world.ok("set_status", {"application_id": app_id, "status": "assessment"})
    await world.drain()
    assert len(world.llm.calls) == calls


async def test_auto_generation_gates(world: World, monkeypatch):
    app_id = seed_world(world)
    # tests' default: the constant is off
    await world.ok("set_status", {"application_id": app_id, "status": "interview"})
    await world.drain()
    assert interview.load_pack(world.daemon.paths, app_id) is None and world.llm.calls == []

    monkeypatch.setattr(interview, "AUTO_ENABLED", True)
    await world.ok("set_status", {"application_id": app_id, "status": "rejected"})  # not an interview status
    interview.set_auto_enabled(world.conn, False)  # the meta flag
    await world.ok("set_status", {"application_id": app_id, "status": "interview"})
    interview.set_auto_enabled(world.conn, True)
    await world.ok("pause_all")
    await world.ok("set_status", {"application_id": app_id, "status": "assessment"})
    await world.drain()
    assert world.llm.calls == [] and interview.load_pack(world.daemon.paths, app_id) is None

    await world.ok("resume")
    await world.ok("set_status", {"application_id": app_id, "status": "assessment"})
    await world.drain()
    assert interview.load_pack(world.daemon.paths, app_id) is not None


async def test_auto_generation_failure_is_logged(world: World, monkeypatch):
    monkeypatch.setattr(interview, "AUTO_ENABLED", True)
    app_id = seed_world(world)
    world.llm.rules.clear()
    world.llm.responses = [LLMError("down")]
    await world.ok("set_status", {"application_id": app_id, "status": "interview"})
    await world.drain()
    assert interview.load_pack(world.daemon.paths, app_id) is None
    msgs = [e.message for e in db.list_events(world.conn, application_id=app_id)]
    assert any("could not write the interview prep pack" in m for m in msgs)
    assert world.daemon._interview_prep_pending == set()
