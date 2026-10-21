"""Job-site accounts: Keychain-backed logins, the agent's account step and the account-wall retry."""

from __future__ import annotations

import email
import itertools

import pytest

from autoapply import db, site_accounts
from autoapply.apply.agentic import AgentToolbox, ToolGate, _site_terms, browser_id, system_prompt
from autoapply.enums import AppState, Ats, Mode
from autoapply.llm.provider import FakeLLMProvider
from autoapply.mail import imap_codes
from autoapply.mail.imap_codes import extract_action_link

from .conftest import make_ctx, make_job, seed_profile

SIGNUP = """- heading "Create Account" [ref=a1]
- textbox "Email Address" [ref=a2]
- textbox "Password" [ref=a3]
- textbox "Verify New Password" [ref=a4]
- textbox "Why do you want to work here?" [ref=a5]
- button "Create Account" [ref=a6]
- button "Submit" [ref=a7]
"""


@pytest.fixture
def keychain(monkeypatch):
    store: dict[str, str] = {}
    monkeypatch.setattr(site_accounts, "keychain_set", lambda host, pw: store.__setitem__(host, pw))
    monkeypatch.setattr(site_accounts, "keychain_get", lambda host: store.get(host))
    monkeypatch.setattr(site_accounts, "keychain_delete", lambda host: store.pop(host, None))
    return store


@pytest.fixture
def mailbox(conn):
    db.set_meta(conn, imap_codes.META_KEY, {"email": "ada@gmail.com", "enabled": True})


@pytest.fixture
def world(conn, autoapply_home, emit, keychain, mailbox, tmp_path):
    seed_profile(conn)
    job, app = make_job(conn, ats=Ats.WORKDAY, state=AppState.FILLING, apply_url="https://acme.wd5.myworkdayjobs.com/en-US/careers/job/1")
    return {"conn": conn, "home": autoapply_home, "emit": emit, "job": job, "app": app, "tmp": tmp_path}


def toolbox(world, phase="fill"):
    ctx = make_ctx(world["conn"], world["app"].id, FakeLLMProvider(default="ok"), world["home"], world["emit"])
    return AgentToolbox(ctx, ToolGate(read_only=phase == "harvest"), phase=phase, output_dir=world["tmp"], mode=Mode.AUTO)


def text(result) -> str:
    return result["content"][0]["text"]


# ---- store ------------------------------------------------------------------------------


def test_password_policy_and_site_key():
    pw = site_accounts.generate_password()
    assert len(pw) == 20 and any(c.isupper() for c in pw) and any(c.islower() for c in pw) and any(c.isdigit() for c in pw)
    assert any(c in "!@#$%^*-_+=" for c in pw)
    assert site_accounts.generate_password() != pw
    assert site_accounts.site_key("https://www.Acme.wd5.myworkdayjobs.com/x?y=1") == "acme.wd5.myworkdayjobs.com"
    with pytest.raises(site_accounts.AccountError):
        site_accounts.site_key("not a url")


def test_create_then_reuse_then_reset(conn, keychain, mailbox):
    url = "https://acme.wd5.myworkdayjobs.com/job/1"
    first = site_accounts.begin(conn, url, purpose="create", company="Acme")
    assert not first.existing and first.email == "ada@gmail.com" and keychain[first.host] == first.password
    assert site_accounts.get_account(conn, first.host)["status"] == "creating"
    site_accounts.finish(conn, first.host, "created")
    again = site_accounts.begin(conn, url, purpose="create")
    assert again.existing and again.password == first.password  # a saved login is reused, not replaced
    reset = site_accounts.begin(conn, url, purpose="reset")
    assert reset.password != first.password and keychain[f"{first.host} (previous)"] == first.password
    site_accounts.finish(conn, first.host, "reset")
    assert f"{first.host} (previous)" not in keychain and site_accounts.reveal(conn, first.host) == reset.password
    rows = site_accounts.list_accounts(conn)
    assert [r["host"] for r in rows] == [first.host] and "password" not in rows[0] and rows[0]["status"] == "active"
    assert site_accounts.delete(conn, first.host) and site_accounts.list_accounts(conn) == [] and not keychain


def test_sign_in_without_saved_login_and_no_mailbox(conn, keychain):
    with pytest.raises(site_accounts.AccountError, match="no mailbox"):
        site_accounts.begin(conn, "https://x.example.com", purpose="create")
    db.set_meta(conn, imap_codes.META_KEY, {"email": "ada@gmail.com", "enabled": True})
    with pytest.raises(site_accounts.AccountError, match="no saved login"):
        site_accounts.begin(conn, "https://x.example.com", purpose="sign_in")
    assert site_accounts.enabled(conn)
    db.update_preferences(conn, {"create_accounts": False})
    assert not site_accounts.enabled(conn)


# ---- the agent's account step -----------------------------------------------------------------


async def test_account_step_tools_and_gate(world, keychain):
    tb = toolbox(world)
    assert tb.accounts_on and {t.name for t in tb.sdk_tools()} >= {"start_account", "check_email", "finish_account"}
    g = tb.gate
    g.observe(SIGNUP)
    c = itertools.count()

    def chk(tool, inp):
        return g.check(browser_id(tool), inp, f"k{next(c)}").allowed

    # the agent is told to create the account instead of parking it
    out = await tb.lookup_answer({"question": "Password", "field_type": "text"})
    assert "start_account" in text(out) and not tb.unresolved
    login = await tb.start_account({"purpose": "create", "site_url": "https://acme.wd5.myworkdayjobs.com/login"})
    data = __import__("json").loads(text(login))
    assert data["email"] == "ada@gmail.com" and keychain["acme.wd5.myworkdayjobs.com"] == data["password"]
    # account fields only; nothing recorded as an application answer; its own button may be clicked
    assert chk("browser_type", {"element": "Email Address", "ref": "a2", "text": "ada@gmail.com"})
    assert chk("browser_type", {"element": "Password", "ref": "a3", "text": data["password"]})
    assert not chk("browser_type", {"element": "Why do you want to work here?", "ref": "a5", "text": "money"})
    assert not chk("browser_file_upload", {"paths": ["/tmp/x.pdf"]})
    assert chk("browser_click", {"element": "Create Account", "ref": "a6"})
    assert not g.data_entered and not g.entries
    done = await tb.finish_account({"outcome": "created"})
    assert "Continue" in text(done) and not g.account_mode
    assert site_accounts.get_account(world["conn"], "acme.wd5.myworkdayjobs.com")["status"] == "active"
    # back to normal rules: submit needs request_submit again
    assert chk("browser_type", {"element": "Why do you want to work here?", "ref": "a5", "text": "x"})
    assert not chk("browser_click", {"element": "Submit", "ref": "a7"})
    # no account step once application data is in
    refused = await tb.start_account({"purpose": "sign_in", "site_url": "https://acme.wd5.myworkdayjobs.com/login"})
    assert refused.get("is_error")


async def test_account_step_allows_typing_during_harvest(world):
    tb = toolbox(world, phase="harvest")
    tb.gate.observe(SIGNUP)
    assert not tb.gate.check(browser_id("browser_type"), {"element": "Email Address", "ref": "a2", "text": "a"}, "1").allowed
    await tb.start_account({"purpose": "create", "site_url": "https://acme.wd5.myworkdayjobs.com/"})
    assert tb.gate.check(browser_id("browser_type"), {"element": "Email Address", "ref": "a2", "text": "a"}, "2").allowed


async def test_failed_account_step_goes_to_the_user(world):
    tb = toolbox(world)
    await tb.start_account({"purpose": "create", "site_url": "https://acme.wd5.myworkdayjobs.com/"})
    await tb.finish_account({"outcome": "failed", "detail": "the site wants a phone code"})
    (field,) = tb.unresolved.values()
    assert field.kind == "action" and "Account required" in field.question.label and "phone code" in field.question.label
    assert site_accounts.get_account(world["conn"], "acme.wd5.myworkdayjobs.com")["status"] == "unconfirmed"


async def test_ask_user_for_an_account_is_redirected_then_parks(world):
    tb = toolbox(world)
    for _ in range(2):
        out = await tb.ask_user({"question": "Account required to apply at acme", "kind": "action"})
        assert "start_account" in text(out) and not tb.unresolved
    await tb.ask_user({"question": "Account required to apply at acme", "kind": "action"})
    assert tb.unresolved  # the agent insisted: it's the user's task after all


async def test_feature_off_keeps_the_old_behaviour(world):
    db.update_preferences(world["conn"], {"create_accounts": False})
    tb = toolbox(world)
    assert not tb.accounts_on and "start_account" not in {t.name for t in tb.sdk_tools()}
    await tb.lookup_answer({"question": "Password"})
    assert tb.unresolved
    assert "Never create accounts" in system_prompt(False) and "start_account" in system_prompt(True)


# ---- mailbox ---------------------------------------------------------------------------


def test_action_link_and_site_terms():
    raw = (
        "Subject: Verify your Acme candidate account\nFrom: Workday <noreply@myworkday.com>\nMIME-Version: 1.0\n"
        "Content-Type: text/html; charset=utf-8\n\n"
        '<p>Hi</p><a href="https://acme.example.com/unsubscribe">Unsubscribe</a>'
        '<a href="https://acme.wd5.myworkdayjobs.com/activate?token=abc&amp;x=1">Verify Account</a>'
    )
    msg = email.message_from_string(raw)
    assert extract_action_link(msg, "") == "https://acme.wd5.myworkdayjobs.com/activate?token=abc&x=1"
    assert set(_site_terms("acme.wd5.myworkdayjobs.com", "Acme Corp")) >= {"Acme Corp", "acme", "myworkdayjobs", "workday"}


# ---- retrying account walls ---------------------------------------------------------------


async def test_account_walls_are_retried_once(world):
    from tests.d_daemon.fakes import EventSink, FakeSource, fake_hooks

    from autoapply.enums import JobSource, QuestionReason
    from autoapply.pipeline import Pipeline

    conn, app = world["conn"], world["app"]
    db.transition(conn, app.id, AppState.NEEDS_YOU, reason="unresolved_questions")
    db.add_question(conn, canonical_question="Account required to apply at acme.wd5.myworkdayjobs.com",
                    job_id=world["job"].id, reason=QuestionReason.UNKNOWN, kind="action")
    hooks, _ = fake_hooks()
    p = Pipeline(conn, paths=world["home"], llm=FakeLLMProvider(default="ok"), sources=[FakeSource([], name=JobSource.GOOGLE)],
                 adapters=[], emit=EventSink(), hooks=hooks, is_paused=lambda: False)
    assert await p.retry_account_walls() == 1
    assert db.get_application(conn, app.id).state is AppState.QUEUED and not db.list_open_clusters(conn)
    # parked again by a failed attempt: stays with the user
    db.transition(conn, app.id, AppState.FILLING, reason="test")
    db.transition(conn, app.id, AppState.NEEDS_YOU, reason="unresolved_questions")
    db.add_question(conn, canonical_question="Account required to apply at acme.wd5.myworkdayjobs.com",
                    job_id=world["job"].id, reason=QuestionReason.UNKNOWN, kind="action")
    assert await p.retry_account_walls() == 0
