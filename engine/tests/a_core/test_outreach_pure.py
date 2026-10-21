"""Cold outreach: pure logic (patterns, confidence, normalisation, do-not-contact, message
composition, the send scheduler, state machines)."""

from __future__ import annotations

import email
import random
from datetime import UTC, date, datetime, timedelta

import pytest

from autoapply import db
from autoapply.enums import EmailStatus, EvidenceKind, MessageState, ReferralState, RoleCategory, SuppressionReason
from autoapply.mail import smtp_send
from autoapply.models import MESSAGE_TRANSITIONS, REFERRAL_TRANSITIONS, is_allowed_message_transition, is_allowed_referral_transition
from autoapply.outreach import contacts, patterns, sender, suppression
from autoapply.outreach.contacts import EvidenceFact, score_email

# ---- patterns ------------------------------------------------------------------------------


@pytest.mark.parametrize(("name", "email", "expected"), [
    ("Jane Doe", "jane.doe@acme.com", {"first.last"}),
    ("Jane Doe", "jdoe@acme.com", {"flast"}),
    ("Jane Doe", "jane@acme.com", {"first"}),
    ("Jane Doe", "janed@acme.com", {"firstl"}),
    ("Jane Doe", "doe.jane@acme.com", {"last.first"}),
    ("Jane Doe", "j.doe@acme.com", {"f.last"}),
    ("José Núñez", "jose.nunez@acme.com", {"first.last"}),
    ("R. Karthik", "karthik.r@acme.com", {"first.last", "last.first"}),  # both parses: given name either way round
    ("Karthik R", "karthikr@acme.com", {"firstlast", "firstl"}),
    ("Venkata Subramanian Iyer", "venkata.iyer@acme.com", {"first.last"}),
    ("Venkata Subramanian Iyer", "venkata.subramanian@acme.com", {"first.last"}),
    ("Jane Doe", "careers@acme.com", set()),                     # role mailbox: never evidence
])
def test_patterns_matching(name, email, expected):
    assert patterns.patterns_matching(name, email) == expected


def test_infer_pattern_confidence_formula():
    samples = [("Jane Doe", "jane.doe@acme.com"), ("Ravi Kumar", "ravi.kumar@acme.com"), ("Meera Nair", "mnair@acme.com")]
    inf = patterns.infer_pattern(samples)
    assert (inf.pattern, inf.supporting, inf.contradicting) == ("first.last", 2, 1)
    assert inf.confidence == 50 + 12 * 2 - 15 * 1
    assert patterns.infer_pattern([("A B", "a.b@x.com")] * 10).confidence == 85  # capped


def test_infer_pattern_defaults_without_evidence():
    assert patterns.infer_pattern([]) == patterns.PatternInference("first.last", 25, 0, 0)
    assert patterns.infer_pattern([], small_company=True).pattern == "first"
    assert patterns.infer_pattern([("Jane Doe", "careers@acme.com")]).confidence == 25


def test_guess_email_and_ambiguity():
    assert patterns.guess_email("Jane Doe", "acme.com", "first.last") == ("jane.doe@acme.com", False)
    addr, ambiguous = patterns.guess_email("Venkata Subramanian Iyer", "acme.com", "first.last")
    assert addr == "venkata.iyer@acme.com" and ambiguous
    assert patterns.guess_email("Madonna", "acme.com", "first.last") == (None, False)
    assert patterns.guess_email("Madonna", "acme.com", "first") == ("madonna@acme.com", False)


def test_next_best_pattern():
    samples = [("Jane Doe", "jdoe@acme.com"), ("Ravi Kumar", "rkumar@acme.com")]
    assert patterns.next_best_pattern(samples, "first.last") == "flast"


# ---- confidence table ----------------------------------------------------------------------


@pytest.mark.parametrize(("evidence", "status", "kw", "expected"), [
    ([], EmailStatus.USER, {}, (100, EmailStatus.USER)),
    ([], EmailStatus.REPLIED, {}, (100, EmailStatus.REPLIED)),
    ([EvidenceFact(EvidenceKind.COMPANY_PAGE, "https://acme.com/team")], EmailStatus.PUBLISHED, {}, (95, EmailStatus.PUBLISHED)),
    ([EvidenceFact(EvidenceKind.JOB_POSTING)], EmailStatus.PUBLISHED, {}, (95, EmailStatus.PUBLISHED)),
    ([EvidenceFact(EvidenceKind.GITHUB)], EmailStatus.PUBLISHED, {}, (95, EmailStatus.PUBLISHED)),
    ([EvidenceFact(EvidenceKind.PROVIDER, snippet="hunter: valid (score 92)")], EmailStatus.PROVIDER_VERIFIED, {}, (90, EmailStatus.PROVIDER_VERIFIED)),
    ([EvidenceFact(EvidenceKind.COMPANY_PAGE, "https://blog.medium.com/x")], EmailStatus.PUBLISHED, {}, (80, EmailStatus.PUBLISHED)),
    ([EvidenceFact(EvidenceKind.GOOGLE_SERP)], EmailStatus.PUBLISHED, {}, (80, EmailStatus.PUBLISHED)),
    ([EvidenceFact(EvidenceKind.PATTERN)], EmailStatus.PATTERN, {"pattern_confidence": 74}, (74, EmailStatus.PATTERN)),
    ([EvidenceFact(EvidenceKind.PATTERN)], EmailStatus.PATTERN, {"pattern_confidence": 74, "ambiguous": True}, (64, EmailStatus.PATTERN)),
    ([EvidenceFact(EvidenceKind.PATTERN)], EmailStatus.PATTERN, {"pattern_confidence": 99}, (85, EmailStatus.PATTERN)),
    ([EvidenceFact(EvidenceKind.PATTERN)], EmailStatus.DELIVERED, {"pattern_confidence": 74}, (84, EmailStatus.PATTERN)),
    ([EvidenceFact(EvidenceKind.PATTERN)], EmailStatus.DELIVERED, {"pattern_confidence": 85}, (90, EmailStatus.PATTERN)),
    ([EvidenceFact(EvidenceKind.COMPANY_PAGE, "https://acme.com/team")], EmailStatus.BOUNCED, {}, (0, EmailStatus.BOUNCED)),
])
def test_confidence_table(evidence, status, kw, expected):
    assert score_email(evidence, status=status, company_domain="acme.com", **kw) == expected


def test_tiers():
    assert [contacts.tier(c) for c in (100, 90, 89, 70, 69, 40, 39)] == ["verified", "verified", "likely", "likely", "guess", "guess", "unknown"]


@pytest.mark.parametrize(("title", "email", "cat"), [
    ("Senior Technical Recruiter", None, RoleCategory.RECRUITER),
    ("Talent Acquisition Partner", None, RoleCategory.RECRUITER),
    ("Head of Talent", None, RoleCategory.TALENT_LEAD),
    ("Engineering Manager, Payments", None, RoleCategory.HIRING_MANAGER),
    ("VP Engineering", None, RoleCategory.ENG_LEADER),
    ("Co-founder & CEO", None, RoleCategory.FOUNDER),
    ("Senior Software Engineer", None, RoleCategory.ENGINEER),
    (None, "careers@acme.com", RoleCategory.ROLE_MAILBOX),
    ("Office Manager", None, RoleCategory.OTHER),
])
def test_classify_role(title, email, cat):
    assert contacts.classify_role(title, email) is cat


# ---- normalisation / do-not-contact ------------------------------------------------------------


@pytest.mark.parametrize(("raw", "norm"), [
    ("  Jane.Doe@ACME.com ", "jane.doe@acme.com"),
    ("mailto:jane@acme.com?subject=hi", "jane@acme.com"),
    ("<jane@acme.com>", "jane@acme.com"),
    ("ｊａｎｅ@acme.com", "jane@acme.com"),  # NFKC full-width
    ("not an email", None),
    ("jane@localhost", None),
    ("a@b@c.com", None),
    (None, None),
])
def test_normalize_email(raw, norm):
    assert suppression.normalize_email(raw) == norm


def test_suppression_checks(conn):
    assert suppression.check(conn, "jane@acme.com") is None
    suppression.add(conn, email="Jane@Acme.com", reason=SuppressionReason.HARD_BOUNCE)
    assert suppression.check(conn, "jane@acme.com") is SuppressionReason.HARD_BOUNCE
    suppression.add(conn, domain="globex.com", reason=SuppressionReason.USER)
    assert suppression.check(conn, "anyone@globex.com") is SuppressionReason.USER
    assert suppression.check(conn, "anyone@eu.globex.com") is SuppressionReason.USER  # subdomain
    assert suppression.check(conn, "anyone@notglobex.com") is None
    # An opt-out upgrades the reason and can never be removed through the API.
    suppression.add(conn, email="jane@acme.com", reason=SuppressionReason.OPT_OUT)
    assert suppression.check(conn, "jane@acme.com") is SuppressionReason.OPT_OUT
    with pytest.raises(suppression.SuppressionLocked):
        suppression.remove(conn, email="jane@acme.com")
    assert suppression.remove(conn, domain="globex.com") is True
    assert suppression.check(conn, "anyone@globex.com") is None


def test_scouted_free_mail_is_never_stored(conn):
    co = db.upsert_company(conn, "Acme", domain="acme.com")
    res = contacts.upsert_contact(conn, company_id=co.id, full_name="Jane Doe", origin="scout", email="jane.doe@gmail.com",
                                  email_status=EmailStatus.PUBLISHED)
    assert res.contact.email is None and res.rejected
    typed = contacts.upsert_contact(conn, company_id=co.id, full_name="Ravi Kumar", origin="user", email="ravi@gmail.com",
                                    email_status=EmailStatus.USER)
    assert typed.contact.email_norm == "ravi@gmail.com" and typed.contact.email_confidence == 100


def test_contact_merge_by_email_and_name(conn):
    co = db.upsert_company(conn, "Acme", domain="acme.com")
    a = contacts.upsert_contact(conn, company_id=co.id, full_name="Jane Doe", origin="scout", email="jane.doe@acme.com",
                                email_status=EmailStatus.PATTERN,
                                evidence=[contacts.NewEvidence(EvidenceKind.PATTERN, "email", snippet="pattern first.last")],
                                pattern_confidence=62)
    assert a.created and a.contact.email_confidence == 62
    b = contacts.upsert_contact(conn, company_id=co.id, full_name="jane doe", origin="scout", email="jdoe@acme.com",
                                email_status=EmailStatus.PUBLISHED, title="Recruiter",
                                evidence=[contacts.NewEvidence(EvidenceKind.COMPANY_PAGE, "email", url="https://acme.com/team")])
    assert b.merged and b.contact.id == a.contact.id
    assert b.contact.email_norm == "jdoe@acme.com" and b.contact.email_confidence == 95  # published beats pattern
    assert b.contact.role_category is RoleCategory.RECRUITER


# ---- message composition ------------------------------------------------------------------------


def test_compose_plain_text_with_threading_and_footer():
    from autoapply.outreach import drafts

    footer = drafts.footer("acme.com/team")
    mid = smtp_send.make_message_id("asha@gmail.com")
    msg = smtp_send.compose(from_name="Asha Rao", from_addr="asha@gmail.com", to="jane@acme.com", subject="Re: Backend role",
                            body=drafts.full_body("Hi Jane,\n\nFollowing up.", footer), message_id=mid,
                            in_reply_to="<orig-1@gmail.com>", references=["<orig-0@gmail.com>"])
    parsed = email.message_from_bytes(msg.as_bytes())
    assert parsed.get_content_type() == "text/plain" and not parsed.is_multipart()
    assert parsed["In-Reply-To"] == "<orig-1@gmail.com>"
    assert parsed["References"] == "<orig-0@gmail.com> <orig-1@gmail.com>"
    assert parsed["Message-ID"] == mid and mid.endswith("@gmail.com>")
    assert parsed["From"] == "Asha Rao <asha@gmail.com>"
    assert "List-Unsubscribe" not in parsed
    body = parsed.get_payload(decode=True).decode()
    assert "I won't email again" in body and "acme.com/team" in body
    assert "<html" not in body.lower() and "<img" not in body.lower()


def test_subject_rules():
    from autoapply.outreach import drafts

    assert drafts.subject_ok("Backend Engineer application – Asha Rao")
    assert not drafts.subject_ok("Re: Backend role")
    assert not drafts.subject_ok("Fwd: hi")
    assert not drafts.subject_ok("one two three four five six seven eight nine")
    assert drafts.reply_subject("Backend role") == "Re: Backend role"
    assert drafts.reply_subject("Re: Backend role") == "Re: Backend role"


# ---- scheduler (window, spacing, caps, ramp) -----------------------------------------------------------

WINDOW = ["09:30", "17:30"]


def _local(y, m, d, hh, mm):
    return datetime(y, m, d, hh, mm).astimezone()


def test_window_and_next_start():
    wed_10 = _local(2026, 10, 21, 10, 0)  # a Wednesday
    assert sender.in_window(wed_10, WINDOW, True)
    assert sender.next_window_start(wed_10, WINDOW, True) == wed_10
    wed_8 = _local(2026, 10, 21, 8, 0)
    assert sender.next_window_start(wed_8, WINDOW, True) == _local(2026, 10, 21, 9, 30)
    fri_18 = _local(2026, 10, 23, 18, 0)
    assert sender.next_window_start(fri_18, WINDOW, True) == _local(2026, 10, 26, 9, 30)  # Monday
    assert sender.next_window_start(fri_18, WINDOW, False) == _local(2026, 10, 24, 9, 30)  # Saturday allowed
    assert sender.add_business_days(_local(2026, 10, 23, 12, 0), 1).date() == date(2026, 10, 26)


def test_plan_spreads_over_days_with_caps_and_spacing():
    now = _local(2026, 10, 21, 16, 0)
    items = [sender.PlanItem(i, f"d{i}.com", True) for i in range(1, 8)]
    times = sender.plan_send_times(items, now=now, window=WINDOW, weekdays_only=True, new_limit=lambda d: 5,
                                   total_cap=20, load=lambda d: sender.DayLoad(), rng=random.Random(1))
    days = sorted({t.date() for t in times.values()})
    per_day = {d: sum(1 for t in times.values() if t.date() == d) for d in days}
    assert per_day[date(2026, 10, 21)] <= 5 and sum(per_day.values()) == 7
    assert all(sender.in_window(t, WINDOW, True) for t in times.values())
    ordered = sorted(times.values())
    for a, b in zip(ordered, ordered[1:]):
        if a.date() == b.date():
            assert (b - a).total_seconds() >= sender.MIN_SPACING_S


def test_plan_respects_per_domain_and_earliest():
    now = _local(2026, 10, 21, 10, 0)
    items = [sender.PlanItem(i, "acme.com", True) for i in range(1, 4)]
    items.append(sender.PlanItem(9, "globex.com", True, earliest=_local(2026, 10, 22, 11, 0)))
    times = sender.plan_send_times(items, now=now, window=WINDOW, weekdays_only=True, new_limit=lambda d: 10, total_cap=20,
                                   load=lambda d: sender.DayLoad(), rng=random.Random(2))
    acme_today = [t for i, t in times.items() if i <= 3 and t.date() == date(2026, 10, 21)]
    assert len(acme_today) == sender.PER_DOMAIN_PER_DAY
    assert times[9] >= _local(2026, 10, 22, 11, 0)


def test_plan_carries_existing_load_over():
    now = _local(2026, 10, 21, 10, 0)
    full = sender.DayLoad(new=5, total=5)
    times = sender.plan_send_times([sender.PlanItem(1, "a.com", True), sender.PlanItem(2, "b.com", False)], now=now, window=WINDOW,
                                   weekdays_only=True, new_limit=lambda d: 5, total_cap=10,
                                   load=lambda d: full if d == date(2026, 10, 21) else sender.DayLoad(), rng=random.Random(3))
    assert times[1].date() == date(2026, 10, 22)  # no new-thread room today
    assert times[2].date() == date(2026, 10, 21)  # a follow-up still fits the total cap


def test_ramp_limits(conn):
    prefs = db.get_preferences(conn)
    today = datetime.now(UTC).astimezone().date()
    assert sender.ramp_limit(conn, prefs, today) == 5  # never sent yet
    db.set_meta(conn, db.META_OUTREACH_FIRST_SEND, (today - timedelta(days=4)).isoformat())
    assert sender.ramp_limit(conn, prefs, today) == 8
    db.set_meta(conn, db.META_OUTREACH_FIRST_SEND, (today - timedelta(days=10)).isoformat())
    assert sender.ramp_limit(conn, prefs, today) == 10
    assert sender.total_limit(10) == 20 and sender.total_limit(40) == 60


# ---- state machines --------------------------------------------------------------------------------


def test_message_transitions():
    assert set(MESSAGE_TRANSITIONS) == set(MessageState)
    assert is_allowed_message_transition("scheduled", "sending")
    assert is_allowed_message_transition("sending", "unknown")
    assert not is_allowed_message_transition("draft", "sending")  # never without approval
    assert not is_allowed_message_transition("draft", "scheduled")
    assert not is_allowed_message_transition("unknown", "scheduled")  # never resent automatically
    assert not is_allowed_message_transition("unknown", "sending")
    assert MESSAGE_TRANSITIONS[MessageState.SENT] == frozenset()


def test_referral_transitions():
    assert set(REFERRAL_TRANSITIONS) == set(ReferralState)
    assert is_allowed_referral_transition("requested", "connected")
    assert is_allowed_referral_transition("asked", "referred")
    assert not is_allowed_referral_transition("suggested", "referred")
    assert REFERRAL_TRANSITIONS[ReferralState.REFERRED] == frozenset()


def test_transition_outreach_enforces_and_logs(conn):
    from autoapply.enums import DraftKind, OutreachKind
    from autoapply.outreach import threads

    co = db.upsert_company(conn, "Acme")
    t = threads.create_thread(conn, kind=OutreachKind.PROSPECT, company_id=co.id, contact_id=None)
    m = threads.insert_draft(conn, thread_id=t.id, kind=DraftKind.PROSPECT, to_email="a@acme.com", subject="s", body="b",
                             footer="f", grounded=True, unsupported=[], story_ids=[])
    with pytest.raises(db.IllegalOutreachTransition):
        db.transition_outreach(conn, m.id, MessageState.SENDING)
    tr = db.transition_outreach(conn, m.id, MessageState.APPROVED)
    assert tr.to_payload().to_state == "approved"
    assert db.list_events(conn, kinds=["outreach"])[-1].payload["to"] == "approved"
