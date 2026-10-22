"""A kind no: rejections never notify (DESIGN_AWARD_VISION 1F)."""

from __future__ import annotations

from autoapply.notify import Notifier

_BASE = {"reply_id": 1, "application_id": 1, "job_id": 1, "company": "Acme", "from_email": "a@acme.com",
         "subject": "Your application", "snippet": "", "received_at": "2026-10-10T09:00:00.000Z", "message_id": "<x@y>"}


def _notifier() -> tuple[Notifier, list[tuple[str, str]]]:
    sent: list[tuple[str, str]] = []

    async def send(title: str, message: str) -> None:
        sent.append((title, message))

    return Notifier(send), sent


async def test_employer_rejection_never_notifies():
    n, sent = _notifier()
    await n.on_event("application_reply", {**_BASE, "label": "rejection", "suggested_status": "rejected"})
    await n.on_event("application_reply", {**_BASE, "label": "rejection"})
    # Whatever the label, a reply that suggests Rejected stays quiet.
    await n.on_event("application_reply", {**_BASE, "label": "other", "suggested_status": "rejected"})
    assert sent == []


async def test_good_news_still_notifies():
    n, sent = _notifier()
    for label in ("interview_invite", "assessment", "offer"):
        await n.on_event("application_reply", {**_BASE, "reply_id": label, "subject": label, "label": label})
    assert [t for t, _ in sent] == ["Acme replied: interview invite", "Acme replied: assessment", "Acme replied: offer"]
    assert not any("rejection" in t for t, _ in sent)


async def test_outreach_not_interested_never_notifies():
    n, sent = _notifier()
    reply = {"thread_id": 1, "contact_name": "Priya Shah", "company": "Acme", "snippet": "Thanks, but no."}
    await n.on_event("outreach_reply", {**reply, "label": "not_interested"})
    await n.on_event("outreach_reply", {**reply, "label": "other", "suggested_status": "rejected"})
    assert sent == []
    await n.on_event("outreach_reply", {**reply, "label": "positive", "snippet": "Happy to chat"})
    assert sent == [("Priya at Acme replied", "Happy to chat")]
