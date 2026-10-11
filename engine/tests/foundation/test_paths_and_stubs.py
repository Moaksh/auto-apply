from __future__ import annotations

import importlib
import inspect
import pkgutil
import stat
from pathlib import Path

import autoapply
from autoapply.apply.base import Adapter
from autoapply.discovery.base import Source
from autoapply.paths import default_home, get_paths, home_dir


def test_home_override(monkeypatch, tmp_path):
    monkeypatch.setenv("AUTOAPPLY_HOME", str(tmp_path / "h"))
    assert home_dir() == (tmp_path / "h").resolve()
    p = get_paths(create=True)
    for d in (p.resumes, p.screenshots, p.cover_letters, p.logs, p.chrome_profile):
        assert d.is_dir()
    assert stat.S_IMODE(p.chrome_profile.stat().st_mode) == 0o700
    assert p.db.name == "autoapply.db" and p.socket.name == "autoapplyd.sock"
    assert p.application_screenshot_dir(5) == p.screenshots / "5"


def test_default_home_is_application_support(monkeypatch):
    monkeypatch.delenv("AUTOAPPLY_HOME", raising=False)
    assert home_dir() == default_home() == Path.home() / "Library" / "Application Support" / "AutoApply"


def test_every_module_imports():
    for m in pkgutil.walk_packages(autoapply.__path__, "autoapply."):
        importlib.import_module(m.name)


def test_stub_classes_satisfy_protocols():
    from autoapply.apply import agentic, ashby, greenhouse, lever
    from autoapply.discovery import ashby as d_ashby
    from autoapply.discovery import careers, glassdoor, linkedin
    from autoapply.discovery import greenhouse as d_gh
    from autoapply.discovery import lever as d_lever

    for mod in (d_gh, d_lever, d_ashby, careers, linkedin, glassdoor):
        cls = next(c for _, c in inspect.getmembers(mod, inspect.isclass) if c.__name__.endswith("Source") and c.__module__ == mod.__name__)
        assert isinstance(cls(), Source)
    for mod in (greenhouse, lever, ashby, agentic):
        cls = next(c for _, c in inspect.getmembers(mod, inspect.isclass) if c.__name__.endswith("Adapter") and c.__module__ == mod.__name__)
        assert isinstance(cls(), Adapter)
