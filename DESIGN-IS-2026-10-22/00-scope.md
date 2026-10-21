# Scope

**Audited:** the AutoApply macOS app UI, `app/Sources/AutoApply` (SwiftUI, macOS 26, Liquid Glass APIs), at commit 298f48b plus the v0.1.3 retheme (ink / stone / deep-green tokens in `DesignSystem/Tokens.swift`, the live `BrandGradientField`).

**Screens:**
- Shell: sidebar, toolbar, inspector
- Dashboard (greeting band, live agent card)
- Needs You
- Review
- Pipeline (board and table)
- Job detail
- Easy Apply
- Cold Email (placeholder)
- Profile, Resumes, Story Bank, Activity
- Settings (8 tabs)
- Onboarding
- Menu-bar popover
- Command palette
- Toasts and overlays

**Primary user:** a job seeker, often a first-time user, who runs an agent that finds and applies to jobs.

**Primary task:** see what the agent did and what needs them: answer questions, approve applications, track outcomes. Everything else is secondary.

**Owner's complaint:** "color scheme is on point to the design theme but the rest, ehh." The UI doesn't fit the new palette.

**Goal:** a minimal, Apple Liquid Glass–native design ("Apple liquid glass, crazy").

**Constraints:**
- SwiftUI on macOS 26.
- Keep the ink / stone / deep-green palette.
- Respect Reduce Motion and dark mode.
- Engine and protocol are out of scope.
- Cold Email is about to be rebuilt by another agent, so it's audited only as a placeholder.

**References:**
- Apple's macOS 26 apps (Finder, Mail, Notes, System Settings) and Apple's Liquid Glass guidance: glass for the navigation / control layer floating over content, and content not glass.
- Cohere-style editorial restraint (the source of the palette).

**Method:** static repo, no running instance driven, so visual facts are INFERRED from source and tokens. Existing render-test snapshots are in scratchpad/snaps.
