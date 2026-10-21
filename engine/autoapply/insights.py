"""Learning from outcomes: an advisory "insights" report computed from the user's own data.

docs/CAREER_OPS_REVIEW.md item 5. Ideas from career-ops' ``calibrate.mjs``,
``skip-blockers.mjs`` and ``upskill.mjs`` (MIT; see THIRD_PARTY_NOTICES.md).

Four parts, all read-only:

1. **Score calibration** — submitted applications bucketed by match-score band, with the share
   that heard back per band. Applications still in flight (submitted < :data:`IN_FLIGHT_DAYS`
   ago, no reply yet) are not data points: counting them as misses would punish recent work.
   Rates are withheld below :data:`MIN_BAND_SAMPLE` per band, and the plain-language finding
   compares only bands that clear it.
2. **Skip blockers** — top skip reasons over the last :data:`SKIP_WINDOW_DAYS` days, plus the
   requirement-level concerns the scorer wrote (``scores.reasons.concerns``) that recur.
3. **Upskill hints** — skills named in the descriptions of jobs the user was skipped for (after
   scoring) or rejected from, that the profile does not mention. Deterministic vocabulary match;
   an optional fast-model summary (:func:`summarize_upskill`). Advisory wording only: it never
   suggests claiming a skill.
4. **Resume variant performance** — the dashboard's "By resume variant" measures (applications,
   responses, interviews, n < 10 = low sample) with a one-line finding.

It never changes a threshold or any other setting. :func:`compute_insights` is pure (reads the
DB only); :func:`get_insights` adds the 6-hour cache in ``meta``.
"""

from __future__ import annotations

import json
import logging
import re
import sqlite3
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

from autoapply import db
from autoapply.models import (
    Insights,
    RequirementBlocker,
    ScoreBand,
    ScoreCalibration,
    SkipBlockers,
    SkipReasonCount,
    UpskillHint,
    UpskillHints,
    VariantInsights,
    VariantPerformance,
    format_ts,
    parse_ts,
)

log = logging.getLogger("autoapply.insights")

# ---- thresholds ---------------------------------------------------------------------------------

#: (label, min, max inclusive) score bands for calibration.
SCORE_BANDS: tuple[tuple[str, int, int], ...] = (
    ("<60", 0, 59), ("60–69", 60, 69), ("70–79", 70, 79), ("80–89", 80, 89), ("90+", 90, 100),
)
#: Applications a band needs (with an outcome) before its rates are shown or compared.
MIN_BAND_SAMPLE = 8
#: A submitted application with no reply is "in flight" (not counted) for this many days.
IN_FLIGHT_DAYS = 14
#: Response-rate gap (percentage points) between the lowest and highest rated band that counts
#: as the score separating (or, negative, inverting).
SEPARATION_PP = 10
SKIP_WINDOW_DAYS = 30
#: A recurring scorer concern is listed once this many skipped jobs share it.
MIN_REQUIREMENT_JOBS = 2
UPSKILL_WINDOW_DAYS = 90
#: A skill is an upskill hint once this many skipped / rejected jobs ask for it.
MIN_UPSKILL_JOBS = 3
#: Dashboard VariantChart: fewer than this many applications = "low sample".
VARIANT_LOW_SAMPLE = 10
CACHE_TTL = timedelta(hours=6)
META_INSIGHTS_CACHE = "insights_cache"

MAX_REASONS = 8
MAX_REQUIREMENTS = 8
MAX_HINTS = 10
MAX_EXAMPLES = 3

POSITIVE_STATUSES = frozenset({"assessment", "interview", "offer"})
RESPONSE_STATUSES = POSITIVE_STATUSES | {"rejected"}
POSITIVE_REPLY_LABELS = ("interview_invite", "assessment", "offer")

# ---- skill vocabulary ---------------------------------------------------------------------------
# (canonical name, regex, case-sensitive). Longest / most specific first: spans matched by an
# earlier entry are consumed, so "React Native" never also counts as "React".

_SKILLS: tuple[tuple[str, str, bool], ...] = (
    # languages
    ("TypeScript", r"typescript", False), ("JavaScript", r"javascript|ecmascript", False),
    ("Python", r"python", False), ("Java", r"java(?!\s*script)", False), ("Kotlin", r"kotlin", False),
    ("Go", r"[Gg]olang|Go(?=\s*[,/)]|\s+(?:and|or|programming|language|services|microservices|backend)\b)|(?<=[,(/]\s)Go\b|(?<=[,(/])Go\b", True),
    ("Rust", r"Rust", True), ("Ruby on Rails", r"ruby on rails|rails", False), ("Ruby", r"ruby", False),
    ("C++", r"c\+\+", False), ("C#", r"c#", False), (".NET", r"\.net(?:\s+core)?", False),
    ("Scala", r"scala", False), ("Elixir", r"elixir", False), ("PHP", r"php", False), ("Swift", r"Swift", True),
    ("SQL", r"sql", False),
    # frontend / frameworks
    ("React Native", r"react\s+native", False), ("React", r"React(?:\.?js|JS)?(?!\s+(?:to|quickly|fast)\b)|[Rr]eact\.js", True), ("Angular", r"angular", False),
    ("Vue.js", r"vue(?:\.?js)?", False), ("Next.js", r"next\.?js", False), ("Svelte", r"svelte", False),
    ("Node.js", r"node(?:\.?js)", False), ("Django", r"django", False), ("Flask", r"flask", False),
    ("FastAPI", r"fastapi", False), ("Spring Boot", r"spring\s+boot", False), ("GraphQL", r"graphql", False),
    ("gRPC", r"grpc", False),
    # data stores / streaming
    ("PostgreSQL", r"postgres(?:ql)?", False), ("MySQL", r"mysql", False), ("MongoDB", r"mongo(?:db)?", False),
    ("Redis", r"redis", False), ("Elasticsearch", r"elasticsearch|opensearch", False), ("DynamoDB", r"dynamodb", False),
    ("Cassandra", r"cassandra", False), ("Snowflake", r"snowflake", False), ("BigQuery", r"bigquery", False),
    ("Databricks", r"databricks", False), ("Kafka", r"kafka", False), ("RabbitMQ", r"rabbitmq", False),
    ("Spark", r"(?:apache\s+)?spark|pyspark", False), ("Airflow", r"airflow", False), ("dbt", r"dbt", False),
    # cloud / infra
    ("AWS", r"aws|amazon web services", False), ("GCP", r"gcp|google cloud(?: platform)?", False),
    ("Azure", r"azure", False), ("Kubernetes", r"kubernetes|k8s", False), ("Docker", r"docker", False),
    ("Terraform", r"terraform", False), ("Ansible", r"ansible", False), ("Helm", r"Helm", True),
    ("CI/CD", r"ci\s*/\s*cd", False), ("GitHub Actions", r"github actions", False), ("Jenkins", r"jenkins", False),
    ("Prometheus", r"prometheus", False), ("Grafana", r"grafana", False), ("Datadog", r"datadog", False),
    ("Linux", r"linux", False),
    # data / ML / AI
    ("PyTorch", r"pytorch", False), ("TensorFlow", r"tensorflow", False), ("scikit-learn", r"scikit-learn|sklearn", False),
    ("Pandas", r"pandas", False), ("NumPy", r"numpy", False), ("MLOps", r"mlops", False), ("MLflow", r"mlflow", False),
    ("LangChain", r"langchain", False), ("LlamaIndex", r"llamaindex", False), ("Hugging Face", r"hugging\s*face", False),
    ("RAG", r"RAG|[Rr]etrieval[- ][Aa]ugmented [Gg]eneration", True), ("LLMs", r"llms?|large language models?", False),
    ("Computer Vision", r"computer vision", False), ("NLP", r"nlp|natural language processing", False),
    # testing
    ("pytest", r"pytest", False), ("Jest", r"Jest", True), ("Cypress", r"cypress", False),
    ("Playwright", r"playwright", False), ("Selenium", r"selenium", False),
    # analytics / product
    ("Tableau", r"tableau", False), ("Power BI", r"power\s*bi", False), ("Looker", r"looker", False),
    ("Figma", r"figma", False), ("Salesforce", r"salesforce", False),
)

_SKILL_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (name, re.compile(rf"(?<![\w+#.])(?:{pat})(?![\w+#])", 0 if cs else re.IGNORECASE)) for name, pat, cs in _SKILLS
)

#: Requirements that are not tool names but recur in many wordings (skip blockers only).
_THEMES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("People management", re.compile(r"\b(?:people|team) manage|\bmanag(?:e|es|ed|ing)\s+(?:\S+\s+){0,2}(?:teams?|engineers|people|direct reports)\b|\bdirect reports\b", re.I)),
    ("Years of experience", re.compile(r"\b\d+\+?\s*(?:years|yrs)\b", re.I)),
    ("Degree", re.compile(r"\b(?:ph\.?d|doctorate|master'?s|bachelor'?s|degree)\b", re.I)),
    ("Security clearance", re.compile(r"\bclearance\b|\bTS/SCI\b", re.I)),
    ("Domain experience", re.compile(r"\b(?:domain|industry) (?:experience|knowledge)\b|\bno (?:\w+ ){0,2}experience in\b", re.I)),
)


def extract_skills(text: str | None) -> set[str]:
    """Canonical skill names named in ``text`` (deterministic vocabulary match)."""
    if not text:
        return set()
    found: set[str] = set()
    taken: list[tuple[int, int]] = []
    for name, pat in _SKILL_PATTERNS:
        for m in pat.finditer(text):
            if any(m.start() < e and s < m.end() for s, e in taken):
                continue
            taken.append((m.start(), m.end()))
            found.add(name)
    return found


def known_skills(profile: Any) -> set[str]:
    """Skills the profile already names anywhere (skills list, headline, summary, roles, resume
    text), canonicalised, plus the raw lowercase skill strings. Used to never hint at a skill the
    user already lists."""
    parts: list[str] = [", ".join(profile.skills or []), profile.headline or "", profile.summary or "", profile.raw_text or ""]
    for w in profile.work_history or []:
        parts.append(w.title or "")
        parts.extend(w.highlights or [])
    known = extract_skills("\n".join(parts))
    for s in profile.skills or []:
        known |= extract_skills(f", {s},")  # list context so "Go" alone still canonicalises
        known.add(s.strip().lower())
    return known


def _is_known(skill: str, known: set[str]) -> bool:
    return skill in known or skill.lower() in known


# ---- rows ---------------------------------------------------------------------------------------


@dataclass(slots=True)
class _Row:
    app_id: int
    state: str
    state_reason: str | None
    state_updated_at: datetime | None
    submitted_at: datetime | None
    status: str | None
    resume_variant_id: int | None
    title: str
    company: str
    description: str | None
    score: int | None
    reasons: dict[str, Any] = field(default_factory=dict)
    skip_reason: str | None = None
    replies: int = 0
    positive_replies: int = 0
    rejection_replies: int = 0

    @property
    def example(self) -> str:
        return f"{self.title} · {self.company}"

    @property
    def responded(self) -> bool:
        """Heard back: a response board status, or any employer reply except an automatic
        "we received your application"."""
        return (self.status in RESPONSE_STATUSES) or self.replies > 0

    @property
    def interviewed(self) -> bool:
        return (self.status in POSITIVE_STATUSES) or self.positive_replies > 0

    @property
    def rejected(self) -> bool:
        if self.status in POSITIVE_STATUSES:
            return False
        return self.status == "rejected" or self.rejection_replies > 0


_ROWS_SQL = """
SELECT a.id AS app_id, a.state, a.state_reason, a.state_updated_at, a.submitted_at, a.status, a.resume_variant_id,
       j.title, j.description, c.name AS company, s.score, s.reasons, s.skip_reason,
       (SELECT COUNT(*) FROM application_replies r WHERE r.application_id = a.id AND r.label <> 'received_ack') AS replies,
       (SELECT COUNT(*) FROM application_replies r WHERE r.application_id = a.id AND r.label IN ({pos})) AS positive_replies,
       (SELECT COUNT(*) FROM application_replies r WHERE r.application_id = a.id AND r.label = 'rejection') AS rejection_replies
FROM applications a
JOIN jobs j ON j.id = a.job_id
JOIN companies c ON c.id = j.company_id
LEFT JOIN scores s ON s.job_id = a.job_id
WHERE a.state IN ('submitted', 'skipped')
""".format(pos=", ".join(f"'{x}'" for x in POSITIVE_REPLY_LABELS))


def _load_rows(conn: sqlite3.Connection) -> list[_Row]:
    rows: list[_Row] = []
    for r in conn.execute(_ROWS_SQL):
        try:
            reasons = json.loads(r["reasons"]) if r["reasons"] else {}
        except ValueError:
            reasons = {}
        rows.append(_Row(
            app_id=r["app_id"], state=r["state"], state_reason=r["state_reason"],
            state_updated_at=parse_ts(r["state_updated_at"]) if r["state_updated_at"] else None,
            submitted_at=parse_ts(r["submitted_at"]) if r["submitted_at"] else None,
            status=r["status"], resume_variant_id=r["resume_variant_id"], title=r["title"], company=r["company"],
            description=r["description"], score=r["score"], reasons=reasons if isinstance(reasons, dict) else {},
            skip_reason=r["skip_reason"], replies=r["replies"], positive_replies=r["positive_replies"],
            rejection_replies=r["rejection_replies"],
        ))
    return rows


def _pct(x: float | None) -> str:
    return f"{round((x or 0) * 100)}%"


# ---- 1. calibration -----------------------------------------------------------------------------


def calibrate(rows: list[_Row], *, now: datetime, threshold: int) -> ScoreCalibration:
    cutoff = now - timedelta(days=IN_FLIGHT_DAYS)
    resolved: list[_Row] = []
    in_flight = unscored = 0
    for r in rows:
        if r.state != "submitted":
            continue
        if r.score is None:
            unscored += 1
            continue
        has_outcome = r.responded or r.status == "ghosted" or (r.submitted_at is not None and r.submitted_at <= cutoff)
        if not has_outcome:
            in_flight += 1
            continue
        resolved.append(r)

    bands: list[ScoreBand] = []
    for label, lo, hi in SCORE_BANDS:
        members = [r for r in resolved if r.score is not None and lo <= r.score <= hi]
        n = len(members)
        resp = sum(r.responded for r in members)
        intv = sum(r.interviewed for r in members)
        enough = n >= MIN_BAND_SAMPLE
        bands.append(ScoreBand(
            label=label, min_score=lo, max_score=hi, applications=n, responses=resp, interviews=intv,
            response_rate=resp / n if enough else None, interview_rate=intv / n if enough else None, enough_data=enough,
        ))

    rated = [b for b in bands if b.enough_data]
    if len(rated) < 2:
        verdict = "insufficient"
        finding = (
            f"Not enough data yet: {len(resolved)} scored application{'s' if len(resolved) != 1 else ''} "
            f"{'have' if len(resolved) != 1 else 'has'} an outcome, and comparing score bands needs at least "
            f"{MIN_BAND_SAMPLE} in two bands. Applications sent in the last {IN_FLIGHT_DAYS} days without a reply "
            "aren't counted yet."
        )
    else:
        low, high = rated[0], rated[-1]
        gap = round(((high.response_rate or 0) - (low.response_rate or 0)) * 100)
        if gap >= SEPARATION_PP:
            verdict = "separating"
            finding = (f"Your match score predicts replies: jobs scored {high.label} heard back {_pct(high.response_rate)} "
                       f"of the time vs {_pct(low.response_rate)} for {low.label}. Trusting the score is paying off.")
        elif gap <= -SEPARATION_PP:
            verdict = "inverted"
            finding = (f"Lower-scored jobs are doing better: {low.label} heard back {_pct(low.response_rate)} of the time "
                       f"vs {_pct(high.response_rate)} for {high.label}. The score isn't predicting replies for you yet; "
                       "it may be worth checking what the high-scored rejections had in common.")
        else:
            verdict = "flat"
            if low.min_score <= threshold + 9:
                finding = (f"Jobs scored {low.label} got replies about as often as {high.label} "
                           f"({_pct(low.response_rate)} vs {_pct(high.response_rate)}), so your threshold "
                           f"({threshold}) may be higher than it needs to be.")
            else:
                finding = (f"No clear difference yet: {high.label} heard back {_pct(high.response_rate)} of the time vs "
                           f"{_pct(low.response_rate)} for {low.label}. This usually sharpens with more outcomes.")
    return ScoreCalibration(bands=bands, min_band_sample=MIN_BAND_SAMPLE, match_threshold=threshold, resolved=len(resolved),
                            in_flight=in_flight, unscored=unscored, verdict=verdict, finding=finding)  # type: ignore[arg-type]


# ---- 2. skip blockers ---------------------------------------------------------------------------

_REASON_LABELS: dict[str, str] = {
    "excluded_company": "Company on your exclude list",
    "location_mismatch": "Location doesn't match",
    "work_auth:no_sponsorship": "No visa sponsorship",
    "salary_below_floor": "Salary below your floor",
    "missing_salary": "No salary listed",
    "company_cooldown": "Applied to this company recently",
    "posting_closed": "Posting was closed",
    "asks_candidate_to_pay": "Asked candidates to pay",
    "question_skipped": "You skipped a question it asked",
}
_PREFIX_LABELS: dict[str, str] = {
    "excluded_keyword": "Excluded keyword “{}”",
    "excluded_industry": "Excluded industry “{}”",
    "seniority_mismatch": "Seniority doesn't match ({})",
    "role_off_field": "Different field ({})",
    "remote_policy": "Work style not wanted ({})",
}


def reason_label(reason: str, threshold: int) -> str:
    if reason == "below_threshold":
        return f"Match score below your threshold ({threshold})"
    if reason in _REASON_LABELS:
        return _REASON_LABELS[reason]
    kind, _, detail = reason.partition(":")
    if detail and kind in _PREFIX_LABELS:
        return _PREFIX_LABELS[kind].format(detail)
    text = reason.replace("_", " ").strip()
    return text[:1].upper() + text[1:] if text else "Unknown"


def _concern_groups(concern: str) -> list[tuple[str, str, str]]:
    """(key, label, kind) groups one scorer concern counts under: its skills, else a theme, else
    its own normalised wording."""
    skills = sorted(extract_skills(concern))
    if skills:
        return [(f"skill:{s}", s, "skill") for s in skills]
    for label, pat in _THEMES:
        if pat.search(concern):
            return [(f"theme:{label}", label, "theme")]
    text = re.sub(r"\s+", " ", concern).strip().rstrip(".")
    key = re.sub(r"[^\w ]", "", text.lower())
    return [(f"requirement:{key}", text, "requirement")] if key else []


def skip_blockers(rows: list[_Row], *, now: datetime, threshold: int) -> SkipBlockers:
    since = now - timedelta(days=SKIP_WINDOW_DAYS)
    skipped = sorted(
        (r for r in rows if r.state == "skipped" and r.state_updated_at is not None and r.state_updated_at >= since),
        key=lambda r: (r.state_updated_at, r.app_id), reverse=True,
    )
    counts: Counter[str] = Counter()
    examples: dict[str, list[str]] = defaultdict(list)
    req: dict[str, dict[str, Any]] = {}
    for r in skipped:
        reason = (r.state_reason or r.skip_reason or "unknown").strip() or "unknown"
        counts[reason] += 1
        if len(examples[reason]) < MAX_EXAMPLES:
            examples[reason].append(r.example)
        concerns = r.reasons.get("concerns") or []
        seen: set[str] = set()
        for c in concerns if isinstance(concerns, list) else []:
            if not isinstance(c, str) or not c.strip():
                continue
            for key, label, kind in _concern_groups(c):
                entry = req.setdefault(key, {"label": label, "kind": kind, "count": 0, "wordings": [], "examples": []})
                if c.strip() not in entry["wordings"] and len(entry["wordings"]) < 2:
                    entry["wordings"].append(c.strip())
                if key in seen:
                    continue
                seen.add(key)
                entry["count"] += 1
                if len(entry["examples"]) < MAX_EXAMPLES:
                    entry["examples"].append(r.example)
    reasons = [
        SkipReasonCount(reason=k, label=reason_label(k, threshold), count=n, examples=examples[k])
        for k, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:MAX_REASONS]
    ]
    requirements = [
        RequirementBlocker(**e) for e in sorted(req.values(), key=lambda e: (-e["count"], e["label"].lower()))
        if e["count"] >= MIN_REQUIREMENT_JOBS
    ][:MAX_REQUIREMENTS]
    return SkipBlockers(window_days=SKIP_WINDOW_DAYS, skipped=len(skipped), reasons=reasons, requirements=requirements)


# ---- 3. upskill ---------------------------------------------------------------------------------

UPSKILL_NOTE = (
    "Skills these jobs asked for that your profile doesn't mention. Worth learning only if they fit where you "
    "want to go. Add a skill to your profile only once you actually have it."
)


def upskill(rows: list[_Row], *, now: datetime, known: set[str]) -> UpskillHints:
    since = now - timedelta(days=UPSKILL_WINDOW_DAYS)
    pool: list[tuple[_Row, str]] = []
    for r in rows:
        # Skipped after scoring (the model judged the fit), not by a hard filter like location.
        if r.state == "skipped" and r.score is not None and r.state_updated_at and r.state_updated_at >= since:
            pool.append((r, "skipped"))
        elif r.state == "submitted" and r.rejected and r.submitted_at and r.submitted_at >= since:
            pool.append((r, "rejected"))
    agg: dict[str, dict[str, Any]] = {}
    for r, kind in sorted(pool, key=lambda p: p[0].app_id, reverse=True):
        for skill in extract_skills(f"{r.title}\n{r.description or ''}"):
            if _is_known(skill, known):
                continue
            e = agg.setdefault(skill, {"skill": skill, "jobs": 0, "skipped": 0, "rejected": 0, "examples": []})
            e["jobs"] += 1
            e[kind] += 1
            if len(e["examples"]) < MAX_EXAMPLES:
                e["examples"].append(r.example)
    hints = [UpskillHint(**e) for e in sorted(agg.values(), key=lambda e: (-e["jobs"], -e["rejected"], e["skill"].lower()))
             if e["jobs"] >= MIN_UPSKILL_JOBS][:MAX_HINTS]
    return UpskillHints(window_days=UPSKILL_WINDOW_DAYS, jobs_considered=len(pool), min_jobs=MIN_UPSKILL_JOBS,
                        hints=hints, note=UPSKILL_NOTE)


# ---- 4. resume variants -------------------------------------------------------------------------


def variant_performance(conn: sqlite3.Connection, rows: list[_Row]) -> VariantInsights:
    labels = {r["id"]: r["label"] for r in conn.execute("SELECT id, label FROM resume_variants")}
    agg: dict[int, list[int]] = defaultdict(lambda: [0, 0, 0])
    for r in rows:
        if r.state == "submitted" and r.resume_variant_id is not None:
            a = agg[r.resume_variant_id]
            a[0] += 1
            a[1] += r.responded
            a[2] += r.interviewed
    variants = sorted(
        (VariantPerformance(resume_variant_id=vid, label=labels.get(vid, f"Resume #{vid}"), applications=n, responses=resp,
                            interviews=intv, response_rate=resp / n if n else 0.0, low_sample=n < VARIANT_LOW_SAMPLE)
         for vid, (n, resp, intv) in agg.items()),
        key=lambda v: (-v.applications, v.resume_variant_id),
    )
    rated = sorted((v for v in variants if not v.low_sample), key=lambda v: v.response_rate, reverse=True)
    if len(rated) < 2:
        finding = (f"Not enough data yet to compare resumes: each needs at least {VARIANT_LOW_SAMPLE} applications."
                   if variants else "No applications sent with a resume yet.")
    else:
        best, worst = rated[0], rated[-1]
        if round((best.response_rate - worst.response_rate) * 100) >= SEPARATION_PP:
            finding = (f"“{best.label}” heard back {_pct(best.response_rate)} of the time vs {_pct(worst.response_rate)} "
                       f"for “{worst.label}” ({best.applications} and {worst.applications} applications).")
        else:
            finding = "Your resumes are getting replies at about the same rate so far."
    return VariantInsights(variants=variants, finding=finding)


# ---- entry points -------------------------------------------------------------------------------


def compute_insights(conn: sqlite3.Connection, *, now: datetime) -> Insights:
    """The whole report from the DB (read-only, deterministic, no model calls)."""
    rows = _load_rows(conn)
    threshold = db.get_preferences(conn).match_threshold
    known = known_skills(db.get_profile(conn))
    return Insights(
        computed_at=now,
        calibration=calibrate(rows, now=now, threshold=threshold),
        skip_blockers=skip_blockers(rows, now=now, threshold=threshold),
        upskill=upskill(rows, now=now, known=known),
        variants=variant_performance(conn, rows),
    )


def cached_insights(conn: sqlite3.Connection, *, now: datetime) -> Insights | None:
    """The cached report if it is younger than :data:`CACHE_TTL`, else None."""
    raw = db.get_meta(conn, META_INSIGHTS_CACHE)
    if not isinstance(raw, dict):
        return None
    try:
        ins = Insights.model_validate(raw)
    except ValueError:
        return None
    age = now - ins.computed_at
    if age < timedelta(0) or age >= CACHE_TTL:
        return None
    return ins.model_copy(update={"cached": True})


def store_insights(conn: sqlite3.Connection, insights: Insights) -> None:
    db.set_meta(conn, META_INSIGHTS_CACHE, insights.model_copy(update={"cached": False}).model_dump(mode="json"))


def get_insights(conn: sqlite3.Connection, *, now: datetime, force: bool = False) -> Insights:
    """Cached for 6 hours in ``meta`` (``force`` recomputes)."""
    if not force:
        hit = cached_insights(conn, now=now)
        if hit is not None:
            return hit
    ins = compute_insights(conn, now=now)
    store_insights(conn, ins)
    return ins


# ---- optional model summary ---------------------------------------------------------------------

SUMMARY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["summary"],
    "properties": {"summary": {"type": "string", "maxLength": 400}},
}
SUMMARY_SYSTEM = (
    "You write one or two short, encouraging sentences for a job seeker about skills that keep appearing in jobs "
    "they were skipped for or rejected from. Advisory only: suggest learning or building real experience. Never "
    "suggest adding a skill to a resume or claiming experience the person does not have. Plain words, no lists."
)


async def summarize_upskill(insights: Insights, llm: Any) -> Insights:
    """Add a short fast-model summary of the upskill hints (tokens recorded on the result).
    Best effort: returns ``insights`` unchanged when there is nothing to summarise or the call fails."""
    hints = insights.upskill.hints
    if llm is None or not hints:
        return insights
    facts = [{"skill": h.skill, "jobs": h.jobs, "skipped": h.skipped, "rejected": h.rejected} for h in hints[:6]]
    prompt = (f"Over the last {insights.upskill.window_days} days, of {insights.upskill.jobs_considered} jobs the user was "
              f"skipped for or rejected from, these skills (not in their profile) appeared most often:\n"
              + json.dumps(facts) + "\nWrite the summary.")
    try:
        res = await llm.complete(prompt, system=SUMMARY_SYSTEM, schema=SUMMARY_SCHEMA, tier="fast", max_tokens=200)
    except Exception:  # noqa: BLE001 - the summary is optional
        log.warning("insights summary failed", exc_info=True)
        return insights
    text = str((res.data or {}).get("summary") or "").strip()
    if not text:
        return insights
    return insights.model_copy(update={
        "upskill": insights.upskill.model_copy(update={"summary": text}),
        "tokens_in": insights.tokens_in + res.usage.input_tokens,
        "tokens_out": insights.tokens_out + res.usage.output_tokens,
    })


__all__ = [
    "CACHE_TTL", "IN_FLIGHT_DAYS", "META_INSIGHTS_CACHE", "MIN_BAND_SAMPLE", "MIN_REQUIREMENT_JOBS", "MIN_UPSKILL_JOBS",
    "SCORE_BANDS", "SKIP_WINDOW_DAYS", "UPSKILL_WINDOW_DAYS", "cached_insights", "compute_insights", "extract_skills",
    "get_insights", "known_skills", "reason_label", "store_insights", "summarize_upskill",
]
