// AppAction.swift — named, app-wide actions shared by menus, toolbar, ⌘K palette and the menu
// bar, so every action exists once with its title, symbol and shortcut.
import AppKit
import Foundation

enum AppAction: Hashable, Sendable, Identifiable {
    case togglePause
    case runNow
    case runPrep
    /// Only the apply step: fill the jobs already queued (incl. ones you just answered), no search.
    case applyQueued
    case nextQuestion
    case addJobByLink
    case go(SidebarItem)
    case setMode(Mode)
    case toggleInspector
    case toggleSidebar
    case openPalette
    case openSettings
    case openAgentChrome
    case openDataFolder
    case openMainWindow
    /// Approve & submit the awaiting-review job open in Job detail (only listed when there is one).
    case approveOpenJob

    var id: String {
        switch self {
        case .go(let item): "go.\(item.rawValue)"
        case .setMode(let m): "mode.\(m.rawValue)"
        default: String(describing: self)
        }
    }

    /// Actions listed in the ⌘K palette's ACTIONS / NAVIGATE sections.
    static var paletteActions: [AppAction] {
        [.approveOpenJob, .addJobByLink, .togglePause, .runNow, .applyQueued, .runPrep, .nextQuestion, .setMode(.auto), .setMode(.review),
         .openAgentChrome, .openDataFolder, .toggleInspector, .openSettings]
            + SidebarItem.allCases.map { .go($0) }
    }

    var isNavigation: Bool { if case .go = self { true } else { false } }

    var shortcut: AppShortcut? {
        switch self {
        case .togglePause: .togglePause
        case .runNow: .runNow
        case .runPrep: .runPrep
        case .applyQueued: .applyQueued
        case .nextQuestion: .nextQuestion
        case .addJobByLink: .addJobByLink
        case .go(let item): .go(item)
        case .toggleInspector: .toggleInspector
        case .toggleSidebar: .toggleSidebar
        case .openPalette: .commandPalette
        case .openSettings: .openSettings
        case .openMainWindow: .openMainWindow
        case .approveOpenJob: .submit
        case .setMode, .openAgentChrome, .openDataFolder: nil
        }
    }

    @MainActor
    func title(in store: AppStore) -> String {
        switch self {
        case .togglePause: store.isPaused ? "Resume agent" : "Pause agent"
        case .runNow: "Run now: find, score and apply"
        case .runPrep: "Collect questions only"
        case .applyQueued: "Apply queued jobs only (no new search)"
        case .nextQuestion: "Answer next question"
        case .addJobByLink: "Add job by link"
        case .go(let item): "Go to \(item.title)"
        case .setMode(let m): m == .auto ? "Switch to Auto mode" : "Switch to Review mode"
        case .toggleInspector: "Show or hide details"
        case .toggleSidebar: "Toggle sidebar"
        case .openPalette: "Command palette"
        case .openSettings: "Open Settings"
        case .openAgentChrome: "Open the agent's Chrome"
        case .openDataFolder: "Open data folder"
        case .openMainWindow: "Open AutoApply"
        case .approveOpenJob: approvableJob(in: store).map { "Approve & submit \($0.company)" } ?? "Approve & submit"
        }
    }

    /// Whether the action applies right now (the palette hides ones that don't).
    @MainActor
    func isAvailable(in store: AppStore) -> Bool {
        switch self {
        case .approveOpenJob: approvableJob(in: store) != nil
        default: true
        }
    }

    /// The job open in Job detail when it's awaiting review.
    @MainActor
    func approvableJob(in store: AppStore) -> JobItem? {
        guard let id = store.router.openJobDetailID, let job = store.jobs.job(id: id), job.state == .awaitingReview else { return nil }
        return job
    }

    @MainActor
    func symbol(in store: AppStore) -> String {
        switch self {
        case .togglePause: store.isPaused ? "play.fill" : "pause.fill"
        case .runNow: "play.fill"
        case .runPrep: "tray.and.arrow.down"
        case .applyQueued: "paperplane.fill"
        case .nextQuestion: "hand.raised.fill"
        case .addJobByLink: "link.badge.plus"
        case .go(let item): item.symbol
        case .setMode(let m): m == .auto ? "bolt.fill" : "checkmark.rectangle.stack"
        case .toggleInspector: "sidebar.right"
        case .toggleSidebar: "sidebar.left"
        case .openPalette: "magnifyingglass"
        case .openSettings: "gear"
        case .openAgentChrome: "globe"
        case .openDataFolder: "folder"
        case .openMainWindow: "macwindow"
        case .approveOpenJob: "paperplane.fill"
        }
    }
}

extension AppStore {
    /// Execute an app action. Window-level effects (Settings, main window) are routed through
    /// `Router` requests that the shell observes.
    func perform(_ action: AppAction) async {
        switch action {
        case .togglePause: await togglePause()
        case .runNow: await runNow(.full)
        case .runPrep: await runPrepPass()
        case .applyQueued: await applyQueued()
        case .nextQuestion:
            router.go(.needsYou)
        case .addJobByLink: router.requestAddJob()
        case .go(let item): router.go(item)
        case .setMode(let mode): await setMode(mode)
        case .toggleInspector: router.toggleInspector()
        case .toggleSidebar: router.toggleSidebar()
        case .openPalette: router.togglePalette()
        case .openSettings: router.requestSettings()
        case .openAgentChrome: await openAgentChrome()
        case .openDataFolder:
            let home = AppPaths.resolve().home
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            NSWorkspace.shared.open(home)
        case .openMainWindow: router.requestMainWindow()
        case .approveOpenJob:
            if let job = action.approvableJob(in: self) { router.requestApprove(jobID: job.id) }
        }
    }
}
