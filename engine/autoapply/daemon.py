"""autoapplyd: Unix-socket NDJSON server, lifecycle, snapshot, command dispatch.

Owner: Workstream D (daemon & LinkedIn).

Protocol: contract/protocol.md. Messages are decoded with ``autoapply.models.decode_line``
and written with ``Envelope.to_line``.

Lifecycle:

1. ``start()`` takes the single-instance lock (``<home>/autoapplyd.lock``, ``flock``), opens
   the DB, runs crash recovery (``db.recover_after_crash`` + ``db.abandon_unfinished_runs``),
   binds ``<home>/autoapplyd.sock`` (0600), and starts the scheduler and maintenance loops.
2. Every client gets exactly one reply per command (``snapshot`` for ``hello``, ``ack``
   otherwise, ``error`` on failure). Side-effect events are broadcast to all clients
   *after* the reply.
3. ``stop()`` cancels the active run (the pipeline requeues anything mid-fill), closes the
   clients and the socket, and releases the lock.

The daemon is the ONLY database writer. Commands are handled one at a time (a lock), and
all SQLite access happens on the event-loop thread, so there are no concurrent writers.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import hashlib
import contextvars
import fcntl
import inspect
import json
import logging
import logging.handlers
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ValidationError

from autoapply import __version__, db
from autoapply.apply.base import Adapter, PausedError
from autoapply.config import NeverGuess
from autoapply.discovery.base import Source
from autoapply.discovery.linkedin import BrowserListingBase, load_source_statuses, next_local_midnight, record_source_status
from autoapply.enums import (
    Actor,
    AnswerOrigin,
    AppState,
    CapKind,
    DaemonActivity,
    ErrorCode,
    JobSource,
    LogLevel,
    QuestionKind,
    QuestionStatus,
    RunKind,
    RunTrigger,
    SourceName,
)
from autoapply.llm.provider import LLMProvider
from autoapply.notify import Notifier
from autoapply.models import (
    PROTOCOL_VERSION,
    ApplicationStatePayload,
    Envelope,
    CapReachedPayload,
    ErrorPayload,
    LogPayload,
    OnboardingState,
    ParseResumeResult,
    Profile,
    ProfilePatch,
    ProtocolError,
    QuestionOpenedPayload,
    QuestionResolvedPayload,
    SnapshotPayload,
    SourceStatus,
    SourceStatusPayload,
    StatePayload,
    SystemCheckItem,
    SystemCheckResult,
    decode_line,
    make_event,
    utcnow,
)
from autoapply.paths import Paths, get_paths
from autoapply.pipeline import Pipeline, PipelineHooks, SubmitCheck
from autoapply.scheduler import Caffeinate, RunConflict, RunCoordinator, Scheduler

log = logging.getLogger("autoapply.daemon")

MAX_LINE_BYTES = 8 * 1024 * 1024
CLIENT_QUEUE_MAX = 10_000
MAX_INFLIGHT_PER_CLIENT = 32  # commands read ahead per client (backpressure beyond this)
LOCK_FILENAME = "autoapplyd.lock"
MAINTENANCE_INTERVAL = 3600.0
#: Extra directories searched for CLIs (launchd gives a minimal PATH).
EXTRA_PATH = ("/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / ".local/bin"), str(Path.home() / ".cargo/bin"))

# Set while a command is being handled: side-effect events are collected here and broadcast
# after the reply (protocol.md §3). Background tasks run with a fresh context.
_DEFERRED: contextvars.ContextVar[list[tuple[str, Any]] | None] = contextvars.ContextVar("autoapply_deferred", default=None)


# =====================================================================================
# Errors used by command handlers
# =====================================================================================


class CommandError(Exception):
    def __init__(self, code: ErrorCode, message: str, *, details: dict[str, Any] | None = None,
                 job_id: int | None = None, application_id: int | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details
        self.job_id = job_id
        self.application_id = application_id


class DaemonAlreadyRunning(RuntimeError):
    pass


# =====================================================================================
# Single-instance lock
# =====================================================================================


class InstanceLock:
    """``flock`` on ``<home>/autoapplyd.lock``; released automatically if the process dies."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._fd: int | None = None

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as e:
            os.close(fd)
            raise DaemonAlreadyRunning(f"another autoapplyd holds {self.path}") from e
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
        self._fd = fd

    def release(self) -> None:
        if self._fd is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(self._fd, fcntl.LOCK_UN)
                os.close(self._fd)
            self._fd = None

    @property
    def held(self) -> bool:
        return self._fd is not None


# =====================================================================================
# Structured logging
# =====================================================================================


class JsonLogFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        data: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created).astimezone().isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key in ("client", "command", "command_id", "run_id", "application_id", "job_id"):
            if hasattr(record, key):
                data[key] = getattr(record, key)
        if record.exc_info:
            data["exc"] = self.formatException(record.exc_info)
        return json.dumps(data, ensure_ascii=False)


def setup_logging(paths: Paths, level: int = logging.INFO, *, stderr: bool = True) -> logging.Handler:
    """JSON lines to ``<home>/logs/autoapplyd.log`` (rotated 5 x 5 MB)."""
    paths.logs.mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(paths.daemon_log, maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8")
    handler.setFormatter(JsonLogFormatter())
    root = logging.getLogger("autoapply")
    root.setLevel(level)
    root.addHandler(handler)
    if stderr:
        sh = logging.StreamHandler(sys.stderr)
        sh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
        root.addHandler(sh)
    return handler


# =====================================================================================
# Clients
# =====================================================================================


@dataclass(eq=False)
class Client:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:8])
    queue: asyncio.Queue[str | None] = field(default_factory=lambda: asyncio.Queue(CLIENT_QUEUE_MAX))
    kind: str = "unknown"
    closed: bool = False
    sender: asyncio.Task[None] | None = None

    def send(self, env: Envelope) -> bool:
        if self.closed:
            return False
        try:
            self.queue.put_nowait(env.to_line())
            return True
        except asyncio.QueueFull:
            log.warning("client %s too slow; disconnecting", self.id)
            self.close()
            return False

    async def run_sender(self) -> None:
        try:
            while True:
                line = await self.queue.get()
                if line is None:
                    break
                self.writer.write(line.encode("utf-8"))
                await self.writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            self.closed = True
            with contextlib.suppress(Exception):
                self.writer.close()

    def close(self) -> None:
        if not self.closed:
            self.closed = True
            with contextlib.suppress(asyncio.QueueFull):
                self.queue.put_nowait(None)
            if self.queue.full():
                with contextlib.suppress(Exception):
                    self.writer.close()


# =====================================================================================
# Helpers: system check, resumes, chrome
# =====================================================================================


def _search_path() -> str:
    parts = os.environ.get("PATH", "").split(os.pathsep)
    return os.pathsep.join(dict.fromkeys([*parts, *EXTRA_PATH]))


def _which(cmd: str) -> str | None:
    return shutil.which(cmd, path=_search_path())


def _version(exe: str, *args: str) -> str | None:
    try:
        out = subprocess.run([exe, *(args or ("--version",))], capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    text = (out.stdout or out.stderr or "").strip().splitlines()
    return text[0][:120] if text else None


def chrome_app_path() -> Path | None:
    for base in (Path("/Applications"), Path.home() / "Applications"):
        p = base / "Google Chrome.app"
        if p.exists():
            return p
    return None


def run_system_check() -> SystemCheckResult:
    """Blocking; run in a thread. Never logs in or spends tokens."""
    items: list[SystemCheckItem] = []
    claude = _which("claude")
    items.append(SystemCheckItem(
        name="claude_cli", ok=claude is not None, required=True, version=_version(claude) if claude else None,
        detail=f"found at {claude}; make sure you're logged in (claude login)" if claude else "claude CLI not found",
        fix_command=None if claude else "npm install -g @anthropic-ai/claude-code && claude login",
    ))
    uv = _which("uv")
    items.append(SystemCheckItem(
        name="uv", ok=uv is not None, required=True, version=_version(uv) if uv else None,
        detail=f"found at {uv}" if uv else "uv not found",
        fix_command=None if uv else "curl -LsSf https://astral.sh/uv/install.sh | sh",
    ))
    node = _which("node")
    items.append(SystemCheckItem(
        name="node", ok=node is not None, required=True, version=_version(node) if node else None,
        detail=f"found at {node} (needed for npx @playwright/mcp)" if node else "Node.js not found (needed for npx @playwright/mcp)",
        fix_command=None if node else "brew install node",
    ))
    items.append(SystemCheckItem(name="autoapplyd", ok=True, required=True, version=__version__, detail=f"running (pid {os.getpid()})"))
    chrome = chrome_app_path()
    items.append(SystemCheckItem(
        name="chrome", ok=chrome is not None, required=False, version=None,
        detail=f"found at {chrome}" if chrome else "Google Chrome not found; Playwright's Chromium will be used",
        fix_command=None if chrome else "brew install --cask google-chrome",
    ))
    return SystemCheckResult(items=items, all_required_ok=all(i.ok for i in items if i.required))


def extract_pdf_links(path: Path) -> dict[str, str]:
    """Real hyperlinks embedded in a PDF resume: {"linkedin": url, "github": url, "website": url}.
    The visible text is often a shortened label ("linkedin.com/JaneDoe") for a different URL."""
    out: dict[str, str] = {}
    try:
        from pypdf import PdfReader

        for page in PdfReader(str(path)).pages:
            for annot in page.get("/Annots") or []:
                uri = str(((annot.get_object() or {}).get("/A") or {}).get("/URI") or "").strip()
                low = uri.lower()
                if not low.startswith("http"):
                    continue
                if "linkedin.com/in/" in low and "linkedin" not in out:
                    out["linkedin"] = uri
                elif re.match(r"https?://(www\.)?github\.com/[^/]+/?$", low) and "github" not in out:
                    out["github"] = uri
                elif not any(h in low for h in ("linkedin.", "github.", "ieeexplore", ".pdf", "doi.org", "scholar.google")) and "website" not in out:
                    out["website"] = uri
    except Exception:  # noqa: BLE001 - links are a bonus
        log.debug("could not read PDF links from %s", path, exc_info=True)
    return out


def extract_pdf_text(path: Path) -> str | None:
    """Best-effort text extraction (pypdf). Non-PDF text files are read as UTF-8."""
    try:
        if path.suffix.lower() != ".pdf":
            return path.read_text(encoding="utf-8", errors="replace")
        from pypdf import PdfReader

        reader = PdfReader(str(path))
        text = "\n".join((page.extract_text() or "") for page in reader.pages)
        return text.strip() or None
    except Exception:  # noqa: BLE001
        log.warning("could not extract text from %s", path, exc_info=True)
        return None


def open_chrome_window(profile_dir: Path, url: str | None) -> None:
    """Bring up the visible agent Chrome (dedicated profile)."""
    args = ["open", "-na", "Google Chrome", "--args", f"--user-data-dir={profile_dir}"]
    if url:
        args.append(url)
    subprocess.run(args, check=True, timeout=15, capture_output=True)


_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_PHONE = re.compile(r"(?:\+\d{1,3}[\s-]?)?(?:\(?\d{2,4}\)?[\s-]?)?\d{3,4}[\s-]?\d{3,4}")
_URL = re.compile(r"(?:https?://)?(?:www\.)?(linkedin\.com/in/[\w-]+|github\.com/[\w-]+)", re.I)

RESUME_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "profile": {
            "type": "object",
            "properties": {
                "full_name": {"type": ["string", "null"]},
                "first_name": {"type": ["string", "null"]},
                "last_name": {"type": ["string", "null"]},
                "email": {"type": ["string", "null"]},
                "phone": {"type": ["string", "null"]},
                "location": {"type": ["string", "null"]},
                "headline": {"type": ["string", "null"]},
                "summary": {"type": ["string", "null"]},
                "links": {"type": "object", "additionalProperties": {"type": "string"}},
                "skills": {"type": "array", "items": {"type": "string"}},
                "years_experience": {"type": ["number", "null"]},
                "work_history": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "company": {"type": "string"}, "title": {"type": "string"},
                            "start": {"type": ["string", "null"]}, "end": {"type": ["string", "null"]},
                            "location": {"type": ["string", "null"]},
                            "highlights": {"type": "array", "items": {"type": "string"}},
                        },
                        "required": ["company", "title"],
                    },
                },
                "education": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "school": {"type": "string"}, "degree": {"type": ["string", "null"]},
                            "field": {"type": ["string", "null"]}, "start": {"type": ["string", "null"]},
                            "end": {"type": ["string", "null"]},
                        },
                        "required": ["school"],
                    },
                },
            },
        },
        "uncertain_fields": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["profile", "uncertain_fields"],
}

RESUME_PROMPT = (
    "Extract the candidate's profile from this resume text. Use ONLY facts present in the text; "
    "use null (or an empty list) when something is absent - never invent. List in "
    "uncertain_fields every profile field you are not confident about.\n\nRESUME:\n{text}"
)


def heuristic_profile(text: str) -> tuple[dict[str, Any], list[str]]:
    """Offline fallback parse: email, phone, name (first line), profile links."""
    patch: dict[str, Any] = {}
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if lines and len(lines[0].split()) <= 5 and not _EMAIL.search(lines[0]):
        patch["full_name"] = lines[0]
        parts = lines[0].split()
        patch["first_name"], patch["last_name"] = parts[0], (parts[-1] if len(parts) > 1 else None)
    if m := _EMAIL.search(text):
        patch["email"] = m.group(0)
    for m in _PHONE.finditer(text):
        digits = re.sub(r"\D", "", m.group(0))
        if 9 <= len(digits) <= 15:
            patch["phone"] = m.group(0).strip()
            break
    links: dict[str, str] = {}
    for m in _URL.finditer(text):
        u = m.group(1)
        links["linkedin" if "linkedin" in u.lower() else "github"] = "https://" + u
    if links:
        patch["links"] = links
    core = {"full_name", "email", "phone", "location", "headline", "work_history", "education", "skills"}
    # Everything we couldn't find, plus the name (a first-line guess) when we did "find" it.
    uncertain = sorted((core - set(patch)) | ({"full_name"} if "full_name" in patch else set()))
    return patch, uncertain


# =====================================================================================
# Default wiring of sources / adapters (A/B classes, constructed defensively)
# =====================================================================================


def _construct(cls: type, available: dict[str, Any]) -> Any | None:
    try:
        params = inspect.signature(cls).parameters
        kwargs = {k: v for k, v in available.items() if k in params}
        return cls(**kwargs)
    except Exception:  # noqa: BLE001
        log.warning("could not construct %s", getattr(cls, "__name__", cls), exc_info=True)
        return None


def default_sources(available: dict[str, Any]) -> list[Source]:
    from autoapply.discovery.ashby import AshbySource
    from autoapply.discovery.careers_agent import CareerPageAgent
    from autoapply.discovery.company_finder import CompanyFinder
    from autoapply.discovery.glassdoor import GlassdoorSource
    from autoapply.discovery.google_jobs import GoogleJobsSource
    from autoapply.discovery.greenhouse import GreenhouseSource
    from autoapply.discovery.lever import LeverSource
    from autoapply.discovery.linkedin import LinkedinSource

    out = [_construct(c, available) for c in (GreenhouseSource, LeverSource, AshbySource, CareerPageAgent, LinkedinSource,
                                              GlassdoorSource, GoogleJobsSource, CompanyFinder)]
    return [s for s in out if s is not None]


def default_adapters(available: dict[str, Any]) -> list[Adapter]:
    from autoapply.apply.agentic import AgenticAdapter
    from autoapply.apply.ashby import AshbyAdapter
    from autoapply.apply.greenhouse import GreenhouseAdapter
    from autoapply.apply.lever import LeverAdapter

    # Scripted adapters before the agentic fallback (select_adapter takes the first match).
    out = [_construct(c, available) for c in (GreenhouseAdapter, LeverAdapter, AshbyAdapter, AgenticAdapter)]
    return [a for a in out if a is not None]


# =====================================================================================
# Daemon
# =====================================================================================


class Daemon:
    def __init__(
        self,
        paths: Paths,
        *,
        llm: LLMProvider | None = None,
        conn: sqlite3.Connection | None = None,
        sources: list[Source] | None = None,
        adapters: list[Adapter] | None = None,
        hooks: PipelineHooks | None = None,
        socket_path: Path | str | None = None,
        enable_scheduler: bool = True,
        enable_maintenance: bool = True,
        caffeinate_factory: Callable[[], Caffeinate] | None = None,
        system_check: Callable[[], SystemCheckResult] | None = None,
        chrome_launcher: Callable[[Path, str | None], None] | None = None,
        source_factory: Callable[[str], BrowserListingBase] | None = None,
        scheduler: Scheduler | None = None,
        notifier: Notifier | None = None,
    ) -> None:
        self.paths = paths
        self.notifier = notifier
        if notifier is not None:
            notifier.suppress = lambda: bool(self.clients)  # the app shows its own notifications
        self.socket_path = Path(socket_path) if socket_path else paths.socket
        self._conn = conn
        self._owns_conn = conn is None
        self.llm = llm
        self._sources_arg = sources
        self._adapters_arg = adapters
        self.hooks = hooks
        self.enable_scheduler = enable_scheduler
        self.enable_maintenance = enable_maintenance
        self.caffeinate_factory = caffeinate_factory or Caffeinate
        self.system_check = system_check or run_system_check
        self.chrome_launcher = chrome_launcher or open_chrome_window
        self._source_factory = source_factory
        self._scheduler_arg = scheduler

        self.clients: set[Client] = set()
        self.lock = InstanceLock(paths.home / LOCK_FILENAME)
        self._server: asyncio.base_events.Server | None = None
        self._cmd_lock = asyncio.Lock()
        self._tasks: set[asyncio.Task[Any]] = set()
        self._stopped = asyncio.Event()
        self._started = False
        self.paused = False
        self.state = StatePayload(daemon=DaemonActivity.IDLE)
        self.pipeline: Pipeline | None = None
        self.coordinator: RunCoordinator | None = None
        self.scheduler: Scheduler | None = None

    # ---- properties --------------------------------------------------------------------

    @property
    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            raise RuntimeError("daemon not started")
        return self._conn

    # ---- lifecycle ---------------------------------------------------------------------

    def _ensure_core(self) -> None:
        """Open DB + build pipeline/coordinator (idempotent; ``handle`` works without a socket)."""
        if self.pipeline is not None:
            return
        if self._conn is None:
            self._conn = db.open_db(self.paths.db)
        else:
            db.migrate(self._conn)
        if self.llm is None:
            from autoapply.llm.provider import get_provider

            self.llm = get_provider(os.environ.get("AUTOAPPLY_LLM_PROVIDER", "agent_sdk"))
        self.paused = bool(db.get_meta(self.conn, db.META_PAUSED, False))
        self.state = StatePayload(daemon=DaemonActivity.IDLE, paused=self.paused)
        available = {
            "conn": self.conn, "paths": self.paths, "llm": self.llm, "emit": self.emit,
            "is_paused": self.is_paused, "profile_dir": self.paths.chrome_profile, "headless": True,
        }
        sources = self._sources_arg if self._sources_arg is not None else default_sources(available)
        adapters = self._adapters_arg if self._adapters_arg is not None else default_adapters(available)
        self.pipeline = Pipeline(
            self.conn, paths=self.paths, llm=self.llm, sources=sources, adapters=adapters, emit=self.emit,
            is_paused=self.is_paused, hooks=self.hooks,
        )
        self.pipeline.notifier = self.notifier
        self.coordinator = RunCoordinator(self._begin_run, self.pipeline.execute, caffeinate_factory=self.caffeinate_factory)
        prefs = db.get_preferences(self.conn)
        last = db.get_current_run(self.conn) or db.get_last_run(self.conn)
        self.scheduler = self._scheduler_arg or Scheduler(prefs.schedule, last_run=last.started_at if last else None)

    async def recover(self) -> db.RecoveryReport:
        """Crash recovery: submitting -> unknown_verify, prepping/filling -> queued; close runs."""
        report = db.recover_after_crash(self.conn)
        abandoned = db.abandon_unfinished_runs(self.conn)
        for t in [*report.unknown_verify, *report.requeued]:
            await self.broadcast("application_state", t.to_payload())
        if report.unknown_verify:
            await self.broadcast("error", ErrorPayload(
                code=ErrorCode.INTERNAL,
                message=f"{len(report.unknown_verify)} application(s) were mid-submit when the daemon stopped; please verify them.",
                details={"application_ids": [t.application_id for t in report.unknown_verify], "reason": "crash_during_submit"},
            ))
        if report.unknown_verify or report.requeued or abandoned:
            log.warning("recovery: %d unknown_verify, %d requeued, %d runs abandoned",
                        len(report.unknown_verify), len(report.requeued), abandoned)
        return report

    async def start(self) -> None:
        if self._started:
            return
        self.paths.ensure()
        self.lock.acquire()
        try:
            self._ensure_core()
            await self.recover()
            if self.socket_path.exists() or self.socket_path.is_symlink():
                self.socket_path.unlink()  # stale: we hold the lock, so nobody is serving it
            if len(str(self.socket_path).encode()) > 103:
                raise RuntimeError(f"socket path too long for AF_UNIX: {self.socket_path}")
            old_umask = os.umask(0o177)
            try:
                self._server = await asyncio.start_unix_server(self._on_client, path=str(self.socket_path), limit=MAX_LINE_BYTES + 1)
            finally:
                os.umask(old_umask)
            os.chmod(self.socket_path, 0o600)
        except BaseException:
            self.lock.release()
            raise
        self._started = True
        self._stopped.clear()
        if self.enable_scheduler:
            self._spawn(self._scheduler_loop(), name="scheduler")
        if self.enable_maintenance:
            self._spawn(self._maintenance_loop(), name="maintenance")
        log.info("autoapplyd %s listening on %s (pid %d)", __version__, self.socket_path, os.getpid())

    async def serve(self) -> None:
        """Bind ``paths.socket`` (0600), accept clients, run the scheduler; until stopped."""
        await self.start()
        await self._stopped.wait()

    async def stop(self) -> None:
        if not self._started:
            if self._owns_conn and self._conn is not None:
                self._conn.close()
                self._conn = None
            return
        self._started = False
        log.info("autoapplyd stopping")
        if self.scheduler is not None:
            self.scheduler.stop()
        if self.coordinator is not None:
            await self.coordinator.cancel()
        for t in list(self._tasks):
            t.cancel()
        for t in list(self._tasks):
            with contextlib.suppress(BaseException):
                await t
        if self.pipeline is not None:
            await self.pipeline.close_adapters()
        if self._server is not None:
            self._server.close()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self._server.wait_closed(), timeout=2)
            self._server = None
        for c in list(self.clients):
            c.close()
            if c.sender is not None:
                with contextlib.suppress(BaseException):
                    await asyncio.wait_for(c.sender, timeout=1)
        self.clients.clear()
        with contextlib.suppress(FileNotFoundError):
            self.socket_path.unlink()
        if self._owns_conn and self._conn is not None:
            self._conn.close()
            self._conn = None
            self.pipeline = None
        self.lock.release()
        self._stopped.set()

    def _spawn(self, coro: Awaitable[Any], *, name: str) -> asyncio.Task[Any]:
        # Fresh context: background work must not see a command's deferred-event buffer.
        task = asyncio.get_running_loop().create_task(coro, name=name, context=contextvars.Context())  # type: ignore[arg-type]
        self._tasks.add(task)
        task.add_done_callback(self._task_done)
        return task

    def _task_done(self, task: asyncio.Task[Any]) -> None:
        self._tasks.discard(task)
        if not task.cancelled() and task.exception() is not None:
            log.error("background task %s failed", task.get_name(), exc_info=task.exception())

    # ---- events ------------------------------------------------------------------------

    def is_paused(self) -> bool:
        return self.paused

    async def emit(self, event_type: str, payload: BaseModel | dict[str, Any]) -> None:
        """EmitFn for the pipeline / sources: deferred while a command is being handled."""
        buf = _DEFERRED.get()
        if buf is not None:
            buf.append((event_type, payload))
        else:
            await self.broadcast(event_type, payload)

    async def broadcast(self, event_type: str, payload: BaseModel | dict[str, Any]) -> None:
        """Send an event to every connected client."""
        env = make_event(event_type, payload)
        if self.notifier is not None:
            await self.notifier.on_event(event_type, payload)
        if event_type == "state":
            st = StatePayload.model_validate(env.payload)
            self.state = st.model_copy(update={"paused": self.paused})
        for c in list(self.clients):
            if not c.send(env):
                self.clients.discard(c)

    async def _broadcast_state(self, **update: Any) -> None:
        await self.emit("state", self.state.model_copy(update={"paused": self.paused, **update}))

    # ---- connections -------------------------------------------------------------------

    async def _on_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        client = Client(reader, writer)
        inflight = asyncio.Semaphore(MAX_INFLIGHT_PER_CLIENT)
        client.sender = asyncio.create_task(client.run_sender(), name=f"client-{client.id}-tx")
        self.clients.add(client)
        log.info("client %s connected", client.id, extra={"client": client.id})
        try:
            while not client.closed:
                try:
                    line = await reader.readline()
                except ValueError:  # line longer than MAX_LINE_BYTES (buffer was discarded)
                    client.send(make_event("error", ErrorPayload(code=ErrorCode.BAD_REQUEST, message=f"line exceeds {MAX_LINE_BYTES} bytes")))
                    continue
                except (ConnectionError, OSError):
                    break
                if not line:
                    break
                if not line.strip():
                    continue
                # Each line is handled in its own task so a slow command (LLM resume parse,
                # system check) never stops the kill switch from being read. Ordinary commands
                # still run one at a time, in arrival order (FIFO on ``_cmd_lock``).
                await inflight.acquire()
                task = self._spawn(self._process_line(client, line), name=f"client-{client.id}-cmd")
                task.add_done_callback(lambda _t: inflight.release())
        finally:
            self.clients.discard(client)
            client.close()
            log.info("client %s disconnected", client.id, extra={"client": client.id})

    async def _process_line(self, client: Client, line: bytes) -> None:
        try:
            env, _payload = decode_line(line, expect="command")
        except ProtocolError as e:
            client.send(e.to_event())
            return
        if env.type == "hello":
            client.kind = str(env.payload.get("client", "app"))
        replies, deferred = await self._handle(env)
        for r in replies:
            client.send(r)
        for event_type, payload in deferred:
            await self.broadcast(event_type, payload)

    async def handle(self, envelope: Envelope) -> list[Envelope]:
        """Dispatch one decoded command; returns the reply event(s) (ack/error/snapshot).

        Side-effect events are broadcast to connected clients after the reply is computed.
        """
        self._ensure_core()
        replies, deferred = await self._handle(envelope)
        for event_type, payload in deferred:
            await self.broadcast(event_type, payload)
        return replies

    async def _handle(self, env: Envelope) -> tuple[list[Envelope], list[tuple[str, Any]]]:
        buf: list[tuple[str, Any]] = []
        token = _DEFERRED.set(buf)
        try:
            if env.type in _UNLOCKED_COMMANDS:
                # Kill switch / liveness: never queued behind a slow command (ack < 2s).
                reply = await self._dispatch(env)
            else:
                async with self._cmd_lock:
                    reply = await self._dispatch(env)
        finally:
            _DEFERRED.reset(token)
        return [reply], buf

    async def _dispatch(self, env: Envelope) -> Envelope:
        extra = {"command": env.type, "command_id": env.id}
        try:
            payload = env.typed_payload()
            if env.type not in _COMMANDS:
                raise ProtocolError(ErrorCode.UNKNOWN_TYPE, f"unknown command type {env.type!r}", msg_id=env.id)
            handler = getattr(self, f"_cmd_{env.type}")
            result = await handler(payload)
            if env.type == "hello":
                return make_event("snapshot", result, reply_to=env.id)
            if isinstance(result, BaseModel):
                result = result.model_dump(mode="json")
            log.info("command %s ok", env.type, extra=extra)
            return make_event("ack", {"ok": True, "result": result}, reply_to=env.id)
        except ProtocolError as e:
            return self._error(env, e.code, e.message, details=e.details)
        except CommandError as e:
            return self._error(env, e.code, e.message, details=e.details, job_id=e.job_id, application_id=e.application_id)
        except db.IllegalTransition as e:
            return self._error(env, ErrorCode.ILLEGAL_TRANSITION, str(e),
                               details={"state": e.from_state.value if e.from_state else None, "to": e.to_state.value},
                               application_id=e.application_id)
        except (db.NotFound, FileNotFoundError) as e:
            return self._error(env, ErrorCode.NOT_FOUND, str(e))
        except (db.Conflict, RunConflict) as e:
            return self._error(env, ErrorCode.CONFLICT, str(e))
        except PausedError as e:
            return self._error(env, ErrorCode.PAUSED, str(e) or "paused")
        except ValidationError as e:
            return self._error(env, ErrorCode.INVALID_PAYLOAD, "invalid value", details={"errors": json.loads(e.json(include_url=False))})
        except ValueError as e:
            return self._error(env, ErrorCode.INVALID_PAYLOAD, str(e))
        except Exception as e:  # noqa: BLE001
            log.exception("command %s failed", env.type, extra=extra)
            return self._error(env, ErrorCode.INTERNAL, f"{type(e).__name__}: {e}")

    def _error(self, env: Envelope, code: ErrorCode, message: str, **kw: Any) -> Envelope:
        log.info("command %s -> error %s: %s", env.type, code.value, message, extra={"command": env.type, "command_id": env.id})
        return make_event("error", ErrorPayload(code=code, message=message, **kw), reply_to=env.id)

    # ---- snapshot ----------------------------------------------------------------------

    def source_statuses(self) -> list[SourceStatus]:
        prefs = db.get_preferences(self.conn)
        meta = load_source_statuses(self.conn)
        out: list[SourceStatus] = []
        for name in SourceName:
            enabled = bool(prefs.sources_enabled.get(name.value, False))
            m = meta.get(name.value) or {}
            needs_login = name in (SourceName.LINKEDIN, SourceName.GLASSDOOR)
            connected = bool(m.get("connected", False)) if needs_login else enabled
            out.append(SourceStatus(
                source=name, enabled=enabled, connected=connected, checked_at=m.get("checked_at"),
                detail=m.get("detail") if needs_login else ("Public job boards · no login" if name is not SourceName.CAREERS else "Company career pages"),
            ))
        return out

    def build_snapshot(self) -> SnapshotPayload:
        self._ensure_core()
        conn = self.conn
        prefs = db.get_preferences(conn)
        live = self.pipeline.live_run_info() if self.pipeline else None
        current = live
        if current is None:
            cur = db.get_current_run(conn)
            current = db.run_info(cur) if cur else None
        last = db.get_last_run(conn)
        onboarding = db.get_meta(conn, db.META_ONBOARDING, {}) or {}
        state = self.state.model_copy(update={"paused": self.paused})
        if current is None and state.daemon is not DaemonActivity.IDLE:
            state = StatePayload(daemon=DaemonActivity.IDLE, paused=self.paused)
        return SnapshotPayload(
            protocol_version=PROTOCOL_VERSION, daemon_version=__version__, state=state, mode=prefs.mode,
            next_run_at=self.scheduler.next_run_at() if self.scheduler else None,
            current_run=current, last_run=db.run_info(last) if last else None,
            counts=db.compute_counts(conn), caps=db.compute_caps(conn, prefs),
            open_clusters=db.list_open_clusters(conn), sources=self.source_statuses(),
            onboarding=OnboardingState(completed=bool(onboarding.get("completed", False)), step=int(onboarding.get("step", 0))),
            preferences=prefs,
        )

    # ---- runs --------------------------------------------------------------------------

    async def _begin_run(self, kind: RunKind, trigger: RunTrigger) -> Any:
        if self.paused:
            raise PausedError("paused")
        assert self.pipeline is not None
        try:
            return await self.pipeline.begin(kind, trigger)
        except db.Conflict as e:
            raise RunConflict(str(e)) from e

    async def start_run(self, kind: RunKind, trigger: RunTrigger) -> str:
        assert self.coordinator is not None
        # Begin inside the command (so run_started is deferred after the ack); the coordinator
        # executes the run detached, in a fresh context.
        run = await self.coordinator.start(kind, trigger)
        return str(run.run_uid)

    async def _scheduler_loop(self) -> None:
        assert self.scheduler is not None and self.coordinator is not None

        async def on_fire(trigger: RunTrigger) -> None:
            if self.paused:
                log.info("scheduled run skipped: paused")
                return
            if self.coordinator.busy:  # type: ignore[union-attr]
                log.info("scheduled run skipped: a run is already active")
                return
            try:
                await self.coordinator.run(RunKind.FULL, trigger)  # type: ignore[union-attr]
            except (RunConflict, PausedError) as e:
                log.info("scheduled run skipped: %s", e)

        await self.scheduler.run_forever(on_fire)

    async def _maintenance_loop(self) -> None:
        while True:
            try:
                if self.pipeline is not None and not (self.coordinator and self.coordinator.busy):
                    await self.pipeline.maintenance()
            except Exception:  # noqa: BLE001
                log.exception("maintenance failed")
            await asyncio.sleep(MAINTENANCE_INTERVAL)

    # =================================================================================
    # Command handlers (one per protocol command; payloads are already validated)
    # =================================================================================

    async def _cmd_hello(self, p: Any) -> SnapshotPayload:
        return self.build_snapshot()

    async def _cmd_ping(self, p: Any) -> None:
        return None

    async def _cmd_run_now(self, p: Any) -> dict[str, Any]:
        if self.paused:
            raise PausedError("AutoApply is paused; resume first")
        return {"run_id": await self.start_run(RunKind(p.kind), RunTrigger.MANUAL)}

    async def _set_paused(self, value: bool) -> None:
        self.paused = value
        db.set_meta(self.conn, db.META_PAUSED, value)
        db.log_event(self.conn, "user", "paused all" if value else "resumed", actor=Actor.USER)
        await self._broadcast_state()

    async def _cmd_pause_all(self, p: Any) -> None:
        await self._set_paused(True)

    async def _cmd_resume(self, p: Any) -> None:
        await self._set_paused(False)

    async def _transition(self, application_id: int, to: AppState, *, reason: str | None = None,
                          actor: Actor = Actor.USER, expected_from: Any = None) -> db.Transition:
        t = db.transition(self.conn, application_id, to, reason=reason, actor=actor, expected_from=expected_from)
        await self.emit("application_state", t.to_payload())
        return t

    def _save_never_guess(self, key: str, answer: str) -> None:
        if key not in NeverGuess.model_fields:
            raise ValueError(f"unknown never_guess key {key!r}")
        if key == "work_auth":
            raise ValueError("work authorization is per country; set it in Settings ▸ Profile instead of save_to_profile")
        ann = NeverGuess.model_fields[key].annotation
        value: Any = answer
        if ann in (bool, bool | None):
            low = answer.strip().lower()
            if low in {"yes", "y", "true", "1"}:
                value = True
            elif low in {"no", "n", "false", "0"}:
                value = False
            else:
                raise ValueError(f"{key} needs a yes/no answer")
        db.set_never_guess(self.conn, {key: value})

    def _save_memory(self, question: str, answer: str, field_type: str) -> int:
        try:
            from autoapply.answers.memory import AnswerMemory

            return AnswerMemory(self.conn).save(question, answer, source="user", field_type=field_type).id
        except NotImplementedError:
            return db.add_answer(self.conn, canonical_question=question, answer=answer, field_type=field_type).id

    async def _cmd_answer_question(self, p: Any) -> dict[str, Any]:
        per_job = {pj.job_id: pj.answer for pj in p.per_job_answers}
        try:
            from autoapply import prep

            outcome = prep.answer_cluster(
                self.conn, p.cluster_id, p.answer, save_to_memory=p.save_to_memory,
                save_to_profile=p.save_to_profile, per_job_answers=per_job,
            )
        except (ImportError, NotImplementedError):
            return await self._answer_question_local(p, per_job)
        # protocol.md §5: question_resolved first, then application_state (needs_you -> queued).
        await self.emit("question_resolved", outcome.to_payload())
        for t in outcome.transitions:
            await self.emit("application_state", t.to_payload())
        # One answer (e.g. work authorisation saved to the profile) can answer other open questions.
        if self.pipeline is not None:
            await self.pipeline.auto_resolve_inbox()
        return {"answer_id": outcome.answer_id, "resumed_application_ids": outcome.application_ids}

    async def _answer_question_local(self, p: Any, per_job: dict[int, str]) -> dict[str, Any]:
        """Fallback used only while ``prep.answer_cluster`` is unavailable."""
        cluster = db.get_cluster(self.conn, p.cluster_id)
        if cluster is None:
            raise db.NotFound(f"open cluster {p.cluster_id!r} not found")
        answer_id: int | None = None
        is_action = cluster.kind == QuestionKind.ACTION.value  # "done, retry": never memory / profile / form answers
        with db.transaction(self.conn):
            saved_profile = False
            if p.save_to_profile and cluster.never_guess_key and not is_action:
                self._save_never_guess(cluster.never_guess_key, p.answer)
                saved_profile = True
            if p.save_to_memory and not saved_profile and not is_action and p.answer.strip():
                answer_id = self._save_memory(cluster.canonical_question, p.answer, cluster.field_type.value)
            job_ids = db.resolve_cluster(self.conn, p.cluster_id, status=QuestionStatus.ANSWERED, answer_text=p.answer, answer_id=answer_id)
            for job_id in job_ids:
                text = per_job.get(job_id)
                if is_action or (text is None and (saved_profile or answer_id is not None)):
                    continue
                app = db.get_application_by_job(self.conn, job_id)
                db.add_application_answer(
                    self.conn, app.id, question=cluster.canonical_question, answer=text if text is not None else p.answer,
                    origin=AnswerOrigin.USER, field_type=cluster.field_type, confidence=1.0, field_key=f"inbox:{p.cluster_id}",
                )
        resumed: list[int] = []
        transitions: list[db.Transition] = []
        for job_id in db.jobs_without_open_questions(self.conn, job_ids):
            app = db.get_application_by_job(self.conn, job_id)
            if app.state is AppState.NEEDS_YOU:
                transitions.append(db.transition(self.conn, app.id, AppState.QUEUED, reason="answered", actor=Actor.USER,
                                                 expected_from=AppState.NEEDS_YOU))
                resumed.append(app.id)
        await self.emit("question_resolved", QuestionResolvedPayload(
            cluster_id=p.cluster_id, status="answered", answer_id=answer_id, resumed_application_ids=resumed,
        ))
        for t in transitions:
            await self.emit("application_state", t.to_payload())
        return {"answer_id": answer_id, "resumed_application_ids": resumed}

    async def _cmd_skip_question(self, p: Any) -> dict[str, Any]:
        try:
            from autoapply import prep

            outcome = prep.skip_cluster(self.conn, p.cluster_id, reason=p.reason)
        except (ImportError, NotImplementedError):
            outcome = None
        if outcome is not None:
            await self.emit("question_resolved", outcome.to_payload())
            for t in outcome.transitions:
                await self.emit("application_state", t.to_payload())
            # Clusters emptied / shrunk as a side effect of skipping this job's questions.
            for extra in getattr(outcome, "extra_resolved_payloads", lambda: [])():
                await self.emit("question_resolved", extra)
            for cid in getattr(outcome, "changed", ()) or ():
                try:
                    await self.emit("question_opened", QuestionOpenedPayload(cluster=db.get_cluster(self.conn, cid)))
                except db.NotFound:
                    pass
            return {"skipped_application_ids": outcome.application_ids}
        job_ids = db.resolve_cluster(self.conn, p.cluster_id, status=QuestionStatus.SKIPPED, answer_text=p.reason)
        skipped: list[int] = []
        for job_id in job_ids:
            app = db.get_application_by_job(self.conn, job_id)
            if app.state is AppState.NEEDS_YOU:
                await self._transition(app.id, AppState.SKIPPED, reason=p.reason or "question_skipped", expected_from=AppState.NEEDS_YOU)
                skipped.append(app.id)
            db.remove_job_from_questions(self.conn, job_id)
        await self.emit("question_resolved", QuestionResolvedPayload(cluster_id=p.cluster_id, status="skipped", resumed_application_ids=[]))
        return {"skipped_application_ids": skipped}

    async def _cmd_approve(self, p: Any) -> dict[str, Any]:
        assert self.pipeline is not None
        ids = list(dict.fromkeys(p.application_ids))
        apps = [db.get_application(self.conn, i) for i in ids]
        for a in apps:
            if a.state is not AppState.AWAITING_REVIEW:
                raise db.IllegalTransition(a.id, a.state, AppState.SUBMITTING, Actor.USER, "not awaiting review")
        prefs = db.get_preferences(self.conn)
        companies: set[int] = set()
        for n, a in enumerate(apps):
            job = db.get_job(self.conn, a.job_id)
            check = self.pipeline.submit_gate(job, prefs, pending=n, application_id=a.id)
            if check.allowed and job.company_id in companies and prefs.per_company_cooldown_days > 0:
                check = SubmitCheck(allowed=False, cap=CapKind.COMPANY_COOLDOWN, reason="company_cooldown",
                                    used=0, limit=prefs.per_company_cooldown_days)
            if not check.allowed:
                if check.reason == "paused":
                    raise PausedError("AutoApply is paused; resume first")
                await self.pipeline.emit_cap(check, job.company_id)
                raise CommandError(ErrorCode.CAP_REACHED, f"{check.reason}: cannot submit application {a.id} now",
                                   details={"cap": check.cap.value if check.cap else None, "used": check.used, "limit": check.limit},
                                   application_id=a.id, job_id=job.id)
            companies.add(job.company_id)
        for a in apps:
            t = db.begin_submit(self.conn, a.id, actor=Actor.USER)
            await self.emit("application_state", t.to_payload())
        self._spawn(self.pipeline.submit_approved(ids), name="submit-approved")
        return {"application_ids": ids}

    async def _cmd_reject(self, p: Any) -> None:
        await self._transition(p.application_id, AppState.SKIPPED, reason=p.reason, expected_from=AppState.AWAITING_REVIEW)

    async def _cmd_set_status(self, p: Any) -> None:
        payload = db.set_status(self.conn, p.application_id, p.status, actor=Actor.USER)
        await self.emit("application_status", payload)

    async def _cmd_update_preferences(self, p: Any) -> dict[str, Any]:
        patch = p.preferences.model_dump(exclude_unset=True, mode="json")
        prefs = db.update_preferences(self.conn, patch)
        if "schedule" in patch and self.scheduler is not None:
            self.scheduler.update_schedule(prefs.schedule)
        return {"preferences": prefs.model_dump(mode="json")}

    async def _cmd_update_never_guess(self, p: Any) -> dict[str, Any]:
        ng = db.set_never_guess(self.conn, p.values.model_dump(exclude_unset=True, mode="json"))
        # Reply as soon as the facts are stored: re-checking open Needs-You questions against them can
        # take seconds (embeddings), and a slow ack made the app report "not saved" for a saved edit.
        if self.pipeline is not None:
            self._spawn(self.pipeline.auto_resolve_inbox(), name="auto-resolve-inbox")
        return {"never_guess": ng.model_dump(mode="json")}

    async def _cmd_update_profile(self, p: Any) -> dict[str, Any]:
        profile = db.update_profile(self.conn, p.profile.model_dump(exclude_unset=True, mode="json"))
        return {"profile": profile.model_dump(mode="json")}

    async def _import_resume(self, file_path: str, label: str, tags: list[str], is_default: bool) -> tuple[int, str | None]:
        src = Path(file_path).expanduser()
        if not src.is_file():
            raise FileNotFoundError(f"resume file not found: {src}")
        # The same PDF added again (e.g. re-doing onboarding) reuses the stored variant.
        src_hash = await asyncio.to_thread(lambda: hashlib.sha256(src.read_bytes()).hexdigest())
        for existing in db.list_resume_variants(self.conn):
            ep = Path(existing.file_path)
            if ep.is_file() and await asyncio.to_thread(lambda ep=ep: hashlib.sha256(ep.read_bytes()).hexdigest()) == src_hash:
                return existing.id, await asyncio.to_thread(extract_pdf_text, ep)
        self.paths.resumes.mkdir(parents=True, exist_ok=True)
        safe = re.sub(r"[^\w.-]+", "_", src.name)[:80] or "resume.pdf"
        dest = self.paths.resumes / f"{uuid.uuid4().hex[:8]}_{safe}"
        await asyncio.to_thread(shutil.copy2, src, dest)
        text = await asyncio.to_thread(extract_pdf_text, dest)
        variant = db.add_resume_variant(self.conn, label=label, file_path=str(dest), tags=tags, text=text, is_default=is_default)
        db.log_event(self.conn, "user", f"added resume {label!r}", actor=Actor.USER, payload={"resume_variant_id": variant.id})
        return variant.id, text

    async def _cmd_add_resume_variant(self, p: Any) -> dict[str, Any]:
        vid, _ = await self._import_resume(p.file_path, p.label, list(p.tags), p.is_default)
        return {"resume_variant_id": vid}

    async def _cmd_update_resume_variant(self, p: Any) -> None:
        db.update_resume_variant(self.conn, p.id, label=p.label, tags=p.tags, enabled=p.enabled, is_default=p.is_default)

    async def _cmd_upsert_story(self, p: Any) -> dict[str, Any]:
        story = db.upsert_story(self.conn, id=p.id, title=p.title, situation=p.situation, task=p.task,
                                action=p.action, result=p.result, tags=p.tags)
        return {"story_id": story.id}

    async def _cmd_delete_story(self, p: Any) -> None:
        db.delete_story(self.conn, p.id)

    async def _cmd_update_answer(self, p: Any) -> None:
        db.update_answer(self.conn, p.answer_id, answer=p.answer, canonical_question=p.canonical_question)

    async def _cmd_delete_answer(self, p: Any) -> None:
        db.delete_answer(self.conn, p.answer_id)

    async def _cmd_edit_application_answer(self, p: Any) -> None:
        db.edit_application_answer(self.conn, p.application_answer_id, p.answer)

    async def _cmd_set_job_mode(self, p: Any) -> None:
        db.set_job_mode_override(self.conn, p.job_id, p.mode)

    async def _cmd_retry_application(self, p: Any) -> None:
        await self._transition(p.application_id, AppState.QUEUED, reason="user_retry", expected_from=AppState.FAILED)

    async def _cmd_resolve_unknown(self, p: Any) -> None:
        to = AppState.SUBMITTED if p.submitted else AppState.FAILED
        reason = "user_verified_submitted" if p.submitted else "user_verified_not_submitted"
        await self._transition(p.application_id, to, reason=reason, expected_from=AppState.UNKNOWN_VERIFY)

    async def _cmd_apply_anyway(self, p: Any) -> None:
        await self._transition(p.application_id, AppState.QUEUED, reason="user_apply_anyway", expected_from=AppState.SKIPPED)

    async def _cmd_add_job_url(self, p: Any) -> dict[str, Any]:
        """Add a job from a pasted link and queue it as the user's choice (``user_added_link``
        exempts it from the hard filters, like "apply anyway"); fills right away unless paused."""
        from autoapply.manual_job import InvalidJobUrl, fetch_job_meta, normalize_job_url

        assert self.pipeline is not None
        try:
            url = normalize_job_url(p.url)
        except InvalidJobUrl as exc:
            raise CommandError(ErrorCode.INVALID_PAYLOAD, str(exc)) from exc
        existing = db.find_job_by_apply_url(self.conn, url)
        if existing is None:
            meta = await fetch_job_meta(url)
            company = db.upsert_company(self.conn, (p.company or "").strip() or meta.company)
            job, created = db.insert_job(
                self.conn, company_id=company.id, source=JobSource.MANUAL, title=(p.title or "").strip() or meta.title,
                location=meta.location, apply_url=url, source_url=url, ats=meta.ats, external_id=meta.external_id,
                description=meta.description, posted_at=meta.posted_at, raw={"added_by_link": True},
            )
        else:
            job, created = existing, False
        app = db.get_application_by_job(self.conn, job.id)
        reason = "user_added_link"
        if app.state is AppState.DISCOVERED:
            await self._transition(app.id, AppState.SCORED, reason=reason)
            await self._transition(app.id, AppState.QUEUED, reason=reason)
        elif app.state in (AppState.SCORED, AppState.SKIPPED, AppState.FAILED):
            await self._transition(app.id, AppState.QUEUED, reason=reason)
        app = db.get_application(self.conn, app.id)
        starting = bool(p.apply_now) and app.state is AppState.QUEUED and not self.is_paused()
        if starting:
            self._spawn(self.pipeline.apply_detached(app.id), name=f"apply-link-{app.id}")
        return {"job_id": job.id, "application_id": app.id, "created": created, "state": app.state.value,
                "title": job.title, "company": db.get_company(self.conn, job.company_id).name, "started": starting}

    async def _cmd_update_job_notes(self, p: Any) -> None:
        notes = (p.notes or "").strip() or None
        db.update_job(self.conn, p.job_id, notes=notes)

    async def _cmd_set_application_resume(self, p: Any) -> dict[str, Any]:
        app = db.get_application(self.conn, p.application_id)
        variant = db.get_resume_variant(self.conn, p.resume_variant_id)
        if not variant.enabled:
            raise ValueError(f"resume variant {variant.id} is disabled")
        swappable = {AppState.DISCOVERED, AppState.SCORED, AppState.QUEUED, AppState.NEEDS_YOU,
                     AppState.AWAITING_REVIEW, AppState.FAILED, AppState.SKIPPED}
        if app.state not in swappable:
            raise CommandError(ErrorCode.CONFLICT, f"cannot change the resume while the application is {app.state.value}",
                               details={"state": app.state.value}, application_id=app.id, job_id=app.job_id)
        db.update_application(self.conn, app.id, resume_variant_id=variant.id)
        requeued = False
        if app.state is AppState.AWAITING_REVIEW and app.resume_variant_id != variant.id:
            # The reviewed form was filled with the old file: re-fill before it can be approved.
            await self._transition(app.id, AppState.QUEUED, reason="resume_swapped", expected_from=AppState.AWAITING_REVIEW)
            requeued = True
        return {"requeued": requeued}

    async def _cmd_mark_easy_apply_done(self, p: Any) -> dict[str, Any]:
        before = db.get_application_by_job(self.conn, p.job_id)
        app = db.mark_easy_apply_done(self.conn, p.job_id)
        await self.emit("application_state", ApplicationStatePayload(
            application_id=app.id, job_id=app.job_id, from_state=before.state, to_state=AppState.SUBMITTED,
            reason="manual_easy_apply", actor=Actor.USER, at=app.state_updated_at,
        ))
        return {"application_id": app.id}

    async def _cmd_mark_easy_apply_opened(self, p: Any) -> None:
        db.mark_easy_apply_opened(self.conn, p.job_id)

    async def _cmd_dismiss_easy_apply(self, p: Any) -> None:
        db.dismiss_easy_apply(self.conn, p.job_id)

    async def _cmd_accept_company_suggestion(self, p: Any) -> dict[str, Any]:
        """Settings > Sources > Suggested companies > Add: watch it (ATS board, else its career page)."""
        company = db.accept_company_suggestion(self.conn, p.suggestion_id)
        db.log_event(self.conn, "user", f"added {company.name} to the watched companies", actor=Actor.USER)
        return {"company_id": company.id}

    async def _cmd_dismiss_company_suggestion(self, p: Any) -> None:
        """Dismiss: never suggest it again (one the agent added by itself is unwatched)."""
        s = db.dismiss_company_suggestion(self.conn, p.suggestion_id)
        db.log_event(self.conn, "user", f"dismissed the suggested company {s.company_name}", actor=Actor.USER)

    def _require_browser_free(self, what: str) -> asyncio.Lock:
        assert self.pipeline is not None
        lock = self.pipeline.browser_lock
        if lock.locked():
            raise CommandError(
                ErrorCode.CONFLICT,
                f"AutoApply's browser is busy with a run, so {what} has to wait. Press the pause button (top left), "
                "wait a few seconds, then try again.",
                details={"reason": "browser_busy"},
            )
        return lock

    async def _cmd_open_agent_chrome(self, p: Any) -> None:
        self._require_browser_free("opening Chrome")
        try:
            await asyncio.to_thread(self.chrome_launcher, self.paths.chrome_profile, p.url)
        except Exception as e:  # noqa: BLE001
            raise CommandError(ErrorCode.UNAVAILABLE, f"could not open Chrome: {e}") from e

    async def _cmd_onboarding_system_check(self, p: Any) -> SystemCheckResult:
        return await asyncio.to_thread(self.system_check)

    async def _parse_profile(self, text: str | None) -> tuple[dict[str, Any], list[str]]:
        if not text:
            return {}, ["full_name", "email", "phone", "location", "work_history", "education", "skills"]
        if self.llm is not None:
            try:
                res = await self.llm.complete(RESUME_PROMPT.format(text=text[:20000]), schema=RESUME_SCHEMA, tier="fast",
                                              system="You extract structured data from resumes. Never invent facts.")
                data = res.data or {}
                raw = {k: v for k, v in (data.get("profile") or {}).items() if v not in (None, "", [], {})}
                patch = ProfilePatch.model_validate(raw).model_dump(exclude_unset=True, mode="json")
                return patch, [f for f in data.get("uncertain_fields", []) if isinstance(f, str)]
            except Exception:  # noqa: BLE001 - fall back to offline heuristics
                log.warning("LLM resume parse failed; using heuristics", exc_info=True)
        return heuristic_profile(text)

    async def _cmd_onboarding_parse_resume(self, p: Any) -> ParseResumeResult:
        first = not db.list_resume_variants(self.conn)
        label = p.label or Path(p.file_path).stem
        vid, text = await self._import_resume(p.file_path, label, [], first)
        patch, uncertain = await self._parse_profile(text)
        if text:
            patch["raw_text"] = text
        # Prefer the resume's real hyperlinks over the visible link text the model read.
        variant = db.get_resume_variant(self.conn, vid)
        real = await asyncio.to_thread(extract_pdf_links, Path(variant.file_path))
        if real:
            patch["links"] = {**(patch.get("links") or {}), **real}
        profile: Profile = db.update_profile(self.conn, patch) if patch else db.get_profile(self.conn)
        from autoapply.prefs_suggest import suggest_preferences

        suggested = await suggest_preferences(profile, self.llm)
        return ParseResumeResult(resume_variant_id=vid, profile=profile, uncertain_fields=uncertain,
                                 suggested_preferences=suggested)

    async def _cmd_suggest_preferences(self, p: Any) -> dict[str, Any]:
        """Roles / seniority / locations suggested from the stored profile (Settings: "Fill from resume")."""
        from autoapply.prefs_suggest import suggest_preferences

        return (await suggest_preferences(db.get_profile(self.conn), self.llm)).model_dump(mode="json")

    def make_source(self, name: str) -> BrowserListingBase:
        if self._source_factory is not None:
            return self._source_factory(name)
        from autoapply.discovery.glassdoor import GlassdoorSource
        from autoapply.discovery.linkedin import LinkedinSource

        cls = LinkedinSource if name == "linkedin" else GlassdoorSource
        return cls(self.conn, emit=self.emit, profile_dir=self.paths.chrome_profile, is_paused=self.is_paused)

    async def _connect_source(self, name: str) -> None:
        try:
            src = self.make_source(name)
            ok = await src.connect()
            if ok:
                prefs = db.get_preferences(self.conn)
                db.update_preferences(self.conn, {"sources_enabled": {**prefs.sources_enabled, name: True}})
                status = record_source_status(self.conn, name, connected=True, detail=f"{name.capitalize()} connected")
                await self.emit("source_status", SourceStatusPayload(source=status))
        except Exception as e:  # noqa: BLE001
            log.exception("connect %s failed", name)
            status = record_source_status(self.conn, name, connected=False, detail=f"Could not open the login window: {e}")
            await self.emit("source_status", SourceStatusPayload(source=status))
            await self.emit("error", ErrorPayload(code=ErrorCode.UNAVAILABLE, message=f"Could not connect {name}: {e}",
                                                  details={"source": name}))

    async def _cmd_onboarding_connect_source(self, p: Any) -> None:
        lock = self._require_browser_free("connecting")
        await lock.acquire()  # free (checked above, no await in between): returns at once
        try:
            task = self._spawn(self._connect_source(p.source), name=f"connect-{p.source}")
        except BaseException:
            lock.release()
            raise
        # Held for the whole login window; released even if the task is cancelled early.
        task.add_done_callback(lambda _t: lock.release())

    async def _cmd_set_mail_account(self, p: Any) -> dict[str, Any]:
        """Connect the mailbox security codes arrive in: log in once to check, then keep the password
        in the macOS Keychain (never in the DB) and the address in meta."""
        from autoapply.mail import imap_codes

        address = p.email.strip()
        if "@" not in address:
            raise CommandError(ErrorCode.INVALID_PAYLOAD, "enter a full email address")
        try:
            await asyncio.to_thread(imap_codes.test_login, address, p.app_password)
            await asyncio.to_thread(imap_codes.keychain_set, address, p.app_password)
        except imap_codes.MailError as e:
            raise CommandError(ErrorCode.UNAVAILABLE, str(e)) from e
        old = imap_codes.account(self.conn)
        if old and old["email"] != address:
            await asyncio.to_thread(imap_codes.keychain_delete, old["email"])
        db.set_meta(self.conn, imap_codes.META_KEY, {"email": address, "enabled": True, "connected_at": utcnow().isoformat()})
        db.log_event(self.conn, "user", f"connected mailbox {address} for security codes", actor=Actor.USER)
        return {"email": address, "connected": True, "error": None}

    async def _cmd_get_mail_account(self, p: Any) -> dict[str, Any]:
        from autoapply.mail import imap_codes

        acc = imap_codes.account(self.conn)
        if not acc:
            return {"email": None, "connected": False, "error": None}
        if not p.test:
            return {"email": acc["email"], "connected": True, "error": None}
        password = await asyncio.to_thread(imap_codes.keychain_get, acc["email"])
        if not password:
            return {"email": acc["email"], "connected": False, "error": "the app password is missing from the Keychain; reconnect"}
        try:
            await asyncio.to_thread(imap_codes.test_login, acc["email"], password)
        except imap_codes.MailError as e:
            return {"email": acc["email"], "connected": False, "error": str(e)}
        return {"email": acc["email"], "connected": True, "error": None}

    async def _cmd_clear_mail_account(self, p: Any) -> dict[str, Any]:
        from autoapply.mail import imap_codes

        acc = imap_codes.account(self.conn)
        if acc:
            await asyncio.to_thread(imap_codes.keychain_delete, acc["email"])
        db.set_meta(self.conn, imap_codes.META_KEY, None)
        return {"email": None, "connected": False, "error": None}

    async def _cmd_reset_source_cap(self, p: Any) -> dict[str, Any]:
        """Settings > "Reset today's reads": zero the day's browsing-session counter for one source."""
        db.reset_source_sessions(self.conn, p.source)
        prefs = db.get_preferences(self.conn)
        limit = prefs.linkedin_sessions_per_day if p.source == "linkedin" else prefs.glassdoor_sessions_per_day
        kind = CapKind.LINKEDIN_BUDGET if p.source == "linkedin" else CapKind.GLASSDOOR_BUDGET
        db.log_event(self.conn, "user", f"reset today's {p.source} read budget", actor=Actor.USER)
        await self.emit("cap_reached", CapReachedPayload(cap=kind, used=0, limit=limit, resets_at=next_local_midnight()))
        return {"used": 0, "limit": limit}

    async def _cmd_check_source_login(self, p: Any) -> dict[str, Any]:
        """"Check now": is the saved Chrome profile logged in? Background window, no login prompt."""
        lock = self._require_browser_free("checking the login")
        await lock.acquire()
        try:
            connected = await self.make_source(p.source).check_login()
        finally:
            lock.release()
        return {"connected": connected}

    def _onboarding(self) -> dict[str, Any]:
        data = db.get_meta(self.conn, db.META_ONBOARDING, {}) or {}
        return {"completed": bool(data.get("completed", False)), "step": int(data.get("step", 0))}

    async def _cmd_onboarding_set_step(self, p: Any) -> None:
        db.set_meta(self.conn, db.META_ONBOARDING, {**self._onboarding(), "step": p.step})

    async def _cmd_onboarding_complete(self, p: Any) -> dict[str, Any]:
        db.set_meta(self.conn, db.META_ONBOARDING, {"completed": True, "step": 7})
        db.log_event(self.conn, "user", "onboarding completed", actor=Actor.USER)
        run_id: str | None = None
        if p.run_prep and not self.paused:
            try:
                run_id = await self.start_run(RunKind.PREP, RunTrigger.MANUAL)
            except RunConflict:
                run_id = None
        return {"run_id": run_id}

    async def log_line(self, level: LogLevel, message: str) -> None:
        await self.emit("log", LogPayload(level=level, message=message, logger=log.name, at=utcnow()))


#: Commands that bypass ``_cmd_lock``: they only flip in-memory/meta state or read, and
#: must answer even while a slow command (LLM call, subprocess, PDF parse) holds the lock.
_UNLOCKED_COMMANDS: frozenset[str] = frozenset({"hello", "ping", "pause_all", "resume"})

_COMMANDS: frozenset[str] = frozenset(
    name[len("_cmd_"):] for name in dir(Daemon) if name.startswith("_cmd_")
)


# =====================================================================================
# Entry point
# =====================================================================================


def main(argv: list[str] | None = None) -> None:
    """Entry point for the ``autoapplyd`` script / LaunchAgent."""
    parser = argparse.ArgumentParser(prog="autoapplyd", description="AutoApply background daemon")
    parser.add_argument("--home", help="data directory (default: $AUTOAPPLY_HOME or ~/Library/Application Support/AutoApply)")
    parser.add_argument("--no-scheduler", action="store_true", help="don't run scheduled pipeline runs")
    parser.add_argument("--log-level", default=os.environ.get("AUTOAPPLY_LOG_LEVEL", "info"))
    parser.add_argument("--version", action="version", version=f"autoapplyd {__version__}")
    args = parser.parse_args(argv)

    paths = get_paths(args.home, create=True)
    setup_logging(paths, getattr(logging, str(args.log_level).upper(), logging.INFO))
    daemon = Daemon(paths, enable_scheduler=not args.no_scheduler, notifier=Notifier(enabled=os.environ.get("AUTOAPPLY_NOTIFY", "1") != "0"))

    async def _run() -> None:
        loop = asyncio.get_running_loop()
        stop = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with contextlib.suppress(NotImplementedError):
                loop.add_signal_handler(sig, stop.set)
        try:
            await daemon.start()
        except DaemonAlreadyRunning as e:
            log.info("%s; exiting", e)
            return
        try:
            await stop.wait()
        finally:
            await daemon.stop()

    asyncio.run(_run())


if __name__ == "__main__":  # pragma: no cover
    main()
