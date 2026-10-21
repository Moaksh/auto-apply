// ShortcutRegistry.swift — the single source for every keyboard shortcut (docs/UI_UX_PLAN.md §3.4).
// Menus (AppCommands), buttons, the ⌘K palette and help text all read from here, so a
// shortcut is defined once.
import SwiftUI

enum AppShortcut: String, CaseIterable, Identifiable, Sendable {
    // Navigation
    case goDashboard, goNeedsYou, goReview, goPipeline, goEasyApply, goProfile, goResumes, goStories, goActivity, goColdEmail
    case commandPalette
    case toggleInspector
    case toggleSidebar
    case openSettings
    case openMainWindow
    case openJobWindow
    case filter
    case escape
    // Agent
    case togglePause
    case runNow
    case runPrep
    case applyQueued
    case nextQuestion
    case addJobByLink
    // Lists / jobs
    case openSelected
    /// ⌘↵: answer in Needs You; Approve & submit in Job detail (awaiting review, also in ⌘K).
    case submit
    case moveStatusPrevious
    case moveStatusNext
    case quickLook
    case copyAll
    // Single-key, view-local (handled with onKeyPress; never in menus)
    case approve
    case toggleSelection
    case skip
    case copyFocused
    case openPosting
    case selectAll

    var id: String { rawValue }

    /// Where the shortcut lives. `.menu` shortcuts are installed as menu items (global);
    /// `.local` ones are handled by the focused view with `.onKeyPress` so they never fire
    /// while typing in a text field.
    enum Scope: Sendable { case menu, local }

    var scope: Scope {
        switch self {
        case .approve, .toggleSelection, .skip, .copyFocused, .openPosting, .openSelected, .escape, .quickLook, .selectAll:
            .local
        default:
            .menu
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .goDashboard: "1"
        case .goNeedsYou: "2"
        case .goReview: "3"
        case .goPipeline: "4"
        case .goEasyApply: "5"
        case .goProfile: "6"
        case .goResumes: "7"
        case .goStories: "8"
        case .goActivity: "9"
        case .goColdEmail: "0"
        case .commandPalette: "k"
        case .toggleInspector: "i"
        case .toggleSidebar: "s"
        case .openSettings: ","
        case .openMainWindow: "o"
        case .openJobWindow: "o"
        case .filter: "f"
        case .escape: .escape
        case .togglePause: "p"
        case .runNow: "r"
        case .runPrep: "r"
        case .applyQueued: "r"
        case .nextQuestion: "j"
        case .addJobByLink: "n"
        case .openSelected: .return
        case .submit: .return
        case .moveStatusPrevious: .leftArrow
        case .moveStatusNext: .rightArrow
        case .quickLook: .space
        case .copyAll: "c"
        case .approve: "a"
        case .toggleSelection: "x"
        case .skip: "s"
        case .copyFocused: "c"
        case .openPosting: "o"
        case .selectAll: "a"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .goDashboard, .goNeedsYou, .goReview, .goPipeline, .goEasyApply, .goProfile, .goResumes, .goStories, .goActivity, .goColdEmail:
            .command
        case .commandPalette, .openSettings, .openMainWindow, .filter, .runNow, .nextQuestion, .submit, .addJobByLink,
             .moveStatusPrevious, .moveStatusNext, .selectAll:
            .command
        case .toggleInspector, .applyQueued: [.command, .option]
        case .toggleSidebar: [.command, .control]
        case .openJobWindow, .togglePause, .runPrep, .copyAll: [.command, .shift]
        case .escape, .openSelected, .quickLook, .approve, .toggleSelection, .skip, .copyFocused, .openPosting:
            []
        }
    }

    var title: String {
        switch self {
        case .goDashboard: "Go to Dashboard"
        case .goNeedsYou: "Go to Needs You"
        case .goReview: "Go to Review"
        case .goPipeline: "Go to Pipeline"
        case .goEasyApply: "Go to Easy Apply"
        case .goProfile: "Go to Profile"
        case .goResumes: "Go to Resumes"
        case .goStories: "Go to Story Bank"
        case .goActivity: "Go to Activity"
        case .goColdEmail: "Go to Cold Email"
        case .commandPalette: "Command Palette"
        case .toggleInspector: "Show or Hide Details"
        case .toggleSidebar: "Toggle Sidebar"
        case .openSettings: "Settings…"
        case .openMainWindow: "Open AutoApply"
        case .openJobWindow: "Open Job in New Window"
        case .filter: "Filter"
        case .escape: "Close / Deselect"
        case .togglePause: "Pause / Resume Agent"
        case .runNow: "Run Now"
        case .runPrep: "Collect Questions Only"
        case .applyQueued: "Apply Queued Jobs Only"
        case .nextQuestion: "Answer Next Question"
        case .addJobByLink: "Add Job by Link…"
        case .openSelected: "Open Selected"
        case .submit: "Submit / Approve"
        case .moveStatusPrevious: "Move to Previous Status"
        case .moveStatusNext: "Move to Next Status"
        case .quickLook: "Quick Look Screenshot"
        case .copyAll: "Copy All Answers"
        case .approve: "Approve"
        case .toggleSelection: "Toggle Selection"
        case .skip: "Skip"
        case .copyFocused: "Copy Answer"
        case .openPosting: "Open Posting"
        case .selectAll: "Select All"
        }
    }

    var symbol: String {
        switch self {
        case .goDashboard: SidebarItem.dashboard.symbol
        case .goNeedsYou: SidebarItem.needsYou.symbol
        case .goReview: SidebarItem.review.symbol
        case .goPipeline: SidebarItem.pipeline.symbol
        case .goEasyApply: SidebarItem.easyApply.symbol
        case .goProfile: SidebarItem.profile.symbol
        case .goResumes: SidebarItem.resumes.symbol
        case .goStories: SidebarItem.stories.symbol
        case .goActivity: SidebarItem.activity.symbol
        case .goColdEmail: SidebarItem.coldEmail.symbol
        case .commandPalette: "magnifyingglass"
        case .toggleInspector: "sidebar.right"
        case .toggleSidebar: "sidebar.left"
        case .openSettings: "gear"
        case .openMainWindow: "macwindow"
        case .openJobWindow: "macwindow.badge.plus"
        case .filter: "line.3.horizontal.decrease"
        case .escape: "escape"
        case .togglePause: "pause.fill"
        case .runNow: "play.fill"
        case .runPrep: "tray.and.arrow.down"
        case .applyQueued: "paperplane.fill"
        case .nextQuestion: "hand.raised.fill"
        case .addJobByLink: "link.badge.plus"
        case .openSelected: "arrow.up.forward.square"
        case .submit: "checkmark.circle"
        case .moveStatusPrevious: "arrow.left"
        case .moveStatusNext: "arrow.right"
        case .quickLook: "eye"
        case .copyAll: "doc.on.doc"
        case .approve: "checkmark"
        case .toggleSelection: "checkmark.square"
        case .skip: "arrow.uturn.right"
        case .copyFocused: "doc.on.clipboard"
        case .openPosting: "safari"
        case .selectAll: "checklist"
        }
    }

    /// "⌘⇧P", "⌘1", "A".
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .return: s += "↵"
        case .escape: s += "esc"
        case .leftArrow: s += "←"
        case .rightArrow: s += "→"
        case .upArrow: s += "↑"
        case .downArrow: s += "↓"
        case .space: s += "Space"
        case .delete: s += "⌫"
        default: s += String(key.character).uppercased()
        }
        return s
    }

    static func go(_ item: SidebarItem) -> AppShortcut {
        switch item {
        case .dashboard: .goDashboard
        case .needsYou: .goNeedsYou
        case .review: .goReview
        case .pipeline: .goPipeline
        case .easyApply: .goEasyApply
        case .profile: .goProfile
        case .resumes: .goResumes
        case .stories: .goStories
        case .activity: .goActivity
        case .coldEmail: .goColdEmail
        }
    }

    /// Combination identity for duplicate detection.
    var combo: String { "\(modifiers.rawValue)-\(String(key.character))" }
}

extension View {
    /// Attach a registry shortcut to a button/menu item.
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }

    /// Handle a `.local` single-key shortcut on a focused view.
    func onShortcut(_ shortcut: AppShortcut, perform action: @escaping () -> Void) -> some View {
        onKeyPress(shortcut.key, phases: .down) { press in
            let relevant: EventModifiers = [.command, .shift, .option, .control]
            guard press.modifiers.intersection(relevant) == shortcut.modifiers else { return .ignored }
            action()
            return .handled
        }
    }
}
