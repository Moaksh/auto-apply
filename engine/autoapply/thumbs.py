"""Small JPEG thumbnails for ``agent_step.screenshot_thumb`` (base64, max 720px wide)."""

from __future__ import annotations

import base64
import io
import logging
import time
from pathlib import Path

log = logging.getLogger(__name__)

MAX_WIDTH = 720
MIN_INTERVAL = 1.5  # seconds between frames per application


def thumb_from_bytes(data: bytes) -> str | None:
    """Downscale PNG/JPEG bytes to a <=720px wide JPEG; returns base64 or None."""
    try:
        from PIL import Image

        im = Image.open(io.BytesIO(data)).convert("RGB")
        if im.width > MAX_WIDTH:
            im = im.resize((MAX_WIDTH, max(1, round(im.height * MAX_WIDTH / im.width))))
        out = io.BytesIO()
        im.save(out, "JPEG", quality=55)
        return base64.b64encode(out.getvalue()).decode("ascii")
    except Exception:  # noqa: BLE001
        log.debug("thumbnail failed", exc_info=True)
        return None


class Throttle:
    def __init__(self, interval: float = MIN_INTERVAL) -> None:
        self.interval = interval
        self._last = -1e9

    def ready(self) -> bool:
        now = time.monotonic()
        if now - self._last < self.interval:
            return False
        self._last = now
        return True


def newest_image(directory: Path, after: float = 0.0) -> tuple[Path, float] | None:
    """Newest png/jpg in ``directory`` modified after ``after`` (mtime), or None."""
    best: tuple[Path, float] | None = None
    try:
        for p in directory.iterdir():
            if p.suffix.lower() in (".png", ".jpg", ".jpeg"):
                m = p.stat().st_mtime
                if m > after and (best is None or m > best[1]):
                    best = (p, m)
    except OSError:
        return None
    return best
