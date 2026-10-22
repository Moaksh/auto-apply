// DayLineWindowShots.swift — opt-in visual review: hosts the Dashboard (with the day line) and a
// Job detail header in an offscreen NSWindow (AppKit's cacheDisplay draws ScrollViews, unlike
// ImageRenderer) with the mock dataset and writes PNGs, light and dark. Skipped unless
// AUTOAPPLY_DAYLINE_SHOTS names a folder.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Day line window shots", .serialized)
struct DayLineWindowShots {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["AUTOAPPLY_DAYLINE_SHOTS"]

    func shoot<V: View>(_ name: String, store: AppStore, scheme: ColorScheme, width: CGFloat, height: CGFloat,
                        @ViewBuilder _ view: () -> V) async {
        let root = view()
            .appEnvironment(store, simulateReduceMotion: true)
            .environment(\.colorScheme, scheme)
            .environment(\.heroGlassOpaque, true)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        // Far off any screen: nothing appears on the desktop.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        let end = Date().addingTimeInterval(1.0)
        while Date() < end {
            WindowHost.spin()
            await Task.yield()
        }
        if let dir = Self.outDir, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        window.orderOut(nil)
        window.close()
    }

    @Test(.enabled(if: outDir != nil)) func dashboardAndJobDetail() async throws {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: MockScenario.idle.rawValue)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.outreach.isLoaded && store.outreach.repliesLoaded }
        store.recomputeStats()
        let review = try #require(MockScripts.reviewSampleJobIDs.compactMap { store.jobs.job(id: $0) }.first)
        let applied = try #require(store.jobs.all.first { $0.state == .submitted && $0.submittedAt.map { Calendar.current.isDateInToday($0) } == true })
        for scheme in [ColorScheme.light, .dark] {
            await shoot("dashboard", store: store, scheme: scheme, width: 1240, height: 1100) { DashboardView() }
            await shoot("day-line", store: store, scheme: scheme, width: 1100, height: 260) {
                DayLineCard().padding(Space.contentPadding)
            }
            await shoot("job-detail-review", store: store, scheme: scheme, width: 1200, height: 520) { JobDetailView(jobID: review.id) }
            await shoot("job-detail-applied", store: store, scheme: scheme, width: 1200, height: 520) { JobDetailView(jobID: applied.id) }
        }
        await store.stop()

        let emptyDaemon = MockDaemon(scenario: .firstRunEmpty, speed: 50)
        let empty = AppStore(client: emptyDaemon, repository: emptyDaemon.repository, mockScenarioName: MockScenario.firstRunEmpty.rawValue)
        empty.start()
        _ = await waitUntil { empty.hasSnapshot && empty.jobs.isLoaded }
        for scheme in [ColorScheme.light, .dark] {
            await shoot("day-line-empty", store: empty, scheme: scheme, width: 1100, height: 200) {
                DayLineCard().padding(Space.contentPadding)
            }
        }
        await empty.stop()
    }
}
