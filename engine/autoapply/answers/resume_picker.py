"""Pick the best approved resume variant per job (role keywords -> tag overlap ->
past response rate). Never edits resumes.

Score (0..1) = 0.45 * tag match (variant tags vs job title / JD)
             + 0.35 * text similarity (variant text vs JD, local embeddings)
             + 0.10 * past response rate (smoothed; only once the variant has history)
             + 0.10 * default-variant prior
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass

import numpy as np

from autoapply.answers.memory import default_embedder
from autoapply.answers.textnorm import content_tokens, normalize_question
from autoapply.models import Job, ResumeVariant


@dataclass(slots=True)
class ResumePick:
    variant: ResumeVariant
    score: float  # 0..1
    reasons: list[str]
    alternatives: list[tuple[int, float]]  # (variant_id, score) for the Review "swap" popover


def _tag_score(tags: list[str], title: str, jd: str) -> tuple[float, list[str]]:
    if not tags:
        return 0.0, []
    title_n = " " + normalize_question(title) + " "
    jd_n = " " + normalize_question(jd) + " "
    hits_title, hits_jd = [], []
    for t in tags:
        tn = normalize_question(t)
        if not tn:
            continue
        if f" {tn} " in title_n:
            hits_title.append(t)
        elif f" {tn} " in jd_n:
            hits_jd.append(t)
    score = min(1.0, 0.6 * len(hits_title) + 0.15 * len(hits_jd))
    return score, hits_title + hits_jd


def _response_rates(conn: sqlite3.Connection) -> dict[int, tuple[int, int]]:
    """variant_id -> (positive responses, submitted)."""
    out: dict[int, tuple[int, int]] = {}
    rows = conn.execute(
        "SELECT resume_variant_id AS v, COUNT(*) AS n, "
        "SUM(CASE WHEN status IN ('assessment','interview','offer') THEN 1 ELSE 0 END) AS pos "
        "FROM applications WHERE state = 'submitted' AND resume_variant_id IS NOT NULL GROUP BY resume_variant_id"
    )
    for r in rows:
        out[int(r["v"])] = (int(r["pos"] or 0), int(r["n"]))
    return out


def pick_resume(conn: sqlite3.Connection, job: Job, variants: list[ResumeVariant] | None = None) -> ResumePick | None:
    """Best enabled variant for ``job`` or None when there are no variants."""
    from autoapply import db

    if variants is None:
        variants = db.list_resume_variants(conn, enabled_only=True)
    variants = [v for v in variants if v.enabled and v.replaced_by is None]
    if not variants:
        return None
    jd = f"{job.title}\n{job.description or ''}"
    emb = default_embedder()
    texts = [f"{v.label} {' '.join(v.tags)} {v.text or ''}"[:6000] for v in variants]
    mat = emb.embed([jd[:6000], *texts])
    sims = mat[1:] @ mat[0]
    # spread raw cosine (short vs long texts are low in absolute terms) into 0..1 relative scale
    top = float(np.max(sims)) if len(sims) else 0.0
    rates = _response_rates(conn)
    jd_tokens = set(content_tokens(jd))
    scored: list[tuple[float, ResumeVariant, list[str]]] = []
    for v, sim in zip(variants, sims, strict=True):
        reasons: list[str] = []
        tag_s, hits = _tag_score(v.tags, job.title, job.description or "")
        if hits:
            reasons.append("tags match: " + ", ".join(hits[:4]))
        sim_rel = float(sim) / top if top > 0 else 0.0
        kw = sorted(jd_tokens & set(content_tokens(v.text or "")))
        if kw and len(kw) >= 3:
            reasons.append("shared keywords: " + ", ".join(kw[:5]))
        pos, n = rates.get(v.id, (0, 0))
        rate_s = 0.0
        if n >= 3:
            rate_s = (pos + 1) / (n + 4)  # Laplace-ish smoothing toward 25%
            reasons.append(f"response rate {pos}/{n}")
        prior = 1.0 if v.is_default else 0.0
        if v.is_default:
            reasons.append("default resume")
        score = 0.45 * tag_s + 0.35 * sim_rel + 0.10 * min(1.0, rate_s * 2) + 0.10 * prior
        scored.append((round(min(1.0, score), 3), v, reasons))
    scored.sort(key=lambda t: (-t[0], not t[1].is_default, t[1].id))
    best_score, best, reasons = scored[0]
    if len(scored) > 1:
        reasons.append(f"beat {scored[1][1].label} ({best_score:.2f} vs {scored[1][0]:.2f})")
    if not reasons:
        reasons.append("only variant" if len(scored) == 1 else "closest text match")
    return ResumePick(
        variant=best, score=best_score, reasons=reasons,
        alternatives=[(v.id, s) for s, v, _ in scored[1:]],
    )

