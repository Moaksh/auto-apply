"""Needs-You item kind: a form *question* (the user types an answer) vs an agent *action*
(the agent is blocked and the user must do or decide something: create an account / sign in,
solve a CAPTCHA, finish an email/SMS verification).

Actions are never answered with free text, never saved to answer memory and never clustered
with form questions. The agent marks them explicitly (``ask_user(kind="action")``); this
deterministic classifier is the fallback for LLM slips, harvested form fields and rows that
were parked before the kind existed.

Pure (no DB / LLM imports): used by db.py migrations, prep, memory clustering and the agent.
"""

from __future__ import annotations

import re

from autoapply.enums import QuestionKind, QuestionReason

#: Action subtypes (wire: ``QuestionCluster.action_type``; the app phrases the task from it).
ACCOUNT = "account"
CAPTCHA = "captcha"
VERIFICATION = "verification"
OTHER = "other"

#: The live email security-code flow (apply/email_code.py) waits for the user to TYPE the code
#: while the session is still open: a real answer, not an action.
_LIVE_CODE_PREFIX = "security code"

_CAPTCHA_RX = re.compile(
    r"captcha|recaptcha|hcaptcha|turnstile|verify (that )?you('| a)re (a )?human|are you a robot|not a robot"
    r"|bot (check|detection|challenge)|human verification|press and hold",
    re.I,
)
_ACCOUNT_RX = re.compile(
    r"\bpass ?words?\b|\bpasscode\b|\bpin code\b"
    r"|\b(confirm|retype|re-type|re-enter|reenter|repeat|verify)\b\s+(your\s+)?(e-?mail|email address)"
    r"|\bcreate (an |your |a new )?(account|profile|login)\b|\baccount (is )?required\b|\brequires? an account\b"
    r"|\bregister (an |for an )?account\b|\bregistration required\b|\bsign[- ]?up required\b"
    r"|\bsign[- ]?in\b|\blog[- ]?in\b|\blogin (is )?required\b|\bsecurity question\b",
    re.I,
)
_VERIFICATION_RX = re.compile(
    r"\bverification (code|link|email)\b|\bverify (your )?(e-?mail|phone|mobile|identity|account)\b"
    r"|\bone[- ]time (pass)?code\b|\botp\b|\bsms code\b|\bsecurity code\b|\b2fa\b|\btwo[- ]factor\b"
    r"|\bconfirmation code\b|\benter the code\b|\bactivate (your )?account\b|\bconfirm (your )?account\b",
    re.I,
)

_OTHER_ACTION_RX = re.compile(r"\bno online application\b|\bapply (by|via) e-?mail\b|\bapply in person\b", re.I)


def action_type(label: str, reason: QuestionReason | str | None = None) -> str | None:
    """The action subtype for ``label`` or None when it reads as an ordinary form question."""
    text = " ".join((label or "").split())
    if reason is not None and str(getattr(reason, "value", reason)) == QuestionReason.CAPTCHA.value:
        return CAPTCHA
    if _CAPTCHA_RX.search(text):
        return CAPTCHA
    if text.lower().startswith(_LIVE_CODE_PREFIX):
        return None
    if _VERIFICATION_RX.search(text):
        return VERIFICATION
    if _ACCOUNT_RX.search(text):
        return ACCOUNT
    if _OTHER_ACTION_RX.search(text):
        return OTHER
    return None


def classify(label: str, reason: QuestionReason | str | None = None) -> QuestionKind:
    """``action`` for account / sign-in / password / CAPTCHA / verification steps, else ``question``."""
    return QuestionKind.ACTION if action_type(label, reason) else QuestionKind.QUESTION


def resolve_kind(label: str, reason: QuestionReason | str | None = None, hint: QuestionKind | str | None = None) -> QuestionKind:
    """Combine the agent's explicit ``hint`` with the classifier. An explicit ``action`` always
    wins; an explicit ``question`` is overridden only by the classifier (so an LLM slip that
    sends "Choose Password" as a question still becomes an action)."""
    if hint is not None and str(getattr(hint, "value", hint)) == QuestionKind.ACTION.value:
        return QuestionKind.ACTION
    return classify(label, reason)


def action_subtype(label: str, reason: QuestionReason | str | None = None) -> str:
    """Subtype of a row already known to be an action (``other`` when no pattern matches)."""
    return action_type(label, reason) or OTHER
