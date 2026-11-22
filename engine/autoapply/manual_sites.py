"""Sites the agent keeps getting stopped at: when a job site blocks the agent with a task for the
user (sign in / create an account, a CAPTCHA, a verification step) on ``REPEAT`` different jobs,
the site goes on the manual list. Its blocked jobs leave the Needs-You inbox for the Easy Apply
list (drafted answers, the company's apply link), where the user applies by themselves, and its
new jobs go straight there instead of the agent's queue.

Stored in ``meta[manual_apply_sites]`` as ``{host: {"action": subtype, "since": ts}}``; the app
reads it to say why a job is on its manual list. "Apply anyway" on one of these jobs still
queues it for the agent (e.g. after signing in).
"""

from __future__ import annotations

import json
import sqlite3
from urllib.parse import urlsplit

from autoapply import db

META_KEY = "manual_apply_sites"
#: Different jobs on one site that stopped the agent with a user task before the site goes manual.
REPEAT = 2
#: The skip reason of a job moved to the manual list.
SKIP_REASON = "apply_manually"


#: Job boards that host many companies under one domain: there, a site is the company's board
#: (``boards.greenhouse.io/stripe``), so one company's sign-in wall never moves another's jobs.
SHARED_HOSTS = frozenset({
    "boards.greenhouse.io", "job-boards.greenhouse.io", "jobs.lever.co", "jobs.ashbyhq.com", "apply.workable.com",
    "jobs.smartrecruiters.com", "careers.smartrecruiters.com", "jobs.jobvite.com", "jobs.eu.lever.co",
})


def site_of(url: str | None) -> str | None:
    """Where a job applies (lowercase host, no ``www.``; plus the company on shared boards); None without one."""
    parts = urlsplit(url or "")
    host = (parts.hostname or "").lower()
    if not host:
        return None
    host = host[4:] if host.startswith("www.") else host
    if host in SHARED_HOSTS:
        tenant = next((seg for seg in parts.path.split("/") if seg), "")
        return f"{host}/{tenant.lower()}" if tenant else host
    return host


def sites(conn: sqlite3.Connection) -> dict[str, dict[str, str]]:
    return dict(db.get_meta(conn, META_KEY, None) or {})


def is_manual(conn: sqlite3.Connection, url: str | None) -> bool:
    site = site_of(url)
    return site is not None and site in sites(conn)


def mark(conn: sqlite3.Connection, site: str, action: str) -> bool:
    """Put ``site`` on the manual list; True the first time."""
    current = sites(conn)
    if site in current:
        return False
    current[site] = {"action": action, "since": db.now_ts()}
    db.set_meta(conn, META_KEY, current)
    return True


def blocked_jobs(conn: sqlite3.Connection, site: str) -> set[int]:
    """Jobs on ``site`` that have stopped the agent with a user task (open or already handled)."""
    ids: set[int] = set()
    for r in conn.execute("SELECT job_ids FROM questions WHERE kind = 'action'"):
        ids.update(json.loads(r["job_ids"] or "[]"))
    if not ids:
        return set()
    marks = ",".join("?" * len(ids))
    rows = conn.execute(f"SELECT id, apply_url FROM jobs WHERE id IN ({marks})", sorted(ids)).fetchall()
    return {r["id"] for r in rows if site_of(r["apply_url"]) == site}


def waiting_on_tasks_only(conn: sqlite3.Connection, site: str) -> list[int]:
    """Jobs on ``site`` waiting in Needs-You for nothing but tasks (no form question open)."""
    tasks: set[int] = set()
    questions: set[int] = set()
    for r in conn.execute("SELECT kind, job_ids FROM questions WHERE status = 'open'"):
        (tasks if r["kind"] == "action" else questions).update(json.loads(r["job_ids"] or "[]"))
    ids = sorted(tasks - questions)
    if not ids:
        return []
    marks = ",".join("?" * len(ids))
    rows = conn.execute(
        f"SELECT j.id, j.apply_url FROM jobs j JOIN applications a ON a.job_id = j.id "
        f"WHERE j.id IN ({marks}) AND a.state = 'needs_you'", ids,
    ).fetchall()
    return [r["id"] for r in rows if site_of(r["apply_url"]) == site]
