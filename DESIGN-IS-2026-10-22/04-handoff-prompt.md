```
/make-plan Redesign the AutoApply macOS app's interaction and visual layer (app/Sources/AutoApply, SwiftUI on macOS 26, Liquid Glass). The current design failed a Dieter Rams audit at 11/30, with critical gaps in principle #6 Honest (0/3) and in #3 Aesthetic, #4 Understandable, #5 Unobtrusive, #8 Thorough, #9 Environmentally friendly and #10 As little design as possible (all 1/3).

Verdict paragraph:
> REDESIGN the UI layer. The engine, data model and core flows are sound. The interaction and visual layer is not: four systems are stacked on top of each other (the old purple-era components, the new palette, Liquid Glass applied everywhere, and one-off views). Redesign it from purpose: content first, glass only on the control layer, one surface, one primary action per screen, and plain, honest words.

Why redesign and not refine: the honesty principle scored 0. Connecting the "Security codes (optional)" mailbox silently turns on account creation on third-party sites, and the Cold Email "Join beta" button promises early access but only sets a local flag. On top of that, the aesthetic, structure and language failures are systemic: 9 surface kinds, 7+ button styles, about 25 jargon terms. They are not isolated bugs.

Preserve from the current design:
- The palette tokens in DesignSystem/Tokens.swift. Ink #17171C/#000, deep green #003C33 (accent #0F5C4F light / #29AB8B dark), stone #EEECE7, coral #FF7759 used only for small warm markers, and the status hues. Fix contrast where noted below.
- The spacing scale (4pt grid: 2/4/8/12/16/24/32/48), the Typography tokens (hero / display / title / body / callout / mono eyebrow), and Motion.resolve plus the \.motionReduced plumbing (DesignSystem/Motion.swift:49-62).
- The information architecture of the primary flows: Dashboard → Needs You (answer once, unblock many) → Review (approve / skip) → Pipeline board (drag and drop) → Job detail. Also keep the keyboard map (⌘R, ⇧⌘R, ⌥⌘R, ⇧⌘P, ⌘J, ⌘↵, A / S / X / ⌘A, ⌘←/→).
- The LiveAgent card concept and the step ticker. The pipeline flow visual stays, but static while idle.
- The ink/white pill tokens primaryFill / onPrimaryFill (Tokens.swift:76-78). They are defined but unused, and become the in-content primary action.

Discard:
- Glass on content: about 81 glass buttons, mostly inside cards (LiveAgentCard.swift:143-159, KPIWidgets.swift:58, ScoreHistogram.swift:78, SettingsTabs.swift:468,511), glass tooltips and capsules inside cards (ApplicationsChart.swift:55, LiveBrowserThumb.swift:33), and prompt text in glass (ReviewView.swift:199-223). This caused the failures on #3 and #5.
- 9 surface kinds: surfaceCard, Card + KPICard glow, sunkenWell, 51 ad-hoc backgrounds, the inspector's .regularMaterial with its radius-14 shadow (RootView.swift:241-245), the LiveAgentCard MeshGradient, and 4 drop shadows. This caused the failure on #3.
- Duplicated affordances: Run now ×6, Approve ×8+ including the mode-popover bypass (RootView.swift:159, which skips the low-confidence and per-company safeguards), Prep ×5, ≥10 header kinds, 6 empty-state styles, ≥12 one-off capsule badges, 3 hidden zero-size shortcut buttons, and the question text rendered twice (InboxView.swift:379,388). This caused the failures on #10 and #2.
- Jargon and inflated copy: "Prep pass", "never-guess", "ATS" and the GH/LV badges, "Inherit", "autoapplyd" / "daemon" / "LaunchAgent", "parked", "Tokens · in/out", "pick 0.83", "Receipts", "kill switch", "Let's get you hired", "Everything stays on this Mac", "no invented facts", "jobs resumed" (the jobs are only re-queued). This caused the failures on #4 and #6.
- Continuous idle animation: the 20 fps brand mesh on the Dashboard, menu bar and empty states (BrandGradient.swift:23), the status-dot breathe, which is not visibility-gated (AgentPill.swift:65), and the clock / moon breathe. This caused the failure on #9.

Top moves from the audit:
1. #6 Honest:
   - Account creation is opt-in, with its own explicit consent row in Settings ▸ Guardrails and in onboarding. It must not be enabled by connecting a mailbox. Flip the engine default too (engine/autoapply/config.py create_accounts: False), and add a migration that keeps the setting for users who already turned it on.
   - Remove the Cold Email waitlist, or make it honest.
   - Rewrite the 14 inflated claims.
   - Show the defaults for save-to-memory, auto-install and include-logs plainly.
   - Evidence: Onboarding/Steps/FinishSteps.swift:59, ColdEmail/ColdEmailView.swift:127-130, Onboarding/Ignition/IgnitionView.swift:58,190,203, JobDetail/QATable.swift:179, Inbox/InboxModel.swift:560.
2. #3 + #5, Liquid Glass hierarchy:
   - Glass only on the control layer: toolbar, sidebar, floating bulk bars, ⌘K palette, toasts, menu-bar panel chrome.
   - Content on one flat `Surface` (surface plus a 0.5 hairline, radius 8, no shadow) and one `Well` (sunken stone) for inputs and quotes.
   - In-content primary = ink/white pill. Secondary = text link or plain glass-free bordered.
   - Inspector = standard sidebar/inspector glass, not a custom material.
   - Evidence: 81 glass buttons, 9 surface kinds, RootView.swift:241-245.
3. #10 + #2, one path per action and one primary per screen:
   - A lint-like test asserts at most one prominent button per screen.
   - Approve only from Review and Job detail; the mode popover only switches mode, and has Cancel.
   - Run controls only in the toolbar's Run menu and ⌘K; the Dashboard shows status, not a duplicate Run button, except in its first-run empty state.
   - A single ScreenHeader, EmptyState, Badge and SelectableRow component.
   - Evidence: the counts above.
4. #4 Understandable, plain language with one name per concept:
   - Glossary: Needs You (questions and tasks for you), Review (approve before sending), Pipeline, Agent, "Collect questions", "Facts only you set", "Application site", "Applied" (one word for submitted).
   - Full site names on badges; hide token counts and pick scores behind a disclosure.
   - Evidence: about 25 jargon terms, 9 names for Needs You, 7 for the agent.
5. #8 + #9, thorough and calm:
   - Every primary screen has empty / loading / error / success / focus / disabled states.
   - Restore system focus rings: remove focusEffectDisabled on 7 containers, or draw Palette.focus.
   - textTertiary ≥ 4.5:1 in both modes; dark-mode accent buttons use ink text (white on #29AB8B is 2.88:1).
   - Status inks ≥ 3:1 (ghosted and skipped are at 1.7–2.6).
   - No continuous idle animation: the brand field is static, and drifts only while the agent is running and the window is visible; no breathing dots.
   - The menu-bar glyph honours Reduce Motion.
   - Two 500 ms polls are fine but documented.
   - Evidence: the contrast table, AgentPill.swift:65, MenuBarExtraViews.swift:29.

Redesign principles, in priority order:
1. #6 Honest: every label and default maps 1:1 to behaviour, and nothing consequential is pre-checked or hidden.
2. #4 Understandable: a first-time user can name every primary control; there is a single glossary; zero internal terms in the UI.
3. #10 As little design as possible: each screen has one primary action, one header and one surface language, and removing any element breaks a task.
4. #5 Unobtrusive: content is the figure and Liquid Glass chrome is the ground, quiet at rest. The system should feel like Apple's own macOS 26 apps (Mail, Notes, System Settings).

Deliverables for the plan:
- New design-system spec in DesignSystem/: Surface, Well, ScreenHeader, Badge, EmptyState / LoadingState / ErrorState, PrimaryPill / SecondaryLink buttons, SelectableRow, GlassBar (floating control). Delete the components that are no longer used.
- A per-screen redesign spec (Dashboard, Needs You, Review, Pipeline, Job detail, Settings, Onboarding, Menu bar, ⌘K, Inspector) with a low-fi before / after layout. Note the one primary action and the states for each screen.
- Copy deck: the glossary plus a rewrite of every flagged string.
- States checklist per screen: empty, loading, error, success, focus, disabled.
- Migration and cutover: no flag and no dual designs. Screens are migrated in one series of commits. The old components are deleted when the last caller moves. Tests are updated, including the render tests (ImageRenderer: avoid onGeometryChange or state-writing onDisappear in rendered views).
- A sequencing note: the Cold Email screens are about to be built on top of this system, so the design-system pieces must land first.

Anti-patterns to guard against:
- Porting the old structure under the new styling, e.g. re-skinning 9 surfaces instead of deleting 7.
- Keeping both designs behind a flag.
- Redesigning to follow a trend: glass for glass's sake, or gradients as decoration.
- Treating the Preserve list as optional.
```
