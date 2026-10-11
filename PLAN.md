# AutoApply — Plan

Personal, local-only macOS app that discovers jobs, applies on the user's behalf, asks the user only when it truly lacks knowledge, and tracks everything.

UI/UX spec lives in [`docs/UI_UX_PLAN.md`](docs/UI_UX_PLAN.md).

---

## 1. Decisions log (from grilling session, 2026-10-10)

| # | Topic | Decision |
|---|---|---|
| 1 | Audience | Personal tool on own machine with own creds; possibly shared build with one friend for testing. All data local. |
| 2 | LLM | Claude Agent SDK (Python), using the machine's existing `claude` CLI login. No BYOK for now. Behind an `LLMProvider` abstraction so an API key can be swapped in with one setting. |
| 3 | Browser | Playwright MCP (agentic, unknown forms) + scripted Playwright (known ATS). Dedicated persistent Chrome profile; user logs into LinkedIn/Glassdoor once inside it. No passwords stored. |
| 4 | Discovery | LinkedIn + Glassdoor **read-only** (human pace, visible browser) + Greenhouse / Lever / Ashby public job boards + company career pages. |
| 5 | Applying | Only on company ATS. **No LinkedIn Easy Apply automation.** Easy Apply jobs → "Manual – Easy Apply" list with link + pre-drafted copy-paste answers. |
| 6 | Autonomy | Global `Auto` (default) / `Review` mode, with per-ATS and per-job overrides. |
| 7 | Unknown questions | Park job + notify + continue pipeline (B), **and** a pre-run Prep pass that batch-collects questions (C). Inbox clusters semantically equivalent questions; answers saved to memory. |
| 8 | Resume / cover letter | User uploads N approved resume variants; agent picks per job. Cover letters generated per job from profile + story bank facts only. No per-job resume rewriting. |
| 9 | Tracker | Post-apply statuses updated **manually** (drag-drop board). Auto-`Ghosted` after 21 days; "Did you hear back?" nudges at day 7 and 14. No email reading. |
| 10 | Runtime | Background **LaunchAgent** daemon (`autoapplyd`), app is dashboard + menu bar. |
| 11 | Preferences | Collected in animated first-launch onboarding; all editable in Settings. |
| 12 | Build strategy | All workstreams in parallel against a frozen contract (schema + socket protocol). |

---

## 2. Architecture

```
┌──────────────────────┐   Unix socket (NDJSON)  ┌──────────────────────────────────────┐
│ AutoApply.app        │ ◄─────────────────────► │ autoapplyd  (Python, user LaunchAgent)│
│ SwiftUI              │   commands ↓  events ↑  │                                      │
│ • onboarding         │                         │  Scheduler ─► Pipeline               │
│ • dashboard / board  │                         │    Discover → Score → Prep → Apply   │
│ • needs-you inbox    │                         │  Adapters: greenhouse, lever, ashby, │
│ • review queue       │                         │            workday(agent), generic   │
│ • settings           │                         │  Agent: claude-agent-sdk + PW MCP    │
│ • MenuBarExtra       │                         │  Guardrails, caps, kill switch       │
└─────────┬────────────┘                         │  SOLE writer → SQLite (WAL)          │
          │ read-only (GRDB)                     └──────────────────────────────────────┘
          ▼
~/Library/Application Support/AutoApply/
  autoapply.db   resumes/   screenshots/   cover_letters/   chrome-profile/   logs/   autoapplyd.sock
```

Rules:
- **Daemon is the only DB writer.** App reads via GRDB; all mutations (answers, card moves, settings) are socket commands.
- **Daemon runs without the app.** App connects/disconnects freely; on connect it receives a `snapshot` event.
- **Visible Chrome** for LinkedIn/Glassdoor; headless allowed for ATS adapters.
- Requirements checked at first launch: `claude` CLI logged in, `uv`, Node (for `npx @playwright/mcp`).

### Privacy boundary
Local: DB, files, credentials, browser profile. Sent to Claude: resume/profile text, job descriptions, form questions, generated answers. Nothing else leaves the machine.

---

## 3. Repo layout

```
auto_apply/
  PLAN.md
  docs/UI_UX_PLAN.md
  contract/
    schema.sql              # single source of truth for DB
    protocol.md             # socket commands/events
    protocol.schema.json    # JSON Schema; codegen for Swift + Python types
  engine/                   # Python, uv-managed
    pyproject.toml
    autoapply/
      daemon.py             # socket server, lifecycle, snapshot
      scheduler.py
      db.py                 # migrations, repo layer
      config.py             # prefs model (pydantic)
      llm/provider.py       # LLMProvider: AgentSDKProvider (default), AnthropicAPIProvider
      discovery/{greenhouse,lever,ashby,linkedin,glassdoor,careers}.py
      scoring.py
      prep.py               # pre-run question harvest
      apply/
        base.py             # Adapter protocol + state machine
        greenhouse.py lever.py ashby.py
        agentic.py          # Playwright MCP fallback (Workday, unknown)
      answers/
        memory.py           # Q→A store + semantic matching
        guardrails.py       # never-guess fields, confidence gate
        cover_letter.py
        resume_picker.py
      easy_apply.py         # drafts copy-paste answers
      cli.py                # `autoapply run|discover|status|answer` for dev/testing
    tests/
  app/                      # Xcode project, SwiftUI, macOS 26+
    AutoApply/
      Core/ (SocketClient, DB (GRDB), Models generated from contract)
      Features/ (Onboarding, Dashboard, Board, Inbox, Review, EasyApply, Profile, Settings, MenuBar)
      DesignSystem/
    Mock/                   # mock daemon event stream for UI dev
  launchd/com.autoapply.daemon.plist
```

---

## 4. Contract (freeze first — everything builds against it)

### 4.1 Core tables (`contract/schema.sql`)
- `profile` — single row: structured resume facts, contact, links.
- `never_guess` — key/value: work_auth per country, sponsorship, salary_expectation, notice_period, start_date, relocation, eeo_* defaults.
- `preferences` — roles, seniority, locations, remote policy, salary_floor, excludes (companies/industries/keywords), daily_cap, per_company_cooldown_days (30), match_threshold (70), mode, per_ats_mode JSON, schedule.
- `resume_variants` — id, label, file_path, tags, embedding.
- `stories` — STAR stories, competency tags.
- `answers` — canonical_question, answer, embedding, source (user/generated), uses, updated_at.
- `companies` — name, domain, ats, last_applied_at.
- `jobs` — id, source, source_url, apply_url, ats, company_id, title, location, remote, salary_min/max, description, discovered_at, dedupe_key (UNIQUE).
- `scores` — job_id, score, reasons JSON, skip_reason.
- `applications` — job_id, state, mode, resume_variant_id, cover_letter_path, screenshot_path, submitted_at, status (manual board status), status_updated_at, nudges_sent.
- `application_answers` — application_id, question, answer, confidence, origin (memory/profile/generated/user).
- `questions` (needs-you inbox) — id, canonical_question, cluster_id, job_ids, field_type, options, status (open/answered), answer_id.
- `easy_apply` — job_id, url, drafted_answers JSON, done.
- `events` — append-only activity log.

### 4.2 Application state machine
```
discovered → scored ─┬─ skipped(reason)
                     └─ queued → prepping → needs_you ⇄ queued
                                  → filling → awaiting_review (Review mode)
                                  → submitting → submitted
                                  → failed(reason) | unknown_verify
```
- `submitting` is written **before** clicking submit. Crash during `submitting` → `unknown_verify`, **never retried automatically** (no double applies).
- Board statuses (manual): `applied, assessment, interview, offer, rejected, ghosted`.

### 4.3 Socket protocol (NDJSON over `autoapplyd.sock`)
Commands (app → daemon): `hello`, `run_now`, `pause_all`, `resume`, `answer_question{cluster_id, answer, save_to_memory}`, `approve{application_ids}`, `reject{application_id, reason}`, `set_status{application_id, status}`, `update_preferences{…}`, `add_resume_variant`, `mark_easy_apply_done`, `onboarding_*`.
Events (daemon → app): `snapshot`, `state{daemon: idle|discovering|scoring|prepping|applying, progress}`, `job_discovered`, `job_scored`, `application_state`, `question_opened`, `question_resolved`, `agent_step{application_id, action, screenshot_thumb?}`, `cap_reached`, `error`, `log`.
Every message: `{ "v": 1, "id": "...", "type": "...", "payload": {...} }`.

---

## 5. Engine design notes

**Discovery**
- Greenhouse: `boards-api.greenhouse.io/v1/boards/{token}/jobs?content=true`; questions via `/jobs/{id}?questions=true`.
- Lever: `api.lever.co/v0/postings/{company}?mode=json`. Ashby: public job board API.
- Company watchlist (user-editable) maps company → ATS + board token; auto-detected from apply URLs found on LinkedIn/Glassdoor.
- LinkedIn/Glassdoor: visible Chrome, logged-in profile, ≤3 short sessions/day, randomized delays, read listing pages only, extract apply URL. Easy Apply listings → `easy_apply` table.
- Dedupe by normalized (company, title, location) + apply URL.

**Scoring**: hard filters first (location, auth, salary floor, excludes, seniority keywords, cooldown, caps) → LLM match score 0–100 with reasons, only for survivors. Batch to save tokens.

**Prep pass**: for queued jobs, harvest form questions (API for GH/Lever, browser scan for others) → resolve against profile / never_guess / answer memory → unresolved go to `questions`, clustered by embedding similarity.

**Apply**
- Known ATS → scripted Playwright fills standard fields deterministically; LLM only for free-text.
- Unknown/Workday → `agentic.py`: Agent SDK + Playwright MCP, with tools exposed to the agent: `get_profile`, `lookup_answer`, `ask_user` (parks job), `pick_resume`, `write_cover_letter`, `request_submit`. The agent cannot click submit directly; `request_submit` routes through guardrails + mode.
- Full-page screenshot + all Q&A recorded before submit.

**Guardrails**
- Never-guess fields resolved only from `never_guess`; missing → `ask_user`.
- Confidence < threshold on generated answers → `ask_user`.
- Caps + cooldown enforced in daemon right before `submitting`.
- `pause_all` checked between every step.
- Cover letters: prompt restricted to profile + stories + JD; no invented facts.

**Token budget**: prefer scripted adapters; trim Playwright MCP snapshots; cache JD scoring; log tokens per application to dashboard.

**Scheduler**: LaunchAgent `KeepAlive` + internal schedule (default 09:00/13:00/18:00). Missed runs fire on wake. `caffeinate -i` during runs.

---

## 6. Workstreams (built in parallel)

| WS | Scope | Depends on |
|---|---|---|
| **0. Contract** | `schema.sql`, `protocol.md`, JSON Schema, codegen for Swift/Python types | — (do first, ~day 1) |
| **A. Engine core** | db, config, discovery (GH/Lever/Ashby), scoring, GH/Lever/Ashby adapters, state machine, CLI | 0 |
| **B. Agent & answers** | LLMProvider, agentic adapter + tools, answer memory + clustering, guardrails, prep pass, resume picker, cover letters, Easy Apply drafts | 0, A's db |
| **C. Swift app** | per `docs/UI_UX_PLAN.md`; built against `app/Mock` event stream, then real socket | 0 |
| **D. Daemon & LinkedIn** | socket server, snapshot, LaunchAgent plist + install/uninstall from app, scheduler, caffeinate, LinkedIn/Glassdoor discovery | 0, A |

Integration milestones:
1. **M1** — CLI submits a real Greenhouse application end-to-end (A).
2. **M2** — App onboarding writes prefs via socket; dashboard shows live events from daemon (C + D).
3. **M3** — Unknown question parks job, appears in app inbox, answer resumes it (B + C + D).
4. **M4** — Scheduled background run with LinkedIn discovery, caps, Easy Apply list (D).

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| LinkedIn account restriction | Read-only, human pace, visible browser, low session count; never Easy Apply. |
| Subscription auth policy / limits | Personal use only; `LLMProvider` swap to API key; token-thrifty adapters. |
| Bad auto-submitted answers | Never-guess fields, confidence gate, audit trail, per-ATS Review override. |
| Double submission | `submitting` pre-write, `unknown_verify`, no auto-retry. |
| Anti-bot / CAPTCHA on ATS | Detect → park as `needs_you` ("solve CAPTCHA") and open the visible window. |
| Workday variability | Agentic adapter; default Workday to Review mode. |
| Spam reputation | Score threshold, 1/company/30d, daily cap. |

## 8. Open questions
- App name (AutoApply is a placeholder).
- Friend's build: same machine-local model, her own `claude` login — confirm acceptable under current Anthropic terms before sharing.
- Embeddings for answer clustering: local model (e.g. `sentence-transformers`) vs Claude-based canonicalization. Leaning local for zero token cost.
