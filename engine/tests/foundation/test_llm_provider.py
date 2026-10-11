from __future__ import annotations

import pytest

from autoapply.llm.provider import (
    AgentSDKProvider,
    AnthropicAPIProvider,
    FakeLLMProvider,
    LLMError,
    LLMProvider,
    LLMSchemaError,
    TokenUsage,
    extract_json,
    get_provider,
)

SCORE_SCHEMA = {
    "type": "object",
    "properties": {"score": {"type": "integer", "minimum": 0, "maximum": 100}, "summary": {"type": "string"}},
    "required": ["score"],
    "additionalProperties": False,
}


async def test_fake_queue_text_and_usage():
    llm = FakeLLMProvider(["hello there"])
    assert isinstance(llm, LLMProvider)
    r = await llm.complete("say hi", system="be brief")
    assert r.text == "hello there" and r.data is None and r.model == "fake-model"
    assert r.usage.calls == 1 and r.usage.input_tokens > 0 and r.usage.output_tokens > 0
    assert llm.usage.total_tokens == r.usage.total_tokens
    assert llm.calls[0].prompt == "say hi" and llm.calls[0].system == "be brief"
    with pytest.raises(LLMError):
        await llm.complete("nothing left")


async def test_fake_rules_take_precedence_and_schema_validates():
    llm = FakeLLMProvider(rules=[(r"score this job", {"score": 88, "summary": "good"})], default="fallback")
    r = await llm.complete("Please SCORE THIS JOB: Stripe", schema=SCORE_SCHEMA)
    assert r.data == {"score": 88, "summary": "good"}
    r2 = await llm.complete("other")
    assert r2.text == "fallback"
    assert llm.usage.calls == 2


async def test_fake_schema_violation_raises():
    llm = FakeLLMProvider([{"score": 500}, '```json\n{"score": 5}\n```', "no json at all"])
    with pytest.raises(LLMSchemaError):
        await llm.complete("x", schema=SCORE_SCHEMA)
    assert (await llm.complete("x", schema=SCORE_SCHEMA)).data == {"score": 5}
    with pytest.raises(LLMSchemaError):
        await llm.complete("x", schema=SCORE_SCHEMA)


async def test_fake_callable_and_exception_responses():
    llm = FakeLLMProvider([lambda p, s, sch: f"echo:{p}", RuntimeError("boom")])
    assert (await llm.complete("abc")).text == "echo:abc"
    with pytest.raises(RuntimeError):
        await llm.complete("x")
    llm.queue("later")
    llm.add_rule("^special", "rule hit")
    assert (await llm.complete("special case")).text == "rule hit"
    assert (await llm.complete("q")).text == "later"


def test_extract_json_variants():
    assert extract_json('{"a": 1}') == {"a": 1}
    assert extract_json('```json\n[1, 2]\n```') == [1, 2]
    assert extract_json('Sure! Here it is: {"a": {"b": 2}} hope that helps') == {"a": {"b": 2}}
    with pytest.raises(LLMSchemaError):
        extract_json("nothing")


def test_token_usage_since():
    u = TokenUsage(10, 5, 1)
    snap = u.snapshot()
    u.add(TokenUsage(3, 2, 1, 0.01))
    d = u.since(snap)
    assert (d.input_tokens, d.output_tokens, d.calls) == (3, 2, 1)


def test_agent_sdk_provider_builds_options_without_calling_cli():
    """Constructs SDK options only — never runs a query (that would use the subscription)."""
    p = AgentSDKProvider(model="claude-sonnet-4-5")
    assert isinstance(p, LLMProvider)
    opts = p._options("You score jobs.", SCORE_SCHEMA)
    assert opts.max_turns == 4 and opts.allowed_tools == [] and opts.model == "claude-sonnet-4-5"
    assert opts.output_format == {"type": "json_schema", "schema": SCORE_SCHEMA}
    assert "JSON Schema" in opts.system_prompt
    u = AgentSDKProvider._usage_from({"input_tokens": 10, "cache_read_input_tokens": 5, "output_tokens": 7}, 0.002)
    assert (u.input_tokens, u.output_tokens, u.cost_usd) == (15, 7, 0.002)


async def test_anthropic_placeholder_and_factory():
    with pytest.raises(ValueError):
        AnthropicAPIProvider(api_key="")
    p = AnthropicAPIProvider(api_key="sk-test")
    with pytest.raises(NotImplementedError):
        await p.complete("x")
    assert isinstance(get_provider("fake", responses=["a"]), FakeLLMProvider)
    assert isinstance(get_provider("agent_sdk"), AgentSDKProvider)
    with pytest.raises(ValueError):
        get_provider("nope")
