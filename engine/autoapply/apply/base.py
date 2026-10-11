"""Apply seam: every application adapter implements :class:`Adapter`.

Owner: Workstream A (scripted adapters: greenhouse/lever/ashby). Workstream B implements
``agentic.py`` against the same protocol.

Division of responsibility (so the double-apply guarantee lives in ONE place):

* The pipeline owns all state transitions (``autoapply.db.transition``). Adapters never
  write ``applications.state``.
* ``fill()`` fills the form and records every Q&A via
  ``db.add_application_answer`` + a full-page screenshot, then returns. It must not click
  submit. Unresolvable fields are returned as ``FillResult.unresolved`` (the pipeline parks
  the job as ``needs_you``).
* The pipeline then checks guardrails (caps, cooldown, pause, mode) and calls
  ``db.begin_submit`` (durable ``submitting`` pre-write) BEFORE calling ``submit()``.
* ``submit()`` clicks submit exactly once and verifies the confirmation. It never retries
  the click. Ambiguous outcome -> ``SubmitResult(verified=False)`` -> ``unknown_verify``.

The state machine itself (allowed transitions) is in ``autoapply.models`` and enforced by
``autoapply.db.transition``; it is re-exported here for convenience.

This module also holds the machinery shared by the scripted (Playwright) adapters:

* :class:`BrowserSession` + :func:`open_session` / :func:`close_session` — one Chromium
  page per application, kept on ``ctx.extra`` between ``fill`` and ``submit`` (the pipeline
  calls them back to back on the same context). Sessions idle for longer than
  :data:`SESSION_MAX_IDLE` are reaped; :func:`close_all_sessions` at daemon shutdown.
* :func:`scan_form` — DOM scan of the application form -> ``FormQuestion`` + a locator key.
* :func:`fill_control` — deterministic filling per control kind (text, select, radio,
  checkbox, file, react-style combobox, Ashby yes/no buttons).
* :class:`AnswerLedger` — reuses answers already recorded for the application (the user may
  have edited them in Review) and records new ones exactly once.
* :class:`ScriptedFormAdapter` — the fill/submit algorithm; ATS adapters subclass it.
* :func:`run_application` — the shared runner (state machine walk) for the CLI / tests:
  queued -> filling -> needs_you | awaiting_review | (guardrail) submitting -> submitted |
  unknown_verify, honouring pause between steps and dry-run.

Safety: ``dry_run`` (``ctx.dry_run`` or ``ctx.extra["dry_run"]``) fills but never clicks.
If ``AUTOAPPLY_SUBMIT_ALLOWED_HOSTS`` is set (comma-separated hostnames), ``submit`` refuses
to click on any other host — tests set it to localhost so a real ATS can never be submitted.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sqlite3
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any, Protocol, runtime_checkable
from urllib.parse import urlsplit

from autoapply.config import NeverGuess, Preferences
from autoapply.enums import AnswerOrigin, AppState, Ats, FieldType, Mode, QuestionReason
from autoapply.llm.provider import LLMProvider
from autoapply.models import (  # noqa: F401  (re-exports)
    ALLOWED_TRANSITIONS,
    USER_ONLY_TRANSITIONS,
    AgentStepPayload,
    Application,
    FormQuestion,
    Job,
    Profile,
    ResumeVariant,
    is_allowed_transition,
)

if TYPE_CHECKING:  # pragma: no cover
    from playwright.async_api import Browser, BrowserContext, Page, Playwright

log = logging.getLogger("autoapply.apply")

#: Emits a protocol event, e.g. ``await emit("agent_step", AgentStepPayload(...))``.
EmitFn = Callable[[str, Any], Awaitable[None]]


class PausedError(Exception):
    """Raised by ``ApplyContext.check_pause`` when the kill switch is on."""


@dataclass(slots=True)
class ApplyContext:
    conn: sqlite3.Connection
    application: Application
    job: Job
    profile: Profile
    never_guess: NeverGuess
    preferences: Preferences
    llm: LLMProvider
    resume: ResumeVariant | None
    screenshots_dir: Path
    emit: EmitFn
    is_paused: Callable[[], bool] = lambda: False
    headless: bool = True
    run_id: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)
    #: Fill but never click submit (``ctx.extra["dry_run"]`` is honoured too). In dry-run
    #: nothing is written to ``application_answers``.
    dry_run: bool = False

    def check_pause(self) -> None:
        """Call between every step (PLAN.md §5 Guardrails: pause_all checked between steps)."""
        if self.is_paused():
            raise PausedError("paused by user")

    @property
    def is_dry_run(self) -> bool:
        return bool(self.dry_run or self.extra.get("dry_run"))


@dataclass(slots=True)
class UnresolvedField:
    """A form field the adapter could not answer confidently -> Needs-You inbox."""

    question: FormQuestion
    reason: str  # QuestionReason value: unknown | never_guess | low_confidence | captcha | always_ask
    never_guess_key: str | None = None
    suggested_answer: str | None = None
    confidence: float | None = None


@dataclass(slots=True)
class RecordedAnswer:
    """One answer the adapter put into the form (also returned in dry-run)."""

    key: str
    question: str
    answer: str
    origin: AnswerOrigin
    field_type: FieldType = FieldType.TEXT
    confidence: float | None = None
    origin_ref: str | None = None
    reused: bool = False  # came from an earlier recorded / user-edited answer


@dataclass(slots=True)
class FillResult:
    ok: bool
    unresolved: list[UnresolvedField] = field(default_factory=list)
    screenshot_path: str | None = None
    cover_letter_path: str | None = None
    error: str | None = None
    answers: list[RecordedAnswer] = field(default_factory=list)


@dataclass(slots=True)
class SubmitResult:
    verified: bool  # confirmation page detected
    confirmation_screenshot_path: str | None = None
    error: str | None = None
    #: False when submit returned WITHOUT clicking (dry-run, refused host, form invalid
    #: before the click). Pipelines may treat that as "definitely not sent".
    clicked: bool = True


@runtime_checkable
class Adapter(Protocol):
    ats: Ats

    def can_handle(self, job: Job) -> bool:
        """True if this adapter can apply to ``job`` (by ATS / URL shape)."""
        ...

    async def harvest_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        """All questions on the application form (API for GH/Lever/Ashby, browser scan
        otherwise). Used by the Prep pass. Must not modify anything remotely."""
        ...

    async def fill(self, ctx: ApplyContext) -> FillResult:
        """Fill every field, upload resume / cover letter, record Q&A + screenshot.
        MUST NOT submit."""
        ...

    async def submit(self, ctx: ApplyContext) -> SubmitResult:
        """Click submit exactly once (only after ``db.begin_submit``) and verify."""
        ...


def select_adapter(job: Job, adapters: list[Adapter]) -> Adapter | None:
    """First adapter whose ``can_handle`` accepts the job (scripted before agentic)."""
    for a in adapters:
        if a.can_handle(job):
            return a
    return None


def scripted_adapters() -> list[Adapter]:
    """The scripted adapters in priority order (agentic fallback is appended by callers)."""
    from autoapply.apply.ashby import AshbyAdapter
    from autoapply.apply.greenhouse import GreenhouseAdapter
    from autoapply.apply.lever import LeverAdapter

    return [GreenhouseAdapter(), LeverAdapter(), AshbyAdapter()]


# =====================================================================================
# Answer resolution seam (implemented by workstream B: answers.resolver.AnswerResolver)
# =====================================================================================


@runtime_checkable
class AnswerResolverLike(Protocol):
    """What the scripted adapters need from an answer resolver.

    ``resolve`` returns an object with ``question``, ``answer``, ``origin``,
    ``confidence``, ``origin_ref``, ``action`` (``upload_resume`` | ``cover_letter`` |
    ``skip`` | None) and ``never_guess_key`` — or raises
    ``autoapply.answers.guardrails.NeedsUser``. ``record`` writes the audit row.
    """

    async def resolve(self, question: FormQuestion) -> Any: ...

    def record(self, application_id: int, resolved: Any, *, answer_override: str | None = None) -> None: ...


def make_resolver(ctx: ApplyContext) -> AnswerResolverLike:
    """``ctx.extra["resolver"]`` (tests / custom) or B's ``AnswerResolver.from_context``."""
    custom = ctx.extra.get("resolver")
    if custom is not None:
        return custom
    from autoapply.answers.resolver import AnswerResolver

    return AnswerResolver.from_context(ctx)


# =====================================================================================
# Standard (deterministic) fields
# =====================================================================================

_STD_KEYS: dict[str, str] = {
    # Greenhouse
    "first_name": "first_name", "last_name": "last_name", "email": "email", "phone": "phone",
    "resume": "resume", "cover_letter": "cover_letter",
    # Lever
    "name": "full_name", "org": "current_company", "location": "location",
    "urls[linkedin]": "linkedin", "urls[github]": "github", "urls[portfolio]": "portfolio",
    "urls[website]": "portfolio", "urls[twitter]": "twitter",
    # Ashby
    "_systemfield_name": "full_name", "_systemfield_email": "email", "_systemfield_phone": "phone",
    "_systemfield_resume": "resume", "_systemfield_location": "location", "_systemfield_linkedin": "linkedin",
    "_systemfield_cover_letter": "cover_letter",
}
_STD_LABELS: list[tuple[str, re.Pattern[str]]] = [
    ("first_name", re.compile(r"^(legal )?first name|^given name|^preferred first name")),
    ("last_name", re.compile(r"^(legal )?last name|^surname|^family name")),
    ("full_name", re.compile(r"^(full |legal )?name$")),
    ("email", re.compile(r"^e-?mail( address)?$")),
    ("phone", re.compile(r"^(phone|mobile|telephone)( number)?$")),
    ("resume", re.compile(r"^(resume|résumé|cv)(\s*/\s*cv)?$|^upload (your )?(resume|cv)")),
    ("cover_letter", re.compile(r"^cover letter")),
    ("linkedin", re.compile(r"^linkedin( profile| url)?$")),
    ("github", re.compile(r"^github( profile| url)?$")),
    ("portfolio", re.compile(r"^(portfolio|website|personal website)( url)?$")),
]


def standard_field(q: FormQuestion) -> str | None:
    """Map a form field to a standard profile slot by its ATS field name, then its label."""
    k = q.key.strip().lower()
    if k in _STD_KEYS:
        return _STD_KEYS[k]
    label = re.sub(r"[*✱]", "", q.label).strip().lower()
    for slot, rx in _STD_LABELS:
        if rx.search(label):
            return slot
    return None


def _split_name(profile: Profile) -> tuple[str | None, str | None]:
    first, last = profile.first_name, profile.last_name
    if (not first or not last) and profile.full_name:
        parts = profile.full_name.split()
        if len(parts) >= 2:
            first = first or parts[0]
            last = last or " ".join(parts[1:])
    return first, last


def _link(profile: Profile, *names: str) -> str | None:
    for want in names:
        for k, v in profile.links.items():
            if want in k.lower() or want in (v or "").lower():
                return v
    return None


def standard_value(slot: str, profile: Profile, resume: ResumeVariant | None) -> tuple[str, AnswerOrigin, str] | None:
    """``(value, origin, origin_ref)`` for a standard slot, or None if the profile lacks it."""
    first, last = _split_name(profile)
    current = next((w for w in profile.work_history if not w.end or str(w.end).lower() in ("present", "current")), None)
    values: dict[str, str | None] = {
        "first_name": first,
        "last_name": last,
        "full_name": profile.full_name or (f"{first} {last}" if first and last else None),
        "email": profile.email,
        "phone": profile.phone,
        "location": profile.location,
        "linkedin": _link(profile, "linkedin"),
        "github": _link(profile, "github"),
        "portfolio": _link(profile, "portfolio", "website", "personal", "site"),
        "twitter": _link(profile, "twitter", "x.com"),
        "current_company": current.company if current else None,
    }
    if slot == "resume":
        if resume is None:
            return None
        return resume.file_path, AnswerOrigin.CV, f"resume_variants:{resume.id}"
    if slot == "cover_letter":
        return None  # generated by the adapter
    v = values.get(slot)
    if v is None or not str(v).strip():
        return None
    return str(v).strip(), AnswerOrigin.PROFILE, f"profile:{slot}"


# =====================================================================================
# Answer ledger (Q&A audit rows, reused across re-fills)
# =====================================================================================


class AnswerLedger:
    """Tracks answers for one application.

    Existing ``application_answers`` rows (by ``field_key``) are REUSED on a re-fill —
    after a Review edit (origin ``user``), an inbox answer, or a re-fill at submit time —
    so the form gets exactly what the user approved and no duplicate audit rows appear.
    """

    def __init__(self, conn: sqlite3.Connection, application_id: int, *, persist: bool = True) -> None:
        from autoapply import db

        self.conn = conn
        self.application_id = application_id
        self.persist = persist
        self.answers: list[RecordedAnswer] = []
        self._existing = {a.field_key: a for a in db.list_application_answers(conn, application_id) if a.field_key}

    def existing(self, key: str) -> RecordedAnswer | None:
        a = self._existing.get(key)
        if a is None:
            return None
        return RecordedAnswer(
            key=key, question=a.question, answer=a.answer, origin=a.origin, field_type=a.field_type,
            confidence=a.confidence, origin_ref=a.origin_ref, reused=True,
        )

    def record(
        self,
        q: FormQuestion,
        answer: str,
        origin: AnswerOrigin,
        *,
        confidence: float | None = None,
        origin_ref: str | None = None,
        resolved: Any = None,
        resolver: AnswerResolverLike | None = None,
        reused: bool = False,
    ) -> RecordedAnswer:
        from autoapply import db

        ra = RecordedAnswer(
            key=q.key, question=q.label, answer=answer, origin=AnswerOrigin(origin), field_type=q.field_type,
            confidence=confidence, origin_ref=origin_ref, reused=reused,
        )
        self.answers.append(ra)
        old = self._existing.get(q.key)
        if self.persist and not reused and old is not None and old.answer != answer and old.origin is not AnswerOrigin.USER:
            # A refreshed value (profile fix, new cover letter…) replaces the audit row, so the app shows
            # what was actually put on the form.
            with db.transaction(self.conn):
                self.conn.execute(
                    "UPDATE application_answers SET answer = ?, origin = ?, origin_ref = ?, confidence = ?, updated_at = ? WHERE id = ?",
                    (answer, AnswerOrigin(origin).value, origin_ref, confidence, db.now_ts(), old.id),
                )
            return ra
        if self.persist and not reused and q.key not in self._existing:
            if resolved is not None and resolver is not None:
                resolver.record(self.application_id, resolved, answer_override=answer)
            else:
                db.add_application_answer(
                    self.conn, self.application_id, question=q.label, answer=answer, origin=origin,
                    field_type=q.field_type, confidence=confidence, field_key=q.key, origin_ref=origin_ref,
                )
        return ra

    def discard(self, keys: set[str]) -> int:
        """Delete the persisted non-user rows for ``keys`` (answers the pre-submit audit
        rejected) so a later fill re-resolves them. Returns how many rows were removed."""
        if not self.persist or not keys:
            return 0
        from autoapply import db

        removed = 0
        for key in sorted(keys):
            n = db.delete_application_answers(self.conn, self.application_id, [key], keep_origins=(AnswerOrigin.USER,))
            removed += n
            if n:
                self._existing.pop(key, None)
        return removed


# =====================================================================================
# Browser sessions
# =====================================================================================

SESSION_KEY = "_browser_session"
SESSION_MAX_IDLE = 180.0  # seconds
_OPEN_SESSIONS: dict[int, BrowserSession] = {}


@dataclass(slots=True)
class BrowserSession:
    application_id: int
    page: Page
    context: BrowserContext
    browser: Browser | None = None  # owned (closed with the session) when not shared
    playwright: Playwright | None = None  # owned when not shared
    last_used: float = field(default_factory=time.monotonic)
    form_url: str | None = None
    filled: bool = False
    kinds: dict[str, str] = field(default_factory=dict)  # field key -> control kind
    #: Form-POST navigations are aborted unless ``submit()`` armed this (fill can never submit).
    allow_submit: bool = False
    blocked_submits: int = 0

    def touch(self) -> None:
        self.last_used = time.monotonic()

    async def close(self) -> None:
        for closer in (self.context.close, getattr(self.browser, "close", None), getattr(self.playwright, "stop", None)):
            if closer is None:
                continue
            try:
                await closer()
            except Exception:  # noqa: BLE001 - best effort
                pass
        _OPEN_SESSIONS.pop(self.application_id, None)


async def reap_idle_sessions(max_idle: float = SESSION_MAX_IDLE) -> int:
    """Close sessions nobody used for ``max_idle`` seconds (e.g. fill happened but the
    submit gate blocked, so ``submit`` was never called). Returns how many were closed."""
    now = time.monotonic()
    stale = [s for s in list(_OPEN_SESSIONS.values()) if now - s.last_used > max_idle]
    for s in stale:
        await s.close()
    return len(stale)


async def close_all_sessions() -> None:
    """Close every open adapter browser (daemon shutdown)."""
    for s in list(_OPEN_SESSIONS.values()):
        await s.close()


_SUBMITLIKE_RE = re.compile(r"submit|apply|application", re.I)
#: Same-origin XHR/fetch POSTs that widgets make while filling (resume upload/parse,
#: location autocomplete, ...). Never treated as a submission.
_GQL_OPNAME_RE = re.compile(r'"operationName"\s*:\s*"([^"]*)"')
_BENIGN_XHR_RE = re.compile(r"upload|presign|parse|attachment|file|autocomplete|location|geo|validat|track|analytic|telemetry|\blog", re.I)


def _is_stray_submit(request: Any, page_url: str) -> bool:
    """True for a request that would send the application while ``submit()`` hasn't armed it.

    * any non-GET navigation (a native ``<form>`` POST), and
    * a non-GET ``fetch``/``xhr`` to the page's own origin that looks like a submission
      (React ATS forms — Ashby, newer Greenhouse — submit via fetch in onSubmit), unless it
      is a known benign widget call (upload / parse / autocomplete ...).
    """
    method = (request.method or "GET").upper()
    if method in ("GET", "HEAD", "OPTIONS"):
        return False
    try:
        if request.is_navigation_request():
            return True
    except Exception:  # noqa: BLE001 - be conservative
        return True
    if request.resource_type not in ("fetch", "xhr"):
        return False
    req, cur = urlsplit(request.url), urlsplit(page_url or "")
    if (req.scheme, req.netloc) != (cur.scheme, cur.netloc):
        return False  # cross-origin (S3 uploads, analytics): not the ATS submit endpoint
    target = f"{req.path}?{req.query}"
    if _BENIGN_XHR_RE.search(target):
        return False
    if _SUBMITLIKE_RE.search(target):
        return True
    try:
        body = request.post_data or ""
    except Exception:  # noqa: BLE001 - binary body
        body = ""
    # GraphQL-style endpoints carry the operation name in the JSON body.
    m = _GQL_OPNAME_RE.search(body[:4000])
    return bool(m and _SUBMITLIKE_RE.search(m.group(1)) and not _BENIGN_XHR_RE.search(m.group(1)))


async def open_session(ctx: ApplyContext) -> BrowserSession:
    """Return the live session on ``ctx`` or start a new Chromium page.

    ``ctx.extra["browser"]`` (a Playwright ``Browser``) is used when given (shared, not
    closed with the session) — tests use this to avoid relaunching Chromium.
    """
    existing: BrowserSession | None = ctx.extra.get(SESSION_KEY)
    if existing is not None and not existing.page.is_closed():
        existing.touch()
        return existing
    await reap_idle_sessions()
    # A session left over from an earlier ctx for the same application (e.g. fill kept it
    # open, then the submit gate blocked and the job was re-queued) would otherwise be
    # dropped from the registry below and leak a whole Chromium until the daemon exits.
    stale = _OPEN_SESSIONS.get(ctx.application.id)
    if stale is not None:
        await stale.close()
    shared: Browser | None = ctx.extra.get("browser")
    pw = None
    browser = shared
    if browser is None:
        from playwright.async_api import async_playwright

        pw = await async_playwright().start()
        browser = await pw.chromium.launch(headless=ctx.headless)
    context = await browser.new_context(viewport={"width": 1280, "height": 900}, locale="en-US")
    context.set_default_timeout(float(ctx.extra.get("timeout_ms", 15_000)))
    page = await context.new_page()
    session = BrowserSession(
        application_id=ctx.application.id, page=page, context=context,
        browser=None if shared is not None else browser, playwright=pw,
    )

    async def _submit_guard(route: Any, request: Any) -> None:
        if not session.allow_submit and _is_stray_submit(request, page.url):
            session.blocked_submits += 1
            log.warning("blocked a form submission outside submit(): %s %s", request.method, request.url)
            await route.abort()
            return
        await route.continue_()

    await page.route("**/*", _submit_guard)
    ctx.extra[SESSION_KEY] = session
    _OPEN_SESSIONS[ctx.application.id] = session
    return session


async def close_session(ctx: ApplyContext) -> None:
    session: BrowserSession | None = ctx.extra.pop(SESSION_KEY, None)
    if session is not None:
        await session.close()


async def wait_for_captcha_clear(page: Page, timeout_s: float, ctx: ApplyContext) -> bool:
    """Bring the (visible) window forward and poll until the CAPTCHA is solved."""
    try:
        await page.bring_to_front()
    except Exception:  # noqa: BLE001
        pass
    deadline = asyncio.get_running_loop().time() + timeout_s
    while asyncio.get_running_loop().time() < deadline:
        ctx.check_pause()
        if not await visible_captcha(page):
            await asyncio.sleep(1.0)  # let the widget finish its callback
            return True
        await asyncio.sleep(2.0)
    return False


async def wait_for_fields(page: Page, timeout_s: float = 20.0) -> int:
    """React ATS forms (Ashby, new Greenhouse) render their fields seconds after the page is
    "idle": wait until visible fields exist and their count stops changing. Returns the count."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout_s
    last, stable = -1, 0
    while loop.time() < deadline:
        try:
            n = await page.locator("input:not([type=hidden]), textarea, select").count()
        except Exception:  # noqa: BLE001 - mid-navigation
            n = 0
        if n > 0 and n == last:
            stable += 1
            if stable >= 2:
                return n
        else:
            stable = 0
        last = n
        await asyncio.sleep(0.5)
    return max(last, 0)


_INTERNAL_PREFIX = re.compile(r"^[0-9a-f]{6,12}_")


def presentable_upload(path: Path) -> Path:
    """The recruiter sees the uploaded file name: stored copies are named "<id>_<original>", so
    upload a copy under the original name ("Jane_Doe_CV.pdf", not "a0037925_Jane_Doe_CV.pdf")."""
    clean = _INTERNAL_PREFIX.sub("", path.name)
    if clean == path.name or not clean:
        return path
    import hashlib
    import shutil
    import tempfile

    folder = Path(tempfile.gettempdir()) / "autoapply-uploads" / hashlib.sha1(str(path).encode()).hexdigest()[:10]
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / clean
    if not target.exists() or target.stat().st_mtime < path.stat().st_mtime:
        shutil.copy2(path, target)
    return target


async def wait_for_upload(page: Page, name: str, input_loc: Any = None, timeout_s: float = 30.0) -> bool:
    """React ATS forms upload the file to storage in the background (a progress bar first, the
    file name when done). Submitting before that sends the application without it. A plain
    ``<input type=file>`` that still holds the file with nothing uploading is done at once."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout_s
    stem = Path(name).stem[:40]
    await asyncio.sleep(0.3)
    if input_loc is not None:
        try:
            held = await input_loc.evaluate("el => el.isConnected && el.files && el.files.length > 0")
            busy = await page.locator("[role=progressbar]:visible, progress:visible").count()
            if held and not busy:
                return True
        except Exception:  # noqa: BLE001 - the widget replaced the input: wait below
            pass
    while loop.time() < deadline:
        try:
            text = await page.evaluate("() => document.body ? document.body.innerText : ''")
            busy = await page.locator("[role=progressbar]:visible, progress:visible, [class*=progress]:visible").count()
        except Exception:  # noqa: BLE001
            text, busy = "", 0
        if stem and stem in text and not busy:
            return True
        await asyncio.sleep(0.5)
    log.warning("upload of %s did not visibly finish within %.0fs", name, timeout_s)
    return False


# =====================================================================================
# DOM scan + filling
# =====================================================================================

#: JS run in the page: finds the application form, tags every control with
#: ``data-aa-key`` and returns one descriptor per question (radio/checkbox groups merged).
_SCAN_JS = r"""
(root) => {
  const forms = Array.from(document.querySelectorAll('form'));
  let scope = root ? document.querySelector(root) : null;
  if (!scope) {
    scope = forms.sort((a, b) => b.querySelectorAll('input,select,textarea').length - a.querySelectorAll('input,select,textarea').length)[0] || document.body;
  }
  const clean = (t) => (t || '').replace(/\s+/g, ' ').replace(/[*✱]/g, '').trim();
  const textOf = (el) => {
    if (!el) return '';
    const c = el.cloneNode(true);
    c.querySelectorAll('input,select,textarea,button,option,ul[role=listbox],[aria-hidden=true],.visually-hidden-required').forEach(n => n.remove());
    return clean(c.textContent);
  };
  const labelFor = (el) => {
    if (el.id) {
      const l = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (l && textOf(l)) return textOf(l);
    }
    const wrap = el.closest('label');
    if (wrap && textOf(wrap)) return textOf(wrap);
    if (el.getAttribute('aria-labelledby')) {
      const t = el.getAttribute('aria-labelledby').split(/\s+/).map(id => textOf(document.getElementById(id))).join(' ');
      if (clean(t)) return clean(t);
    }
    if (el.getAttribute('aria-label')) return clean(el.getAttribute('aria-label'));
    const box = el.closest('.application-question, .field, .form-field, fieldset, [class*="question"], [class*="field-entry"], [class*="Field"]');
    if (box) {
      const head = box.querySelector('legend, label, .application-label, .text, [class*="label"], [class*="title"]');
      if (head && textOf(head)) return textOf(head);
    }
    return clean(el.getAttribute('placeholder') || el.name || el.id || '');
  };
  const groupLabel = (el) => {
    const box = el.closest('fieldset, .application-question, .field, [role=radiogroup], [role=group], [class*="question"], [class*="field-entry"]');
    if (box) {
      const head = box.querySelector('legend, .application-label, [class*="label"]:not(label[for]), .text');
      if (head && textOf(head)) return textOf(head);
      const lab = Array.from(box.querySelectorAll('label')).find(l => !l.contains(box.querySelector('input')) && !l.querySelector('input'));
      if (lab && textOf(lab)) return textOf(lab);
    }
    return clean(el.name);
  };
  const isRequired = (el, label) => {
    if (el.required || el.getAttribute('aria-required') === 'true') return true;
    const box = el.closest('.application-question, .field, fieldset, [class*="question"], [class*="field-entry"]');
    if (box && box.querySelector('[class*="_required"], label.required, .required, [aria-required=true]')) return true;
    const raw = box ? box.textContent : (label || '');
    return /[*✱]|\(required\)/i.test(raw.slice(0, 400)) && !/optional/i.test((label||''));
  };
  const visible = (el) => {
    if (el.type === 'file') return true;  // file inputs are usually hidden behind a button
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden') {
      // react-select style: the real value input is hidden; skip it
      return false;
    }
    return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  };
  const out = [];
  const seenGroups = new Set();
  let n = 0;
  const controls = scope.querySelectorAll('input, select, textarea');
  for (const el of controls) {
    const type = (el.getAttribute('type') || el.tagName).toLowerCase();
    if (['hidden', 'submit', 'button', 'reset', 'image', 'search'].includes(type)) continue;
    if (el.disabled || el.closest('[data-aa-ignore]')) continue;
    if (type !== 'radio' && type !== 'checkbox' && !visible(el)) continue;
    const name = el.getAttribute('name') || '';
    // react-select's anonymous "required" shadow input (opacity 0, tabindex -1) backs a
    // combobox that is scanned separately; it can't be typed into.
    if (!name && !el.id && type !== 'file' && (el.getAttribute('aria-hidden') === 'true' || el.tabIndex === -1
        || parseFloat(getComputedStyle(el).opacity) === 0)) continue;
    if (type === 'radio' || type === 'checkbox') {
      const group = name ? Array.from(scope.querySelectorAll(`input[name="${CSS.escape(name)}"]`)) : [el];
      const gkey = name || el.id || ('aa_' + (n++));
      if (seenGroups.has(gkey)) continue;
      seenGroups.add(gkey);
      if (type === 'checkbox' && group.length === 1) {
        el.setAttribute('data-aa-key', gkey);
        const label = labelFor(el);
        out.push({key: gkey, label, kind: 'checkbox', type: 'boolean', required: isRequired(el, label), options: [], maxLength: null});
        continue;
      }
      const options = group.map(r => labelFor(r) || r.value);
      group.forEach(r => r.setAttribute('data-aa-key', gkey));
      const label = groupLabel(el);
      out.push({key: gkey, label, kind: type === 'radio' ? 'radio' : 'checkbox_group', type: type === 'radio' ? 'select' : 'multiselect',
                required: group.some(r => r.required) || isRequired(el, label), options, maxLength: null});
      continue;
    }
    const key = name || el.id || ('aa_' + (n++));
    el.setAttribute('data-aa-key', key);
    const label = labelFor(el);
    let kind = 'text', ftype = 'text', options = [];
    if (el.tagName === 'SELECT') {
      kind = 'select'; ftype = el.multiple ? 'multiselect' : 'select';
      options = Array.from(el.options).filter(o => o.value !== '' && !/^(select|choose|please select)/i.test(o.textContent.trim())).map(o => o.textContent.trim());
    } else if (el.tagName === 'TEXTAREA') { kind = 'text'; ftype = 'textarea'; }
    else if (el.getAttribute('role') === 'combobox' || el.getAttribute('aria-autocomplete') === 'list') { kind = 'combobox'; ftype = 'select';
      const lb = el.getAttribute('aria-controls') && document.getElementById(el.getAttribute('aria-controls'));
      if (lb) options = Array.from(lb.querySelectorAll('[role=option]')).map(o => o.textContent.trim());
      if (!options.length) ftype = 'text';
    }
    else if (type === 'file') { kind = 'file'; ftype = 'file'; }
    else if (type === 'email') ftype = 'email';
    else if (type === 'tel') ftype = 'phone';
    else if (type === 'url') ftype = 'url';
    else if (type === 'number') ftype = 'number';
    else if (type === 'date') ftype = 'date';
    const ml = el.maxLength && el.maxLength > 0 && el.maxLength < 100000 ? el.maxLength : null;
    out.push({key, label, kind, type: ftype, required: isRequired(el, label), options, maxLength: ml});
  }
  // Ashby-style yes/no button pairs
  scope.querySelectorAll('[class*="yesno"], [data-yesno]').forEach((box) => {
    const buttons = Array.from(box.querySelectorAll('button'));
    if (buttons.length < 2) return;
    const entry = box.closest('[class*="field-entry"], .field, fieldset, [class*="question"]') || box.parentElement;
    const head = entry && entry.querySelector('label, legend, [class*="label"]');
    const label = head ? textOf(head) : '';
    const hidden = entry && entry.querySelector('input[type=hidden][name], input[name]');
    const key = (hidden && hidden.name) || box.id || ('aa_yesno_' + (n++));
    box.setAttribute('data-aa-key', key);
    out.push({key, label, kind: 'yesno', type: 'boolean', required: isRequired(box, label), options: buttons.map(b => b.textContent.trim()), maxLength: null});
  });
  return out;
}
"""

_KIND_TYPES = {t.value: t for t in FieldType}


async def scan_form(page: Page, root_selector: str | None = None) -> tuple[list[FormQuestion], dict[str, str]]:
    """Scan the (largest) form on the page. Returns ``(questions, kinds)`` where ``kinds``
    maps question key -> control kind used by :func:`fill_control`."""
    raw = await page.evaluate(_SCAN_JS, root_selector)
    questions: list[FormQuestion] = []
    kinds: dict[str, str] = {}
    for f in raw:
        key = f["key"]
        if key in kinds:
            continue
        kinds[key] = f["kind"]
        label = f["label"] or key
        questions.append(
            FormQuestion(
                key=key, label=label, field_type=_KIND_TYPES.get(f["type"], FieldType.TEXT),
                required=bool(f["required"]), options=[o for o in f["options"] if o], max_length=f.get("maxLength"),
            )
        )
    return questions, kinds


def _locator(page: Page, key: str):
    return page.locator(f"[data-aa-key={json.dumps(key)}]")


_LABEL_JS = (
    "el => { const l = (el.id && document.querySelector(`label[for=\"${CSS.escape(el.id)}\"]`)) || el.closest('label');"
    " return (l ? l.textContent : (el.value || '')).replace(/\\s+/g, ' ').trim(); }"
)


async def _control_label(item: Any) -> str:
    return str(await item.evaluate(_LABEL_JS))


_TRUTHY = re.compile(r"^\s*(yes|y|true|1|on|checked|agree|i agree|accept|i accept|i confirm|confirm)\b", re.I)


def match_option(value: str, options: list[str]) -> str | None:
    """The option (verbatim) matching ``value``; B's matcher when available.

    B's ``None`` is authoritative (ambiguous / decline-with-no-decline-option): it is never
    overridden. The local fallback runs only when B's module is unavailable or raises, and
    accepts exact or unique whole-word matches only.
    """
    try:
        from autoapply.answers.textnorm import match_option as _mo
    except Exception:  # noqa: BLE001 - B's module unavailable: strict fallback below
        _mo = None
    if _mo is not None:
        try:
            return _mo(value, options)
        except Exception as e:  # noqa: BLE001 - B's matcher failing: strict fallback below
            log.warning("textnorm.match_option failed (%s); using strict fallback", e)
    return _strict_match_option(value, options)


def _strict_match_option(value: str, options: list[str]) -> str | None:
    def norm(t: str) -> str:
        return re.sub(r"\s+", " ", t).strip().lower()

    v = norm(value or "")
    if not v:
        return None
    for o in options:
        if norm(o) == v:
            return o

    def word_in(needle: str, hay: str) -> bool:
        return bool(needle) and re.search(rf"(?<!\w){re.escape(needle)}(?!\w)", hay) is not None

    cands = [o for o in options if word_in(v, norm(o)) or word_in(norm(o), v)]
    return cands[0] if len(cands) == 1 else None


def _autocomplete_prefix_match(value: str, options: list[str]) -> str | None:
    """A single autocomplete suggestion that extends the typed text at a word boundary
    ("San Francisco" -> "San Francisco, California, United States")."""
    if len(options) != 1:
        return None
    v = re.sub(r"\s+", " ", value or "").strip().lower()
    o = re.sub(r"\s+", " ", options[0]).strip().lower()
    if v and o.startswith(v) and (len(o) == len(v) or not o[len(v)].isalnum()):
        return options[0]
    return None


async def fill_control(page: Page, key: str, kind: str, value: str, options: list[str] | None = None) -> bool:
    """Put ``value`` into the control tagged ``data-aa-key=key``. Returns False when the
    value could not be applied (e.g. no matching option)."""
    return await fill_control_value(page, key, kind, value, options) is not None


async def fill_control_value(page: Page, key: str, kind: str, value: str, options: list[str] | None = None) -> str | None:
    """Like :func:`fill_control` but returns what was actually put into the form — the
    option text that was selected/clicked for choice controls, ``value`` otherwise — or
    None when nothing could be applied. Callers record/audit THIS, not the raw answer."""
    loc = _locator(page, key)
    options = options or []
    if kind == "file":
        if not value or not Path(value).exists():
            return None
        upload = presentable_upload(Path(value))
        await loc.first.set_input_files(str(upload))
        await wait_for_upload(page, upload.name, loc.first)
        return str(upload)  # the name the recruiter sees
    if kind == "select":
        multiple = await loc.first.evaluate("el => el.multiple")
        if multiple:
            wanted = [match_option(v.strip(), options) for v in re.split(r"[;\n]|,(?=\s*[A-Z])", value) if v.strip()]
            labels = [w for w in wanted if w]
            if not labels:
                return None
            await loc.first.select_option(label=labels)
            return "; ".join(labels)
        opt = match_option(value, options) if options else value
        if opt is None:
            return None
        await loc.first.select_option(label=opt)
        return opt
    if kind in ("radio", "checkbox_group"):
        items = await loc.all()
        labels = [await _control_label(item) for item in items]
        if kind == "radio":
            target = match_option(value, labels)
            if target is None:
                return None
            await items[labels.index(target)].check()
            return target
        wanted = {match_option(v.strip(), labels) for v in re.split(r"[;\n]|,(?=\s*[A-Z])", value) if v.strip()}
        wanted.discard(None)
        if not wanted:
            return None
        for item, lab in zip(items, labels, strict=True):
            if lab in wanted:
                await item.check()
        return "; ".join(lab for lab in labels if lab in wanted)
    if kind == "checkbox":
        if _TRUTHY.match(value or ""):
            await loc.first.check()
        else:
            await loc.first.uncheck()
        return value
    if kind == "yesno":
        target = (match_option(value, options) if options else None) or value
        btn = loc.first.locator("button", has_text=re.compile(rf"^\s*{re.escape(target)}\s*$", re.I))
        if await btn.count() == 0:
            return None
        await btn.first.click()
        return target
    if kind == "combobox":
        # NEVER press Enter here: inside a <form> it can submit the application.
        el = loc.first
        await el.click()
        await el.fill("")
        await el.type(value[:60], delay=10)
        listbox_id = await el.get_attribute("aria-controls") or await el.get_attribute("aria-owns")
        scope = f"#{listbox_id} " if listbox_id and re.fullmatch(r"[A-Za-z][\w\-:.]*", listbox_id) else ""
        opt_loc = page.locator(f"{scope}[role=option]:visible")
        try:
            # Location pickers geocode as you type: their suggestions can take a few seconds.
            await opt_loc.first.wait_for(state="visible", timeout=6000)
        except Exception:  # noqa: BLE001 - no visible suggestion
            # A real listbox with no matching suggestion: nothing was selected (the typed
            # text is not the answer). Only a free-text combobox keeps the typed text.
            has_listbox = bool(scope) and await page.locator(f"#{listbox_id}").count() > 0
            if has_listbox:
                await el.press("Escape")
                return None
            await el.press("Tab")
            return value
        texts = [t.strip() for t in await opt_loc.all_inner_texts()]
        # Only click a suggestion that actually matches the answer — never "the only one".
        target = _head_match(value, texts) or match_option(value, texts) or _autocomplete_prefix_match(value, texts)
        if target is None:
            await el.press("Escape")
            return None
        await opt_loc.nth(texts.index(target)).click()
        return target
    # text-like
    await loc.first.fill(value)
    return value


def _head_match(value: str, texts: list[str]) -> str | None:
    """Option whose leading part equals the answer: "India +91" for "India" (not "British Indian
    Ocean Territory"), "Bangalore, Karnataka, India" for "Bangalore" (the first such suggestion is the
    picker's best match)."""
    want = value.strip().lower()
    if not want:
        return None
    for t in texts:
        head = re.sub(r"\s*\+\d[\d\s-]*$", "", t).strip().lower()  # trailing phone code
        if head == want or head.split(",")[0].strip() == want or head.split(" (")[0].strip() == want:
            return t
    return None


# =====================================================================================
# Confirmation / captcha detection
# =====================================================================================

_DEFAULT_CONFIRM_TEXT = re.compile(
    # NB: no "thank you for your interest" — job descriptions shown above the form end with it.
    r"thank(s| you) for (applying|your application|submitting)|application (has been |was )?(successfully )?(submitted|received)"
    r"|we('ve| have) received your application|your application (is|has been) (in|submitted|received)",
    re.I,
)
_VALIDATION_SELECTORS = (
    "[aria-invalid=true]", ".error:not(:empty)", ".field-error:not(:empty)", ".error-message:not(:empty)",
    "[class*='errorMessage']:not(:empty)", "[role=alert]:not(:empty)",
)
_CAPTCHA_SELECTORS = (
    "iframe[src*='hcaptcha.com'][src*='checkbox']", "iframe[src*='recaptcha/api2/anchor']:not([src*='size=invisible'])",
    "iframe[src*='recaptcha/api2/bframe']", "iframe[src*='challenges.cloudflare.com']", ".cf-turnstile", "[data-aa-captcha]",
)


async def visible_captcha(page: Page) -> bool:
    """True when a CAPTCHA widget or challenge is VISIBLE (invisible reCAPTCHA v3 badges,
    present on most Greenhouse pages, don't count)."""
    for sel in _CAPTCHA_SELECTORS:
        loc = page.locator(sel)
        try:
            for i in range(await loc.count()):
                box = await loc.nth(i).bounding_box()
                if box and box["width"] > 30 and box["height"] > 30 and await loc.nth(i).is_visible():
                    return True
        except Exception:  # noqa: BLE001
            continue
    return False


async def validation_errors(page: Page) -> list[str]:
    msgs: list[str] = []
    for sel in _VALIDATION_SELECTORS:
        loc = page.locator(sel)
        try:
            for i in range(min(await loc.count(), 10)):
                item = loc.nth(i)
                if not await item.is_visible():
                    continue
                txt = (await item.inner_text()).strip() if sel != "[aria-invalid=true]" else (await item.get_attribute("name") or "invalid field")
                if txt:
                    msgs.append(txt[:120])
        except Exception:  # noqa: BLE001
            continue
    return list(dict.fromkeys(msgs))


def _host_allowed(url: str) -> bool:
    allowed = os.environ.get("AUTOAPPLY_SUBMIT_ALLOWED_HOSTS")
    if not allowed:
        return True
    host = (urlsplit(url).hostname or "").lower()
    return host in {h.strip().lower() for h in allowed.split(",") if h.strip()}


def _ts_slug() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%S%f")[:-3]


async def emit_step(ctx: ApplyContext, index: int, action: str, *, total: int | None = None,
                    detail: str | None = None, confidence: float | None = None) -> None:
    """Best-effort ``agent_step`` event (an observer failure never breaks applying)."""
    try:
        payload = AgentStepPayload(
            application_id=ctx.application.id, job_id=ctx.job.id, run_id=ctx.run_id, index=index, total=total,
            action=action[:200], detail=(detail or None) and detail[:500],
            confidence=None if confidence is None else max(0.0, min(1.0, float(confidence))), at=datetime.now(UTC),
        )
        thumb = await _page_thumb(ctx)
        if thumb:
            payload.screenshot_thumb = thumb
        await ctx.emit("agent_step", payload)
    except Exception:  # noqa: BLE001
        log.debug("agent_step emit failed", exc_info=True)


async def _page_thumb(ctx: ApplyContext) -> str | None:
    """Throttled live frame of the application page for the app's Live Agent view."""
    from autoapply.thumbs import Throttle, thumb_from_bytes

    session: BrowserSession | None = ctx.extra.get(SESSION_KEY)
    if session is None or session.page.is_closed():
        return None
    throttle: Throttle = ctx.extra.setdefault("_thumb_throttle", Throttle())
    if not throttle.ready():
        return None
    try:
        data = await session.page.screenshot(type="jpeg", quality=60, timeout=3000)
    except Exception:  # noqa: BLE001
        return None
    return thumb_from_bytes(data)


# =====================================================================================
# Scripted adapter (fill / submit algorithm shared by greenhouse / lever / ashby)
# =====================================================================================


class ScriptedFormAdapter:
    """Deterministic Playwright adapter. Subclasses set ``ats``, ``hosts`` and may override
    :meth:`form_url`, :meth:`open_form`, :meth:`form_questions`, :meth:`api_questions`."""

    ats: Ats = Ats.OTHER
    hosts: tuple[str, ...] = ()
    form_selector: str | None = None
    submit_selectors: tuple[str, ...] = (
        "button[type=submit]", "input[type=submit]", "button:has-text('Submit application')", "button:has-text('Submit')",
    )
    confirm_url: re.Pattern[str] = re.compile(r"/(confirmation|thanks|thank-you|thank_you|submitted|success)\b", re.I)
    confirm_text: re.Pattern[str] = _DEFAULT_CONFIRM_TEXT
    submit_timeout_s: float = 20.0

    # ---- routing ---------------------------------------------------------------------

    def can_handle(self, job: Job) -> bool:
        if Ats(job.ats) is self.ats:
            return True
        from autoapply.discovery.base import detect_ats

        return detect_ats(job.apply_url)[0] is self.ats

    def form_url(self, ctx: ApplyContext) -> str:
        """The URL of the application form (``ctx.extra["form_url"]`` overrides)."""
        override = ctx.extra.get("form_url")
        if override:
            return str(override)
        url = ctx.job.apply_url or ctx.job.source_url
        if not url:
            raise ValueError("job has no apply_url")
        return url

    async def open_form(self, page: Page, ctx: ApplyContext) -> None:
        """Navigate to the form. Subclasses may click an 'Apply' button etc."""
        await page.goto(self.form_url(ctx), wait_until="domcontentloaded")
        try:
            await page.wait_for_load_state("networkidle", timeout=5000)
        except Exception:  # noqa: BLE001 - long-polling pages never go idle
            pass
        await wait_for_fields(page)

    async def api_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        """Questions from the ATS API (labels/options/required are cleaner than the DOM)."""
        return []

    async def form_questions(self, page: Page, ctx: ApplyContext) -> tuple[list[FormQuestion], dict[str, str]]:
        """DOM scan, enriched with API metadata (by key) when available."""
        questions, kinds = await scan_form(page, self.form_selector)
        try:
            api = {q.key: q for q in await self.api_questions(ctx)}
        except Exception as e:  # noqa: BLE001 - API metadata is optional
            log.debug("api questions unavailable: %s", e)
            api = {}
        if api:
            merged = []
            for q in questions:
                a = api.get(q.key)
                if a is not None:
                    q = q.model_copy(update={
                        "label": a.label or q.label, "required": a.required or q.required,
                        "options": q.options or a.options, "description": a.description,
                        "field_type": q.field_type if q.field_type is not FieldType.TEXT or not a.options else a.field_type,
                    })
                merged.append(q)
            questions = merged
        return questions, kinds

    # ---- Prep harvest ----------------------------------------------------------------

    async def harvest_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        try:
            api = await self.api_questions(ctx)
        except Exception as e:  # noqa: BLE001
            log.info("api harvest failed (%s); scanning the page instead", e)
            api = []
        if api:
            return api
        session = await open_session(ctx)
        try:
            await self.open_form(session.page, ctx)
            questions, _ = await self.form_questions(session.page, ctx)
            return questions
        finally:
            await close_session(ctx)

    # ---- fill ------------------------------------------------------------------------

    def _will_submit_next(self, ctx: ApplyContext) -> bool:
        if ctx.is_dry_run:
            return False
        if ctx.extra.get("approved"):
            return True
        mode = ctx.preferences.effective_mode(ctx.job.ats, ctx.job.company_id, ctx.job.mode_override)
        return mode is Mode.AUTO

    async def fill(self, ctx: ApplyContext) -> FillResult:
        ctx.check_pause()
        result = FillResult(ok=True)
        session = await open_session(ctx)
        keep_open = False
        try:
            page = session.page
            await emit_step(ctx, 0, f"opening {self.ats.value} application form")
            await self.open_form(page, ctx)
            session.form_url = page.url
            ctx.check_pause()
            if await visible_captcha(page) and ctx.extra.get("captcha_wait_s") and not ctx.headless:
                await emit_step(ctx, 0, "waiting for you to solve the CAPTCHA in the browser window")
                await wait_for_captcha_clear(page, float(ctx.extra["captcha_wait_s"]), ctx)
            if await visible_captcha(page):
                result.unresolved.append(UnresolvedField(
                    question=FormQuestion(key="__captcha__", label="Solve the CAPTCHA on this application", required=True),
                    reason=QuestionReason.CAPTCHA.value,
                ))
                return result
            questions, kinds = await self.form_questions(page, ctx)
            session.kinds = kinds
            if session.blocked_submits:
                result.ok = False
                result.error = "the form tried to submit while filling (blocked)"
                return result
            if not questions:
                result.ok = False
                result.error = "no application form found on the page"
                return result
            await self._fill_questions(ctx, page, questions, kinds, result)
            ctx.check_pause()
            if session.blocked_submits:
                result.ok = False
                result.error = "the form tried to submit while filling (blocked)"
            result.screenshot_path = await self._screenshot(page, ctx, "filled")
            session.filled = True
            await emit_step(ctx, len(questions) + 1, "captured filled form", detail=result.screenshot_path)
            keep_open = result.ok and not result.unresolved and self._will_submit_next(ctx)
            return result
        finally:
            if not keep_open:
                await close_session(ctx)
            else:
                session.touch()

    async def _fill_questions(self, ctx: ApplyContext, page: Page, questions: list[FormQuestion],
                              kinds: dict[str, str], result: FillResult) -> None:
        from autoapply.answers.guardrails import AnswerForCheck, NeedsUser, check_answers

        ledger = AnswerLedger(ctx.conn, ctx.application.id, persist=not ctx.is_dry_run)
        resolver = make_resolver(ctx)
        audit: list[tuple[AnswerForCheck, RecordedAnswer]] = []
        total = len(questions)
        for i, q in enumerate(questions, start=1):
            ctx.check_pause()
            kind = kinds.get(q.key, "text")
            value: str | None = None
            origin = AnswerOrigin.PROFILE
            confidence: float | None = 1.0
            origin_ref: str | None = None
            resolved: Any = None
            ng_key: str | None = None
            reused = False

            prior = ledger.existing(q.key)
            slot = standard_field(q)
            # Profile-derived answers (name, email, links…) always come from the CURRENT profile:
            # a value recorded by an earlier fill must not outlive a profile fix.
            if prior is not None and prior.origin is AnswerOrigin.PROFILE and slot is not None and slot != "cover_letter":
                prior = None
            if prior is not None and prior.field_type is not FieldType.FILE:
                value, origin, confidence, origin_ref, reused = prior.answer, prior.origin, prior.confidence, prior.origin_ref, True
            elif slot == "cover_letter":
                value = await self._cover_letter(ctx, q, result)
                if value is None:
                    if q.required:
                        result.unresolved.append(UnresolvedField(q, QuestionReason.UNKNOWN.value))
                    continue
                origin, confidence, origin_ref = AnswerOrigin.GENERATED, None, "cover_letter"
            elif slot is not None and (std := standard_value(slot, ctx.profile, ctx.resume)) is not None:
                value, origin, origin_ref = std
            else:
                try:
                    resolved = await resolver.resolve(q)
                except NeedsUser as nu:
                    if q.required:
                        result.unresolved.append(nu.to_unresolved())
                        await emit_step(ctx, i, f"needs you: {q.label}", total=total, detail=nu.reason.value)
                    continue
                action = getattr(resolved, "action", None)
                if action == "skip":
                    continue
                if action == "cover_letter":
                    value = await self._cover_letter(ctx, q, result)
                    if value is None:
                        if q.required:
                            result.unresolved.append(UnresolvedField(q, QuestionReason.UNKNOWN.value))
                        continue
                    resolved = None
                    origin, confidence, origin_ref = AnswerOrigin.GENERATED, None, "cover_letter"
                else:
                    value = str(resolved.answer)
                    origin = AnswerOrigin(resolved.origin)
                    confidence = resolved.confidence
                    origin_ref = resolved.origin_ref
                    ng_key = getattr(resolved, "never_guess_key", None)
            if value is None or (value == "" and kind != "checkbox"):
                if q.required:
                    result.unresolved.append(UnresolvedField(q, QuestionReason.UNKNOWN.value))
                continue
            if kind == "file" and slot == "resume" and prior is not None and ctx.resume is not None:
                value = ctx.resume.file_path
            from playwright.async_api import Error as PlaywrightError

            try:
                applied = await fill_control_value(page, q.key, kind, value, q.options)
            except PlaywrightError as e:
                # One stubborn control (overlay, detached node, custom widget) must not abort
                # the whole application: treat it like an unappliable value.
                log.warning("fill failed for %r (%s): %s", q.label, kind, str(e).splitlines()[0])
                applied = None
            if applied is None:
                if q.required:
                    result.unresolved.append(UnresolvedField(
                        q, QuestionReason.LOW_CONFIDENCE.value if q.options else QuestionReason.UNKNOWN.value,
                        suggested_answer=value if kind != "file" else None, confidence=confidence,
                    ))
                continue
            # Record + audit what actually went into the form (the selected option for
            # choice controls), so the audit trail, Review and the guardrails see it.
            if kind != "file":
                value = applied
            shown = Path(value).name if kind == "file" else value
            ra = ledger.record(q, shown if kind == "file" else value, origin, confidence=confidence, origin_ref=origin_ref,
                               resolved=resolved, resolver=resolver if resolved is not None else None, reused=reused)
            if kind != "file":
                audit.append((AnswerForCheck(question=q, answer=value, origin=origin, confidence=confidence, never_guess_key=ng_key), ra))
            await emit_step(ctx, i, f"answering {q.label!r}", total=total, detail=shown[:200], confidence=confidence)
        result.answers = ledger.answers
        # Pre-submit audit (B's guardrail hook): never-guess / always-ask / confidence.
        try:
            violations = check_answers([a for a, _ in audit], ctx.never_guess, ctx.preferences)
        except NotImplementedError:
            violations = []
        flagged = {v.question for v in violations}
        flagged_keys: set[str] = set()
        for v in violations:
            q = next((a.question for a, _ in audit if a.question.label == v.question), None)
            if q is not None:
                result.unresolved.append(UnresolvedField(q, QuestionReason(v.reason).value))
                flagged_keys.add(q.key)
        # A rejected answer must not be reused by the next fill (it would shadow the
        # user's inbox answer forever): drop its non-user audit row so the field is
        # resolved afresh. User-origin rows (Review edits / inbox answers) are kept.
        ledger.discard(flagged_keys)
        if flagged:
            log.info("guardrail audit flagged %d answer(s): %s", len(flagged), sorted(flagged))

    async def _cover_letter(self, ctx: ApplyContext, q: FormQuestion, result: FillResult) -> str | None:
        """Generate a grounded cover letter (B) -> file path for uploads, text for textareas."""
        provided = ctx.extra.get("cover_letter_path") or ctx.application.cover_letter_path
        if provided and Path(provided).exists():
            result.cover_letter_path = str(provided)
            if q.field_type is FieldType.FILE:
                return str(self._letter_upload_name(ctx, Path(provided)))
            return Path(provided).read_text(encoding="utf-8")
        if not q.required and not ctx.extra.get("always_cover_letter", True):
            return None
        try:
            from autoapply import db
            from autoapply.answers.cover_letter import generate_cover_letter
            from autoapply.paths import get_paths

            company = db.get_company(ctx.conn, ctx.job.company_id)
            out_dir = Path(ctx.extra.get("cover_letters_dir") or get_paths().cover_letters)
            letter = await generate_cover_letter(
                ctx.llm, profile=ctx.profile, stories=db.list_stories(ctx.conn), job=ctx.job, company=company,
                out_dir=None if ctx.is_dry_run else out_dir,
            )
        except Exception as e:  # noqa: BLE001 - generation is best effort for optional fields
            log.info("cover letter unavailable: %s", e)
            return None
        if not getattr(letter, "text", ""):
            return None
        if q.field_type is FieldType.FILE:
            path = letter.path
            if path is None:
                tmp = ctx.screenshots_dir / "cover_letter.txt"
                tmp.parent.mkdir(parents=True, exist_ok=True)
                tmp.write_text(letter.text + "\n", encoding="utf-8")
                path = tmp
            result.cover_letter_path = str(path)
            return str(self._letter_upload_name(ctx, Path(path)))
        if letter.path is not None:
            result.cover_letter_path = str(letter.path)
        return letter.text

    @staticmethod
    def _letter_upload_name(ctx: ApplyContext, path: Path) -> Path:
        """The recruiter sees the uploaded file name: "<Name> - Cover Letter - <Company>.txt"."""
        try:
            from autoapply import db

            company = db.get_company(ctx.conn, ctx.job.company_id).name
        except Exception:  # noqa: BLE001
            company = ""
        safe = lambda v: re.sub(r"[^\w .&-]+", "", v or "").strip()[:60]  # noqa: E731
        want = " - ".join(x for x in (safe(ctx.profile.full_name), "Cover Letter", safe(company)) if x) + path.suffix
        if path.name == want:
            return path
        import shutil
        import tempfile

        target = Path(tempfile.gettempdir()) / "autoapply-uploads" / f"letter-{ctx.application.id}" / want
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        return target

    async def _screenshot(self, page: Page, ctx: ApplyContext, label: str) -> str | None:
        try:
            ctx.screenshots_dir.mkdir(parents=True, exist_ok=True)
            path = ctx.screenshots_dir / f"{label}-{_ts_slug()}.png"
            await page.screenshot(path=str(path), full_page=True)
            return str(path)
        except Exception as e:  # noqa: BLE001
            log.warning("screenshot failed: %s", e)
            return None

    # ---- submit ----------------------------------------------------------------------

    async def submit(self, ctx: ApplyContext) -> SubmitResult:
        """Click submit exactly once and verify. Re-fills from the recorded answers when the
        page from ``fill`` is gone (e.g. an approved Review item)."""
        if ctx.is_dry_run:
            await close_session(ctx)
            return SubmitResult(verified=False, error="dry_run: submit not clicked", clicked=False)
        session: BrowserSession | None = ctx.extra.get(SESSION_KEY)
        try:
            if session is None or session.page.is_closed() or not session.filled:
                refill = await self._refill_for_submit(ctx)
                if isinstance(refill, SubmitResult):
                    return refill
                session = refill
            page = session.page
            if not _host_allowed(page.url):
                return SubmitResult(verified=False, error=f"submit refused: host {urlsplit(page.url).hostname} not allowed", clicked=False)
            button = await self._submit_button(page)
            if button is None:
                return SubmitResult(verified=False, error="submit button not found", clicked=False)
            await emit_step(ctx, 1000, "clicking submit")
            before = page.url
            # Confirmation wording may already be on the page (job description, FAQ):
            # snapshot it so only NEW confirmation text counts after the click.
            hits_before = await self._confirm_hits(page)
            session.allow_submit = True
            await button.click()  # exactly once — never retried
            return await self._verify(page, ctx, before, confirm_hits_before=hits_before)
        finally:
            await close_session(ctx)

    async def _refill_for_submit(self, ctx: ApplyContext) -> BrowserSession | SubmitResult:
        result = FillResult(ok=True)
        session = await open_session(ctx)
        await self.open_form(session.page, ctx)
        if await visible_captcha(session.page):
            return SubmitResult(verified=False, error="captcha present; not clicked", clicked=False)
        questions, kinds = await self.form_questions(session.page, ctx)
        session.kinds = kinds
        await self._fill_questions(ctx, session.page, questions, kinds, result)
        if result.unresolved:
            labels = ", ".join(u.question.label for u in result.unresolved)[:300]
            return SubmitResult(verified=False, error=f"re-fill left unresolved fields: {labels}", clicked=False)
        session.filled = True
        return session

    async def _submit_button(self, page: Page):
        for sel in self.submit_selectors:
            loc = page.locator(sel)
            try:
                n = await loc.count()
            except Exception:  # noqa: BLE001
                continue
            for i in range(n):
                if await loc.nth(i).is_visible() and await loc.nth(i).is_enabled():
                    return loc.nth(i)
        return None

    async def _confirm_hits(self, page: Page) -> int | None:
        """How many times ``confirm_text`` matches the page body (None if unreadable)."""
        try:
            body = await page.inner_text("body", timeout=2000)
        except Exception:  # noqa: BLE001
            return None
        return sum(1 for _ in self.confirm_text.finditer(body))

    async def _form_present(self, page: Page) -> bool:
        """True while a submit control of the application form is still visible (disabled
        counts: a button greyed out mid-request is still the form)."""
        for sel in self.submit_selectors:
            loc = page.locator(sel)
            try:
                for i in range(await loc.count()):
                    if await loc.nth(i).is_visible():
                        return True
            except Exception:  # noqa: BLE001 - mid-navigation
                continue
        return False

    async def _text_confirms(self, page: Page, body: str, url: str, before_url: str,
                             confirm_hits_before: int | None) -> bool:
        """Confirmation TEXT only counts when it is new: more matches than before the click,
        or the page moved on (URL changed / the application form is gone). Text that was
        already on the form page (e.g. "Thank you for applying" in the description) never
        verifies a click that did nothing."""
        hits = sum(1 for _ in self.confirm_text.finditer(body))
        if hits == 0:
            return False
        if url != before_url:
            return True
        if confirm_hits_before is not None and hits > confirm_hits_before:
            return True
        return not await self._form_present(page)

    async def _complete_email_code(self, page: Page, ctx: ApplyContext, body: str) -> SubmitResult | None:
        """The ATS emailed a code before it accepts the application: get it (Needs-You question tied to
        this job), type it, click Submit again. None = code entered and resubmitted (keep verifying)."""
        from autoapply.apply.email_code import code_email, code_length, type_code, wait_for_code

        shot = await self._screenshot(page, ctx, "verification-code")
        await emit_step(ctx, 1001, "waiting for the security code emailed to you (see Needs You)")
        code = await wait_for_code(ctx, ats=self.ats.value.capitalize(), email=code_email(body), length=code_length(body))
        if not code:
            return SubmitResult(verified=False, confirmation_screenshot_path=shot, error="verification code not entered in time")
        if not await type_code(page, code):
            return SubmitResult(verified=False, confirmation_screenshot_path=shot, error="could not type the verification code")
        await emit_step(ctx, 1002, "security code entered; submitting")
        await asyncio.sleep(0.5)
        button = await self._submit_button(page)
        if button is not None:
            await button.click()  # the first click only triggered the code email; this one submits
        return None

    async def _verify(self, page: Page, ctx: ApplyContext, before_url: str, *,
                      confirm_hits_before: int | None = None) -> SubmitResult:
        """Wait for proof the click submitted. ``confirm_hits_before`` is the number of
        ``confirm_text`` matches before the click; when unknown (None), a text match needs
        a URL change or the form to disappear."""
        deadline = time.monotonic() + self.submit_timeout_s
        last_errors: list[str] = []
        code_done = False
        while time.monotonic() < deadline:
            try:
                url = page.url
                body = await page.inner_text("body", timeout=2000)
            except Exception:  # noqa: BLE001 - mid-navigation
                await asyncio.sleep(0.25)
                continue
            if (url != before_url and self.confirm_url.search(urlsplit(url).path)) or await self._text_confirms(
                page, body, url, before_url, confirm_hits_before
            ):
                shot = await self._screenshot(page, ctx, "confirmation")
                return SubmitResult(verified=True, confirmation_screenshot_path=shot)
            if not code_done:
                from autoapply.apply.email_code import code_requested

                if code_requested(body):
                    code_done = True
                    failed = await self._complete_email_code(page, ctx, body)
                    if failed is not None:
                        return failed
                    deadline = time.monotonic() + self.submit_timeout_s
                    continue
            if await visible_captcha(page):
                shot = await self._screenshot(page, ctx, "captcha-after-submit")
                return SubmitResult(verified=False, confirmation_screenshot_path=shot, error="captcha challenge after submit")
            last_errors = await validation_errors(page)
            if last_errors and url == before_url:
                await asyncio.sleep(1.0)  # let async validation settle, then re-check once
                try:
                    body2, url2 = await page.inner_text("body", timeout=2000), page.url
                except Exception:  # noqa: BLE001 - navigated meanwhile: keep polling
                    continue
                if not await self._text_confirms(page, body2, url2, before_url, confirm_hits_before):
                    shot = await self._screenshot(page, ctx, "submit-errors")
                    return SubmitResult(verified=False, confirmation_screenshot_path=shot,
                                        error="form errors after submit: " + "; ".join(last_errors)[:300])
            await asyncio.sleep(0.3)
        shot = await self._screenshot(page, ctx, "submit-timeout")
        return SubmitResult(verified=False, confirmation_screenshot_path=shot, error="no confirmation detected")


# =====================================================================================
# Shared runner (CLI / tests). The daemon's Pipeline (D) implements the same walk.
# =====================================================================================


@dataclass(slots=True)
class RunResult:
    application_id: int
    final_state: AppState
    fill: FillResult | None = None
    submit: SubmitResult | None = None
    reason: str | None = None


SubmitGate = Callable[..., Any]


def _park_unresolved(ctx: ApplyContext, unresolved: list[UnresolvedField]) -> None:
    """Put unresolved fields in the Needs-You inbox via B's ``prep.park_unresolved`` (joins
    paraphrase clusters, tags country-dependent questions with the job's country); falls back
    to plain ``db.add_question`` rows if that is unavailable."""
    from autoapply import db

    try:
        from autoapply import prep

        prep.park_unresolved(ctx.conn, ctx.job.id, unresolved)
        return
    except (ImportError, NotImplementedError):
        log.debug("prep.park_unresolved unavailable; using plain inbox questions", exc_info=True)
    for u in unresolved:
        try:
            reason = QuestionReason(u.reason)
        except ValueError:
            reason = QuestionReason.UNKNOWN
        db.add_question(ctx.conn, canonical_question=u.question.label, job_id=ctx.job.id, field_type=u.question.field_type,
                        options=u.question.options, never_guess_key=u.never_guess_key, reason=reason,
                        suggested_answer=u.suggested_answer, suggested_confidence=u.confidence)


async def run_application(
    ctx: ApplyContext,
    adapter: Adapter,
    *,
    gate: SubmitGate | None = None,
    run_db_id: int | None = None,
) -> RunResult:
    """Fill (and in Auto mode submit) one application, walking the state machine.

    queued|prepping -> filling -> needs_you (unresolved) | failed (fill error) |
    awaiting_review (Review mode) | queued (pause / guardrail blocked) |
    submitting (``db.begin_submit``, durable) -> submitted | unknown_verify.

    ``ctx.dry_run``: fills only; NO state changes and no answers persisted.
    ``gate``: ``(conn, application, job, preferences, *, paused) -> SubmitCheck``; defaults
    to ``answers.guardrails.check_submit_allowed``.
    """
    from autoapply import db

    app_id = ctx.application.id

    async def emit_t(t: Any) -> None:
        try:
            await ctx.emit("application_state", t.to_payload())
        except Exception:  # noqa: BLE001
            log.debug("emit application_state failed", exc_info=True)

    async def move(to: AppState, reason: str | None = None, expected: Any = None) -> None:
        t = db.transition(ctx.conn, app_id, to, reason=reason, expected_from=expected, run_id=run_db_id)
        await emit_t(t)

    if ctx.is_dry_run:
        try:
            fill = await adapter.fill(ctx)
        finally:
            await close_session(ctx)
        return RunResult(app_id, db.get_application(ctx.conn, app_id).state, fill=fill, reason="dry_run")

    mode = ctx.preferences.effective_mode(ctx.job.ats, ctx.job.company_id, ctx.job.mode_override)
    db.update_application(ctx.conn, app_id, mode=mode.value)
    await move(AppState.FILLING, expected=(AppState.QUEUED, AppState.PREPPING))
    try:
        fill = await adapter.fill(ctx)
    except PausedError:
        await close_session(ctx)
        await move(AppState.QUEUED, "paused", AppState.FILLING)
        return RunResult(app_id, AppState.QUEUED, reason="paused")
    except Exception as e:  # noqa: BLE001
        await close_session(ctx)
        log.exception("fill failed")
        await move(AppState.FAILED, f"adapter_error: {e}"[:300], AppState.FILLING)
        return RunResult(app_id, AppState.FAILED, reason=str(e))

    art = {k: v for k, v in (("screenshot_path", fill.screenshot_path), ("cover_letter_path", fill.cover_letter_path)) if v}
    if art:
        db.update_application(ctx.conn, app_id, **art)
    if fill.unresolved:
        await close_session(ctx)
        _park_unresolved(ctx, fill.unresolved)
        await move(AppState.NEEDS_YOU, "unresolved_questions", AppState.FILLING)
        return RunResult(app_id, AppState.NEEDS_YOU, fill=fill, reason="unresolved_questions")
    if not fill.ok:
        await close_session(ctx)
        await move(AppState.FAILED, fill.error or "fill_failed", AppState.FILLING)
        return RunResult(app_id, AppState.FAILED, fill=fill, reason=fill.error)
    if mode is Mode.REVIEW and not ctx.extra.get("approved"):
        await close_session(ctx)
        await move(AppState.AWAITING_REVIEW, "review_mode", AppState.FILLING)
        return RunResult(app_id, AppState.AWAITING_REVIEW, fill=fill)

    # final gate -> durable pre-write -> click (no await between gate and pre-write)
    if gate is None:
        from autoapply.answers.guardrails import check_submit_allowed as gate
    prefs = db.get_preferences(ctx.conn)
    check = gate(ctx.conn, db.get_application(ctx.conn, app_id), ctx.job, prefs, paused=ctx.is_paused())
    if not check.allowed:
        await close_session(ctx)
        await move(AppState.QUEUED, check.reason or "blocked", AppState.FILLING)
        return RunResult(app_id, AppState.QUEUED, fill=fill, reason=check.reason)
    t = db.begin_submit(ctx.conn, app_id, run_id=run_db_id)
    await emit_t(t)
    try:
        res = await adapter.submit(ctx)
    except Exception as e:  # noqa: BLE001 - the click may have happened
        await move(AppState.UNKNOWN_VERIFY, f"submit_error: {e}"[:300], AppState.SUBMITTING)
        return RunResult(app_id, AppState.UNKNOWN_VERIFY, fill=fill, reason=str(e))
    if res.verified:
        t = db.complete_submit(ctx.conn, app_id, confirmation_screenshot_path=res.confirmation_screenshot_path, run_id=run_db_id)
        await emit_t(t)
        return RunResult(app_id, AppState.SUBMITTED, fill=fill, submit=res)
    if res.confirmation_screenshot_path:
        db.update_application(ctx.conn, app_id, confirmation_screenshot_path=res.confirmation_screenshot_path)
    if not res.clicked:  # nothing was clicked: definitely not sent
        await move(AppState.FAILED, f"not_submitted: {res.error or 'submit not clicked'}"[:300], AppState.SUBMITTING)
        return RunResult(app_id, AppState.FAILED, fill=fill, submit=res, reason=res.error)
    await move(AppState.UNKNOWN_VERIFY, res.error or "unverified", AppState.SUBMITTING)
    return RunResult(app_id, AppState.UNKNOWN_VERIFY, fill=fill, submit=res, reason=res.error)


def build_context(
    conn: sqlite3.Connection,
    application_id: int,
    *,
    llm: LLMProvider,
    emit: EmitFn | None = None,
    screenshots_root: Path | None = None,
    **kwargs: Any,
) -> ApplyContext:
    """Convenience: an :class:`ApplyContext` from DB state (CLI / tests)."""
    from autoapply import db
    from autoapply.paths import get_paths

    app = db.get_application(conn, application_id)
    job = db.get_job(conn, app.job_id)
    resume = None
    if app.resume_variant_id is not None:
        resume = db.get_resume_variant(conn, app.resume_variant_id)
    else:
        variants = db.list_resume_variants(conn, enabled_only=True)
        resume = variants[0] if variants else None

    async def _noop(_type: str, _payload: Any) -> None:
        return None

    root = screenshots_root or get_paths().screenshots
    return ApplyContext(
        conn=conn, application=app, job=job, profile=db.get_profile(conn), never_guess=db.get_never_guess(conn),
        preferences=db.get_preferences(conn), llm=llm, resume=resume, screenshots_dir=root / str(app.id),
        emit=emit or _noop, **kwargs,
    )
