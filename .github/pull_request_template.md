## What changed

<!-- What does this change, from the user's point of view? -->

## Why

<!-- The problem, and its cause. Link issues with "Fixes #123". -->

## How I tested it

<!-- Tests added or run, and what you checked by hand. Screenshots or a recording for UI changes. -->

- [ ] `cd engine && uv run pytest -q` passes
- [ ] `cd app && swift test` passes
- [ ] Tests stay offline: no real network, no real LLM, no real application submits
- [ ] If I changed `engine/autoapply/models.py`, I regenerated the contract files and Swift messages
- [ ] No guardrail is weakened (daily cap, per-company cooldown, never-guess facts, Review, submit gate, cold email approval), or it's discussed above
