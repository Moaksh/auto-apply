"""``OutreachService``: what the daemon owns for cold outreach (plan §G.4).

* Command implementations (``_cmd_*`` in the daemon delegate here).
* Hooks: :meth:`on_submitted` after an application becomes ``submitted`` (auto-scout +
  auto-draft, both on by default, 30-day per-company cache).
* :meth:`tick` every 60 s: the sender (one due message), the mail watcher every 10 minutes
  while something was sent in the last 45 days, and the Sent Mail check for ``unknown``
  messages left by a crash.
* :meth:`maintenance` (hourly, from ``Pipeline.maintenance``): follow-ups, referral reminders,
  "delivered" confidence bumps, retention purge, watchlist prospects, the daily "drafts ready".
* :meth:`run_google_work`: the parts that need the agent Chrome (people / referrer / company
  searches on Google). Runs as the last step of a full run, or when the browser is free.

Nothing here sends an email that the user did not approve with ``approve_outreach``.
"""

from __future__ import annotations

import asyncio
import csv
import logging
import random
import smtplib
import sqlite3
from collections.abc import Awaitable, Callable, Coroutine
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta
from email.message import EmailMessage
from email.utils import parseaddr
from pathlib import Path
from typing import Any

import httpx

from autoapply import db
from autoapply.enums import (
    Actor,
    ContactOrigin,
    DraftKind,
    EmailStatus,
    ErrorCode,
    EvidenceKind,
    MessageState,
    OutreachKind,
    ProspectStatus,
    ReferralState,
    ScoutPurpose,
    SuppressionReason,
    ThreadOutcome,
    ThreadState,
)
from autoapply.answers import voice
from autoapply.llm.provider import LLMProvider
from autoapply.models import (
    OutreachMessage,
    OutreachThread,
    ScoutFinishedPayload,
    format_ts,
    new_id,
    now_ts,
    parse_ts,
    utcnow,
)
from autoapply.outreach import contacts, domains, drafts, mailwatch, prospects, referrals, sender, suppression, threads
from autoapply.outreach.contacts import NewEvidence
from autoapply.outreach.scout import ContactScout, best_contact, google_queue, pop_google, recently_scouted
from autoapply.outreach.sources import google_people

log = logging.getLogger("autoapply.outreach.service")

#: Tests switch this off (conftest) so a submitted application never triggers network work.
AUTO_ENABLED = True
MAIL_SCAN_EVERY_S = 600.0
DELIVERED_AFTER_H = 72
META_REFERRER_QUEUE = "outreach_referrer_queue"
META_DRAFTS_NOTIFIED = "outreach_drafts_notified"
META_DAILY_DONE = "outreach_daily_maintenance"

EmitFn = Callable[[str, Any], Awaitable[None]]
SpawnFn = Callable[[Coroutine[Any, Any, Any], str], Any]


class OutreachError(Exception):
    """A command failed for a reason the user can act on (mapped to the protocol error code)."""

    def __init__(self, code: ErrorCode, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details


def _default_http() -> Any:
    @asynccontextmanager
    async def factory():  # type: ignore[no-untyped-def]
        async with httpx.AsyncClient(timeout=20, headers={"User-Agent": domains.USER_AGENT}) as client:
            yield client

    return factory


@dataclass(slots=True)
class _MailAccount:
    email: str
    send_enabled: bool


class OutreachService:
    def __init__(
        self,
        conn: sqlite3.Connection,
        llm: LLMProvider | None,
        emit: EmitFn,
        *,
        is_paused: Callable[[], bool],
        spawn: SpawnFn | None = None,
        notifier: Any = None,
        http_factory: Callable[[], Any] | None = None,
        mx_resolver: domains.MxResolver | None = None,
        smtp_factory: Callable[..., Any] | None = None,
        mailbox_factory: Callable[[str, str], Any] | None = None,
        browser_factory: Any = None,
        profile_dir: Path | None = None,
        mail_password: Callable[[str], str | None] | None = None,
        provider_key: Callable[[str], str | None] | None = None,
        pacer: Any = None,
        now: Callable[[], datetime] | None = None,
        rng: random.Random | None = None,
    ) -> None:
        from autoapply.mail import imap_codes
        from autoapply.outreach.providers import base as providers

        self.conn = conn
        self.llm = llm
        self.emit = emit
        self.is_paused = is_paused
        self._spawn = spawn
        self.notifier = notifier
        self.http_factory = http_factory or _default_http()
        self.mx_resolver = mx_resolver or domains.dns_mx_hosts
        self.smtp_factory = smtp_factory or smtplib.SMTP
        self.mailbox_factory = mailbox_factory
        self._browser_factory = browser_factory
        self.profile_dir = profile_dir
        self.mail_password = mail_password or imap_codes.keychain_get
        self.provider_key = provider_key or providers.keychain_get
        self.pacer = pacer
        self.now = now or utcnow
        self.rng = rng or random.Random()
        self._last_scan: datetime | None = None
        self._google_lock = asyncio.Lock()
        self._verify_lock = asyncio.Lock()
        self.scout = ContactScout(
            conn, llm, http_factory=self.http_factory, mx_resolver=self.mx_resolver,
            provider_factory=self._provider, github_token=lambda: self.provider_key("github"), is_paused=is_paused,
        )
        self.sender = sender.OutreachSender(
            conn, emit=emit, compose_fn=self.compose, deliver_fn=self.deliver, ready=self.send_blocker,
            is_paused=is_paused, on_sent=self._on_sent, now=self.now, rng=self.rng,
        )

    # =================================================================================
    # Plumbing
    # =================================================================================

    def spawn(self, coro: Coroutine[Any, Any, Any], name: str) -> None:
        if self._spawn is not None:
            self._spawn(coro, name)
        else:
            asyncio.get_running_loop().create_task(coro, name=name)

    async def _emit_all(self, items: list[tuple[str, Any]] | list[Any], event_type: str | None = None) -> None:
        for it in items:
            if it is None:
                continue
            if event_type is not None:
                await self.emit(event_type, it)
            else:
                await self.emit(it[0], it[1])

    def _provider(self, http: httpx.AsyncClient) -> Any:
        key = self.provider_key("hunter")
        if not key:
            return None
        from autoapply.outreach.providers.hunter import HunterProvider

        return HunterProvider(key, http, self.conn)

    def browser_factory(self) -> Any:
        if self._browser_factory is None:
            from autoapply.discovery.linkedin import playwright_browser_factory
            from autoapply.paths import get_paths

            self._browser_factory = playwright_browser_factory(self.profile_dir or get_paths().chrome_profile)
        return self._browser_factory

    # =================================================================================
    # Mailbox / sending switch
    # =================================================================================

    def account(self) -> _MailAccount | None:
        from autoapply.mail import imap_codes

        acc = imap_codes.account(self.conn)
        if not acc:
            return None
        return _MailAccount(email=str(acc["email"]), send_enabled=bool(acc.get("send_enabled", False)))

    def send_blocker(self) -> str | None:
        """Why nothing can be sent right now (None: sending is on)."""
        from autoapply.mail.common import is_google_mailbox

        acc = self.account()
        if acc is None:
            return "connect your mailbox first (Settings ▸ Outreach)"
        if not is_google_mailbox(acc.email):
            return "sending works with Gmail / Google Workspace mailboxes only"
        if not acc.send_enabled:
            return "sending is off: turn on 'Enable sending' (it sends you a test email first)"
        return None

    async def enable_sending(self, enabled: bool) -> dict[str, Any]:
        from autoapply.mail import imap_codes, smtp_send
        from autoapply.mail.common import is_google_mailbox

        acc = imap_codes.account(self.conn)
        if not enabled:
            if acc:
                db.set_meta(self.conn, imap_codes.META_KEY, {**acc, "send_enabled": False})
            db.log_event(self.conn, "user", "turned off outreach sending", actor=Actor.USER)
            return {"send_enabled": False, "test_sent_to": None}
        if not acc:
            raise OutreachError(ErrorCode.UNAVAILABLE, "connect your mailbox first (the same app password works for sending)")
        address = str(acc["email"])
        if not is_google_mailbox(address):
            raise OutreachError(ErrorCode.UNAVAILABLE, "sending works with Gmail / Google Workspace mailboxes only (for now)")
        password = await asyncio.to_thread(self.mail_password, address)
        if not password:
            raise OutreachError(ErrorCode.UNAVAILABLE, "the app password is missing from the Keychain; reconnect the mailbox")
        name = db.get_profile(self.conn).full_name
        try:
            await asyncio.to_thread(smtp_send.send_test_email, address, password, from_name=name, smtp_factory=self.smtp_factory)
        except (smtp_send.SendRefused, smtp_send.SendUnknown) as e:
            raise OutreachError(ErrorCode.UNAVAILABLE, f"the test email did not go through: {e}") from e
        db.set_meta(self.conn, imap_codes.META_KEY, {**acc, "send_enabled": True, "send_enabled_at": now_ts()})
        db.log_event(self.conn, "user", f"enabled outreach sending from {address} (test email sent)", actor=Actor.USER)
        return {"send_enabled": True, "test_sent_to": address}

    def compose(self, msg: OutreachMessage, thread: OutreachThread) -> EmailMessage:
        """The exact email for ``msg`` (body + footer, threading headers). Runs on the loop."""
        from autoapply.mail import smtp_send

        acc = self.account()
        if acc is None or not msg.to_email or not msg.message_id_header:
            raise ValueError("no mailbox / recipient / Message-ID")
        prior = [m.message_id_header for m in threads.sent_messages(self.conn, thread.id) if m.message_id_header and m.id != msg.id]
        footer = msg.footer or drafts.footer("a public web page")
        return smtp_send.compose(
            from_name=db.get_profile(self.conn).full_name, from_addr=acc.email, to=msg.to_email,
            subject=msg.subject or thread.subject or "", body=drafts.full_body(msg.body, footer),
            message_id=msg.message_id_header, in_reply_to=msg.in_reply_to or (prior[-1] if prior else None), references=prior,
        )

    def deliver(self, email: EmailMessage) -> None:
        """SMTP (worker thread): no database access here."""
        from autoapply.mail import smtp_send

        address = parseaddr(str(email["From"]))[1]
        password = self.mail_password(address)
        if not password:
            raise smtp_send.SendRefused("the app password is missing from the Keychain")
        smtp_send.send(address, password, email, smtp_factory=self.smtp_factory)

    async def _on_sent(self, msg: OutreachMessage, thread: OutreachThread) -> None:
        prefs = db.get_preferences(self.conn)
        sent_at = msg.sent_at or self.now()
        next_at = sender.add_business_days(sent_at, prefs.outreach_followup_days)
        p = threads.set_thread_state(self.conn, thread.id, ThreadState.ACTIVE, reason="sent", next_action_at=format_ts(next_at))
        if p is not None:
            await self.emit("outreach_state", p)
        if thread.contact_id is not None:
            with db.transaction(self.conn):
                self.conn.execute("UPDATE contacts SET last_contacted_at = ?, updated_at = ? WHERE id = ?",
                                  (format_ts(sent_at), now_ts(), thread.contact_id))
        if thread.kind is OutreachKind.PROSPECT:
            pr = prospects.get_by_company(self.conn, thread.company_id)
            if pr is not None and pr.status is not ProspectStatus.CONTACTED:
                prospects.set_status(self.conn, pr.id, ProspectStatus.CONTACTED)
        who = "?"
        if thread.contact_id is not None:
            try:
                c = contacts.get_contact(self.conn, thread.contact_id)
                who = c.full_name.split()[0] + (f" ({c.title})" if c.title else "")
            except db.NotFound:
                pass
        db.log_event(self.conn, "outreach", f"Emailed {who}" + (" (follow-up)" if msg.seq else ""), job_id=thread.job_id,
                     application_id=thread.application_id, payload={"thread_id": thread.id, "message_id": msg.id})

    # =================================================================================
    # Scouting
    # =================================================================================

    def on_submitted(self, application_id: int) -> None:
        """Pipeline / daemon hook: an application just became ``submitted``."""
        if not AUTO_ENABLED:
            return
        try:
            prefs = db.get_preferences(self.conn)
            if not prefs.outreach_auto_scout:
                return
            app = db.get_application(self.conn, application_id)
            job = db.get_job(self.conn, app.job_id)
        except Exception:  # noqa: BLE001 - a hook must never break the caller
            log.exception("outreach on_submitted failed")
            return
        self.spawn(self.scout_and_draft(job.company_id, ScoutPurpose.APPLICATION, job_id=job.id, application_id=application_id),
                   f"outreach-scout-{job.company_id}")

    def scout_command(self, company_id: int | None, application_id: int | None, purpose: ScoutPurpose) -> dict[str, Any]:
        job_id = None
        if application_id is not None:
            app = db.get_application(self.conn, application_id)
            job = db.get_job(self.conn, app.job_id)
            company_id, job_id = job.company_id, job.id
        if company_id is None:
            raise ValueError("give company_id or application_id")
        db.get_company(self.conn, company_id)
        self.spawn(self.scout_and_draft(company_id, purpose, job_id=job_id, application_id=application_id, force=True),
                   f"outreach-scout-{company_id}")
        prefs = db.get_preferences(self.conn)
        return {"company_id": company_id, "queued_google": prefs.people_finder_visits_per_day > 0}

    async def scout_and_draft(self, company_id: int, purpose: ScoutPurpose, *, job_id: int | None = None,
                              application_id: int | None = None, force: bool = False) -> ScoutFinishedPayload | None:
        """HTTP scout (unless cached), then the automatic draft for an application."""
        if self.is_paused():
            return None
        try:
            queued = False
            if force or not recently_scouted(self.conn, company_id):
                report = await self.scout.scout_http(company_id, purpose, job_id=job_id)
                queued = report.queued_google
            thread_id = None
            if purpose is ScoutPurpose.APPLICATION and application_id is not None:
                thread_id = await self._auto_draft(company_id, application_id)
            found, with_email, best = self._company_summary(company_id)
            payload = ScoutFinishedPayload(company_id=company_id, purpose=purpose, application_id=application_id, found=found,
                                           with_email=with_email, best_confidence=best, queued_google=queued, thread_id=thread_id)
            await self.emit("scout_finished", payload)
            return payload
        except Exception:  # noqa: BLE001 - background work: log, never crash the daemon
            log.exception("scout of company %s failed", company_id)
            return None

    def _company_summary(self, company_id: int) -> tuple[int, int, int | None]:
        rows = self.conn.execute("SELECT email_norm, email_confidence FROM contacts WHERE company_id = ?", (company_id,)).fetchall()
        confs = [int(r["email_confidence"]) for r in rows if r["email_norm"]]
        return len(rows), len(confs), (max(confs) if confs else None)

    async def _auto_draft(self, company_id: int, application_id: int) -> int | None:
        prefs = db.get_preferences(self.conn)
        if not prefs.outreach_auto_draft:
            return None
        exists = self.conn.execute("SELECT 1 FROM outreach_threads WHERE application_id = ? AND state <> 'cancelled'",
                                   (application_id,)).fetchone()
        if exists:
            return None
        app = db.get_application(self.conn, application_id)
        if app.status is not None and app.status.value in ("rejected", "offer"):
            return None
        c = best_contact(self.conn, company_id, ScoutPurpose.APPLICATION, min_confidence=prefs.outreach_min_email_confidence)
        if c is None:
            return None
        try:
            res = await self.draft(c.id, OutreachKind.APPLICATION, application_id=application_id)
        except OutreachError as e:
            log.info("no automatic draft for application %s: %s", application_id, e.message)
            return None
        return int(res["thread_id"])

    # =================================================================================
    # Contacts
    # =================================================================================

    def add_contact(self, p: Any) -> dict[str, Any]:
        company_id = p.company_id
        if company_id is None and (p.company_name or "").strip():
            company_id = db.upsert_company(self.conn, p.company_name.strip()).id
        elif company_id is not None:
            db.get_company(self.conn, company_id)
        if p.email and suppression.normalize_email(p.email) is None:
            raise ValueError(f"not an email address: {p.email!r}")
        existing = contacts.find_by_email(self.conn, p.email)
        ev = [NewEvidence(EvidenceKind.USER, "name", snippet="added by you")]
        if p.email:
            ev.append(NewEvidence(EvidenceKind.USER, "email", snippet="typed by you"))
        res = contacts.upsert_contact(
            self.conn, company_id=company_id, full_name=p.full_name, origin=ContactOrigin.USER, email=p.email,
            email_status=EmailStatus.USER if p.email else EmailStatus.NONE, title=p.title, linkedin_url=p.linkedin_url,
            relationship=p.relationship.value if p.relationship else None, notes=p.notes, share_ok=p.share_ok, evidence=ev,
        )
        db.log_event(self.conn, "user", f"added contact {res.contact.full_name}", actor=Actor.USER, payload={"contact_id": res.contact.id})
        return {"contact_id": res.contact.id, "merged": existing is not None or res.merged}

    def update_contact(self, contact_id: int, patch: dict[str, Any]) -> None:
        if "relationship" in patch and patch["relationship"] is not None:
            patch["relationship"] = getattr(patch["relationship"], "value", patch["relationship"])
        c = contacts.update_contact(self.conn, contact_id, patch)
        if c.email_norm and suppression.check(self.conn, c.email_norm) is not None:
            log.info("contact %s now has a do-not-contact address", contact_id)

    async def delete_contact(self, contact_id: int, suppress: bool) -> None:
        contacts.get_contact(self.conn, contact_id)
        events = []
        for r in self.conn.execute("SELECT id FROM outreach_threads WHERE contact_id = ? AND state IN ('draft','active')",
                                   (contact_id,)).fetchall():
            events += threads.cancel_pending(self.conn, int(r["id"]), "contact deleted", actor=Actor.USER)
        contacts.delete_contact(self.conn, contact_id, suppress=suppress)
        await self._emit_all(events, "outreach_state")

    def import_contacts(self, file_path: str) -> dict[str, int]:
        path = Path(file_path).expanduser()
        if not path.is_file():
            raise FileNotFoundError(f"CSV not found: {path}")
        added = merged = skipped = 0
        with path.open(newline="", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            for raw in reader:
                row = {(k or "").strip().lower(): (v or "").strip() for k, v in raw.items()}
                name, email = row.get("name") or row.get("full_name") or "", row.get("email") or ""
                if not name or (email and suppression.normalize_email(email) is None):
                    skipped += 1
                    continue
                if email and suppression.check(self.conn, email) is not None:
                    skipped += 1
                    continue
                company_id = db.upsert_company(self.conn, row["company"]).id if row.get("company") else None
                ev = [NewEvidence(EvidenceKind.USER, "name", snippet=f"imported from {path.name}")]
                if email:
                    ev.append(NewEvidence(EvidenceKind.USER, "email", snippet=f"imported from {path.name}"))
                res = contacts.upsert_contact(
                    self.conn, company_id=company_id, full_name=name, origin=ContactOrigin.IMPORT, email=email or None,
                    email_status=EmailStatus.USER if email else EmailStatus.NONE, title=row.get("title") or None,
                    linkedin_url=row.get("linkedin_url") or None, notes=row.get("notes") or None, share_ok=False, evidence=ev,
                )
                if res.created:
                    added += 1
                else:
                    merged += 1
        db.log_event(self.conn, "user", f"imported contacts from {path.name}: {added} new, {merged} merged, {skipped} skipped",
                     actor=Actor.USER)
        return {"added": added, "merged": merged, "skipped": skipped}

    # =================================================================================
    # Drafting
    # =================================================================================

    def _context(self, thread: OutreachThread, kind: DraftKind, *, contact_id: int | None = None,
                 previous: OutreachMessage | None = None, instructions: str | None = None) -> drafts.DraftContext:
        cid = contact_id if contact_id is not None else thread.contact_id
        contact = contacts.get_contact(self.conn, cid) if cid is not None else None
        company = db.get_company(self.conn, thread.company_id)
        job = db.get_job(self.conn, thread.job_id) if thread.job_id is not None else None
        evidence: list[str] = []
        pr = prospects.get_by_company(self.conn, company.id)
        if pr is not None and pr.summary:
            evidence.append(pr.summary)
        basis, has_ref = None, False
        if contact is not None:
            ref = self.conn.execute("SELECT * FROM referrals WHERE contact_id = ? ORDER BY id DESC LIMIT 1", (contact.id,)).fetchone()
            if ref is not None:
                from autoapply.models import Referral

                r = Referral.from_row(ref)
                basis = referrals.basis_sentence(r, db.get_profile(self.conn))  # type: ignore[arg-type]
                has_ref = r.state is ReferralState.REFERRED  # type: ignore[union-attr]
        return drafts.DraftContext(
            kind=kind, profile=db.get_profile(self.conn), stories=db.list_stories(self.conn), company=company,
            recipient_name=contact.full_name if contact else "", recipient_title=contact.title if contact else None,
            job=job, company_evidence=evidence, referral_basis=basis, has_referral=has_ref,
            previous_subject=previous.subject if previous else None, previous_body=previous.body if previous else None,
            instructions=instructions, voice=voice.load_profile(self.conn),
        )

    @staticmethod
    def _first_kind(kind: OutreachKind) -> DraftKind:
        return {OutreachKind.APPLICATION: DraftKind.APPLICATION_FOLLOWUP, OutreachKind.PROSPECT: DraftKind.PROSPECT,
                OutreachKind.REFERRAL_EMAIL: DraftKind.REFERRAL_EMAIL}[kind]

    async def draft(self, contact_id: int, kind: OutreachKind, *, application_id: int | None = None,
                    instructions: str | None = None) -> dict[str, Any]:
        """Write (or rewrite) the first email to ``contact_id``. Never sends."""
        if self.llm is None:
            raise OutreachError(ErrorCode.UNAVAILABLE, "no model available to draft with")
        contact = contacts.get_contact(self.conn, contact_id)
        if not contact.email_norm:
            raise OutreachError(ErrorCode.CONFLICT, f"{contact.full_name} has no email address yet")
        if (why := suppression.check(self.conn, contact.email_norm)) is not None:
            raise OutreachError(ErrorCode.CONFLICT, f"{contact.email_norm} is on your do-not-contact list ({why.value})",
                                {"reason": why.value})
        if contact.email_status is EmailStatus.BOUNCED:
            raise OutreachError(ErrorCode.CONFLICT, f"{contact.email_norm} bounced before")
        job_id = None
        if kind is OutreachKind.APPLICATION:
            if application_id is None:
                raise ValueError("an application email needs application_id")
            app = db.get_application(self.conn, application_id)
            if app.state.value != "submitted":
                raise OutreachError(ErrorCode.CONFLICT, "follow-ups are for submitted applications")
            job = db.get_job(self.conn, app.job_id)
            job_id, company_id = job.id, job.company_id
        else:
            if contact.company_id is None:
                raise OutreachError(ErrorCode.CONFLICT, "give the contact a company first")
            company_id = contact.company_id
            if kind is OutreachKind.PROSPECT:
                why_not = prospects.blocked_reason(self.conn, company_id, db.get_preferences(self.conn), contact_id=contact_id,
                                                   now=self.now())
                if why_not:
                    raise OutreachError(ErrorCode.CONFLICT, why_not)
            ref = self.conn.execute("SELECT job_id FROM referrals WHERE contact_id = ? AND job_id IS NOT NULL ORDER BY id DESC LIMIT 1",
                                    (contact_id,)).fetchone()
            job_id = int(ref[0]) if (kind is OutreachKind.REFERRAL_EMAIL and ref) else None
        # Reuse the open draft thread (switching contact re-drafts); never a second live thread.
        if application_id is not None:
            row = self.conn.execute("SELECT * FROM outreach_threads WHERE application_id = ? AND state IN ('draft','active') "
                                    "ORDER BY id DESC LIMIT 1", (application_id,)).fetchone()
        else:
            row = self.conn.execute("SELECT * FROM outreach_threads WHERE company_id = ? AND contact_id = ? AND kind = ? "
                                    "AND state IN ('draft','active') ORDER BY id DESC LIMIT 1", (company_id, contact_id, kind.value)).fetchone()
        thread = OutreachThread.from_row(row) if row else None  # type: ignore[assignment]
        if thread is not None and thread.state is ThreadState.ACTIVE:
            raise OutreachError(ErrorCode.CONFLICT, "an email in this conversation already went out; follow-ups are drafted automatically",
                                {"thread_id": thread.id})
        if thread is None:
            thread = threads.create_thread(self.conn, kind=kind, company_id=company_id, contact_id=contact_id, job_id=job_id,
                                           application_id=application_id)
        elif thread.contact_id != contact_id:
            threads.update_thread(self.conn, thread.id, contact_id=contact_id)
            thread = threads.get_thread(self.conn, thread.id)
        await self._emit_all(threads.cancel_pending(self.conn, thread.id, "re-drafted", actor=Actor.USER), "outreach_state")
        dkind = self._first_kind(kind)
        ctx = self._context(thread, dkind, contact_id=contact_id, instructions=instructions)
        d = await drafts.generate(self.llm, ctx)
        footer = drafts.footer(contacts.best_email_source_label(self.conn, contact))
        msg = threads.insert_draft(
            self.conn, thread_id=thread.id, kind=dkind, to_email=contact.email_norm, subject=d.subject, body=d.body, footer=footer,
            grounded=d.grounded, unsupported=d.unsupported_claims, story_ids=d.story_ids, tokens_in=d.tokens_in,
            tokens_out=d.tokens_out, seq=0,
        )
        db.log_event(self.conn, "outreach", f"drafted an email to {contact.full_name}" + ("" if d.grounded else " (needs your check)"),
                     job_id=job_id, application_id=application_id, payload={"thread_id": thread.id, "message_id": msg.id})
        from autoapply.models import OutreachStatePayload

        await self.emit("outreach_state", OutreachStatePayload(thread_id=thread.id, message_id=msg.id, entity="message",
                                                               from_state=None, to_state=MessageState.DRAFT.value, at=now_ts()))
        return {"thread_id": thread.id, "message_id": msg.id, "grounded": d.grounded, "unsupported_claims": d.unsupported_claims}

    def edit_draft(self, message_id: int, subject: str | None, body: str, confirm_claims: bool) -> dict[str, Any]:
        msg = threads.get_message(self.conn, message_id)
        if msg.direction != "out" or msg.state is not MessageState.DRAFT:
            raise OutreachError(ErrorCode.CONFLICT, f"only drafts can be edited (this one is {msg.state.value}); cancel it first")
        thread = threads.get_thread(self.conn, msg.thread_id)
        if subject is not None and msg.seq == 0 and not drafts.subject_ok(subject):
            raise ValueError("subject: at most 8 words, and never starting with Re: or Fwd:")
        previous = None
        if msg.seq > 0:
            sent = threads.sent_messages(self.conn, thread.id)
            previous = sent[-1] if sent else None
        ctx = self._context(thread, msg.kind or self._first_kind(thread.kind), previous=previous)
        unsupported = drafts.check(body, ctx)
        fields = {
            "body": body.strip(), "origin": "user", "grounded": int(not unsupported), "unsupported_claims": db._j(unsupported),
            "claims_overridden": int(bool(unsupported) and confirm_claims), "updated_at": now_ts(),
        }
        if subject is not None and msg.seq == 0:
            fields["subject"] = subject.strip()
        with db.transaction(self.conn):
            sql, params = db._update_sql("outreach_messages", fields, "id = ?")
            self.conn.execute(sql, [*params, message_id])
            if "subject" in fields:
                threads.update_thread(self.conn, thread.id, subject=fields["subject"])
            if confirm_claims and unsupported:
                db.log_event(self.conn, "outreach", "you confirmed claims the fact check could not find: " + "; ".join(unsupported)[:300],
                             actor=Actor.USER, payload={"thread_id": thread.id, "message_id": message_id})
        return {"grounded": not unsupported, "unsupported_claims": unsupported}

    # =================================================================================
    # Approval and scheduling
    # =================================================================================

    async def approve(self, message_ids: list[int], include_followups: bool, send_anyway: list[int]) -> dict[str, Any]:
        """The ONLY way an email gets on its way: schedule the user's approved drafts."""
        if (why := self.send_blocker()) is not None:
            raise OutreachError(ErrorCode.UNAVAILABLE, why)
        prefs = db.get_preferences(self.conn)
        ids = list(dict.fromkeys(message_ids))
        msgs = [threads.get_message(self.conn, i) for i in ids]
        problems: dict[str, Any] = {}
        items: list[sender.PlanItem] = []
        for m in msgs:
            if m.direction != "out" or m.state is not MessageState.DRAFT:
                raise OutreachError(ErrorCode.ILLEGAL_TRANSITION, f"message {m.id} is {m.state.value}, not a draft",
                                    {"message_id": m.id, "state": m.state.value})
            if not m.grounded and not m.claims_overridden:
                problems.setdefault("ungrounded", []).append(m.id)
                continue
            if not m.to_email or suppression.check(self.conn, m.to_email) is not None:
                problems.setdefault("do_not_contact", []).append(m.id)
                continue
            t = threads.get_thread(self.conn, m.thread_id)
            if t.state not in (ThreadState.DRAFT, ThreadState.ACTIVE):
                problems.setdefault("thread_closed", []).append(m.id)
                continue
            if t.contact_id is not None and m.seq == 0 and m.id not in send_anyway:
                c = contacts.get_contact(self.conn, t.contact_id)
                if c.email_confidence < prefs.outreach_min_email_confidence:
                    problems.setdefault("low_confidence", []).append(m.id)
                    continue
            earliest = None
            if t.application_id is not None and m.seq == 0:
                app = db.get_application(self.conn, t.application_id)
                if app.submitted_at is not None:
                    earliest = sender.add_business_days(app.submitted_at, sender.APPLICATION_DELAY_BUSINESS_DAYS)
            items.append(sender.PlanItem(m.id, suppression.email_domain(m.to_email) or "", m.seq == 0, earliest))
        if problems:
            parts = []
            if "ungrounded" in problems:
                parts.append("some drafts have claims the fact check could not find (edit them, or confirm they are true)")
            if "low_confidence" in problems:
                parts.append("some addresses are below your confidence bar (use 'Send anyway' for each)")
            if "do_not_contact" in problems:
                parts.append("some recipients are on the do-not-contact list")
            if "thread_closed" in problems:
                parts.append("some conversations are already closed")
            raise OutreachError(ErrorCode.CONFLICT, "; ".join(parts), problems)
        now = self.now()
        tz = now.astimezone().tzinfo
        times = sender.plan_send_times(
            items, now=now, window=prefs.outreach_send_window, weekdays_only=prefs.outreach_weekdays_only,
            new_limit=lambda d: sender.ramp_limit(self.conn, prefs, d), total_cap=sender.total_limit(prefs.outreach_daily_cap),
            load=lambda d: sender.day_load(self.conn, d, tz), rng=self.rng,
        )
        batch = new_id()
        scheduled: list[dict[str, Any]] = []
        changes: list[db.OutreachTransition] = []
        with db.transaction(self.conn):
            for m in msgs:
                at = times[m.id]
                changes.append(db.transition_outreach(self.conn, m.id, MessageState.APPROVED, actor=Actor.USER,
                                                      fields={"batch_uid": batch, "approved_at": now_ts()}))
                changes.append(db.transition_outreach(self.conn, m.id, MessageState.SCHEDULED, actor=Actor.USER,
                                                      fields={"send_at": format_ts(at)}))
                scheduled.append({"message_id": m.id, "send_at": format_ts(at)})
                if include_followups and m.seq == 0:
                    threads.update_thread(self.conn, m.thread_id, followup_approved=1)
        for t in changes:
            await self.emit("outreach_state", t.to_payload())
        days: dict[str, int] = {}
        for s in scheduled:
            d = parse_ts(s["send_at"]).astimezone().date().isoformat()
            days[d] = days.get(d, 0) + 1
        db.log_event(self.conn, "user", f"approved {len(scheduled)} email(s) to send", actor=Actor.USER,
                     payload={"batch_uid": batch, "days": days})
        return {"batch_uid": batch, "scheduled": scheduled, "days": [{"date": k, "count": v} for k, v in sorted(days.items())]}

    async def cancel(self, message_ids: list[int]) -> dict[str, Any]:
        n = 0
        for mid in dict.fromkeys(message_ids):
            m = threads.get_message(self.conn, mid)
            if m.state in (MessageState.APPROVED, MessageState.SCHEDULED):
                t = db.transition_outreach(self.conn, mid, MessageState.DRAFT, reason="cancelled by you", actor=Actor.USER,
                                           fields={"send_at": None, "batch_uid": None, "approved_at": None})
                await self.emit("outreach_state", t.to_payload())
                n += 1
        return {"cancelled": n}

    async def discard(self, thread_id: int) -> None:
        t = threads.get_thread(self.conn, thread_id)
        if threads.sent_messages(self.conn, thread_id):
            raise OutreachError(ErrorCode.CONFLICT, "an email in this conversation already went out; close it instead")
        await self._emit_all(threads.cancel_pending(self.conn, thread_id, "discarded", actor=Actor.USER), "outreach_state")
        if t.state is not ThreadState.CANCELLED:
            p = threads.set_thread_state(self.conn, thread_id, ThreadState.CANCELLED, reason="discarded", actor=Actor.USER)
            if p:
                await self.emit("outreach_state", p)

    async def resolve_unknown(self, message_id: int, sent: bool) -> None:
        m = threads.get_message(self.conn, message_id)
        if m.state is not MessageState.UNKNOWN:
            raise OutreachError(ErrorCode.ILLEGAL_TRANSITION, f"message {message_id} is {m.state.value}, not unknown")
        if sent:
            t = db.transition_outreach(self.conn, message_id, MessageState.SENT, reason="you checked Sent Mail", actor=Actor.USER,
                                       fields={"sent_at": format_ts(m.updated_at)})
            await self.emit("outreach_state", t.to_payload())
            await self._on_sent(threads.get_message(self.conn, message_id), threads.get_thread(self.conn, m.thread_id))
        else:
            t = db.transition_outreach(self.conn, message_id, MessageState.FAILED, reason="not sent (you checked)", actor=Actor.USER)
            await self.emit("outreach_state", t.to_payload())

    def mark_reply_read(self, thread_id: int) -> None:
        threads.get_thread(self.conn, thread_id)
        threads.update_thread(self.conn, thread_id, unread_reply=0)

    async def set_outcome(self, thread_id: int, outcome: ThreadOutcome | None, close: bool) -> None:
        t = threads.get_thread(self.conn, thread_id)
        if outcome is not None:
            threads.update_thread(self.conn, thread_id, outcome=outcome.value)
        if close:
            await self._emit_all(threads.cancel_pending(self.conn, thread_id, "closed by you", actor=Actor.USER), "outreach_state")
            p = threads.set_thread_state(self.conn, thread_id, ThreadState.CLOSED, reason="closed by you", actor=Actor.USER,
                                         unread_reply=0)
            if p:
                await self.emit("outreach_state", p)
            if t.kind is OutreachKind.PROSPECT and t.state is ThreadState.ACTIVE:
                prospects.start_cooldown(self.conn, t.company_id, self.now())

    async def suppress(self, email: str | None, domain: str | None, reason: SuppressionReason) -> None:
        s = suppression.add(self.conn, email=email, domain=domain, reason=reason, source="you")
        await self._cancel_for_suppressed(s.email_norm, s.domain, f"do-not-contact ({reason.value})")

    async def _cancel_for_suppressed(self, email_norm: str | None, domain: str | None, why: str) -> None:
        rows = self.conn.execute("SELECT id, to_email FROM outreach_messages WHERE direction = 'out' "
                                 "AND state IN ('draft','approved','scheduled')").fetchall()
        for r in rows:
            e = (r["to_email"] or "").lower()
            if (email_norm and e == email_norm) or (domain and (e.endswith("@" + domain) or e.endswith("." + domain))):
                t = db.transition_outreach(self.conn, int(r["id"]), MessageState.CANCELLED, reason=why)
                await self.emit("outreach_state", t.to_payload())

    def unsuppress(self, email: str | None, domain: str | None) -> None:
        try:
            if not suppression.remove(self.conn, email=email, domain=domain):
                raise db.NotFound("not on the do-not-contact list")
        except suppression.SuppressionLocked as e:
            raise OutreachError(ErrorCode.CONFLICT, str(e), {"reason": "opt_out"}) from e

    # =================================================================================
    # Prospects
    # =================================================================================

    def search_prospects(self, query: str, location: str | None) -> dict[str, Any]:
        sid = prospects.queue_search(self.conn, query, location)
        db.log_event(self.conn, "user", f"company search queued: {query}" + (f" ({location})" if location else ""), actor=Actor.USER)
        return {"search_id": sid}

    async def add_prospect(self, company_name: str | None, url: str | None) -> dict[str, Any]:
        domain = domains.domain_from_url(url) if url else None
        name = (company_name or "").strip()
        if not name and domain:
            name = domain.split(".")[0].capitalize()
        if not name:
            raise ValueError("give a company name or its website")
        company = db.upsert_company(self.conn, name, domain=domain)
        p = prospects.upsert(self.conn, company.id, status=ProspectStatus.SHORTLISTED, found_via="user")
        assert p is not None
        self.spawn(self._enrich_and_scout(company.id, url), f"outreach-prospect-{company.id}")
        return {"prospect_id": p.id, "company_id": company.id}

    async def _enrich_and_scout(self, company_id: int, url: str | None) -> None:
        try:
            company = db.get_company(self.conn, company_id)
            prefs = db.get_preferences(self.conn)
            async with self.http_factory() as http:
                en = await prospects.enrich(http, url=url or (f"https://{company.domain}" if company.domain else None), prefs=prefs)
            fit, reasons = await prospects.prospect_fit(self.llm, company=company.name, summary=en.summary,
                                                         matching_roles=en.matching_roles, profile=db.get_profile(self.conn), prefs=prefs)
            prospects.upsert(self.conn, company_id, summary=en.summary, summary_url=en.summary_url, matching_roles=en.matching_roles,
                             fit_score=fit, fit_reasons=reasons)
        except Exception:  # noqa: BLE001
            log.exception("prospect enrichment failed for %s", company_id)
        await self.scout_and_draft(company_id, ScoutPurpose.PROSPECT, force=True)

    async def update_prospect(self, prospect_id: int, status: ProspectStatus | None, watch: bool) -> None:
        p = prospects.get(self.conn, prospect_id)
        company = db.get_company(self.conn, p.company_id)
        if status is not None and status is not p.status:
            prospects.set_status(self.conn, prospect_id, status)
            if status is ProspectStatus.SHORTLISTED:
                self.spawn(self.scout_and_draft(company.id, ScoutPurpose.PROSPECT, force=not recently_scouted(self.conn, company.id)),
                           f"outreach-scout-{company.id}")
        if watch:
            from autoapply.discovery.base import detect_ats

            ats, token = detect_ats(company.careers_url)
            if company.ats is None and token and ats.value in ("greenhouse", "lever", "ashby"):
                db.upsert_company(self.conn, company.name, ats=ats, board_token=token, watch=True)
            else:
                db.upsert_company(self.conn, company.name, watch=True,
                                  careers_url=company.careers_url or (f"https://{company.domain}/careers" if company.domain else None))
            db.log_event(self.conn, "user", f"added {company.name} to the watched companies", actor=Actor.USER)

    # =================================================================================
    # Referrals
    # =================================================================================

    def suggest_referrers(self, company_id: int, job_id: int | None) -> dict[str, Any]:
        db.get_company(self.conn, company_id)
        items = [i for i in (db.get_meta(self.conn, META_REFERRER_QUEUE, []) or []) if i.get("company_id") != company_id]
        items.append({"company_id": company_id, "job_id": job_id, "queued_at": now_ts()})
        db.set_meta(self.conn, META_REFERRER_QUEUE, items[-30:])
        return {"queued_google": True}

    def add_referral(self, p: Any) -> dict[str, Any]:
        contact = contacts.get_contact(self.conn, p.contact_id) if p.contact_id is not None else None
        company_id = p.company_id or (contact.company_id if contact else None)
        if company_id is None:
            raise ValueError("give company_id (or a contact with a company)")
        name = p.person_name or (contact.full_name if contact else None)
        if not name:
            raise ValueError("give person_name or contact_id")
        r, created = referrals.add(
            self.conn, company_id=company_id, person_name=name, basis=p.basis, job_id=p.job_id, contact_id=p.contact_id,
            title=p.title or (contact.title if contact else None), linkedin_url=p.linkedin_url or (contact.linkedin_url if contact else None),
            basis_detail=p.basis_detail, state=ReferralState.TO_CONNECT,
        )
        return {"referral_id": r.id, "created": created}

    async def draft_referral(self, referral_id: int, instructions: str | None) -> dict[str, Any]:
        if self.llm is None:
            raise OutreachError(ErrorCode.UNAVAILABLE, "no model available to draft with")
        r = referrals.get(self.conn, referral_id)
        profile = db.get_profile(self.conn)
        company = db.get_company(self.conn, r.company_id)
        job = db.get_job(self.conn, r.job_id) if r.job_id is not None else None
        base = dict(profile=profile, stories=db.list_stories(self.conn), company=company, recipient_name=r.person_name,
                    recipient_title=r.title, job=job, referral_basis=referrals.basis_sentence(r, profile),
                    has_referral=False, instructions=instructions, voice=voice.load_profile(self.conn))
        note = await drafts.generate_connect_note(self.llm, drafts.DraftContext(kind=DraftKind.LINKEDIN_CONNECT_NOTE, **base))
        dm = await drafts.generate(self.llm, drafts.DraftContext(kind=DraftKind.LINKEDIN_REFERRAL_DM, **base))
        unsupported = list(dict.fromkeys([*note.unsupported_claims, *dm.unsupported_claims]))
        referrals.update_texts(self.conn, referral_id, connect_note=note.body, referral_dm=dm.body, grounded=not unsupported,
                               unsupported=unsupported)
        return {"connect_note": note.body, "referral_dm": dm.body, "grounded": not unsupported, "unsupported_claims": unsupported}

    def update_referral(self, referral_id: int, state: ReferralState | None, connect_note: str | None, referral_dm: str | None) -> None:
        r = referrals.get(self.conn, referral_id)
        if connect_note is not None or referral_dm is not None:
            if connect_note is not None and len(connect_note) > drafts.CONNECT_NOTE_CHARS:
                raise ValueError(f"a connection note is at most {drafts.CONNECT_NOTE_CHARS} characters")
            referrals.update_texts(self.conn, referral_id, connect_note=connect_note, referral_dm=referral_dm)
        if state is not None and state is not r.state:
            try:
                referrals.transition(self.conn, referral_id, state, reason="by you", actor="user")
            except referrals.IllegalReferralTransition as e:
                raise OutreachError(ErrorCode.ILLEGAL_TRANSITION, str(e)) from e
            if state is ReferralState.REFERRED and r.job_id is not None:
                try:
                    app = db.get_application_by_job(self.conn, r.job_id)
                    note = f"Referred by {r.person_name}."
                    db.update_application(self.conn, app.id, notes=((app.notes or "") + "\n" + note).strip())
                except db.NotFound:
                    pass

    # =================================================================================
    # Provider keys
    # =================================================================================

    async def set_provider_key(self, provider: str, api_key: str | None) -> dict[str, Any]:
        from autoapply.outreach.providers import base

        if not api_key:
            await asyncio.to_thread(base.keychain_delete, provider)
            db.log_event(self.conn, "user", f"removed the {provider} key", actor=Actor.USER)
            return {"provider": provider, "ok": False}
        key = api_key.strip()
        ok = False
        async with self.http_factory() as http:
            if provider == "hunter":
                from autoapply.outreach.providers.hunter import HunterProvider

                ok = await HunterProvider(key, http).check_key()
            else:
                try:
                    r = await http.get("https://api.github.com/user", headers={"Authorization": f"Bearer {key}",
                                                                                "Accept": "application/vnd.github+json"})
                    ok = r.status_code == 200
                except httpx.HTTPError:
                    ok = False
        if not ok:
            raise OutreachError(ErrorCode.UNAVAILABLE, f"{provider} did not accept that key")
        try:
            await asyncio.to_thread(base.keychain_set, provider, key)
        except base.ProviderError as e:
            raise OutreachError(ErrorCode.UNAVAILABLE, str(e)) from e
        db.log_event(self.conn, "user", f"saved a {provider} key", actor=Actor.USER)
        return {"provider": provider, "ok": True}

    # =================================================================================
    # Loops
    # =================================================================================

    async def tick(self) -> None:
        """Every 60 s: send one due email; watch the mailbox every 10 minutes."""
        try:
            await self.sender.tick()
        except Exception:  # noqa: BLE001
            log.exception("outreach sender tick failed")
        now = self.now()
        if self._last_scan is None or (now - self._last_scan).total_seconds() >= MAIL_SCAN_EVERY_S:
            self._last_scan = now
            try:
                await self.scan_mail()
                await self.verify_unknown()
            except Exception:  # noqa: BLE001
                log.exception("outreach mail watch failed")

    async def scan_mail(self) -> mailwatch.ApplyReport | None:
        """One mail-watch pass: IMAP reads in a worker thread, then classification and DB writes here."""
        spec = mailwatch.build_spec(self.conn, self.now())
        acc = self.account()
        if spec is None or acc is None:
            return None
        password = await asyncio.to_thread(self.mail_password, acc.email)
        if not password:
            return None

        def work() -> mailwatch.Collected:
            mb = self._mailbox(acc.email, password)
            try:
                return mailwatch.collect(mb, spec)
            finally:
                mb.close()

        got = await asyncio.to_thread(work)
        rep = await mailwatch.apply(self.conn, got, self.llm)
        await self._emit_all(rep.events)
        for title, message in rep.notifications:
            await self._notify(title, message)
        return rep

    def _mailbox(self, address: str, password: str) -> Any:
        """Read-only mailbox (blocking login: call from a worker thread)."""
        from autoapply.mail.common import ImapMailbox

        factory = self.mailbox_factory or ImapMailbox
        return factory(address, password)

    async def verify_unknown(self) -> int:
        """Sent Mail check for ``unknown`` messages: found -> ``sent``; otherwise they stay for the user."""
        async with self._verify_lock:  # start-up recovery and the tick may both ask
            return await self._verify_unknown()

    async def _verify_unknown(self) -> int:
        rows = self.conn.execute("SELECT id, message_id_header FROM outreach_messages WHERE state = 'unknown' "
                                 "AND message_id_header IS NOT NULL").fetchall()
        acc = self.account()
        if not rows or acc is None:
            return 0
        password = await asyncio.to_thread(self.mail_password, acc.email)
        if not password:
            return 0
        mids = [(int(r["id"]), str(r["message_id_header"])) for r in rows]

        def work() -> list[int]:
            mb = self._mailbox(acc.email, password)
            try:
                return [i for i, mid in mids if mailwatch.find_in_sent(mb, mid)]
            finally:
                mb.close()

        found = await asyncio.to_thread(work)
        resolved = 0
        for mid in found:
            m = threads.get_message(self.conn, mid)
            if m.state is not MessageState.UNKNOWN:
                continue  # the user resolved it meanwhile
            resolved += 1
            t = db.transition_outreach(self.conn, mid, MessageState.SENT, reason="found in Sent Mail",
                                       fields={"sent_at": format_ts(m.updated_at)})
            await self.emit("outreach_state", t.to_payload())
            await self._on_sent(threads.get_message(self.conn, mid), threads.get_thread(self.conn, m.thread_id))
        return resolved

    async def _notify(self, title: str, message: str) -> None:
        if self.notifier is not None:
            try:
                await self.notifier.notify(title, message)
            except Exception:  # noqa: BLE001
                log.debug("notify failed", exc_info=True)

    # ---- hourly maintenance --------------------------------------------------------------

    async def maintenance(self, now: datetime | None = None) -> None:
        now = now or self.now()
        steps = (self._cancel_for_closed_applications, self._create_followups, self._referral_reminders, self._mark_delivered,
                 self._daily)
        for step in steps:
            try:
                await step(now)
            except Exception:  # noqa: BLE001
                log.exception("outreach maintenance step %s failed", step.__name__)

    async def _cancel_for_closed_applications(self, now: datetime) -> None:
        rows = self.conn.execute(
            "SELECT t.id FROM outreach_threads t JOIN applications a ON a.id = t.application_id "
            "WHERE t.state IN ('draft','active') AND a.status IN ('rejected','offer')").fetchall()
        for r in rows:
            await self._emit_all(threads.cancel_pending(self.conn, int(r["id"]), "application closed", followups_only=True),
                                 "outreach_state")

    async def _create_followups(self, now: datetime) -> int:
        prefs = db.get_preferences(self.conn)
        if prefs.outreach_max_followups <= 0 or self.llm is None or self.is_paused():
            return 0
        made = 0
        for row in self.conn.execute("SELECT * FROM outreach_threads WHERE state = 'active'").fetchall():
            t: OutreachThread = OutreachThread.from_row(row)  # type: ignore[assignment]
            sent = threads.sent_messages(self.conn, t.id)
            if not sent or len(sent) - 1 >= prefs.outreach_max_followups:
                continue
            pending = [m for m in threads.messages(self.conn, t.id, direction="out")
                       if m.state in (MessageState.DRAFT, MessageState.APPROVED, MessageState.SCHEDULED, MessageState.SENDING,
                                      MessageState.UNKNOWN)]
            if pending:
                continue
            last = sent[-1]
            due = sender.add_business_days(last.sent_at or now, prefs.outreach_followup_days)
            if t.next_action_at is not None and t.next_action_at > due:
                due = t.next_action_at
            if due > now or not last.to_email or suppression.check(self.conn, last.to_email) is not None:
                continue
            if t.application_id is not None:
                st = self.conn.execute("SELECT status FROM applications WHERE id = ?", (t.application_id,)).fetchone()
                if st and st["status"] in ("rejected", "offer"):
                    continue
            ctx = self._context(t, DraftKind.FOLLOWUP, previous=sent[0])
            d = await drafts.generate(self.llm, ctx)
            msg = threads.insert_draft(
                self.conn, thread_id=t.id, kind=DraftKind.FOLLOWUP, to_email=last.to_email, subject=d.subject, body=d.body,
                footer=last.footer, grounded=d.grounded, unsupported=d.unsupported_claims, story_ids=d.story_ids,
                tokens_in=d.tokens_in, tokens_out=d.tokens_out, in_reply_to=last.message_id_header,
            )
            made += 1
            if t.followup_approved and d.grounded and self.send_blocker() is None:
                tz = now.astimezone().tzinfo
                times = sender.plan_send_times(
                    [sender.PlanItem(msg.id, suppression.email_domain(msg.to_email) or "", False)], now=now,
                    window=prefs.outreach_send_window, weekdays_only=prefs.outreach_weekdays_only,
                    new_limit=lambda d_: sender.ramp_limit(self.conn, prefs, d_), total_cap=sender.total_limit(prefs.outreach_daily_cap),
                    load=lambda d_: sender.day_load(self.conn, d_, tz), rng=self.rng)
                for to, fields in ((MessageState.APPROVED, {"approved_at": now_ts(), "batch_uid": "followup"}),
                                   (MessageState.SCHEDULED, {"send_at": format_ts(times[msg.id])})):
                    tr = db.transition_outreach(self.conn, msg.id, to, reason="follow-up approved with the first email", fields=fields)
                    await self.emit("outreach_state", tr.to_payload())
            else:
                from autoapply.models import OutreachStatePayload

                await self.emit("outreach_state", OutreachStatePayload(thread_id=t.id, message_id=msg.id, entity="message",
                                                                       to_state=MessageState.DRAFT.value, reason="follow-up", at=now_ts()))
        return made

    async def _referral_reminders(self, now: datetime) -> None:
        to_ask, _stale = referrals.due_reminders(self.conn, now)
        key = "outreach_referral_reminded"
        reminded = set(db.get_meta(self.conn, key, []) or [])
        for r in to_ask:
            if r.id in reminded:
                continue
            reminded.add(r.id)
            await self._notify(f"Ask {r.person_name.split()[0]} for a referral", f"You've been connected for {referrals.ASK_AFTER_DAYS}+ days.")
        db.set_meta(self.conn, key, sorted(reminded)[-500:])

    async def _mark_delivered(self, now: datetime) -> None:
        cutoff = format_ts(now - timedelta(hours=DELIVERED_AFTER_H))
        rows = self.conn.execute(
            "SELECT DISTINCT t.contact_id FROM outreach_messages m JOIN outreach_threads t ON t.id = m.thread_id "
            "JOIN contacts c ON c.id = t.contact_id WHERE m.direction = 'out' AND m.state = 'sent' AND m.sent_at < ? "
            "AND t.state NOT IN ('bounced') AND c.email_status IN ('pattern','published','provider_verified') "
            "AND lower(c.email_norm) = lower(m.to_email)", (cutoff,)).fetchall()
        for r in rows:
            contacts.set_email_status(self.conn, int(r[0]), EmailStatus.DELIVERED)

    async def _daily(self, now: datetime) -> None:
        today = now.astimezone().date().isoformat()
        if db.get_meta(self.conn, META_DAILY_DONE, None) == today:
            return
        db.set_meta(self.conn, META_DAILY_DONE, today)
        purged = contacts.purge_expired(self.conn, now)
        if any(purged):
            log.info("outreach retention: deleted %d contact(s), %d thread(s)", *purged)
        prospects.seed_from_watchlist(self.conn, now)
        n = db.compute_counts(self.conn, now).outreach_drafts
        if n and db.get_meta(self.conn, META_DRAFTS_NOTIFIED, None) != today:
            db.set_meta(self.conn, META_DRAFTS_NOTIFIED, today)
            await self._notify(f"{n} email draft(s) ready to review", "Cold Email ▸ Outbox")

    # ---- Google work (agent Chrome) ----------------------------------------------------------

    def has_google_work(self) -> bool:
        return bool(google_queue(self.conn) or db.get_meta(self.conn, META_REFERRER_QUEUE, []) or prospects.pending_searches(self.conn))

    async def run_google_work(self) -> dict[str, int]:
        """Queued scouts, referrer searches and company searches that need Google. The caller
        holds the browser (the pipeline's ``browser_lock``)."""
        done = {"scouts": 0, "referrers": 0, "searches": 0}
        if self.is_paused() or not self.has_google_work() or self._google_lock.locked():
            return done
        async with self._google_lock:
            prefs = db.get_preferences(self.conn)
            people = google_people.GoogleReader(self.conn, self.browser_factory(), budget_key=google_people.PEOPLE_KEY,
                                                limit=lambda: db.get_preferences(self.conn).people_finder_visits_per_day,
                                                pacer=self.pacer, is_paused=self.is_paused)
            try:
                for item in google_queue(self.conn):
                    if not people.available():
                        break
                    purpose = ScoutPurpose(item.get("purpose") or "application")
                    try:
                        await self.scout.scout_google(int(item["company_id"]), purpose, people, job_id=item.get("job_id"))
                    except google_people.NavigationRefused:
                        raise
                    except db.NotFound:
                        pop_google(self.conn, int(item["company_id"]), purpose.value)
                        continue
                    done["scouts"] += 1
                    if purpose is ScoutPurpose.APPLICATION and item.get("application_id"):
                        await self._auto_draft(int(item["company_id"]), int(item["application_id"]))
                for item in list(db.get_meta(self.conn, META_REFERRER_QUEUE, []) or []):
                    if not people.available():
                        break
                    await self._find_referrers(int(item["company_id"]), item.get("job_id"), people)
                    rest = [i for i in (db.get_meta(self.conn, META_REFERRER_QUEUE, []) or []) if i.get("company_id") != item["company_id"]]
                    db.set_meta(self.conn, META_REFERRER_QUEUE, rest)
                    done["referrers"] += 1
            finally:
                await people.close()
            searches = prospects.pending_searches(self.conn)
            if searches:
                reader = google_people.GoogleReader(self.conn, self.browser_factory(), budget_key=google_people.PROSPECT_KEY,
                                                    limit=lambda: google_people.PROSPECT_VISITS_PER_DAY, pacer=self.pacer,
                                                    is_paused=self.is_paused)
                try:
                    for s in searches:
                        if not reader.available():
                            break
                        found = await self._run_search(s, reader, prefs)
                        prospects.finish_search(self.conn, s["id"], "done", found)
                        done["searches"] += 1
                finally:
                    await reader.close()
        return done

    async def _find_referrers(self, company_id: int, job_id: int | None, reader: google_people.GoogleReader) -> int:
        company = db.get_company(self.conn, company_id)
        profile = db.get_profile(self.conn)
        prefs = db.get_preferences(self.conn)
        job = db.get_job(self.conn, job_id) if job_id else None
        function = (job.title if job else (prefs.roles[0] if prefs.roles else None))
        city = (prefs.locations[0].split(",")[0] if prefs.locations else None)
        cands: list[referrals.Candidate] = []
        for q in referrals.referrer_queries(profile, company.name, function=function, city=city):
            hits = await reader.read(q.query)
            if hits is None:
                break
            cands += referrals.candidates_from_results(hits, q, company.name)
        cands.sort(key=lambda c: c.rank)
        n = 0
        for c in cands[:10]:
            _r, created = referrals.add(self.conn, company_id=company_id, person_name=c.name, basis=c.basis, job_id=job_id,
                                        title=c.title, linkedin_url=c.linkedin_url, basis_detail=c.detail,
                                        evidence_url=c.linkedin_url, evidence_snippet=c.snippet)
            n += int(created)
        db.log_event(self.conn, "outreach", f"found {n} possible referrer(s) at {company.name}", payload={"company_id": company_id})
        return n

    async def _run_search(self, s: dict[str, Any], reader: google_people.GoogleReader, prefs: Any) -> int:
        from autoapply.outreach.sources.extract import page_text

        queries = await prospects.prospect_queries(self.llm, s["query"], s.get("location"), prefs)
        found: dict[str, prospects.FoundCompany] = {}
        async with self.http_factory() as http:
            for q in queries:
                hits = await reader.read(q)
                if hits is None:
                    break
                for h in hits[: prospects.MAX_RESULT_PAGES_PER_QUERY]:
                    if google_people.is_linkedin_profile(h.url) or any(b in h.url for b in google_people.NEVER_OPEN):
                        continue
                    try:
                        r = await http.get(h.url, headers={"User-Agent": domains.USER_AGENT}, follow_redirects=True, timeout=15)
                    except httpx.HTTPError:
                        continue
                    if r.status_code >= 400 or "html" not in r.headers.get("content-type", "html"):
                        continue
                    if self.llm is None:
                        continue
                    for fc in await prospects.extract_companies(self.llm, page_text(r.text), str(r.url)):
                        found.setdefault(fc.name.lower(), fc)
                    if len(found) >= prospects.MAX_COMPANIES_PER_SEARCH:
                        break
            n = 0
            for fc in list(found.values())[: prospects.MAX_COMPANIES_PER_SEARCH]:
                if prospects.excluded(prefs, fc.name) or db.company_dismissed(self.conn, fc.name):
                    continue
                en = await prospects.enrich(http, url=fc.url, prefs=prefs)
                company = db.upsert_company(self.conn, fc.name, domain=en.domain)
                existing = prospects.get_by_company(self.conn, company.id)
                if existing is not None and existing.status is ProspectStatus.DISMISSED:
                    continue
                fit, reasons = await prospects.prospect_fit(self.llm, company=fc.name, summary=en.summary or fc.evidence,
                                                             matching_roles=en.matching_roles, profile=db.get_profile(self.conn), prefs=prefs)
                if fc.evidence:
                    reasons = {**reasons, "evidence": fc.evidence, "evidence_url": fc.source_url}
                if prospects.upsert(self.conn, company.id, fit_score=fit, fit_reasons=reasons, summary=en.summary,
                                    summary_url=en.summary_url, matching_roles=en.matching_roles, found_via="search",
                                    search_query=s["query"]) is not None:
                    n += 1
        db.log_event(self.conn, "outreach", f"company search '{s['query']}': {n} prospect(s)", payload={"search_id": s["id"]})
        return n


__all__ = ["AUTO_ENABLED", "OutreachError", "OutreachService"]
