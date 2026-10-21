// C2RenderTests.swift — feature registration through C1's ScreenRegistry, and offscreen render
// smoke tests of every C2 screen/widget against the mock daemon (light + dark, Reduce Motion
// and normal). AUTOAPPLY_SNAPSHOT_DIR=<dir> writes PNGs for visual review.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("C2 · Registration & render", .serialized)
struct C2RenderTests {
    let outputDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    @Test func featuresRegisterTheirScreens() {
        let registry = ScreenRegistry()
        registry.discoverFeatures()
        #expect(registry.discoveredFeatures.contains("DashboardFeature"))
        #expect(registry.discoveredFeatures.contains("BoardFeature"))
        #expect(registry.discoveredFeatures.contains("JobDetailFeature"))
        #expect(registry.discoveredFeatures.contains("ActivityLogFeature"))
        #expect(registry.isRegistered(.dashboard))
        #expect(registry.isRegistered(.board))
        #expect(registry.isRegistered(.activityLog))
        #expect(registry.hasJobDetail)
        #expect(registry.hasInspector(for: .activityLog))
        #expect(registry.jobInspector(id: 1) != nil)
    }

    func makeStore(_ scenario: MockScenario) async -> AppStore {
        let daemon = MockDaemon(scenario: scenario, speed: 1)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
        store.statsDebounce = .milliseconds(1)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded }
        store.recomputeStats()
        return store
    }

    @discardableResult
    func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, store: AppStore, scheme: ColorScheme = .light,
                         reduceMotion: Bool = true, @ViewBuilder _ view: () -> V) -> CGImage? {
        let content = view()
            .appEnvironment(store, simulateReduceMotion: reduceMotion)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.cgImage
        if let image, let dir = outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("c2-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        return image
    }

    @Test func dashboardRendersInEveryHeroState() async {
        for scenario in [MockScenario.idle, .happyRun, .firstRunEmpty, .capReached] {
            let store = await makeStore(scenario)
            for scheme in [ColorScheme.light, .dark] {
                #expect(render("dashboard-\(scenario.rawValue)", width: 1240, height: 1500, store: store, scheme: scheme) { DashboardView() } != nil)
            }
            #expect(render("dashboard-narrow-\(scenario.rawValue)", width: 900, height: 2000, store: store, reduceMotion: false) { DashboardView() } != nil)
            await store.stop()
        }
    }

    @Test func widgetsRenderWithData() async {
        let store = await makeStore(.idle)
        #expect(store.stats.totalApplied > 0, "fixture has submissions")
        let image = render("widgets", width: 900, height: 1400, store: store) {
            VStack(spacing: Space.gutter) {
                HStack(alignment: .top, spacing: Space.gutter) { AppliedTodayCard(); NeedsYouCard(); ResponseRateCard(); CapsCard() }
                ApplicationsChart()
                HStack(alignment: .top, spacing: Space.gutter) { FunnelChart(); VariantChart() }
                HStack(alignment: .top, spacing: Space.gutter) { ScoreHistogram(); SourcesChart() }
                ActivityHeatmap()
            }
            .padding()
        }
        #expect(image != nil)
        await store.stop()
    }

    @Test func boardTableAndDetailRender() async {
        let store = await makeStore(.idle)
        let model = BoardModel(store: store)
        model.defaults = C2.isolatedDefaults()
        #expect(render("board", width: 1300, height: 800, store: store) { BoardView(model: model) } != nil)
        store.router.pipelineFilter = PipelineFilter(showSkipped: true)
        #expect(render("board-skipped", width: 1300, height: 800, store: store, scheme: .dark) { BoardView(model: model) } != nil)

        let submitted = store.jobs.all.first { $0.state == .submitted }!
        let skipped = store.jobs.all.first { $0.state == .skipped }!
        #expect(render("detail-submitted", width: 1100, height: 1000, store: store) { JobDetailView(jobID: submitted.id) } != nil)
        #expect(render("detail-skipped", width: 760, height: 1000, store: store, scheme: .dark) { JobDetailView(jobID: skipped.id) } != nil)
        #expect(render("detail-missing", width: 760, height: 400, store: store) { JobDetailView(jobID: 999_999) } != nil)

        // Mock mode ships reviewable jobs with a Q&A audit and a real pre-submit screenshot.
        let reviewable = MockScripts.reviewSampleJobIDs.compactMap { store.jobs.job(id: $0) }
        #expect(reviewable.count == 2 && reviewable.allSatisfy { $0.state == .awaitingReview })
        #expect(reviewable.allSatisfy { LocalFiles.existing($0.screenshotPath) != nil })
        for job in reviewable {
            #expect(render("detail-review-\(job.id)", width: 1200, height: 1100, store: store) { JobDetailView(jobID: job.id) } != nil)
        }
        if let parked = store.jobs.all.first(where: { $0.state == .needsYou }) {
            #expect(render("detail-needs-you", width: 1100, height: 700, store: store, scheme: .dark) { JobDetailView(jobID: parked.id) } != nil)
        }
        #expect(render("inspector", width: 360, height: 700, store: store) { JobInspector(jobID: submitted.id) } != nil)
        await store.stop()
    }

    @Test func activityLogAndInspectorRender() async {
        let store = await makeStore(.idle)
        #expect(render("activity", width: 1100, height: 700, store: store) { ActivityLogView() } != nil)
        let model = ActivityLogModel.shared
        model.sync(events: store.activity.events, filter: ActivityFilter(), jobLabel: { _ in nil }, forceSynchronous: true)
        model.selection = store.activity.events.last { $0.level == .error }?.id ?? store.activity.events.last?.id
        #expect(render("activity-inspector", width: 360, height: 700, store: store) { ActivityInspector() } != nil)
        model.selection = nil
        await store.stop()
    }

    @Test func liveComponentsRender() async {
        let store = await makeStore(.idle)
        var counts = RunStats()
        counts.discovered = 41; counts.scored = 38; counts.skipped = 27; counts.queued = 12; counts.submitted = 21; counts.needsYou = 2
        let transitions = [StageTransition(jobID: 1, from: .scored, to: .queued, start: Date()),
                           StageTransition(jobID: 2, from: .scored, to: .skipped, start: Date().addingTimeInterval(-0.3))]
        let steps = (0..<5).map { i in
            TickerStep(applicationID: 1, jobID: 1, index: i, total: 7, action: ["open_form", "upload_resume", "fill_fields", "answer", "cover letter"][i],
                       detail: i == 3 ? "\"Years with Go?\" → 4" : nil, confidence: i == 3 ? 0.5 : 0.9, at: Date())
        }
        let image = render("live", width: 1000, height: 420, store: store, reduceMotion: false) {
            VStack(spacing: Space.l) {
                PipelineFlowView(snapshot: FlowSnapshot(counts: counts, transitions: transitions, activeJobID: 1), isRunning: true, isIdle: false)
                    .frame(height: 150)
                PipelineFlowView(snapshot: FlowSnapshot(counts: RunStats(), transitions: [], activeJobID: nil), isRunning: false, isIdle: true, isSkeleton: true)
                    .frame(height: 120)
                StepTicker(steps: steps, isActive: true)
            }
            .padding()
        }
        #expect(image != nil)
        await store.stop()
    }
}
