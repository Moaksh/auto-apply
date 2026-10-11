from __future__ import annotations

import json
import re

import jsonschema
import pytest

from autoapply.enums import AppState, BoardStatus, ErrorCode
from autoapply.models import (
    ALLOWED_TRANSITIONS,
    COMMAND_PAYLOADS,
    EVENT_PAYLOADS,
    PROTOCOL_VERSION,
    Envelope,
    ProtocolError,
    SnapshotPayload,
    build_protocol_schema,
    decode_line,
    format_ts,
    make_command,
    make_event,
    parse_ts,
    render_protocol_schema,
)
from autoapply.paths import CONTRACT_DIR, PROTOCOL_SCHEMA_PATH
from tests.foundation import protocol_samples


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(PROTOCOL_SCHEMA_PATH.read_text())


@pytest.fixture(scope="module")
def validator(schema):
    jsonschema.Draft202012Validator.check_schema(schema)
    return jsonschema.Draft202012Validator(schema, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER)


def test_committed_schema_matches_models():
    """contract/protocol.schema.json is generated from models.py; it must not drift.
    Fix: `uv run python -m autoapply.models`."""
    assert PROTOCOL_SCHEMA_PATH.read_text() == render_protocol_schema()


def test_committed_examples_match_samples():
    """Fix: `uv run python -m tests.foundation.protocol_samples`."""
    assert protocol_samples.EXAMPLES_PATH.read_text() == protocol_samples.render()


def test_samples_cover_every_message_type():
    types = {env.type for env in protocol_samples.samples()}
    assert types == set(COMMAND_PAYLOADS) | set(EVENT_PAYLOADS)


def test_every_sample_validates_against_json_schema(validator):
    for line in protocol_samples.EXAMPLES_PATH.read_text().splitlines():
        msg = json.loads(line)
        errors = sorted(validator.iter_errors(msg), key=str)
        assert not errors, f"{msg['type']}: {errors[0].message}"


@pytest.mark.parametrize("env", protocol_samples.samples(), ids=lambda e: e.type)
def test_round_trip_through_wire(env: Envelope):
    line = env.to_line()
    assert line.endswith("\n") and "\n" not in line[:-1]
    decoded, payload = decode_line(line)
    assert decoded == env
    model = COMMAND_PAYLOADS.get(env.type) or EVENT_PAYLOADS[env.type]
    assert isinstance(payload, model)
    # typed payload -> JSON -> typed payload is lossless
    assert model.model_validate(json.loads(json.dumps(payload.model_dump(mode="json")))) == payload


def test_schema_rejects_bad_messages(validator):
    good = json.loads(make_command("approve", {"application_ids": [1]}, id="x").to_line())
    assert validator.is_valid(good)
    for mutate in (
        lambda m: m.update(v=2),
        lambda m: m.pop("id"),
        lambda m: m.update(type="nope"),
        lambda m: m["payload"].update(application_ids=[]),
        lambda m: m["payload"].update(extra=1),
        lambda m: m.update(reply_to="z"),  # commands don't carry reply_to
    ):
        bad = json.loads(json.dumps(good))
        mutate(bad)
        assert not validator.is_valid(bad), bad
    ack_without_reply = {"v": 1, "id": "e", "type": "ack", "payload": {"ok": True}}
    assert not validator.is_valid(ack_without_reply)


def test_schema_state_machine_matches_python(schema):
    sm = schema["x-state-machine"]
    assert sm["states"] == [s.value for s in AppState]
    assert sm["board_statuses"] == [s.value for s in BoardStatus]
    assert {k: set(v) for k, v in sm["transitions"].items()} == {
        f.value: {t.value for t in tos} for f, tos in ALLOWED_TRANSITIONS.items()
    }
    assert schema["x-command-types"] == list(COMMAND_PAYLOADS)
    assert schema["x-event-types"] == list(EVENT_PAYLOADS)


def test_protocol_md_documents_every_type_and_transition():
    md = (CONTRACT_DIR / "protocol.md").read_text()
    for t in [*COMMAND_PAYLOADS, *EVENT_PAYLOADS]:
        assert re.search(rf"`{t}`", md), f"protocol.md does not document {t}"
    for frm, tos in ALLOWED_TRANSITIONS.items():
        for to in tos:
            assert f"{frm.value} → {to.value}" in md, f"protocol.md missing transition {frm.value} → {to.value}"


# ---- decode errors ----------------------------------------------------------------------


def _err(line: str | bytes, **kw) -> ProtocolError:
    with pytest.raises(ProtocolError) as ei:
        decode_line(line, **kw)
    return ei.value


def test_decode_errors():
    assert _err("not json").code is ErrorCode.BAD_REQUEST
    assert _err(b"\xff\xfe").code is ErrorCode.BAD_REQUEST
    assert _err("[1,2]").code is ErrorCode.BAD_REQUEST
    e = _err('{"v":2,"id":"a","type":"ping","payload":{}}')
    assert e.code is ErrorCode.UNSUPPORTED_VERSION and e.msg_id == "a"
    e = _err('{"v":1,"id":"b","type":"warp","payload":{}}')
    assert e.code is ErrorCode.UNKNOWN_TYPE and e.msg_id == "b"
    e = _err('{"v":1,"id":"c","type":"approve","payload":{"application_ids":"x"}}')
    assert e.code is ErrorCode.INVALID_PAYLOAD and e.details["errors"]
    assert _err('{"v":1,"type":"ping","payload":{}}').code is ErrorCode.BAD_REQUEST
    # an event type is not acceptable where a command is expected
    assert _err('{"v":1,"id":"d","type":"log","payload":{"message":"x","at":"2026-01-01T00:00:00Z"}}',
                expect="command").code is ErrorCode.UNKNOWN_TYPE


def test_protocol_error_to_event_correlates():
    e = _err('{"v":1,"id":"abc","type":"warp","payload":{}}')
    ev = e.to_event()
    assert ev.type == "error" and ev.reply_to == "abc" and ev.payload["code"] == "unknown_type"


def test_make_helpers_validate():
    with pytest.raises(ValueError):
        make_command("log")
    with pytest.raises(ValueError):
        make_event("ack", {"ok": True})  # missing reply_to
    with pytest.raises(Exception):
        make_command("approve", {"application_ids": []})
    env = make_command("ping")
    assert env.v == PROTOCOL_VERSION and len(env.id) == 32
    assert "reply_to" not in json.loads(env.to_line())


def test_commands_from_swift_may_omit_optional_fields():
    _, p = decode_line('{"v":1,"id":"s","type":"answer_question","payload":{"cluster_id":"k","answer":"a"}}')
    assert p.save_to_memory is True and p.per_job_answers == []
    _, p = decode_line('{"v":1,"id":"s","type":"update_preferences","payload":{"preferences":{"daily_cap":3}}}')
    assert p.preferences.model_dump(exclude_unset=True) == {"daily_cap": 3}


def test_timestamp_format():
    dt = parse_ts("2026-10-10T09:00:00.123456+05:30")
    assert format_ts(dt) == "2026-10-10T03:30:00.123Z"
    assert format_ts(parse_ts("2026-10-10T09:00:00Z")) == "2026-10-10T09:00:00.000Z"


def test_snapshot_requires_preferences():
    with pytest.raises(Exception):
        SnapshotPayload.model_validate({"daemon_version": "x", "state": {"daemon": "idle"}, "mode": "auto"})


def test_schema_builder_is_deterministic():
    assert build_protocol_schema() == build_protocol_schema()
