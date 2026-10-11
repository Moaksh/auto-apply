"""Scripted Lever adapter (``jobs.lever.co/{company}/{id}/apply``).

Owner: Workstream A (engine core).

Lever forms use stable field names: ``resume`` (file), ``name``, ``email``, ``phone``,
``org`` (current company), ``location``, ``urls[LinkedIn]`` / ``urls[GitHub]`` /
``urls[Portfolio]``, custom question cards ``cards[<uuid>][fieldN]``, ``comments``
(additional information) and EEO selects ``eeo[gender|race|veteran]``. Lever has no public
form API, so questions are harvested from the page. Success redirects to ``.../thanks``.
"""

from __future__ import annotations

import re
from urllib.parse import urlsplit, urlunsplit

from autoapply.apply.base import ApplyContext, ScriptedFormAdapter
from autoapply.enums import Ats


class LeverAdapter(ScriptedFormAdapter):
    """Implements :class:`autoapply.apply.base.Adapter`."""

    ats = Ats.LEVER
    hosts = ("jobs.lever.co", "jobs.eu.lever.co")
    form_selector = "form#application-form, form[action*='/apply']"
    submit_selectors = ("#btn-submit", "button[data-qa=btn-submit]", "button[type=submit]", "input[type=submit]")
    confirm_url = re.compile(r"/thanks\b", re.I)
    confirm_text = re.compile(r"application submitted|thank(s| you) for applying|we('ve| have) received your application", re.I)

    def form_url(self, ctx: ApplyContext) -> str:
        override = ctx.extra.get("form_url")
        if override:
            return str(override)
        url = ctx.job.apply_url or ctx.job.source_url
        if not url:
            raise ValueError("lever job has no apply URL")
        parts = urlsplit(url)
        if (parts.hostname or "") in self.hosts and not parts.path.rstrip("/").endswith("/apply"):
            return urlunsplit((parts.scheme, parts.netloc, parts.path.rstrip("/") + "/apply", parts.query, ""))
        return url

    async def form_questions(self, page, ctx):  # type: ignore[no-untyped-def]
        questions, kinds = await super().form_questions(page, ctx)
        if not questions:  # form_selector didn't match: fall back to the largest form
            from autoapply.apply.base import scan_form

            questions, kinds = await scan_form(page, None)
        return questions, kinds
