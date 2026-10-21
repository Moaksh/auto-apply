// RenderSmokeTests.swift — renders key components and screens offscreen with ImageRenderer in
// light and dark. Asserts they produce an image; when AUTOAPPLY_SNAPSHOT_DIR is set, writes PNGs
// there for visual review (AppKit-backed controls like TextField render as placeholders).
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Render smoke", .serialized)
struct RenderSmokeTests {
    let outputDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    @discardableResult
    func render<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil, scheme: ColorScheme = .light, @ViewBuilder _ view: () -> V) -> CGImage? {
        let content = view()
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.cgImage
        if let image, let dir = outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        return image
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

    @Test func brandFieldAndProminentEmptyStateRender() {
        // The mesh never folds: every drifting point stays inside the unit square.
        for t in stride(from: 0.0, through: 600, by: 7.3) {
            let points = BrandMesh.points(at: t)
            #expect(points.count == 9 && BrandMesh.colors(at: t).count == 9)
            #expect(points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        }
        for scheme in [ColorScheme.light, .dark] {
            for reduce in [true, false] {
                let image = render("brand-field-\(reduce ? "static" : "live")", width: 720, scheme: scheme) {
                    VStack(spacing: Space.l) {
                        Text("Good morning.").heroDisplayStyle()
                            .padding(Space.xl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .brandHeroBand()
                        EmptyState(symbol: "checkmark.rectangle.stack", title: "Nothing to review",
                                   message: "Filled applications wait here.", actionTitle: "Open board", prominent: true) {}
                    }
                    .padding()
                    .motionEnvironment(simulateReduceMotion: reduce)
                }
                #expect(image != nil)
            }
        }
    }

    @Test func componentGalleryRenders() {
        for scheme in [ColorScheme.light, .dark] {
            let image = render("components", width: 720, scheme: scheme) {
                VStack(alignment: .leading, spacing: Space.l) {
                    HStack(spacing: Space.gutter) {
                        KPICard(title: "Applied today", value: MetricText(9, size: .xl), caption: "+4 vs avg",
                                delta: .init(text: "4", isPositive: true), sparkline: [2, 3, 5, 3, 6, 7, 9])
                        Card("Needs you", tint: Palette.needsYou) {
                            HStack(alignment: .firstTextBaseline) {
                                MetricText(6, size: .xl, color: Palette.needsYou)
                                Text("questions · 14 jobs parked").font(Typography.callout)
                            }
                        }
                    }
                    Card("Caps") {
                        VStack(spacing: Space.s) {
                            CapBar(title: "Applications", used: 13, limit: 15)
                            CapBar(title: "LinkedIn sessions", used: 3, limit: 3)
                        }
                    }
                    HStack { ForEach(StatusKind.allCases, id: \.self) { StatusChip($0, size: .small) } }
                    HStack(spacing: Space.s) {
                        StatusChip(.needsYou); StatusChip(.interview); ScorePill(score: 91); ScorePill(score: 64)
                        ProvenanceTag(origin: .cv); ProvenanceTag(origin: .neverGuess); ProvenanceTag(origin: .user)
                        ConfidenceDot(level: .high); ConfidenceDot(level: .medium)
                    }
                    LockedField(title: "Notice period") { Text("60 days") }
                    AgentPill(status: AgentStatus(kind: .applying, title: "Applying", detail: "3 of 12 today", progress: 0.25))
                    Banner(issues: [AppIssue(id: "x", severity: .warning, message: "LinkedIn session expired.", fixTitle: "Reconnect", fix: nil)],
                           onFix: { _ in }, onShowAll: {})
                    HStack {
                        StepRail(steps: [.init(id: 1, title: "System check"), .init(id: 2, title: "Resumes"), .init(id: 3, title: "Preferences"),
                                         .init(id: 4, title: "Story bank", isOptional: true)], current: 2)
                        Spacer()
                        EmptyState(symbol: "tray", title: "All caught up.", message: "14 jobs resumed.")
                    }
                    MiniHistogram(bins: MiniHistogram.benchmark, threshold: 70).frame(height: 36)
                }
                .padding(Space.xl)
            }
            #expect(image != nil)
        }
    }

    @Test func ignitionFinalFrameRenders() {
        let image = render("ignition", width: 880, height: 620) { IgnitionView {}.environment(\.motionReduced, true) }
        #expect(image != nil)
    }

    @Test func menuBarPanelRendersWithLiveData() async {
        let store = await makeStore(.reviewMode)
        for scheme in [ColorScheme.light, .dark] {
            let image = render("menubar", width: LayoutMetrics.menuBarWidth, scheme: scheme) {
                MenuBarPanel().appEnvironment(store, simulateReduceMotion: true)
            }
            #expect(image != nil)
        }
        await store.stop()
    }

    @Test func onboardingStepsRender() async {
        let store = await makeStore(.onboarding)
        let model = OnboardingModel(store: store, checker: FakeChecker(items: []))
        model.load()
        model.preferencesDraft.roles = ["Backend Engineer", "ML Engineer"]
        for step in OnboardingModel.Step.allCases where step != .ignition {
            model.go(to: step)
            let image = render("onboarding-\(step.rawValue)-\(step.title.replacingOccurrences(of: " ", with: ""))", width: 650, height: 560) {
                VStack(alignment: .leading, spacing: Space.l) {
                        switch step {
                        case .systemCheck: SystemCheckStep(model: model)
                        case .resumes: ResumesStep(model: model)
                        case .preferences: PreferencesStep(model: model)
                        case .neverGuess: NeverGuessStep(model: model)
                        case .stories: StoriesStep(model: model)
                        case .sources: SourcesStep(model: model)
                        case .mode: ModeStep(model: model)
                        case .ready: ReadyStep(model: model, onFinished: {})
                        case .ignition: EmptyView()
                        }
                }
                .padding(Space.xxl)
                .frame(maxHeight: .infinity, alignment: .top)
                .appEnvironment(store, simulateReduceMotion: true)
            }
            #expect(image != nil)
        }
        await store.stop()
    }

    @Test func placeholderAndPaletteRender() async {
        let store = await makeStore(.idle)
        let image = render("placeholder", width: 700, height: 400) {
            PlaceholderScreen(screen: .dashboard).appEnvironment(store, simulateReduceMotion: true)
        }
        #expect(image != nil)
        let palette = render("palette", width: LayoutMetrics.paletteWidth, height: 420) {
            BasicCommandPalette().appEnvironment(store, simulateReduceMotion: true)
        }
        #expect(palette != nil)
        await store.stop()
    }
}
