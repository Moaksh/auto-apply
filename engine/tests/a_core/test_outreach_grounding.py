"""Cold outreach anti-hallucination: the model never adds a person who is not on the page, never
produces an address, and a draft with an invented claim cannot be approved without the user."""

from __future__ import annotations

import contextlib
from typing import Any

import httpx
import pytest
import respx

from autoapply import db
from autoapply.enums import EmailStatus, OutreachKind, RoleCategory, ScoutPurpose
from autoapply.llm.provider import FakeLLMProvider
from autoapply.outreach import contacts, domains
from autoapply.outreach.scout import ContactScout, best_contact
from autoapply.outreach.service import OutreachError, OutreachService
from autoapply.outreach.sources.extract import verify_people
from tests.outreach_fakes import GOOD_DRAFT, connect_mailbox, fixture, resolver, seed_profile, seed_submitted_application

EXTRACT = {"people": [
    {"name": "Ananya Iyer", "title": "Talent Acquisition Lead"},
    {"name": "Elon Musk", "title": "CEO"},                       # not on the page: must be dropped
    {"name": "Rahul Verma", "title": "Chief Wizard"},             # on the page, title invented: title cleared
]}


def http_factory():
    @contextlib.asynccontextmanager
    async def factory():
        async with httpx.AsyncClient() as client:
            yield client

    return factory


def test_verify_people_drops_names_not_on_the_page():
    text = "Our team: Ananya Iyer, Talent Acquisition Lead. Rahul Verma, Engineering Manager."
    assert verify_people(EXTRACT["people"], text) == [("Ananya Iyer", "Talent Acquisition Lead"), ("Rahul Verma", None)]


def _routes() -> None:
    respx.get("https://acme.com/").respond(200, html=fixture("home.html"))
    respx.get("https://acme.com/team").respond(200, html=fixture("team.html"))
    respx.get(url__regex=r"https://acme\.com/.*").respond(404)
    respx.get(url__regex=r"https://api\.github\.com/.*").respond(404)


@respx.mock
async def test_scout_drops_invented_people_and_never_invents_addresses(conn):
    _routes()
    co = db.upsert_company(conn, "Acme", domain="acme.com")
    llm = FakeLLMProvider(rules=[(r"PAGE TEXT", EXTRACT), (r"Rate 0-100", {"items": []})])
    scout = ContactScout(conn, llm, http_factory=http_factory(), mx_resolver=resolver())
    report = await scout.scout_http(co.id, ScoutPurpose.APPLICATION)
    people = {c.full_name: c for c in contacts.list_contacts(conn, co.id)}
    assert "Elon Musk" not in people
    assert {"Priya Shah", "Rahul Verma", "Ananya Iyer"} <= set(people)
    assert people["Rahul Verma"].title == "Engineering Manager"  # the page's title (JSON-LD), not the model's
    # Published address (JSON-LD) vs. pattern guesses from that one sample (first.last, k=1).
    assert people["Priya Shah"].email_status is EmailStatus.PUBLISHED and people["Priya Shah"].email_confidence == 95
    assert people["Ananya Iyer"].email == "ananya.iyer@acme.com"
    assert people["Ananya Iyer"].email_status is EmailStatus.PATTERN and people["Ananya Iyer"].email_confidence == 62
    assert people["Ananya Iyer"].role_category is RoleCategory.RECRUITER
    mailbox = [c for c in people.values() if c.role_category is RoleCategory.ROLE_MAILBOX]
    assert mailbox and mailbox[0].email == "careers@acme.com"
    # Every stored address is either on the page or produced by the domain pattern.
    for c in people.values():
        ev = contacts.list_evidence(conn, c.id)
        assert any(e.field == "email" for e in ev), c.full_name
    assert domains.get_pattern(conn, "acme.com").pattern == "first.last"
    assert "company_pages" in report.sources
    assert not report.queued_google  # three usable contacts: no Google reading needed
    best = best_contact(conn, co.id, ScoutPurpose.APPLICATION, min_confidence=60)
    assert best is not None and best.full_name == "Ananya Iyer"  # recruiter-ish first for applications


@respx.mock
async def test_no_mx_means_no_addresses(conn):
    _routes()
    co = db.upsert_company(conn, "Acme", domain="acme.com")
    scout = ContactScout(conn, FakeLLMProvider(rules=[(r"PAGE TEXT", EXTRACT), (r"Rate", {"items": []})]),
                         http_factory=http_factory(), mx_resolver=resolver({"acme.com": []}))
    report = await scout.scout_http(co.id, ScoutPurpose.APPLICATION)
    assert report.mx is not None and report.mx.value == "none"
    assert all(c.email_norm is None for c in contacts.list_contacts(conn, co.id))


async def _service(conn, llm) -> tuple[OutreachService, list[tuple[str, Any]]]:
    events: list[tuple[str, Any]] = []

    async def emit(t: str, p: Any) -> None:
        events.append((t, p))

    svc = OutreachService(conn, llm, emit, is_paused=lambda: False, http_factory=http_factory(), mx_resolver=resolver(),
                          mail_password=lambda a: "pw", provider_key=lambda p: None)
    return svc, events


async def test_invented_metric_blocks_approval_until_confirmed(conn):
    seed_profile(conn)
    connect_mailbox(conn)
    co_id, _job_id, app_id = seed_submitted_application(conn)
    c = contacts.upsert_contact(conn, company_id=co_id, full_name="Jane Doe", origin="user", email="jane@acme.com",
                                email_status=EmailStatus.USER, title="Senior Recruiter").contact
    invented = {**GOOD_DRAFT, "body": GOOD_DRAFT["body"].replace("40%", "70%")}
    llm = FakeLLMProvider(default=invented)
    svc, _ = await _service(conn, llm)
    res = await svc.draft(c.id, OutreachKind.APPLICATION, application_id=app_id)
    assert res["grounded"] is False and "70%" in res["unsupported_claims"]
    assert len(llm.calls) == 2  # one regeneration with feedback
    assert "70%" in llm.calls[1].prompt and "PREVIOUS DRAFT" in llm.calls[1].prompt
    with pytest.raises(OutreachError) as ei:
        await svc.approve([res["message_id"]], False, [])
    assert ei.value.code.value == "conflict" and ei.value.details == {"ungrounded": [res["message_id"]]}
    # Editing still leaves the claim unsupported; "These are true" lets it through.
    out = svc.edit_draft(res["message_id"], None, invented["body"], confirm_claims=True)
    assert out["grounded"] is False
    ok = await svc.approve([res["message_id"]], False, [])
    assert len(ok["scheduled"]) == 1


async def test_grounded_draft_and_outreach_rules(conn):
    seed_profile(conn)
    co_id, _job_id, app_id = seed_submitted_application(conn)
    c = contacts.upsert_contact(conn, company_id=co_id, full_name="Jane Doe", origin="user", email="jane@acme.com",
                                email_status=EmailStatus.USER).contact
    svc, events = await _service(conn, FakeLLMProvider(default=GOOD_DRAFT))
    res = await svc.draft(c.id, OutreachKind.APPLICATION, application_id=app_id)
    assert res["grounded"] is True and res["unsupported_claims"] == []
    from autoapply.outreach import threads

    m = threads.get_message(conn, res["message_id"])
    assert m.subject == GOOD_DRAFT["subject"] and "I won't email again" in (m.footer or "")
    assert "a mutual contact" in (m.footer or "")  # user-typed contact
    assert any(t == "outreach_state" for t, _ in events)
    # A prospect email may not say "I applied" (and Acme has an application: prospecting is refused).
    with pytest.raises(OutreachError):
        await svc.draft(c.id, OutreachKind.PROSPECT)
    # Recipient flattery and fake referrals are flagged by the rules.
    from autoapply.outreach import drafts

    ctx = svc._context(threads.get_thread(conn, res["thread_id"]), drafts.DraftKind.APPLICATION_FOLLOWUP)
    flags = drafts.outreach_violations("I loved your talk. Sam referred me. Can we talk? Could you help?", ctx)
    assert any("talk" in f for f in flags) and any("referred" in f for f in flags) and "more than one ask" in flags


async def test_draft_refuses_do_not_contact(conn):
    from autoapply.enums import SuppressionReason
    from autoapply.outreach import suppression

    seed_profile(conn)
    co_id, _job_id, app_id = seed_submitted_application(conn)
    c = contacts.upsert_contact(conn, company_id=co_id, full_name="Jane Doe", origin="user", email="jane@acme.com",
                                email_status=EmailStatus.USER).contact
    suppression.add(conn, domain="acme.com", reason=SuppressionReason.USER)
    svc, _ = await _service(conn, FakeLLMProvider(default=GOOD_DRAFT))
    with pytest.raises(OutreachError) as ei:
        await svc.draft(c.id, OutreachKind.APPLICATION, application_id=app_id)
    assert "do-not-contact" in ei.value.message
