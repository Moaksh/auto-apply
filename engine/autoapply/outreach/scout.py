"""The contact scout (plan §B.1): deterministic code that calls small sources in order, stops
early once it has enough, and writes ``contacts`` / ``contact_evidence`` / ``domain_patterns``.
It is not a free-roaming browser agent.

``scout_http`` (no browser; runs any time, also during a run):

1. resolve the company domain (§B.2) and check its MX (no MX: no email addresses);
2. contact lines in the job posting;
3. the company's own pages;
4. its GitHub org (skipped when 2-3 already gave enough usable contacts);
5. the domain pattern from all evidence, then pattern-guessed addresses for named people;
6. the user's Hunter key, only when nothing usable was found and credits are left;
7. role fit for new contacts (one model call).

``scout_google`` (needs the agent Chrome, so only when the browser is free or as the last
step of a full run): Google result pages for recruiters / managers (LinkedIn result titles
only, never the profiles) and ``"@domain"`` email samples; and the official-site query when the
domain is still unknown.
"""

from __future__ import annotations

import logging
import sqlite3
from collections.abc import Callable
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass, field
from typing import Any

import httpx

from autoapply import db
from autoapply.enums import ContactOrigin, EmailStatus, EvidenceKind, MxProvider, RoleCategory, ScoutPurpose
from autoapply.llm.provider import LLMProvider, TokenUsage
from autoapply.models import Company, Contact, Job, now_ts, parse_ts, utcnow
from autoapply.outreach import contacts, domains, patterns, suppression
from autoapply.outreach.contacts import NewEvidence
from autoapply.outreach.providers.base import EmailProvider, ProviderError
from autoapply.outreach.sources import github_org, google_people, posting, site_pages
from autoapply.outreach.sources.extract import Person

log = logging.getLogger("autoapply.outreach.scout")

#: A company scouted within this many days is not scouted again (its contacts are reused).
SCOUT_CACHE_DAYS = 30
META_SCOUTED = "outreach_scouted"  # {company_id: iso ts}
META_GOOGLE_QUEUE = "outreach_google_queue"  # [{company_id, purpose, job_id, application_id, queued_at}]
#: "Enough": this many contacts of a useful category with a usable address.
ENOUGH_CONTACTS = 3
#: Pattern-guessed addresses are made for at most this many named people per scout.
MAX_GUESSES = 8

FIT_SCHEMA = {
    "type": "object",
    "properties": {"items": {"type": "array", "items": {
        "type": "object", "properties": {"i": {"type": "integer"}, "role_fit": {"type": "integer", "minimum": 0, "maximum": 100}},
        "required": ["i", "role_fit"]}}},
    "required": ["items"],
}

HttpFactory = Callable[[], AbstractAsyncContextManager[httpx.AsyncClient]]


@dataclass(slots=True)
class ScoutReport:
    company_id: int
    purpose: ScoutPurpose
    domain: str | None = None
    mx: MxProvider | None = None
    contact_ids: list[int] = field(default_factory=list)
    queued_google: bool = False
    guesses: int = 0
    sources: list[str] = field(default_factory=list)
    usage: TokenUsage = field(default_factory=TokenUsage)

    def summary(self, conn: sqlite3.Connection) -> tuple[int, int, int | None]:
        """(found, with an address, best confidence) over the company's contacts."""
        rows = conn.execute("SELECT email_norm, email_confidence FROM contacts WHERE company_id = ?", (self.company_id,)).fetchall()
        with_email = [int(r["email_confidence"]) for r in rows if r["email_norm"]]
        return len(rows), len(with_email), (max(with_email) if with_email else None)


def recently_scouted(conn: sqlite3.Connection, company_id: int) -> bool:
    data = db.get_meta(conn, META_SCOUTED, {}) or {}
    ts = data.get(str(company_id))
    if not ts:
        return False
    return (utcnow() - parse_ts(ts)).days < SCOUT_CACHE_DAYS


def mark_scouted(conn: sqlite3.Connection, company_id: int) -> None:
    data = dict(db.get_meta(conn, META_SCOUTED, {}) or {})
    data[str(company_id)] = now_ts()
    db.set_meta(conn, META_SCOUTED, data)


def queue_google(conn: sqlite3.Connection, company_id: int, purpose: ScoutPurpose, *, job_id: int | None = None,
                 application_id: int | None = None) -> None:
    items = [i for i in (db.get_meta(conn, META_GOOGLE_QUEUE, []) or [])
             if not (i.get("company_id") == company_id and i.get("purpose") == purpose.value)]
    items.append({"company_id": company_id, "purpose": purpose.value, "job_id": job_id, "application_id": application_id,
                  "queued_at": now_ts()})
    db.set_meta(conn, META_GOOGLE_QUEUE, items[-50:])


def google_queue(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    return list(db.get_meta(conn, META_GOOGLE_QUEUE, []) or [])


def pop_google(conn: sqlite3.Connection, company_id: int, purpose: str) -> None:
    items = [i for i in google_queue(conn) if not (i.get("company_id") == company_id and i.get("purpose") == purpose)]
    db.set_meta(conn, META_GOOGLE_QUEUE, items)


class ContactScout:
    def __init__(
        self,
        conn: sqlite3.Connection,
        llm: LLMProvider | None,
        *,
        http_factory: HttpFactory,
        mx_resolver: domains.MxResolver,
        provider_factory: Callable[[httpx.AsyncClient], EmailProvider | None] | None = None,
        github_token: Callable[[], str | None] | None = None,
        is_paused: Callable[[], bool] | None = None,
    ) -> None:
        self.conn = conn
        self.llm = llm
        self.http_factory = http_factory
        self.mx_resolver = mx_resolver
        self.provider_factory = provider_factory
        self.github_token = github_token or (lambda: None)
        self.is_paused = is_paused or (lambda: False)

    # ---- helpers ---------------------------------------------------------------------------

    def _usable(self, company_id: int, purpose: ScoutPurpose) -> int:
        prefs = db.get_preferences(self.conn)
        useful = {c.value for c in contacts.PURPOSE_ORDER[purpose][:4]}
        return int(self.conn.execute(
            f"SELECT COUNT(*) FROM contacts WHERE company_id = ? AND email_norm IS NOT NULL AND email_confidence >= ? "
            f"AND role_category IN ({','.join('?' * len(useful))})",
            (company_id, prefs.outreach_min_email_confidence, *useful)).fetchone()[0])

    def _save(self, company: Company, p: Person, *, domain: str | None, mx_ok: bool, pattern: patterns.PatternInference | None,
              report: ScoutReport) -> Contact | None:
        ev: list[NewEvidence] = [NewEvidence(p.kind, "name", url=p.url, snippet=p.snippet)]
        if p.title:
            ev.append(NewEvidence(p.kind, "title", url=p.url, snippet=p.snippet))
        email, status, ambiguous = None, EmailStatus.NONE, False
        if p.email and mx_ok:
            email, status = p.email, EmailStatus.PUBLISHED
            ev.append(NewEvidence(p.kind, "email", url=p.url, snippet=p.snippet))
        elif domain and mx_ok and pattern is not None and report.guesses < MAX_GUESSES:
            guess, ambiguous = patterns.guess_email(p.name, domain, pattern.pattern)
            if guess and suppression.check(self.conn, guess) is None:
                report.guesses += 1
                email, status = guess, EmailStatus.PATTERN
                ev.append(NewEvidence(EvidenceKind.PATTERN, "email", snippet=(
                    f"pattern {pattern.pattern} ({pattern.supporting} confirming sample(s))" + ("; ambiguous name" if ambiguous else ""))))
        if email and suppression.check(self.conn, email) is not None:
            email, status = None, EmailStatus.NONE
            ev = [e for e in ev if e.field != "email"]
        res = contacts.upsert_contact(
            self.conn, company_id=company.id, full_name=p.name, origin=ContactOrigin.SCOUT, email=email, email_status=status,
            title=p.title, linkedin_url=p.linkedin_url, github_login=p.github_login, location=p.location, evidence=ev,
            ambiguous=ambiguous,
        )
        c = res.contact
        if c.role_category is RoleCategory.OTHER and p.kind is EvidenceKind.GITHUB and not c.title:
            with db.transaction(self.conn):
                self.conn.execute("UPDATE contacts SET role_category = 'engineer' WHERE id = ?", (c.id,))
        if c.id not in report.contact_ids:
            report.contact_ids.append(c.id)
        return c

    def _save_mailbox(self, company: Company, email: str, url: str, report: ScoutReport) -> None:
        if suppression.check(self.conn, email) is not None:
            return
        res = contacts.upsert_contact(
            self.conn, company_id=company.id, full_name=f"{company.name} {email.split('@')[0]} mailbox", origin=ContactOrigin.SCOUT,
            email=email, email_status=EmailStatus.PUBLISHED,
            evidence=[NewEvidence(EvidenceKind.COMPANY_PAGE, "email", url=url, snippet=f"{email} published on {url}")],
        )
        if res.contact.id not in report.contact_ids:
            report.contact_ids.append(res.contact.id)

    async def _role_fit(self, ids: list[int], job: Job | None, report: ScoutReport) -> None:
        todo = [contacts.get_contact(self.conn, i) for i in ids]
        todo = [c for c in todo if c.role_fit is None and c.title]
        if not todo:
            return
        default = {RoleCategory.RECRUITER: 70, RoleCategory.TALENT_LEAD: 65, RoleCategory.HIRING_MANAGER: 70,
                   RoleCategory.ENG_LEADER: 60, RoleCategory.ENGINEER: 45, RoleCategory.FOUNDER: 55}
        fits: dict[int, int] = {}
        if self.llm is not None:
            lines = "\n".join(f"{i}. {c.title}" + (f" ({c.location})" if c.location else "") for i, c in enumerate(todo))
            target = f"the role '{job.title}'" + (f" in {job.location}" if job and job.location else "") if job else "the user's target roles"
            try:
                res = await self.llm.complete(
                    f"Rate 0-100 how relevant each person is to contact about {target} (function, seniority, location).\n{lines}",
                    schema=FIT_SCHEMA, tier="fast", max_tokens=400)
                report.usage.add(res.usage)
                for it in (res.data or {}).get("items") or []:
                    i = int(it.get("i", -1))
                    if 0 <= i < len(todo):
                        fits[todo[i].id] = max(0, min(100, int(it.get("role_fit", 50))))
            except Exception as e:  # noqa: BLE001
                log.info("classify_title failed: %s", e)
        with db.transaction(self.conn):
            for c in todo:
                fit = fits.get(c.id, default.get(c.role_category, 40))
                # A title only seen in a Google snippet may be stale.
                serp_only = not self.conn.execute(
                    "SELECT 1 FROM contact_evidence WHERE contact_id = ? AND field = 'title' AND kind <> 'google_serp'", (c.id,)).fetchone()
                if serp_only and fit >= 15:
                    fit -= 15
                self.conn.execute("UPDATE contacts SET role_fit = ? WHERE id = ?", (fit, c.id))

    async def _provider(self, http: httpx.AsyncClient, company: Company, domain: str, report: ScoutReport) -> None:
        if self.provider_factory is None:
            return
        provider = self.provider_factory(http)
        if provider is None:
            return
        try:
            result = await provider.domain_search(domain)
        except ProviderError as e:
            log.info("provider %s: %s", getattr(provider, "name", "?"), e)
            return
        report.sources.append(getattr(provider, "name", "provider"))
        row = domains.get_pattern(self.conn, domain)
        if result.pattern and (row is None or row.confidence < 60):
            with db.transaction(self.conn):
                self.conn.execute("UPDATE domain_patterns SET pattern = ?, confidence = MAX(confidence, 60) WHERE domain = ?",
                                  (result.pattern, domain))
        for e in result.emails:
            name = " ".join(x for x in (e.first_name, e.last_name) if x)
            if not name or suppression.check(self.conn, e.email) is not None:
                continue
            status = "valid" if e.status == "valid" else (e.status or "unverified")
            res = contacts.upsert_contact(
                self.conn, company_id=company.id, full_name=name, origin=ContactOrigin.SCOUT, email=e.email,
                email_status=EmailStatus.PROVIDER_VERIFIED if status == "valid" else EmailStatus.PATTERN, title=e.position,
                evidence=[NewEvidence(EvidenceKind.PROVIDER, "email", url=e.source_url, provider=provider.name,
                                      snippet=f"{provider.name}: {status} (score {e.score})"),
                          NewEvidence(EvidenceKind.PROVIDER, "name", provider=provider.name, url=e.source_url)],
                pattern_confidence=min(85, int(e.score or 50)),
            )
            if res.contact.id not in report.contact_ids:
                report.contact_ids.append(res.contact.id)

    # ---- HTTP phase ----------------------------------------------------------------------------

    async def scout_http(self, company_id: int, purpose: ScoutPurpose, *, job_id: int | None = None) -> ScoutReport:
        purpose = ScoutPurpose(purpose)
        company = db.get_company(self.conn, company_id)
        job = db.get_job(self.conn, job_id) if job_id is not None else None
        report = ScoutReport(company_id=company_id, purpose=purpose)
        async with self.http_factory() as http:
            domain = await domains.resolve_domain(self.conn, company, job=job, http=http)
            report.domain = domain
            mx_ok = False
            if domain:
                report.mx = await domains.check_mx(self.conn, domain, self.mx_resolver, company_id=company_id)
                mx_ok = report.mx is not MxProvider.NONE  # None = lookup failed: keep going
            people: list[Person] = []
            samples: list[dict] = []
            # #1b founders from public facts (YC's page), when reaching out to a startup
            if purpose is ScoutPurpose.PROSPECT:
                people += founders_as_people(self.conn, company)
                if people:
                    report.sources.append("yc_page")
            # #2 the posting
            if job is not None and job.description:
                found, left = await posting.from_posting(job.description, company=company.name, domain=domain, url=job.apply_url,
                                                         llm=self.llm, usage=report.usage)
                report.sources.append("posting")
                people += found
                samples += [{"name": p.name, "email": p.email, "source": "job_posting", "url": job.apply_url} for p in found if p.email]
                for e in left:
                    if patterns.is_role_mailbox(e) and mx_ok and domain and e.endswith("@" + domain):
                        self._save_mailbox(company, e, job.apply_url or "", report)
            site: site_pages.SiteFindings | None = None
            if domain and not self.is_paused():
                # #3 company pages
                site = await site_pages.from_site(http, domain, company=company.name, llm=self.llm, usage=report.usage)
                report.sources.append("company_pages")
                people += [p for p in site.people if not any(q.name == p.name for q in people)]
                samples += site.samples
                if mx_ok:
                    for email, url in site.role_mailboxes[:2]:
                        self._save_mailbox(company, email, url, report)
            if domain and not self.is_paused():
                inf = domains.add_samples(self.conn, domain, samples, company_id=company_id)
                for p in people:
                    self._save(company, p, domain=domain, mx_ok=mx_ok, pattern=inf, report=report)
                # #4 GitHub, unless we already have enough
                if self._usable(company_id, purpose) < ENOUGH_CONTACTS:
                    gh = await github_org.from_github(http, domain=domain, company=company.name,
                                                      hints=site.github_orgs if site else [], token=self.github_token())
                    if gh.org:
                        report.sources.append("github")
                    inf = domains.add_samples(self.conn, domain, gh.samples, company_id=company_id)
                    for p in gh.people:
                        self._save(company, p, domain=domain, mx_ok=mx_ok, pattern=inf, report=report)
                    # Re-guess earlier people now that the pattern may be better.
                    if gh.samples:
                        for p in people:
                            if not p.email:
                                self._save(company, p, domain=domain, mx_ok=mx_ok, pattern=inf, report=report)
                # #8 provider (user's key), only when nothing usable was found
                if mx_ok and self._usable(company_id, purpose) == 0:
                    await self._provider(http, company, domain, report)
            else:
                for p in people:
                    self._save(company, p, domain=None, mx_ok=False, pattern=None, report=report)
        await self._role_fit(report.contact_ids, job, report)
        if site is not None and site.summary and purpose is ScoutPurpose.PROSPECT:
            from autoapply.outreach import prospects

            prospects.upsert(self.conn, company_id, summary=site.summary, summary_url=site.summary_url)
        mark_scouted(self.conn, company_id)
        prefs = db.get_preferences(self.conn)
        if prefs.people_finder_visits_per_day > 0 and (domain is None or self._usable(company_id, purpose) < ENOUGH_CONTACTS):
            queue_google(self.conn, company_id, purpose, job_id=job_id)
            report.queued_google = True
        db.log_event(self.conn, "outreach", f"scouted {company.name}: {len(report.contact_ids)} contact(s) via "
                     + (", ".join(report.sources) or "nothing"), job_id=job_id,
                     payload={"company_id": company_id, "contacts": report.contact_ids, "domain": domain})
        return report

    # ---- Google phase ---------------------------------------------------------------------------

    async def scout_google(self, company_id: int, purpose: ScoutPurpose, reader: google_people.GoogleReader, *,
                           job_id: int | None = None) -> ScoutReport:
        purpose = ScoutPurpose(purpose)
        company = db.get_company(self.conn, company_id)
        job = db.get_job(self.conn, job_id) if job_id is not None else None
        report = ScoutReport(company_id=company_id, purpose=purpose, domain=company.domain)
        if company.domain is None:
            hits = await reader.read(f'"{company.name}" official website')
            if hits:
                found = google_people.find_official_site(hits, company.name)
                if found:
                    company = db.upsert_company(self.conn, company.name, domain=found)
                    report.domain = found
                    http_report = await self.scout_http(company_id, purpose, job_id=job_id)
                    report.contact_ids += http_report.contact_ids
                    report.usage.add(http_report.usage)
        domain = company.domain
        mx_ok = False
        if domain:
            report.mx = await domains.check_mx(self.conn, domain, self.mx_resolver, company_id=company_id)
            mx_ok = report.mx is not MxProvider.NONE
        prefs = db.get_preferences(self.conn)
        location = (job.location if job and job.location else (prefs.locations[0] if prefs.locations else None))
        city = location.split(",")[0].strip() if location else None
        people: list[Person] = []
        samples: list[dict] = []
        for q in google_people.people_queries(company.name, purpose=purpose.value, location=city, domain=domain if mx_ok else None):
            if self.is_paused():
                break
            hits = await reader.read(q)
            if hits is None:
                break
            report.sources.append("google")
            if q.startswith('"@'):
                samples += google_people.email_samples_from_results(hits, domain or "")
            else:
                people += [p for p in google_people.people_from_results(hits, company.name) if not any(x.name == p.name for x in people)]
        inf = domains.add_samples(self.conn, domain, samples, company_id=company_id) if domain else None
        for s in samples:
            people.append(Person(name=s["name"], email=s["email"], url=s["url"], kind=EvidenceKind.GOOGLE_SERP,
                                 snippet=f"{s['email']} in a search result"))
        for p in people:
            self._save(company, p, domain=domain, mx_ok=mx_ok, pattern=inf, report=report)
        await self._role_fit(report.contact_ids, job, report)
        pop_google(self.conn, company_id, purpose.value)
        return report


def best_contact(conn: sqlite3.Connection, company_id: int, purpose: ScoutPurpose, *, min_confidence: int = 0) -> Contact | None:
    """The contact to write to for ``purpose`` (an address on the do-not-contact list never counts)."""
    rows = [c for c in contacts.list_contacts(conn, company_id) if c.email_norm and c.email_confidence >= min_confidence
            and c.email_status is not EmailStatus.BOUNCED and suppression.check(conn, c.email_norm) is None]
    if not rows:
        return None
    posting_ids = {int(r[0]) for r in conn.execute(
        "SELECT DISTINCT contact_id FROM contact_evidence WHERE kind = 'job_posting' AND field = 'name'")}
    small = is_small_team(conn, company_id)
    return sorted(rows, key=lambda c: contacts.rank_key(c, purpose, from_posting=c.id in posting_ids, small_team=small))[0]


def is_small_team(conn: sqlite3.Connection, company_id: int) -> bool:
    """A startup of at most ``contacts.SMALL_TEAM`` people (team size from public facts)."""
    from autoapply.outreach import facts

    f = facts.get(conn, company_id)
    return bool(f and f.team_size and f.team_size <= contacts.SMALL_TEAM)


def founders_as_people(conn: sqlite3.Connection, company: Company) -> list[Person]:
    """Founders listed on the company's YC page (``company_facts.founders``), as scout people."""
    from autoapply.outreach import facts

    f = facts.get(conn, company.id)
    out: list[Person] = []
    for x in (f.founders if f else []):
        name = str(x.get("name") or "").strip()
        if not name:
            continue
        title = str(x.get("title") or "").strip() or "Founder"
        url = x.get("url") or (f.yc_url if f else None)
        out.append(Person(name=name, title=title, url=url, kind=EvidenceKind.COMPANY_PAGE, linkedin_url=x.get("linkedin_url"),
                          snippet=f"{name}, {title}: listed on Y Combinator's page for {company.name}"))
    return out


__all__ = ["ContactScout", "ScoutReport", "best_contact", "founders_as_people", "google_queue", "is_small_team", "mark_scouted",
           "pop_google", "queue_google", "recently_scouted"]
