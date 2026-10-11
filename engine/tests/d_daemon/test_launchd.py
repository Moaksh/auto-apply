"""LaunchAgent plist generation + install/uninstall/status with a fake launchctl.

Never touches the real launchd or ~/Library/LaunchAgents.
"""

from __future__ import annotations

import plistlib
import subprocess
from collections.abc import Sequence
from pathlib import Path

import pytest

from autoapply.launchd_install import LABEL, LaunchAgentManager, parse_launchctl_print, render_plist
from autoapply.paths import Paths, REPO_ROOT


class FakeLaunchctl:
    def __init__(self) -> None:
        self.calls: list[list[str]] = []
        self.loaded = False
        self.bootstrap_rc = 0

    def __call__(self, args: Sequence[str]) -> subprocess.CompletedProcess[str]:
        args = list(args)
        self.calls.append(args)
        assert args[0] == "launchctl"
        sub = args[1]
        if sub == "print":
            if self.loaded:
                out = f"{args[2]} = {{\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n\tlast exit code = 0\n}}\n"
                return subprocess.CompletedProcess(args, 0, out, "")
            return subprocess.CompletedProcess(args, 113, "", "Could not find service")
        if sub == "bootstrap":
            if self.bootstrap_rc == 0:
                self.loaded = True
            return subprocess.CompletedProcess(args, self.bootstrap_rc, "", "Bootstrap failed: 5: Input/output error" if self.bootstrap_rc else "")
        if sub == "bootout":
            self.loaded = False
        return subprocess.CompletedProcess(args, 0, "", "")


def test_render_plist(autoapply_home: Paths) -> None:
    data = plistlib.loads(render_plist(autoapply_home, program_arguments=["/opt/x/bin/autoapplyd"], path_env="/usr/bin:/bin"))
    assert data["Label"] == LABEL == "com.autoapply.daemon"
    assert data["ProgramArguments"] == ["/opt/x/bin/autoapplyd"]
    assert data["RunAtLoad"] is True and data["KeepAlive"] == {"SuccessfulExit": False}
    assert data["ProcessType"] == "Interactive"
    assert data["EnvironmentVariables"]["PATH"] == "/usr/bin:/bin"
    assert "AUTOAPPLY_HOME" not in data["EnvironmentVariables"]
    assert data["StandardErrorPath"] == str(autoapply_home.logs / "autoapplyd.stderr.log")
    assert data["WorkingDirectory"] == str(autoapply_home.home)
    data2 = plistlib.loads(render_plist(autoapply_home, set_home_env=True))
    assert data2["EnvironmentVariables"]["AUTOAPPLY_HOME"] == str(autoapply_home.home)
    assert data2["ProgramArguments"]  # default resolution finds autoapplyd or python -m


def test_template_matches_rendered_keys(autoapply_home: Paths) -> None:
    template = plistlib.loads((REPO_ROOT / "launchd" / "com.autoapply.daemon.plist").read_bytes())
    rendered = plistlib.loads(render_plist(autoapply_home, program_arguments=["x"]))
    assert set(template) == set(rendered)
    assert template["Label"] == rendered["Label"] and template["KeepAlive"] == rendered["KeepAlive"]


def test_install_status_uninstall(autoapply_home: Paths, tmp_path: Path) -> None:
    fake = FakeLaunchctl()
    agents = tmp_path / "LaunchAgents"
    mgr = LaunchAgentManager(autoapply_home, agents_dir=agents, runner=fake, uid=501)
    assert mgr.status().installed is False and mgr.status().loaded is False

    path = mgr.install(program_arguments=["/bin/autoapplyd"])
    assert path == agents / "com.autoapply.daemon.plist" and path.exists()
    assert ["launchctl", "bootstrap", "gui/501", str(path)] in fake.calls
    assert ["launchctl", "enable", "gui/501/com.autoapply.daemon"] in fake.calls
    st = mgr.status()
    assert st.installed and st.loaded and st.running and st.pid == 4242 and st.last_exit_code == 0

    fake.calls.clear()
    mgr.install(program_arguments=["/bin/autoapplyd"])  # reinstall boots out the old one first
    subs = [c[1] for c in fake.calls]
    assert subs.index("bootout") < subs.index("bootstrap")

    assert mgr.uninstall() is True
    assert not path.exists() and not fake.loaded
    assert mgr.uninstall() is False


def test_install_failure_raises(autoapply_home: Paths, tmp_path: Path) -> None:
    fake = FakeLaunchctl()
    fake.bootstrap_rc = 5
    mgr = LaunchAgentManager(autoapply_home, agents_dir=tmp_path, runner=fake, uid=501)
    with pytest.raises(RuntimeError, match="bootstrap failed"):
        mgr.install(program_arguments=["/bin/autoapplyd"])


def test_parse_launchctl_print() -> None:
    out = "gui/501/com.autoapply.daemon = {\n\tstate = not running\n\tlast exit code = 78: EX_CONFIG\n\tjob state = exited\n}"
    assert parse_launchctl_print(out) == {"state": "not running", "last_exit_code": 78}
