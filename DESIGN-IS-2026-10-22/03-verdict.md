# Verdict: REDESIGN (the UI layer)

**Total: 11/30.** Principle #6 (honest), which carries the most weight, scored 0, so by the rule the verdict is REDESIGN.

The engine, data model and core flows are sound. The interaction and visual layer is not: four systems are stacked on top of each other — the old purple-era components, the new palette, Liquid Glass applied everywhere, and one-off views. It needs to be redesigned from purpose: content first, glass only on the control layer, one surface, one primary action per screen, and plain, honest words.

## Highest-leverage moves

1. **#6 Honest.**
   - Make every consequential default explicit:
     - Account creation is opt-in, with its own consent row. It must not be switched on by connecting a mailbox.
     - Save-to-memory and auto-install defaults are shown, not assumed.
   - Remove the fake "Join beta" waitlist.
   - Rewrite the 14 inflated claims ("Let's get you hired", "Everything stays on this Mac", "no invented facts", "jobs resumed").
   - Evidence: `FinishSteps.swift:59`, `ColdEmailView.swift:127-130`, `IgnitionView.swift:58,190,203`, `QATable.swift:179`, `InboxModel.swift:560`.
2. **#3 Aesthetic and #5 Unobtrusive: a Liquid Glass hierarchy.**
   - Glass only on the navigation / control layer: toolbar, sidebar, floating bars, palette, toasts.
   - Content sits on one flat surface (`surface` plus hairline). There are no glass buttons inside cards; in-content actions use the ink/white pill (`primaryFill` / `onPrimaryFill`, defined but unused) or text links.
   - Retire `surfaceCard` / `sunkenWell` / ad-hoc backgrounds in favour of 2 surface kinds, and remove the 4 shadows.
   - Evidence: about 81 glass buttons, mostly in content (`LiveAgentCard.swift:143-159`, `KPIWidgets.swift:58`, `SettingsTabs.swift:468`); 9 surface kinds; the inspector's own material, shadow and radius (`RootView.swift:241-245`).
3. **#10 As little design as possible and #2 Useful: one path per action, one primary per screen.**
   - At most one prominent button visible per screen.
   - One way to approve (the Review screen / Job detail; the mode popover never approves).
   - Run controls live only in the toolbar and ⌘K.
   - One header component, one empty-state component, one badge component.
   - Evidence: Run now ×6, Approve ×8+, 6 empty-state styles, ≥10 header kinds; the popover bypass at `RootView.swift:159`.
4. **#4 Understandable: plain language and one name per concept.**
   - "Collect questions" (not "Prep pass").
   - "Facts only you set" (not "never-guess").
   - "Application site" (not "ATS").
   - "Agent" (not autoapplyd / daemon / LaunchAgent).
   - Badges show full site names.
   - Hide tokens and pick scores.
   - Evidence: about 25 jargon terms; 9 names for Needs You, 7 for the agent (§3).
5. **#8 Thorough and #9 Environmentally friendly: states, contrast, calm.**
   - Add the missing states: loading and error on Needs You and Review, disabled on the Board, focus on every screen.
   - Restore the system focus ring.
   - Raise `textTertiary` to at least 4.5:1, and use dark text on the dark-mode accent.
   - No continuous idle animation: the mesh is static, or only moves while the agent works, and nothing breathes.
   - Honour Reduce Motion in the menu bar.
   - Evidence: `textTertiary` at 2.55–3.75:1; white on the accent at 2.88:1; 4 idle animations; `MenuBarExtraViews.swift:29`.
