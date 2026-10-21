"""macOS notifications from the daemon (works with the app closed).

Quiet by design: only events that need the user are notified (a question, a CAPTCHA,
a form waiting for review, a failure). No notification per submission.
"""

from __future__ import annotations

import asyncio
import logging
import sys
import time
from collections.abc import Awaitable, Callable
from typing import Any

log = logging.getLogger(__name__)

NotifyFn = Callable[[str, str], Awaitable[None]]

#: Same (title, message) is not repeated inside this window.
DEDUPE_SECONDS = 60.0


#: Employer-reply labels worth a notification (``application_reply``), as words.
_REPLY_WORDS = {"interview_invite": "interview invite", "assessment": "assessment", "rejection": "rejection", "offer": "offer"}


def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


async def osascript_notify(title: str, message: str) -> None:
    script = f'display notification "{_esc(message)[:220]}" with title "AutoApply" subtitle "{_esc(title)[:80]}" sound name "Glass"'
    try:
        proc = await asyncio.create_subprocess_exec(
            "osascript", "-e", script, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=5)
    except Exception:  # noqa: BLE001 - a notification must never break the pipeline
        log.debug("notification failed", exc_info=True)


class Notifier:
    def __init__(self, send: NotifyFn | None = None, *, enabled: bool = True) -> None:
        self._send = send or osascript_notify
        self.enabled = enabled and (send is not None or sys.platform == "darwin")
        self._recent: dict[tuple[str, str], float] = {}
        #: When this returns True the app is connected and posts its own (clickable) notifications;
        #: osascript notifications are attributed to Script Editor, so they are only the fallback.
        self.suppress: Callable[[], bool] = lambda: False

    async def notify(self, title: str, message: str) -> None:
        if not self.enabled or self.suppress():
            return
        now = time.monotonic()
        key = (title, message)
        if now - self._recent.get(key, -1e9) < DEDUPE_SECONDS:
            return
        self._recent[key] = now
        await self._send(title, message)

    async def on_event(self, event_type: str, payload: Any) -> None:
        """Map a daemon event to a notification (or nothing)."""
        d = payload if isinstance(payload, dict) else payload.model_dump(mode="json")
        if event_type == "question_opened":
            c = d["cluster"]
            if c.get("kind") == "action" and c.get("reason") != "captcha":
                await self.notify("Agent is blocked", f"{c.get('canonical_question') or 'A step needs you'} · do it, then retry.")
            elif c.get("reason") == "captcha":
                await self.notify("CAPTCHA needs you", f"Solve it in the AutoApply browser window ({', '.join(c.get('companies') or [])}).")
            else:
                await self.notify("Needs your input", c.get("canonical_question") or "A question needs an answer")
        elif event_type == "application_state" and d.get("to_state") == "awaiting_review":
            await self.notify("Ready for review", "A filled application is waiting for your approval.")
        elif event_type == "application_state" and d.get("to_state") == "failed":
            await self.notify("Application failed", d.get("reason") or "See the activity log.")
        elif event_type == "outreach_reply" and d.get("label") not in ("ooo", "bounce"):
            who = (d.get("contact_name") or "Someone").split()[0]
            await self.notify(f"{who} at {d.get('company')} replied", d.get("snippet") or "Open it in Gmail.")
        elif event_type == "application_reply" and d.get("label") in _REPLY_WORDS:
            # Acknowledgements and "other" stay quiet; the reply is still on the board.
            await self.notify(f"{d.get('company') or 'An employer'} replied: {_REPLY_WORDS[d['label']]}",
                              d.get("subject") or d.get("snippet") or "Open it in Gmail.")
        elif event_type == "error":
            await self.notify("AutoApply problem", d.get("message") or "See the activity log.")
