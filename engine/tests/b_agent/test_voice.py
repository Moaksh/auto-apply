"""Writing voice: the AI-tells linter (flag + safe rewrite, never a fact change), the stored
voice profile, and the prompt guidance in cover letters, outreach drafts and long answers."""

from __future__ import annotations

import re

import pytest

from autoapply import db
from autoapply.answers import voice
from autoapply.answers.cover_letter import extract_claims, generate_cover_letter
from autoapply.answers.resolver import AnswerResolver
from autoapply.enums import DraftKind, FieldType, Formality
from autoapply.llm.provider import FakeLLMProvider
from autoapply.models import FormQuestion, VoiceProfile
from autoapply.outreach import drafts

from .conftest import gen, make_job, seed_profile

SLOP = (
    "Dear Stripe hiring team,\n\n"
    "I hope this email finds you well. I am writing to express my interest in the Backend Engineer role at Stripe! "
    "I am passionate about building fast systems — at Acme Pay I leveraged Go and Postgres to cut payment latency by 40% "
    "— and I'm excited to delve into payments infrastructure!\n\n"
    "I am a motivated, dedicated, and innovative engineer who thrives in a fast-paced environment and loves cutting-edge synergy.\n\n"
    "Please don't hesitate to contact me if you need anything.\n\n"
    "Sincerely,\nAda Lovelace"
)


def _numbers_and_names(text: str) -> set[str]:
    return {c for c in extract_claims(text) if not c.lower().startswith(("dear", "sincerely", "best"))}


def test_linter_rewrites_safely_and_keeps_every_fact():
    res = voice.lint(SLOP, VoiceProfile(), kind="cover_letter")
    out = res.text
    changed = {i.rule for i in res.changed}
    assert changed >= {"hope_well", "writing_to_express", "passionate_about", "leverage", "excited_to", "delve", "em_dash",
                       "exclamations", "triple_adjectives", "cutting_edge", "generic_closer", "sign_off"}
    assert {i.rule for i in res.flagged} >= {"synergy", "fast_paced"}
    for gone in ("hope this email", "writing to express", "passionate", "leveraged", "excited", "delve", "—", "!",
                 "cutting-edge", "hesitate", "Sincerely"):
        assert gone not in out, gone
    assert "I'm interested in the Backend Engineer role at Stripe." in out
    assert "I used Go and Postgres" in out and "dig into" in out and "motivated and dedicated engineer" in out
    assert out.rstrip().endswith("Best regards,\nAda Lovelace")
    # Facts: every number and proper noun survives, nothing new appears.
    before, after = _numbers_and_names(SLOP), _numbers_and_names(out)
    assert before - after <= {"I'm"} and after - before <= {"I'm"}
    assert "40%" in out and "Acme Pay" in out and "Postgres" in out
    rep = res.report()
    assert rep["reverted"] is False and any(c["rule"] == "delve" for c in rep["changed"])


@pytest.mark.parametrize(("text", "rule", "fixed", "expected"), [
    ("I delved into Kafka internals.", "delve", True, "I dug into Kafka internals."),
    ("We leverage Kafka for events.", "leverage", True, "We use Kafka for events."),
    ("Leveraging Go, I cut costs by 30%.", "leverage", True, "Using Go, I cut costs by 30%."),
    ("The deal gave us leverage in talks.", None, False, "The deal gave us leverage in talks."),
    ("We are passionate about clean APIs.", "passionate_about", True, "We care about clean APIs."),
    ("Her passionate about-face surprised us.", "passionate_about", False, None),
    ("I would be excited to talk.", "excited_to", True, "I would be glad to talk."),
    ("The team is excited about Go.", "excited_to", False, None),
    ("We built cutting-edge tools.", "cutting_edge", True, "We built modern tools."),
    ("We found real synergy with Infra.", "synergy", False, None),
    ("I enjoy a fast-paced environment.", "fast_paced", False, None),
    ("I am reliable, curious, and organised.", "triple_adjectives", True, "I am reliable and curious."),
    ("I know Python, Go, and Rust.", None, False, "I know Python, Go, and Rust."),
    ("Great! Thanks! See you!", "exclamations", True, "Great. Thanks. See you."),
    ("Happy to help!", None, False, "Happy to help!"),
    ("To whom it may concern, I applied.", "generic_opener", False, None),
    ("I built X — fast — at Acme.", "em_dash", True, "I built X, fast, at Acme."),
    ("I worked there 2019—2021 — and again — later.", "em_dash", True, "I worked there 2019–2021, and again, later."),
    ("Thanks.\n\nFeel free to reach out if you have any questions.\n\nBest regards,\nAda", "generic_closer", True,
     "Thanks.\n\nBest regards,\nAda"),
    ("I am writing to apply for the SRE role.", "writing_to_express", True, "I'd like to apply for the SRE role."),
])
def test_linter_rules(text, rule, fixed, expected):
    res = voice.lint(text, VoiceProfile(), kind="email")
    if rule is None:
        assert res.issues == [] and res.text == expected
        return
    hits = [i for i in res.issues if i.rule == rule]
    assert hits and all(i.fixed is fixed for i in hits), res.issues
    if expected is not None:
        assert res.text == expected
    if not fixed:
        assert res.text == text


def test_rewrite_that_would_drop_a_name_is_only_flagged():
    text = "Hi team,\n\nI hope this email finds you well, Priya. I applied for the Go role.\n\nBest regards,\nAda"
    res = voice.lint(text, VoiceProfile(), kind="email")
    assert res.text == text
    assert [(i.rule, i.fixed) for i in res.issues] == [("hope_well", False)]


def test_formal_profile_contractions_and_exclamations():
    p = VoiceProfile(formality=Formality.FORMAL)
    res = voice.lint("I am writing to express my interest in the role. Thank you!", p, kind="email")
    assert res.text == "I am interested in the role. Thank you."


def test_sign_off_follows_the_profile_and_avoid_phrases_are_flagged():
    p = VoiceProfile(sign_off="Thanks", avoid_phrases=["circling back"])
    res = voice.lint("Hi Jane,\n\nCircling back on my note.\n\nWarm regards,\nAda", p, kind="email")
    assert res.text.endswith("Thanks,\nAda")
    assert ("avoid_phrase", False) in [(i.rule, i.fixed) for i in res.issues]
    # Answers have no sign-off: not touched.
    assert voice.lint("Done.\n\nRegards,\nAda", p, kind="answer").text == "Done.\n\nRegards,\nAda"
    long = " ".join(["word"] * 80)
    assert [i.rule for i in voice.lint(long, VoiceProfile(max_words=60), kind="email").issues] == ["too_long"]


def test_polish_reverts_when_the_fact_check_objects():
    text = "I'm excited to join. Cheers!"
    res = voice.polish(text, VoiceProfile(), kind="answer", verify=lambda t: ["new claim"] if t != text else [])
    assert res.text == text and res.reverted and res.issues and not any(i.fixed for i in res.issues)
    assert voice.polish(text, VoiceProfile(), kind="answer", verify=lambda t: []).text == "I'd like to join. Cheers!"


# ---- profile ---------------------------------------------------------------------------------


def test_voice_profile_defaults_and_update(conn):
    p = voice.load_profile(conn)
    assert (p.sign_off, p.formality, p.max_words, p.avoid_phrases, p.writing_sample) == ("Best regards", Formality.NEUTRAL, 250, [], None)
    p = voice.update_profile(conn, {"sign_off": "Thanks, ", "formality": "casual", "avoid_phrases": [" circling back", "circling back", ""],
                                    "writing_sample": "  Hey, quick one.  "})
    assert (p.sign_off, p.formality, p.avoid_phrases, p.writing_sample) == ("Thanks", Formality.CASUAL, ["circling back"], "Hey, quick one.")
    assert voice.load_profile(conn) == p and voice.active() == p
    assert db.get_meta(conn, voice.META_VOICE_PROFILE)["formality"] == "casual"
    p = voice.update_profile(conn, {"sign_off": None, "writing_sample": None})
    assert p.sign_off == "Best regards" and p.writing_sample is None and p.formality is Formality.CASUAL
    with pytest.raises(ValueError):
        voice.update_profile(conn, {"max_words": 5})
    with pytest.raises(ValueError):
        voice.update_profile(conn, {"tone": "x"})
    db.set_meta(conn, voice.META_VOICE_PROFILE, {"max_words": "lots"})
    assert voice.load_profile(conn) == VoiceProfile()


def test_prompt_guidance_reflects_the_profile():
    p = VoiceProfile(sign_off="Warm wishes", formality=Formality.FORMAL, max_words=150, avoid_phrases=["synergise"],
                     writing_sample="I like short notes. Numbers help.")
    g = voice.prompt_guidance(p, kind="email")
    assert "Warm wishes," in g and "under 150 words" in g and "no contractions" in g and '"synergise"' in g
    assert "I like short notes" in g and "NOT a source of facts" in g and "every fact rule above still applies" in g
    a = voice.prompt_guidance(p, kind="answer")
    assert "Warm wishes" not in a and "words." not in a


# ---- injection into generation --------------------------------------------------------------

GOOD_LETTER = (
    "Dear Stripe hiring team,\n\nAt Acme Pay I cut payment latency by 40% and led our migration to Go microservices — "
    "fast — and I leveraged Postgres. I would like to bring that to your payments infrastructure!!\n\nSincerely,\nAda Lovelace"
)


async def test_cover_letter_prompt_has_voice_guidance_and_output_is_linted(conn):
    seed_profile(conn)
    job, _ = make_job(conn)
    company = db.get_company(conn, job.company_id)
    llm = FakeLLMProvider(rules=[("COVER LETTER", {"text": GOOD_LETTER, "story_ids": []})])
    p = VoiceProfile(sign_off="Warm wishes", avoid_phrases=["circling back"], writing_sample="Short and plain.")
    letter = await generate_cover_letter(llm, profile=db.get_profile(conn), stories=[], job=job, company=company, voice=p)
    prompt = llm.calls[0].prompt
    assert "WRITING VOICE" in prompt and 'Sign off with "Warm wishes,"' in prompt and "Short and plain." in prompt
    assert "HARD RULE" in llm.calls[0].system  # grounding untouched
    assert letter.grounded, letter.unsupported_claims
    assert "—" not in letter.text and "!" not in letter.text and "leveraged" not in letter.text
    assert letter.text.endswith("Warm wishes,\nAda Lovelace") and "40%" in letter.text and "Acme Pay" in letter.text
    assert {c["rule"] for c in letter.voice["changed"]} >= {"em_dash", "exclamations", "leverage", "sign_off"}


async def test_cover_letter_uses_the_active_profile_without_a_connection(conn):
    seed_profile(conn)
    job, _ = make_job(conn)
    voice.update_profile(conn, {"sign_off": "Cheers", "max_words": 120})
    llm = FakeLLMProvider(rules=[("COVER LETTER", {"text": "Dear team,\n\nI build Go services.\n\nAda Lovelace", "story_ids": []})])
    await generate_cover_letter(llm, profile=db.get_profile(conn), stories=[], job=job, company=db.get_company(conn, job.company_id))
    assert '"Cheers,"' in llm.calls[0].prompt and "At most 120 words" in llm.calls[0].prompt


async def test_cover_letter_fact_check_still_rejects_inventions(conn):
    seed_profile(conn)
    job, _ = make_job(conn)
    invented = "Dear Stripe hiring team,\n\nAt Google I scaled Kubernetes to 10,000 nodes!\n\nAda Lovelace"
    llm = FakeLLMProvider(rules=[("COVER LETTER", {"text": invented, "story_ids": []})])
    letter = await generate_cover_letter(llm, profile=db.get_profile(conn), stories=[], job=job, company=db.get_company(conn, job.company_id))
    assert not letter.grounded and any("Google" in c for c in letter.unsupported_claims)


async def test_outreach_prompts_have_voice_guidance(conn):
    seed_profile(conn)
    job, _ = make_job(conn)
    company = db.get_company(conn, job.company_id)
    body = ("Hi Jane,\n\nI hope this email finds you well. I applied for the Backend Engineer role at Stripe. At Acme Pay I cut "
            "payment latency by 40%.\n\nWould you pass my application to the hiring manager?\n\nBest,\nAda Lovelace")
    llm = FakeLLMProvider(rules=[("connection note", {"note": "Hi Jane, I'd like to connect!"})],
                          default={"subject": "Backend Engineer application", "body": body, "story_ids": []})
    p = VoiceProfile(sign_off="Thanks", formality=Formality.CASUAL)
    ctx = drafts.DraftContext(kind=DraftKind.APPLICATION_FOLLOWUP, profile=db.get_profile(conn), stories=[], company=company,
                              recipient_name="Jane Doe", recipient_title="Recruiter", job=job, voice=p)
    d = await drafts.generate(llm, ctx)
    prompt = llm.calls[-1].prompt
    assert "WRITING VOICE" in prompt and 'Sign off with "Thanks,"' in prompt and "relaxed" in prompt
    assert d.grounded, d.unsupported_claims
    assert "hope this email" not in d.body and d.body.endswith("Thanks,\nAda Lovelace")
    assert any(c["rule"] == "hope_well" for c in d.voice["changed"])

    note_ctx = drafts.DraftContext(kind=DraftKind.LINKEDIN_CONNECT_NOTE, profile=db.get_profile(conn), stories=[], company=company,
                                   recipient_name="Jane Doe", job=job, voice=p, referral_basis="We're connected on LinkedIn.")
    note = await drafts.generate_connect_note(llm, note_ctx)
    assert "WRITING VOICE" in llm.calls[-1].prompt and "Sign off" not in llm.calls[-1].prompt
    assert note.body == "Hi Jane, I'd like to connect!"  # one exclamation is fine


async def test_long_form_answer_gets_guidance_and_lint(conn):
    seed_profile(conn)
    job, _ = make_job(conn)
    voice.update_profile(conn, {"avoid_phrases": ["synergy"]})
    llm = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("I'm passionate about payments — and APIs — so I leveraged Go at Acme Pay.", 0.9))])
    r = AnswerResolver(conn, llm, job=job)
    res = await r.resolve(FormQuestion(key="why", label="Why this role?", field_type=FieldType.TEXTAREA))
    assert "WRITING VOICE" in llm.calls[-1].prompt and '"synergy"' in llm.calls[-1].prompt
    assert res.answer == "I care about payments, and APIs, so I used Go at Acme Pay."
    assert res.voice and {c["rule"] for c in res.voice["changed"]} == {"passionate_about", "em_dash", "leverage"}
    # Short fields: no guidance, no rewriting.
    llm2 = FakeLLMProvider(rules=[("GENERATE ANSWER", gen("Go — mostly", 0.9))])
    short = await AnswerResolver(conn, llm2, job=job).resolve(FormQuestion(key="lang", label="Main language", field_type=FieldType.TEXT))
    assert "WRITING VOICE" not in llm2.calls[-1].prompt and short.answer == "Go — mostly" and short.voice is None


def test_guidance_does_not_mention_grounding_exceptions():
    g = voice.prompt_guidance(VoiceProfile(writing_sample="I led 12 people at Foo Corp."), kind="cover_letter")
    assert re.search(r"NOT a source of facts", g)
