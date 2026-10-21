"""Scoring eval harness: runs :func:`autoapply.scoring.score_jobs` over the labelled cases in
``cases.yaml`` with a pluggable LLM provider and reports band / dealbreaker agreement.

* Offline (default test run): :func:`scripted_provider` is a deterministic fake that checks the
  prompt the scorer builds, then answers from the case labels plus deliberately hallucinated
  evidence and a fake dealbreaker, so parsing, the grounding guard and band mapping are all
  exercised without a model.
* Live: ``AUTOAPPLY_SCORING_EVAL=1 uv run pytest tests/evals/scoring -m network -s`` or
  ``uv run python -m tests.evals.scoring.harness`` runs the real model and prints a drift report.

No database is needed: rows are built in memory.
"""

from __future__ import annotations

import argparse
import asyncio
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from autoapply.config import Preferences
from autoapply.db import normalize_text
from autoapply.enums import JobSource, Seniority
from autoapply.llm.provider import FakeLLMProvider, LLMProvider
from autoapply.models import Company, Job, Profile, utcnow
from autoapply.scoring import SCORE_SCHEMA, SCORE_SYSTEM, ScoreResult, score_jobs

CASES_FILE = Path(__file__).resolve().parent / "cases.yaml"

BANDS = ("strong", "borderline", "poor")
#: The fake answers with a score in the middle of the expected band.
BAND_ANCHOR = {"strong": 88, "borderline": 70, "poor": 35}

# Planted by the scripted fake; the grounding guard must remove both.
HALLUCINATED_EVIDENCE = "Led a 40-person platform team at NASA"
FAKE_DEALBREAKER_QUOTE = "An active government security clearance is mandatory."


def band_for(score: int | None) -> str | None:
    """strong >= 80, borderline 60-79, poor < 60."""
    if score is None:
        return None
    if score >= 80:
        return "strong"
    if score >= 60:
        return "borderline"
    return "poor"


@dataclass(slots=True)
class Case:
    id: str
    profile_key: str
    profile: Profile
    preferences: Preferences
    job: Job
    company: Company
    band: str
    dealbreakers: list[dict[str, str]]


def load_cases(path: Path = CASES_FILE) -> list[Case]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    profiles: dict[str, dict[str, Any]] = data["profiles"]
    now = utcnow()
    out: list[Case] = []
    for i, c in enumerate(data["cases"], start=1):
        p = dict(profiles[c["profile"]])
        prefs = Preferences(roles=p.pop("roles", []), seniority=[Seniority(s) for s in p.pop("seniority", [])])
        profile = Profile(**p)
        company = Company(id=i, name=c["company"], normalized_name=normalize_text(c["company"]), created_at=now, updated_at=now)
        job = Job(id=1000 + i, source=JobSource.MANUAL, company_id=i, title=c["title"], location=c.get("location"),
                  description=c["jd"], discovered_at=now, dedupe_key=f"eval:{c['id']}")
        assert c["band"] in BANDS, f"{c['id']}: unknown band {c['band']!r}"
        out.append(Case(c["id"], c["profile"], profile, prefs, job, company, c["band"], list(c.get("dealbreakers") or [])))
    return out


# =====================================================================================
# Deterministic fake
# =====================================================================================


def scripted_provider(case: Case) -> FakeLLMProvider:
    """A fake that asserts the prompt is built correctly for ``case`` and answers from the
    labels, salted with one hallucinated evidence quote and one invented dealbreaker."""

    def respond(prompt: str, system: str | None, schema: dict[str, Any] | None) -> dict[str, Any]:
        assert system == SCORE_SYSTEM and schema == SCORE_SCHEMA
        head, _, tail = prompt.partition("jobs:\n")
        assert head.startswith("Candidate profile:\n")
        brief = json.loads(head[len("Candidate profile:\n"):].split("\n\nScore these")[0])
        assert brief["skills"] == case.profile.skills[:60]
        assert brief["target_roles"] == case.preferences.roles
        [job] = json.loads(tail)
        assert job["job_id"] == case.job.id and job["title"] == case.job.title and job["company"] == case.company.name
        assert job["description"] == (case.job.description or "")[:3000]

        reqs: list[dict[str, Any]] = [
            {"requirement": d["keyword"], "dealbreaker": True, "jd_quote": d["jd_quote"], "status": "missing",
             "evidence": "", "confidence": "high"}
            for d in case.dealbreakers
        ]
        reqs += [
            {"requirement": "Core skill", "dealbreaker": False, "status": "met",
             "evidence": case.profile.skills[0], "confidence": "high"},
            {"requirement": "Leadership", "dealbreaker": False, "status": "met",
             "evidence": HALLUCINATED_EVIDENCE, "confidence": "medium"},
            {"requirement": "Clearance", "dealbreaker": True, "jd_quote": FAKE_DEALBREAKER_QUOTE,
             "status": "missing", "evidence": "", "confidence": "low"},
        ]
        s = BAND_ANCHOR[case.band]
        return {"results": [{"job_id": job["job_id"], "score": s, "summary": f"{case.band} fit",
                             "factors": {"skills": s, "seniority": s, "role": s, "domain": s},
                             "concerns": [], "requirements": reqs}]}

    return FakeLLMProvider(default=respond)


# =====================================================================================
# Running + reporting
# =====================================================================================


@dataclass(slots=True)
class CaseOutcome:
    case: Case
    result: ScoreResult
    band: str | None
    dealbreakers_found: list[str] = field(default_factory=list)   # expected keywords the model flagged
    dealbreakers_missed: list[str] = field(default_factory=list)  # expected keywords it did not
    dealbreakers_extra: list[str] = field(default_factory=list)   # flagged but not labelled

    @property
    def band_hit(self) -> bool:
        return self.band == self.case.band


def _match_dealbreakers(case: Case, result: ScoreResult) -> tuple[list[str], list[str], list[str]]:
    flagged = [r for r in result.reasons.get("requirements", []) if r.get("dealbreaker")]
    texts = [normalize_text(f"{r.get('requirement', '')} {r.get('jd_quote', '')}") for r in flagged]
    found, missed, used = [], [], set()
    for d in case.dealbreakers:
        kw = normalize_text(d["keyword"])
        hit = next((i for i, t in enumerate(texts) if kw in t), None)
        if hit is None:
            missed.append(d["keyword"])
        else:
            found.append(d["keyword"])
            used.add(hit)
    extra = [flagged[i].get("jd_quote") or flagged[i]["requirement"] for i in range(len(flagged)) if i not in used]
    return found, missed, extra


async def run_case(case: Case, llm: LLMProvider) -> CaseOutcome:
    [res] = await score_jobs(llm, profile=case.profile, preferences=case.preferences, jobs=[(case.job, case.company)])
    found, missed, extra = _match_dealbreakers(case, res)
    return CaseOutcome(case, res, band_for(res.score), found, missed, extra)


async def run_all(cases: list[Case], make_llm: Any, *, concurrency: int = 4) -> list[CaseOutcome]:
    """``make_llm(case) -> LLMProvider`` (a fresh fake per case, or one shared real provider)."""
    sem = asyncio.Semaphore(max(1, concurrency))

    async def one(c: Case) -> CaseOutcome:
        async with sem:
            return await run_case(c, make_llm(c))

    return list(await asyncio.gather(*(one(c) for c in cases)))


def drift_report(outcomes: list[CaseOutcome]) -> str:
    lines = [f"{'case':<26} {'want':<10} {'got':<10} {'score':>5}  band  dealbreakers"]
    for o in outcomes:
        score = "err" if o.result.score is None else str(o.result.score)
        db_bits = []
        if o.dealbreakers_found:
            db_bits.append("found=" + ",".join(o.dealbreakers_found))
        if o.dealbreakers_missed:
            db_bits.append("MISSED=" + ",".join(o.dealbreakers_missed))
        if o.dealbreakers_extra:
            db_bits.append(f"extra={len(o.dealbreakers_extra)}")
        g = o.result.reasons.get("grounding")
        if g:
            db_bits.append(f"grounding={g}")
        if o.result.error:
            db_bits.append(f"error={o.result.error}")
        lines.append(f"{o.case.id:<26} {o.case.band:<10} {str(o.band):<10} {score:>5}  "
                     f"{'hit ' if o.band_hit else 'MISS'}  {' '.join(db_bits)}")
    n = len(outcomes)
    hits = sum(o.band_hit for o in outcomes)
    exp = sum(len(o.case.dealbreakers) for o in outcomes)
    found = sum(len(o.dealbreakers_found) for o in outcomes)
    tin = sum(o.result.tokens_in for o in outcomes)
    tout = sum(o.result.tokens_out for o in outcomes)
    lines.append("")
    lines.append(f"band accuracy: {hits}/{n} = {hits / n:.0%}" if n else "band accuracy: n/a")
    lines.append(f"dealbreaker recall: {found}/{exp}" + (f" = {found / exp:.0%}" if exp else ""))
    lines.append(f"tokens: in={tin} out={tout} (avg/case in={tin // max(1, n)} out={tout // max(1, n)})")
    return "\n".join(lines)


def accuracy(outcomes: list[CaseOutcome]) -> float:
    return sum(o.band_hit for o in outcomes) / len(outcomes) if outcomes else 0.0


def live_provider(model: str | None = None) -> LLMProvider:
    from autoapply.llm.provider import get_provider

    return get_provider("agent_sdk", model=model)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Scoring eval: band + dealbreaker drift report")
    ap.add_argument("--fake", action="store_true", help="use the deterministic scripted fake instead of the real model")
    ap.add_argument("--model", default=None, help="model override for the live provider")
    ap.add_argument("--case", action="append", default=[], help="only run these case ids (repeatable)")
    ap.add_argument("--concurrency", type=int, default=4)
    args = ap.parse_args(argv)
    cases = [c for c in load_cases() if not args.case or c.id in args.case]
    if args.fake:
        outcomes = asyncio.run(run_all(cases, scripted_provider, concurrency=args.concurrency))
    else:
        llm = live_provider(args.model)
        outcomes = asyncio.run(run_all(cases, lambda _c: llm, concurrency=args.concurrency))
    print(drift_report(outcomes))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
