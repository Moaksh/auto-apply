"""Tests for notifier, thumbnails and the headed CAPTCHA handoff."""

from __future__ import annotations

import asyncio
import base64
import io
import os
import time
from types import SimpleNamespace

import pytest
from PIL import Image

from autoapply import thumbs
from autoapply.apply.base import FillResult, UnresolvedField
from autoapply.enums import AppState, Mode, QuestionReason
from autoapply.models import FormQuestion
from autoapply.notify import Notifier
from autoapply.pipeline import Pipeline


# ------------------------------------------------------------------ Notifier


def _notifier(enabled: bool = True):
    sent: list[tuple[str, str]] = []

    async def send(t: str, m: str) -> None:
        sent.append((t, m))

    return Notifier(send, enabled=enabled), sent


async def test_notifier_dedupes_same_message():
    n, sent = _notifier()
    await n.notify("a", "b")
    await n.notify("a", "b")
    await n.notify("a", "c")
    assert sent == [("a", "b"), ("a", "c")]


async def test_notifier_dedupe_expires(monkeypatch):
    n, sent = _notifier()
    await n.notify("a", "b")
    n._recent[("a", "b")] -= 120
    await n.notify("a", "b")
    assert len(sent) == 2


async def test_notifier_disabled_does_nothing():
    n, sent = _notifier(enabled=False)
    await n.notify("a", "b")
    await n.on_event("error", {"message": "x"})
    assert sent == []


async def test_notifier_event_mapping():
    n, sent = _notifier()
    await n.on_event("question_opened", {"cluster": {"reason": "captcha", "companies": ["Acme", "Beta"]}})
    await n.on_event("question_opened", {"cluster": {"reason": "unknown", "canonical_question": "Visa?"}})
    await n.on_event("application_state", {"to_state": "awaiting_review"})
    await n.on_event("application_state", {"to_state": "failed", "reason": "boom"})
    await n.on_event("application_state", {"to_state": "submitted"})
    await n.on_event("error", {"message": "bad"})
    await n.on_event("log", {"message": "ignored"})
    assert [t for t, _ in sent] == ["CAPTCHA needs you", "Needs your input", "Ready for review", "Application failed", "AutoApply problem"]
    assert "Acme, Beta" in sent[0][1]
    assert sent[1][1] == "Visa?"
    assert sent[3][1] == "boom"
    assert sent[4][1] == "bad"


async def test_notifier_accepts_pydantic_payload():
    from pydantic import BaseModel

    class P(BaseModel):
        message: str

    n, sent = _notifier()
    await n.on_event("error", P(message="hi"))
    assert sent == [("AutoApply problem", "hi")]


# ------------------------------------------------------------------ thumbs


def _png(w: int, h: int) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (200, 30, 30)).save(buf, "PNG")
    return buf.getvalue()


def test_thumb_downscales_to_jpeg():
    b64 = thumbs.thumb_from_bytes(_png(1600, 1000))
    im = Image.open(io.BytesIO(base64.b64decode(b64)))
    assert im.format == "JPEG"
    assert im.width == 720
    assert im.height == 450


def test_thumb_keeps_small_images():
    im = Image.open(io.BytesIO(base64.b64decode(thumbs.thumb_from_bytes(_png(300, 200)))))
    assert (im.width, im.height) == (300, 200)


def test_thumb_garbage_returns_none():
    assert thumbs.thumb_from_bytes(b"not an image") is None


def test_throttle(monkeypatch):
    t = [100.0]
    monkeypatch.setattr(thumbs.time, "monotonic", lambda: t[0])
    th = thumbs.Throttle(2.0)
    assert th.ready()
    t[0] += 1.0
    assert not th.ready()
    t[0] += 1.5
    assert th.ready()


def test_newest_image(tmp_path):
    assert thumbs.newest_image(tmp_path) is None
    assert thumbs.newest_image(tmp_path / "missing") is None
    a, b, c = tmp_path / "a.png", tmp_path / "b.JPG", tmp_path / "c.txt"
    for p, m in ((a, 1000), (b, 2000), (c, 3000)):
        p.write_bytes(b"x")
        os.utime(p, (m, m))
    path, m = thumbs.newest_image(tmp_path)
    assert path == b and m == 2000
    assert thumbs.newest_image(tmp_path, after=2000) is None
    assert thumbs.newest_image(tmp_path, after=1500)[0] == b


# ------------------------------------------------------------------ captcha handoff


def _unresolved(reason: str) -> UnresolvedField:
    return UnresolvedField(question=FormQuestion(key="k", label="q", required=True), reason=reason)


class FakeAdapter:
    def __init__(self, results):
        self.results = list(results)
        self.calls: list[tuple[bool, object]] = []

    async def fill(self, ctx):
        self.calls.append((ctx.headless, ctx.extra.get("captcha_wait_s")))
        return self.results.pop(0)


class _Usage:
    total_tokens = 0

    def snapshot(self):
        return 0

    def since(self, _):
        return self


def _pipeline(captcha_wait_s: float):
    p = object.__new__(Pipeline)
    p.captcha_wait_s = captcha_wait_s
    p.llm = SimpleNamespace(usage=_Usage())
    p.conn = None
    p.notifier, p.parked, p.transitions, p.notified = None, [], [], []

    async def _noop(*a, **k):
        return None

    async def park(app_id, job, unresolved):
        p.parked.append([u.reason for u in unresolved])
        return []

    async def transition(app_id, to, **k):
        p.transitions.append(to)

    async def notify(t, m):
        p.notified.append(t)

    p._log = _noop
    p.park = park
    p._transition = transition
    p.notifier = SimpleNamespace(notify=notify)
    return p


async def _run(p, adapter, *, headless=True, dry_run=False):
    ctx = SimpleNamespace(headless=headless, extra={}, is_dry_run=dry_run)
    app = SimpleNamespace(id=1)
    job = SimpleNamespace(id=1)
    company = SimpleNamespace(name="Acme", id=1)
    state = await p._fill_and_submit(app, job, company, Mode.REVIEW, adapter, ctx)
    return state, ctx


async def test_captcha_handoff_success_does_not_park():
    p = _pipeline(30)
    ad = FakeAdapter([FillResult(ok=False, unresolved=[_unresolved(QuestionReason.CAPTCHA.value)]), FillResult(ok=True)])
    state, ctx = await _run(p, ad)
    assert state is AppState.AWAITING_REVIEW
    assert ad.calls == [(True, None), (False, 30)]
    assert p.parked == []
    assert p.notified == ["CAPTCHA needs you"]
    assert "captcha_wait_s" not in ctx.extra


@pytest.mark.parametrize("wait", [0, -1])
async def test_captcha_handoff_disabled_parks(wait):
    p = _pipeline(wait)
    ad = FakeAdapter([FillResult(ok=False, unresolved=[_unresolved("captcha")])])
    state, _ = await _run(p, ad)
    assert state is AppState.NEEDS_YOU
    assert len(ad.calls) == 1
    assert p.parked == [["captcha"]]


async def test_non_captcha_or_mixed_unresolved_parks_without_retry():
    for reasons in (["unknown"], ["captcha", "unknown"]):
        p = _pipeline(30)
        ad = FakeAdapter([FillResult(ok=False, unresolved=[_unresolved(r) for r in reasons])])
        state, _ = await _run(p, ad)
        assert state is AppState.NEEDS_YOU
        assert len(ad.calls) == 1
        assert p.parked == [reasons]


async def test_captcha_still_unsolved_after_handoff_parks():
    p = _pipeline(30)
    cap = lambda: FillResult(ok=False, unresolved=[_unresolved("captcha")])  # noqa: E731
    ad = FakeAdapter([cap(), cap()])
    state, _ = await _run(p, ad)
    assert state is AppState.NEEDS_YOU
    assert len(ad.calls) == 2  # only one retry
    assert p.parked == [["captcha"]]


async def test_already_headed_or_dry_run_no_handoff():
    for kw in ({"headless": False}, {"dry_run": True}):
        p = _pipeline(30)
        ad = FakeAdapter([FillResult(ok=False, unresolved=[_unresolved("captcha")])])
        state, _ = await _run(p, ad, **kw)
        assert state is AppState.NEEDS_YOU and len(ad.calls) == 1


async def test_headed_retry_exception_fails_application():
    class Boom(FakeAdapter):
        async def fill(self, ctx):
            self.calls.append(ctx.headless)
            if len(self.calls) == 1:
                return FillResult(ok=False, unresolved=[_unresolved("captcha")])
            raise RuntimeError("window closed")

    p = _pipeline(30)
    state, ctx = await _run(p, Boom([]))
    assert state is AppState.FAILED
    assert "captcha_wait_s" not in ctx.extra
