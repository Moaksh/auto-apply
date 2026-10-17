"""LinkedIn's 2026 pages: lazy result cards, screen-reader title copies, an invisible reCAPTCHA
badge on every page, and a job page with hashed class names (only labels are stable)."""

from __future__ import annotations

from autoapply.discovery.linkedin import (
    LinkedinSource,
    PageState,
    linkedin_unloaded_cards,
    parse_linkedin_detail,
    parse_linkedin_search,
)

SEARCH = """<html><head><title>(26) AI Engineer Jobs in India | LinkedIn</title></head><body>
<nav class="global-nav"></nav>
<iframe src="https://www.google.com/recaptcha/enterprise/anchor?k=x" height="60"></iframe>
<div class="scaffold-layout__list"><ul>
<li data-occludable-job-id="111"><div class="job-card-container" data-job-id="111">
  <a class="job-card-container__link job-card-list__title--link" href="/jobs/view/111/?trk=x" aria-label="AI Engineer with verification">
    <span aria-hidden="true"><strong>AI Engineer</strong></span><span class="visually-hidden">AI Engineer with verification</span></a>
  <div class="artdeco-entity-lockup__subtitle">GoML</div><div class="artdeco-entity-lockup__caption">India (Remote)</div>
</div></li>
<li data-occludable-job-id="222"></li>
<li data-occludable-job-id="333"></li>
</ul></div></body></html>"""

DETAIL = """<html><head><title>AI Engineer | GoML | LinkedIn</title></head><body>
<nav class="global-nav"></nav>
<div class="i0la1"><a class="i0lmel" aria-label="Company, GoML." href="https://www.linkedin.com/company/goml/life/">GoML</a></div>
<a class="i0lmel i0lmek" aria-label="Apply on company website" data-view-name="job-apply-button" target="_blank"
   href="https://www.linkedin.com/safety/go/?url=https%3A%2F%2Fneuralgo%2Ekeka%2Ecom%2Fcareers%2Fjobdetails%2F130739%3Fsource%3Dlinkedin&urlhash=o8TZ">Apply</a>
<div class="i0lx"><div class="i0ly"><h2 class="i0ll5s">About the job</h2></div>
  <div class="i0lz"><p>Build LLM agents in Python.</p><p>3+ years.</p></div></div>
<h2>About the company</h2></body></html>"""

EASY = DETAIL.replace('<a class="i0lmel i0lmek" aria-label="Apply on company website"', '<button aria-label="Easy Apply to this job"').replace(">Apply</a>", ">Easy Apply</button>")


def test_search_cards_have_clean_titles_and_count_unloaded() -> None:
    cards = parse_linkedin_search(SEARCH)
    assert [(c.title, c.company, c.external_id) for c in cards] == [("AI Engineer", "GoML", "111")]
    assert linkedin_unloaded_cards(SEARCH) == (2, 3)


def test_invisible_recaptcha_badge_is_not_a_captcha() -> None:
    src = LinkedinSource(None, emit=None)
    assert src.page_state(SEARCH, "https://www.linkedin.com/jobs/search/?keywords=ai") is PageState.OK
    assert src.page_state(SEARCH, "https://www.linkedin.com/checkpoint/challenge/abc") is PageState.CAPTCHA


def test_new_job_page_layout() -> None:
    d = parse_linkedin_detail(DETAIL)
    assert (d.title, d.company, d.easy_apply) == ("AI Engineer", "GoML", False)
    assert d.apply_url == "https://neuralgo.keka.com/careers/jobdetails/130739"
    assert d.description and d.description.startswith("Build LLM agents") and "About the company" not in d.description
    e = parse_linkedin_detail(EASY)
    assert e.easy_apply and e.apply_url is None


def test_title_with_a_pipe_and_company_from_label() -> None:
    page = DETAIL.replace("<title>AI Engineer | GoML | LinkedIn</title>", "<title>AI Researcher (Remote | $80/hr) | Creospan Inc. | LinkedIn</title>")
    d = parse_linkedin_detail(page.replace('aria-label="Company, GoML."', 'aria-label="Company, Creospan Inc.."'))
    assert (d.title, d.company) == ("AI Researcher (Remote | $80/hr)", "Creospan Inc.")
