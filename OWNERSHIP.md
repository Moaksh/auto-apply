# File ownership map

Parallel workstreams edit **only** the files they own. Need a change in a file you don't
own? Don't edit it; request it (orchestrator `contract_change_requests`). Source of truth for
decisions: [`PLAN.md`](PLAN.md), [`docs/UI_UX_PLAN.md`](docs/UI_UX_PLAN.md),
[`contract/`](contract/).

## Shared foundation — READ-ONLY for all builders

Owned by the Foundation agent. Builders import/use these but never edit them.

| Path | What |
|---|---|
| `contract/schema.sql` | SQLite schema (single source of truth), schema_version = 1 |
| `contract/protocol.md` | Socket protocol + state machine (human spec) |
| `contract/protocol.schema.json` | **Generated** from `engine/autoapply/models.py` (`uv run python -m autoapply.models`) |
| `contract/protocol.examples.ndjson` | **Generated** one example per message type (`uv run python -m tests.foundation.protocol_samples`); decoded by both Python and Swift tests |
| `engine/pyproject.toml`, `engine/uv.lock`, `engine/.python-version`, `engine/README.md` | Dependencies (request additions) |
| `engine/autoapply/__init__.py` | Package root |
| `engine/autoapply/paths.py` | Application Support layout, `AUTOAPPLY_HOME` override |
| `engine/autoapply/enums.py` | Canonical enums (match schema CHECKs + protocol) |
| `engine/autoapply/config.py` | `Preferences`, `NeverGuess`, patch models, defaults |
| `engine/autoapply/models.py` | Row models, protocol payloads/envelope/codec, state machine table, schema generator |
| `engine/autoapply/db.py` | Connections, migrations, repositories, `transition()`, `begin_submit()`, `recover_after_crash()` |
| `engine/autoapply/llm/__init__.py`, `engine/autoapply/llm/provider.py` | `LLMProvider`, `FakeLLMProvider`, `AgentSDKProvider`, `AnthropicAPIProvider` |
| `engine/autoapply/{discovery,apply,answers}/__init__.py` | Subpackage markers |
| `engine/scripts/gen_swift_messages.py` | Swift codegen for Messages.swift |
| `engine/tests/__init__.py`, `engine/tests/conftest.py` | Shared fixtures: `autoapply_home`, `conn`, `fake_llm` |
| `engine/tests/foundation/` | Foundation tests (must keep passing) |
| `app/Package.swift`, `app/Package.resolved` | SwiftPM manifest (GRDB 7.x dependency) |
| `app/Sources/AutoApply/Core/Protocol/Messages.swift` | **Generated** Codable mirror of the protocol |
| `app/Sources/AutoApply/Core/Daemon/DaemonClient.swift` | `DaemonConnecting` protocol (the seam; implementations live elsewhere) |
| `.gitignore`, `OWNERSHIP.md` | Repo hygiene |

Interface stubs created by Foundation (signatures + docstrings + `NotImplementedError`) are
**owned by the workstream listed below**, which replaces the stubs with real code. Seams other
workstreams depend on — `discovery/base.py` (`Source`, `DiscoveredJob`), `apply/base.py`
(`Adapter`, `ApplyContext`, `FillResult`, `SubmitResult`) — may be extended by their owner (A)
but must stay backward compatible; breaking changes need an orchestrator request.

## Workstreams

### A — Engine core
- `engine/autoapply/discovery/{base,greenhouse,lever,ashby,careers}.py`
- `engine/autoapply/scoring.py`
- `engine/autoapply/apply/{base,greenhouse,lever,ashby}.py`
- `engine/autoapply/cli.py`
- `engine/tests/a_core/`
- `engine/tests/fixtures/ats/`

### B — Agent & answers
- `engine/autoapply/apply/agentic.py`
- `engine/autoapply/answers/*` (except `answers/__init__.py`)
- `engine/autoapply/prep.py`
- `engine/autoapply/easy_apply.py`
- `engine/tests/b_agent/`

### D — Daemon & LinkedIn
- `engine/autoapply/{daemon,scheduler}.py`
- `engine/autoapply/discovery/{linkedin,glassdoor}.py`
- `engine/autoapply/pipeline.py`
- `engine/autoapply/launchd_install.py`
- `launchd/`
- `engine/tests/d_daemon/` (incl. `test_guardrails.py`)

### C1 — Swift foundation
- `app/Sources/AutoApply/{App,Core (except Messages.swift & DaemonClient.swift protocol),DesignSystem,Mock}/`
- `app/Sources/AutoApply/Features/{Onboarding,MenuBar}/`
- `app/Tests/` (`app/Tests/AutoApplyTests/MessagesTests.swift` was seeded by Foundation; keep it passing)

### C2 — Swift dashboard & pipeline
- `app/Sources/AutoApply/Features/{Dashboard,Board,JobDetail,ActivityLog}/`
- `app/Tests/AutoApplyTests/C2/` (compiled by the `AutoApplyTests` target)

### C3 — Swift inbox & settings
- `app/Sources/AutoApply/Features/{Inbox,Review,EasyApply,Profile,Resumes,Settings,CommandPalette}/`
- `app/Tests/C3/` (its own `C3Tests` target in `Package.swift`)

### Integration (post-merge)
- `engine/tests/e2e/` — socket-level end-to-end smoke (`test_smoke.py`) and contract
  regression tests (`test_integration_contract.py`)
- `app/Tests/AutoApplyTests/IntegrationCommandsTests.swift`
- `README.md`

## Conventions for builders

- Python tests: `cd engine && uv run pytest tests/<your dir> -q`. Put an empty `__init__.py`
  in your test dir (tests are packages; avoids module-name clashes). Use the shared fixtures
  (`conn`, `autoapply_home`, `fake_llm`). Never call the real Agent SDK, never hit the network
  in tests (mark smoke checks `@pytest.mark.network`; they're deselected by default).
- All application state changes go through `db.transition()` (never `UPDATE applications SET state`).
  Submits: guardrails -> `db.begin_submit()` -> click -> `db.complete_submit()`.
- Protocol messages: build with `models.make_event` / `models.make_command`, parse with
  `models.decode_line`, write with `Envelope.to_line()`.
- Swift: `cd app && swift build`. `swift test` inside this repo currently fails at the
  test-bundle codesign step (sandbox adds `com.apple.provenance` xattrs under `.build`); run
  `swift test --scratch-path <dir outside the repo>` instead, e.g. a temp dir.
- Swift types for protocol payloads come only from `Messages.swift` (regenerated, never hand-edited).
