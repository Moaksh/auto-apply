# Scorecard: AutoApply macOS UI (2026-10-22)

| # | Principle | Score |
|---|---|---|
| 1 | Innovative | 2/3 |
| 2 | Useful | 2/3 |
| 3 | Aesthetic | 1/3 |
| 4 | Understandable | 1/3 |
| 5 | Unobtrusive | 1/3 |
| 6 | Honest | **0/3** |
| 7 | Long-lasting | 1/3 |
| 8 | Thorough | 1/3 |
| 9 | Environmentally friendly | 1/3 |
| 10 | As little design as possible | 1/3 |
| | **Total** | **11/30** |

## 1. Good design is innovative: 2/3
- **Evidence:** the live agent card, the pipeline flow, and "answer once, every job asking it resumes" (Needs You clusters) are real refreshes. The shell, sidebar and cards are standard macOS patterns.
- **Why 2:** it clearly improves on existing patterns, but nothing is new across peer products and none of it is restrained.

## 2. Good design makes a product useful: 2/3
- **Evidence:** every primary action is keyboard-reachable (§2 Accessibility). Approve has 8+ entry points, and the toolbar mode popover's "Approve N" skips the safeguard (`RootView.swift:159`).
- **Why 2:** the primary tasks complete, but adjacent surfaces add detours and duplicate paths. That isn't 3.

## 3. Good design is aesthetic: 1/3
- **Evidence:** the token system exists, but it's overridden by:
  - 9 surface kinds and 7+ button styles
  - 26 raw radii and 230 raw frames
  - two competing greens
  - an inspector with its own material, shadow and radius
  - glass on content
  - the new ink/white pill tokens left unused (§1, §2)
- **Why 1:** far more than 5 inconsistencies, and several jarring ones. It's not 0 because a visible token system does exist.

## 4. Good design makes a product understandable: 1/3
- **Evidence:**
  - about 25 jargon terms ("Prep pass", "never-guess", "ATS", "Inherit", "autoapplyd", "parked", "pick 0.83", …)
  - 9 names for "questions waiting on you" and 7 for the background agent (§3)
- **Why 1:** jargon is pervasive and several controls are unclear. The primary action is still identifiable, so not 0.

## 5. Good design is unobtrusive: 1/3
- **Evidence:**
  - 4 continuous idle animations, including the 20 fps mesh on Dashboard, menu bar and empty states (§4)
  - 3 surfaces for one "daemon down" fact
  - about 81 glass buttons, mostly inside content cards
  - 4 of 8 screens with more than one prominent button
- **Why 1:** decoration and chrome compete with content. It isn't dominant everywhere, so not 0.

## 6. Good design is honest: 0/3
- **Evidence:**
  - Connecting the "Security codes (optional)" mailbox silently turns on account creation on third-party sites (`create_accounts` defaults to true; `FinishSteps.swift:59`).
  - Cold Email "Join beta" only sets a local bool but promises "We'll turn it on for you first" (`ColdEmailView.swift:127-130`).
  - 14 inflations ("Let's get you hired", "Everything stays on this Mac", "no invented facts", "jobs resumed") (§3).
- **Why 0:** the hidden-consequence default and the false waitlist promise are deceptive flows. The tie-breaker rule says to take the lower score.

## 7. Good design is long-lasting: 1/3
- **Evidence:**
  - always-on animated mesh gradients
  - glass applied everywhere, including content
  - confetti and celebration flourishes on routine actions
- **Why 1:** 2–3 trend markers that will date quickly, but the core layout is timeless macOS, so not 0.

## 8. Good design is thorough down to the last detail: 1/3
- **Evidence:**
  - Review has no screen-level loading or error state; Inbox the same.
  - Board has no disabled state.
  - Focus is missing on Dashboard, Settings and onboarding steps; the focus ring is suppressed on 7 containers.
  - 12 of 35 icon buttons have no label.
  - `textTertiary` (131 uses) is below 4.5:1 everywhere, and white on the dark accent is 2.88:1 (§2).
- **Why 1:** the worst screen is missing 2–3 states, and there are contrast failures on core tokens.

## 9. Good design is environmentally friendly: 1/3
- **Evidence:**
  - the idle 20 fps mesh on the Dashboard and menu bar
  - the status-dot breathe, not visibility-gated, on every screen
  - two 500 ms poll loops
  - the menu-bar glyph ignores Reduce Motion
  - dark mode is honoured, and most motion is gated (§2, §4)
- **Why 1:** motion is largely gated, but idle animation is present and partly ungated. The rule says to score the worst instance.

## 10. Good design is as little design as possible: 1/3
- **Evidence:**
  - Run now ×6, Approve ×8+, Prep ×5
  - 6 empty-state styles, ≥10 header kinds
  - the question text rendered twice
  - 3 hidden shortcut buttons
  - 8 Settings tabs (§1)
- **Why 1:** 3–5 classes of removable or duplicated affordances, short of total domination.
