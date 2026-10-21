"""Filesystem layout for AutoApply.

Everything lives under one "home" directory:

    ~/Library/Application Support/AutoApply/
        autoapply.db        SQLite (WAL) — daemon is the only writer
        autoapplyd.sock     Unix socket (NDJSON protocol, contract/protocol.md)
        resumes/            user-approved resume PDFs (never modified)
        screenshots/        full-page screenshots per application
        cover_letters/      generated cover letters
        interview_prep/     interview prep packs and debriefs (JSON, one file per application)
        chrome-profile/     dedicated persistent Chrome profile for Playwright
        logs/               daemon logs

Set ``AUTOAPPLY_HOME`` to relocate the whole tree (tests always do this).
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

ENV_HOME = "AUTOAPPLY_HOME"
APP_DIR_NAME = "AutoApply"

DB_FILENAME = "autoapply.db"
SOCKET_FILENAME = "autoapplyd.sock"

#: Repository root (…/auto_apply). Used to locate contract/ in a source checkout.
REPO_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_DIR = REPO_ROOT / "contract"
SCHEMA_SQL_PATH = CONTRACT_DIR / "schema.sql"
PROTOCOL_SCHEMA_PATH = CONTRACT_DIR / "protocol.schema.json"


def default_home() -> Path:
    """The default data directory (macOS Application Support)."""
    return Path.home() / "Library" / "Application Support" / APP_DIR_NAME


def home_dir() -> Path:
    """Resolve the data directory, honouring ``AUTOAPPLY_HOME``. Does not create it."""
    override = os.environ.get(ENV_HOME)
    if override:
        return Path(override).expanduser().resolve()
    return default_home()


@dataclass(frozen=True, slots=True)
class Paths:
    """Concrete paths for one AutoApply home. Build with :func:`get_paths`."""

    home: Path

    @property
    def db(self) -> Path:
        return self.home / DB_FILENAME

    @property
    def socket(self) -> Path:
        return self.home / SOCKET_FILENAME

    @property
    def resumes(self) -> Path:
        return self.home / "resumes"

    @property
    def screenshots(self) -> Path:
        return self.home / "screenshots"

    @property
    def cover_letters(self) -> Path:
        return self.home / "cover_letters"

    @property
    def interview_prep(self) -> Path:
        """Interview prep packs (``<id>.json``) and debriefs (``<id>.debriefs.json``); created on first write."""
        return self.home / "interview_prep"

    @property
    def chrome_profile(self) -> Path:
        return self.home / "chrome-profile"

    @property
    def logs(self) -> Path:
        return self.home / "logs"

    @property
    def daemon_log(self) -> Path:
        return self.logs / "autoapplyd.log"

    def application_screenshot_dir(self, application_id: int) -> Path:
        return self.screenshots / str(application_id)

    def ensure(self) -> "Paths":
        """Create the home tree (idempotent). The chrome profile is created 0700."""
        self.home.mkdir(parents=True, exist_ok=True)
        for d in (self.resumes, self.screenshots, self.cover_letters, self.logs):
            d.mkdir(parents=True, exist_ok=True)
        self.chrome_profile.mkdir(mode=0o700, parents=True, exist_ok=True)
        return self


def get_paths(home: Path | str | None = None, *, create: bool = False) -> Paths:
    """Return :class:`Paths` for ``home`` (default: :func:`home_dir`)."""
    p = Paths(Path(home).expanduser().resolve() if home is not None else home_dir())
    return p.ensure() if create else p


def schema_sql_path() -> Path:
    """Location of contract/schema.sql (``AUTOAPPLY_SCHEMA_PATH`` overrides)."""
    override = os.environ.get("AUTOAPPLY_SCHEMA_PATH")
    return Path(override) if override else SCHEMA_SQL_PATH
