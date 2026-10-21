// ScreenRegistry.swift — lets feature workstreams (C2/C3) plug their screens into the app
// shell without editing shell files.
//
// How a feature registers (in its OWN directory, no shell edits needed):
//
//   @objc(DashboardFeature)                 // the runtime name MUST match ScreenRegistry.featureClassNames
//   final class DashboardFeature: NSObject, FeatureRegistrant {
//       static func register(in registry: ScreenRegistry) {
//           registry.register(.dashboard) { DashboardView() }
//       }
//   }
//
// At launch the shell calls `discoverFeatures()`, which looks each well-known class name up
// with NSClassFromString and calls its `register(in:)`. Screens nobody registered render a
// labeled placeholder, so the app always builds and runs.
import AppKit
import Observation
import SwiftUI

/// Every pluggable screen. Raw values are stable identifiers.
enum ScreenID: String, CaseIterable, Sendable, Hashable {
    case dashboard, inbox, review, board, easyApply, coldEmail, profile, resumes, stories, activityLog, settings, commandPalette

    /// The view type the owning workstream is expected to provide.
    var expectedViewName: String {
        switch self {
        case .dashboard: "DashboardView"
        case .inbox: "InboxView"
        case .review: "ReviewQueueView"
        case .board: "BoardView"
        case .easyApply: "EasyApplyView"
        case .coldEmail: "ColdEmailView"
        case .profile: "ProfileView"
        case .resumes: "ResumesView"
        case .stories: "StoryBankView"
        case .activityLog: "ActivityLogView"
        case .settings: "SettingsView"
        case .commandPalette: "CommandPaletteView"
        }
    }

    var owner: String {
        switch self {
        case .dashboard, .board, .activityLog: "C2"
        default: "C3"
        }
    }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .inbox: "Needs You"
        case .review: "Review"
        case .board: "Pipeline"
        case .easyApply: "Easy Apply"
        case .coldEmail: "Cold Email"
        case .profile: "Profile"
        case .resumes: "Resumes"
        case .stories: "Story Bank"
        case .activityLog: "Activity"
        case .settings: "Settings"
        case .commandPalette: "Command Palette"
        }
    }
}

/// Implemented by one NSObject subclass per feature folder (see file header).
@MainActor
protocol FeatureRegistrant: AnyObject {
    static func register(in registry: ScreenRegistry)
}

@MainActor
@Observable
final class ScreenRegistry {
    static let shared = ScreenRegistry()

    /// Runtime class names probed by `discoverFeatures()` — one per feature folder.
    /// C2: DashboardFeature, BoardFeature, JobDetailFeature, ActivityLogFeature.
    /// C3: InboxFeature, ReviewFeature, EasyApplyFeature, ProfileFeature, ResumesFeature,
    ///     SettingsFeature, CommandPaletteFeature.
    static let featureClassNames: [String] = [
        "DashboardFeature", "BoardFeature", "JobDetailFeature", "ActivityLogFeature",
        "InboxFeature", "ReviewFeature", "EasyApplyFeature", "ColdEmailFeature", "ProfileFeature", "ResumesFeature",
        "SettingsFeature", "CommandPaletteFeature",
    ]

    typealias ScreenFactory = @MainActor () -> AnyView
    typealias JobFactory = @MainActor (Int) -> AnyView

    private var screens: [ScreenID: ScreenFactory] = [:]
    private var inspectors: [ScreenID: ScreenFactory] = [:]
    private var jobDetailFactory: JobFactory?
    private var jobInspectorFactory: JobFactory?
    private(set) var discoveredFeatures: [String] = []

    init() {}

    // MARK: Registration

    func register<V: View>(_ id: ScreenID, @ViewBuilder _ make: @escaping @MainActor () -> V) {
        screens[id] = { AnyView(make()) }
    }

    /// Content for the trailing inspector while `id` is on screen (⌘⌥I toggles it).
    func registerInspector<V: View>(for id: ScreenID, @ViewBuilder _ make: @escaping @MainActor () -> V) {
        inspectors[id] = { AnyView(make()) }
    }

    /// The Job Detail screen (pushed in the detail column and used by the pop-out window).
    func registerJobDetail<V: View>(@ViewBuilder _ make: @escaping @MainActor (Int) -> V) {
        jobDetailFactory = { AnyView(make($0)) }
    }

    /// Inspector summary for a focused job (Pipeline shows it).
    func registerJobInspector<V: View>(@ViewBuilder _ make: @escaping @MainActor (Int) -> V) {
        jobInspectorFactory = { AnyView(make($0)) }
    }

    func unregisterAll() {
        screens.removeAll()
        inspectors.removeAll()
        jobDetailFactory = nil
        jobInspectorFactory = nil
        discoveredFeatures.removeAll()
    }

    /// Probe `featureClassNames` (plus `extra`) and let each found feature register itself.
    func discoverFeatures(extra: [String] = []) {
        for name in Self.featureClassNames + extra where !discoveredFeatures.contains(name) {
            guard let cls = NSClassFromString(name), let feature = cls as? any FeatureRegistrant.Type else { continue }
            feature.register(in: self)
            discoveredFeatures.append(name)
        }
    }

    // MARK: Lookup

    func isRegistered(_ id: ScreenID) -> Bool { screens[id] != nil }
    var hasJobDetail: Bool { jobDetailFactory != nil }
    func hasInspector(for id: ScreenID) -> Bool { inspectors[id] != nil }

    func view(for id: ScreenID) -> AnyView {
        if let make = screens[id] { return make() }
        return AnyView(PlaceholderScreen(screen: id))
    }

    func inspector(for id: ScreenID) -> AnyView? { inspectors[id]?() }

    func jobDetail(id: Int) -> AnyView {
        if let make = jobDetailFactory { return make(id) }
        return AnyView(JobDetailPlaceholder(jobID: id))
    }

    func jobInspector(id: Int) -> AnyView? { jobInspectorFactory?(id) }
}

/// Shown for screens whose feature hasn't registered yet.
struct PlaceholderScreen: View {
    let screen: ScreenID

    var body: some View {
        EmptyState(
            symbol: "hammer",
            title: screen.title,
            message: "This screen isn't available in this build."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackground)
    }
}

/// Fallback job detail: shows the basics from the store so navigation is testable end to end.
struct JobDetailPlaceholder: View {
    let jobID: Int
    @Environment(AppStore.self) private var store

    var body: some View {
        if let job = store.jobs.job(id: jobID) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(job.company).font(Typography.title1)
                Text(job.title).font(Typography.title2).foregroundStyle(.secondary)
                HStack(spacing: Space.s) {
                    Badge(job: job)
                    if let score = job.score { Badge(score: score, threshold: store.preferences.matchThreshold) }
                    Text(job.ats.label).font(Typography.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyState(symbol: "questionmark.folder", title: "Job not found", message: "Job #\(jobID) isn't in the local database yet.")
        }
    }
}
