"""Developer CLI: ``autoapply init|watch|discover|score|apply|status|answer|run``.

Owner: Workstream A (engine core).

Runs in-process against the same SQLite DB as the daemon (``AUTOAPPLY_HOME`` relocates it).
Do not run it while ``autoapplyd`` is writing (the daemon is meant to be the only writer).

Safety: ``apply`` is a DRY RUN by default (fills the form, never clicks submit). A real
submission needs ``--submit`` and an interactive confirmation (or ``--yes``).
"""

from __future__ import annotations

import asyncio
import json
import shutil
import sqlite3
from collections.abc import Callable
from pathlib import Path
from typing import Any

import httpx
import typer
from rich.console import Console
from rich.table import Table

from autoapply import db
from autoapply.enums import Actor, AppState, Ats, QuestionStatus, RunKind
from autoapply.llm.provider import LLMProvider, get_provider
from autoapply.paths import get_paths

app = typer.Typer(help="AutoApply developer CLI", no_args_is_help=True)
watch_app = typer.Typer(help="Manage the company watchlist", no_args_is_help=True)
app.add_typer(watch_app, name="watch")
console = Console()

#: Factory for the LLM provider (tests replace it with a FakeLLMProvider factory).
LLM_FACTORY: Callable[[str], LLMProvider] = lambda name: get_provider(name)  # noqa: E731


def _open() -> sqlite3.Connection:
    return db.open_db(get_paths(create=True).db)


def _run(coro: Any) -> Any:
    return asyncio.run(coro)


# =====================================================================================
# init / watch
# =====================================================================================


@app.command()
def init(
    profile: Path | None = typer.Option(None, help="JSON file with Profile fields to load"),
    resume: Path | None = typer.Option(None, help="Resume PDF to add as a variant (copied into the home)"),
    label: str = typer.Option("Default", help="Label for --resume"),
) -> None:
    """Create the data directory + database, optionally load a profile and a resume."""
    paths = get_paths(create=True)
    conn = db.open_db(paths.db)
    try:
        if profile is not None:
            data = json.loads(profile.read_text(encoding="utf-8"))
            db.update_profile(conn, data)
            console.print(f"loaded profile fields: {', '.join(sorted(data))}")
        if resume is not None:
            if not resume.exists():
                raise typer.BadParameter(f"{resume} does not exist")
            dest = paths.resumes / resume.name
            if resume.resolve() != dest.resolve():
                shutil.copy2(resume, dest)
            text = None
            try:
                from pypdf import PdfReader

                text = "\n".join(p.extract_text() or "" for p in PdfReader(str(dest)).pages) or None
            except Exception:  # noqa: BLE001 - not a PDF / unreadable: keep the file anyway
                pass
            rv = db.add_resume_variant(conn, label=label, file_path=str(dest), text=text, is_default=True)
            console.print(f"added resume variant #{rv.id} ({rv.label})")
        console.print(f"AutoApply home: {paths.home}\ndatabase: {paths.db} (schema v{db.current_schema_version(conn)})")
    finally:
        conn.close()


@watch_app.command("add")
def watch_add(
    name: str = typer.Argument(..., help="Company name"),
    url_or_token: str = typer.Argument(..., help="ATS URL, career-page URL, or board token (with --ats)"),
    ats: str | None = typer.Option(None, help="greenhouse|lever|ashby when passing a bare token"),
) -> None:
    """Watch a company (its public job board is polled on every discovery)."""
    from autoapply.discovery.careers import add_to_watchlist

    conn = _open()
    try:
        c = add_to_watchlist(conn, name, url_or_token, ats=Ats(ats) if ats else None)
        console.print(f"watching {c.name}: ats={c.ats.value if c.ats else '-'} token={c.board_token or '-'} careers={c.careers_url or '-'}")
    finally:
        conn.close()


@watch_app.command("list")
def watch_list() -> None:
    """List watched companies."""
    conn = _open()
    try:
        t = Table("id", "company", "ats", "board token", "careers url", "last applied")
        for c in db.list_companies(conn, watch_only=True):
            t.add_row(str(c.id), c.name, c.ats.value if c.ats else "-", c.board_token or "-", c.careers_url or "-",
                      c.last_applied_at.date().isoformat() if c.last_applied_at else "-")
        console.print(t)
    finally:
        conn.close()


@watch_app.command("remove")
def watch_remove(name: str) -> None:
    """Stop watching a company."""
    conn = _open()
    try:
        if db.get_company_by_name(conn, name) is None:
            raise typer.BadParameter(f"unknown company {name!r}")
        db.upsert_company(conn, name, watch=False)
        console.print(f"stopped watching {name}")
    finally:
        conn.close()


# =====================================================================================
# discover / score
# =====================================================================================


def _sources(names: list[str]) -> list[Any]:
    from autoapply.discovery.ashby import AshbySource
    from autoapply.discovery.careers import CareersSource
    from autoapply.discovery.greenhouse import GreenhouseSource
    from autoapply.discovery.lever import LeverSource

    registry = {"greenhouse": GreenhouseSource, "lever": LeverSource, "ashby": AshbySource, "careers": CareersSource}
    return [registry[n]() for n in names]


async def discover_async(
    conn: sqlite3.Connection, *, source: str = "all", persist: bool = True, limit: int | None = None,
    http: httpx.AsyncClient | None = None,
) -> tuple[list[Any], list[tuple[Any, bool]], dict[str, str]]:
    """Run public-board discovery for the watchlist. Returns (discovered, persisted, errors)."""
    from autoapply.discovery.base import DiscoveryContext, persist_discovered

    prefs = db.get_preferences(conn)
    if source == "all":
        names = [n for n in ("greenhouse", "lever", "ashby", "careers") if prefs.sources_enabled.get(n, False)]
    else:
        names = [source]
    own = http is None
    client = http or httpx.AsyncClient(timeout=20.0, follow_redirects=True)
    try:
        ctx = DiscoveryContext(preferences=prefs, companies=db.list_companies(conn, watch_only=True), http=client,
                               limit_per_company=limit)
        found = []
        for src in _sources(names):
            found.extend(await src.discover(ctx))
    finally:
        if own:
            await client.aclose()
    persisted = persist_discovered(conn, found) if persist else []
    return found, persisted, ctx.errors


@app.command()
def discover(
    source: str = typer.Option("all", help="all|greenhouse|lever|ashby|careers"),
    persist: bool = typer.Option(True, help="Insert into the DB (deduped)"),
    limit: int | None = typer.Option(None, help="Max postings per company"),
    as_json: bool = typer.Option(False, "--json", help="Print JSON instead of a table"),
) -> None:
    """Discover jobs from the watchlist's public job boards and print them."""
    if source not in ("all", "greenhouse", "lever", "ashby", "careers"):
        raise typer.BadParameter("source must be all|greenhouse|lever|ashby|careers")
    conn = _open()
    try:
        found, persisted, errors = _run(discover_async(conn, source=source, persist=persist, limit=limit))
        created = sum(1 for _, c in persisted if c)
        if as_json:
            console.print_json(json.dumps([
                {"company": j.company_name, "title": j.title, "location": j.location, "remote": j.remote.value if j.remote else None,
                 "ats": j.ats.value, "apply_url": j.apply_url, "salary": [j.salary_min, j.salary_max, j.salary_currency]}
                for j in found
            ]))
        else:
            t = Table("company", "title", "location", "remote", "salary", "ats")
            for j in found[:200]:
                sal = f"{j.salary_min or '?'}-{j.salary_max or '?'} {j.salary_currency or ''}" if (j.salary_min or j.salary_max) else "-"
                t.add_row(j.company_name, j.title, j.location or "-", j.remote.value if j.remote else "-", sal, j.ats.value)
            console.print(t)
        console.print(f"{len(found)} postings found; {created} new" + (" (not persisted)" if not persist else ""))
        for name, err in errors.items():
            console.print(f"[yellow]! {name}: {err}[/yellow]")
    finally:
        conn.close()


@app.command()
def score(
    llm: str = typer.Option("agent_sdk", help="LLM provider (agent_sdk uses your claude CLI login)"),
    batch_size: int = typer.Option(8, help="Jobs per LLM call"),
) -> None:
    """Hard-filter + LLM-score every discovered job; queue those above the threshold."""
    from autoapply.scoring import score_pending

    conn = _open()
    try:
        provider = LLM_FACTORY(llm)
        report = _run(score_pending(conn, provider, batch_size=batch_size))
        t = Table("job", "company · title", "score", "result")
        for r in report.results:
            job = db.get_job(conn, r.job_id)
            company = db.get_company(conn, job.company_id)
            result = "error: " + r.error if r.error else ("skipped: " + r.skip_reason if r.skip_reason else "queued")
            t.add_row(str(r.job_id), f"{company.name} · {job.title}", "-" if r.score is None else str(r.score), result)
        console.print(t)
        console.print(f"queued {len(report.queued)}, skipped {len(report.skipped)}, errors {len(report.errors)}, "
                      f"tokens {report.tokens_in}+{report.tokens_out}")
    finally:
        conn.close()


# =====================================================================================
# apply
# =====================================================================================


@app.command()
def apply(
    application_id: int = typer.Argument(..., help="Application id (see `autoapply status --queue`)"),
    dry_run: bool = typer.Option(True, "--dry-run/--submit", help="Dry run (default) fills only; --submit really applies"),
    yes: bool = typer.Option(False, "--yes", help="Skip the confirmation prompt for --submit"),
    headed: bool = typer.Option(False, help="Show the browser window"),
    llm: str = typer.Option("agent_sdk", help="LLM provider for free-text answers"),
) -> None:
    """Fill an application with the scripted adapter (dry run unless --submit)."""
    from autoapply.apply.base import build_context, run_application, scripted_adapters, select_adapter

    conn = _open()
    try:
        app_row = db.get_application(conn, application_id)
        job = db.get_job(conn, app_row.job_id)
        company = db.get_company(conn, job.company_id)
        adapter = select_adapter(job, scripted_adapters())
        if adapter is None:
            console.print(f"[red]no scripted adapter for ats={job.ats.value} ({job.apply_url})[/red]")
            raise typer.Exit(2)
        if not dry_run:
            if app_row.state not in (AppState.QUEUED, AppState.PREPPING):
                console.print(f"[red]application is {app_row.state.value}; only queued applications can be submitted[/red]")
                raise typer.Exit(2)
            if not yes and not typer.confirm(f"Really submit an application to {company.name} · {job.title}?"):
                raise typer.Exit(1)
        ctx = build_context(conn, application_id, llm=LLM_FACTORY(llm), headless=not headed, dry_run=dry_run)
        result = _run(run_application(ctx, adapter))
        fill = result.fill
        if fill is not None:
            t = Table("question", "answer", "origin", "conf")
            for a in fill.answers:
                t.add_row(a.question[:60], a.answer[:70].replace("\n", " "), a.origin.value,
                          "-" if a.confidence is None else f"{a.confidence:.2f}")
            console.print(t)
            for u in fill.unresolved:
                console.print(f"[yellow]needs you ({u.reason}): {u.question.label}[/yellow]")
            if fill.screenshot_path:
                console.print(f"screenshot: {fill.screenshot_path}")
            if fill.error:
                console.print(f"[red]{fill.error}[/red]")
        console.print(f"state: {result.final_state.value}" + (f" ({result.reason})" if result.reason else ""))
    finally:
        conn.close()


# =====================================================================================
# status / answer / run
# =====================================================================================


@app.command()
def status(queue: bool = typer.Option(False, "--queue", help="List queued / review / needs-you applications")) -> None:
    """Print counts / caps / inbox summary."""
    conn = _open()
    try:
        counts = db.compute_counts(conn)
        caps = db.compute_caps(conn)
        t = Table("metric", "value")
        for k, v in counts.model_dump().items():
            t.add_row(k, str(v))
        t.add_row("daily cap", f"{caps.daily_used}/{caps.daily_limit}")
        t.add_row("companies cooling down", str(caps.companies_cooling_down))
        t.add_row("paused", str(bool(db.get_meta(conn, db.META_PAUSED, False))))
        console.print(t)
        clusters = db.list_open_clusters(conn)
        if clusters:
            ct = Table("cluster", "question", "jobs", "reason")
            for c in clusters:
                ct.add_row(c.cluster_id, c.canonical_question[:70], str(c.job_count), c.reason.value)
            console.print(ct)
        if queue:
            qt = Table("app", "state", "company · title", "ats", "score")
            states = [AppState.QUEUED, AppState.NEEDS_YOU, AppState.AWAITING_REVIEW, AppState.UNKNOWN_VERIFY, AppState.FAILED]
            for a in db.list_applications(conn, states=states):
                job = db.get_job(conn, a.job_id)
                company = db.get_company(conn, job.company_id)
                sc = db.get_score(conn, job.id)
                qt.add_row(str(a.id), a.state.value, f"{company.name} · {job.title}", job.ats.value,
                           "-" if sc is None or sc.score is None else str(sc.score))
            console.print(qt)
    finally:
        conn.close()


@app.command()
def answer(cluster_id: str, text: str, save: bool = typer.Option(True, help="Save to memory")) -> None:
    """Answer a Needs-You cluster and re-queue the jobs it was blocking."""
    conn = _open()
    try:
        cluster = db.get_cluster(conn, cluster_id)
        if cluster is None:
            raise typer.BadParameter(f"no open cluster {cluster_id!r}")
        answer_id = None
        if save:
            try:
                from autoapply.answers.memory import AnswerMemory

                answer_id = AnswerMemory(conn).save(cluster.canonical_question, text, source="user",
                                                    field_type=cluster.field_type.value).id
            except NotImplementedError:
                answer_id = db.add_answer(conn, canonical_question=cluster.canonical_question, answer=text,
                                          field_type=cluster.field_type).id
        job_ids = db.resolve_cluster(conn, cluster_id, status=QuestionStatus.ANSWERED, answer_text=text, answer_id=answer_id)
        try:  # per-job inbox answer so the resolver uses it even without memory
            from autoapply.answers.resolver import set_inbox_answers

            for jid in job_ids:
                set_inbox_answers(conn, jid, {q: text for q in cluster.variants})
        except Exception:  # noqa: BLE001 - B's module optional here
            pass
        requeued = []
        for jid in db.jobs_without_open_questions(conn, job_ids):
            a = db.get_application_by_job(conn, jid)
            if a.state is AppState.NEEDS_YOU:
                db.transition(conn, a.id, AppState.QUEUED, reason="answered", actor=Actor.USER)
                requeued.append(a.id)
        console.print(f"answered {cluster.canonical_question!r} for {len(job_ids)} job(s); re-queued applications {requeued}")
    finally:
        conn.close()


@app.command()
def run(kind: str = typer.Option("full", help="full|discover (full = discover + score; apply with `autoapply apply`)"),
        llm: str = typer.Option("agent_sdk", help="LLM provider for scoring")) -> None:
    """Run discovery (+ scoring) in-process."""
    RunKind(kind)
    conn = _open()
    try:
        found, persisted, errors = _run(discover_async(conn))
        console.print(f"discovered {len(found)} postings, {sum(1 for _, c in persisted if c)} new")
        for name, err in errors.items():
            console.print(f"[yellow]! {name}: {err}[/yellow]")
        if kind == "full":
            from autoapply.scoring import score_pending

            report = _run(score_pending(conn, LLM_FACTORY(llm)))
            console.print(f"scored: queued {len(report.queued)}, skipped {len(report.skipped)}, errors {len(report.errors)}")
    finally:
        conn.close()


def main() -> None:
    app()


if __name__ == "__main__":  # `uv run python -m autoapply.cli ...`
    main()


__all__ = ["app", "discover_async", "main"]
