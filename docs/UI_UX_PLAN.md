# AutoApply: UI/UX Plan

> Status: v1 design spec. It drives the SwiftUI implementation. Product decisions (architecture, autonomy, guardrails, tracker statuses) are settled; this doc decides **how it looks, moves and feels**.
>
> North star: *a calm instrument panel for an agent that works while you don't.* It should feel like it belongs next to Finder, Mail and Xcode, only more alive. Every pixel of motion has to earn its place by explaining something.

---

## 0. Design principles (the five rules)

1. **Calm by default, alive on change.** At rest the UI is still and quiet. Motion happens only when state changes: a job moves stage, a number ticks up, the agent needs you. Nothing loops "for vibes". The one exception is a slow "breathing" status glow that shows the agent is running, and it stops when the agent is idle.
2. **The agent is a colleague, not a slot machine.** Show what it's doing in plain sentences ("Filling *Stripe – Backend Engineer* · step 4 of 7 · answering 'Years with Go'"). Never hide autonomy behind spinners.
3. **One accent, many greys.** Color carries meaning (status, "needs you"), never decoration. If everything is colorful, nothing is urgent.
4. **Keyboard-first, mouse-beautiful.** Every action has a shortcut and appears in ⌘K. Pointer interactions still get hover states, drag physics and haptics.
5. **Trust through receipts.** Every automated action has an inspectable artifact: screenshot, Q&A, timestamp, reason. The UI makes receipts one click away, everywhere.

---

## 1. Design language

### 1.1 Platform target

- **macOS 26 (Tahoe) minimum**, built with the Xcode 26 SDK, so we get **Liquid Glass** natively. Newer OS APIs go behind `if #available`.
- Use system materials and standard components first (`NavigationSplitView`, `Table`, `Inspector`, toolbars, `MenuBarExtra`) so the app picks up glass, sidebars and window chrome for free. Custom drawing is only for the live viz and charts.
- **Glass is for the navigation and control layer, never for content.** Sidebar, toolbar, floating control clusters, the ⌘K palette, the menu bar popover and HUD toasts get glass. Cards, tables, the JD text and screenshots sit on solid or near-solid surfaces so they stay readable.

### 1.2 Typography

System fonts only. No custom typefaces. They render best on macOS and support Dynamic Type equivalents.

| Token | Font | Size / weight | Use |
|---|---|---|---|
| `display` | SF Pro Display | 34 / Bold, tracking −0.4 | Onboarding titles, inbox-zero headline |
| `title1` | SF Pro Display | 26 / Semibold | Screen titles (Dashboard, Inbox) |
| `title2` | SF Pro Text | 17 / Semibold | Card titles, section headers |
| `body` | SF Pro Text | 13 / Regular | Default macOS body |
| `bodyEmph` | SF Pro Text | 13 / Medium | Company names in lists |
| `callout` | SF Pro Text | 12 / Regular | Secondary lines, metadata |
| `caption` | SF Pro Text | 11 / Medium, uppercase, tracking +0.6 | Eyebrows ("TODAY", "PIPELINE") |
| `metricXL` | **SF Pro Rounded** | 44 / Semibold, `.monospacedDigit()` | Hero KPI numbers |
| `metric` | SF Pro Rounded | 22 / Semibold, `.monospacedDigit()` | Card KPI numbers, match scores |
| `mono` | **SF Mono** | 12 / Regular | Activity log, step ticker, URLs, raw Q&A keys, socket errors |
| `monoSmall` | SF Mono | 10.5 / Medium | Timestamps, durations ("00:42") |

Rules:
- **Rounded is reserved for numbers.** Scores, counts and caps use SF Rounded so they feel friendly and distinct from text. Everything else uses SF Pro.
- **Mono is reserved for what the machine says.** Log lines, ticker steps, URLs and timestamps. This builds a visual grammar: *mono = agent speaking, Pro = you / the app speaking.*
- All numbers that change use `.monospacedDigit()` and `.contentTransition(.numericText())` so widths don't jitter.
- Use semantic `Font.TextStyle` (`.title`, `.body`…) with the weights above so the app respects the system text-size setting (see §7).

### 1.3 Color system

One accent, a neutral ramp, and status hues. Everything is defined as semantic tokens in an asset catalog with Any/Dark and High Contrast variants. Views never use raw colors.

**Accent: "Signal Indigo"**
- Light `#4F5BD5`, Dark `#7C86FF`, High contrast light `#3A44B8`, High contrast dark `#A3AAFF`.
- Used for: primary buttons, selection, focus ring, the live pipeline's "active" particle, the "running" glow. Nothing else.
- We respect the user's system accent color if they've changed it from multicolor (`Color.accentColor`). Signal Indigo is the app's default `AccentColor`.

**Neutrals (semantic)**

| Token | Light | Dark | Notes |
|---|---|---|---|
| `bg.window` | system `windowBackgroundColor` | system | Window ground under glass |
| `bg.surface` | `#FFFFFF` | `#1C1C1E` | Cards |
| `bg.surfaceRaised` | `#FAFAFB` | `#242427` | Popovers on content, hovered cards |
| `bg.sunken` | `#F2F2F5` | `#141416` | Inputs, code/log wells, screenshot wells |
| `stroke.hairline` | black 8% | white 8% | 0.5pt card borders (1 device pixel on Retina) |
| `stroke.strong` | black 14% | white 14% | Dividers in dense tables |
| `text.primary` | `labelColor` | `labelColor` | |
| `text.secondary` | `secondaryLabelColor` | | |
| `text.tertiary` | `tertiaryLabelColor` | | Timestamps, placeholders |

**Status colors.** Each one is a hue plus an SF Symbol, so meaning never relies on color alone.

| Status | Token | Light / Dark | Symbol |
|---|---|---|---|
| Discovered | `status.discovered` | `#8E8E93` / `#98989F` | `sparkle.magnifyingglass` |
| Skipped | `status.skipped` | `#AEAEB2` / `#636366` (muted) | `arrow.uturn.right` |
| Queued | `status.queued` | `#5E9EFF` / `#6AA8FF` | `tray.full` |
| Filling (live) | `accent` | accent | `pencil.and.outline` |
| Needs you | `status.needsYou` | `#F5A524` / `#FFB940` | `hand.raised.fill` |
| Applied | `status.applied` | `#30B06E` / `#3CCB7F` | `paperplane.fill` |
| Assessment | `status.assessment` | `#A970FF` / `#B98BFF` | `doc.text.magnifyingglass` |
| Interview | `status.interview` | `#16A3B8` / `#2DC6DC` | `person.2.fill` |
| Offer | `status.offer` | `#E8B500` gold / `#FFD43B` | `star.fill` |
| Rejected | `status.rejected` | `#E5484D` at 70% sat / `#FF6369` | `xmark` |
| Ghosted | `status.ghosted` | `#C7C7CC` / `#48484A` | `moon.zzz` |
| Error | `status.error` | `#E5484D` / `#FF6369` | `exclamationmark.triangle.fill` |

Rules:
- Status color appears as an **8pt dot, symbol tint, or a 2pt leading bar**. It never fills a whole card. The only full-tint surface in the app is the "Needs you" banner, at 12% opacity.
- **Amber (Needs you) is the only "shouting" color.** Red is for errors and rejections only, and rejections are deliberately desaturated so the board doesn't feel like a wall of failure.
- **Chart palette:** charts use an indigo ramp (accent at 100/70/45/25%) for single-series data. Categorical data (sources, resume variants) uses a 5-step palette that shares the accent's luminance: Indigo `#7C86FF`, Teal `#2DC6DC`, Amber `#FFB940`, Rose `#F27BA6`, Slate `#8E9AAF`. These are validated for deuteranopia and protanopia distinguishability, and every series also gets a direct label (no legend-only encoding).

### 1.4 Spacing, layout, radii, depth

- **4pt base grid.** Spacing tokens: `xxs 2`, `xs 4`, `s 8`, `m 12`, `l 16`, `xl 24`, `xxl 32`, `xxxl 48`.
- Content padding inside the detail pane is 24. Card internal padding is 16. Gutter between dashboard cards is 12.
- **Radii** (always `.continuous`, the squircle):
  - Window: system.
  - Card: **14**.
  - Inner elements inside cards (chips, wells, thumbnails): **8**. This follows the concentric rule: inner radius = outer radius − padding, clamped to ≥ 6.
  - Buttons: system glass/bordered (capsule for primary floating actions).
  - Status chip: capsule.
  - Screenshot thumbnails: 6.
- **Depth.** There are three levels, and we don't stack shadows:
  1. *Ground*: window background.
  2. *Surface*: cards. 0.5pt hairline plus shadow `black 4%, y 1, blur 2` (light). In dark mode there's no shadow; a 1pt top inner highlight of white 4% does the lifting instead.
  3. *Floating*: glass (toolbar, palette, popovers, drag previews). It uses system glass shadows. A dragged kanban card gets `scale 1.03`, shadow `black 18%, y 12, blur 24`, rotation ±1.5° based on drag velocity.
- **Window sizes.** Minimum 1040×680. Default 1320×860. Sidebar 220 (collapsible). Inspector 320–420.

### 1.5 Materials and vibrancy

| Surface | Material |
|---|---|
| Sidebar | System sidebar (Liquid Glass, automatic in `NavigationSplitView`) |
| Toolbar | System glass toolbar. Grouped items use `ToolbarItemGroup` so they share a glass capsule |
| Live Agent hero card | Solid `bg.surface` with a subtle **accent mesh gradient** (`MeshGradient`, 3×3, accent at 0–10% opacity) that slowly shifts only while running |
| ⌘K palette | `.glassEffect(.regular, in: .rect(cornerRadius: 18))` floating panel |
| Menu bar popover | `MenuBarExtra(.window)` with glass background |
| HUD toasts (Submitted, Copied) | `.glassEffect(.regular.tint(.accent.opacity(0.15)), in: .capsule)` |
| Floating bulk-action bar (Review) | `GlassEffectContainer` holding capsule glass buttons, which morph as the selection count changes |

With **Reduce Transparency** on, every glass surface falls back to `bg.surfaceRaised`, fully opaque with a hairline border (SwiftUI does most of this automatically; custom `MeshGradient`s are hidden).

### 1.6 Iconography

- **SF Symbols 7 only.** Hierarchical rendering by default. Palette rendering for status symbols (status color plus secondary grey).
- Sidebar icons: `square.grid.2x2` Dashboard, `hand.raised` Needs You, `checkmark.rectangle.stack` Review, `rectangle.split.3x1` Pipeline, `bolt.horizontal` Easy Apply, `person.text.rectangle` Profile, `doc.on.doc` Resumes, `text.book.closed` Story Bank, `list.bullet.rectangle` Activity, gear for Settings (opens the Settings scene).
- **App icon:** a glass squircle with a single indigo paper plane leaving a fine dotted trajectory that bends into a check mark. Built in Icon Composer with layered glass, so it gets light/dark/tinted variants.
- **Menu bar glyph:** a custom template symbol (paper plane outline). The state variants are listed in §3.5.
- **Symbol effects** (each one used for exactly one meaning):

| Effect | Meaning | Where |
|---|---|---|
| `.symbolEffect(.pulse, isActive:)` | Agent is working | Menu bar glyph, hero status dot |
| `.symbolEffect(.bounce, value:)` | Something new arrived | Inbox badge when a new question lands |
| `.symbolEffect(.wiggle)` | Needs your attention now (once, not looping) | Needs-you sidebar icon on arrival |
| `.contentTransition(.symbolEffect(.replace))` | State swap | Play/Pause, Auto/Review toggle, copy → checkmark |
| `.symbolEffect(.drawOn)` | Completion | Check mark on submit, inbox zero, onboarding steps |
| `.symbolEffect(.variableColor.iterative)` | Indeterminate progress | System check rows "checking…" |
| `.symbolEffect(.breathe)` | Idle but armed (scheduled) | Hero idle state "Next run 14:00" |

---

## 2. Motion system

### 2.1 Principle

Motion has to answer one of three questions: **Where did it come from? Where did it go? What changed?** If an animation answers none of them, delete it.

### 2.2 Spring presets

Defined once in `Motion.swift`. Views never inline animation values.

| Name | Definition | Use |
|---|---|---|
| `.snappy` | `.spring(duration: 0.28, bounce: 0.0)` | Selection, hover, toggles, list reorders. Default for most UI |
| `.settle` | `.spring(duration: 0.45, bounce: 0.12)` | Cards entering, kanban drop landing, inspector open |
| `.flow` | `.spring(duration: 0.7, bounce: 0.0)` | Jobs moving between pipeline stages, matched-geometry flights |
| `.celebrate` | `.spring(duration: 0.55, bounce: 0.32)` | Submitted check, inbox zero, offer moved. Rare by design |
| `.gentle` | `.smooth(duration: 0.9)` | Chart data changes, mesh gradient shifts |
| `.press` | `.spring(duration: 0.16, bounce: 0.0)` | Button press scale 0.97 |
| `.numeric` | `.snappy` (shared) | Paired with `.contentTransition(.numericText(value:))` |

```swift
enum Motion {
    static let snappy    = Animation.spring(duration: 0.28, bounce: 0.0)
    static let settle    = Animation.spring(duration: 0.45, bounce: 0.12)
    static let flow      = Animation.spring(duration: 0.70, bounce: 0.0)
    static let celebrate = Animation.spring(duration: 0.55, bounce: 0.32)
    static let gentle    = Animation.smooth(duration: 0.9)
    static let press     = Animation.spring(duration: 0.16, bounce: 0.0)

    /// Reduce-motion aware: returns a cross-fade instead of movement.
    static func resolve(_ a: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : a
    }
}
```

**Durations cap.** No UI animation takes longer than 0.7s, except the onboarding opening (about 3.2s, skippable) and celebrations (≤ 1.2s, non-blocking).

### 2.3 Transitions catalog

| Name | Implementation | Use |
|---|---|---|
| `cardIn` | `.opacity` + `.offset(y: 8)` + `.scale(0.98)`, `.settle`, staggered 30ms per item, max 8 staggered then the rest appear together | Dashboard cards on first load |
| `rowInsert` | `.push(from: .top)` + opacity, `.snappy` | New log lines, new inbox items |
| `blurReplace` | `.blurReplace` | Hero status sentence swaps, onboarding step content |
| `stageFlight` | `matchedGeometryEffect(id: job.id, in: pipelineNS)` | Job chip flying between pipeline columns (dashboard and board) |
| `cardToDetail` | `matchedGeometryEffect` on company logo + title (not the whole card), `.flow` | Kanban card → Job Detail. Logo and title fly, body fades |
| `inboxCollapse` | answered cluster `.scale(0.96)+.opacity` while the next cluster slides up, `.settle` | Answer-once flow |
| `glassMorph` | `glassEffectID(_:in:)` inside `GlassEffectContainer` | Bulk action bar growing from 1 button to 3, palette result chips |

### 2.4 PhaseAnimator and KeyframeAnimator uses (the complete list)

1. **Submitted moment** (KeyframeAnimator): check-mark scale 0.6 → 1.12 → 1.0, opacity 0 → 1, plus a ring stroke that expands from radius 10 → 28 while fading 0.5 → 0. Total 0.6s.
2. **Needs-you arrival** (PhaseAnimator, 3 phases, runs once): badge scale 1 → 1.25 → 1, tint flash amber 0 → 20% → 0 on the sidebar row.
3. **Onboarding opening** (KeyframeAnimator timeline, §5.1).
4. **Live hero "thinking" dots** (PhaseAnimator, looping only while the agent's state is `.thinking`): three 4pt dots, opacity 0.3/1.0 staggered. They stop when the state changes.
5. **Inbox zero** (KeyframeAnimator, §6).
6. **Error shake** (KeyframeAnimator): offset x 0 → −6 → 5 → −3 → 0 over 0.35s. Only for an invalid input in onboarding or settings.

### 2.5 Number roll-ups

```swift
Text(stats.appliedToday, format: .number)
    .font(.metricXL)
    .monospacedDigit()
    .contentTransition(.numericText(value: Double(stats.appliedToday)))
    .animation(Motion.snappy, value: stats.appliedToday)
```

- Counts tick up digit by digit. Percentages animate via `.numericText` too.
- On first appearance the dashboard counts up from 0 **only on the first launch of the day** (stored in `@AppStorage`). After that, numbers render at their value immediately, because a count-up every time you open the window is a gimmick.

### 2.6 Reduce Motion fallbacks

`@Environment(\.accessibilityReduceMotion)` is read in one place (`MotionEnvironment`) and propagated.

| Normal | Reduce Motion |
|---|---|
| Matched-geometry flights | Cross-fade 0.18s in place |
| Spring bounces | Ease-in-out, no overshoot |
| Pipeline particles flowing | Static stage counts that update with a numeric fade. Particles are hidden |
| Mesh gradient drift | Static gradient |
| Celebrations (ring, confetti dots) | A single symbol `.drawOn` only |
| Card staggers | All appear at once |
| Number roll | Instant swap with a 0.15s opacity fade |
| Symbol pulse/breathe | Static symbol with a color state |

### 2.7 Performance budget

- **120fps on ProMotion and 60fps everywhere**, with zero dropped frames during: scrolling a 5,000-row Activity log, dragging a kanban card across a 300-card board, and the live hero running.
- Main-thread work per event: under **2ms**. The daemon can emit 20+ events/sec, so the UI **coalesces them into one state publish per frame** (§8.4).
- Live viz drawn in **one `Canvas` inside `TimelineView(.animation(minimumInterval: 1/60, paused: !isRunning || !isVisible))`**, so there are no per-particle views. Particle cap: 60.
- Lists use `List`/`Table`/`LazyVStack` with stable `id`s. No `AnyView` in rows. Row views are `Equatable` where props are value types.
- Screenshots: decode thumbnails off-main with `CGImageSourceCreateThumbnailAtIndex` (max 640px) and cache them in `NSCache`. Full-res images load lazily in the viewer.
- Charts: data is pre-aggregated in the store (daily buckets), with at most ~365 marks per chart. No chart is computed from raw rows in `body`.
- Charts and the Canvas pause when the window is occluded (`NSWindow.occlusionState`) or the app is hidden.
- Instruments gate: every phase has a "Hitches" template run in the definition of done (target hitch ratio < 1 ms/s).

---

## 3. Information architecture and window structure

### 3.1 Scenes

```swift
@main struct AutoApplyApp: App {
    var body: some Scene {
        Window("AutoApply", id: "main") { RootView() }          // single main window
            .defaultSize(width: 1320, height: 860)
            .windowToolbarStyle(.unified)
            .commands { AppCommands() }
        Window("Onboarding", id: "onboarding") { OnboardingView() }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
        WindowGroup("Job", id: "job", for: Job.ID.self) { JobDetailWindow(id: $0) } // pop-out
        Settings { SettingsView() }
        MenuBarExtra { MenuBarPanel() } label: { MenuBarGlyph() }
            .menuBarExtraStyle(.window)
    }
}
```

The app keeps running in the menu bar when the main window closes (it's an `LSUIElement`-style accessory toggle in Settings: "Show in Dock" defaults to on).

### 3.2 Main window layout

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  ‹sidebar›   Dashboard            [⏸ Pause] [Auto|Review]  [⌘K Search…]  [⋯] │ ← unified glass toolbar
├────────────┬─────────────────────────────────────────────────────────┬───────────────┤
│ ▢ Dashboard│                                                         │  Inspector    │
│ ✋ Needs You 6│                     Detail content                      │  (contextual, │
│ ☑ Review  3│                                                         │   ⌘⌥I)        │
│ ▥ Pipeline │                                                         │               │
│ ⚡ Easy App 9│                                                         │               │
│ ─────────  │                                                         │               │
│ LIBRARY    │                                                         │               │
│ 👤 Profile  │                                                         │               │
│ 📄 Resumes  │                                                         │               │
│ 📖 Stories  │                                                         │               │
│ ─────────  │                                                         │               │
│ ≡ Activity │                                                         │               │
│            │                                                         │               │
│ ┌────────┐ │                                                         │               │
│ │● Applying│ │                                                         │               │
│ │ 3 / 12  │ │  ← sidebar footer: mini agent status (always visible)   │               │
│ └────────┘ │                                                         │               │
└────────────┴─────────────────────────────────────────────────────────┴───────────────┘
```

**Sidebar sections:**
- *(unlabeled, "Now")* Dashboard, Needs You (badge: open clusters), Review (badge: pending, hidden when mode is Auto and the queue is empty), Pipeline, Easy Apply (badge: unopened).
- **Library**: Profile, Resumes, Story Bank.
- **System**: Activity.
- Footer: the **Agent Pill**, a compact live status (dot + sentence + progress ring). Clicking it jumps to the Dashboard hero. It's the same component as in the menu bar popover.

Badges use `.badge(count)` and system styling. Needs You badges are tinted amber (`.badgeProminence(.increased)`).

**Toolbar** (left to right after the title):
- **Pause / Resume**: global kill switch. Glass capsule, `pause.fill` ↔ `play.fill` with `.replace`. While paused, the entire window gets a 1pt amber hairline under the toolbar and the title reads "Paused".
- **Mode segmented control**: Auto | Review. Switching to Auto with items in the review queue asks "Approve 3 pending, or keep them in Review?" in an inline popover. That's a decision the user makes, not a default.
- **Search field** that opens ⌘K.
- **More (⋯)**: Run now, Prep pass, Open agent Chrome, Open data folder.

**Inspector** (`.inspector(isPresented:)`): contextual. Pipeline shows the selected job summary, Activity shows the event payload, Dashboard has none.

### 3.3 Command palette (⌘K)

A floating glass panel 640 wide, centered in the upper third of the window. It works from anywhere in the app. Raycast-style.

```
╭──────────────────────────────────────────────────────────────╮
│  🔍  stripe                                              esc │
├──────────────────────────────────────────────────────────────┤
│  JOBS                                                        │
│  ▸ ● Stripe · Backend Engineer, Payments      Applied · 3d ↵ │
│    ● Stripe · Staff Engineer, Infra            Skipped (68)  │
│  ACTIONS                                                     │
│    ⏸  Pause agent                                       ⌘⇧P │
│    ▶  Run discovery now                                 ⌘R  │
│    ✋  Answer next question                              ⌘J  │
│  NAVIGATE                                                    │
│    ▥  Go to Pipeline                                    ⌘3  │
╰──────────────────────────────────────────────────────────────╯
```

- Fuzzy search across jobs (company, title), inbox questions, stories, settings keys ("salary floor"), and actions.
- Prefix scopes: `>` actions, `@` companies, `?` inbox questions, `/` settings.
- Inline result actions: ↵ opens, ⌘↵ opens the job posting in the browser, ⌥↵ shows the job in Pipeline.
- Motion: the panel scales 0.96 → 1 plus opacity with `.snappy`. The results list resizes height with `.snappy`. The selection highlight is a single `matchedGeometryEffect` capsule that slides between rows, which is the only thing moving while you arrow through.

### 3.4 Keyboard map

| Shortcut | Action |
|---|---|
| ⌘1 … ⌘9 | Sidebar sections in order |
| ⌘K | Command palette |
| ⌘⇧P | Pause / resume agent (also global hotkey, optional, in Settings) |
| ⌘R | Run now |
| ⌘⇧R | Run Prep pass |
| ⌘J | Jump to next unanswered question |
| ⌘⌥I | Toggle inspector |
| ⌘⌃S | Toggle sidebar |
| ↑↓ / J K | Move selection in lists, board columns, inbox |
| ← → / H L | Move between kanban columns (selection) |
| ⌘← / ⌘→ | **Move selected job to previous/next status** (keyboard drag-drop) |
| Space | Quick Look the screenshot of the selected job |
| ↵ | Open selected |
| ⌘↵ | Submit answer / approve |
| A | Approve (Review queue) |
| X | Toggle selection (Review, Easy Apply) |
| ⌘A then A | Approve all selected |
| S | Skip / reject from Review (asks reason) |
| C | Copy the focused answer (Easy Apply) |
| ⌘⇧C | Copy all answers for the job as formatted text |
| O | Open the posting (Easy Apply, Job) |
| ⌘F | Filter within current view |
| ⌘, | Settings |
| Esc | Close palette / inspector / deselect |

All shortcuts live in the menu bar (`CommandMenu("Agent")`, `CommandMenu("Job")`) so they're discoverable and VoiceOver-accessible.

### 3.5 Menu bar extra

**Glyph states** (template image, 18pt, with a small badge overlay where noted):

| State | Glyph | Effect |
|---|---|---|
| Idle (scheduled) | paper plane outline | none |
| Discovering | paper plane + tiny magnifier | `.pulse` (slow) |
| Applying | paper plane filled | `.pulse`, plus the text `3/12` next to the glyph (optional setting, default on) |
| Needs you | paper plane + amber dot | one `.bounce` on transition, then static |
| Paused | paper plane with pause bars | none |
| Error / daemon down | paper plane + small `!` | none |

**Popover** (`.window` style, 340 wide, glass):

```
╭────────────────────────────────────────╮
│  ● Applying · 3 of 12 today       ⏸   │  ← Agent Pill (large) + pause button
│  ┌──────────────────────────────────┐ │
│  │ [live chrome thumbnail 16:10]    │ │  ← updates every ~2s while filling
│  │                                  │ │
│  └──────────────────────────────────┘ │
│  Stripe · Backend Engineer            │
│  step 4/7  answering "Years with Go"  │  ← SF Mono ticker
│ ────────────────────────────────────── │
│  ✋ 6 questions need you        Answer ›│  ← amber row, only if > 0
│  ☑ 3 waiting for review        Review ›│
│ ────────────────────────────────────── │
│  Today  ▂▃▅▇  9 applied · 41 found     │  ← sparkline + numbers
│  Caps   ████████░░░░  9 / 15           │
│ ────────────────────────────────────── │
│  Next run 14:00     Open AutoApply  ⌘O │
╰────────────────────────────────────────╯
```

- Pause in the popover is the **kill switch**. It's instant and optimistic in the UI, then confirmed by the daemon. If the daemon doesn't ack within 2s, the pill shows "Pausing…" with a spinner and retries.
- The popover's height animates with `.snappy` when rows appear or disappear.

### 3.6 Notifications

`UserNotifications`, with grouped threads and actionable categories. **Quiet by default**: there's no notification per submission unless the user enables it.

| Category | When | Title / body | Actions | Default |
|---|---|---|---|---|
| `NEEDS_YOU` | New question cluster (debounced 60s, batched) | "3 questions need you" / "Why Stripe? · Notice period · +1" | **Answer** (opens inbox), Snooze 1h | On |
| `REVIEW_READY` | Review queue reaches N (default 5) or a run ends | "5 applications ready to review" | Review | On |
| `RUN_SUMMARY` | End of each scheduled run | "Run complete · 9 applied, 2 need you, 31 skipped" | Open | On |
| `SUBMITTED` | Each submission | "Applied to Stripe · Backend Engineer" | View receipt | **Off** |
| `NUDGE` | Day 7/14 after applying | "Heard back from Stripe?" | **Interview**, **Rejected**, Not yet | On |
| `ERROR` | Daemon down, login expired, CAPTCHA | "LinkedIn session expired" | Reconnect | On, time-sensitive |

Threads group by category (`threadIdentifier`). The nudge actions update the tracker directly from the notification, without opening the app.

---

## 4. The Dashboard

### 4.1 Concept

It's an **instrument panel with one live window into the agent**. The top third is the *Live Agent* hero (what's happening right now). Below that is a calm grid of measured widgets (what has happened). The hero is the only thing that moves continuously, and only while the agent is running. Everything else updates in discrete, explained steps.

### 4.2 Wireframe (1320×860, sidebar visible)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ TODAY · Friday 10 Oct                                          Next run 14:00 · Auto ●   │
│ Good afternoon, Moaksh.                                                                  │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ ╭─ LIVE AGENT ─────────────────────────────────────────────────────────────────────────╮ │
│ │  ● Applying  ·  Stripe · Backend Engineer, Payments                       00:42  ⏸   │ │
│ │                                                                                      │ │
│ │  DISCOVERED        SCORED           QUEUED          FILLING          SUBMITTED       │ │
│ │     41      ───▶     38     ───▶      12     ───▶      1      ───▶       9           │ │
│ │  ·· ·  ·  ··──────·· · ·  ·──────── ·  · ·  ───────── ◉ ──────────  ✓✓✓✓✓✓✓✓✓       │ │
│ │       ↘ 27 skipped (below 70)           ↘ 2 need you                                 │ │
│ │                                                                                      │ │
│ │  ┌────────────────────────────┐   STEP TICKER                                        │ │
│ │  │                            │   14:02:11  ✓ opened greenhouse form                 │ │
│ │  │   live chrome thumbnail    │   14:02:18  ✓ uploaded Backend.pdf (match 0.91)      │ │
│ │  │   (16:10, 360×225)         │   14:02:29  ✓ filled 9 standard fields               │ │
│ │  │                            │   14:02:40  ◌ answering "Years with Go?" → "4"  ···  │ │
│ │  └────────────────────────────┘   ▢ cover letter   ▢ review   ▢ submit               │ │
│ ╰──────────────────────────────────────────────────────────────────────────────────────╯ │
│                                                                                          │
│ ╭─ APPLIED TODAY ─╮ ╭─ NEEDS YOU ──────╮ ╭─ RESPONSE RATE ─╮ ╭─ CAPS ───────────────────╮ │
│ │   9             │ │  6  questions     │ │   18%   ▲ 3pt   │ │ Applications  9 / 15  ▓▓▓░│ │
│ │   ▂▃▅▃▆▇▅ 7d    │ │  14 jobs parked   │ │  30-day window  │ │ Per company   1 / 30d  ✓ │ │
│ │   +4 vs avg     │ │  [ Answer  ⌘J ]   │ │                 │ │ LinkedIn reads 212/400 ▓░│ │
│ ╰─────────────────╯ ╰──────────────────╯ ╰─────────────────╯ ╰──────────────────────────╯ │
│                                                                                          │
│ ╭─ APPLICATIONS · 30 DAYS ─────────────────────────╮ ╭─ FUNNEL ─────────────────────────╮ │
│ │  ▁▂▃▂▅▆▄▃▅▇█▆▅▄▆▇▅▃▂▄▆▇█▇▅▆▇▆▅▇  (bars + 7d avg) │ │ Applied      142 ████████████████ │ │
│ │                                                  │ │ Responded     26 ███        18%   │ │
│ ╰──────────────────────────────────────────────────╯ │ Assessment     9 █           6%   │ │
│                                                      │ Interview      7 █           5%   │ │
│ ╭─ BY RESUME VARIANT ─────╮ ╭─ MATCH SCORES ────────╮ │ Offer          1 ▏         0.7%   │ │
│ │ Backend  ████████ 22%   │ │      ▁▂▅▇█▆▃  |70     │ ╰──────────────────────────────────╯ │
│ │ ML       ████     11%   │ │ skipped ░░ | applied ▓│ ╭─ SOURCES ────────────────────────╮ │
│ │ Infra    ██████   17%   │ ╰───────────────────────╯ │ Greenhouse ██████ 46  Lever ██ 18 │ │
│ ╰─────────────────────────╯                           │ Ashby ███ 24  Careers █ 9  LI→ 45│ │
│ ╭─ ACTIVITY HEATMAP · 26 WEEKS ─────────────────────────────────────────────────────────╮ │
│ │ M ░░▒▒▓░░▒▓▓█░▒▒░░▓▒▒▓▓░░▒                                                           │ │
│ │ W ░▒▓▓█▒░▒▓█▓░▒▒▓░░▒▓█▓▒░▒            Less ░▒▓█ More                                   │ │
│ │ F ░░▒▓▓░░░▒▓▒░░▒░░▒▒▓▓░░░▒                                                           │ │
│ ╰──────────────────────────────────────────────────────────────────────────────────────╯ │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

Grid: an adaptive 12-column `Grid` with 12pt gutters. Under 1100pt content width, the KPI row goes 2×2 and charts stack into a single column. The hero always spans full width.

### 4.3 Widget specifications

#### W1. Greeting header
- **Data:** date, time-of-day greeting, next scheduled run, mode.
- **Behavior:** the greeting changes at most once per session. "Next run" counts down only in the last 10 minutes ("in 4 min"). Before that it shows the clock time, to avoid constant ticking.
- **States:** paused shows "Paused · resumes when you press ⌘⇧P". Daemon down shows an error chip (W1 is where global errors surface, see §4.4).

#### W2. Live Agent hero (`LiveAgentCard`): the signature widget
Four layers, from top to bottom:

**a) Status line.** Status dot (accent, `.pulse` while active) + verb + job + elapsed timer (`monoSmall`, `TimelineView(.periodic(from:by:1))`) + Pause.
- Verbs: *Idle · Discovering · Scoring · Filling · Waiting on page · Submitting · Paused · Needs you · Error*.
- The sentence swaps with `.blurReplace` + `.snappy`. The job name is a link to Job Detail.

**b) Pipeline Flow (`PipelineFlowView`).** Five stage nodes, Discovered → Scored → Queued → Filling → Submitted, with counts for **the current run**. They're connected by hairline rails. Drawn in a single `Canvas`:
- Each job in the current run is a **3pt particle**. When the daemon emits a stage change, that job's particle travels along the rail to the next node over 0.7s (`.flow` easing, implemented as a time-based interpolation in Canvas). At the node, the count ticks up via `.numericText`.
- **Skipped** particles peel off downward from Scored on a curved branch and fade into a muted "27 skipped (below 70)" label. Clicking the label opens Pipeline filtered by skip reason.
- **Needs you** particles peel off from Filling into an amber branch with a "2 need you" label. Clicking it opens the inbox.
- The **Filling** node holds the active job as a larger 8pt accent orb with a soft 12pt glow ring, breathing at 0.5Hz.
- **Submitted** shows up to 12 tiny check glyphs. Past 12 it shows "✓ × 21".
- Particles are deterministic: positions are derived from `(eventTime, now)`, so redraws are stateless and cheap. Idle = no particles, nodes show the last run's totals in `text.tertiary`, and the `TimelineView` is paused.
- **Hover** a node to get a popover listing the jobs at that stage (up to 8). Click to jump to Pipeline filtered.

**c) Live Chrome thumbnail (`LiveBrowserThumb`).** 360×225 (16:10) in a `bg.sunken` well with a 6pt radius.
- The daemon sends a downscaled JPEG frame (max 720px wide) every **2s while filling** and on each step event. The new frame cross-fades in over 0.25s, so the image never pops.
- A thin accent scan-line sweeps top-to-bottom once per new frame (0.4s, 20% opacity). It signals "fresh" without moving content. It's hidden under Reduce Motion.
- Overlay chip in the corner: the ATS logo/name ("Greenhouse"). Click it to bring the real Chrome window forward (`open -a`).
- When not filling, the thumbnail shows the last submitted page, desaturated 60%, with the caption "Last: Ramp · 13:58".

**d) Step Ticker (`StepTicker`).** SF Mono. The last 4 completed steps plus the current one (with thinking dots), then a row of upcoming step chips (`▢ cover letter ▢ review ▢ submit`) that fill in as they complete (`drawOn` check).
- New lines insert with `rowInsert` and the oldest line fades out the top. That's a fixed height, so layout never jumps.
- Low-confidence answers show an amber "?" and the text "low confidence → asking you" before the job parks.

**Hero states**

| State | Visual |
|---|---|
| Idle (scheduled) | Status "Idle · next run 14:00" with `.breathe` symbol. Flow shows last run totals greyed out. Thumbnail shows the last page desaturated. Primary button **Run now** |
| Discovering | Ticker lists sources being read ("LinkedIn · 'backend engineer' · page 3"). Particles appear at Discovered as jobs are found, in bursts |
| Scoring | Particles move Discovered → Scored. Skip branch active |
| Filling | Full layout as wireframed |
| Needs you (pipeline continuing) | A small amber chip in the status line: "2 parked". The agent keeps going |
| Paused | Mesh gradient stops, everything goes to 60% saturation, centered glass capsule "Paused · Resume ⌘⇧P" |
| Daemon unreachable | Hero replaced by an error panel: "Can't reach autoapplyd" + last-seen time + **Restart daemon** (runs `launchctl kickstart`) + **View log**. No fake data |
| Loading (first connect) | Skeleton: node circles and rails drawn in `stroke.hairline` with a shimmer *off* (a static skeleton, no shimmer: shimmer is decoration) |
| First run ever (no data) | The flow is drawn but empty, with the line "Your agent hasn't run yet. **Run a Prep pass** to collect questions first, or **Run now**." |

#### W3. Applied Today (`KPICard`)
- **Data:** count of submissions today, 7-day sparkline (`Chart` with `LineMark` + `AreaMark` at 15% accent), delta vs the 14-day average.
- **Animation:** numeric roll on change. The sparkline's last point extends with `.gentle`. On a new submission the card gets a 0.6s accent hairline glow (border opacity 0 → 40% → 0).
- **Empty:** "0" with the caption "Nothing yet today". The sparkline is a flat dotted line.

#### W4. Needs You (`NeedsYouCard`)
- **Data:** open question clusters, number of parked jobs.
- **Visual:** amber when > 0 (12% amber surface tint, amber number). When 0 it turns neutral, with a green `checkmark.circle` and "All clear".
- **Animation:** the arrival PhaseAnimator (§2.4). **Answer ⌘J** button.
- This card is the one place on the dashboard that's allowed to be loud.

#### W5. Response Rate (`KPICard`)
- **Data:** (responses of any kind: assessment/interview/offer/rejection) ÷ applied, rolling 30 days, delta vs the previous 30.
- **Note:** ghosted doesn't count as a response. Rate is shown with 0 decimals. The tooltip explains the definition.
- **Empty (< 10 applications):** "—" with the caption "Needs 10+ applications".

#### W6. Caps (`CapsCard`)
- **Data:** daily application cap (used/limit), company cooldown status (any company blocked today? "2 companies cooling down"), LinkedIn/Glassdoor read budget.
- **Visual:** thin 4pt capsule progress bars. They turn amber at 80% and show a grey "cap reached · resumes tomorrow" text at 100%. Never red: hitting a cap means the guardrail worked, it isn't an error.

#### W7. Applications · 30 days (`ApplicationsChart`)
- **Swift Charts:** `BarMark` per day (accent 70%) + a `LineMark` 7-day moving average (accent 100%, 1.5pt, `.interpolationMethod(.catmullRom)`) + a `RuleMark` for the daily cap (dashed, tertiary).
- **Interaction:** `chartXSelection` shows a scrubbing rule with an annotation popover ("Tue 7 Oct · 12 applied · 3 skipped by cap"). The trackpad gets an alignment haptic when snapping to each day.
- **Animation:** new data animates with `.gentle`. Bars grow from the baseline only on first appearance.

#### W8. Funnel (`FunnelChart`)
- **Data:** Applied → Responded → Assessment → Interview → Offer over the selected window (30d / 90d / All, a segmented control in the card header).
- **Visual:** horizontal `BarMark`s in status colors, with the absolute count and step conversion % labeled directly. Hover shows conversion from the previous step.
- **Click** a bar to open Pipeline filtered to that status.

#### W9. Response rate by resume variant (`VariantChart`)
- **Data:** per resume variant: applications, response rate, interview rate.
- **Visual:** horizontal bars (categorical palette) with response % labeled, plus a small sample-size caption ("n=64"). Variants with n < 10 show a hatched bar and "low sample". **This is the most decision-relevant chart in the app**, because it tells the user which resume works.

#### W10. Match score distribution (`ScoreHistogram`)
- **Data:** histogram of scores (bins of 5) for jobs discovered in the window, stacked into skipped vs. applied.
- **Visual:** `BarMark`s (skipped = slate 40%, applied = accent) + a draggable **threshold `RuleMark`** at 70.
- **Interaction:** dragging the threshold rule shows a live preview ("At 65: +23 jobs/week would qualify") and a **Set threshold** button. It doesn't save silently.

#### W11. Sources (`SourcesChart`)
- **Data:** jobs discovered per source (Greenhouse, Lever, Ashby, Career pages, LinkedIn→ATS, Glassdoor→ATS) plus apply rate per source.
- **Visual:** a single stacked horizontal bar (100%) with direct labels underneath. Easy Apply jobs are shown separately as a hatched segment "LinkedIn Easy Apply (manual) 45".

#### W12. Activity heatmap (`ActivityHeatmap`)
- **Data:** applications per day for the last 26 weeks.
- **Visual:** GitHub-style grid, 11pt cells, 3pt gap, 3pt radius, 5-step accent ramp (0 = `bg.sunken`). Drawn with `Canvas` for performance, with an overlay of invisible accessibility elements per week.
- **Hover** shows a tooltip ("Mon 6 Oct · 11 applications · 2 interviews later"). Click opens Activity filtered to that day.

### 4.4 Dashboard-wide states

- **Loading:** skeleton cards with real titles and greyed-out placeholder shapes. No spinners. Data arrives and cards cross-fade content (0.2s).
- **Error per widget:** a small inline message in the card ("Couldn't read stats · Retry"). The rest of the dashboard keeps working.
- **Global errors** (daemon down, DB locked, login expired) show as a **single banner under the greeting**: amber or red tint, one sentence, one fix button. Never more than one banner; if there are several issues, it says "2 issues · View".
- **Brand-new install:** charts show designed empty states (a dotted-line axis with the caption "Charts fill in after your first ~10 applications") rather than empty boxes.

---

## 5. Screens

### 5.1 Onboarding

A separate borderless window, 880×620, centered, `.hiddenTitleBar`, glass background over a deep gradient. It has a step rail on the left (from step 1 on) and content on the right. Each step has **one primary action**, and **Back** is always available. ⌘↵ = Continue.

#### 5.1.0 Signature opening: "Ignition" (frame by frame, about 3.2s, click or any key skips)

Concept: a single point of light becomes a trajectory, the trajectory becomes the paper-plane mark, the mark settles into the welcome screen. It's the same visual idea as the live pipeline (particles on rails), so the opening *teaches the app's visual language*.

| t (s) | Frame |
|---|---|
| 0.00 | Window fades in on a near-black canvas (`#0B0B12`, both themes). Silence. Center: nothing. |
| 0.15 | A single 2pt accent dot appears at center with an 18pt soft glow (opacity 0 → 1, 0.25s ease-out). |
| 0.40 | The dot begins moving left-to-right along an invisible gentle S-curve, leaving a **trail of 40 fading particles** (Canvas, each particle's opacity = 1 − age/0.8s). Speed eases in. |
| 0.90 | Two more faint dots join from the edges (representing "jobs") and merge into the main trail, each with a tiny brightness pulse on contact. |
| 1.30 | The trail bends upward and closes into the **paper-plane outline**. The stroke draws on (`trim(from:to:)` 0 → 1, 0.6s, `.flow`) while the particles get absorbed into the stroke. |
| 1.90 | The plane's interior fills with Liquid Glass (opacity 0 → 1). A specular highlight sweeps across it once (a linear gradient mask moving −30° → +30°, 0.5s). |
| 2.20 | The trail behind the plane resolves into a **dotted line that ends in a check mark** (the app icon composition). The check uses `.drawOn`. |
| 2.45 | The background slowly brightens into the onboarding gradient (accent-tinted `MeshGradient`, 3×3, deep indigo → near-black). The mark scales 1 → 0.62 and moves up 120pt (`.settle`). |
| 2.70 | The headline types in by word (not by character), 60ms stagger, `.blurReplace`: **"Let's get you hired."** (`display`). |
| 2.95 | The subhead fades in: "AutoApply finds roles that fit and applies for you, only with facts you approve." (`title2`, secondary). |
| 3.20 | The **Get started** button (glass, prominent, capsule) rises 8pt + fades. Footnote: "Everything stays on this Mac." with `lock.fill`. |

- Sound (only if the user later enables sounds; onboarding is silent by default).
- **Reduce Motion:** the mark appears fully formed with a 0.4s fade, and the text fades in together.
- Implementation: one `KeyframeAnimator` driving a `IgnitionState` struct (`dotProgress`, `trimEnd`, `glassOpacity`, `markScale`, `markOffset`, `textPhase`), and a `Canvas` for the particle trail. A `@State var skipped` jumps the animator to its final values.

#### Step rail (shared across steps 1 to 7)

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  ◉ System check        │                                                      │
│  ○ Resumes             │                    [ step content ]                  │
│  ○ Preferences         │                                                      │
│  ○ Never-guess facts   │                                                      │
│  ○ Story bank  opt.    │                                                      │
│  ○ Sources             │                                                      │
│  ○ Mode                │                                                      │
│                        │                                                      │
│  ✈ (mark, small)       │                       [ Back ]   [ Continue ⌘↵ ]     │
└───────────────────────────────────────────────────────────────────────────────┘
```

- Completed steps get a check that draws on, and the connector line between dots fills with accent (`.flow`). The current dot is a filled accent circle with a soft ring.
- Step content transitions: forward = new content slides in from trailing 24pt + fades, old content slides out leading. Back reverses. Uses `.settle`.
- Progress persists. Quitting mid-onboarding resumes at the same step.

#### Step 1: System check

```
  System check
  AutoApply drives Chrome with Claude. Let's make sure the tools are here.

  ┌────────────────────────────────────────────────────────────────────┐
  │ ✓  Claude CLI        logged in as moaksh@…              v2.4.1     │
  │ ✓  uv                found at /opt/homebrew/bin/uv      0.6.2      │
  │ ✕  Node.js ≥ 20      not found                [ Install with brew ]│
  │ ◌  autoapplyd        installing LaunchAgent…                       │
  │ ○  Chrome            waiting                                       │
  └────────────────────────────────────────────────────────────────────┘
                                         [ Re-check ]   [ Continue ⌘↵ ]
```

- Checks run sequentially with a 150ms stagger, so the column "cascades" to green. ◌ uses `variableColor.iterative`. ✓ draws on.
- Fix-it buttons run the command in an embedded, collapsible terminal well (SF Mono) so the user sees exactly what runs. For `claude login`, the button opens Terminal with the command prefilled, because it needs an interactive browser login.
- Continue is disabled until the required checks pass. A failing row gets an expandable "Why this matters" disclosure.

#### Step 2: Resumes, then parsed profile

```
  Your resumes
  Add every approved version. The agent picks the best one per job, and never edits them.

  ╭───────────────────────────────────────────────────────╮
  │                                                       │
  │            ⬇  Drop PDFs here or Choose files…         │   ← drop zone (dashed 1.5pt, r14)
  │                                                       │
  ╰───────────────────────────────────────────────────────╯
  ┌──────────┐ ┌──────────┐ ┌──────────┐
  │ [thumb]  │ │ [thumb]  │ │ [thumb]  │
  │Backend   │ │ ML       │ │ Infra    │   ← name editable, tag chips: "backend, go"
  │ ✓ parsed │ │ ◌ parsing│ │ ✓ parsed │
  └──────────┘ └──────────┘ └──────────┘
```

- Drag-over: the drop zone scales 1.01, the border goes from dashed to solid accent, and the trackpad gets a `.generic` haptic on enter.
- On drop, each PDF's first-page thumbnail flies from the cursor position into its slot (`.settle`), then "parsing" runs and resolves to ✓.
- Then the **Confirm profile** sub-step: a two-column form (name, email, phone, location, links, work history, education, skills), with fields prefilled from the parse. Each parsed field shows a faint `doc.text.viewfinder` source icon. Hovering it highlights the line in the PDF preview on the right. Uncertain parses get an amber underline and "Check this".

#### Step 3: Job preferences

```
  What are you looking for?

  Roles            [Backend Engineer ×] [ML Engineer ×] [+ add]
  Seniority        ( Junior ) ( Mid ) (●Senior ) (●Staff ) ( Principal )
  Location         (●Remote) (●Hybrid) ( Onsite )   Cities [Bangalore ×] [+]
  Work auth        [ India citizen; needs US visa sponsorship        ▾ ]
  Salary floor     [ ₹ 40,00,000 ] per year   ☐ Hide jobs without salary
  Exclude          Companies [Acme ×]   Keywords [crypto ×] [gambling ×]
  Daily cap        ──────●────────  15 applications / day
  Match threshold  ─────────●─────  70      "≈ 18 jobs/week at current volume"
```

- Chips insert with `.snappy` scale-in. Sliders use `.monospacedDigit` labels with `numericText`.
- The threshold slider shows a live mini histogram (the W10 component in miniature, using sample/benchmark data until real data exists). This teaches the threshold concept in place.

#### Step 4: Never-guess facts

```
  Facts the agent will never guess
  These only ever come from you. If a form asks something not listed, the agent stops and asks.

  ┌──────────────────────────────────────────────────────────────┐
  │ 🔒 Visa / sponsorship   [ Requires sponsorship (H-1B)     ▾ ]│
  │ 🔒 Expected salary      [ ₹45L ] [ Negotiable ☑ ]            │
  │ 🔒 Notice period        [ 60 days ]                          │
  │ 🔒 Relocation           ( Yes ) (●Case by case ) ( No )      │
  │ 🔒 EEO / demographics   (●Decline to answer) ( Fill: … )     │
  │ 🔒 Legal attestations   ☐ Agent may confirm "info is accurate"│
  │                         ☐ Agent may accept background checks │
  └──────────────────────────────────────────────────────────────┘
  Leave anything blank to always be asked.
```

- The lock icons are deliberate: these fields have a distinct visual treatment *everywhere* in the app (a lock glyph plus a `bg.sunken` well), so the user learns "locked = only I set this".
- Blank fields are valid. They show "Always ask me" in tertiary text.

#### Step 5: Story bank (optional)

- One card per story: Title, Situation, Task, Action, Result (expanding text fields), plus tags (leadership, conflict, scale…).
- A **Skip for now** link is as prominent as Continue. Copy: "Cover letters and 'why' answers only use facts from your stories and profile. Fewer stories = more questions later."
- An "Import from text" button: paste a brag doc, and the agent proposes STAR stories for the user to accept or edit (each proposed story card has accept/discard).

#### Step 6: Connect sources

```
  Where should we look?

  ┌──────────────────────────────┐ ┌──────────────────────────────┐
  │ in  LinkedIn                 │ │ G   Glassdoor                │
  │ Read-only browsing           │ │ Read-only browsing           │
  │ [ Log in in agent Chrome ]   │ │ ✓ Connected · 10 Oct         │
  └──────────────────────────────┘ └──────────────────────────────┘
  ┌──────────────────────────────┐ ┌──────────────────────────────┐
  │ ● Greenhouse · Lever · Ashby │ │ 🌐 Career pages               │
  │ Public boards · no login     │ │ [ + Add company URL ]        │
  │ ✓ Ready                      │ │ stripe.com/jobs ×  ramp.com ×│
  └──────────────────────────────┘ └──────────────────────────────┘
```

- **Log in** opens the Playwright Chrome window. The card shows "Waiting for you to log in in Chrome…" with a `variableColor` symbol. When the daemon detects a session, the card flips (a 3D `rotation3DEffect` of 180° over 0.5s, the one place we use a flip, because it's literally a card "turning on") to its connected face.
- Copy states plainly: "LinkedIn is only browsed, never used to apply. Easy Apply jobs go to a manual list."

#### Step 7: Mode

```
  How much should the agent do on its own?

  ╭────────────────────────────╮  ╭────────────────────────────╮
  │  ⚡ Auto                    │  │  ☑ Review                  │
  │  Applies when confident.   │  │  Fills everything, waits   │
  │  Asks when unsure.         │  │  for your approval.        │
  │  [mini animation]          │  │  [mini animation]          │
  ╰────────────────────────────╯  ╰────────────────────────────╯
        Recommended for your first week: Review
  You can override this per ATS or per job anytime.

                                        [ Start AutoApply ⌘↵ ]
```

- Each card has a looping mini animation (only while hovered or selected, max 3s loop): Auto shows a particle going straight to ✓; Review shows a particle pausing at a small "you" avatar, then ✓.
- **Finish moment** (§6): the selected card's mark flies (matched geometry) to the window center, the window cross-fades to a "Ready" state ("Your agent starts at 09:00. First, a Prep pass?" with **Run Prep pass** and **Not now**). Then the onboarding window closes and the main window opens with the dashboard cards staggering in.

### 5.2 Dashboard
See §4.

### 5.3 Pipeline (kanban board)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Pipeline     [Board | Table]   🔍 Filter   Source ▾  Score ≥ ▾  Resume ▾   ☐ Show skipped │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ QUEUED 12    NEEDS YOU 6   APPLIED 98      ASSESSMENT 4  INTERVIEW 3   OFFER 1  REJECTED 31 GHOSTED 17│
│ ┌─────────┐ ┌─────────┐ ┌─────────────┐  ┌──────────┐  ┌──────────┐  ┌──────┐ ┌───────┐ ┌──────┐│
│ │▌Ramp     │ │▌Notion  │ │▌Stripe       │  │▌Figma     │  │▌Linear    │  │▌Vercel│ │ Plaid  │ │ Brex ││
│ │ Backend  │ │ SWE II  │ │ Backend, Pay │  │ SWE       │  │ Sr. Eng   │  │ Staff │ │ …      │ │ …    ││
│ │ 86 · GH  │ │ ✋ 2 Qs  │ │ 91 · 3d  ⏱7│  │ due Fri   │  │ Tue 3pm   │  │       │ │        │ │ 22d  ││
│ └─────────┘ └─────────┘ └─────────────┘  └──────────┘  └──────────┘  └──────┘ └───────┘ └──────┘│
│ ┌─────────┐              ┌─────────────┐                                                       │
│ │ …        │              │ "Heard back?"│ ← nudge chip on day 7/14 cards                        │
│ └─────────┘              └─────────────┘                                                       │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Columns:** Queued, Needs you, Applied, Assessment, Interview, Offer, Rejected, Ghosted. Discovered and Skipped are hidden by default (they're high-volume) and live in Table view or behind the "Show skipped" toggle, which adds a collapsed Skipped column with reasons grouped ("Below threshold · 27", "Excluded keyword · 4", "Company cooldown · 2").
- **Column width** is 248. Columns scroll horizontally, and each column scrolls vertically with a `LazyVStack`.
- **Job card (`JobCard`)**: 2pt status bar on the leading edge, company logo (favicon cached, 20pt, r5), company (`bodyEmph`), title (`callout`, 1 line), and a meta row: match score pill (Rounded), ATS badge, age ("3d"), and resume variant initial. Optional chips: "✋ 2 Qs", nudge "Heard back?", "⏱ 7d".
- **Drag and drop:** only legal transitions are droppable. The agent owns Queued → Applied; the user owns post-apply statuses. While dragging, illegal columns dim to 40% and get the `nosign` cursor. Legal targets get a 1.5pt accent dashed outline, and the insertion slot opens with `.snappy` (cards part to make room). On drop, the card lands with `.settle`, the column counts roll, and there's a `.levelChange` trackpad haptic. Undo is ⌘Z with a toast "Moved to Interview · Undo".
- **Keyboard drag:** select a card, ⌘→ moves it to the next legal status with the same flight animation.
- **Ghosted:** cards auto-move after 21 days with a gentle flight the next time the board is visible, plus an inline "Moved 2 to Ghosted · 21 days without reply" toast. They aren't animated while off-screen.
- **Table view:** a `Table` with sortable columns (Company, Title, Status, Score, Source, ATS, Resume, Applied, Last update). It's for power filtering, and it's the way to browse Discovered/Skipped with reasons.

### 5.4 Job detail

It opens in the detail pane (push from board with `cardToDetail` matched geometry) or in its own window (⌘⇧O / double-click).

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ ‹ Pipeline   [logo] Stripe · Backend Engineer, Payments                    ● Applied ▾   │
│              Remote (India) · Greenhouse · found via LinkedIn · 10 Oct      [Open posting]│
├───────────────────────────────┬──────────────────────────────────────────────────────────┤
│ MATCH 91                      │  [ Overview | Application | Screenshots | Timeline ]     │
│ ┌───────────────────────────┐ │                                                          │
│ │ Skills      ██████████ 95 │ │  APPLICATION (Q&A AUDIT)                    ⌘⇧C Copy all │
│ │ Seniority   ████████░░ 85 │ │  ┌────────────────────────────────────────────────────┐ │
│ │ Location    ██████████ 100│ │  │ Full name                 Moaksh Kakkar    profile │ │
│ │ Salary      ███████░░░ 70 │ │  │ Years with Go?            4          ● high · CV   │ │
│ │ Domain      █████████░ 90 │ │  │ Requires sponsorship?  🔒 Yes        profile·locked│ │
│ └───────────────────────────┘ │  │ Why Stripe?               "I've built…" memory ▸   │ │
│ Why: strong Go + payments,    │  │ Cover letter              Generated · 212 words ▸  │ │
│ senior level, remote ok.      │  │ Resume                    Backend.pdf   picked: 0.91│ │
│                               │  └────────────────────────────────────────────────────┘ │
│ RESUME  Backend.pdf  (why ▸)  │                                                          │
│ OVERRIDES                     │  SUBMITTED PAGE                                         │
│ Mode   [ Inherit (Auto) ▾ ]   │  ┌──────────────────────────┐                           │
│                               │  │ [full-page screenshot    │  Space: Quick Look        │
│ NOTES                         │  │  scroll preview]         │  ⌘+ / ⌘−: zoom            │
│ [ free text…            ]     │  └──────────────────────────┘                           │
└───────────────────────────────┴──────────────────────────────────────────────────────────┘
```

- **Match breakdown:** factor bars (they animate from 0 on first open with `.gentle`, 40ms stagger) plus the agent's 1–2 sentence rationale. For skipped jobs, the logged reason is shown at the top as a muted banner ("Skipped · below threshold (64) · salary floor not met").
- **Q&A audit:** every field, with the answer, a **provenance** tag (profile / CV / memory / story #3 / generated / you), and a confidence dot (green high, amber medium, grey n/a). Locked never-guess fields show the lock. Clicking a provenance tag reveals the source snippet in a popover. Copy buttons appear on hover.
- **Screenshot viewer (`ScreenshotViewer`):** full-page screenshots are tall, so it uses a scroll-preview with a minimap strip on the right. Q&A rows are **linked to screenshot regions** where the daemon provides bounding boxes: hover a Q&A row and the viewer scrolls and highlights that field with an accent box. Space opens Quick Look (`QLPreviewPanel`). Multiple screenshots (pre-submit, post-submit confirmation) appear as a filmstrip.
- **Timeline tab:** a vertical timeline of events: Discovered (source) → Scored 91 → Queued → Filling (duration) → Submitted → Nudge day 7 → Moved to Interview (by you). Each item has a timestamp in SF Mono. Agent events use a `cpu` mini-icon, user events use `person`.
- **Status menu** (top right) offers legal manual transitions. Same rules as the board.

### 5.5 Needs You inbox

The emotional center of the "agent asks you" experience. The goal is to **make answering feel fast, few and final.**

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Needs You      6 questions · 14 jobs waiting                        [ Run Prep pass ⌘⇧R ]│
├───────────────────────────────────┬──────────────────────────────────────────────────────┤
│ ● Why do you want to work here?   │  WHY DO YOU WANT TO WORK HERE?                        │
│   14 jobs · Stripe, Ramp, +12     │  Asked by 14 jobs · variants:                         │
│ ● Notice period?          🔒      │   "Why Stripe?" · "What draws you to Ramp?" · +12 ▾   │
│   5 jobs                          │                                                      │
│ ● Years of Kubernetes?            │  ◉ Template answer, personalized per company          │
│   3 jobs                          │  ┌────────────────────────────────────────────────┐  │
│ ● Willing to work PST hours?      │  │ I'm drawn to {company} because {reason}. In my │  │
│   2 jobs                          │  │ last role I…                                   │  │
│ ● Portfolio URL?                  │  └────────────────────────────────────────────────┘  │
│   1 job                           │  Suggested from your stories: [Payments scale ▸]     │
│ ● "Describe a conflict…" (long)   │  Preview for Stripe ▾  "I'm drawn to Stripe because…"│
│   1 job                           │                                                      │
│                                   │  ☑ Save to memory (reuse for future jobs)            │
│                                   │  ○ Answer per job instead                            │
│                                   │                    [ Skip these jobs ]  [ Answer ⌘↵ ]│
└───────────────────────────────────┴──────────────────────────────────────────────────────┘
```

- **Clusters** are sorted by jobs-unblocked (impact first). Each row shows the canonical question, a job count, and a lock if it's a never-guess field. Unread rows have an amber dot.
- **Answer types** adapt to the question: short text, number with unit, yes/no segmented, choice (options pulled from the actual forms, unioned across the cluster), long text (template with `{company}` / `{role}` tokens, plus a per-company preview), and URL.
- **Never-guess clusters** (locked) also offer "**Save to profile**" instead of memory, and the copy explains it will be used for all future forms.
- **Answer-once flow:** ⌘↵ submits. The answered cluster compresses into a green "✓ Answered · 14 jobs resumed" pill that slides into a collapsed "Answered today" section at the bottom (`.settle`). The next cluster auto-selects, and its content cross-fades in with `.blurReplace`. The header count rolls down. The jobs-waiting number ticks down by the cluster size. **There's no modal confirmation, and Undo (⌘Z) is available for 10s.**
- **Inbox zero** celebration: see §6.
- **Prep pass mode:** when a Prep pass is running, the header shows "Collecting questions from 40 queued jobs… 23/40" with a thin progress bar, and clusters stream in (rows insert with `rowInsert`, deduped into clusters live, so counts tick up on existing rows rather than adding duplicates).
- Per-job escape hatch: "Answer per job instead" expands to a compact list of jobs with an individual field each.

### 5.6 Review queue

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Review    3 ready · Mode: Review (Greenhouse override: Auto)        ☐ Select all  ⌘A     │
├──────────────────────────────┬───────────────────────────────────────────────────────────┤
│ ☑ Stripe · Backend      91   │  ┌─────────────────────┐  Q&A (12)          ⚠ 1 medium    │
│ ☑ Ramp · Platform Eng   86   │  │ [full-page          │  Full name     Moaksh Kakkar  ✓   │
│ ☐ Notion · SWE II       78 ⚠ │  │  screenshot,        │  Years w/ Go   4              ✓   │
│                              │  │  scrollable,        │  Why Ramp?     "I'm drawn…" ✎     │
│                              │  │  fields highlighted]│  Salary   🔒   ₹45L           ✓   │
│                              │  │                     │  Start date    "2 months" ⚠ ✎     │
│                              │  └─────────────────────┘  Cover letter  212 words ▸ ✎     │
│                              │                          Resume        Backend.pdf  ↻     │
├──────────────────────────────┴───────────────────────────────────────────────────────────┤
│                 ╭──────────────────────────────────────────────────────╮                  │
│                 │ 2 selected   [ Approve & submit  A ]  [ Skip  S ]  [ ✕ ]│  ← floating glass│
│                 ╰──────────────────────────────────────────────────────╯                  │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- The list on the left sorts medium/low-confidence items **to the top**, with a ⚠ marker.
- The detail shows the screenshot and every Q&A side by side, and hover-linking highlights fields (same as §5.4). ✎ edits inline; edited answers get a "you" provenance tag. ↻ swaps the resume variant (a popover with the alternatives and their pick scores).
- **The floating action bar** (`BulkActionBar`) appears when ≥ 1 item is selected. It's a `GlassEffectContainer` whose buttons morph in with `glassEffectID` as the selection count goes from 0 → 1 → many. The count rolls.
- **Approve flow:** A approves the focused item (or all selected). The approved rows slide out to the right in sequence (40ms stagger) while each shows a brief ✓ draw-on, then collapse. The daemon submits them in the background, and their progress appears in the hero/menu bar rather than blocking here.
- **Bulk-approve safeguard:** if the selection contains ⚠ items, the button reads "Approve 2 (1 needs a look)" and approving asks inline in the bar ("Include the flagged one? Yes / Only the 1 clean one"). The bar expands to show this, so there's no modal.
- **Skip (S):** a reason picker in the bar (Not interested / Wrong answers / Company / Other). This feeds the skip log.

### 5.7 Easy Apply (manual list)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Easy Apply     9 to do · LinkedIn only · applied manually by you   [Unopened|All|Done]   │
├──────────────────────────────┬───────────────────────────────────────────────────────────┤
│ ● Razorpay · Backend SDE  88 │  Razorpay · Backend SDE                [ Open on LinkedIn O]│
│ ● CRED · Platform Eng     84 │  Match 88 · posted 2d ago · 120 applicants                │
│ ○ Swiggy · SDE III        81 │                                                           │
│ ✓ Zepto · Backend         79 │  PRE-DRAFTED ANSWERS                    [ Copy all ⌘⇧C ]  │
│                              │  ┌───────────────────────────────────────────────────┐    │
│                              │  │ Phone                  +91 98…            [copy]  │    │
│                              │  │ Years of experience    5                  [copy]  │    │
│                              │  │ Notice period 🔒       60 days            [copy]  │    │
│                              │  │ Why Razorpay?          "Payments infra…"  [copy]  │    │
│                              │  │ Resume to upload       Backend.pdf  [Reveal in Finder]│    │
│                              │  └───────────────────────────────────────────────────┘    │
│                              │                       [ Mark as applied ✓ ]  [ Dismiss ]  │
└──────────────────────────────┴───────────────────────────────────────────────────────────┘
```

- **Copy interaction:** clicking a row (or pressing C on the focused row) copies it. The copy icon morphs into a checkmark (`.replace`), the row flashes a 10% accent tint for 0.3s, and a HUD toast "Copied · Years of experience" appears for 1.2s. ↑↓ moves through rows, so the user can alt-tab between LinkedIn and the app and paste fields in sequence.
- **Resume row:** "Reveal in Finder" and a drag handle. Dragging the resume out of the row drops the actual PDF into the LinkedIn upload field (a `Transferable` file representation).
- **Mark as applied** moves the job into the tracker as Applied with source "LinkedIn Easy Apply (manual)". The row checks and fades to the Done filter.
- Unanswerable Easy Apply questions show as "Ask me" rows that link to the inbox.

### 5.8 Profile and Story bank

**Profile:** a form-style document view (not a settings list), with sections Identity, Contact, Links, Experience, Education, Skills, **Never-guess facts** (locked styling), and **Memory** (answers saved from the inbox: question, answer, used-in count, last used, edit/delete).

```
┌───────────────────────────────────────────────────────────────────────────┐
│ Profile                                              Last updated today   │
│ ─ IDENTITY ─────────────────────────────────────────────────────────────  │
│ Moaksh Kakkar  ·  Bangalore, India  ·  moaksh@…                     ✎     │
│ ─ NEVER-GUESS FACTS ──────────────────────────────────── 🔒 only you ───  │
│ Sponsorship   Requires (H-1B)      Salary   ₹45L, negotiable              │
│ Notice        60 days              Relocate Case by case                  │
│ ─ MEMORY · 23 answers ──────────────────────────────────────────────────  │
│ Why {company}?      template · used 31×        last: Stripe, today   ✎ ✕  │
│ Years of K8s?       3                  used 4×                       ✎ ✕  │
└───────────────────────────────────────────────────────────────────────────┘
```

**Story bank:** a two-pane view: a list of stories (title + tags + "used in 7 applications") on the left, the STAR editor on the right. Each of S/T/A/R is its own text area with a gentle label. A "Facts only" reminder in the footer: "The agent quotes these; it won't invent metrics." Empty state: a book symbol and "Add your first story. Stories make 'why' and 'tell us about a time' answers sound like you." with an **Import from text** option.

### 5.9 Resume variants

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ Resumes                                                    [ + Add resume ]   │
│ ┌───────────────┐ ┌───────────────┐ ┌───────────────┐                         │
│ │ [page preview]│ │ [page preview]│ │ [page preview]│                         │
│ │               │ │               │ │               │                         │
│ │ Backend.pdf   │ │ ML.pdf        │ │ Infra.pdf     │                         │
│ │ backend · go  │ │ ml · python   │ │ k8s · sre     │                         │
│ │ 64 sent · 22% │ │ 28 sent · 11% │ │ 41 sent · 17% │  ← response rate        │
│ │ ● default     │ │               │ │               │                         │
│ └───────────────┘ └───────────────┘ └───────────────┘                         │
│ HOW THE AGENT PICKS:  role keywords → tag overlap → past response rate        │
└───────────────────────────────────────────────────────────────────────────────┘
```

- The grid uses `LazyVGrid` cards (r14) with real PDF first-page thumbnails (PDFKit, rendered off-main). Hover lifts the card 2pt with the shadow strengthening (`.snappy`).
- Selecting a card opens an inspector: tags (editable), "use for roles like…", disable toggle, and the list of jobs it was used for, with outcome dots.
- The resume file is **read-only** in-app (it's approved and never modified). Replacing it means uploading a new version, which keeps history ("v2 · replaced 3 Oct").

### 5.10 Settings (⌘,)

A standard `Settings` scene with a tabbed toolbar (glass), 640 wide, height animating per tab with `.snappy`.

| Tab | Contents |
|---|---|
| **General** | Show in Dock, launch at login, menu bar counter, notifications per category, sounds (off), haptics (on), global pause hotkey |
| **Preferences** | Everything from onboarding step 3 |
| **Guardrails** | Never-guess facts (same component as onboarding step 4), confidence threshold for asking (Strict / Balanced / Lenient, with an explainer), legal attestation permissions, "always ask" question patterns list |
| **Modes** | Global Auto/Review, **per-ATS overrides table** (Greenhouse · Lever · Ashby · Workday · Other with Inherit/Auto/Review), per-company overrides list |
| **Sources** | Source cards from onboarding step 6 with session health ("LinkedIn session valid · checked 2h ago"), reconnect, career page URL list, Glassdoor/LinkedIn read budgets |
| **Schedule & Caps** | A weekly schedule grid (click-drag to paint active hours on a 7×24 grid, accent cells), runs per day, daily application cap, per-company cooldown (30d), auto-ghost days (21), nudge days (7, 14) |
| **Agent** | Daemon status, version, Restart daemon, log level, Chrome profile path, Open data folder, "Re-run onboarding" |
| **Data** | DB location, export (CSV of the tracker, a zip of receipts), delete a job's data, reset |

### 5.11 Activity log

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Activity    [All | Agent | You | Errors]   🔍 filter…   Run: Today 09:00 ▾    ⏸ Follow ● │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ 14:02:40.118  FILL     stripe/backend-pay   answered "Years with Go" = 4  (cv, 0.93)     │
│ 14:02:29.502  FILL     stripe/backend-pay   filled 9 standard fields                     │
│ 14:02:18.044  RESUME   stripe/backend-pay   picked Backend.pdf (0.91 vs ML 0.62)         │
│ 14:01:55.870  SCORE    ramp/platform        86  ✓ queued                                 │
│ 14:01:54.211  SKIP     acme/sre             64  below threshold                          │
│ 14:01:12.990  ASK      notion/swe2          parked: "Willing to work PST hours?"   → inbox│
│ 13:58:03.400  ERROR    lever/foo            selector timeout on step 5 · retried ok      │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- SF Mono throughout. The event type is a fixed-width colored tag (status colors). It's a `Table` with virtualized rows, handling 100k rows smoothly.
- **Follow mode** (on by default when scrolled to the top): new rows insert at the top with `rowInsert`. If the user scrolls away, follow pauses automatically and a glass pill "12 new events ↑" appears. Clicking it scrolls back with `.flow`.
- Selecting a row shows the full JSON payload in the inspector (syntax-tinted mono) plus a link to the job.
- Errors expand to show the stack/step, with a "Copy diagnostic" button.

---

## 6. Micro-interactions and delight

Tasteful means: **short, rare, tied to an actual achievement, never blocking, and never repeated within a minute.** Each moment is listed with its exact recipe.

| Moment | Recipe | Frequency guard |
|---|---|---|
| **Application submitted** (app in foreground) | The hero's Filling orb travels to Submitted (`.flow`). At arrival, the KeyframeAnimator check (§2.4 #1) plus an expanding ring in `status.applied`. The Submitted count rolls. The W3 card border glows once. Optional sound: a soft "tock" (system `Tink`-like, custom 80ms) | Burst-coalesced: if 3 submit within 5s, one ring and the count rolls by 3 |
| **Inbox zero** | The last cluster pill slides down. The list area shows a large `checkmark.seal` symbol drawn on (`.drawOn`, 0.6s), and 12 tiny accent dots burst radially from it (Canvas, 0.8s, fade + decelerate, no gravity confetti). Headline "All caught up." (`display`) and subline "14 jobs resumed. The agent's back at it." The header count rolls to 0. Trackpad haptic `.levelChange` | Once per transition to 0 |
| **First interview moved on the board** (ever) | On drop into Interview: the card lands with `.celebrate`, the column header briefly tints `status.interview` at 15%, and a one-time inline note appears under the card: "First interview. Nice. Good luck, Moaksh." Fades after 4s | Once per lifetime, stored flag |
| **Any interview / offer drop** | `.celebrate` landing plus a column count roll. Offer additionally gets a gold star `.bounce` on the card | Every time (rare by nature) |
| **Onboarding finish** | The selected mode card's glyph flies to center (matched geometry), morphs into the app mark (`.replace`), the mark gets a specular sweep, and "You're set." appears. Then the main window opens and dashboard cards stagger in with `cardIn` | Once |
| **Cap reached for the day** | The caps bar fills, its color stays neutral, and the hero status settles into "Done for today · 15/15 · resumes tomorrow 09:00" with `.breathe`. Calm, not alarming | Daily |
| **Copy answer** | Icon `.replace` → checkmark, row tint flash, HUD toast | Every copy |
| **Agent asks you** (foreground) | The sidebar Needs You icon `.wiggle`s once and the badge bounces. If the user is on the Dashboard, the W4 card does the arrival PhaseAnimator | Debounced 10s |
| **Threshold drag** | Histogram bars cross-fade between skipped/applied colors as the rule passes over them, with an alignment haptic each 5 points | — |

**Haptics** (`NSHapticFeedbackManager.defaultPerformer`, trackpad only, toggle in Settings, default on):
- `.alignment`: snapping chart scrub to a day, threshold rule snapping, kanban insertion slot changing.
- `.levelChange`: successful drop on a new column, inbox zero, toggling Pause.
- `.generic`: drag entering a drop zone (resume upload, kanban column).

**Sound** (off by default, Settings → General → "Play sounds"): three custom sounds total, all under 150ms, mixed at −18 LUFS: *submit tock*, *needs-you chime* (two soft notes), *inbox zero* (rising triad). There are no other sounds.

---

## 7. Accessibility

- **VoiceOver for visualizations:**
  - `PipelineFlowView` exposes one accessibility element per stage (`.accessibilityElement(children: .ignore)` per node): "Scored, 38 jobs, 27 skipped below threshold". The whole view has a summary label: "Agent applying. Current run: 41 discovered, 38 scored, 12 queued, 1 filling, 9 submitted". Stage changes post `AccessibilityNotification.Announcement` **throttled to one per 10s** ("Submitted to Stripe").
  - All Swift Charts use `.accessibilityChartDescriptor` (an `AXChartDescriptorRepresentable`) so audio graphs work. Bars get `accessibilityLabel/Value` per mark.
  - The heatmap provides per-week rows ("Week of 6 October: 41 applications, busiest Tuesday with 11").
  - The live thumbnail is labeled "Live view of Chrome, Stripe application, step 4 of 7"; it's not announced on each frame.
  - Kanban drag-drop has accessibility actions per card: "Move to Interview", "Move to Rejected"… (`.accessibilityAction(named:)`), mirroring ⌘←/⌘→.
- **Dynamic Type equivalent:** macOS has a system "Text size" setting (Settings → Accessibility → Display) and the sidebar-size setting. All text uses semantic text styles so it scales. Metric numbers use `@ScaledMetric`. Layouts use `ViewThatFits` so the KPI row reflows to 2×2 / 1×4 at large sizes. Card heights are intrinsic, never fixed.
- **Contrast:** all text tokens meet WCAG AA (4.5:1 body, 3:1 large/UI). Status colors on surfaces are checked at ≥ 3:1 as UI glyphs. Text over status tints always uses `text.primary`, never the status color. Increase Contrast swaps to the HC tokens and turns hairlines to 1pt `stroke.strong`.
- **Never color alone:** every status has a symbol and a label. Chart series have direct labels and, where adjacent, pattern differentiation (hatching for "low sample" / "manual").
- **Reduce Motion:** §2.6. **Reduce Transparency:** §1.5. **Differentiate without color:** status chips show their symbol even in compact layouts.
- **Full keyboard access:** every control is reachable via Tab (full keyboard access mode) and the focus ring uses the accent. Custom views use `.focusable()` + `.focused($focus)` + `.onKeyPress`. The board, inbox and review queue all have a defined focus order and a visible focus state (2pt accent ring, r = card radius + 2).
- **Notifications** have meaningful titles without relying on emoji.
- **Testing:** Accessibility Inspector audit per screen in each phase's definition of done, plus a VoiceOver walkthrough of onboarding → answer a question → approve review.

---

## 8. SwiftUI implementation notes

### 8.1 Targets and APIs

- **Deployment target:** macOS 26.0. Swift 6 language mode, strict concurrency.
- **Frameworks:** SwiftUI, Observation (`@Observable`), Swift Charts, PDFKit (thumbnails), QuickLookUI, UserNotifications, ServiceManagement (`SMAppService` for login item and LaunchAgent registration), Network (`NWConnection` over a Unix domain socket), GRDB (read-only SQLite with `ValueObservation`), AppKit bridges only where needed (haptics, `NSWindow` occlusion, Quick Look panel).
- **Key APIs:** `NavigationSplitView`, `.inspector`, `Table`, `MenuBarExtra(.window)`, `Settings`, `Window`/`WindowGroup(for:)`, `glassEffect`, `GlassEffectContainer`, `glassEffectID`, `.buttonStyle(.glass/.glassProminent)`, `MeshGradient`, `TimelineView`, `Canvas`, `KeyframeAnimator`, `PhaseAnimator`, `matchedGeometryEffect`, `symbolEffect`, `contentTransition(.numericText)`, `chartXSelection`, `draggable`/`dropDestination` with `Transferable`, `onKeyPress`, `focusable`, `ViewThatFits`.

### 8.2 Project structure

```
AutoApply/
  App/            AutoApplyApp.swift, AppCommands.swift, RootView.swift
  DesignSystem/   Tokens.swift (Color/Font/Spacing/Radius), Motion.swift, Haptics.swift,
                  Sounds.swift, Materials.swift
  Components/     (see 8.3)
  Features/
    Onboarding/   Ignition/, Steps/
    Dashboard/    LiveAgent/, Widgets/
    Pipeline/  JobDetail/  Inbox/  Review/  EasyApply/
    Profile/  Resumes/  Stories/  Activity/  Settings/  MenuBar/
  Data/
    Daemon/       DaemonClient.swift (socket), EventDecoder.swift, Commands.swift
    Store/        AppStore.swift, LiveRunStore.swift, StatsStore.swift, JobsRepository.swift (GRDB)
    Models/       Job, JobStatus, QACluster, Question, Answer, ResumeVariant, Story, AgentEvent
  Mock/           MockDaemon.swift, Fixtures/*.json, Scenarios.swift
  Previews/       PreviewContainer.swift
```

### 8.3 Component inventory

| Component | Purpose |
|---|---|
| `Card` | Surface with title/eyebrow, trailing accessory, padding, states (`.loading/.empty/.error`) |
| `KPICard` | Metric + caption + optional sparkline + delta |
| `MetricText` | Rounded, monospaced digits, numericText transition |
| `StatusChip` / `StatusDot` | Status symbol + color + label, sizes `.small/.regular` |
| `ScorePill` | 0–100 match score, tinted by distance to threshold |
| `AgentPill` | Live status (sidebar footer, menu bar, hero compact) |
| `PipelineFlowView` | Canvas live pipeline (hero) |
| `LiveBrowserThumb` | Cross-fading live frame well |
| `StepTicker` | Mono step list with upcoming chips |
| `JobCard` / `JobRow` | Board card, list row |
| `KanbanColumn` | Column with drop logic, insertion slot, counts |
| `QATable` | Q&A audit rows with provenance + confidence + copy + hover-link |
| `ProvenanceTag` | profile / cv / memory / story / generated / you |
| `LockedField` | Never-guess field styling |
| `ScreenshotViewer` | Tall scroll preview + minimap + highlights + Quick Look |
| `ClusterRow` / `AnswerComposer` | Inbox list row and adaptive answer editor |
| `BulkActionBar` | Floating glass morphing action bar |
| `CopyRow` | Easy Apply copyable field |
| `HUDToast` | Glass capsule toast, queue-managed |
| `Banner` | Single global issue banner |
| `CommandPalette` | ⌘K |
| `ChipField` | Token input (roles, excludes) |
| `ThresholdSlider` | Slider + mini histogram |
| `ScheduleGrid` | 7×24 paint grid |
| `Skeleton` | Static placeholder shapes |
| `EmptyState` | Symbol + title + body + action |
| `Celebration` | Ring / radial dots / drawOn check, reduce-motion aware |
| `StepRail` | Onboarding step indicator |
| Charts | `ApplicationsChart`, `FunnelChart`, `VariantChart`, `ScoreHistogram`, `SourcesChart`, `ActivityHeatmap`, `Sparkline` |

### 8.4 State architecture: streaming daemon events without jank

```
 autoapplyd ──(Unix socket, NDJSON events)──▶ DaemonClient (actor)
                                                  │ decode off-main
                                                  ▼
                                         EventBuffer (actor) ── coalesce per frame
                                                  │  (CADisplayLink-paced flush / 16ms)
                                                  ▼
                       @MainActor @Observable LiveRunStore  (current run, hero, ticker, menu bar)
                       @MainActor @Observable InboxStore    (cluster counts, badges)
 SQLite (read-only) ──GRDB ValueObservation──▶ JobsRepository ──▶ @Observable JobsStore / StatsStore
```

Rules:
1. **Two sources of truth, split by latency.** The socket drives *ephemeral live state* (current step, thumbnail, particles, counts during a run). SQLite drives *durable state* (jobs, statuses, stats, audits). When a socket event implies a durable change (e.g. `submitted`), the UI updates optimistically from the event, and the GRDB observation reconciles within a second. The DB always wins.
2. **Decode and coalesce off the main actor.** `DaemonClient` is an actor reading lines. `EventBuffer` accumulates events and flushes **at most once per display frame** as a single batch to the main actor. One batch = one Observation transaction = one render pass.
3. **Fine-grained observation.** `@Observable` stores are split so the ticker changing doesn't invalidate the charts. Views read only the properties they render. The hero reads `LiveRunStore.stageCounts`, `.activeJob`, `.ticker`, `.frame`; the charts read `StatsStore` (updated at most every 5s from DB aggregates).
4. **Particles are not state.** `PipelineFlowView` gets an immutable array of `(jobID, fromStage, toStage, startTime)` transitions. The Canvas computes positions from `timeline.date`. There are no `@State` per particle and no SwiftUI animations per particle.
5. **Thumbnails** arrive as JPEG `Data`. They're decoded into a `CGImage` off-main, and only the latest frame is kept (dropping intermediate frames if the UI is behind).
6. **Commands** (pause, run now, approve, answer) go through `DaemonClient.send(_:)` with optimistic UI and an ack timeout of 2s (then roll back + toast "Daemon didn't respond").
7. **Connection lifecycle:** auto-reconnect with backoff (0.5, 1, 2, 5s). While disconnected, the live state is marked stale (hero greys out, error panel after 5s), but DB-driven screens keep working.

Event model (sketch):

```swift
enum AgentEvent: Decodable, Sendable {
    case runStarted(runID: UUID, kind: RunKind, at: Date)
    case stageChanged(jobID: Job.ID, from: Stage, to: Stage, at: Date)
    case step(jobID: Job.ID, index: Int, total: Int, text: String, confidence: Double?)
    case frame(jobID: Job.ID, jpeg: Data)
    case needsYou(jobID: Job.ID, questionID: UUID, clusterID: UUID)
    case submitted(jobID: Job.ID, at: Date)
    case error(jobID: Job.ID?, code: String, message: String)
    case state(DaemonState)   // idle / discovering / applying(n, of) / paused
}
```

Live viz core:

```swift
struct PipelineFlowView: View {
    let snapshot: FlowSnapshot          // immutable value from LiveRunStore
    var isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60, paused: !isRunning || reduceMotion)) { tl in
            Canvas { ctx, size in
                let layout = FlowLayout(size: size)
                layout.drawRails(&ctx)
                for t in snapshot.transitions {          // ≤ 60, pruned after 0.8s
                    let p = min(1, tl.date.timeIntervalSince(t.start) / 0.7)
                    let pt = layout.point(from: t.from, to: t.to, progress: Ease.flow(p))
                    ctx.fill(Circle().path(in: .init(center: pt, radius: 1.5)),
                             with: .color(.accentColor.opacity(0.9)))
                }
                layout.drawActiveOrb(&ctx, at: tl.date)
            }
        }
        .overlay { StageLabels(counts: snapshot.counts) }   // real Text views → numericText + a11y
        .accessibilityRepresentation { FlowAccessibility(snapshot: snapshot) }
    }
}
```

### 8.5 Preview and mock data strategy (build the UI before the engine)

- **`DaemonClient` is a protocol** (`DaemonConnecting`) with `LiveDaemonClient` (socket) and `MockDaemon` implementations. `JobsRepository` is also a protocol with GRDB and in-memory fixture implementations.
- **`MockDaemon` replays scenario scripts** in real time (or at 4× speed): timestamped `AgentEvent` sequences in `Fixtures/*.json`. Scenarios:
  - `happyRun`: 40 discovered, 27 skipped, 12 queued, 9 submitted over 3 minutes.
  - `needsYouStorm`: Prep pass producing 14 questions that collapse into 6 clusters.
  - `reviewMode`: 5 filled jobs awaiting review, 1 low-confidence.
  - `daemonDown`, `loginExpired`, `capReached`, `firstRunEmpty`, `burstSubmit` (5 submits in 2s, to test coalescing).
  - `stress`: 5,000 jobs, 100k log rows, 50 events/s.
- **Debug menu** (DEBUG builds only): pick a scenario, set the speed, toggle reduce motion/transparency simulation, force light/dark/high contrast, and trigger each celebration.
- **Previews:** every component has `#Preview` variants for light/dark, loading/empty/error, and an XXL text size, using `PreviewContainer` (in-memory stores seeded from fixtures). Use `@Previewable @State` for interactive previews.
- **Fixtures** are generated once from realistic fake data (real-looking companies, varied ATSes, titles, Q&A sets with provenance) so the UI is designed against true density, not lorem ipsum.
- **Snapshot tests** (swift-snapshot-testing) for core components in both themes. They catch token regressions.

---

## 9. Inspiration and anti-patterns

### 9.1 Craft to emulate (specifically)

| App | What to take |
|---|---|
| **Things 3** | Calm density, generous whitespace, the "Magic Plus" style of physical-feeling drag with insertion gaps, celebrations that are tiny (the check sound and motion) |
| **Linear** | Keyboard-first everything, ⌘K as a primary surface, crisp status iconography, speed as a feature (optimistic updates), subtle hover states |
| **Raycast** | Command palette ergonomics: scoped prefixes, inline actions with ⌘↵/⌥↵, a single sliding selection highlight |
| **Arc** | Sidebar as the spine, playful-yet-restrained onboarding with a memorable opener |
| **CleanShot X** | Floating HUD toasts and overlays that appear, confirm and vanish; screenshot viewing/annotation ergonomics |
| **Craft** | Document-like forms (our Profile), beautiful typographic hierarchy |
| **Apple Activity / Fitness** | Rings and heatmap restraint, numbers in SF Rounded, celebrations proportional to the achievement |
| **Apple Stocks / Weather (macOS 26)** | Chart scrubbing, glass over content done right, live data that feels calm |
| **Xcode / Instruments** | The Activity log: dense mono with color-coded event types, follow mode |
| **iStat Menus** | Menu bar popover information density without clutter |
| **Teenage Engineering (OP-1 UI)** | Inspiration for the live pipeline: minimal geometric signals that feel alive |

### 9.2 Anti-patterns to avoid

1. **Spinners for known work.** Show the step ("uploading resume") instead. Spinners only for truly indeterminate waits under 2s.
2. **Looping animations at rest.** Nothing moves when the agent is idle except the `.breathe` on the idle symbol.
3. **Glass on content.** No glass behind body text, tables, the JD or screenshots.
4. **Rainbow dashboards.** One accent. Status colors only on status. No gradient fills on charts.
5. **Shimmer skeletons, confetti showers, parallax, bouncy-everything.** Bounce > 0.15 is reserved for `.celebrate`.
6. **Modal confirmations for reversible actions.** Use Undo instead. Modals only for irreversible actions (delete data, reset).
7. **Fake progress or fake data.** If the daemon is down, say so. Never show stale numbers as live.
8. **Notification spam.** No per-submission notifications by default. Batch and debounce.
9. **Hidden autonomy.** Never let the agent do something without a receipt one click away.
10. **Web-app chrome in a Mac app.** No hamburger menus, custom title bars, or non-native scrollbars. Use system controls and system right-click menus.
11. **Red for rejections at full intensity.** Rejection is normal in a job search. Keep it desaturated.
12. **Color-only meaning, legend-only charts, hover-only info** (everything on hover also has a keyboard/VoiceOver path).
13. **Per-particle SwiftUI views or `@State` timers for the live viz.** Canvas + TimelineView only.
14. **Count-up animations on every window open.** First launch of the day only.

---

## 10. Phased UI build order

The UI is built **against `MockDaemon` and fixtures first**, so every phase below can ship visually before its engine counterpart exists.

| Phase | Engine phase | UI deliverables | Mock-first? |
|---|---|---|---|
| **U0: Foundations** (before or in parallel with engine core) | Engine core | Design tokens, `Motion`, `Haptics`; component library (Card, KPICard, MetricText, StatusChip, ScorePill, JobCard, EmptyState, Skeleton, HUDToast, Banner); `MockDaemon` + fixtures + debug menu; app shell (NavigationSplitView, sidebar, toolbar, Settings scene stub, MenuBarExtra stub); event model `AgentEvent` agreed with the engine as the socket contract | Fully mock |
| **U1: Read the truth** | Engine core (SQLite schema exists) | GRDB read-only repository; **Pipeline** (board + table, drag-drop for post-apply statuses, undo); **Job Detail** (match breakdown, Q&A audit, screenshot viewer, timeline); **Activity log** (Table, follow mode). This makes the engine's output inspectable while it's being built, which is useful for debugging | Fixtures, then real DB |
| **U2: Ask and approve** | Agent + inbox | **Needs You inbox** (clusters, adaptive composer, answer-once, inbox zero), **Review queue** (bulk action bar, safeguards), **Easy Apply list**, notifications (`NEEDS_YOU`, `REVIEW_READY`), command contracts (answer, approve, skip) | Mock scenarios `needsYouStorm`, `reviewMode` first |
| **U3: The living app** | Swift app | **Dashboard**: Live Agent hero (PipelineFlowView, LiveBrowserThumb, StepTicker), all KPI cards and charts, global states; **⌘K palette**; full keyboard map; **Onboarding** including the Ignition opener and all 7 steps (system check wired to real checks); **Profile, Story bank, Resumes**; full **Settings**; celebrations and haptics; accessibility pass | Hero built on `happyRun`/`burstSubmit`/`stress` before the real socket |
| **U4: Always-on** | Daemon + LinkedIn | **Menu bar extra** full popover and glyph states; LaunchAgent management in Settings → Agent; source connection flow (Playwright Chrome login detection, card flip); session health; `ERROR`/`NUDGE`/`RUN_SUMMARY` notifications with actions; auto-ghost and day 7/14 nudges on the board; performance pass with Instruments on `stress`; final polish and sound design | Login detection mocked until daemon emits `sourceConnected` |

**Definition of done for every phase:** light/dark/high-contrast screenshots of each new screen, Reduce Motion and Reduce Transparency verified, VoiceOver walkthrough, keyboard-only walkthrough, and an Instruments hitch check on the `stress` scenario.

---

*Appendix: token quick reference*

```swift
enum Space { static let xxs: CGFloat = 2, xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0, xxxl = 48.0 }
enum Radius { static let card: CGFloat = 14, inner = 8.0, thumb = 6.0, palette = 18.0 }
extension Font {
    static let metricXL = Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
    static let metric   = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    static let mono     = Font.system(size: 12, design: .monospaced)
    static let eyebrow  = Font.system(size: 11, weight: .medium).width(.standard)
}
```
