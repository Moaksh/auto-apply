"""Scripted Greenhouse adapter.

Owner: Workstream A (engine core).

* Form URL: the bare embed form ``job-boards.greenhouse.io/embed/job_app?for={token}&token={id}``
  (the board's ``absolute_url`` often points at the company's own careers site, which embeds
  this form in an iframe, and the hosted page redirects there too). Classic ``boards.greenhouse.io`` URLs are used as-is.
* Questions: ``boards-api .../jobs/{id}?questions=true`` (clean labels, options, required)
  for the Prep pass and to enrich the DOM scan; the DOM (``#first_name``, ``#resume``,
  ``#question_123``, react-select comboboxes) is what gets filled.
* Confirmation: redirect to ``.../confirmation`` or "Thank you for applying".
"""

from __future__ import annotations

import re

import httpx

from autoapply.apply.base import ApplyContext, ScriptedFormAdapter
from autoapply.discovery.base import detect_ats, extract_job_id
from autoapply.discovery.greenhouse import embed_application_url, fetch_greenhouse_questions
from autoapply.enums import Ats
from autoapply.models import FormQuestion


class GreenhouseAdapter(ScriptedFormAdapter):
    """Implements :class:`autoapply.apply.base.Adapter`."""

    ats = Ats.GREENHOUSE
    hosts = ("boards.greenhouse.io", "job-boards.greenhouse.io", "job-boards.eu.greenhouse.io")
    submit_selectors = (
        "button[type=submit]:has-text('Submit')", "#submit_app", "input#submit_app", "button[type=submit]", "input[type=submit]",
    )
    confirm_url = re.compile(r"/confirmation\b", re.I)

    def _token_and_id(self, ctx: ApplyContext) -> tuple[str | None, str | None]:
        raw = ctx.job.raw or {}
        token = raw.get("board_token")
        job_id = raw.get("job_id") or ctx.job.external_id
        if not token:
            _, token = detect_ats(ctx.job.apply_url)
        if not token:
            from autoapply import db

            company = db.get_company(ctx.conn, ctx.job.company_id)
            token = company.board_token if company.ats in (None, Ats.GREENHOUSE) else None
        if not job_id:
            job_id = extract_job_id(ctx.job.apply_url)
        return token, (str(job_id) if job_id else None)

    def form_url(self, ctx: ApplyContext) -> str:
        override = ctx.extra.get("form_url")
        if override:
            return str(override)
        url = ctx.job.apply_url or ctx.job.source_url or ""
        ats, _ = detect_ats(url)
        if ats is Ats.GREENHOUSE and "gh_jid" not in url and any(h in url for h in self.hosts):
            return url
        token, job_id = self._token_and_id(ctx)
        if token and job_id:
            # Not the hosted page: boards with a custom careers URL redirect it to the company
            # site, where the form lives in an iframe the scripted fill can't see.
            return embed_application_url(token, job_id)
        if url:
            return url
        raise ValueError("greenhouse job has no usable apply URL")

    async def api_questions(self, ctx: ApplyContext) -> list[FormQuestion]:
        if ctx.extra.get("no_api"):
            return []
        token, job_id = self._token_and_id(ctx)
        if not token or not job_id:
            return []
        http: httpx.AsyncClient | None = ctx.extra.get("http")
        if http is not None:
            return await fetch_greenhouse_questions(http, token, job_id)
        async with httpx.AsyncClient(timeout=15.0) as client:
            return await fetch_greenhouse_questions(client, token, job_id)

    async def open_form(self, page, ctx: ApplyContext) -> None:  # type: ignore[no-untyped-def]
        await super().open_form(page, ctx)
        # New boards show the form inline; some layouts hide it behind an "Apply" button.
        form = page.locator("form#application-form, form#application_form")
        if await form.count() and not await form.first.is_visible():
            apply_btn = page.get_by_role("button", name=re.compile(r"^\s*apply", re.I))
            if await apply_btn.count():
                await apply_btn.first.click()
