"""``import_linkedin_connections``, ``get_voice_profile`` and ``update_voice_profile`` through the
daemon, plus the voice profile reaching an outreach draft prompt. No network."""

from __future__ import annotations

from pathlib import Path

import pytest

from autoapply import db
from autoapply.answers import voice
from autoapply.paths import Paths
from tests.d_daemon.test_outreach import World


@pytest.fixture
async def world(autoapply_home: Paths):
    w = World(autoapply_home)
    try:
        yield w
    finally:
        await w.daemon.stop()


async def test_import_linkedin_connections_command(world: World, tmp_path: Path):
    _app_id, _cid, co_id = world.seed()  # Acme, with a submitted application
    db.upsert_company(world.conn, "Razorpay", watch=True)
    csv_path = tmp_path / "Connections.csv"
    csv_path.write_text(
        "﻿Notes:\n\"Some emails are missing.\"\n\n"
        "First Name,Last Name,URL,Email Address,Company,Position,Connected On\n"
        "Ravi,Kumar,https://www.linkedin.com/in/ravik,,Acme Pvt Ltd,Engineer,01 Feb 2024\n"
        "Priya,Sharma,https://www.linkedin.com/in/priya,,Razorpay,EM,01 Feb 2024\n"
        "Arjun,Rao,https://www.linkedin.com/in/arjun,,Initech,Analyst,01 Feb 2024\n",
        encoding="utf-8",
    )
    res = await world.ok("import_linkedin_connections", {"file_path": str(csv_path)})
    assert (res["imported"], res["merged"], res["skipped"], res["referral_suggestions"]) == (3, 0, 0, 2)
    assert {m["name"] for m in res["matched_companies"]} == {"Acme", "Razorpay"}
    ref = world.conn.execute("SELECT * FROM referrals WHERE company_id = ?", (co_id,)).fetchone()
    assert ref["person_name"] == "Ravi Kumar" and ref["job_id"] is not None and ref["state"] == "suggested"
    again = await world.ok("import_linkedin_connections", {"file_path": str(csv_path)})
    assert (again["imported"], again["merged"], again["referral_suggestions"]) == (0, 3, 0)
    missing = await world.cmd("import_linkedin_connections", {"file_path": str(tmp_path / "nope.csv")})
    assert missing["type"] == "error" and missing["code"] == "not_found"
    bad = tmp_path / "other.csv"
    bad.write_text("name,email\nJane,jane@x.com\n")
    err = await world.cmd("import_linkedin_connections", {"file_path": str(bad)})
    assert err["type"] == "error" and err["code"] == "invalid_payload"


async def test_voice_profile_commands_and_draft_prompt(world: World):
    assert await world.ok("get_voice_profile") == {"sign_off": "Best regards", "formality": "neutral", "max_words": 250,
                                                   "avoid_phrases": [], "writing_sample": None}
    got = await world.ok("update_voice_profile", {"sign_off": "Thanks", "formality": "casual", "avoid_phrases": ["circling back"]})
    assert got["sign_off"] == "Thanks" and got["formality"] == "casual" and got["max_words"] == 250
    assert (await world.ok("get_voice_profile"))["avoid_phrases"] == ["circling back"]
    assert voice.active().sign_off == "Thanks"
    reset = await world.ok("update_voice_profile", {"sign_off": None})
    assert reset["sign_off"] == "Best regards" and reset["formality"] == "casual"

    app_id, cid, _co = world.seed()
    d = await world.ok("draft_outreach", {"contact_id": cid, "kind": "application", "application_id": app_id})
    prompt = world.llm.calls[-1].prompt
    assert "WRITING VOICE" in prompt and '"circling back"' in prompt and "relaxed" in prompt
    assert d["grounded"] is True
    body = world.conn.execute("SELECT body FROM outreach_messages WHERE id = ?", (d["message_id"],)).fetchone()[0]
    assert body.rstrip().endswith("Best regards,\nAsha Rao")  # GOOD_DRAFT signs "Best," -> the profile's sign-off
