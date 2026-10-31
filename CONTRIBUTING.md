# Contributing to AutoApply

Thanks for helping. AutoApply is a small, single-maintainer project, so clear reports and focused
pull requests go a long way.

## Reporting bugs and asking for features

- **From the app:** Help ▸ Report a Bug… (or Request a Feature…), also in Settings. It opens a
  GitHub issue with your app version, macOS version, agent status and a redacted log excerpt
  already filled in, and saves a full redacted log bundle you can drag into the issue. This is the
  fastest route.
- **On GitHub:** use the [bug report](https://github.com/Moaksh/auto-apply/issues/new?template=bug_report.yml)
  or [feature request](https://github.com/Moaksh/auto-apply/issues/new?template=feature_request.yml)
  form.
- **Security issues:** don't open a public issue. See [`SECURITY.md`](SECURITY.md).

Logs can contain job titles, company names and answers you gave. The app redacts emails, phone
numbers, tokens and your home folder, but read the excerpt before you post it.

## Development setup

Everything is in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md): requirements, building the engine
and the app, running the daemon against a scratch `AUTOAPPLY_HOME`, mock mode for UI work, and
troubleshooting. Architecture and decisions are in [`PLAN.md`](PLAN.md); the app ⇄ agent contract
is in [`contract/`](contract/).

## Before you open a pull request

Run the tests for whatever you touched:

```bash
cd engine && uv run pytest -q        # engine: no network, no real LLM, never submits
cd app && swift test                 # app: Swift Testing
```

Please also:

- **Keep tests offline.** No real network calls, no real LLM (use `FakeLLMProvider`), and never a
  real application submit. Board APIs are mocked with respx; forms are local fixture pages.
- **Don't weaken a guardrail** (daily cap, per-company cooldown, never-guess facts, Review, the
  submit gate, read-only LinkedIn and Glassdoor, cold email approval) without discussing it in an
  issue first.
- **Protocol changes:** if you change a model in `engine/autoapply/models.py`, regenerate
  `contract/protocol.schema.json`, `contract/protocol.examples.ndjson` and the Swift messages (the
  commands are in `docs/DEVELOPMENT.md`) and commit them with your change.
- **Schema changes** go through `contract/schema.sql` with a migration, so existing users keep
  their data when they update.
- **UI text** is plain and specific. The agent speaks in the first person ("I can send this from
  Nov 11") and says what to do next.

## Commit messages

See `git log` for the style:

- A subject line that says what changed from the user's point of view, in plain words, e.g.
  "Review says when a job can't be sent yet, and why, instead of failing Approve".
- A body that explains the problem, the cause and the fix, with the engine and app parts described
  separately when both changed. Reference issues with `fixes #N`.

## Pull requests

- One focused change per pull request. Small is easier to review.
- Say what changed, why, and how you tested it. Screenshots or a short recording help for UI
  changes.
- Both test suites pass.
- By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
