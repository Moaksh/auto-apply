"""Posting legitimacy signals (deterministic)."""

from __future__ import annotations

import sqlite3
from datetime import timedelta

import pytest

from autoapply import db, legitimacy as L
from autoapply.models import format_ts, utcnow

GOOD = ("Responsibilities: own the payments backend. Requirements: 4+ years of Python, "
        "experience with Postgres and AWS. You will work with product and design.")


@pytest.mark.parametrize("text", [
    "A registration fee of Rs 500 is required to process your application.",
    "Registration charges: Rs. 999 only.",
    "Candidates must pay a refundable deposit of INR 2000 before the interview.",
    "Pay a one-time processing fee to confirm your seat.",
    "Training fees of Rs 15,000 apply for the first month.",
    "A security deposit is collected from selected candidates at joining.",
    "You will need to pay for the training kit.",
    "Rs 1500 towards registration, payable on selection.",
])
def test_fee_asks(text: str) -> None:
    assert L.fee_ask(text)


@pytest.mark.parametrize("text", [
    "We do not charge any registration fee at any stage of recruitment.",
    "Beware of fraudsters asking for a security deposit; we never ask for money.",
    "Training fees will be reimbursed by the company.",
    "You need to pay attention to detail.",
    "Collect security deposits from tenants and track rent.",
    "Competitive salary, health insurance and learning budget.",
    "The company pays the relocation fee.",
])
def test_not_fee_asks(text: str) -> None:
    assert L.fee_ask(text) is None


def test_personal_email_only() -> None:
    assert L.personal_email_only("Mail your CV to hr.jobs2026@gmail.com") == "hr.jobs2026@gmail.com"
    assert L.personal_email_only("Contact: recruit@yahoo.co.in") == "recruit@yahoo.co.in"
    assert L.personal_email_only("Write to talent@acme.com or acme.hr@gmail.com") is None
    assert L.personal_email_only("Apply on our site.") is None


def test_agency_unnamed() -> None:
    assert L.agency_unnamed("We are hiring for one of our clients, a fintech.", "TalentBridge")
    assert L.agency_unnamed("Opening with a leading MNC in Pune.", "ABC Consultants")
    assert L.agency_unnamed("Our client is a Series B SaaS company.", "Hire Co")
    assert L.agency_unnamed("Great role.", "Confidential")
    # consulting / product companies talking about their own clients
    assert L.agency_unnamed("We deliver value for our clients across industries.", "Accenture") is None
    assert L.agency_unnamed("We are a leading company in payments.", "Razorpay") is None


def test_vague() -> None:
    assert L.vague("Urgent hiring. Good salary. Freshers welcome.")
    assert L.vague(GOOD) is None
    assert L.vague(None) is None and L.vague("") is None


def _job(conn: sqlite3.Connection, title: str, location: str, *, company: str = "Acme", days_ago: int = 0, desc: str = GOOD):
    co = db.upsert_company(conn, company)
    job, _ = db.insert_job(conn, company_id=co.id, source="manual", title=title, location=location, description=desc,
                           apply_url=f"https://acme.example/jobs/{title}-{location}".replace(" ", "-"))
    conn.execute("UPDATE jobs SET discovered_at = ? WHERE id = ?", (format_ts(utcnow() - timedelta(days=days_ago)), job.id))
    return db.get_job(conn, job.id)


def test_repost_needs_three_listings_on_two_days(conn: sqlite3.Connection) -> None:
    a = _job(conn, "Backend Engineer", "Bangalore", days_ago=20)
    _job(conn, "Engineer, Backend", "Bengaluru", days_ago=10)
    assert L.reposts(conn, a) is None  # two listings only
    c = _job(conn, "Backend Engineer", "Bengaluru, India", days_ago=1)
    assert L.reposts(conn, c) == "3 listings in 30 days"
    # a different title word (seniority) is a different requisition
    s = _job(conn, "Senior Backend Engineer", "Bengaluru", days_ago=0)
    assert L.reposts(conn, s) is None


def test_same_day_siblings_are_not_reposts(conn: sqlite3.Connection) -> None:
    jobs = [_job(conn, "Sales Executive", city, days_ago=0) for city in ("Pune", "Mumbai", "Delhi")]
    assert L.reposts(conn, jobs[0]) is None


def test_old_listings_outside_window_ignored(conn: sqlite3.Connection) -> None:
    _job(conn, "Data Analyst", "Pune", days_ago=60)
    _job(conn, "Data Analyst", "Pune, MH", days_ago=45)
    j = _job(conn, "Data Analyst", "Pune, India", days_ago=0)
    assert L.reposts(conn, j) is None


def test_levels_and_storage(conn: sqlite3.Connection) -> None:
    clean = _job(conn, "Backend Engineer", "Remote")
    assert L.ensure(conn, clean).level == L.NONE
    assert db.get_job(conn, clean.id).raw["risk"]["level"] == "none"

    caution = _job(conn, "Ops Associate", "Remote", desc="Urgent hiring. Good salary.")
    r = L.ensure(conn, caution)
    assert r.level == L.CAUTION and r.codes == [L.SIG_VAGUE]

    two_soft = _job(conn, "Ops Lead", "Remote", desc="Hiring for one of our clients. Good pay.", company="TalentBridge")
    assert L.ensure(conn, two_soft).level == L.HIGH

    fee = _job(conn, "Data Entry", "Remote", desc=GOOD + " Registration fee Rs 300 payable online.")
    r = L.ensure(conn, fee)
    assert r.level == L.HIGH and r.asks_to_pay


def test_ensure_computes_once(conn: sqlite3.Connection) -> None:
    j = _job(conn, "Backend Engineer", "Remote")
    first = L.ensure(conn, j)
    # later evidence doesn't change a stored result
    db.update_job(conn, j.id, description="Send CV to x@gmail.com")
    again = L.ensure(conn, db.get_job(conn, j.id))
    assert again.level == first.level == L.NONE


def test_ensure_keeps_other_raw_keys(conn: sqlite3.Connection) -> None:
    j = _job(conn, "Backend Engineer", "Remote")
    db.update_job(conn, j.id, raw={"search_key": "k1"})
    L.ensure(conn, j)  # stale object: raw re-read before writing
    raw = db.get_job(conn, j.id).raw
    assert raw["search_key"] == "k1" and "risk" in raw
