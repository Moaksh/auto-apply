# Evidence

Paths are under `app/Sources/AutoApply/` unless stated otherwise. All visual facts are INFERRED from source; no running instance was driven.

## 4. Weight & friction (native adaptation)

- **Bundle:**
  - AutoApply.app is 28M; the binary is 26M; the bundled engine is 1.2M.
  - Messages.swift is 2911 lines.
- **Launch work:**
  - 1 timer: the 6 h updater.
  - 2 loops at 500 ms: the GRDB poll (`Core/Data/GRDBRepository.swift:26,47-55`) and the AppStore prune (`Core/Store/AppStore.swift:131-136`).
  - Up to 3 network/daemon calls.
  - A notification-permission prompt at launch (`AppNotifier.swift:23`).
  - 3 launch animations on the Dashboard: entrance stagger, count-up, accent glow (`Features/Dashboard/DashboardView.swift:99-115,220-227`).
- **Idle continuous animations on the Dashboard and menu bar: 4.**
  - BrandGradientField mesh at ≤20 fps, on the Dashboard header and the menu-bar header. It runs **even when the agent is idle**; gated by visibility and Reduce Motion (`DesignSystem/Components/BrandGradient.swift:23`, `DashboardView.swift:31`, `MenuBarExtraViews.swift:76`).
  - AgentStatusDot `.breathe` repeating, *not visibility-gated* (`DesignSystem/Components/AgentPill.swift:65`).
  - LiveAgentCard clock `.breathe` (`LiveAgentCard.swift:101`).
  - Plus a 15 s / 300 s header TimelineView (`DashboardView.swift:158`).
  - The menu-bar glyph pulse ignores Reduce Motion (`MenuBarExtraViews.swift:29`).
- **Attention on first open (up to):**
  - 3 sidebar badges plus a BETA pill (`App/SidebarView.swift:36-65`).
  - 1 issue banner.
  - A duplicate "Daemon down" chip (`DashboardView.swift:153`), alongside the hero error "Can't reach autoapplyd" (`LiveAgentCard.swift:250-256`). That is 3 surfaces for one fact.
  - Up to 2 toasts.
  - The permission prompt.
  - An update notification.
- **Navigation weight:**
  - 10 sidebar items in 3 sections.
  - 6 toolbar controls: Add job, Run (a split menu with 3 items), Pause, the Auto/Review segment, Search, More (5 items), Details (`App/RootView.swift:103-196`).
  - 8 Settings tabs.
  - 23 palette actions, 24 settings deep-links and about 30 shortcuts.
  - 6 scenes.

## 3. Copy & honesty

### Inflations (14)

| Claim | Where | Problem |
|---|---|---|
| "Let's get you hired." | `Onboarding/Ignition/IgnitionView.swift:58` | Promises an outcome the app can't deliver |
| "only with facts you approve" | `IgnitionView.swift:190` | Balanced, the default, lets medium-confidence generated answers through (`SettingsTabs.swift:178`) |
| "Everything stays on this Mac." | `IgnitionView.swift:203` | Claude, Gmail IMAP and GitHub update checks all leave the Mac |
| "no invented facts" | `JobDetail/QATable.swift:179` | Unverified absolute |
| "the agent stops and asks" | `SettingsTabs.swift:153` | Absolute, while drafts auto-fill |
| "jobs resumed" / "the application resumes" | `InboxModel.swift:560`, `Celebration.swift:116`, `InboxView.swift:47`, `JobQuestionsPane.swift:24` | Jobs only go back to Queued |
| Cold Email marketing copy | `ColdEmail/ColdEmailView.swift:46,58,62` | Describes an unbuilt feature |

### Dark patterns and risky defaults

- **Defaults that act without asking**
  - `create_accounts` defaults to **true**. Connecting the onboarding "Security codes (optional)" mailbox silently enables account creation (`FinishSteps.swift:59`, `SettingsTabs.swift:690`).
  - Save-to-memory is on by default (`InboxModel.swift:53`).
  - Auto-install updates is on by default (`SettingsView.swift:191`).
  - "Include logs" is on by default (`FeedbackView.swift:18`); mitigated by a preview.
- **The mode-switch popover**
  - Its prominent "Approve N" skips the low-confidence safeguard and the per-company split (`App/RootView.swift:155-162,212` vs `ReviewModel.swift:250-262`).
  - It has no Cancel.
  - "Keep in Review" still switches mode.
- **Fake exclusivity:** Cold Email "Join beta" only sets a local bool, yet promises "We'll turn it on for you first" (`ColdEmailView.swift:14,127-130`).
- **Undo**
  - Approve, the irreversible action, has no undo window (`ReviewModel.swift:280`).
  - The answer undo toast can be queued behind other toasts while its 10 s send timer is already running (`ToastCenter.swift:39-46` vs `InboxModel.swift:539`).

### Jargon (about 25 terms)

- "Prep pass" / "Prepping" (around 8 sites)
- "Never-guess"
- "ATS" / "Per ATS" / "GH/LV/AB/WD/EA" badges (`StateMachine.swift:129`)
- "Inherit" / "Mode: inherit"
- "autoapplyd" / "daemon" / "LaunchAgent" / "Engine folder … pyproject.toml"
- "parked"
- "Tokens · N in · M out"
- "pick 0.83"
- "Q&A audit"
- "Step ticker"
- "Read budgets" / "sessions / day" / "reads"
- "Receipts"
- "variants:"
- "kill switch"
- "Skip (reject)"
- A developer placeholder: "JobDetailView is provided by workstream C2." (`ScreenRegistry.swift:188`)

### Label → behaviour mismatches (12)

- **Board empty-state "Run now"** does a full apply run and isn't paused-gated (`BoardView.swift:175`).
- **"Run discovery now"** also submits applications (`AppAction.swift:66`).
- **"Changes save automatically"** isn't true while the form is invalid (`SettingsModel.swift:204`).
- **"Review, then Save."** — there's no Save button (`SettingsTabs.swift:27`).
- **Nudge "Not yet"** is an empty closure (`JobCard.swift:97`).
- **The same resolve action has two label sets:** "It was submitted" (`JobDetailModel.swift:56`) and "It was sent" (`:95`).
- **"Apply anyway"** queues for the next run, while drag-to-Queued applies now.

### One concept, many names

| Concept | Names | Example sites |
|---|---|---|
| Questions waiting on the user | 9 | Needs You / Inbox / parked / Needs your input / … |
| The background process | 7 | agent / autoapplyd / daemon / LaunchAgent / engine / … |
| A submitted application | 4 | Applied / Submitted / sent / submitted |
| The jobs list | 4 | Pipeline / Board / Pipeline board / tracker |
| Skipping | 5 | Skip / Skip (reject) / Skip / Reject / … |
| Locked facts | 4 | |
| The daily limit | 4 | |

## 2. Visual system and accessibility (INFERRED)

### Spacing
- Tokens follow a 4pt grid (`DesignSystem/Tokens.swift:179-195`). Most calls use them: 229 of 293 `.padding(` and 382 `spacing:`.
- Raw `spacing:` literals: 85, some off-grid (1, 3).
- Raw padding literals: about 56. Values include 1, 2, 3, 5, 6, 7.25, 80 and 90 (e.g. `StepRail.swift:43`, `CommandPaletteHost.swift:26`, `ReviewView.swift:122`).
- Raw `.frame` literals: 230, including five different label-column widths (84 / 120 / 150 / 170 / 220).

### Type
- 13 tokens, well used (callout 209, body 97).
- 21 raw `.font(.system(size:))` calls, with sizes 7 / 8 / 9 / 10 / 13 / 18 / 22 / 24 / 28 / 30 / 32 / 40 / 56.
- 7 bold weights despite "no heavy bold" (`Tokens.swift:130`).
- 108 uses of 10.5pt mono eyebrow / monoSmall text.

### Color
- About 32 semantic tokens and 11 brand swatches.
- **The ink/white pill system is defined but unused:** `primaryFill` and `onPrimaryFill` have 0 uses, as do `link`, `focus`, the washes, `stone` and `coralSoft`. `coral` is used once.
- Prominent buttons all use `.glassProminent` tinted with the accent (`App/AutoApplyApp.swift:96`).
- 55 `.opacity()` stacks on tokens; accent alone has 18 alpha steps.
- Two competing greens: brand 0x0F5C4F and applied 0x2F8F46. Status hues add blue, pink, mustard and steel.

### Radii
- `card` == `inner` == 8, so the concentric rule is a no-op.
- 26 raw radii (1, 1.5, 2, 3, 4, 5, 6, 14), 7 of them not `.continuous`.
- The Dashboard alone mixes 22 / 8 / 6 / 3 / 2 and capsules.

### Depth and glass
- 4 drop shadows, against "flat by design" (`Materials.swift:16`).
- The inspector uses its own system (`App/RootView.swift:241-245`): the only `.regularMaterial`, radius 14, a 0.35 black shadow and a `.separator` stroke.
- About 81 glass buttons (55 `.glass`, 24 `.glassProminent`), most inside **content cards**:
  - `LiveAgentCard.swift:143-159`, `KPIWidgets.swift:58`, `ScoreHistogram.swift:78`, `SettingsTabs.swift:468,511`
  - Job detail, Inbox, Inspector, Profile and Story Bank
  - A glass tooltip inside a card (`ApplicationsChart.swift:55`)
  
  This contradicts the system's own rule: "glass is for the navigation/control layer, never content" (`Materials.swift:1`).

### Contrast
- Primary text is fine (≥9.7:1).
- **`textTertiary`, used 131 times, is below 4.5:1 on every surface in both modes** (2.55–3.75).
- **White on the dark-mode accent (prominent buttons) is 2.88:1.**
- `needsYou` coral in light mode is 3.44:1 on sunken / window.
- `ghosted` and `skipped` status inks are 1.7–2.6:1.

### States
- Inbox: no loading state, no screen-level error.
- Review: no screen-level loading or error.
- Board: no disabled state.
- Dashboard, Settings and Onboarding steps: no focus handling.

### Accessibility
- Every primary action is keyboard-reachable: approve, answer, run, pause, move status.
- The system focus ring is turned off on 7 containers, and the `focus` token is unused.
- 12 of 35 icon-only buttons have no explicit `accessibilityLabel`.
- Reduce Motion is centralised (57 references) but ignored in about 9 places, including the menu-bar glyph.

### Motion
- About 220 motion sites in total: 61 transitions, 30 symbolEffects, 12 TimelineViews, 10 Canvas.
- Continuous animation on idle screens:
  - the brand mesh at 20 fps on the Dashboard, menu bar and prominent empty states
  - the sidebar status dot's breathe (on every screen)
  - the clock / moon breathe
  - onboarding mode animations

## 1. Structural

### Interactive elements (default state)

| Screen | Count | Source |
|---|---|---|
| Shell | 18 | toolbar 7, sidebar 11 |
| Dashboard | 11–18 | |
| Needs You | 5 + rows, up to +11 | |
| Review | 5 + 2×rows + edits, plus a 3-button bulk bar | |
| Pipeline | 6 header controls + 8 columns | |
| Job detail | 5–9+ | 2 hidden zero-size shortcut buttons (`JobDetailView.swift:332,340`) |
| Settings | 8 tabs | Preferences alone has 20–57 controls |
| Menu bar | 4–6 | |

### Nesting depth

| Screen | Depth | Deepest point |
|---|---|---|
| Dashboard | 11 | `VariantChart.swift:31` |
| Needs You | 12 | `InboxView.swift:766` |
| Review | 11 | |
| Board | 10 | |
| Job detail | 13 | `JobDetailView` → `JobQuestionsPane` → `InboxView.swift:766` |

### Repeated patterns

- **Run now:** 6 call sites, plus ⌘K.
- **Prep pass:** 5. Pause: 5. Open agent Chrome: 4. Apply queued: 4.
- **Approve:** 8+ UI entry points (`RootView.swift:159`, `ReviewView.swift:134,182,205,219,357`, `JobDetailView.swift:340,369,443`, `AppAction.swift:24`). The confirm / skip-reason UI is built twice (`ReviewView.swift:195-233` vs `JobDetailView.swift:428-455`).
- **Skip:** 5 paths.
- **Badges:** 4 badge components plus ≥12 one-off capsules.
- **Headers:** ≥10 header kinds. The question text renders twice, as eyebrow and as title2 (`InboxView.swift:379,388`).
- **Empty states:** 6 styles.
- **Selected-row highlight:** 4 copies.

### Surfaces

9 kinds:
- `surfaceCard` (21)
- `Card` (8, plus `KPICard` with its own glow)
- `sunkenWell` (22)
- 51 ad-hoc `.background(X, in:)`
- `glassEffect` (5)
- `glassPanel` (3)
- `glassCapsule` (4)
- the inspector `.regularMaterial` (1)
- `brandHeroBand` (4)
- a `MeshGradient` card (1, `LiveAgentCard.swift:263`)

### Buttons

- 7 styles plus default plus custom: `.glass` 55, `.glassProminent` 24, `.borderless` 32, `.plain` 28, `.link` 26, `.borderedProminent` 6, `.bordered` 6, plus PressScale and AnyPrimitive.
- **4 of 8 screens can show more than one prominent button at once:** Dashboard, Needs You, Review and Job detail.

### Dead code

- `SkeletonCircle` is unused.
- 6 unused tokens: `primaryFill`, `onPrimaryFill`, `coralSoft`, `Radius.concentric`, `inspectorMin`, `inspectorMax`.
- 3 unused properties (`IssueBannerView.swift:7`, `SidebarView.swift:8,11`).
- 1 unused import (`ResumesView.swift:6`).
- 1 unused function (`PreferenceSteps.swift:137`).
