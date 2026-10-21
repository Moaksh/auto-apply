"""Warm intros from the user's own LinkedIn export: CSV parsing, company matching, contact
import / merge, referral suggestions and the do-not-contact list. No network."""

from __future__ import annotations

from pathlib import Path

import pytest

from autoapply import db
from autoapply.enums import AppState, Ats, ContactOrigin, ProspectStatus, ReferralBasis, ReferralState, SuppressionReason
from autoapply.outreach import linkedin_export as lx
from autoapply.outreach import prospects, suppression

PREAMBLE = (
    "Notes:\n"
    '"When exporting your connection data, you may notice that some of the email addresses are missing. '
    'You will only see email addresses for connections who have allowed their connections to see or download their email '
    'address using this setting https://www.linkedin.com/psettings/privacy/email. You can learn more here, too."\n'
    "\n"
)
HEADER = "First Name,Last Name,URL,Email Address,Company,Position,Connected On\n"


def _csv(*rows: str, bom: bool = True, preamble: bool = True) -> str:
    return ("﻿" if bom else "") + (PREAMBLE if preamble else "") + HEADER + "".join(r + "\n" for r in rows)


# ---- parsing --------------------------------------------------------------------------------


def test_parse_skips_preamble_and_bom_and_handles_quotes_and_missing_emails():
    text = _csv(
        'Priya,Sharma,https://www.linkedin.com/in/priya-sharma-123/,,Razorpay,"Engineering Manager, Payments",03 Aug 2024',
        'Rahul,Verma,https://in.linkedin.com/in/RahulVerma?trk=abc,rahul@gmail.com,"Acme Technologies Pvt. Ltd.",SDE II,15 Jan 2023',
        ",,,,,,",
        ',,https://www.linkedin.com/in/nameless,,Nowhere,,01 Jan 2020',
    )
    res = lx.parse_connections(text)
    assert res.header_found and res.skipped_no_name == 1
    a, b = res.connections
    assert (a.full_name, a.first_name, a.last_name) == ("Priya Sharma", "Priya", "Sharma")
    assert a.position == "Engineering Manager, Payments"  # quoted comma kept in one cell
    assert a.email is None and a.company == "Razorpay" and a.connected_on == "2024-08-03"
    assert a.linkedin_url == "https://www.linkedin.com/in/priya-sharma-123"
    assert b.linkedin_url == "https://www.linkedin.com/in/rahulverma"  # host, case, query normalized
    assert b.email == "rahul@gmail.com" and b.company == "Acme Technologies Pvt. Ltd." and b.connected_on == "2023-01-15"


def test_parse_header_variations_and_no_preamble():
    text = "﻿email,COMPANY,first name,last name,title,profile url,connected on\nx@y.com,Globex,Ann,Lee,CTO,linkedin.com/in/annlee,2024-02-29\n"
    (c,) = lx.parse_connections(text).connections
    assert (c.full_name, c.company, c.position, c.email) == ("Ann Lee", "Globex", "CTO", "x@y.com")
    assert c.linkedin_url == "https://www.linkedin.com/in/annlee" and c.connected_on == "2024-02-29"


def test_parse_quoted_newline_in_preamble_and_bad_dates():
    text = 'Notes:\n"line one,\nline two, with First Name and Company words"\n\n' + HEADER + "A,B,,,C,,31 Feb 2024\n"
    res = lx.parse_connections(text)
    assert res.header_found and len(res.connections) == 1 and res.connections[0].connected_on is None


def test_parse_no_header():
    res = lx.parse_connections("name,email\nJane,jane@x.com\n")
    assert not res.header_found and res.connections == []


def test_read_utf16(tmp_path: Path):
    p = tmp_path / "Connections.csv"
    p.write_bytes(_csv("Ann,Lee,,,Globex,CTO,", bom=False).encode("utf-16"))
    assert lx.read_connections(p).connections[0].company == "Globex"


# ---- matching -------------------------------------------------------------------------------


@pytest.mark.parametrize(("a", "b", "tier"), [
    ("Razorpay", "Razorpay Software Private Limited", "strong"),
    ("Razorpay", "RAZORPAY PVT LTD", "exact"),
    ("Acme Inc.", "acme", "exact"),
    ("Acme Technologies Pvt. Ltd.", "Acme Technologies", "exact"),
    ("Freshworks", "Freshworks Inc", "exact"),
    ("Go Daddy", "GoDaddy", "exact"),
    ("Tata Consultancy Services", "TCS", "exact"),
    ("Meta", "Facebook", "exact"),
    ("Amazon", "Amazon Web Services (AWS)", "exact"),
    ("Swiggy", "Bundl Technologies Private Limited", "exact"),
    ("Microsoft", "Microsoft India", "exact"),
    ("Infosys", "Infosys Limited", "exact"),
    ("Zeta", "Zeta Suite", None),
    ("Epic Systems", "Epic Games", None),
    ("Loop", "Loopio", None),
    ("GE", "GE Digital", None),
    ("Stealth Startup", "Acme", None),
    ("", "Acme", None),
])
def test_match_tier(a, b, tier):
    assert lx.match_tier(a, b) == tier
    assert lx.match_tier(b, a) == tier


# ---- import ---------------------------------------------------------------------------------


@pytest.fixture
def world(conn):
    """Razorpay watched, Acme Technologies with a queued job, Globex a prospect, Initech ignored."""
    razor = db.upsert_company(conn, "Razorpay", domain="razorpay.com", watch=True)
    acme = db.upsert_company(conn, "Acme Technologies", domain="acme.com")
    job, _ = db.insert_job(conn, company_id=acme.id, source="greenhouse", title="Backend Engineer",
                           apply_url="https://boards.greenhouse.io/acme/jobs/1", ats=Ats.GREENHOUSE, description="Go")
    app = db.get_application_by_job(conn, job.id)
    db.transition(conn, app.id, AppState.SCORED)
    db.transition(conn, app.id, AppState.QUEUED)
    globex = db.upsert_company(conn, "Globex Corporation", domain="globex.com")
    prospects.upsert(conn, globex.id, status=ProspectStatus.SUGGESTED, found_via="search")
    db.upsert_company(conn, "Initech")  # known but not of interest
    return {"razorpay": razor.id, "acme": acme.id, "globex": globex.id, "job": job.id}


EXPORT_1 = _csv(
    'Priya,Sharma,https://www.linkedin.com/in/priya,,Razorpay Software Private Limited,"Engineering Manager, Payments",03 Aug 2024',
    "Rahul,Verma,https://www.linkedin.com/in/rahul,rahul@gmail.com,Acme Technologies Pvt. Ltd.,SDE II,15 Jan 2023",
    "Neha,Iyer,https://www.linkedin.com/in/neha,,GLOBEX,Recruiter,10 Mar 2022",
    "Arjun,Rao,https://www.linkedin.com/in/arjun,,Initech,Analyst,10 Mar 2022",
    "Kiran,Das,https://www.linkedin.com/in/kiran,,Some Startup,Founder,10 Mar 2022",
)


def _write(tmp_path: Path, text: str, name: str = "Connections.csv") -> Path:
    p = tmp_path / name
    p.write_text(text, encoding="utf-8")
    return p


def test_import_creates_contacts_and_referral_suggestions(conn, world, tmp_path):
    rep = lx.import_connections(conn, _write(tmp_path, EXPORT_1))
    assert (rep.imported, rep.merged, rep.skipped, rep.referral_suggestions) == (5, 0, 0, 3)
    assert {m["name"] for m in rep.matched_companies} == {"Razorpay", "Acme Technologies", "Globex Corporation"}
    rows = {r["full_name"]: r for r in conn.execute("SELECT * FROM contacts")}
    assert len(rows) == 5
    for r in rows.values():
        assert r["origin"] == ContactOrigin.IMPORT.value and r["share_ok"] == 0 and r["relationship"] == "other"
        assert r["notes"].startswith("LinkedIn connection")
    assert rows["Priya Sharma"]["company_id"] == world["razorpay"] and rows["Priya Sharma"]["title"] == "Engineering Manager, Payments"
    assert rows["Rahul Verma"]["email_norm"] == "rahul@gmail.com" and rows["Rahul Verma"]["email_confidence"] == 100
    assert rows["Arjun Rao"]["company_id"] is None and rows["Kiran Das"]["company_id"] is None
    refs = {r["person_name"]: r for r in conn.execute("SELECT * FROM referrals")}
    assert set(refs) == {"Priya Sharma", "Rahul Verma", "Neha Iyer"}
    rahul = refs["Rahul Verma"]
    assert rahul["basis"] == ReferralBasis.USER.value and rahul["basis_detail"] == lx.BASIS_DETAIL
    assert rahul["state"] == ReferralState.SUGGESTED.value and rahul["linkedin_url"] == "https://www.linkedin.com/in/rahul"
    assert rahul["job_id"] == world["job"] and rahul["contact_id"] == rows["Rahul Verma"]["id"]
    assert refs["Priya Sharma"]["job_id"] is None and "LinkedIn export" in refs["Priya Sharma"]["evidence_snippet"]


def test_reimport_newer_export_merges_and_suggests_once(conn, world, tmp_path):
    lx.import_connections(conn, _write(tmp_path, EXPORT_1))
    newer = _csv(
        # promoted: same URL, new title
        'Priya,Sharma,https://www.linkedin.com/in/priya/,,Razorpay,"Director, Engineering",03 Aug 2024',
        # moved from Acme to an untracked company
        "Rahul,Verma,https://www.linkedin.com/in/rahul,rahul@gmail.com,Hooli,SDE III,15 Jan 2023",
        "Neha,Iyer,https://www.linkedin.com/in/neha,,Globex,Recruiter,10 Mar 2022",
        "Arjun,Rao,https://www.linkedin.com/in/arjun,,Razorpay,Analyst,10 Mar 2022",  # moved to a watched company
        "Kiran,Das,https://www.linkedin.com/in/kiran,,Some Startup,Founder,10 Mar 2022",
        "Meera,Nair,https://www.linkedin.com/in/meera,,Acme Technologies,QA,01 Oct 2024",  # new
    )
    rep = lx.import_connections(conn, _write(tmp_path, newer, "Connections (1).csv"))
    assert (rep.imported, rep.merged) == (1, 5)
    assert rep.referral_suggestions == 2  # Arjun at Razorpay, Meera at Acme; the rest exist already
    assert conn.execute("SELECT COUNT(*) FROM contacts").fetchone()[0] == 6
    rows = {r["full_name"]: r for r in conn.execute("SELECT * FROM contacts")}
    assert rows["Priya Sharma"]["title"] == "Director, Engineering"
    assert "Director, Engineering at Razorpay" in rows["Priya Sharma"]["notes"]
    assert rows["Rahul Verma"]["company_id"] is None  # left Acme
    assert rows["Arjun Rao"]["company_id"] == world["razorpay"]
    assert conn.execute("SELECT COUNT(*) FROM referrals").fetchone()[0] == 5
    # A third import of the same file changes nothing.
    again = lx.import_connections(conn, _write(tmp_path, newer, "again.csv"))
    assert (again.imported, again.merged, again.referral_suggestions) == (0, 6, 0)
    assert conn.execute("SELECT COUNT(*) FROM contacts").fetchone()[0] == 6


def test_dismissed_suggestion_is_not_recreated(conn, world, tmp_path):
    from autoapply.outreach import referrals

    lx.import_connections(conn, _write(tmp_path, EXPORT_1))
    rid = conn.execute("SELECT id FROM referrals WHERE person_name = 'Priya Sharma'").fetchone()[0]
    referrals.transition(conn, rid, ReferralState.DISMISSED)
    rep = lx.import_connections(conn, _write(tmp_path, EXPORT_1, "b.csv"))
    assert rep.referral_suggestions == 0
    assert referrals.get(conn, rid).state is ReferralState.DISMISSED


def test_import_keeps_a_typed_contact_and_forces_share_off(conn, world, tmp_path):
    from autoapply.outreach import contacts

    typed = contacts.upsert_contact(conn, company_id=world["razorpay"], full_name="Priya Sharma", origin="user",
                                    email="priya@razorpay.com", email_status="user", notes="Met at PyCon", share_ok=True).contact
    rep = lx.import_connections(conn, _write(tmp_path, EXPORT_1))
    assert rep.merged == 1 and rep.imported == 4
    c = contacts.get_contact(conn, typed.id)
    assert c.notes == "Met at PyCon" and c.email_norm == "priya@razorpay.com" and not c.share_ok
    assert c.linkedin_url == "https://www.linkedin.com/in/priya" and c.origin is ContactOrigin.USER


def test_do_not_contact_list_is_respected(conn, world, tmp_path):
    suppression.add(conn, email="rahul@gmail.com", reason=SuppressionReason.OPT_OUT)
    suppression.add(conn, domain="globex.com", reason=SuppressionReason.USER)
    rep = lx.import_connections(conn, _write(tmp_path, EXPORT_1))
    assert rep.skipped == 1 and rep.imported == 4
    names = {r[0] for r in conn.execute("SELECT full_name FROM contacts")}
    assert "Rahul Verma" not in names and "Neha Iyer" in names  # stored, but no suggestion at a do-not-contact domain
    assert {r[0] for r in conn.execute("SELECT person_name FROM referrals")} == {"Priya Sharma"}
    assert {m["name"] for m in rep.matched_companies} == {"Razorpay"}


def test_rejected_application_and_dismissed_prospect_are_not_targets(conn, world, tmp_path):
    conn.execute("UPDATE prospects SET status = 'dismissed'")
    conn.execute("UPDATE companies SET watch = 0")
    names = {t.name for t in lx.targets_of_interest(conn)}
    assert names == {"Acme Technologies"}


def test_bad_files(conn, tmp_path):
    with pytest.raises(FileNotFoundError):
        lx.import_connections(conn, tmp_path / "missing.csv")
    with pytest.raises(ValueError, match="LinkedIn Connections export"):
        lx.import_connections(conn, _write(tmp_path, "name,email\nJane,jane@x.com\n"))
