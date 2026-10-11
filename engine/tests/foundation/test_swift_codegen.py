"""Messages.swift is generated from contract/protocol.schema.json; it must not drift.
Fix: `uv run python scripts/gen_swift_messages.py`."""

from __future__ import annotations

import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "gen_swift_messages.py"


def _load():
    spec = importlib.util.spec_from_file_location("gen_swift_messages", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def test_messages_swift_is_up_to_date():
    gen = _load()
    assert gen.OUT_PATH.read_text(encoding="utf-8") == gen.render()


def test_messages_swift_covers_every_type():
    gen = _load()
    text = gen.OUT_PATH.read_text(encoding="utf-8")
    import json

    schema = json.loads(gen.SCHEMA_PATH.read_text())
    for t in schema["x-command-types"] + schema["x-event-types"]:
        assert f'"{t}"' in text, t
