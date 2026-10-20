"""Starter watchlist: public ATS boards a fresh install watches before its first run.

A new install has no watched companies, so its only jobs come from Google Jobs listings, and most
of those point at LinkedIn / Indeed (Easy Apply, i.e. manual) rather than a form the agent can
fill. The company finder grows the watchlist, but only a few Google pages a day. Seeding these
verified Greenhouse / Lever / Ashby boards gives the agent real apply targets from the first run;
the board sources still only keep openings that match the user's roles.

Seeded once per database (``meta``), only while the watchlist is empty. Each one is recorded as an
``auto`` suggestion, so Settings > Sources shows it as agent-added and the user can undo it.
"""

from __future__ import annotations

import logging
import sqlite3

from autoapply import db
from autoapply.discovery.suggestions import board_url
from autoapply.enums import Ats, SuggestionStatus

log = logging.getLogger("autoapply.discovery.starter")

META_SEEDED = "starter_watchlist_seeded"
#: The pipeline seeds on its first discovery when True (the test suite turns it off).
AUTO_SEED = True
STARTER_SOURCE = "starter"

#: (name, ats, board token); every board was checked against its public jobs API.
STARTER_BOARDS: tuple[tuple[str, Ats, str], ...] = (
    ("Airbnb", Ats.GREENHOUSE, "airbnb"),
    ("Anthropic", Ats.GREENHOUSE, "anthropic"),
    ("Cloudflare", Ats.GREENHOUSE, "cloudflare"),
    ("Coinbase", Ats.GREENHOUSE, "coinbase"),
    ("Databricks", Ats.GREENHOUSE, "databricks"),
    ("Datadog", Ats.GREENHOUSE, "datadog"),
    ("Discord", Ats.GREENHOUSE, "discord"),
    ("Dropbox", Ats.GREENHOUSE, "dropbox"),
    ("Druva", Ats.GREENHOUSE, "druva"),
    ("Elastic", Ats.GREENHOUSE, "elastic"),
    ("Figma", Ats.GREENHOUSE, "figma"),
    ("Fivetran", Ats.GREENHOUSE, "fivetran"),
    ("GitLab", Ats.GREENHOUSE, "gitlab"),
    ("Glean", Ats.GREENHOUSE, "gleanwork"),
    ("Groww", Ats.GREENHOUSE, "groww"),
    ("HackerRank", Ats.GREENHOUSE, "hackerrank"),
    ("Instacart", Ats.GREENHOUSE, "instacart"),
    ("Lyft", Ats.GREENHOUSE, "lyft"),
    ("MongoDB", Ats.GREENHOUSE, "mongodb"),
    ("Netskope", Ats.GREENHOUSE, "netskope"),
    ("Observe.AI", Ats.GREENHOUSE, "observeai"),
    ("Okta", Ats.GREENHOUSE, "okta"),
    ("Pinterest", Ats.GREENHOUSE, "pinterest"),
    ("Pure Storage", Ats.GREENHOUSE, "purestorage"),
    ("Reddit", Ats.GREENHOUSE, "reddit"),
    ("Roblox", Ats.GREENHOUSE, "roblox"),
    ("Robinhood", Ats.GREENHOUSE, "robinhood"),
    ("Rubrik", Ats.GREENHOUSE, "rubrik"),
    ("Samsara", Ats.GREENHOUSE, "samsara"),
    ("Scale AI", Ats.GREENHOUSE, "scaleai"),
    ("Stripe", Ats.GREENHOUSE, "stripe"),
    ("Twilio", Ats.GREENHOUSE, "twilio"),
    ("Vercel", Ats.GREENHOUSE, "vercel"),
    ("Zscaler", Ats.GREENHOUSE, "zscaler"),
    ("CRED", Ats.LEVER, "cred"),
    ("Meesho", Ats.LEVER, "meesho"),
    ("Mindtickle", Ats.LEVER, "mindtickle"),
    ("Paytm", Ats.LEVER, "paytm"),
    ("Spotify", Ats.LEVER, "spotify"),
    ("Anyscale", Ats.ASHBY, "anyscale"),
    ("Cohere", Ats.ASHBY, "cohere"),
    ("ElevenLabs", Ats.ASHBY, "elevenlabs"),
    ("Harvey", Ats.ASHBY, "harvey"),
    ("Linear", Ats.ASHBY, "linear"),
    ("Notion", Ats.ASHBY, "notion"),
    ("OpenAI", Ats.ASHBY, "openai"),
    ("Perplexity", Ats.ASHBY, "perplexity"),
    ("PostHog", Ats.ASHBY, "posthog"),
    ("Ramp", Ats.ASHBY, "ramp"),
    ("Replit", Ats.ASHBY, "replit"),
    ("Sarvam AI", Ats.ASHBY, "sarvam"),
    ("Supabase", Ats.ASHBY, "supabase"),
)


def seed_starter_watchlist(conn: sqlite3.Connection) -> list[str]:
    """Watch the starter boards once, on a database whose watchlist is empty. Returns the names added."""
    if db.get_meta(conn, META_SEEDED):
        return []
    if db.list_companies(conn, watch_only=True):
        db.set_meta(conn, META_SEEDED, True)  # an existing install already has its own list
        return []
    added: list[str] = []
    for name, ats, token in STARTER_BOARDS:
        if db.company_dismissed(conn, name):
            continue
        company = db.upsert_company(conn, name, ats=ats, board_token=token, watch=True)
        db.suggest_company(conn, name, url=board_url(ats, token), source=STARTER_SOURCE, ats=ats, board_token=token,
                           verified=True, status=SuggestionStatus.AUTO, company_id=company.id)
        added.append(name)
    db.set_meta(conn, META_SEEDED, True)
    log.info("starter watchlist: watching %d company boards", len(added))
    return added


__all__ = ["AUTO_SEED", "META_SEEDED", "STARTER_BOARDS", "seed_starter_watchlist"]
