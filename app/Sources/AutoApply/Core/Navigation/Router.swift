// Router.swift — navigation model for the main window.
import Observation
import SwiftUI

/// Sidebar sections, in ⌘1…⌘9 order.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard, needsYou, review, pipeline, easyApply, profile, resumes, stories, activity, coldEmail

    var id: String { rawValue }

    enum Section: String, CaseIterable, Sendable {
        case now, library, system

        var title: String? {
            switch self {
            case .now: nil
            case .library: "Library"
            case .system: "System"
            }
        }

        var items: [SidebarItem] { SidebarItem.allCases.filter { $0.section == self } }
    }

    var section: Section {
        switch self {
        case .dashboard, .needsYou, .review, .pipeline, .easyApply, .coldEmail: .now
        case .profile, .resumes, .stories: .library
        case .activity: .system
        }
    }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .needsYou: "Needs You"
        case .review: "Review"
        case .pipeline: "Pipeline"
        case .easyApply: "Easy Apply"
        case .coldEmail: "Cold Email"
        case .profile: "Profile"
        case .resumes: "Resumes"
        case .stories: "Story Bank"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .needsYou: "hand.raised"
        case .review: "checkmark.rectangle.stack"
        case .pipeline: "rectangle.split.3x1"
        case .easyApply: "bolt.horizontal"
        case .coldEmail: "envelope.open"
        case .profile: "person.text.rectangle"
        case .resumes: "doc.on.doc"
        case .stories: "text.book.closed"
        case .activity: "list.bullet.rectangle"
        }
    }

    /// The registry screen rendered for this item.
    var screen: ScreenID {
        switch self {
        case .dashboard: .dashboard
        case .needsYou: .inbox
        case .review: .review
        case .pipeline: .board
        case .easyApply: .easyApply
        case .coldEmail: .coldEmail
        case .profile: .profile
        case .resumes: .resumes
        case .stories: .stories
        case .activity: .activityLog
        }
    }

    /// 1-based ⌘-number shortcut.
    var shortcutNumber: Int { self == .coldEmail ? 0 : (SidebarItem.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// Things pushed onto the detail column's navigation stack.
enum Destination: Hashable, Sendable {
    case job(id: Int)
    /// Dashboard ▸ What's working (the advisory insights report).
    case insights
}

/// Deep-link filters other screens can set before navigating (e.g. hero "27 skipped" label).
struct PipelineFilter: Hashable, Sendable {
    var columns: Set<BoardColumn>? = nil
    var skipReason: String? = nil
    var status: BoardStatus? = nil
    var source: JobSource? = nil
    var minScore: Int? = nil
    var showSkipped = false
    var searchText = ""
}

struct ActivityFilter: Hashable, Sendable {
    enum Scope: String, CaseIterable, Sendable { case all, agent, you, errors }
    var scope: Scope = .all
    var day: Date? = nil
    var jobID: Int? = nil
    var searchText = ""
}

@MainActor
@Observable
final class Router {
    var selection: SidebarItem = .dashboard {
        didSet {
            guard oldValue != selection else { return }
            path.removeAll()
            // A focused job only means something in Pipeline; leaving it must not leave the
            // Job-menu shortcuts (⌘← / ⌘→) armed against an off-screen job.
            if selection != .pipeline { focusedJobID = nil }
        }
    }
    /// Detail-column stack (e.g. Pipeline -> Job detail).
    var path: [Destination] = []
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isInspectorPresented = false
    var isPalettePresented = false
    /// The "Add job by link" sheet, optionally seeded with a URL (e.g. pasted into ⌘K).
    var isAddJobPresented = false
    var addJobSeed = ""
    /// Initial query to seed the palette with (e.g. a scope prefix like ">").
    var paletteSeed = ""
    /// The job currently focused in Pipeline / lists (drives the inspector and job shortcuts).
    var focusedJobID: Int?
    var pipelineFilter = PipelineFilter()
    var activityFilter = ActivityFilter()
    /// Bumped to ask the Settings scene to open (views observe it and call `openSettings`).
    private(set) var settingsRequest = 0
    /// Bumped to ask the main window to come forward (from menu bar / notifications).
    private(set) var mainWindowRequest = 0
    /// Job ids requested to open in their own window.
    private(set) var jobWindowRequest: JobWindowRequest?
    /// Bumped to ask the on-screen Job detail to approve its job (⌘K "Approve & submit"); the
    /// detail runs it through the same low-confidence safeguard as its button and ⌘↵.
    private(set) var jobApproveRequest: JobActionRequest?
    /// Bumped to ask the on-screen Job detail to show a tab (⌘K "Interview prep: …").
    private(set) var jobTabRequest: JobTabRequest?

    struct JobWindowRequest: Equatable, Sendable {
        var id: Int
        var serial: Int
    }

    struct JobActionRequest: Equatable, Sendable {
        var jobID: Int
        var serial: Int
    }

    struct JobTabRequest: Equatable, Sendable {
        var jobID: Int
        /// A `JobDetailTab` raw value.
        var tab: String
        var serial: Int
    }

    init() {}

    /// The job whose detail page is on top of the detail column, if any.
    var openJobDetailID: Int? {
        if case .job(let id) = path.last { return id }
        return nil
    }

    /// Open `jobID`'s detail on `tab` (a `JobDetailTab` raw value), from anywhere.
    func openJob(id: Int, tab: String) {
        if openJobDetailID != id {
            if selection != .pipeline { selection = .pipeline }
            openJob(id: id)
        }
        jobTabRequest = JobTabRequest(jobID: id, tab: tab, serial: (jobTabRequest?.serial ?? 0) + 1)
    }

    /// Dashboard ▸ What's working.
    func showInsights() {
        selection = .dashboard
        if path.last != .insights { path = [.insights] }
    }

    func requestApprove(jobID: Int) {
        jobApproveRequest = JobActionRequest(jobID: jobID, serial: (jobApproveRequest?.serial ?? 0) + 1)
    }

    /// True while a job is on screen as the focus: Pipeline with a focused job, or a pushed
    /// job detail. Gates the Job-menu key equivalents.
    var isJobContextActive: Bool {
        guard focusedJobID != nil else { return false }
        if case .job = path.last { return true }
        return selection == .pipeline
    }

    func go(_ item: SidebarItem) {
        selection = item
    }

    func openJob(id: Int) {
        focusedJobID = id
        if path.last != .job(id: id) {
            path.append(.job(id: id))
        }
    }

    func openJobInWindow(id: Int) {
        jobWindowRequest = JobWindowRequest(id: id, serial: (jobWindowRequest?.serial ?? 0) + 1)
    }

    func showPipeline(filter: PipelineFilter) {
        pipelineFilter = filter
        selection = .pipeline
    }

    func showActivity(filter: ActivityFilter) {
        activityFilter = filter
        selection = .activity
    }

    func back() {
        if !path.isEmpty { path.removeLast() }
    }

    func togglePalette(seed: String = "") {
        paletteSeed = seed
        isPalettePresented.toggle()
    }

    func requestAddJob(url: String = "") {
        addJobSeed = url
        isPalettePresented = false
        isAddJobPresented = true
    }

    func toggleInspector() { isInspectorPresented.toggle() }

    func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    func requestSettings() { settingsRequest += 1 }
    func requestMainWindow() { mainWindowRequest += 1 }

    /// Esc: close palette, then inspector, then pop / deselect.
    func escape() {
        if isPalettePresented { isPalettePresented = false; return }
        if isInspectorPresented { isInspectorPresented = false; return }
        if !path.isEmpty { path.removeLast(); return }
        focusedJobID = nil
    }
}
