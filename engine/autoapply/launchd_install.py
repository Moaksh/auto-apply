"""Install / uninstall / inspect the ``autoapplyd`` LaunchAgent (``com.autoapply.daemon``).

Owner: Workstream D (daemon & LinkedIn).

Usage::

    uv run python -m autoapply.launchd_install install|uninstall|status|print

* ``install`` renders the plist to ``~/Library/LaunchAgents/com.autoapply.daemon.plist`` and
  loads it with ``launchctl bootstrap gui/$UID <plist>`` (booting out an older copy first).
* ``uninstall`` runs ``launchctl bootout gui/$UID/com.autoapply.daemon`` and deletes the file.
* ``status`` parses ``launchctl print gui/$UID/com.autoapply.daemon``.

The checked-in template ``launchd/com.autoapply.daemon.plist`` documents the same keys with
placeholders; :func:`render_plist` is the source of truth. ``launchctl`` is reached through
an injectable runner so tests never touch the real launchd.
"""

from __future__ import annotations

import argparse
import time
import os
import plistlib
import re
import shutil
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from autoapply.paths import Paths, get_paths

LABEL = "com.autoapply.daemon"
PLIST_NAME = f"{LABEL}.plist"
DEFAULT_PATH_DIRS = (
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
)

Runner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]


BOOTSTRAP_RETRIES = 8
_sleep = time.sleep


def _default_runner(args: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(list(args), capture_output=True, text=True, check=False, timeout=30)


def launch_agents_dir() -> Path:
    return Path.home() / "Library" / "LaunchAgents"


def gui_domain(uid: int | None = None) -> str:
    return f"gui/{os.getuid() if uid is None else uid}"


def default_program_arguments() -> list[str]:
    """``autoapplyd`` from the active environment, else ``python -m autoapply.daemon``."""
    exe = shutil.which("autoapplyd")
    if exe is None:
        candidate = Path(sys.executable).with_name("autoapplyd")
        exe = str(candidate) if candidate.exists() else None
    return [exe] if exe else [sys.executable, "-m", "autoapply.daemon"]


def package_root() -> Path:
    """Directory that contains the ``autoapply`` package (``engine/`` in a dev checkout)."""
    return Path(__file__).resolve().parent.parent


def default_path_env() -> str:
    home = Path.home()
    dirs = [str(home / ".local" / "bin"), *DEFAULT_PATH_DIRS]
    venv_bin = str(Path(sys.executable).parent)
    if venv_bin not in dirs:
        dirs.insert(0, venv_bin)
    return ":".join(dict.fromkeys(dirs))


def render_plist(
    paths: Paths,
    *,
    program_arguments: Sequence[str] | None = None,
    path_env: str | None = None,
    extra_env: dict[str, str] | None = None,
    set_home_env: bool = False,
) -> bytes:
    """Build the LaunchAgent plist (XML bytes).

    ``KeepAlive.SuccessfulExit = false``: restarted after a crash, but a clean exit (e.g. a
    second instance finding the lock held) is final. ``ProcessType = Interactive`` because
    the daemon drives a visible Chrome window for LinkedIn/Glassdoor.
    """
    # PYTHONPATH pins the package location explicitly: the venv's editable-install ``.pth``
    # can be skipped by Python (e.g. macOS marks it UF_HIDDEN, and 3.12 ignores hidden
    # ``.pth`` files), which would make ``autoapplyd`` die on import and launchd restart-loop.
    env = {"PATH": path_env or default_path_env(), "PYTHONUNBUFFERED": "1", "PYTHONPATH": str(package_root())}
    if set_home_env:
        env["AUTOAPPLY_HOME"] = str(paths.home)
    env.update(extra_env or {})
    data: dict[str, Any] = {
        "Label": LABEL,
        "ProgramArguments": list(program_arguments or default_program_arguments()),
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 30,
        "ProcessType": "Interactive",
        "WorkingDirectory": str(paths.home),
        "EnvironmentVariables": env,
        "StandardOutPath": str(paths.logs / "autoapplyd.stdout.log"),
        "StandardErrorPath": str(paths.logs / "autoapplyd.stderr.log"),
    }
    return plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)


@dataclass(slots=True)
class AgentStatus:
    installed: bool  # plist file present
    loaded: bool  # known to launchd
    running: bool
    pid: int | None = None
    last_exit_code: int | None = None
    state: str | None = None
    plist_path: str | None = None


def parse_launchctl_print(output: str) -> dict[str, Any]:
    """Extract ``state``, ``pid`` and ``last exit code`` from ``launchctl print`` output."""
    out: dict[str, Any] = {}
    for raw in output.splitlines():
        line = raw.strip()
        if " = " not in line:
            continue
        key, _, value = line.partition(" = ")
        key = key.strip()
        value = value.strip()
        if key == "state" and "state" not in out:
            out["state"] = value
        elif key == "pid" and "pid" not in out:
            try:
                out["pid"] = int(value)
            except ValueError:
                pass
        elif key == "last exit code" and "last_exit_code" not in out:
            m = re.match(r"-?\d+", value)
            if m:
                out["last_exit_code"] = int(m.group(0))
    return out


class LaunchAgentManager:
    def __init__(
        self,
        paths: Paths | None = None,
        *,
        agents_dir: Path | None = None,
        runner: Runner | None = None,
        uid: int | None = None,
    ) -> None:
        self.paths = paths or get_paths(create=True)
        self.agents_dir = agents_dir or launch_agents_dir()
        self.runner = runner or _default_runner
        self.domain = gui_domain(uid)

    @property
    def plist_path(self) -> Path:
        return self.agents_dir / PLIST_NAME

    @property
    def service_target(self) -> str:
        return f"{self.domain}/{LABEL}"

    def is_loaded(self) -> bool:
        return self.runner(["launchctl", "print", self.service_target]).returncode == 0

    def install(self, *, program_arguments: Sequence[str] | None = None, **render_kw: Any) -> Path:
        self.paths.ensure()
        self.agents_dir.mkdir(parents=True, exist_ok=True)
        content = render_plist(self.paths, program_arguments=program_arguments, **render_kw)
        tmp = self.plist_path.with_suffix(".plist.tmp")
        tmp.write_bytes(content)
        os.chmod(tmp, 0o644)
        tmp.replace(self.plist_path)
        if self.is_loaded():
            self.runner(["launchctl", "bootout", self.service_target])
            self._wait_unloaded()
        # A previously booted-out/disabled service makes bootstrap fail with "5: Input/output error".
        self.runner(["launchctl", "enable", self.service_target])
        res = self.runner(["launchctl", "bootstrap", self.domain, str(self.plist_path)])
        for _ in range(BOOTSTRAP_RETRIES):
            if res.returncode == 0 or self.is_loaded():
                break
            # bootout is asynchronous: bootstrapping while the old job is still tearing down gives error 5.
            _sleep(1.0)
            res = self.runner(["launchctl", "bootstrap", self.domain, str(self.plist_path)])
        if res.returncode != 0 and not self.is_loaded():
            raise RuntimeError(f"launchctl bootstrap failed ({res.returncode}): {(res.stderr or res.stdout).strip()}")
        self.runner(["launchctl", "enable", self.service_target])
        return self.plist_path

    def _wait_unloaded(self, timeout: float = 10.0) -> None:
        waited = 0.0
        while self.is_loaded() and waited < timeout:
            _sleep(0.5)
            waited += 0.5

    def uninstall(self) -> bool:
        """Bootout + delete the plist. Returns True if anything was removed."""
        removed = False
        if self.is_loaded():
            self.runner(["launchctl", "bootout", self.service_target])
            removed = True
        if self.plist_path.exists():
            self.plist_path.unlink()
            removed = True
        return removed

    def restart(self) -> None:
        self.runner(["launchctl", "kickstart", "-k", self.service_target])

    def status(self) -> AgentStatus:
        res = self.runner(["launchctl", "print", self.service_target])
        installed = self.plist_path.exists()
        if res.returncode != 0:
            return AgentStatus(installed=installed, loaded=False, running=False, plist_path=str(self.plist_path))
        info = parse_launchctl_print(res.stdout or "")
        pid = info.get("pid")
        return AgentStatus(
            installed=installed, loaded=True, running=info.get("state") == "running" or pid is not None,
            pid=pid, last_exit_code=info.get("last_exit_code"), state=info.get("state"), plist_path=str(self.plist_path),
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="autoapply-launchd", description="Manage the autoapplyd LaunchAgent")
    parser.add_argument("action", choices=["install", "uninstall", "status", "print", "restart"])
    parser.add_argument("--home", help="AutoApply data directory (sets AUTOAPPLY_HOME in the agent)")
    args = parser.parse_args(argv)
    paths = get_paths(args.home, create=args.action == "install")
    mgr = LaunchAgentManager(paths)
    if args.action == "print":
        sys.stdout.write(render_plist(paths, set_home_env=bool(args.home)).decode())
    elif args.action == "install":
        print(f"installed {mgr.install(set_home_env=bool(args.home))}")
    elif args.action == "uninstall":
        print("removed" if mgr.uninstall() else "not installed")
    elif args.action == "restart":
        mgr.restart()
    else:
        st = mgr.status()
        print(f"installed={st.installed} loaded={st.loaded} running={st.running} pid={st.pid} "
              f"state={st.state} last_exit_code={st.last_exit_code}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
