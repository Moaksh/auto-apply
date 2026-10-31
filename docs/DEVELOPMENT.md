# Developing AutoApply

Everything you need to build, run and test AutoApply from source. For what the app does, see the
[README](../README.md). Decisions and architecture are in [`PLAN.md`](../PLAN.md), the UI spec is
in [`docs/UI_UX_PLAN.md`](UI_UX_PLAN.md), and the frozen contract (DB schema and socket protocol)
is in [`contract/`](../contract/).

AutoApply has two pieces:

- **`autoapplyd`** is a Python daemon that runs as a user LaunchAgent. It runs discovery, scoring,
  the question Prep pass, applying and cold email, and it is the only process that writes the
  database.
- **`AutoApply.app`** is a SwiftUI app (macOS 26+) with a dashboard, a board, the Needs-You inbox,
  the Review queue, Cold Email, settings and a menu bar extra. It reads the database read-only and
  sends every change to the daemon over a Unix socket.

## Requirements

| What | Why |
|---|---|
| macOS 26 or later, Apple silicon | The app targets macOS 26 (Liquid Glass, Observation). |
| Xcode 26 or a Swift 6.4 toolchain | Builds the SwiftPM package in `app/`. |
| [`uv`](https://docs.astral.sh/uv/) | Manages the Python 3.12 engine in `engine/`. uv installs Python 3.12 itself if needed. |
| `claude` CLI, logged in | The default LLM provider is the Claude Agent SDK, which uses your existing `claude` login. |
| Node.js (`npx`) | The agentic adapter runs `npx @playwright/mcp` for unknown or Workday forms. |
| Google Chrome | The agent uses a dedicated, persistent Chrome profile: a visible window for LinkedIn and Glassdoor, headless Chromium for ATS forms. |

The onboarding flow's System check verifies all of these and offers a fix command for each one.

## Setup

```bash
git clone https://github.com/Moaksh/auto-apply.git auto_apply && cd auto_apply

# Engine
cd engine
uv sync                                   # creates engine/.venv and installs deps + dev tools
uv run playwright install chromium        # browser for the scripted ATS adapters
uv run pytest -q                          # ~1,460 tests, no network, no real LLM
cd ..

# App
cd app
swift build                               # or: open Package.swift   (opens in Xcode; run the AutoApply scheme)
swift test                                # Swift Testing: AutoApplyTests + C3Tests
cd ..
```

## Double-clickable app

```bash
cd engine && uv sync && uv run autoapply init && cd ..   # first run: creates ~/Library/Application Support/AutoApply
app/scripts/make_app.sh                                  # release build -> app/build/AutoApply.app (ad-hoc signed)
open app/build/AutoApply.app
```

The app does not launch the daemon itself; it connects to `autoapplyd.sock` in the AutoApply home.
Start the daemon first (see below: `cd engine && uv run autoapplyd --no-scheduler`, or install the
LaunchAgent, which Settings ▸ Agent and onboarding's "Install agent" can also do). Without it the
app shows "Can't reach autoapplyd". Because the bundle is ad-hoc signed, if Gatekeeper blocks a copy
moved elsewhere, right-click > Open once.

### Release builds

`app/build/` holds `AutoApply.app` and `AutoApply-<version>.dmg` and is never committed.

1. Bump `CFBundleShortVersionString` in `app/scripts/make_app.sh` (e.g. 0.1.5 -> 0.1.6).
2. `app/scripts/make_dmg.sh` -> `app/build/AutoApply-0.1.6.dmg` (includes a "READ ME FIRST.txt").
3. `gh release create v0.1.6 app/build/AutoApply-0.1.6.dmg --prerelease --title "AutoApply v0.1.6 (beta)"`

Installed apps (0.1.1+) find updates via GitHub Releases: the tag must be newer than the app's
version and the release must have the `.dmg` attached. The repo has to stay public for the free,
tokenless update check.

## Running the daemon

The daemon keeps its data in `~/Library/Application Support/AutoApply/` by default. Set
`AUTOAPPLY_HOME` (or pass `--home`) to use another directory.

```
autoapply.db   resumes/   screenshots/   cover_letters/   chrome-profile/   logs/   autoapplyd.sock
```

**In the foreground** (development):

```bash
cd engine
uv run autoapplyd --no-scheduler                        # real Claude via your `claude` login
AUTOAPPLY_LLM_PROVIDER=fake uv run autoapplyd \
    --home /tmp/aa-dev --no-scheduler                   # scratch home, no LLM calls at all
```

With the fake provider every LLM call either uses a scripted answer or fails, so nothing is
generated.

**As a LaunchAgent** (normal use). It starts at login and restarts if it crashes:

```bash
cd engine
uv run python -m autoapply.launchd_install install      # also: status | restart | uninstall | print
```

Settings ▸ Agent in the app can install, restart and uninstall it too. The agent's label is
`com.autoapply.daemon` and its logs go to `<home>/logs/`. It runs 09:00, 13:00 and 18:00 by
default (editable in Settings ▸ Schedule). A run missed while the Mac was asleep fires once on
wake.

**Developer CLI**: it works on the same database, so stop the daemon first or point it at another
`AUTOAPPLY_HOME`.

```bash
cd engine
uv run python -m autoapply.cli init --help
uv run python -m autoapply.cli watch add "Acme" https://boards.greenhouse.io/acme
uv run python -m autoapply.cli discover          # public Greenhouse / Lever / Ashby boards (read-only GETs)
uv run python -m autoapply.cli score
uv run python -m autoapply.cli status --queue
uv run python -m autoapply.cli apply 12          # DRY RUN: fills the form, never clicks submit
uv run python -m autoapply.cli apply 12 --submit # a real submit, asks for confirmation first
```

## Running the app

**Mock mode** needs no daemon. A built-in mock daemon plays scripted scenarios against an
in-memory database:

```bash
cd app
AUTOAPPLY_MOCK=happyRun swift run AutoApply
AUTOAPPLY_MOCK=reviewMode AUTOAPPLY_MOCK_SPEED=4 swift run AutoApply
```

Scenarios: `idle`, `happyRun`, `needsYouStorm`, `reviewMode`, `daemonDown`, `loginExpired`,
`capReached`, `firstRunEmpty`, `burstSubmit`, `stress` (5,000 jobs), `onboarding`. `AUTOAPPLY_MOCK=1`
means `happyRun`. In Xcode, set the variable in the scheme's Run ▸ Environment, or pass
`-AUTOAPPLY_MOCK <scenario>` as a launch argument. In Debug builds a **Debug** menu switches
scenario and speed at runtime and can simulate Reduce Motion.

**Live mode** is a plain launch with no `AUTOAPPLY_MOCK`. The app connects to
`<AUTOAPPLY_HOME or ~/Library/Application Support/AutoApply>/autoapplyd.sock`, reconnects with
backoff and re-reads the DB whenever the daemon writes to it. On first launch, onboarding walks
through the system check, resume upload and parse, preferences, never-guess facts, stories,
sources (optional LinkedIn and Glassdoor login in the agent's Chrome) and the Auto/Review mode.

To run app and daemon against a scratch home, give both the same `AUTOAPPLY_HOME`:

```bash
export AUTOAPPLY_HOME=/tmp/aa-dev
(cd engine && AUTOAPPLY_LLM_PROVIDER=fake uv run autoapplyd --no-scheduler) &
(cd app && swift run AutoApply)
```

## Tests

```bash
cd engine && uv run pytest -q                    # everything (~1,460 tests)
cd engine && uv run pytest tests/e2e -q          # end-to-end smoke (below)
cd app && swift test                             # ~560 Swift Testing tests
```

Tests never touch the network or a real LLM, and never submit a real application. Board APIs are
mocked (respx), forms are local fixture pages on 127.0.0.1, and the LLM is `FakeLLMProvider`. The
only network tests are a few read-only board GETs, deselected by default (`uv run pytest -m network`).

`engine/tests/e2e/test_smoke.py` starts `autoapplyd` with the real pipeline on a temporary home
and talks to it over its Unix socket. It configures profile, preferences and resume, then calls
`run_now`:

1. Discovery runs the real Greenhouse source against mocked boards.
2. Scoring uses the fake LLM, and one job is hard-filtered.
3. In Prep, one job parks in `needs_you` on a low-confidence question.
4. Apply runs the real scripted adapter in headless Chromium against the local fixture form; the
   other job stops at `awaiting_review`.

The test then approves that job (`submitting` is committed before the local POST, then
`submitted`), answers the inbox question (`question_resolved`, then `needs_you → queued`), runs
apply again and approves the second job. It also spawns the real `python -m autoapply.daemon`
process and checks the socket permissions and the graceful SIGTERM.

## Environment variables

| Variable | Used by | Meaning |
|---|---|---|
| `AUTOAPPLY_HOME` | daemon, CLI, app | Data directory (default `~/Library/Application Support/AutoApply`). |
| `AUTOAPPLY_LLM_PROVIDER` | daemon | `agent_sdk` (default), `fake`, or `anthropic_api` (placeholder, not implemented yet). |
| `AUTOAPPLY_LOG_LEVEL` | daemon | `debug` / `info` (default) / `warning`. |
| `AUTOAPPLY_SUBMIT_ALLOWED_HOSTS` | scripted adapters | Only click submit on these hosts (comma-separated). The tests set it to `127.0.0.1,localhost`. |
| `AUTOAPPLY_MOCK`, `AUTOAPPLY_MOCK_SPEED` | app | Mock daemon scenario and speed. |
| `AUTOAPPLY_ENGINE_DIR` | app | Where `engine/` lives, for Settings ▸ Agent install/uninstall. |
| `AUTOAPPLY_SCHEMA_PATH` | app tests | Override the path to `contract/schema.sql`. |

## Project map

```
PLAN.md                     decisions, architecture, milestones
docs/UI_UX_PLAN.md          UI/UX spec
docs/COLD_EMAIL_PLAN.md     cold email design
OWNERSHIP.md                who owns which files
contract/
  schema.sql                SQLite schema (single source of truth)
  protocol.md               socket protocol + application state machine
  protocol.schema.json      GENERATED from engine/autoapply/models.py  (uv run python -m autoapply.models)
  protocol.examples.ndjson  GENERATED examples                        (uv run python -m tests.foundation.protocol_samples)
engine/                     Python 3.12, uv
  autoapply/
    daemon.py               socket server (NDJSON), snapshot, command handlers, lifecycle
    pipeline.py             Discover → Score → Prep → Apply, guardrails before begin_submit
    scheduler.py            run schedule, catch-up on wake, caffeinate, one run at a time
    db.py models.py config.py enums.py paths.py
    llm/provider.py         LLMProvider: AgentSDKProvider (default), FakeLLMProvider
    discovery/              greenhouse, lever, ashby, workday, smartrecruiters, workable, recruitee,
                            careers (+ watchlist), google_jobs, linkedin, glassdoor (read-only)
    scoring.py              hard filters + batched LLM match scores
    prep.py                 pre-run question harvest, inbox clustering, answer_cluster / skip_cluster
    apply/                  base (scripted machinery + runner), greenhouse, lever, ashby, agentic (Agent SDK + Playwright MCP)
    answers/                resolver, memory (local embeddings), guardrails, cover_letter, resume_picker, voice
    autonomy.py             earned per-site Auto suggestions
    site_accounts.py        job-site accounts (passwords in the Keychain)
    interview.py insights.py  interview prep packs, insights from your own outcomes
    liveness.py legitimacy.py closed-posting and posting-legitimacy checks
    mail/                   security-code reader (IMAP), reply watch, SMTP send
    outreach/               cold email: startups, prospects, contacts, referrals, drafts, sender
    easy_apply.py           drafted answers for manual LinkedIn Easy Apply
    cli.py                  developer CLI
    launchd_install.py      LaunchAgent install/uninstall/status
  scripts/gen_swift_messages.py   GENERATES app/.../Core/Protocol/Messages.swift
  tests/                    foundation, a_core, b_agent, d_daemon, e2e, evals, top-level unit tests
app/                        SwiftPM, SwiftUI, macOS 26+
  Sources/AutoApply/
    App/                    scenes, root view, sidebar, commands, palette host
    Core/                   daemon client (socket), GRDB repository, stores, router, registry, protocol (generated)
    DesignSystem/           tokens, motion, materials, components
    Mock/                   mock daemon + scenarios
    Features/               Onboarding, MenuBar, Dashboard, Board, JobDetail, ActivityLog, Inbox, Review,
                            EasyApply, ColdEmail, AddJob, Feedback, Profile (+ Story bank), Resumes,
                            Settings, Session, CommandPalette, EasterEggs
  Tests/AutoApplyTests/     store, client, repository, mock, onboarding, C2 feature tests
  Tests/C3/                 C3 feature tests
  scripts/                  make_app.sh, make_dmg.sh, make_icon.swift
launchd/com.autoapply.daemon.plist   template (launchd_install.py renders the real one)
```

When you change a protocol model in `engine/autoapply/models.py`, regenerate all three artifacts:

```bash
cd engine
uv run python -m autoapply.models
uv run python -m tests.foundation.protocol_samples
uv run python scripts/gen_swift_messages.py
```

## Troubleshooting

- **`autoapply` / `autoapplyd` fails with `ModuleNotFoundError: No module named 'autoapply'`.**
  macOS sometimes sets the hidden flag on the venv's editable-install `.pth` file, and Python 3.12
  skips hidden `.pth` files. Use `uv run python -m autoapply.cli` / `uv run python -m autoapply.daemon`
  from `engine/`, or clear the flag with `chflags nohidden engine/.venv/lib/python3.12/site-packages/*.pth`.
  The LaunchAgent and the app's installer are not affected because they set `PYTHONPATH`.
- **`swift test` fails at codesign with "resource fork, Finder information, or similar detritus".**
  Some sandboxes add extended attributes to build products. Build outside the repo:
  `swift build --build-tests --scratch-path /tmp/aa-build && swift test --skip-build --scratch-path /tmp/aa-build`.
- **The app shows "daemon unreachable".** Check `uv run python -m autoapply.launchd_install status`
  and `<home>/logs/autoapplyd.log`. Only one daemon can run per home (a lock file); a second one
  exits immediately.
