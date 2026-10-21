# Scoring eval set

20 labelled, synthetic cases (`cases.yaml`). Each case pairs a job description with one of six
candidate profiles and states the expected band and the JD's mandatory requirements
(dealbreakers). Several are Indian-market roles. All people, companies and postings are
invented, so don't paste real postings or profiles in here.

| band | score |
|---|---|
| strong | ≥ 80 |
| borderline | 60–79 |
| poor | < 60 |

`harness.py` runs `autoapply.scoring.score_jobs` on every case through a pluggable LLM
provider. For each case it reports whether the band matched, which labelled dealbreakers the
model flagged, any extra dealbreakers, and what the grounding guard dropped.

## Offline (part of the default test run)

```
cd engine && uv run pytest -q tests/evals/scoring
```

This mode uses a deterministic fake (`scripted_provider`). The fake checks the prompt the
scorer builds (system prompt, schema, profile brief, job payload) and answers from the case
labels. It also plants one hallucinated evidence quote and one invented dealbreaker, so the
test covers parsing, the grounding guard and band mapping. It also checks that every
labelled dealbreaker quote really appears in its JD.

## Live drift check (real model, costs tokens)

```
cd engine && AUTOAPPLY_SCORING_EVAL=1 uv run pytest tests/evals/scoring -m network -s
```

or, without pytest:

```
cd engine && uv run python -m tests.evals.scoring.harness            # all cases
cd engine && uv run python -m tests.evals.scoring.harness --case dev_sre_k8s --model claude-haiku-4-5
cd engine && uv run python -m tests.evals.scoring.harness --fake     # the offline fake, as a report
```

Both forms use the `agent_sdk` provider, which needs the local `claude` CLI login. They print
one row per case (band hit or MISS, plus dealbreakers found, missed and extra), then overall
band accuracy, dealbreaker recall and token totals.

Optional environment variables for the pytest form:

- `AUTOAPPLY_SCORING_EVAL_MODEL`: model override.
- `AUTOAPPLY_SCORING_EVAL_MIN_ACCURACY`: fail below this band accuracy (0–1). The default is 0,
  which only reports.

Borderline labels are fuzzy by nature, so use the report to watch for drift between prompt or
model changes. Don't treat a single miss as a failure.

## Adding a case

Add an entry under `cases:` in `cases.yaml`. Reuse a profile from `profiles:` or add a new
one. Each dealbreaker's `jd_quote` must appear verbatim in the `jd`, and its `keyword` must
appear in the quote. The offline test enforces both rules.
