"""LLM access behind one small abstraction (PLAN.md decision #2).

* :class:`LLMProvider` — the protocol every caller uses: ``await llm.complete(prompt,
  system=..., schema=...)`` -> :class:`LLMResult` (text, parsed JSON, token usage).
* :class:`AgentSDKProvider` — default; uses ``claude-agent-sdk`` and the machine's existing
  ``claude`` CLI login. NEVER instantiate/call it in tests (it spends the subscription).
* :class:`AnthropicAPIProvider` — placeholder for the API-key swap (not implemented).
* :class:`FakeLLMProvider` — deterministic scripted provider for tests.

Every provider accumulates usage in ``provider.usage`` (:class:`TokenUsage`) so the
daemon can attribute tokens to runs/applications (``usage.snapshot()`` before/after).
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

import jsonschema


class LLMError(Exception):
    """Provider failure (transport, auth, refusal, unparsable structured output)."""


class LLMSchemaError(LLMError):
    """The model's output did not match the requested JSON schema."""


@dataclass(slots=True)
class TokenUsage:
    input_tokens: int = 0
    output_tokens: int = 0
    calls: int = 0
    cost_usd: float = 0.0

    def add(self, other: "TokenUsage") -> None:
        self.input_tokens += other.input_tokens
        self.output_tokens += other.output_tokens
        self.calls += other.calls
        self.cost_usd += other.cost_usd

    def snapshot(self) -> "TokenUsage":
        return TokenUsage(self.input_tokens, self.output_tokens, self.calls, self.cost_usd)

    def since(self, earlier: "TokenUsage") -> "TokenUsage":
        """Usage accumulated after ``earlier`` (a previous :meth:`snapshot`)."""
        return TokenUsage(
            self.input_tokens - earlier.input_tokens,
            self.output_tokens - earlier.output_tokens,
            self.calls - earlier.calls,
            self.cost_usd - earlier.cost_usd,
        )

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens


#: Model routing. Callers pass ``tier="fast"`` for cheap extraction/classification and leave it
#: unset (smart) for judgment and writing. Aliases track the newest model of each family;
#: override with ``AUTOAPPLY_FAST_MODEL`` / ``AUTOAPPLY_SMART_MODEL``.
FAST_TIER = "fast"
SMART_TIER = "smart"


def model_for_tier(tier: str | None) -> str:
    import os

    if tier == FAST_TIER:
        return os.environ.get("AUTOAPPLY_FAST_MODEL", "haiku")
    return os.environ.get("AUTOAPPLY_SMART_MODEL", "sonnet")


@dataclass(slots=True)
class LLMResult:
    text: str
    data: Any = None  # parsed + validated JSON when a schema was requested
    usage: TokenUsage = field(default_factory=TokenUsage)
    model: str | None = None


@runtime_checkable
class LLMProvider(Protocol):
    """Minimal completion interface used by scoring, answers, cover letters, prep."""

    name: str
    usage: TokenUsage

    async def complete(
        self,
        prompt: str,
        *,
        system: str | None = None,
        schema: dict[str, Any] | None = None,
        max_tokens: int | None = None,
        tier: str | None = None,
    ) -> LLMResult:
        """Single-turn completion.

        If ``schema`` (a JSON Schema object) is given the provider must return JSON that
        validates against it in ``LLMResult.data`` (raising :class:`LLMSchemaError`
        otherwise); ``text`` holds the raw output either way.
        """
        ...


# -------------------------------------------------------------------------------------
# helpers
# -------------------------------------------------------------------------------------

_FENCE = re.compile(r"^```(?:json)?\s*(.*?)\s*```$", re.S)


def extract_json(text: str) -> Any:
    """Parse JSON from model text: raw JSON, a ```json fence, or the first {...}/[...] span."""
    s = text.strip()
    m = _FENCE.match(s)
    if m:
        s = m.group(1)
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        pass
    for open_c, close_c in (("{", "}"), ("[", "]")):
        start, end = s.find(open_c), s.rfind(close_c)
        if start != -1 and end > start:
            try:
                return json.loads(s[start : end + 1])
            except json.JSONDecodeError:
                continue
    raise LLMSchemaError(f"no JSON found in model output: {text[:200]!r}")


def validate_json(data: Any, schema: dict[str, Any]) -> Any:
    try:
        jsonschema.validate(data, schema)
    except jsonschema.ValidationError as e:
        raise LLMSchemaError(f"output does not match schema: {e.message}") from e
    return data


def schema_instruction(schema: dict[str, Any]) -> str:
    return (
        "Respond with ONLY a single JSON value (no prose, no code fences) that validates "
        "against this JSON Schema:\n" + json.dumps(schema, separators=(",", ":"))
    )


def estimate_tokens(text: str) -> int:
    """Cheap token estimate (~4 chars/token) used by the fake provider."""
    return max(1, (len(text) + 3) // 4) if text else 0


# -------------------------------------------------------------------------------------
# FakeLLMProvider (tests)
# -------------------------------------------------------------------------------------

Responder = Callable[[str, str | None, dict[str, Any] | None], Any]


@dataclass(slots=True)
class FakeCall:
    prompt: str
    system: str | None
    schema: dict[str, Any] | None
    max_tokens: int | None


class FakeLLMProvider:
    """Scripted provider. Responses are resolved in this order:

    1. ``rules``: list of ``(pattern, response)``; first regex that matches the prompt wins
       (searched case-insensitively; patterns may be reused).
    2. ``responses``: a queue consumed one per call.
    3. ``default`` (if set), else :class:`LLMError`.

    A response may be a ``str`` (returned as text), a ``dict``/``list`` (JSON-encoded; becomes
    ``data`` when a schema is requested), a callable ``(prompt, system, schema) -> response``,
    or an ``Exception`` instance (raised). Structured responses are validated against the
    requested schema exactly like a real provider.
    """

    name = "fake"

    def __init__(
        self,
        responses: Sequence[Any] | None = None,
        *,
        rules: Sequence[tuple[str, Any]] | None = None,
        default: Any = None,
        model: str = "fake-model",
    ) -> None:
        self.responses: list[Any] = list(responses or [])
        self.rules: list[tuple[re.Pattern[str], Any]] = [(re.compile(p, re.I), r) for p, r in (rules or [])]
        self.default = default
        self.model = model
        self.usage = TokenUsage()
        self.calls: list[FakeCall] = []
        self.tiers: list[str | None] = []

    def queue(self, *responses: Any) -> None:
        self.responses.extend(responses)

    def add_rule(self, pattern: str, response: Any) -> None:
        self.rules.append((re.compile(pattern, re.I), response))

    def _pick(self, prompt: str) -> Any:
        for pat, resp in self.rules:
            if pat.search(prompt):
                return resp
        if self.responses:
            return self.responses.pop(0)
        if self.default is not None:
            return self.default
        raise LLMError(f"FakeLLMProvider has no response for prompt: {prompt[:120]!r}")

    async def complete(
        self,
        prompt: str,
        *,
        system: str | None = None,
        schema: dict[str, Any] | None = None,
        max_tokens: int | None = None,
        tier: str | None = None,
    ) -> LLMResult:
        self.calls.append(FakeCall(prompt, system, schema, max_tokens))
        self.tiers.append(tier)
        resp = self._pick(prompt)
        if callable(resp) and not isinstance(resp, type):
            resp = resp(prompt, system, schema)
        if isinstance(resp, BaseException):
            raise resp
        text = resp if isinstance(resp, str) else json.dumps(resp)
        usage = TokenUsage(
            input_tokens=estimate_tokens(prompt) + estimate_tokens(system or ""),
            output_tokens=estimate_tokens(text),
            calls=1,
        )
        self.usage.add(usage)
        data = None
        if schema is not None:
            data = validate_json(resp if not isinstance(resp, str) else extract_json(resp), schema)
        return LLMResult(text=text, data=data, usage=usage, model=self.model)


# -------------------------------------------------------------------------------------
# AgentSDKProvider (default, real) — never used in tests
# -------------------------------------------------------------------------------------


class AgentSDKProvider:
    """Completion via ``claude-agent-sdk`` using the local ``claude`` CLI login.

    Runs a short query with all user tools disabled (structured output is delivered via an
    internal tool call, so it needs more than one turn). When ``schema`` is given it asks for
    structured output (``output_format``) and also instructs the model in the system
    prompt, then validates locally.
    """

    name = "agent_sdk"

    def __init__(
        self,
        *,
        model: str | None = None,
        cwd: str | None = None,
        max_turns: int = 4,
        cli_path: str | None = None,
    ) -> None:
        self.model = model
        self.cwd = cwd
        self.max_turns = max_turns
        self.cli_path = cli_path
        self.usage = TokenUsage()

    def _options(self, system: str | None, schema: dict[str, Any] | None, tier: str | None = None) -> Any:
        from claude_agent_sdk import ClaudeAgentOptions

        sys_prompt = system or "You are a precise assistant."
        if schema is not None:
            sys_prompt = f"{sys_prompt}\n\n{schema_instruction(schema)}"
        kwargs: dict[str, Any] = {
            "system_prompt": sys_prompt,
            "max_turns": self.max_turns,
            "allowed_tools": [],
            "tools": [],
            "setting_sources": [],  # don't load user/project CLAUDE.md or settings
        }
        kwargs["model"] = self.model or model_for_tier(tier)
        if self.cwd:
            kwargs["cwd"] = self.cwd
        if self.cli_path:
            kwargs["cli_path"] = self.cli_path
        if schema is not None:
            kwargs["output_format"] = {"type": "json_schema", "schema": schema}
        return ClaudeAgentOptions(**kwargs)

    @staticmethod
    def _usage_from(result_usage: dict[str, Any] | None, cost: float | None) -> TokenUsage:
        u = result_usage or {}
        input_tokens = int(u.get("input_tokens") or 0) + int(u.get("cache_read_input_tokens") or 0) + int(
            u.get("cache_creation_input_tokens") or 0
        )
        return TokenUsage(
            input_tokens=input_tokens,
            output_tokens=int(u.get("output_tokens") or 0),
            calls=1,
            cost_usd=float(cost or 0.0),
        )

    async def complete(
        self,
        prompt: str,
        *,
        system: str | None = None,
        schema: dict[str, Any] | None = None,
        max_tokens: int | None = None,  # noqa: ARG002 - the CLI manages output length
        tier: str | None = None,
    ) -> LLMResult:
        try:
            from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock, query
        except ImportError as e:  # pragma: no cover
            raise LLMError("claude-agent-sdk is not installed") from e

        texts: list[str] = []
        structured: Any = None
        usage = TokenUsage(calls=1)
        model: str | None = self.model
        error: str | None = None
        try:
            async for msg in query(prompt=prompt, options=self._options(system, schema, tier)):
                if isinstance(msg, AssistantMessage):
                    model = msg.model or model
                    texts.extend(b.text for b in msg.content if isinstance(b, TextBlock))
                elif isinstance(msg, ResultMessage):
                    usage = self._usage_from(msg.usage, msg.total_cost_usd)
                    if msg.is_error:
                        # Don't raise inside the async-for: it closes the SDK generator
                        # mid-iteration ("aclose(): asynchronous generator is already running").
                        error = f"agent SDK returned an error result: {msg.result or msg.subtype}"
                        continue
                    structured = msg.structured_output
                    if not texts and msg.result:
                        texts.append(msg.result)
        except LLMError:
            raise
        except Exception as e:  # transport / CLI errors
            raise LLMError(f"agent SDK query failed: {e}") from e

        self.usage.add(usage)
        if error is not None:
            raise LLMError(error)
        text = "".join(texts).strip()
        data = None
        if schema is not None:
            data = validate_json(structured if structured is not None else extract_json(text), schema)
        return LLMResult(text=text, data=data, usage=usage, model=model)


# -------------------------------------------------------------------------------------
# AnthropicAPIProvider (placeholder for the API-key swap)
# -------------------------------------------------------------------------------------


class AnthropicAPIProvider:
    """Placeholder: direct Messages API with an API key. Not implemented yet (PLAN #2)."""

    name = "anthropic_api"

    def __init__(self, *, api_key: str, model: str = "claude-sonnet-4-5") -> None:
        if not api_key:
            raise ValueError("api_key is required")
        self.api_key = api_key
        self.model = model
        self.usage = TokenUsage()

    async def complete(
        self,
        prompt: str,
        *,
        system: str | None = None,
        schema: dict[str, Any] | None = None,
        max_tokens: int | None = None,
        tier: str | None = None,
    ) -> LLMResult:
        raise NotImplementedError("AnthropicAPIProvider is a placeholder; use AgentSDKProvider")


def get_provider(name: str = "agent_sdk", **kwargs: Any) -> LLMProvider:
    """Factory used by the daemon/CLI (setting: ``llm_provider``)."""
    if name == "agent_sdk":
        return AgentSDKProvider(**kwargs)
    if name == "anthropic_api":
        return AnthropicAPIProvider(**kwargs)
    if name == "fake":
        return FakeLLMProvider(**kwargs)
    raise ValueError(f"unknown LLM provider {name!r}")
