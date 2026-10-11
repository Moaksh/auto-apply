"""Agentic adapter with the Claude Agent SDK mocked by a scripted client.

The fake client mimics the SDK's permission flow for every tool call: PreToolUse hook
first, then ``can_use_tool`` for tools not in ``allowed_tools``; allowed calls run the
real toolbox handlers (own tools) or return canned page text (browser tools).
"""

from __future__ import annotations

import itertools
from pathlib import Path
from typing import Any

import pytest
from claude_agent_sdk import AssistantMessage, ResultMessage, ToolPermissionContext, ToolResultBlock, ToolUseBlock, UserMessage

from autoapply import db
from autoapply.apply.agentic import (
    PLAYWRIGHT_MCP_PACKAGE,
    AgenticAdapter,
    AgentToolbox,
    ToolGate,
    browser_id,
    tool_id,
)
from autoapply.apply.base import PausedError
from autoapply.enums import AnswerOrigin, AppState, Ats, Mode
from autoapply.llm.provider import FakeLLMProvider

from .conftest import gen, make_ctx, make_job, seed_profile

_ids = itertools.count(1)

SNAPSHOT = """- heading "Apply to Stripe" [ref=e1]
- textbox "First name" [ref=e2]
- textbox "Email" [ref=e3]
- combobox "Will you require sponsorship?" [ref=e4]
- button "Upload resume" [ref=e5]
- button "Submit application" [ref=e9]
"""


def step(tool: str, inp: dict[str, Any] | None = None, result: str = "ok") -> tuple[str, dict[str, Any], str]:
    name = tool if tool.startswith("mcp__") else (browser_id(tool) if tool.startswith("browser_") else tool_id(tool))
    return name, inp or {}, result


class FakeClient:
    def __init__(self, options: Any, toolbox: AgentToolbox, scripts: list[list[tuple[str, dict[str, Any], str]]], log: dict):
        self.options = options
        self.toolbox = toolbox
        self.scripts = scripts
        self.log = log
        self.connected = False
        self.interrupted = False
        self.script: list = []
        log.setdefault("clients", []).append(self)
        self.results: list[tuple[str, str, bool]] = []

    async def connect(self, prompt: Any = None) -> None:
        self.connected = True

    async def query(self, prompt: str, session_id: str = "default") -> None:
        self.log.setdefault("prompts", []).append(prompt)
        self.script = self.scripts.pop(0)

    async def interrupt(self) -> None:
        self.interrupted = True

    async def disconnect(self) -> None:
        self.connected = False
        self.log["disconnects"] = self.log.get("disconnects", 0) + 1

    async def _permitted(self, name: str, inp: dict[str, Any], use_id: str) -> tuple[bool, str]:
        for matcher in self.options.hooks.get("PreToolUse", []):
            for hook in matcher.hooks:
                out = await hook({"tool_name": name, "tool_input": inp}, use_id, None)
                spec = out.get("hookSpecificOutput") or {}
                if spec.get("permissionDecision") == "deny":
                    return False, spec["permissionDecisionReason"]
        if name in self.options.disallowed_tools:
            return False, "disallowed"
        if name not in self.options.allowed_tools:
            res = await self.options.can_use_tool(name, inp, ToolPermissionContext(tool_use_id=use_id))
            if res.behavior == "deny":
                return False, res.message
        return True, ""

    async def _execute(self, name: str, inp: dict[str, Any], canned: str, use_id: str) -> tuple[str, bool]:
        ok, why = await self._permitted(name, inp, use_id)
        if not ok:
            return why, True
        if name.startswith("mcp__autoapply__"):
            out = await self.toolbox.handler(name)(inp)
            return out["content"][0]["text"], bool(out.get("is_error"))
        if name.endswith("browser_take_screenshot"):
            out_dir = Path(self.options.cwd)
            (out_dir / inp.get("filename", "shot.png")).write_bytes(b"\x89PNG fake")
        return canned, False

    async def receive_response(self):
        for name, inp, canned in self.script:
            use_id = f"tu{next(_ids)}"
            yield AssistantMessage(content=[ToolUseBlock(id=use_id, name=name, input=inp)], model="fake")
            text, is_error = await self._execute(name, inp, canned, use_id)
            self.results.append((name, text, is_error))
            yield UserMessage(content=[ToolResultBlock(tool_use_id=use_id, content=[{"type": "text", "text": text}], is_error=is_error)])
            if self.interrupted:
                break
        yield ResultMessage(subtype="success", duration_ms=1, duration_api_ms=1, is_error=False, num_turns=3, session_id="s",
                            usage={"input_tokens": 1000, "output_tokens": 200, "cache_read_input_tokens": 50}, total_cost_usd=0.01)


def adapter_with(scripts: list[list], log: dict) -> AgenticAdapter:
    return AgenticAdapter(client_factory=lambda options, toolbox: FakeClient(options, toolbox, scripts, log))


@pytest.fixture
def world(conn, autoapply_home, emit, tmp_path):
    seed_profile(conn)
    resume = tmp_path / "backend.pdf"
    resume.write_bytes(b"%PDF fake")
    v = db.add_resume_variant(conn, label="Backend", file_path=str(resume), tags=["backend"])
    db.set_never_guess(conn, {"sponsorship": "Not required"})
    job, app = make_job(conn, ats=Ats.WORKDAY, state=AppState.FILLING, apply_url="https://stripe.wd1.myworkdayjobs.com/apply/1")
    db.update_application(conn, app.id, resume_variant_id=v.id)
    llm = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("I want to build payments infrastructure.", 0.9))])
    return {"conn": conn, "home": autoapply_home, "emit": emit, "job": job, "app": app, "resume": str(resume), "llm": llm}


def ctx_for(world, **kw):
    return make_ctx(world["conn"], world["app"].id, world["llm"], world["home"], world["emit"], **kw)


FILL_SCRIPT = [
    step("browser_navigate", {"url": "https://stripe.wd1.myworkdayjobs.com/apply/1"}, SNAPSHOT),
    step("get_profile"),
    step("lookup_answer", {"question": "First name"}),
    step("browser_type", {"element": "First name", "ref": "e2", "text": "Ada"}),
    step("lookup_answer", {"question": "Email", "field_type": "email"}),
    step("browser_type", {"element": "Email", "ref": "e3", "text": "ada@example.com"}),
    step("lookup_answer", {"question": "Will you require sponsorship?", "field_type": "select", "options": ["Yes", "No"]}),
    step("browser_select_option", {"element": "sponsorship", "ref": "e4", "values": ["No"]}),
    step("pick_resume"),
    step("lookup_answer", {"question": "Why do you want to work at Stripe?", "field_type": "textarea"}),
    step("browser_take_screenshot", {"fullPage": True, "filename": "prefill.png"}),
]


def submit_request(**extra: Any):
    return step("request_submit", {"answers": [
        {"question": "First name", "answer": "Ada"},
        {"question": "Email", "answer": "ada@example.com"},
        {"question": "Will you require sponsorship?", "answer": "No"},
        {"question": "Why do you want to work at Stripe?", "answer": "I want to build payments infrastructure."},
        {"question": "Resume", "answer": extra.pop("resume", "backend.pdf")},
    ], "screenshot": "prefill.png", **extra})


# ---- gate unit tests -------------------------------------------------------------------


def test_gate_blocks_submit_clicks_until_armed():
    g = ToolGate()
    g.observe(SNAPSHOT)
    click = browser_id("browser_click")
    assert g.check(click, {"element": "First name", "ref": "e2"}, "a").allowed
    # by description
    assert not g.check(click, {"element": "Submit application button", "ref": "e9"}, "b").allowed
    # mislabelled element, but the ref's accessible name is "Submit application"
    assert not g.check(click, {"element": "Continue", "ref": "e9"}, "c").allowed
    g.arm_submit()
    assert g.check(click, {"element": "Submit", "ref": "e9"}, "d").allowed
    assert g.submit_clicked
    assert not g.check(click, {"element": "Submit", "ref": "e9"}, "e").allowed  # exactly once
    # hook + can_use_tool for the same call share one decision
    g.arm_submit()
    first = g.check(click, {"element": "Submit", "ref": "e9"}, "f")
    again = g.check(click, {"element": "Submit", "ref": "e9"}, "f")
    assert first.allowed and again.allowed and g.submit_clicks_left == 0


def test_gate_other_rules(tmp_path):
    g = ToolGate()
    g.observe(SNAPSHOT)
    ok = tmp_path / "r.pdf"
    ok.write_text("x")
    g.allowed_upload_paths.add(str(ok.resolve()))
    c = itertools.count()

    def chk(tool, inp):
        return g.check(tool if tool.startswith("mcp__") else browser_id(tool), inp, f"x{next(c)}").allowed

    assert not chk("browser_navigate", {"url": "https://www.linkedin.com/jobs/view/1"})
    assert not chk("browser_navigate", {"url": "https://glassdoor.com/x"})
    assert not chk("browser_navigate", {"url": "file:///etc/passwd"})
    assert chk("browser_navigate", {"url": "https://boards.greenhouse.io/x"})
    assert not chk("browser_evaluate", {"function": "() => form.submit()"})
    assert not chk("browser_run_code", {})
    assert not chk("mcp__other__thing", {})
    assert not chk("browser_type", {"ref": "e2", "text": "Ada", "submit": True})
    assert not chk("browser_press_key", {"key": "Enter"})
    assert chk("browser_click", {"element": "sponsorship", "ref": "e4"})  # combobox focus
    assert chk("browser_press_key", {"key": "Enter"})
    assert chk("browser_file_upload", {"paths": [str(ok)]})
    assert not chk("browser_file_upload", {"paths": ["/Users/someone/.ssh/id_rsa"]})
    assert chk("browser_snapshot", {})
    assert chk(tool_id("lookup_answer"), {})


def test_options_wire_playwright_mcp_and_gate(world):
    ad = AgenticAdapter()
    ctx = ctx_for(world)
    tb = ad._toolbox(ctx, "fill")
    opts = ad._options(ctx, tb)
    pw = opts.mcp_servers["playwright"]
    assert pw["command"] == "npx" and PLAYWRIGHT_MCP_PACKAGE in pw["args"]
    assert pw["args"][pw["args"].index("--user-data-dir") + 1] == str(world["home"].chrome_profile)
    assert "--headless" in pw["args"]
    assert opts.mcp_servers["autoapply"]["type"] == "sdk"
    assert opts.tools == [] and opts.setting_sources == []
    assert browser_id("browser_click") not in opts.allowed_tools  # gated => can_use_tool consulted
    assert browser_id("browser_evaluate") in opts.disallowed_tools
    assert opts.can_use_tool == tb.gate.can_use_tool
    assert len(tb.sdk_tools()) == 9


def test_can_handle():
    from autoapply.models import Job

    base = {"id": 1, "source": "careers", "company_id": 1, "title": "t", "discovered_at": "2026-01-01T00:00:00Z", "dedupe_key": "k"}
    ad = AgenticAdapter()
    assert ad.can_handle(Job(**base, ats="workday", apply_url="https://x.wd1.myworkdayjobs.com/a"))
    assert ad.can_handle(Job(**base, ats="other", apply_url="https://jobs.example.com/a"))
    assert not ad.can_handle(Job(**base, ats="greenhouse", apply_url="https://boards.greenhouse.io/a"))
    assert not ad.can_handle(Job(**base, ats="other", apply_url="https://www.linkedin.com/jobs/1"))
    assert not ad.can_handle(Job(**base, ats="other", apply_url="https://x.com/a", easy_apply=True))
    assert not ad.can_handle(Job(**base, ats="other"))


# ---- fill / submit flows -----------------------------------------------------------------


async def test_fill_review_mode_never_clicks_submit(world):
    log: dict = {}
    script = [*FILL_SCRIPT,
              step("browser_click", {"element": "Submit application", "ref": "e9"}),  # agent tries anyway
              submit_request(),
              step("browser_click", {"element": "Continue", "ref": "e9"})]  # sneaky: ref is the submit button
    ad = adapter_with([script], log)
    ctx = ctx_for(world)  # Workday => Review mode by default (per_ats_mode)
    res = await ad.fill(ctx)

    assert res.ok and res.unresolved == [] and res.screenshot_path.endswith("prefill.png")
    client = log["clients"][0]
    clicks = [(t, e) for n, t, e in client.results if n.endswith("browser_click")]
    assert all(err for _, err in clicks) and "request_submit" in clicks[0][0]
    req = next(t for n, t, _ in client.results if n.endswith("request_submit"))
    assert "review" in req.lower() and "do not click submit" in req.lower()
    assert not ad.last_toolbox.gate.submit_clicked
    assert ctx.extra["agentic"] == {"mode": "review", "submit_ready": True, "session_open": False}
    assert log["disconnects"] == 1 and ad._live == {}

    # Q&A audit recorded with provenance
    rows = {r.question: r for r in db.list_application_answers(world["conn"], world["app"].id)}
    assert rows["First name"].origin is AnswerOrigin.PROFILE
    assert rows["Will you require sponsorship?"].origin is AnswerOrigin.NEVER_GUESS
    assert rows["Why do you want to work at Stripe?"].origin is AnswerOrigin.GENERATED
    assert rows["Why do you want to work at Stripe?"].confidence == 0.9
    app = db.get_application(world["conn"], world["app"].id)
    assert app.screenshot_path == res.screenshot_path
    # tokens: SDK session (1000+50 in, 200 out) + generation via the LLM provider
    assert app.tokens_in >= 1050 and app.tokens_out >= 200
    assert app.state is AppState.FILLING  # adapters never write state
    steps = world["emit"].of("agent_step")
    assert steps[0].index == 0 and steps[0].action.startswith("opening") and len(steps) == len(script)


async def test_request_submit_blocked_by_guardrails(world):
    log: dict = {}
    bad = step("request_submit", {"answers": [
        {"question": "First name", "answer": "Ada"},
        {"question": "Will you require sponsorship?", "answer": "Yes"},  # contradicts never_guess
        {"question": "What is your notice period?", "answer": "2 weeks"},  # never looked up
        {"question": "Favourite colour", "answer": "Blue"},  # invented
    ], "screenshot": "prefill.png"})
    ad = adapter_with([[*FILL_SCRIPT, bad]], log)
    res = await ad.fill(ctx_for(world))
    assert not res.ok and "guardrails" in res.error
    text = log["clients"][0].results[-1][1]
    assert "entered 'Yes' but lookup_answer returned 'No'" in text
    assert "notice period" in text and "sensitive" in text
    assert "Favourite colour" in text
    assert db.list_application_answers(world["conn"], world["app"].id) == []


async def test_request_submit_requires_screenshot(world):
    log: dict = {}
    script = [s for s in FILL_SCRIPT if not s[0].endswith("browser_take_screenshot")] + [submit_request()]
    res = await adapter_with([script], log).fill(ctx_for(world))
    assert not res.ok and "screenshot" in res.error


async def test_low_confidence_generation_parks(world):
    world["llm"] = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("meh", 0.4))])
    log: dict = {}
    script = [*FILL_SCRIPT, submit_request()]
    res = await adapter_with([script], log).fill(ctx_for(world))
    assert not res.ok and res.error is None
    (uf,) = res.unresolved
    assert uf.reason == "low_confidence" and uf.suggested_answer == "meh"
    assert "waiting on the user" in log["clients"][0].results[-1][1]


async def test_ask_user_parks_job(world):
    log: dict = {}
    script = [FILL_SCRIPT[0], step("ask_user", {"question": "Do you have a valid driver's license?", "field_type": "select", "options": ["Yes", "No"]})]
    res = await adapter_with([script], log).fill(ctx_for(world))
    assert not res.ok and [u.question.label for u in res.unresolved] == ["Do you have a valid driver's license?"]
    assert res.unresolved[0].question.options == ["Yes", "No"]


async def test_captcha_in_page_parks_and_interrupts(world):
    log: dict = {}
    script = [step("browser_navigate", {"url": "https://stripe.wd1.myworkdayjobs.com/apply/1"},
                   '- iframe "reCAPTCHA" [ref=e7]:\n  - checkbox "I\'m not a robot" [ref=e8]'),
              step("browser_snapshot", {})]
    res = await adapter_with([script], log).fill(ctx_for(world))
    assert not res.ok and res.unresolved[0].reason == "captcha"
    client = log["clients"][0]
    assert client.interrupted and len(client.results) == 1


async def test_agent_reported_captcha(world):
    log: dict = {}
    res = await adapter_with([[step("report_captcha", {"detail": "hCaptcha"})]], log).fill(ctx_for(world))
    assert res.unresolved[0].reason == "captcha"


async def test_auto_mode_keeps_session_and_submit_clicks_once(world):
    conn = world["conn"]
    db.update_preferences(conn, {"per_ats_mode": {}})  # Workday inherits global Auto
    log: dict = {}
    fill_script = [*FILL_SCRIPT, submit_request()]
    submit_script = [
        submit_request(),
        step("browser_click", {"element": "Submit application", "ref": "e9"}, "Thank you for applying!"),
        step("browser_click", {"element": "Submit application", "ref": "e9"}),  # second click must be denied
        step("browser_take_screenshot", {"filename": "confirmation.png"}),
        step("report_submission_result", {"confirmed": True, "evidence": "Thank you for applying!"}),
    ]
    ad = adapter_with([fill_script, submit_script], log)
    ctx = ctx_for(world)
    res = await ad.fill(ctx)
    assert res.ok and ctx.extra["agentic"]["session_open"] and world["app"].id in ad._live
    req = next(t for n, t, _ in log["clients"][0].results if n.endswith("request_submit"))
    assert "Approved" in req and "Do NOT click submit" in req

    # pipeline: guardrails -> begin_submit -> adapter.submit
    db.begin_submit(conn, world["app"].id)
    sub = await ad.submit(ctx_for(world))
    assert sub.verified and sub.confirmation_screenshot_path.endswith("confirmation.png")
    client = log["clients"][0]  # same live session reused
    assert len(log["clients"]) == 1
    clicks = [(t, e) for n, t, e in client.results if n.endswith("browser_click")]
    assert clicks[-2] == ("Thank you for applying!", False) and clicks[-1][1] is True
    assert ad._live == {} and not client.connected


async def test_submit_refused_unless_submitting(world):
    log: dict = {}
    ad = adapter_with([], log)
    res = await ad.submit(ctx_for(world))  # state is filling: begin_submit not called
    assert not res.verified and res.error.startswith("not_submitted")
    assert log == {}  # no agent session started


async def test_submit_fresh_session_after_review_approval(world):
    conn = world["conn"]
    log: dict = {}
    ad = adapter_with([[*FILL_SCRIPT, submit_request()], [
        step("lookup_answer", {"question": "Will you require sponsorship?", "options": ["Yes", "No"]}),
        step("browser_take_screenshot", {"fullPage": True, "filename": "prefill.png"}),
        submit_request(),
        step("browser_click", {"element": "Submit application", "ref": "e9"}, "Application received"),
        step("report_submission_result", {"confirmed": True, "evidence": "Application received"}),
    ]], log)
    assert (await ad.fill(ctx_for(world))).ok  # review mode: session closed
    db.transition(conn, world["app"].id, AppState.AWAITING_REVIEW)
    # the user edits an answer in Review; the refill must use the edited value
    why = next(r for r in db.list_application_answers(conn, world["app"].id) if r.question.startswith("Why"))
    db.edit_application_answer(conn, why.id, "Edited by me.")
    db.begin_submit(conn, world["app"].id, actor="user")
    log["clients"].clear()
    res = await ad.submit(ctx_for(world))
    # agent re-sent the stale generated answer -> blocked: the approved (edited) answer is authoritative
    assert not res.verified and "not_submitted" in res.error
    refusal = log["clients"][0].results[2][1]
    assert "Edited by me." in refusal or "lookup_answer returned" in refusal


async def test_submit_click_without_confirmation_is_unverified(world):
    conn = world["conn"]
    db.update_preferences(conn, {"per_ats_mode": {}})
    log: dict = {}
    ad = adapter_with([[*FILL_SCRIPT, submit_request()], [
        submit_request(),
        step("browser_click", {"element": "Submit application", "ref": "e9"}, "Spinner..."),
        step("report_submission_result", {"confirmed": False, "evidence": "page hung"}),
    ]], log)
    assert (await ad.fill(ctx_for(world))).ok
    db.begin_submit(conn, world["app"].id)
    res = await ad.submit(ctx_for(world))
    assert not res.verified and res.error == "unverified: page hung"  # pipeline -> unknown_verify


async def test_pause_interrupts_session(world):
    log: dict = {}
    flag = {"paused": False}

    class PausingClient(FakeClient):
        async def receive_response(self):
            async for m in super().receive_response():
                flag["paused"] = True
                yield m

    ad = AgenticAdapter(client_factory=lambda o, t: PausingClient(o, t, [FILL_SCRIPT], log))
    with pytest.raises(PausedError):
        await ad.fill(ctx_for(world, is_paused=lambda: flag["paused"]))
    assert log["clients"][0].interrupted and not log["clients"][0].connected


async def test_harvest_questions(world):
    log: dict = {}
    script = [step("browser_navigate", {"url": "https://stripe.wd1.myworkdayjobs.com/apply/1"}, SNAPSHOT),
              step("browser_type", {"element": "First name", "ref": "e2", "text": "Ada"}),  # denied: read-only
              step("report_form_questions", {"questions": [
                  {"label": "First name", "field_type": "text", "required": True},
                  {"label": "Will you require sponsorship?", "field_type": "select", "options": ["Yes", "No"]},
                  {"label": "", "field_type": "text"},
                  {"label": "Weird", "field_type": "nonsense"},
              ]})]
    qs = await adapter_with([script], log).harvest_questions(ctx_for(world))
    assert log["clients"][0].results[1][2] is True  # typing refused while harvesting
    assert [q.label for q in qs] == ["First name", "Will you require sponsorship?", "Weird"]
    assert qs[1].options == ["Yes", "No"] and qs[0].required
    assert "LIST QUESTIONS ONLY" in log["prompts"][0]


async def test_harvest_without_report_raises(world):
    with pytest.raises(RuntimeError):
        await adapter_with([[step("browser_snapshot", {})]], {}).harvest_questions(ctx_for(world))


async def test_write_cover_letter_tool(world, tmp_path):
    conn = world["conn"]
    letter = ("Dear Stripe hiring team,\n\nAt Acme Pay I cut payment latency by 40% using Go.\n\nAda Lovelace")
    world["llm"] = FakeLLMProvider(rules=[("COVER LETTER", {"text": letter, "story_ids": []})])
    ctx = ctx_for(world)
    tb = AgentToolbox(ctx, ToolGate(), phase="fill", output_dir=tmp_path, mode=Mode.REVIEW, cover_letters_dir=tmp_path / "cl")
    out = await tb.write_cover_letter({})
    assert not out.get("is_error")
    path = db.get_application(conn, world["app"].id).cover_letter_path
    assert path and Path(path).read_text().startswith("Dear Stripe")
    assert str(Path(path).resolve()) in tb.gate.allowed_upload_paths

    world["llm"] = FakeLLMProvider(default={"text": "At Google I led 300 people.", "story_ids": []})
    db.update_application(conn, world["app"].id, cover_letter_path=None)
    tb2 = AgentToolbox(ctx_for(world), ToolGate(), phase="fill", output_dir=tmp_path, mode=Mode.REVIEW, cover_letters_dir=tmp_path / "cl2")
    bad = await tb2.write_cover_letter({})
    assert bad.get("is_error") and "supported" in bad["content"][0]["text"]
