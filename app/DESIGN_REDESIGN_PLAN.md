# AutoApply UI redesign plan (Rams audit 2026-10-22 → REDESIGN)

Goal: feel like Apple's own macOS 26 apps. Quiet content, glass only on the floating control
layer, one obvious primary action per screen, plain words, nothing moving at rest.
Keep: ink / stone / deep-green palette, 4pt spacing, Typography, Motion.resolve + `\.motionReduced`,
the primary flows and every keyboard shortcut.

## 1. Design system (`DesignSystem/`)

| Component | Replaces | Rule |
|---|---|---|
| `Surface` (view) + `.surface()` | `Card`, `KPICard`, `surfaceCard`, `brandHeroBand` on content, ad-hoc `.background(X, in:)` cards, LiveAgent mesh | `Palette.surface` + 0.5 hairline, radius 8, no shadow, no tint, no glow. Optional eyebrow title, trailing accessory, `SurfaceState` (content/loading/empty/error). |
| `.well()` | `sunkenWell`, ad-hoc sunken capsules | Sunken stone for inputs, quotes, screenshots, logs. |
| `ScreenHeader` | ≥10 header kinds | Title (title1), one plain summary line, optional trailing slot (filters, the screen's one action). |
| `Badge` | `StatusChip`, `ScorePill`, `ProvenanceTag`, BETA pill, ATS capsules, one-off capsules | Symbol + text on `sunken` capsule; tones: neutral / status / accent / warning. Full site names. |
| `EmptyState` / `LoadingState` / `ErrorState` | 6 empty styles, prominent brand-band empty state, `InlineError` | One calm style: symbol, title, one line, ≤1 action (PrimaryPill only in a first-run state, else SecondaryLink). `ErrorState(compact:)` covers inline widget errors. |
| `PrimaryPill` (`.buttonStyle(.primaryPill)`) | `.glassProminent` / `.borderedProminent` in content (30) | Ink pill / white pill (`primaryFill` / `onPrimaryFill`). At most one visible per screen. |
| `SecondaryLink` (`.buttonStyle(.secondaryLink)`) | `.glass` buttons in content (54), most `.link` | Text-only action in `Palette.link`; system `.bordered` stays for plain secondary buttons. |
| `SelectableRow` | 4 selected-row highlight copies | Row with hover / focused / selected background (accent 12%), consistent padding + radius. |
| `GlassBar` | `BulkActionBar` shell, glass capsules, `PausedCapsule` | The only in-window floating glass: bulk bars, toasts, paused capsule. |

Tokens: `textTertiary` → ≥4.5:1 on surface / sunken / window in both modes; add `onAccent`
(ink on the dark-mode accent); `skipped` / `ghosted` inks ≥3:1. `Radius.inner` → 6 so concentric
radii mean something. Remove unused tokens/shadows. Brand field: static unless the agent runs and the
window is visible. No `.breathe`. Menu-bar glyph honours Reduce Motion.

Prominence audit: `PrimaryPill` reports to an optional `ProminenceAudit` in the environment, so a
render test can assert ≤1 prominent action per primary screen. No `.glassProminent` /
`.borderedProminent` may remain in `Sources` (lint test).

## 2. Screens (single primary action · states)

| Screen | Change | Primary | States |
|---|---|---|---|
| Shell | Toolbar: Add job, **Run menu** (Run now · Collect questions · Apply queued), Pause, Auto/Review, Search, More, Details. Sidebar: plain labels, no BETA pill, agent pill without breathing. Inspector: system `.inspector` glass column look (no custom material/shadow/radius 14). Mode popover only switches mode, with Cancel. | — (toolbar) | paused hairline, disconnected |
| Dashboard | Flat header (date, greeting, next-run · mode), no brand band. LiveAgent on `Surface`, no mesh, no Run button except first-run empty state; static flow when idle. KPI tiles = `Surface`. Daemon-down shown once (hero). | first run only: "Run now" | first-run, loading, idle, running, paused, cap, unreachable |
| Needs You | `ScreenHeader` ("Needs You", "N questions · M jobs waiting"), question shown once, Collect questions moved to Run menu/⌘K, `SelectableRow`, wells. | Answer / Done, try again | empty (all clear), loading, error (disconnected), selected, focus |
| Review | `ScreenHeader`, `SelectableRow`, GlassBar bulk bar; per-job Approve is the one pill; "Mode: inherit" → "Uses app setting". | Approve & submit | empty, loading, disconnected, flagged, in-flight |
| Pipeline | `ScreenHeader`; board empty state no longer runs a full apply (opens Run menu copy); badges full names; disabled while disconnected. | none (drag/drop) | empty, loading, disconnected (disabled), focus |
| Job detail | One action row; hidden zero-size buttons replaced by real `.keyboardShortcut` on visible buttons; Q&A "Answer log"; tokens/pick behind "Technical details" disclosure. | state-dependent single pill (Approve / Answer / Mark applied) | loading, error, each job state |
| Settings | Plain rows, no glass; Guardrails gets explicit **Create accounts on job sites for me** toggle; mailbox rows show the toggle + one-line consequence next to the connect form; defaults shown plainly. | none (auto-save, honest) | invalid form (says "Not saved"), disconnected |
| Onboarding | Honest copy, static background, "Facts only you set", mailbox step shows account-creation toggle. | Continue | per-step validation, focus |
| Menu bar | No brand band; flat header; glyph honours Reduce Motion; Run in a menu only. | Open AutoApply | paused, disconnected |
| ⌘K | Glass panel stays (control layer); plain command names from the glossary. | Return runs selected | empty results |

## 3. Glossary (one name per concept)

| Use | Never |
|---|---|
| Needs You (questions and tasks for you) | Inbox, parked, Needs your input |
| Review (approve before sending) | Receipts |
| Pipeline | Board, tracker |
| Agent | autoapplyd, daemon, LaunchAgent, engine |
| Collect questions | Prep pass, Prepping |
| Facts only you set | never-guess, locked facts |
| Application site | ATS; badges show "Greenhouse", "Lever", "Ashby", "Workday" |
| Applied | Submitted, sent |
| Skip | Reject, Skip (reject) |
| Uses app setting | Inherit, Mode: inherit |
| Daily limit | cap, read budget |
| Waiting for you / back in the queue | resumed, parked |
| Stop switch → "Pause the agent" | kill switch |
| Answer log | Q&A audit |
| Technical details (disclosure) | Tokens · in/out, pick 0.83 |

Inflated → honest: "Let's get you hired." → "Set up your job agent."; "Everything stays on this
Mac." → "Your data stays on this Mac. Form text goes to Claude to draft answers; Gmail is read only
for codes."; "no invented facts" → "drafted from your profile and stories"; "jobs resumed" →
"jobs back in the queue"; Cold Email "Join beta" waitlist → removed (screen says it isn't built yet).

## 4. Commit order (no flag, no dual design)

1. Tokens + new primitives (Surface, Well, ScreenHeader, Badge, States, PrimaryPill, SecondaryLink, SelectableRow, GlassBar, ProminenceAudit).
2. Shell (toolbar Run menu, mode popover fix, sidebar, inspector, toasts).
3. Dashboard (+ widgets, LiveAgent, brand field static).
4. Needs You. 5. Review. 6. Pipeline. 7. Job detail.
8. Settings (+ account-creation disclosure). 9. Onboarding. 10. Menu bar. 11. ⌘K.
12. Secondary screens (Profile, Resumes, Story Bank, Activity, Easy Apply, Feedback, Cold Email honesty).
13. Delete `Card`, `KPICard`, `surfaceCard`, `sunkenWell`, `brandHeroBand`, `BulkActionBar` shell, `PressScaleStyle`, `SkeletonCircle`, `InlineError`, `AnyPrimitiveButtonStyle`; update tests; add the prominence + lint tests.

Cold Email is built next on this system by another agent, so step 1 lands first.

Account creation (owner decision): the `create_accounts` default stays on (engine, schema and
Swift defaults unchanged, no migration). The honesty fix is disclosure at the point of
consequence: wherever the inbox is connected (onboarding "Email inbox", Settings ▸ Sources) the
"Create accounts on job sites for me" toggle and a one-line explanation sit next to the form.
