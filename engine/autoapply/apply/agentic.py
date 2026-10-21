"""Agentic fallback adapter (Workday / unknown forms): Claude Agent SDK + Playwright MCP.

The agent drives a real browser through ``npx @playwright/mcp`` (persistent Chrome profile
at ``<home>/chrome-profile``; concurrent worker N>1 uses ``chrome-profile-N``, see
:meth:`AgenticAdapter.profile_dir`) and talks to the engine through custom in-process tools:

``get_profile``      contact/links/work history (never the never-guess facts)
``lookup_answer``    :class:`~autoapply.answers.resolver.AnswerResolver` for one question
``ask_user``         park the question in the Needs-You inbox (job -> needs_you)
``pick_resume``      best approved resume variant (file path the agent may upload)
``write_cover_letter`` grounded cover letter (file path the agent may upload)
``report_captcha``   CAPTCHA / bot challenge -> needs_you
``request_submit``   the ONLY route to submission: guardrails (every answer audited) + mode
``report_submission_result`` / ``report_form_questions``  structured outcomes

**The agent can never click submit on its own.** :class:`ToolGate` is installed both as the
SDK ``can_use_tool`` callback and as a ``PreToolUse`` hook. It denies clicks on
submit-like controls (by the agent's element description *and* by the accessible name of
the ``ref`` in the latest page snapshot; "Apply"/"Send"/"Done"/"Complete" count once any
data was entered), Enter / Space key presses unless they directly follow an interaction
with a combobox (Enter) or checkbox/radio (Space) — any Tab resets that — typed newlines
and ``type(submit=true)``, JavaScript evaluation, navigation to LinkedIn/Glassdoor, and uploads of
any file other than the chosen resume / cover letter. A single submit click is armed only
by ``request_submit`` during :meth:`AgenticAdapter.submit`, i.e. after the pipeline has
durably recorded ``submitting`` (``db.begin_submit``) — which ``request_submit`` re-checks.
``request_submit`` also cross-checks every value the gate saw typed/selected against the
audited answers, requires a screenshot taken in the current session, and in the submit
phase only accepts answers that were recorded (and possibly edited) at fill/review time.

CAPTCHAs are detected both by the agent (``report_captcha``) and by scanning every browser
tool result; either parks the job as ``needs_you`` (reason ``captcha``).

Token usage of every session is added to ``applications.tokens_in/out``.

Testing: pass ``client_factory`` — a callable ``(options, toolbox) -> client`` returning an
object with ``connect / query / receive_response / interrupt / disconnect`` (the
``ClaudeSDKClient`` surface). The default factory builds a real ``ClaudeSDKClient``; tests
never use it.
"""

from __future__ import annotations

import json
import logging
import re
import time
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlsplit

from autoapply import db
from autoapply.answers.cover_letter import generate_cover_letter
from autoapply.answers.guardrails import (
    AnswerForCheck,
    NeedsUser,
    check_answers,
    classify_never_guess,
    detect_captcha,
    matches_always_ask,
)
from autoapply.answers.resolver import AnswerResolver, ResolvedAnswer, profile_answer
from autoapply.answers.resume_picker import pick_resume
from autoapply.answers.textnorm import match_option, normalize_question, yes_no
from autoapply.apply.base import ApplyContext, FillResult, HarvestBlocked, PausedError, SubmitResult, UnresolvedField
from autoapply.enums import AnswerOrigin, AppState, Ats, FieldType, Mode, QuestionKind, QuestionReason
from autoapply.llm.provider import AgentSDKProvider, TokenUsage
from autoapply.models import AgentStepPayload, ApplicationAnswer, FormQuestion, Job, choice_field_type, now_ts
from autoapply.paths import get_paths
from autoapply.question_kind import classify as classify_kind
from autoapply.question_kind import ACCOUNT as ACTION_ACCOUNT
from autoapply.question_kind import VERIFICATION as ACTION_VERIFICATION
from autoapply.question_kind import action_type, resolve_kind
from autoapply.workers import current_slot

log = logging.getLogger(__name__)

#: npm package for the Playwright MCP server. Override per adapter (``playwright_mcp_package``).
PLAYWRIGHT_MCP_PACKAGE = "@playwright/mcp@latest"
TOOL_SERVER = "autoapply"
BROWSER_SERVER = "playwright"


def tool_id(name: str) -> str:
    return f"mcp__{TOOL_SERVER}__{name}"


def browser_id(name: str) -> str:
    return f"mcp__{BROWSER_SERVER}__{name}"


#: Read-only / harmless browser tools: auto-approved (still pass through the hook).
SAFE_BROWSER_TOOLS = ("browser_snapshot", "browser_take_screenshot", "browser_wait_for", "browser_tabs", "browser_navigate_back", "browser_hover")
#: Browser tools that act on the page: every call is checked by the gate.
GATED_BROWSER_TOOLS = (
    "browser_navigate", "browser_click", "browser_type", "browser_fill_form", "browser_select_option",
    "browser_file_upload", "browser_press_key", "browser_handle_dialog",
)
#: Never available (arbitrary JS could submit the form; installs / network dumps are noise).
FORBIDDEN_BROWSER_TOOLS = (
    "browser_evaluate", "browser_run_code", "browser_install", "browser_network_requests", "browser_console_messages",
    "browser_resize", "browser_drag", "browser_pdf_save", "browser_mouse_click_xy", "browser_mouse_drag_xy", "browser_mouse_move_xy",
)
OWN_TOOLS = (
    "get_profile", "lookup_answer", "ask_user", "pick_resume", "write_cover_letter", "report_captcha",
    "request_submit", "report_submission_result", "report_form_questions",
    "start_account", "check_email", "finish_account",
)
#: Fields the account step may fill (sign-up / sign-in / reset forms): nothing from the application.
ACCOUNT_FIELD_RX = re.compile(
    r"e-?mail|user ?name|user ?id|login|password|passcode|pass word|confirm|first name|last name|given name|family name"
    r"|surname|full name|\bname\b|phone|mobile|country|code|otp|pin\b",
    re.I,
)

#: Controls whose activation submits an application.
SUBMIT_CONTROL_RX = re.compile(
    r"\bsubmit\b|\bsend (my |your )?application\b|\bcomplete (my |your )?application\b|\bfinish( application)?\b"
    r"|\bconfirm (and )?(apply|submit)\b|\breview (and|&) submit\b|\bapply now\b.*\bsubmit\b",
    re.I,
)
#: Labels that are the final submit button on many career sites ("Apply", "Send", "Done",
#: "Complete"). Treated as submit controls once any data has been entered (before that,
#: "Apply" is how the agent opens the form).
WEAK_SUBMIT_CONTROL_RX = re.compile(r"\b(apply|applying|send|done|complete|completed|finish|finished|confirm)\b", re.I)
_CLICKABLE_ROLES = {"button", "link", "menuitem"}
BLOCKED_HOSTS = ("linkedin.com", "glassdoor.com", "glassdoor.co.uk", "glassdoor.co.in", "glassdoor.ca")
_ENTER_OK_ROLES = {"combobox", "searchbox", "listbox", "option", "menuitem", "spinbutton"}
_SPACE_OK_ROLES = {"checkbox", "radio", "switch"}
_ENTER_KEYS = {"enter", "numpadenter", "return"}
_SPACE_KEYS = {"space", "spacebar", " "}
#: keys that keep focus on the current widget (arrowing through a combobox's options)
_FOCUS_KEEPING_KEYS = {"arrowup", "arrowdown", "arrowleft", "arrowright", "home", "end", "pageup", "pagedown", "escape", "backspace", "delete"}


@dataclass(slots=True)
class EnteredValue:
    """A value the agent put into the page (recorded by the gate, audited by request_submit)."""

    label: str
    value: str
    kind: str  # type | fill | select
    role: str = ""
_REF_RX = re.compile(r'-\s*([a-z]+)\s+"([^"]*)"[^\n]*?\[ref=([A-Za-z0-9_\-]+)\]')


# =====================================================================================
# harvest fallback: questions read straight from a page snapshot (accessibility tree)
# =====================================================================================

#: snapshot roles that are form inputs (a page showing any of these may be the form)
_FORM_FIELD_ROLES = {"textbox", "combobox", "listbox", "checkbox", "radiogroup", "radio", "spinbutton"}
_SNAP_LINE_RX = re.compile(r'^(\s*)-\s*([a-z]+)(?:\s+"((?:[^"\\]|\\.)*)")?')
_SNAP_SKIP_RX = re.compile(r"\bsearch\b|\bnewsletter\b|\bsubscribe\b|\bcookie|\bkeyword|\bjob alert", re.I)
_SNAP_UPLOAD_RX = re.compile(r"\b(resume|cv|cover letter)\b", re.I)
_SNAP_REQUIRED_RX = re.compile(r"\s*(\*|\(required\))\s*", re.I)
#: fewer fields than this is a search box / newsletter signup, not an application form
MIN_SNAPSHOT_FIELDS = 2


def _snap_field_type(role: str, label: str) -> FieldType:
    if role in {"combobox", "listbox", "radiogroup"}:
        return FieldType.SELECT
    if role == "checkbox":
        return FieldType.BOOLEAN
    if role == "spinbutton":
        return FieldType.NUMBER
    low = label.lower()
    if re.search(r"\be-?mail\b", low):
        return FieldType.EMAIL
    if re.search(r"\b(phone|mobile|telephone)\b", low):
        return FieldType.PHONE
    if re.search(r"\b(linkedin|github|website|portfolio|url)\b", low):
        return FieldType.URL
    return FieldType.TEXT


def questions_from_snapshot(text: str) -> list[FormQuestion]:
    """Best-effort form questions from a Playwright MCP snapshot (used when the agent did not
    call report_form_questions). Labels come from the inputs' accessible names; options from
    the ``option`` / ``radio`` children of a combobox / listbox / radiogroup. Returns [] when
    the page does not look like an application form."""
    out: list[FormQuestion] = []
    seen: set[str] = set()
    container: tuple[int, FormQuestion] | None = None  # (indent, question collecting options)
    for line in (text or "").splitlines():
        m = _SNAP_LINE_RX.match(line)
        if not m:
            continue
        indent, role, raw_name = len(m.group(1)), m.group(2), (m.group(3) or "").replace('\\"', '"')
        if container is not None and indent <= container[0]:
            container = None
        if container is not None and role in {"option", "radio"}:
            name = raw_name.strip()
            if name and not re.fullmatch(r"(select|choose|please select)\b.*|-+", name, re.I) and name not in container[1].options:
                container[1].options.append(name)
            continue
        if role not in _FORM_FIELD_ROLES - {"radio"} and not (role == "button" and _SNAP_UPLOAD_RX.search(raw_name)):
            continue
        required = bool(_SNAP_REQUIRED_RX.search(raw_name))
        label = _SNAP_REQUIRED_RX.sub(" ", raw_name).strip(" :")
        if not label or _SNAP_SKIP_RX.search(label):
            continue
        if role == "button":  # "Upload resume" / "Attach CV" -> the file field
            ftype, label = FieldType.FILE, ("Cover letter" if re.search(r"cover letter", label, re.I) else "Resume")
        else:
            ftype = _snap_field_type(role, label)
        norm = normalize_question(label)
        if not norm or norm in seen:
            continue
        seen.add(norm)
        q = FormQuestion(key=f"snap{len(out)}", label=label, field_type=ftype, required=required)
        out.append(q)
        if role in {"combobox", "listbox", "radiogroup"}:
            container = (indent, q)
    return out if len(out) >= MIN_SNAPSHOT_FIELDS else []


# =====================================================================================
# client seam
# =====================================================================================


class AgentClient(Protocol):
    async def connect(self, prompt: Any = None) -> None: ...
    async def query(self, prompt: str, session_id: str = "default") -> None: ...
    def receive_response(self) -> AsyncIterator[Any]: ...
    async def interrupt(self) -> None: ...
    async def disconnect(self) -> None: ...


ClientFactory = Callable[[Any, "AgentToolbox"], AgentClient]


def default_client_factory(options: Any, toolbox: AgentToolbox) -> AgentClient:  # pragma: no cover - real SDK
    from claude_agent_sdk import ClaudeSDKClient

    return ClaudeSDKClient(options=options)


# =====================================================================================
# the gate
# =====================================================================================


@dataclass(slots=True)
class GateDecision:
    allowed: bool
    message: str = ""


@dataclass
class ToolGate:
    """Permission policy for every tool call the agent makes."""

    allowed_upload_paths: set[str] = field(default_factory=set)
    submit_armed: bool = False
    submit_clicks_left: int = 0
    submit_clicked: bool = False
    refs: dict[str, tuple[str, str]] = field(default_factory=dict)  # ref -> (role, name)
    #: role of the element that currently has focus as far as the gate knows (None once a
    #: key press may have moved focus, e.g. Tab)
    last_ref_role: str | None = None
    #: kind of the last allowed page interaction: click | type | nav_key | key
    last_action: str | None = None
    #: any value typed / selected / uploaded this session (after that, "Apply"/"Send"/
    #: "Done"/"Complete" buttons count as submit controls)
    data_entered: bool = False
    #: every value entered, keyed by ref (or element description); last write wins
    entries: dict[str, EnteredValue] = field(default_factory=dict)
    denials: list[tuple[str, str]] = field(default_factory=list)
    #: harvest phase: no data entry at all (navigation / reading / non-submit clicks only)
    read_only: bool = False
    #: signing up / in / resetting a password (start_account .. finish_account): only account
    #: fields may be typed, nothing is recorded as an application answer, and the account
    #: form's own button ("Submit", "Create account", "Verify") may be clicked
    account_mode: bool = False
    #: the latest page snapshot that contained form fields (harvest fallback)
    last_form_snapshot: str = ""
    _decided: dict[str, GateDecision] = field(default_factory=dict, repr=False)

    # -- observation of page snapshots ------------------------------------------------

    def observe(self, text: str) -> None:
        found = _REF_RX.findall(text or "")
        for role, name, ref in found:
            self.refs[ref] = (role, name)
        if any(role in _FORM_FIELD_ROLES for role, _, _ in found):
            self.last_form_snapshot = text

    def arm_submit(self) -> None:
        self.submit_armed = True
        self.submit_clicks_left = 1

    def disarm(self) -> None:
        self.submit_armed = False
        self.submit_clicks_left = 0

    # -- policy -----------------------------------------------------------------------

    def _is_submit_control(self, inp: dict[str, Any]) -> bool:
        desc = str(inp.get("element") or "")
        ref = str(inp.get("ref") or "")
        role, name = self.refs.get(ref, ("", ""))
        if SUBMIT_CONTROL_RX.search(desc) or (name and SUBMIT_CONTROL_RX.search(name)):
            return True
        if not self.data_entered:
            return False
        if role and role not in _CLICKABLE_ROLES:
            return False  # a radio/checkbox/option labelled "Done" etc. is not a submit button
        return bool(WEAK_SUBMIT_CONTROL_RX.search(desc) or (name and WEAK_SUBMIT_CONTROL_RX.search(name)))

    def _label_of(self, ref: str, desc: str) -> str:
        return self.refs.get(ref, ("", ""))[1] or desc

    def _record_entry(self, ref: str, desc: str, value: str, kind: str, role: str = "") -> None:
        self.data_entered = True
        key = ref or desc or f"#{len(self.entries)}"
        self.entries[key] = EnteredValue(self._label_of(ref, desc), value, kind, role or self.refs.get(ref, ("", ""))[0])

    def check(self, tool_name: str, inp: dict[str, Any] | None, tool_use_id: str | None = None) -> GateDecision:
        """Decide once per tool call. The SDK consults both the PreToolUse hook and
        ``can_use_tool`` for the same call; the second consultation reuses the first
        decision so side effects (consuming the single armed submit click) happen once."""
        key = tool_use_id or f"{tool_name}:{json.dumps(inp or {}, sort_keys=True, default=str)}"
        if key in self._decided:
            return self._decided.pop(key)
        d = self._check(tool_name, inp or {})
        self._decided[key] = d
        if len(self._decided) > 256:  # safe tools are only consulted once; bound the cache
            self._decided.pop(next(iter(self._decided)))
        return d

    def _check(self, tool_name: str, inp: dict[str, Any]) -> GateDecision:
        own = {tool_id(t) for t in OWN_TOOLS}
        if tool_name in own:
            return GateDecision(True)
        if not tool_name.startswith(f"mcp__{BROWSER_SERVER}__"):
            return self._deny(tool_name, "Only the browser tools and the autoapply tools are available.")
        short = tool_name.removeprefix(f"mcp__{BROWSER_SERVER}__")
        if short in FORBIDDEN_BROWSER_TOOLS:
            return self._deny(tool_name, f"{short} is not allowed.")
        if short in SAFE_BROWSER_TOOLS:
            return GateDecision(True)
        if short not in GATED_BROWSER_TOOLS:
            return self._deny(tool_name, f"{short} is not allowed.")
        if self.account_mode:
            account = self._check_account_step(tool_name, short, inp)
            if account is not None:
                return account
        if self.read_only and short in {"browser_type", "browser_fill_form", "browser_select_option", "browser_file_upload", "browser_press_key"}:
            return self._deny(tool_name, "Only list the questions now: do not enter any data.")
        if short == "browser_navigate":
            url = str(inp.get("url") or "")
            parts = urlsplit(url)
            host = (parts.hostname or "").lower()
            if parts.scheme not in {"http", "https"}:
                return self._deny(tool_name, "Only http(s) URLs may be opened.")
            if any(host == h or host.endswith("." + h) for h in BLOCKED_HOSTS):
                return self._deny(tool_name, "LinkedIn/Glassdoor must never be automated.")
            return GateDecision(True)
        if short == "browser_click":
            ref = str(inp.get("ref") or "")
            self.last_ref_role = self.refs.get(ref, ("", ""))[0] or None
            self.last_action = "click"
            if self._is_submit_control(inp):
                if self.submit_armed and self.submit_clicks_left > 0:
                    self.submit_clicks_left -= 1
                    self.submit_clicked = True
                    if self.submit_clicks_left == 0:
                        self.submit_armed = False
                    return GateDecision(True)
                return self._deny(
                    tool_name,
                    "Clicking submit (or a final Apply/Send/Done/Complete button) is not allowed. When every field "
                    "is filled, call request_submit; the system decides whether and when to submit.",
                )
            return GateDecision(True)
        if short == "browser_type":
            ref = str(inp.get("ref") or "")
            desc = str(inp.get("element") or "")
            role = self.refs.get(ref, ("", ""))[0]
            text = str(inp.get("text") or "")
            if inp.get("submit"):
                return self._deny(tool_name, "type(submit=true) could submit the form; type without submit.")
            if inp.get("slowly") and ("\n" in text or "\r" in text):
                # typed key by key, a newline is an Enter press (implicit form submission)
                return self._deny(tool_name, "Typing a newline key by key may submit the form; type without slowly=true.")
            self.last_ref_role = role or None
            self.last_action = "type"
            self._record_entry(ref, desc, text, "type", role)
            return GateDecision(True)
        if short == "browser_press_key":
            return self._check_key(tool_name, str(inp.get("key") or ""))
        if short == "browser_fill_form":
            for f in inp.get("fields") or []:
                if str(f.get("type", "")).lower() in {"button", "submit"} or SUBMIT_CONTROL_RX.search(str(f.get("name", ""))) and str(
                    f.get("type", "")
                ).lower() not in {"textbox", "checkbox", "radio", "combobox", "slider"}:
                    return self._deny(tool_name, "fill_form cannot press buttons.")
            for f in inp.get("fields") or []:
                self._record_entry(str(f.get("ref") or ""), str(f.get("name") or ""), str(f.get("value") or ""), "fill",
                                   str(f.get("type") or "").lower())
            self.last_ref_role = None  # focus is wherever the last field left it
            self.last_action = "type"
            return GateDecision(True)
        if short == "browser_select_option":
            ref = str(inp.get("ref") or "")
            values = [str(v) for v in inp.get("values") or []]
            self._record_entry(ref, str(inp.get("element") or ""), "; ".join(values), "select")
            self.last_ref_role = self.refs.get(ref, ("", ""))[0] or None
            self.last_action = "type"
            return GateDecision(True)
        if short == "browser_file_upload":
            paths = [str(Path(p).expanduser().resolve()) for p in inp.get("paths") or []]
            bad = [p for p in paths if p not in self.allowed_upload_paths]
            if bad:
                return self._deny(tool_name, "Only the resume from pick_resume or the cover letter from write_cover_letter may be uploaded.")
            self.data_entered = self.data_entered or bool(paths)
            return GateDecision(True)
        return GateDecision(True)  # browser_handle_dialog

    def _check_account_step(self, tool_name: str, short: str, inp: dict[str, Any]) -> GateDecision | None:
        """The account step's own policy; None = fall through to the normal rules."""
        def is_account_field(ref: str, desc: str) -> bool:
            return bool(ACCOUNT_FIELD_RX.search(self._label_of(ref, desc)) or ACCOUNT_FIELD_RX.search(desc))

        outside = ("During the account step only fill the sign-up / sign-in fields (email, password, name, phone, "
                   "code). Call finish_account first, then fill the application.")
        if short == "browser_type":
            if inp.get("submit"):
                return self._deny(tool_name, "type(submit=true) is not allowed; click the form's button instead.")
            ref, desc = str(inp.get("ref") or ""), str(inp.get("element") or "")
            if not is_account_field(ref, desc):
                return self._deny(tool_name, outside)
            self.last_ref_role = self.refs.get(ref, ("", ""))[0] or None
            self.last_action = "type"
            return GateDecision(True)  # never recorded: account values are not application answers
        if short == "browser_fill_form":
            if any(not is_account_field(str(f.get("ref") or ""), str(f.get("name") or "")) for f in inp.get("fields") or []):
                return self._deny(tool_name, outside)
            if any(str(f.get("type", "")).lower() in {"button", "submit"} for f in inp.get("fields") or []):
                return self._deny(tool_name, "fill_form cannot press buttons.")
            self.last_ref_role = None
            self.last_action = "type"
            return GateDecision(True)
        if short == "browser_select_option":
            self.last_ref_role = self.refs.get(str(inp.get("ref") or ""), ("", ""))[0] or None
            self.last_action = "type"
            return GateDecision(True)
        if short == "browser_file_upload":
            return self._deny(tool_name, "No uploads during the account step.")
        if short == "browser_click":
            self.last_ref_role = self.refs.get(str(inp.get("ref") or ""), ("", ""))[0] or None
            self.last_action = "click"
            return GateDecision(True)  # the sign-up / sign-in / verify button
        return None

    def _check_key(self, tool_name: str, key: str) -> GateDecision:
        """Keyboard activation can submit a form as surely as a click: Enter only right after
        interacting with a combobox-like widget, Space only on a checkbox/radio just clicked,
        and any focus-moving key (Tab, ...) forgets what has focus."""
        parts = [p.strip().lower() for p in key.split("+")] if key.strip() else [key.lower()]
        base = parts[-1] if parts and parts[-1] else ("space" if key.endswith(" ") or key.endswith("+") else "")
        modifiers = [p for p in parts[:-1] if p]
        role = self.last_ref_role or ""
        if base in _ENTER_KEYS:
            ok = (not modifiers and role in _ENTER_OK_ROLES and self.last_action in {"click", "type", "nav_key"})
            self.last_ref_role = None  # one Enter per widget interaction
            self.last_action = "key"
            if not ok:
                return self._deny(tool_name, "Enter may submit the form; only press Enter right after typing in / clicking a "
                                             "combobox or search field.")
            return GateDecision(True)
        if base in _SPACE_KEYS:
            if modifiers or role not in _SPACE_OK_ROLES or self.last_action != "click":
                self.last_ref_role = None
                self.last_action = "key"
                return self._deny(tool_name, "Space can press the focused button; click checkboxes/radios directly instead.")
            return GateDecision(True)
        if base in _FOCUS_KEEPING_KEYS and not modifiers:
            self.last_action = "nav_key" if self.last_action in {"click", "type", "nav_key"} else "key"
            return GateDecision(True)
        # Tab / Shift+Tab / letters / shortcuts: focus may have moved anywhere
        self.last_ref_role = None
        self.last_action = "key"
        return GateDecision(True)

    def _deny(self, tool_name: str, message: str) -> GateDecision:
        self.denials.append((tool_name, message))
        return GateDecision(False, message)

    # -- SDK adapters -----------------------------------------------------------------

    async def can_use_tool(self, tool_name: str, tool_input: dict[str, Any], context: Any) -> Any:
        from claude_agent_sdk import PermissionResultAllow, PermissionResultDeny

        d = self.check(tool_name, tool_input, getattr(context, "tool_use_id", None))
        return PermissionResultAllow() if d.allowed else PermissionResultDeny(message=d.message)

    async def pre_tool_use_hook(self, input_data: dict[str, Any], tool_use_id: str | None, context: Any) -> dict[str, Any]:
        d = self.check(str(input_data.get("tool_name", "")), input_data.get("tool_input") or {}, tool_use_id)
        if d.allowed:
            return {}
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": d.message,
            }
        }


# =====================================================================================
# the toolbox (custom tools exposed to the agent)
# =====================================================================================


def _ok(data: Any) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": data if isinstance(data, str) else json.dumps(data, ensure_ascii=False)}]}


def _err(message: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": message}], "is_error": True}


def _answers_agree(given: str, expected: str, options: list[str]) -> bool:
    g, e = normalize_question(given), normalize_question(expected)
    if g == e:
        return True
    if options:
        mg, me = match_option(given, options), match_option(expected, options)
        return mg is not None and mg == me
    return bool(g and e and (g in e or e in g) and min(len(g), len(e)) >= 0.8 * max(len(g), len(e)))


_LOOKUP_SCHEMA = {
    "type": "object",
    "properties": {
        "question": {"type": "string", "description": "Exact label of the form field."},
        "field_type": {"type": "string", "enum": [f.value for f in FieldType]},
        "options": {"type": "array", "items": {"type": "string"}},
        "required": {"type": "boolean"},
        "field_key": {"type": "string"},
        "max_length": {"type": "integer"},
    },
    "required": ["question"],
}
_ASK_SCHEMA = {
    "type": "object",
    "properties": {
        "question": {"type": "string"},
        "field_type": {"type": "string", "enum": [f.value for f in FieldType]},
        "options": {"type": "array", "items": {"type": "string"},
                    "description": "Every choice the form offers for this field (dropdown / radio / scale), exactly as shown."},
        "reason": {"type": "string", "enum": ["unknown", "low_confidence"]},
        "kind": {
            "type": "string", "enum": ["question", "action"],
            "description": "'question' = a value to write into a form field. 'action' = you are blocked and the user "
                           "must DO something (create an account / sign in, solve a CAPTCHA, finish an email/SMS "
                           "verification, set a password); phrase the question as that task.",
        },
    },
    "required": ["question"],
}
_SUBMIT_SCHEMA = {
    "type": "object",
    "properties": {
        "answers": {
            "type": "array",
            "description": "EVERY field you filled: label and the exact value entered/selected.",
            "items": {
                "type": "object",
                "properties": {"question": {"type": "string"}, "answer": {"type": "string"}, "field_key": {"type": "string"}},
                "required": ["question", "answer"],
            },
        },
        "screenshot": {"type": "string", "description": "Filename of the full-page screenshot you took of the filled form."},
    },
    "required": ["answers"],
}
_RESULT_SCHEMA = {
    "type": "object",
    "properties": {"confirmed": {"type": "boolean"}, "evidence": {"type": "string"}, "screenshot": {"type": "string"}},
    "required": ["confirmed", "evidence"],
}
_QUESTIONS_SCHEMA = {
    "type": "object",
    "properties": {
        "questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "field_type": {"type": "string", "enum": [f.value for f in FieldType]},
                    "required": {"type": "boolean"},
                    "options": {"type": "array", "items": {"type": "string"}},
                    "key": {"type": "string"},
                },
                "required": ["label"],
            },
        }
    },
    "required": ["questions"],
}
_EMPTY_SCHEMA: dict[str, Any] = {"type": "object", "properties": {}}
_START_ACCOUNT_SCHEMA = {
    "type": "object",
    "properties": {
        "purpose": {"type": "string", "enum": ["create", "sign_in", "reset"],
                    "description": "'create' = sign up (returns a saved login instead when one exists), 'sign_in' = "
                                   "use the saved login, 'reset' = the email is already registered: new password via "
                                   "'Forgot password'."},
        "site_url": {"type": "string", "description": "URL of the page you are on (the account belongs to its site)."},
    },
    "required": ["purpose", "site_url"],
}
_CHECK_EMAIL_SCHEMA = {
    "type": "object",
    "properties": {
        "want": {"type": "string", "enum": ["code", "link"]},
        "length": {"type": "integer", "description": "Code length when the page says it (e.g. 6)."},
    },
    "required": ["want"],
}
_FINISH_ACCOUNT_SCHEMA = {
    "type": "object",
    "properties": {
        "outcome": {"type": "string", "enum": ["created", "signed_in", "reset", "failed"]},
        "detail": {"type": "string", "description": "For 'failed': what stopped you (shown to the user)."},
    },
    "required": ["outcome"],
}
_CAPTCHA_SCHEMA = {"type": "object", "properties": {"detail": {"type": "string"}}}


class AgentToolbox:
    """State + handlers for the custom tools of one agent session.

    ``phase``: "harvest" (list questions only), "fill" (fill, then request_submit -> stop) or
    "submit" (refill if needed, request_submit arms exactly one submit click)."""

    def __init__(self, ctx: ApplyContext, gate: ToolGate, *, phase: str, output_dir: Path, mode: Mode,
                 cover_letters_dir: Path | None = None) -> None:
        self.ctx = ctx
        self.gate = gate
        self.phase = phase
        self.output_dir = output_dir
        self.mode = mode
        self.cover_letters_dir = cover_letters_dir
        self.resolver = AnswerResolver.from_context(ctx)
        self.resolved: dict[str, ResolvedAnswer] = {}
        self.unresolved: dict[str, UnresolvedField] = {}
        self.captcha: str | None = None
        self.submit_ready = False
        self.submit_refusals: list[str] = []
        self.submission: dict[str, Any] | None = None
        self.harvested: list[FormQuestion] | None = None
        self.resume_path: str | None = None
        self.resume_variant_id: int | None = None
        self.cover_letter_path: str | None = None
        self.screenshot_path: str | None = None
        self.usage = TokenUsage()
        #: the agent may create / reset job-site accounts this session (preference on + mailbox)
        self.accounts_on = _accounts_enabled(ctx)
        self.account_host: str | None = None
        self.account_started: float | None = None
        self.account_failed = False
        self.account_nudges = 0
        #: screenshots older than this session do not count (the Review-time prefill.png
        #: already sits in the same directory when a fresh submit session starts)
        self.started_at = time.time()
        # submit phase: what was audited at fill time is authoritative
        self.recorded: dict[str, ApplicationAnswer] = {}
        if phase == "submit":
            self.load_recorded()
        if ctx.resume is not None:
            self._allow_upload(ctx.resume.file_path)
            self.resume_path = ctx.resume.file_path
            self.resume_variant_id = ctx.resume.id
        if ctx.application.cover_letter_path:
            self._allow_upload(ctx.application.cover_letter_path)
            self.cover_letter_path = ctx.application.cover_letter_path

    def load_recorded(self) -> None:
        """Answers audited at fill time (and possibly edited by the user in Review)."""
        self.recorded = {
            normalize_question(aa.question): aa for aa in db.list_application_answers(self.ctx.conn, self.ctx.application.id)
        }

    @property
    def parked(self) -> bool:
        return bool(self.unresolved) or self.captcha is not None

    def _allow_upload(self, path: str) -> None:
        self.gate.allowed_upload_paths.add(str(Path(path).expanduser().resolve()))

    def _park(self, q: FormQuestion, reason: QuestionReason | str, **kw: Any) -> None:
        kind = resolve_kind(q.label, reason, kw.pop("kind", None))
        if kind is QuestionKind.ACTION:
            kw.pop("suggested_answer", None)  # nothing to type for an action
        self.unresolved[normalize_question(q.label)] = UnresolvedField(question=q, reason=QuestionReason(reason).value,
                                                                       kind=kind.value, **kw)

    # ---- handlers (async (args) -> MCP result) ---------------------------------------

    async def get_profile(self, args: dict[str, Any]) -> dict[str, Any]:
        p = self.ctx.profile
        data = p.model_dump(mode="json", exclude={"raw_text", "updated_at", "extra"})
        data["note"] = "Sensitive fields (work authorization, sponsorship, salary, notice, start date, relocation, EEO, attestations) are NOT here: always use lookup_answer for them."
        return _ok(data)

    async def lookup_answer(self, args: dict[str, Any]) -> dict[str, Any]:
        q = FormQuestion(
            key=str(args.get("field_key") or normalize_question(args["question"])[:80] or "q"), label=str(args["question"]).strip(),
            field_type=FieldType(args.get("field_type") or "text"), required=bool(args.get("required", False)),
            options=[str(o) for o in args.get("options") or []], max_length=args.get("max_length"),
        )
        norm = normalize_question(q.label)
        if self.accounts_on and action_type(q.label) in {ACTION_ACCOUNT, ACTION_VERIFICATION} and not self.account_failed:
            return _ok({"status": "account_step", "instruction": (
                "This is part of signing up / signing in, not a question to answer. Use the email and password from "
                "start_account (and a code from check_email). Never put them in lookup_answer or request_submit."
                if self.gate.account_mode else
                "This site needs an account. Call start_account (purpose 'create', or 'sign_in' if you are on a "
                "sign-in page) and use the email and password it returns."
            )})
        if classify_kind(q.label) is QuestionKind.ACTION:
            # Passwords, "retype email", sign-in and verification steps are never answered by the
            # agent (nor stored in memory): the user does them in the agent's Chrome, then retries.
            self._park(q, QuestionReason.UNKNOWN, kind=QuestionKind.ACTION)
            return _ok({
                "status": "needs_user", "reason": "action",
                "instruction": "This is an account / sign-in / verification step, not a question to answer. Do NOT "
                               "fill it or create an account. It has been sent to the user as a task. Stop now.",
            })
        if self.phase == "submit" and norm in self.recorded:
            aa = self.recorded[norm]
            q = q.model_copy(update={"field_type": aa.field_type})
            self.resolved[norm] = ResolvedAnswer(q, aa.answer, aa.origin, aa.confidence, origin_ref=f"application_answers:{aa.id}")
            return _ok({"status": "answered", "answer": aa.answer, "origin": aa.origin.value,
                        "note": "Already approved: use exactly this value."})
        before = self.resolver.usage.snapshot()
        try:
            r = await self.resolver.resolve(q)
        except NeedsUser as nu:
            self._park(q, nu.reason, never_guess_key=nu.never_guess_key, suggested_answer=nu.suggested_answer, confidence=nu.confidence)
            return _ok({
                "status": "needs_user", "reason": nu.reason.value,
                "instruction": "Do NOT fill this field. It has been sent to the user. Continue looking up the remaining "
                               "fields (to collect every unknown at once), then stop without calling request_submit.",
            })
        finally:
            self.usage.add(self.resolver.usage.since(before))
        self.resolved[norm] = r
        payload: dict[str, Any] = {"status": "answered", "answer": r.answer, "origin": r.origin.value, "confidence": r.confidence}
        if r.action == "upload_resume":
            self._allow_upload(r.answer)
            self.resume_path = r.answer
            payload["instruction"] = "Upload this file with browser_file_upload."
        elif r.action == "cover_letter":
            payload["instruction"] = "Call write_cover_letter and upload the returned file (or paste its text)."
        elif r.action == "skip":
            payload["instruction"] = "Optional field: leave it blank."
        return _ok(payload)

    async def ask_user(self, args: dict[str, Any]) -> dict[str, Any]:
        opts = [str(o) for o in args.get("options") or [] if str(o).strip()]
        q = FormQuestion(
            key=normalize_question(args["question"])[:80] or "q", label=str(args["question"]).strip(),
            field_type=choice_field_type(args.get("field_type") or "text", opts), options=opts,
        )
        reason = QuestionReason(args.get("reason") or "unknown")
        kind = resolve_kind(q.label, reason, args.get("kind"))
        if (kind is QuestionKind.ACTION and self.accounts_on and not self.account_failed and self.account_nudges < 2
                and action_type(q.label, reason) in {ACTION_ACCOUNT, ACTION_VERIFICATION}):
            self.account_nudges += 1
            return _ok("Creating accounts is turned on: do not ask the user. Call start_account (purpose 'create', "
                       "'sign_in' or 'reset') and continue; use check_email for emailed codes or links. Only if that "
                       "fails, call finish_account(outcome='failed').")
        if kind is QuestionKind.ACTION:
            self._park(q, reason, kind=kind)
            return _ok("Sent to the user as a task to do (not a field to fill). Do not fill anything for it and do not "
                       "create accounts. Stop now.")
        self._park(q, reason, never_guess_key=classify_never_guess(q), kind=kind)
        return _ok("Sent to the user. Do not fill this field. Finish looking up any other unknown fields, then stop.")

    # ---- job-site accounts (start_account / check_email / finish_account) ---------------

    async def start_account(self, args: dict[str, Any]) -> dict[str, Any]:
        from autoapply import site_accounts

        if not self.accounts_on:
            return _err("Creating accounts is turned off. Call ask_user ('Account required to apply at <site>', kind "
                        "'action') and stop.")
        if self.gate.data_entered:
            return _err("Do the account step before entering application data: finish the application form instead, "
                        "or ask_user if the site wants an account now.")
        purpose = str(args.get("purpose") or "create")
        url = str(args.get("site_url") or self.ctx.job.apply_url or self.ctx.job.source_url or "")
        company = db.get_company(self.ctx.conn, self.ctx.job.company_id).name
        try:
            login = site_accounts.begin(self.ctx.conn, url, purpose=purpose, company=company, job_id=self.ctx.job.id)
        except site_accounts.AccountError as e:
            return _err(f"{e}.")
        self.account_host = login.host
        self.account_started = time.time()
        self.gate.account_mode = True
        p = self.ctx.profile
        first = getattr(p, "first_name", None) or (p.full_name or "").split(" ")[0] or None
        last = getattr(p, "last_name", None) or (" ".join((p.full_name or "").split(" ")[1:]) or None)
        steps = {
            "create": "Fill the sign-up form with exactly this email and password (also any confirm-password field) and "
                      "the name / phone below, tick only the checkboxes the form requires (terms), and press its "
                      "sign-up button. If the site says the email is already registered, call start_account with "
                      "purpose 'reset'. If it wants an emailed code or link, call check_email.",
            "sign_in": "Sign in with exactly this email and password. If the site rejects them, call start_account with "
                       "purpose 'reset'.",
            "reset": "Use the site's 'Forgot password' with this email, then call check_email(want='link') (or 'code'), "
                     "open the link with browser_navigate and set this new password (both fields), then sign in.",
        }[purpose]
        return _ok({
            "site": login.host, "email": login.email, "password": login.password, "saved_login": login.existing,
            "first_name": first, "last_name": last, "phone": p.phone,
            "instruction": steps + " When you are signed in (or the application form shows), call finish_account with "
                                   "the outcome, then fill the application. Never report these values in "
                                   "request_submit, and never type the password anywhere except this site's "
                                   "password fields.",
        })

    async def check_email(self, args: dict[str, Any]) -> dict[str, Any]:
        from autoapply.mail import imap_codes

        if not self.gate.account_mode or self.account_host is None:
            return _err("Call start_account first.")
        want = "link" if str(args.get("want") or "code") == "link" else "code"
        company = db.get_company(self.ctx.conn, self.ctx.job.company_id).name
        from datetime import UTC, datetime

        since = datetime.fromtimestamp(self.account_started or time.time(), UTC)
        found = await imap_codes.poll_account_mail(self.ctx.conn, terms=_site_terms(self.account_host, company),
                                                   sent_after=since, want=want, length=args.get("length"),
                                                   timeout_s=float(args.get("timeout_s") or 120))
        if not found:
            return _ok({"found": False, "instruction": "Nothing arrived yet. Check the page asked for it (resend if it "
                                                       "offers), call check_email once more, else finish_account('failed')."})
        if want == "link":
            return _ok({"found": True, "link": found, "instruction": "Open it with browser_navigate."})
        return _ok({"found": True, "code": found, "instruction": "Type it into the code field."})

    async def finish_account(self, args: dict[str, Any]) -> dict[str, Any]:
        from autoapply import site_accounts

        outcome = str(args.get("outcome") or "failed")
        host = self.account_host
        self.gate.account_mode = False
        self.account_host = None
        if host is not None:
            site_accounts.finish(self.ctx.conn, host, outcome)
        if outcome == "failed":
            self.account_failed = True
            why = str(args.get("detail") or "").strip()
            self._park(FormQuestion(key="account", label=f"Account required to apply at {host or 'this site'}"
                                    + (f": {why}" if why else ""), field_type=FieldType.TEXT), QuestionReason.UNKNOWN,
                       kind=QuestionKind.ACTION)
            return _ok("Sent to the user as a task (the saved password is in Settings > Guardrails > Job-site "
                       "accounts). Stop now.")
        return _ok("Account step done. Continue with the application form as usual.")

    async def pick_resume(self, args: dict[str, Any]) -> dict[str, Any]:
        if self.ctx.resume is not None:
            v = self.ctx.resume
            return _ok({"file_path": v.file_path, "label": v.label, "reasons": ["chosen for this application"]})
        pick = pick_resume(self.ctx.conn, self.ctx.job)
        if pick is None:
            self._park(FormQuestion(key="resume", label="Resume", field_type=FieldType.FILE, required=True), QuestionReason.UNKNOWN)
            return _err("No approved resume is available; the user has been asked. Stop.")
        self._allow_upload(pick.variant.file_path)
        self.resume_path = pick.variant.file_path
        self.resume_variant_id = pick.variant.id
        db.update_application(self.ctx.conn, self.ctx.application.id, resume_variant_id=pick.variant.id, resume_pick_score=pick.score)
        return _ok({"file_path": pick.variant.file_path, "label": pick.variant.label, "reasons": pick.reasons})

    async def write_cover_letter(self, args: dict[str, Any]) -> dict[str, Any]:
        if self.cover_letter_path and Path(self.cover_letter_path).exists():
            return _ok({"file_path": self.cover_letter_path, "text": Path(self.cover_letter_path).read_text(encoding="utf-8")})
        job = self.ctx.job
        company = db.get_company(self.ctx.conn, job.company_id)
        out_dir = self.cover_letters_dir or get_paths(create=True).cover_letters
        letter = await generate_cover_letter(
            self.ctx.llm, profile=self.ctx.profile, stories=db.list_stories(self.ctx.conn), job=job, company=company, out_dir=out_dir,
        )
        self.usage.add(TokenUsage(letter.tokens_in, letter.tokens_out, 1))
        if not letter.grounded or letter.path is None:
            return _err(
                "Could not write a cover letter supported by the candidate's facts. If the field is optional leave it "
                "empty; if it is required call ask_user with question 'Cover letter'."
            )
        self.cover_letter_path = str(letter.path)
        self._allow_upload(self.cover_letter_path)
        db.update_application(self.ctx.conn, self.ctx.application.id, cover_letter_path=self.cover_letter_path)
        for sid in letter.story_ids:
            db.record_story_use(self.ctx.conn, sid)
        return _ok({"file_path": self.cover_letter_path, "text": letter.text})

    async def report_captcha(self, args: dict[str, Any]) -> dict[str, Any]:
        self.captcha = str(args.get("detail") or "CAPTCHA on the application page")
        return _ok("Noted. The user will solve it. Stop now.")

    async def request_submit(self, args: dict[str, Any]) -> dict[str, Any]:
        if self.phase == "harvest":
            return _err("Not available while listing questions.")
        if self.parked:
            missing = [u.question.label for u in self.unresolved.values()] + ([f"CAPTCHA: {self.captcha}"] if self.captcha else [])
            return self._refuse("Cannot submit: waiting on the user for: " + "; ".join(missing) + ". Stop now.")
        problems, checks = self._audit(args.get("answers") or [])
        if not problems:
            problems = self._audit_entries(checks)
        if not problems and self.phase == "submit":
            problems = self._unapproved(checks)
            if problems:
                return self._refuse(
                    "Submission blocked: these answers differ from what was approved for this application:\n- "
                    + "\n- ".join(problems) + "\nDo not submit. Stop now."
                )
        if problems:
            return self._refuse("Submission blocked by guardrails:\n- " + "\n- ".join(problems) + "\nFix these (use lookup_answer), then call request_submit again.")
        shot = str(args.get("screenshot") or "")
        shot_path = self._find_screenshot(shot)
        if shot_path is None:
            name = "prefill.png" if self.phase == "fill" else "presubmit.png"
            return self._refuse(
                "Take a full-page screenshot of the filled form first: browser_take_screenshot with fullPage=true and "
                f"filename='{name}', then call request_submit with screenshot='{name}'."
            )
        self.screenshot_path = str(shot_path)
        if self.phase == "fill":
            self._record(checks)
            self.submit_ready = True
            if self.mode is Mode.REVIEW:
                return _ok("Form complete and saved for the user's review. Do NOT click submit. Stop now.")
            return _ok("Approved. Do NOT click submit yourself: the system finalises the submission. Stop now.")
        # submit phase: only after the pipeline durably recorded `submitting`
        app = db.get_application(self.ctx.conn, self.ctx.application.id)
        if app.state is not AppState.SUBMITTING:
            return self._refuse(f"Submission is not authorised (application state is {app.state.value}). Stop now.")
        # everything that will be sent is on the audit trail before the click
        self._record([(r, g) for r, g in checks if not (r.origin_ref or "").startswith("application_answers:")])
        self.submit_ready = True
        self.gate.arm_submit()
        return _ok(
            "Authorised. Click the form's submit button exactly ONCE now. Do not click it again even if nothing seems "
            "to happen. Then take a screenshot named 'confirmation.png' and call report_submission_result."
        )

    async def report_submission_result(self, args: dict[str, Any]) -> dict[str, Any]:
        self.submission = {"confirmed": bool(args.get("confirmed")), "evidence": str(args.get("evidence") or ""),
                           "screenshot": args.get("screenshot")}
        return _ok("Recorded. Stop now.")

    async def report_form_questions(self, args: dict[str, Any]) -> dict[str, Any]:
        out: list[FormQuestion] = []
        for i, q in enumerate(args.get("questions") or []):
            try:
                ft = FieldType(q.get("field_type") or "text")
            except ValueError:
                ft = FieldType.TEXT
            label = str(q.get("label") or "").strip()
            if not label:
                continue
            opts = [str(o) for o in q.get("options") or [] if str(o).strip()]
            out.append(FormQuestion(key=str(q.get("key") or f"q{i}"), label=label, field_type=choice_field_type(ft, opts),
                                    required=bool(q.get("required")), options=opts))
        self.harvested = out
        return _ok(f"Recorded {len(out)} questions. Stop now.")

    # ---- helpers ---------------------------------------------------------------------

    def _refuse(self, message: str) -> dict[str, Any]:
        self.submit_refusals.append(message)
        return _err(message)

    def _find_screenshot(self, name: str) -> Path | None:
        """A screenshot taken during THIS session (an older file with the same name, e.g. the
        Review-time prefill.png, does not prove the current page state)."""
        cands = []
        if name:
            p = Path(name)
            cands += [p] if p.is_absolute() else [self.output_dir / p, self.output_dir / p.name]
        cands += [self.output_dir / "prefill.png", self.output_dir / "presubmit.png"]
        for c in cands:
            try:
                if (c.is_file() and c.resolve().is_relative_to(self.output_dir.resolve())
                        and c.stat().st_mtime >= self.started_at - 1.0):
                    return c
            except OSError:
                continue
        return None

    def _unapproved(self, checks: list[tuple[ResolvedAnswer, str]]) -> list[str]:
        """Submit phase: every answer must be one recorded (and possibly edited/approved) at
        fill/review time, or a deterministic profile / never-guess fact / the chosen file."""
        out = []
        for r, _ in checks:
            if (r.origin_ref or "").startswith("application_answers:"):
                continue
            if r.action in {"upload_resume", "cover_letter"} or r.question.field_type is FieldType.FILE:
                continue
            if r.origin in {AnswerOrigin.PROFILE, AnswerOrigin.NEVER_GUESS}:
                continue
            out.append(f"'{r.question.label}' ({r.origin.value}) was not part of the approved answers")
        return out

    def _audit_entries(self, checks: list[tuple[ResolvedAnswer, str]]) -> list[str]:
        """Cross-check what was actually typed/selected (recorded by the gate) against the
        audited answers: a value the agent entered but did not report cannot slip through."""
        audited: list[tuple[ResolvedAnswer, str]] = [(r, g) for r, g in checks]
        values = [v for r, g in audited for v in (g, r.answer) if v]
        labels = [normalize_question(r.question.label) for r, _ in audited]
        problems: list[str] = []
        for e in self.gate.entries.values():
            vals = [v.strip() for v in (e.value.split("; ") if e.kind == "select" else [e.value]) if v.strip()]
            if not vals:
                continue
            nlabel = normalize_question(e.label)
            if e.kind == "fill" and e.role in {"checkbox", "radio", "switch"}:
                if yes_no(e.value) is False or e.value.strip().lower() in {"false", "unchecked", "off"}:
                    continue
                if not any(nlabel and lab and (nlabel in lab or lab in nlabel) for lab in labels):
                    problems.append(f"'{e.label}' was checked but is not in the answers you reported (use lookup_answer)")
                continue
            sensitive = bool(e.label and (classify_never_guess(e.label) or matches_always_ask(e.label, self.ctx.preferences)))
            for v in vals:
                nv = normalize_question(v)
                if any(nv == normalize_question(x) for x in values):
                    continue
                if not sensitive and any(_answers_agree(v, x, []) for x in values):
                    continue
                if not sensitive and e.kind == "type" and e.role in {"combobox", "searchbox"} and nv and any(
                        nv in normalize_question(x) for x in values):
                    continue  # search text typed into a combobox before picking the option
                problems.append(f"'{e.label or 'a field'}': entered {v!r}, which is not an answer you obtained and reported "
                                "(every value typed or selected must come from get_profile/lookup_answer)")
        return problems

    def _audit(self, answers: list[dict[str, Any]]) -> tuple[list[str], list[tuple[ResolvedAnswer, str]]]:
        """Match every claimed answer to how it was obtained, then run guardrails."""
        problems: list[str] = []
        checks: list[tuple[ResolvedAnswer, str]] = []
        if not answers:
            return ["List every field you filled in `answers`."], []
        for item in answers:
            label = str(item.get("question") or "").strip()
            given = str(item.get("answer") or "")
            if not label:
                continue
            norm = normalize_question(label)
            # submit phase: the answers recorded (and possibly edited) at fill/review time win
            r = None if (self.phase == "submit" and norm in self.recorded) else self.resolved.get(norm)
            if r is None and norm in self.recorded:  # submit phase: approved at fill/review time
                aa = self.recorded[norm]
                r = ResolvedAnswer(FormQuestion(key=aa.field_key or norm[:80] or "q", label=aa.question, field_type=aa.field_type),
                                   aa.answer, aa.origin, aa.confidence, origin_ref=f"application_answers:{aa.id}")
            if r is not None:
                if r.action in {"upload_resume", "cover_letter"} or r.question.field_type is FieldType.FILE:
                    checks.append((r, given))
                    continue
                if not _answers_agree(given, r.answer, r.question.options):
                    problems.append(f"'{label}': entered {given!r} but lookup_answer returned {r.answer!r}")
                    continue
                checks.append((r, given))
                continue
            q = FormQuestion(key=str(item.get("field_key") or norm[:80] or "q"), label=label)
            if classify_never_guess(q) or matches_always_ask(label, self.ctx.preferences):
                problems.append(f"'{label}' is a sensitive field: it must come from lookup_answer")
                continue
            prof = profile_answer(self.ctx.profile, q)
            if prof is not None and _answers_agree(given, prof[0], []):
                checks.append((ResolvedAnswer(q, prof[0], AnswerOrigin.PROFILE, 1.0, origin_ref=f"profile:{prof[1]}"), given))
                continue
            if self._is_upload_label(label, given):
                checks.append((ResolvedAnswer(q, given, AnswerOrigin.CV, 1.0, action="upload_resume"), given))
                continue
            problems.append(f"'{label}': answer was not obtained from get_profile/lookup_answer — call lookup_answer for it")
        violations = check_answers(
            [AnswerForCheck(r.question, r.answer, r.origin, r.confidence, r.never_guess_key) for r, _ in checks
             if r.action not in {"upload_resume", "cover_letter", "skip"}],
            self.ctx.never_guess, self.ctx.preferences, country=self.resolver.country,
        )
        problems += [f"'{v.question}': {v.problem}" for v in violations]
        return problems, checks

    def _is_upload_label(self, label: str, given: str) -> bool:
        if not re.search(r"\b(resume|cv|cover letter)\b", label, re.I):
            return False
        g = str(Path(given).expanduser())
        return any(p.endswith(Path(g).name) for p in self.gate.allowed_upload_paths)

    def _record(self, checks: list[tuple[ResolvedAnswer, str]]) -> None:
        conn, app_id = self.ctx.conn, self.ctx.application.id
        with db.transaction(conn):
            for r, given in checks:
                if r.action == "skip":
                    continue
                if r.action == "cover_letter":
                    r = ResolvedAnswer(r.question, self.cover_letter_path or given, AnswerOrigin.GENERATED, None, action=r.action)
                self.resolver.record(app_id, r, answer_override=given if r.action is None else None)

    # ---- SDK tool objects ------------------------------------------------------------

    def sdk_tools(self) -> list[Any]:
        from claude_agent_sdk import SdkMcpTool

        spec = [
            ("get_profile", "Candidate contact details, links, work history, education and skills.", _EMPTY_SCHEMA, self.get_profile),
            ("lookup_answer", "Get the answer for ONE form field (call it for every question, incl. sensitive ones).", _LOOKUP_SCHEMA, self.lookup_answer),
            ("ask_user", "Send a question you cannot answer to the user (parks this application).", _ASK_SCHEMA, self.ask_user),
            ("pick_resume", "Best approved resume for this job: returns the file path to upload.", _EMPTY_SCHEMA, self.pick_resume),
            ("write_cover_letter", "Write a fact-checked cover letter; returns file path and text.", _EMPTY_SCHEMA, self.write_cover_letter),
            ("report_captcha", "Report a CAPTCHA / bot check on the page (the user will solve it).", _CAPTCHA_SCHEMA, self.report_captcha),
            ("request_submit", "Ask permission to submit once EVERY field is filled. Never click submit without it.", _SUBMIT_SCHEMA, self.request_submit),
            ("report_submission_result", "Report whether a confirmation ('thank you', 'application received') appeared.", _RESULT_SCHEMA, self.report_submission_result),
            ("report_form_questions", "Report every question on the application form (label, type, required, options).", _QUESTIONS_SCHEMA, self.report_form_questions),
        ]
        if self.accounts_on:
            spec += [
                ("start_account", "The site wants an account: get the email + password to sign up / sign in / reset with.", _START_ACCOUNT_SCHEMA, self.start_account),
                ("check_email", "Wait for the site's email (code or confirm / reset link) in the user's mailbox.", _CHECK_EMAIL_SCHEMA, self.check_email),
                ("finish_account", "End the account step: created / signed_in / reset, or failed (goes to the user).", _FINISH_ACCOUNT_SCHEMA, self.finish_account),
            ]
        return [SdkMcpTool(name=n, description=d, input_schema=s, handler=h) for n, d, s, h in spec]

    def handler(self, name: str) -> Callable[[dict[str, Any]], Any]:
        """Direct access to a tool handler (tests / fake clients)."""
        if name.startswith(f"mcp__{TOOL_SERVER}__"):
            name = name.removeprefix(f"mcp__{TOOL_SERVER}__")
        if name not in OWN_TOOLS:
            raise KeyError(name)
        return getattr(self, name)


# =====================================================================================
# prompts
# =====================================================================================

SYSTEM_PROMPT = """You complete job applications in a real browser on the candidate's behalf, carefully and honestly.

Rules (non-negotiable):
- Use ONLY values from the autoapply tools: get_profile for contact/links/history, lookup_answer for EVERY other
  question (including work authorization, sponsorship, salary, notice period, start date, relocation, demographic
  and legal questions). Never guess or invent an answer.
- If lookup_answer says needs_user, leave that field empty; keep looking up the rest so every unknown is collected, then stop.
- Upload only the file paths returned by pick_resume / write_cover_letter.
- You may NOT submit yourself: no clicking submit/apply/send/done/complete/finish buttons once you have entered data,
  and no submitting with the keyboard (Enter/Space on a button). When every field is filled, take a full-page
  screenshot (browser_take_screenshot, fullPage=true, filename 'prefill.png') and call request_submit with EVERY
  field you filled and the exact value entered (values you type but do not report block the submission).
- If you see a CAPTCHA or "verify you are human" check, call report_captcha and stop.
- Never log in to or visit LinkedIn or Glassdoor.
{account_rule}
- ask_user has two kinds. kind 'question' is for a value to write into a form field (work authorization, years of
  experience, an essay prompt). kind 'action' is for anything that is a STEP for the user to perform rather than an
  answer: account or login required, password / confirm-password / retype-email fields of an account form, CAPTCHA
  or bot checks, email or SMS verification codes or links, no online form. Phrase an action as the task
  ('Account required to apply at <site>', 'Verify your email at <site>'). Never ask the user to type a password.
- Multi-page forms: use 'Next'/'Continue'/'Save and continue' buttons to move between pages.
- Prefer browser_snapshot over screenshots to read the page (cheaper)."""

_ACCOUNT_RULE_OFF = """- Never create accounts or set passwords: if the site requires an account, call ask_user with question
  'Account required to apply at <site>' and kind 'action', and stop."""
_ACCOUNT_RULE_ON = """- If the site requires an account or sign-in (including Workday's 'Create Account' / 'Sign In'), do it yourself
  BEFORE entering any application data: call start_account (purpose 'create'; 'sign_in' on a sign-in page; 'reset'
  when the email is already registered), use exactly the email and password it returns, get emailed codes or links
  with check_email, then call finish_account. Never invent or reuse other passwords, never sign in with Google /
  LinkedIn / other single sign-on, and never report account values in request_submit. CAPTCHAs still go to
  report_captcha. Only if the account step fails, call finish_account(outcome='failed') and stop."""


def system_prompt(accounts_on: bool) -> str:
    return SYSTEM_PROMPT.replace("{account_rule}", _ACCOUNT_RULE_ON if accounts_on else _ACCOUNT_RULE_OFF)


def _accounts_enabled(ctx: ApplyContext) -> bool:
    from autoapply import site_accounts

    try:
        return site_accounts.enabled(ctx.conn)
    except Exception:  # noqa: BLE001 - a missing table / meta must never break applying
        log.debug("could not read the account setting", exc_info=True)
        return False


_GENERIC_HOST_LABELS = {"www", "jobs", "careers", "career", "apply", "join", "hire", "recruiting", "talent", "boards",
                        "job-boards", "app", "my", "com", "co", "io", "net", "org", "in"}


def _site_terms(host: str, company: str) -> list[str]:
    """What an account email from ``host`` mentions: the company and the site's brand labels
    ("acme.wd5.myworkdayjobs.com" -> acme, myworkdayjobs, workday)."""
    labels = [lbl for lbl in host.split(".") if lbl and lbl not in _GENERIC_HOST_LABELS and not re.fullmatch(r"wd\d+", lbl)]
    terms = [company, host, *labels]
    if "myworkdayjobs" in host:
        terms.append("workday")
    return [t for t in dict.fromkeys(t.strip() for t in terms if t) if len(t) >= 3]


def _job_header(job: Job, company: str) -> str:
    return f"Company: {company}\nRole: {job.title}\nApplication URL: {job.apply_url or job.source_url}\n"


# =====================================================================================
# the adapter
# =====================================================================================


@dataclass(slots=True)
class SessionOutcome:
    usage: TokenUsage = field(default_factory=TokenUsage)
    error: str | None = None
    steps: int = 0
    interrupted: bool = False
    #: the session raised (the client was disconnected; it can't take a follow-up query)
    crashed: bool = False


#: Big, regenerable or per-process parts of a Chrome profile that a seeded copy doesn't need.
_PROFILE_SKIP = {"Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache",
                 "ShaderCache", "GraphiteDawnCache", "Crashpad", "component_crx_cache", "optimization_guide_model_store",
                 "SingletonLock", "SingletonSocket", "SingletonCookie", "lockfile", "RunningChromeVersion"}


def _seed_profile(base: Path, target: Path) -> None:
    """Give a worker's own Chrome profile the main profile's logins (cookies, local storage), so
    agents 2..N aren't signed out everywhere. Re-copied when the main profile's cookies are newer
    than the last copy (e.g. after you sign in to a site in the agent's Chrome)."""
    import shutil

    marker = target / ".seeded-from-main"
    src_cookies = base / "Default" / "Cookies"
    if not src_cookies.exists():
        return
    try:
        if marker.exists() and marker.stat().st_mtime >= src_cookies.stat().st_mtime:
            return
        for item in base.iterdir():
            if item.name in _PROFILE_SKIP:
                continue
            dest = target / item.name
            if item.is_dir():
                shutil.copytree(item, dest, dirs_exist_ok=True, symlinks=True,
                                ignore=shutil.ignore_patterns(*_PROFILE_SKIP))
            else:
                shutil.copy2(item, dest)
        marker.touch()
    except OSError as e:  # best-effort: an unseeded profile still works, it's just signed out
        log.warning("could not copy the agent's logins into %s: %s", target, e)


class AgenticAdapter:
    """Implements :class:`autoapply.apply.base.Adapter` (used for Workday and unknown ATS)."""

    ats = Ats.OTHER
    HANDLES = frozenset({Ats.WORKDAY, Ats.OTHER})

    def __init__(
        self,
        *,
        client_factory: ClientFactory | None = None,
        model: str | None = None,
        max_turns: int = 80,
        harvest_max_turns: int = 40,
        max_budget_usd: float | None = None,
        playwright_mcp_package: str = PLAYWRIGHT_MCP_PACKAGE,
        chrome_profile_dir: Path | None = None,
        npx_command: str = "npx",
        keep_session_for_submit: bool = True,
    ) -> None:
        self.client_factory: ClientFactory = client_factory or default_client_factory
        self.model = model
        self.max_turns = max_turns
        self.harvest_max_turns = harvest_max_turns
        self.max_budget_usd = max_budget_usd
        self.playwright_mcp_package = playwright_mcp_package
        self.chrome_profile_dir = chrome_profile_dir
        self.npx_command = npx_command
        self.keep_session_for_submit = keep_session_for_submit
        self._live: dict[int, tuple[AgentClient, AgentToolbox]] = {}
        #: application id -> worker slot (Chrome profile) its kept-open session holds
        self._live_slot: dict[int, int] = {}
        self.last_toolbox: AgentToolbox | None = None

    # ---- Adapter protocol ------------------------------------------------------------

    def can_handle(self, job: Job) -> bool:
        if job.easy_apply or job.ats is Ats.LINKEDIN_EASY_APPLY:
            return False
        url = job.apply_url or ""
        host = (urlsplit(url).hostname or "").lower()
        if not url or any(host == h or host.endswith("." + h) for h in BLOCKED_HOSTS):
            return False
        return job.ats in self.HANDLES or "myworkdayjobs.com" in host

    async def harvest_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        """Browser scan: the agent lists the form's questions without filling anything.

        Outcomes, in order:

        * CAPTCHA, or the agent called ``ask_user`` (account / login wall, no online form)
          -> :class:`HarvestBlocked` carrying those inbox items (prep parks the job now
          instead of re-queueing it for a fill that would hit the same wall);
        * ``report_form_questions`` was called -> those questions;
        * otherwise ONE follow-up turn in the same session demanding the report;
        * otherwise the questions read from the last page snapshot that showed form fields;
        * otherwise ``RuntimeError`` with the session's own error (max turns, crash, ...).
        """
        await self._close_slot()  # one browser per Chrome profile: release any kept-open session first
        toolbox = self._toolbox(ctx, "harvest")
        company = db.get_company(ctx.conn, ctx.job.company_id).name
        prompt = (
            "LIST QUESTIONS ONLY. Do not type into, select, upload or click anything except navigation needed to reveal "
            "the application form (e.g. an 'Apply' / 'Apply now' button or link that opens it — also when this page is "
            "a job board, aggregator or news post that links to the employer's application page — or 'Next' on "
            "multi-page forms only if no data entry is required). Open the application URL, read the form with "
            "browser_snapshot, and call report_form_questions with every field (label, field_type, required, options). "
            "Then stop.\n"
            "You MUST finish with exactly one of these calls:\n"
            "- report_form_questions (the form's fields);\n"
            + ("- if applying needs an account or login, do the account step first (start_account, check_email, "
               "finish_account; typing into the account form is allowed), then list the application form's questions; "
               "only if it fails, finish_account(outcome='failed');\n"
               if toolbox.accounts_on else
               "- ask_user with question 'Account required to apply at <site>' and kind 'action' if applying needs an "
               "account or login (also when the form starts with password / retype-email fields);\n")
            + "- ask_user with question 'No online application form at <site>: <what the posting says to do instead>' "
            "and kind 'action' if there is no form to fill (e.g. apply by email or an external Google Form);\n"
            "- report_captcha for a CAPTCHA / human check.\n"
            "Do not spend long exploring: if the form is not reachable in a few steps, use ask_user as above.\n\n"
            + _job_header(ctx.job, company)
        )
        client = self.client_factory(self._options(ctx, toolbox, max_turns=self.harvest_max_turns), toolbox)
        outcome = await self._run(ctx, toolbox, prompt, client=client, keep_open=True)
        try:
            if self._harvest_settled(toolbox) is None and not outcome.crashed:
                log.info("harvest: agent stopped without reporting the questions (%s); asking once more",
                         outcome.error or "no report")
                retry = (
                    "You stopped without calling report_form_questions. Do it NOW, without further navigation: call "
                    "report_form_questions with every field of the application form you have seen (label, field_type, "
                    "required, options). If there was no form to read, call ask_user instead ('Account required to "
                    "apply at <site>' or 'No online application form at <site>: <how to apply>'). Then stop."
                )
                second = await self._run(ctx, toolbox, retry, client=client, keep_open=True, already_connected=True)
                outcome.error = second.error or outcome.error
        finally:
            await self._disconnect(client)

        settled = self._harvest_settled(toolbox)
        if settled is not None:
            return settled
        fallback = questions_from_snapshot(toolbox.gate.last_form_snapshot)
        if fallback:
            log.info("harvest: agent did not report; read %d questions from the page snapshot", len(fallback))
            return fallback
        detail = outcome.error or (f"last refusal: {toolbox.gate.denials[-1][1]}" if toolbox.gate.denials else "")
        raise RuntimeError("agent did not report the form questions" + (f" ({detail})" if detail else ""))

    def _harvest_settled(self, toolbox: AgentToolbox) -> list[FormQuestion] | None:
        """Questions if the harvest session reached an outcome (raises HarvestBlocked when it
        needs the user), None when the agent never reported."""
        company = db.get_company(toolbox.ctx.conn, toolbox.ctx.job.company_id).name
        if toolbox.captcha:
            q = FormQuestion(key="captcha", label=f"Solve the CAPTCHA at {company}", required=True)
            raise HarvestBlocked("captcha", [UnresolvedField(question=q, reason=QuestionReason.CAPTCHA.value)],
                                 toolbox.harvested)
        if toolbox.unresolved:
            items = list(toolbox.unresolved.values())
            raise HarvestBlocked(items[0].question.label, items, toolbox.harvested)
        return toolbox.harvested

    async def fill(self, ctx: ApplyContext) -> FillResult:
        await self._close_slot()  # a leaked session would hold this worker's Chrome profile
        mode = self._mode(ctx)
        toolbox = self._toolbox(ctx, "fill", mode=mode)
        company = db.get_company(ctx.conn, ctx.job.company_id).name
        prompt = (
            "FILL THIS APPLICATION. Open the application URL, fill every field using the autoapply tools, upload the "
            "resume from pick_resume (and a cover letter from write_cover_letter only if the form asks for one), then "
            "take the full-page screenshot and call request_submit. Do not click submit.\n\n" + _job_header(ctx.job, company)
        )
        client = self.client_factory(self._options(ctx, toolbox), toolbox)
        outcome = await self._run(ctx, toolbox, prompt, client=client, keep_open=True)
        keep = False
        try:
            if toolbox.captcha:
                q = FormQuestion(key="captcha", label=f"Solve the CAPTCHA on the {company} application", required=True)
                return FillResult(ok=False, unresolved=[UnresolvedField(question=q, reason=QuestionReason.CAPTCHA.value)],
                                  screenshot_path=toolbox.screenshot_path, error=None)
            if toolbox.unresolved:
                return FillResult(ok=False, unresolved=list(toolbox.unresolved.values()), screenshot_path=toolbox.screenshot_path)
            if not toolbox.submit_ready:
                err = outcome.error or (toolbox.submit_refusals[-1] if toolbox.submit_refusals else "agent finished without completing the form")
                return FillResult(ok=False, error=err, screenshot_path=toolbox.screenshot_path)
            if toolbox.screenshot_path:
                db.update_application(ctx.conn, ctx.application.id, screenshot_path=toolbox.screenshot_path)
            keep = self.keep_session_for_submit and mode is Mode.AUTO
            if keep:
                self._live[ctx.application.id] = (client, toolbox)
                self._live_slot[ctx.application.id] = _slot()
            ctx.extra["agentic"] = {"mode": mode.value, "submit_ready": True, "session_open": keep}
            return FillResult(ok=True, screenshot_path=toolbox.screenshot_path, cover_letter_path=toolbox.cover_letter_path)
        finally:
            if not keep:
                await self._disconnect(client)

    async def submit(self, ctx: ApplyContext) -> SubmitResult:
        """Click submit exactly once (gate-enforced) and verify. Only after ``db.begin_submit``."""
        app = db.get_application(ctx.conn, ctx.application.id)
        if app.state is not AppState.SUBMITTING:
            return SubmitResult(verified=False, error=f"not_submitted: application state is {app.state.value}, expected submitting",
                                clicked=False)
        live = self._live.pop(ctx.application.id, None)
        self._live_slot.pop(ctx.application.id, None)
        await self._close_slot()  # sessions kept for other applications must not hold the profile
        company = db.get_company(ctx.conn, ctx.job.company_id).name
        if live is not None:
            client, toolbox = live
            toolbox.phase = "submit"
            toolbox.ctx = ctx
            toolbox.load_recorded()
            prompt = (
                "The user's settings allow this submission. Call request_submit again with the same answers and "
                "screenshot; if authorised, click the submit button exactly once, take a screenshot 'confirmation.png' "
                "and call report_submission_result."
            )
            fresh = False
        else:
            toolbox = self._toolbox(ctx, "submit", mode=self._mode(ctx))
            client = self.client_factory(self._options(ctx, toolbox), toolbox)
            prompt = (
                "SUBMIT THIS APPROVED APPLICATION. Open the application URL and fill every field with the answers "
                "lookup_answer returns (they were approved by the user — use them exactly), upload the resume / cover "
                "letter, take the full-page screenshot 'presubmit.png', call request_submit, and if authorised click "
                "submit exactly once. Then take 'confirmation.png' and call report_submission_result.\n\n"
                + _job_header(ctx.job, company)
            )
            fresh = True
        try:
            outcome = await self._run(ctx, toolbox, prompt, client=client, keep_open=True, already_connected=not fresh)
        finally:
            toolbox.gate.disarm()
            await self._disconnect(client)
        confirm_shot = self._confirmation_shot(toolbox)
        if not toolbox.gate.submit_clicked:
            why = toolbox.submit_refusals[-1] if toolbox.submit_refusals else (outcome.error or "agent did not click submit")
            return SubmitResult(verified=False, confirmation_screenshot_path=confirm_shot, error=f"not_submitted: {why}", clicked=False)
        if toolbox.submission and toolbox.submission.get("confirmed"):
            return SubmitResult(verified=True, confirmation_screenshot_path=confirm_shot)
        evidence = (toolbox.submission or {}).get("evidence") or outcome.error or "no confirmation reported"
        return SubmitResult(verified=False, confirmation_screenshot_path=confirm_shot, error=f"unverified: {evidence}")

    async def close(self, application_id: int | None = None) -> None:
        """Disconnect kept-open sessions (e.g. the pipeline decided not to submit)."""
        ids = [application_id] if application_id is not None else list(self._live)
        for i in ids:
            live = self._live.pop(i, None)
            self._live_slot.pop(i, None)
            if live is not None:
                await self._disconnect(live[0])

    async def _close_slot(self) -> None:
        """Disconnect kept-open sessions on the current worker's Chrome profile only: other
        workers' sessions use other profiles and are still in use."""
        slot = _slot()
        for i in [i for i in list(self._live) if self._live_slot.get(i, 1) == slot]:
            await self.close(i)

    # ---- internals -------------------------------------------------------------------

    def _mode(self, ctx: ApplyContext) -> Mode:
        return ctx.preferences.effective_mode(ctx.job.ats, ctx.job.company_id, ctx.job.mode_override)

    def _output_dir(self, ctx: ApplyContext) -> Path:
        d = Path(ctx.screenshots_dir)
        d.mkdir(parents=True, exist_ok=True)
        return d

    def _toolbox(self, ctx: ApplyContext, phase: str, *, mode: Mode | None = None) -> AgentToolbox:
        tb = AgentToolbox(ctx, ToolGate(read_only=phase == "harvest"), phase=phase, output_dir=self._output_dir(ctx),
                          mode=mode or self._mode(ctx))
        self.last_toolbox = tb
        return tb

    def profile_dir(self) -> Path:
        """Chrome profile for the current worker. Chromium allows one process per profile, so
        concurrent workers each get their own: slot 1 (and anything outside a worker pool) uses
        the main profile, slot N uses ``<profile>-N`` next to it (kept between runs)."""
        base = self.chrome_profile_dir or get_paths(create=True).chrome_profile
        slot = _slot()
        if slot == 1:
            return base
        p = base.with_name(f"{base.name}-{slot}")
        p.mkdir(mode=0o700, parents=True, exist_ok=True)
        _seed_profile(base, p)
        return p

    def playwright_server_config(self, ctx: ApplyContext) -> dict[str, Any]:
        profile = self.profile_dir()
        args = [
            "-y", self.playwright_mcp_package,
            "--user-data-dir", str(profile),
            "--output-dir", str(self._output_dir(ctx)),
            "--browser", "chrome",
            "--block-service-workers",
        ]
        if ctx.headless:
            args.append("--headless")
        return {"type": "stdio", "command": self.npx_command, "args": args}

    def _options(self, ctx: ApplyContext, toolbox: AgentToolbox, *, max_turns: int | None = None) -> Any:
        from claude_agent_sdk import ClaudeAgentOptions, HookMatcher, create_sdk_mcp_server

        server = create_sdk_mcp_server(TOOL_SERVER, tools=toolbox.sdk_tools())
        kwargs: dict[str, Any] = {
            "system_prompt": system_prompt(toolbox.accounts_on),
            "mcp_servers": {BROWSER_SERVER: self.playwright_server_config(ctx), TOOL_SERVER: server},
            "strict_mcp_config": True,
            "tools": [],  # no built-in Claude Code tools (Bash, Read, ...)
            "allowed_tools": [tool_id(t) for t in OWN_TOOLS] + [browser_id(t) for t in SAFE_BROWSER_TOOLS],
            "disallowed_tools": [browser_id(t) for t in FORBIDDEN_BROWSER_TOOLS],
            "can_use_tool": toolbox.gate.can_use_tool,
            "hooks": {"PreToolUse": [HookMatcher(matcher=None, hooks=[toolbox.gate.pre_tool_use_hook])]},
            "permission_mode": "default",
            "setting_sources": [],
            "max_turns": max_turns or self.max_turns,
            "cwd": str(self._output_dir(ctx)),
        }
        from autoapply.llm.provider import model_for_tier

        kwargs["model"] = self.model or model_for_tier(None)  # form filling needs the smart tier
        if self.max_budget_usd is not None:
            kwargs["max_budget_usd"] = self.max_budget_usd
        return ClaudeAgentOptions(**kwargs)

    async def _run(
        self,
        ctx: ApplyContext,
        toolbox: AgentToolbox,
        prompt: str,
        *,
        client: AgentClient | None = None,
        keep_open: bool = False,
        already_connected: bool = False,
    ) -> SessionOutcome:
        from claude_agent_sdk import AssistantMessage, ResultMessage, ToolResultBlock, ToolUseBlock, UserMessage

        outcome = SessionOutcome()
        client = client or self.client_factory(self._options(ctx, toolbox), toolbox)
        ctx.check_pause()
        try:
            if not already_connected:
                await client.connect()
            await client.query(prompt)
            async for msg in client.receive_response():
                if ctx.is_paused():
                    await client.interrupt()
                    outcome.interrupted = True
                    raise PausedError("paused by user")
                if isinstance(msg, AssistantMessage):
                    for block in msg.content:
                        if isinstance(block, ToolUseBlock):
                            await self._emit_step(ctx, outcome, block.name, block.input)
                elif isinstance(msg, UserMessage) and isinstance(msg.content, list):
                    for block in msg.content:
                        if isinstance(block, ToolResultBlock):
                            text = _flatten(block.content)
                            toolbox.gate.observe(text)
                            if toolbox.captcha is None and detect_captcha(text):
                                toolbox.captcha = "CAPTCHA detected on the page"
                    if toolbox.captcha is not None and not outcome.interrupted:
                        await client.interrupt()
                        outcome.interrupted = True
                elif isinstance(msg, ResultMessage):
                    outcome.usage = AgentSDKProvider._usage_from(msg.usage, msg.total_cost_usd)
                    if msg.is_error:
                        outcome.error = f"agent error: {msg.result or msg.subtype}"
                    break
        except PausedError:
            await self._disconnect(client)
            self._account(ctx, toolbox, outcome)
            raise
        except Exception as e:
            log.exception("agent session failed")
            outcome.error = f"agent session failed: {e}"
            outcome.crashed = True
            keep_open = False
        self._account(ctx, toolbox, outcome)
        if not keep_open:
            await self._disconnect(client)
        return outcome

    def _account(self, ctx: ApplyContext, toolbox: AgentToolbox, outcome: SessionOutcome) -> None:
        total = TokenUsage()
        total.add(outcome.usage)
        total.add(toolbox.usage)
        toolbox.usage = TokenUsage()
        if total.total_tokens:
            db.add_application_tokens(ctx.conn, ctx.application.id, total.input_tokens, total.output_tokens)
        acc = ctx.extra.setdefault("agent_usage", TokenUsage())
        acc.add(total)

    async def _emit_step(self, ctx: ApplyContext, outcome: SessionOutcome, name: str, inp: dict[str, Any]) -> None:
        action = _describe(name, inp)
        try:
            await ctx.emit("agent_step", AgentStepPayload(
                application_id=ctx.application.id, job_id=ctx.job.id, run_id=ctx.run_id, index=outcome.steps,
                action=action, at=now_ts(), screenshot_thumb=self._latest_thumb(ctx),
            ))
        except Exception:  # an emit failure must never break the session
            log.debug("emit agent_step failed", exc_info=True)
        outcome.steps += 1

    def _latest_thumb(self, ctx: ApplyContext) -> str | None:
        """Newest browser screenshot the agent saved to its output dir, as a throttled thumbnail."""
        from autoapply.thumbs import Throttle, newest_image, thumb_from_bytes

        throttle: Throttle = ctx.extra.setdefault("_thumb_throttle", Throttle())
        if not throttle.ready():
            return None
        found = newest_image(self._output_dir(ctx), ctx.extra.get("_thumb_mtime", 0.0))
        if found is None:
            return None
        path, mtime = found
        ctx.extra["_thumb_mtime"] = mtime
        try:
            return thumb_from_bytes(path.read_bytes())
        except OSError:
            return None

    def _confirmation_shot(self, toolbox: AgentToolbox) -> str | None:
        name = (toolbox.submission or {}).get("screenshot") or "confirmation.png"
        p = toolbox.output_dir / Path(str(name)).name
        return str(p) if p.is_file() else None

    @staticmethod
    async def _disconnect(client: AgentClient) -> None:
        try:
            await client.disconnect()
        except Exception:
            log.debug("disconnect failed", exc_info=True)


def _slot() -> int:
    return current_slot() or 1


def _flatten(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(_flatten(c.get("text") if isinstance(c, dict) else c) for c in content)
    return str(content)


def _describe(name: str, inp: dict[str, Any]) -> str:
    short = name.split("__")[-1]
    if short == "lookup_answer":
        return f"answering \"{str(inp.get('question', ''))[:60]}\""
    if short == "browser_navigate":
        return f"opening {urlsplit(str(inp.get('url', ''))).hostname or 'page'}"
    if short == "browser_click":
        return f"clicking {str(inp.get('element', ''))[:50]}"
    if short in {"browser_type", "browser_fill_form", "browser_select_option"}:
        return f"filling {str(inp.get('element', '') or 'fields')[:50]}"
    if short == "browser_file_upload":
        return "uploading file"
    if short == "request_submit":
        return "requesting submit"
    return short.replace("browser_", "").replace("_", " ")
