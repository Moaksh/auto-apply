"""Cold outreach: parsers against fixtures (company pages, JSON-LD, security.txt, Google result
pages, GitHub / Hunter JSON via respx, DSN bounces, auto-replies, LinkedIn notification emails),
and the LinkedIn safety rules."""

from __future__ import annotations

import httpx
import pytest
import respx

from autoapply import db
from autoapply.discovery.linkedin import HumanPacer
from autoapply.enums import EvidenceKind, ReferralBasis
from autoapply.outreach import domains, mailwatch, referrals
from autoapply.outreach.providers.hunter import HunterProvider, map_pattern
from autoapply.outreach.sources import github_org, google_people, posting, site_pages
from tests.outreach_fakes import eml, fixture

# ---- company pages ----------------------------------------------------------------------------


def test_team_page_jsonld_people_and_mailboxes():
    f = site_pages.parse_page("https://acme.com/team", fixture("team.html"), "acme.com")
    names = {p.name: p for p in f.people}
    assert set(names) == {"Priya Shah", "Rahul Verma"}  # JSON-LD people (the model adds the rest)
    assert names["Priya Shah"].email == "priya.shah@acme.com" and names["Priya Shah"].title == "Head of Engineering"
    assert f.samples == [{"name": "Priya Shah", "email": "priya.shah@acme.com", "source": "company_page", "url": "https://acme.com/team"}]
    assert f.role_mailboxes == [("careers@acme.com", "https://acme.com/team")]
    assert f.github_orgs == ["acme-inc"]


def test_homepage_summary_and_security_txt():
    assert site_pages.homepage_summary(fixture("home.html")) == "Acme builds payment infrastructure for Indian small businesses."
    assert site_pages.security_txt_emails(fixture("security.txt")) == ["security@acme.com"]
    f = site_pages.parse_page("https://acme.com/.well-known/security.txt", fixture("security.txt"), "acme.com")
    assert f.role_mailboxes == [("security@acme.com", "https://acme.com/.well-known/security.txt")]


def test_posting_contact_lines():
    text = ("We're hiring! Reach out to Jane Doe (jane.doe@acme.com) with questions. Recruiter: Ravi Kumar. "
            "Send other questions to careers@acme.com.")
    people = {p.name: p for p in posting.phrase_people(text)}
    assert set(people) == {"Jane Doe", "Ravi Kumar"} and people["Ravi Kumar"].title == "Recruiter"


async def test_posting_links_emails_to_names():
    text = "Reach out to Jane Doe (jane.doe@acme.com) or careers@acme.com."
    people, left = await posting.from_posting(text, company="Acme", domain="acme.com", url="https://x")
    assert people[0].email == "jane.doe@acme.com" and people[0].kind is EvidenceKind.JOB_POSTING
    assert left == ["careers@acme.com"]


def test_domain_helpers():
    assert domains.registrable_domain("careers.eu.acme.co.in") == "acme.co.in"
    assert domains.domain_from_url("https://boards.greenhouse.io/acme/jobs/1") is None
    assert domains.domain_from_url("https://www.linkedin.com/in/x") is None
    assert domains.domain_from_url("https://careers.acme.com/jobs") == "acme.com"
    html = ('<script type="application/ld+json">{"@type":"JobPosting","hiringOrganization":'
            '{"@type":"Organization","name":"Acme","sameAs":"https://www.acme.com"}}</script>')
    assert domains.website_from_posting(html) == "acme.com"
    assert domains.classify_mx(["aspmx.l.google.com"]).value == "google"
    assert domains.classify_mx(["acme-com.mail.protection.outlook.com"]).value == "microsoft"
    assert domains.classify_mx([]).value == "none"


# ---- Google result pages ------------------------------------------------------------------------


def test_google_people_results():
    hits = google_people.parse_results(fixture("google_people.html"))
    assert hits[0].url == "https://in.linkedin.com/in/jane-doe-12345"
    people = google_people.people_from_results(hits, "Acme")
    assert [(p.name, p.title) for p in people] == [("Jane Doe", "Senior Recruiter"), ("Ravi Kumar", "Talent Acquisition Partner")]
    assert people[0].linkedin_url == "https://in.linkedin.com/in/jane-doe-12345" and people[0].kind is EvidenceKind.GOOGLE_SERP
    # Sam works at Globex now: not a contact at Acme.
    assert all(p.name != "Sam Wright" for p in people)


def test_google_email_samples_and_official_site():
    hits = google_people.parse_results(fixture("google_emails.html"))
    assert google_people.email_samples_from_results(hits, "acme.com") == [
        {"name": "Meera Nair", "email": "meera.nair@acme.com", "source": "google_serp", "url": "https://conf.example.org/speakers"}]
    people_hits = google_people.parse_results(fixture("google_people.html"))
    assert google_people.find_official_site(people_hits, "Acme") == "acme.com"


@pytest.mark.parametrize(("title", "parsed"), [
    ("Jane Doe – Senior Recruiter – Acme | LinkedIn", ("Jane Doe", "Senior Recruiter", "Acme")),
    ("Ravi Kumar - Engineering Manager at Acme | LinkedIn", ("Ravi Kumar", "Engineering Manager", "Acme")),
    ("Priya Shah (She/Her) - Acme | LinkedIn", ("Priya Shah", "Acme", None)),
    ("Jobs at Acme | LinkedIn", None),
])
def test_parse_linkedin_title(title, parsed):
    assert google_people.parse_linkedin_title(title) == parsed


class _Page:
    def __init__(self, html: str, url: str = "https://www.google.com/search?q=x") -> None:
        self._html, self._url, self.visited = html, url, []

    @property
    def url(self) -> str:
        return self._url

    async def goto(self, url: str) -> None:
        self.visited.append(url)

    async def content(self) -> str:
        return self._html

    async def scroll(self, pixels: int) -> None:
        pass

    async def close(self) -> None:
        pass


class _Browser:
    def __init__(self, page: _Page) -> None:
        self.page = page

    async def new_page(self) -> _Page:
        return self.page

    async def close(self) -> None:
        pass


async def _no_sleep(_s: float) -> None:
    return None


async def test_google_reader_budget_and_captcha(conn):
    page = _Page(fixture("google_people.html"))

    async def factory():
        return _Browser(page)

    reader = google_people.GoogleReader(conn, factory, budget_key="people_finder", limit=lambda: 2, pacer=HumanPacer(sleep=_no_sleep))
    assert len(await reader.read('site:linkedin.com/in "Acme" recruiter')) >= 3
    assert len(await reader.read("q2")) >= 3
    assert await reader.read("q3") is None  # budget used
    assert db.get_source_sessions(conn, "people_finder") == 2
    db.reset_source_sessions(conn, "people_finder")
    page._html = fixture("google_captcha.html")
    captcha = google_people.GoogleReader(conn, factory, budget_key="people_finder", limit=lambda: 5, pacer=HumanPacer(sleep=_no_sleep))
    assert await captcha.read("q") is None and captcha.captcha
    assert captcha.resting()  # all outreach Google reading rests after a CAPTCHA
    assert all(u.startswith("https://www.google.com/search") for u in page.visited)


# ---- LinkedIn safety ------------------------------------------------------------------------------


async def test_outreach_browser_never_opens_linkedin():
    from autoapply.apply.agentic import BLOCKED_HOSTS

    assert BLOCKED_HOSTS == ("linkedin.com", "glassdoor.com", "glassdoor.co.uk", "glassdoor.co.in", "glassdoor.ca")
    assert set(google_people.NEVER_OPEN) == set(BLOCKED_HOSTS)
    page = google_people.GoogleOnlyPage(_Page(""))
    for url in ("https://www.linkedin.com/in/jane-doe", "https://in.linkedin.com/in/x", "https://acme.com/team",
                "https://www.glassdoor.co.in/x"):
        with pytest.raises(google_people.NavigationRefused):
            await page.goto(url)
    await page.goto(google_people.search_url('site:linkedin.com/in "Acme"'))  # Google itself is fine


def test_referral_queries_and_basis_evidence():
    from autoapply.models import Profile

    profile = Profile.model_validate({"work_history": [{"company": "Razorpay", "title": "SWE"}],
                                      "education": [{"school": "IIT Madras"}], "updated_at": "2026-01-01T00:00:00Z"})
    qs = referrals.referrer_queries(profile, "Acme", function="Backend Engineer", city="Bengaluru")
    assert [q.basis for q in qs] == [ReferralBasis.EX_COLLEAGUE, ReferralBasis.ALUMNI, ReferralBasis.SAME_FUNCTION]
    assert all("linkedin.com/in" in q.query for q in qs)
    hits = google_people.parse_results(fixture("google_people.html"))
    alumni = referrals.candidates_from_results(hits, qs[1], "Acme")
    assert [c.name for c in alumni] == ["Jane Doe"]  # only Jane's snippet mentions IIT Madras
    colleagues = referrals.candidates_from_results(hits, qs[0], "Acme")
    assert [c.name for c in colleagues] == ["Jane Doe"]


# ---- GitHub / Hunter (respx) ---------------------------------------------------------------------


@respx.mock
async def test_github_org_members_and_commit_emails():
    respx.get("https://api.github.com/orgs/acme-inc").respond(json={"login": "acme-inc", "blog": "https://acme.com", "name": "Acme"})
    respx.get("https://api.github.com/orgs/acme-inc/repos").respond(json=[{"name": "api", "fork": False}])
    respx.get("https://api.github.com/repos/acme-inc/api/commits").respond(json=[
        {"commit": {"author": {"name": "Meera Nair", "email": "meera.nair@acme.com"}}},
        {"commit": {"author": {"name": "Bot", "email": "bot@users.noreply.github.com"}}},
        {"commit": {"author": {"name": "Jane Doe", "email": "jane@gmail.com"}}},
    ])
    respx.get("https://api.github.com/orgs/acme-inc/public_members").respond(json=[{"login": "rverma"}])
    respx.get("https://api.github.com/users/rverma").respond(json={"login": "rverma", "name": "Rahul Verma", "email": "rahul.verma@acme.com"})
    async with httpx.AsyncClient() as http:
        gh = await github_org.from_github(http, domain="acme.com", company="Acme", hints=["acme-inc"])
    assert gh.org == "acme-inc"
    assert gh.samples == [{"name": "Meera Nair", "email": "meera.nair@acme.com", "source": "github", "url": "https://github.com/acme-inc/api"}]
    emails = {p.name: p.email for p in gh.people}
    assert emails == {"Rahul Verma": "rahul.verma@acme.com", "Meera Nair": "meera.nair@acme.com"}
    assert gh.requests <= github_org.MAX_REQUESTS


@respx.mock
async def test_github_org_must_point_at_the_company():
    respx.get("https://api.github.com/orgs/acme").respond(json={"login": "acme", "blog": "https://acme-games.io", "name": "Acme Games"})
    respx.get(url__regex=r"https://api.github.com/orgs/.*").respond(404)
    async with httpx.AsyncClient() as http:
        gh = await github_org.from_github(http, domain="acme.com", company="Acme Payments")
    assert gh.org is None and gh.people == []


@respx.mock
async def test_hunter_domain_search_and_credits(conn):
    route = respx.get("https://api.hunter.io/v2/domain-search").respond(json={"data": {
        "pattern": "{first}.{last}",
        "emails": [{"value": "jane.doe@acme.com", "first_name": "Jane", "last_name": "Doe", "position": "Recruiter",
                    "confidence": 94, "verification": {"status": "valid"}, "sources": [{"uri": "https://acme.com/team"}]}]}})
    async with httpx.AsyncClient() as http:
        res = await HunterProvider("k", http, conn, monthly_searches=1).domain_search("acme.com")
        assert res.pattern == "first.last" and res.emails[0].status == "valid"
        from autoapply.outreach.providers.base import ProviderError

        with pytest.raises(ProviderError):
            await HunterProvider("k", http, conn, monthly_searches=1).domain_search("acme.com")
    assert route.calls.call_count == 1 and route.calls[0].request.url.params["api_key"] == "k"
    assert map_pattern("{f}{last}") == "flast"


# ---- mail: bounces, auto-replies, opt-outs, LinkedIn notifications -----------------------------------


def test_bounce_parsing():
    hard = mailwatch.parse_bounce(eml("bounce_gmail_511.eml"))
    assert hard is not None and hard.hard
    assert (hard.recipient, hard.status, hard.original_message_id) == ("priya.shah@acme.com", "5.1.1", "<orig-1@gmail.com>")
    delay = mailwatch.parse_bounce(eml("bounce_delay_4xx.eml"))
    assert delay is not None and not delay.hard and delay.status == "4.4.1"
    assert mailwatch.parse_bounce(eml("reply_positive.eml")) is None


def test_auto_reply_and_opt_out_detection():
    assert mailwatch.is_auto_reply(eml("auto_reply.eml"))
    assert not mailwatch.is_auto_reply(eml("reply_positive.eml"))
    from autoapply.mail.common import _text

    assert mailwatch.is_opt_out(_text(eml("reply_optout.eml")))
    # The quoted footer ("reply \"no thanks\"") in a normal reply is not an opt-out.
    assert not mailwatch.is_opt_out(_text(eml("reply_positive.eml")))
    assert mailwatch.reply_text("Sounds good!\n\nOn Mon, Oct 19, 2026 Asha wrote:\n> no thanks") == "Sounds good!"


def test_linkedin_notification_emails():
    assert mailwatch.parse_linkedin_notification(eml("linkedin_accepted.eml")) == ("accepted", "Jane Doe")
    assert mailwatch.parse_linkedin_notification(eml("linkedin_message.eml")) == ("message", "Jane Doe")
    assert mailwatch.parse_linkedin_notification(eml("reply_positive.eml")) is None
