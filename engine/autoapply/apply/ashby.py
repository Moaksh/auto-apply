"""Scripted Ashby adapter (``jobs.ashbyhq.com/{org}/{id}/application``).

Owner: Workstream A (engine core).

Ashby renders a React form: system fields ``_systemfield_name`` / ``_systemfield_email`` /
``_systemfield_resume`` / ``_systemfield_phone``, custom questions keyed by UUID, yes/no
questions as a pair of buttons (container class contains ``yesno``) and selects as
comboboxes. There is no public form API, so questions are harvested from the page. Success
shows "Your application was successfully submitted" in place.
"""

from __future__ import annotations

import re
from urllib.parse import urlsplit, urlunsplit

from autoapply.apply.base import ApplyContext, ScriptedFormAdapter, wait_for_fields
from autoapply.enums import Ats


class AshbyAdapter(ScriptedFormAdapter):
    """Implements :class:`autoapply.apply.base.Adapter`."""

    ats = Ats.ASHBY
    hosts = ("jobs.ashbyhq.com",)
    submit_selectors = (
        "button:has-text('Submit Application')", "button[class*='submit']", "button[type=submit]", "input[type=submit]",
    )
    confirm_text = re.compile(
        r"(application was )?successfully submitted|thank(s| you) for (applying|your application)|application (received|submitted)",
        re.I,
    )

    def form_url(self, ctx: ApplyContext) -> str:
        override = ctx.extra.get("form_url")
        if override:
            return str(override)
        url = ctx.job.apply_url or ctx.job.source_url
        if not url:
            raise ValueError("ashby job has no apply URL")
        parts = urlsplit(url)
        if (parts.hostname or "") in self.hosts and not parts.path.rstrip("/").endswith("/application"):
            return urlunsplit((parts.scheme, parts.netloc, parts.path.rstrip("/") + "/application", parts.query, ""))
        return url

    async def open_form(self, page, ctx: ApplyContext) -> None:  # type: ignore[no-untyped-def]
        await super().open_form(page, ctx)
        # The posting page has an "Application" tab; /application opens it directly, but
        # click it when the form isn't rendered yet.
        # Ashby no longer wraps the fields in a <form>: look for the fields themselves. Clicking the
        # tab while they are already shown re-renders the page and empties it right before the scan.
        if not await page.locator("input:not([type=hidden]), textarea").count():
            tab = page.get_by_role("tab", name=re.compile("application", re.I))
            if await tab.count():
                await tab.first.click()
                await wait_for_fields(page)
