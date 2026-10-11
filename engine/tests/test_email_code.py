"""Emailed security codes after Submit: tied to the exact job, answered in Needs-You, never memorised."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

from autoapply import db, prep
from autoapply.apply.email_code import clean_code, code_email, code_length, code_requested, wait_for_code

BODY = ("A verification code was sent to jane@example.com. To submit your application, enter the "
        "8-character code to confirm you're a human.")


def test_detects_greenhouse_code_prompt() -> None:
    assert code_requested(BODY) and code_length(BODY) == 8 and code_email(BODY) == "jane@example.com"
    assert not code_requested("Thank you for applying!")
    assert clean_code(" ab12 CD34 ", 8) == "ab12CD34" and clean_code("123", 8) is None


async def test_code_question_is_tied_to_the_job_and_not_memorised(conn) -> None:  # type: ignore[no-untyped-def]
    co = db.upsert_company(conn, "Observe.AI")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="AI Agent Engineer",
                           apply_url="https://boards.greenhouse.io/observeai/jobs/1")
    events: list[tuple[str, object]] = []

    async def emit(t: str, p: object) -> None:
        events.append((t, p))

    ctx = SimpleNamespace(conn=conn, job=job, emit=emit)

    async def user_answers() -> None:
        while True:
            open_ = [c for c in db.list_open_clusters(conn) if job.id in c.job_ids]
            if open_:
                assert "Observe.AI · AI Agent Engineer" in open_[0].canonical_question
                assert "jane@example.com" in open_[0].canonical_question
                prep.answer_cluster(conn, open_[0].cluster_id, "AB12CD34", save_to_memory=True)
                return
            await asyncio.sleep(0.05)

    code, _ = await asyncio.gather(
        wait_for_code(ctx, ats="Greenhouse", email="jane@example.com", length=8, timeout_s=5, poll_s=0.05), user_answers())
    assert code == "AB12CD34"
    assert conn.execute("SELECT COUNT(*) FROM answers").fetchone()[0] == 0  # single-use: not in memory
    assert any(t == "question_opened" for t, _ in events)


async def test_code_wait_times_out_and_closes_the_question(conn) -> None:  # type: ignore[no-untyped-def]
    co = db.upsert_company(conn, "Acme")
    job, _ = db.insert_job(conn, company_id=co.id, source="greenhouse", title="ML Engineer", apply_url="https://x.test/1")

    async def emit(t: str, p: object) -> None:
        return None

    ctx = SimpleNamespace(conn=conn, job=job, emit=emit)
    assert await wait_for_code(ctx, ats="Greenhouse", email=None, length=8, timeout_s=0.2, poll_s=0.05) is None
    assert not db.list_open_clusters(conn)
