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

    @Test func brandFieldAndEmptyStateRender() {
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
                        Text("Set up your job agent.").heroDisplayStyle()
                            .padding(Space.xl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .brandHeroBand()
                        EmptyState(symbol: "checkmark.rectangle.stack", title: "Nothing to review",
                                   message: "Filled applications wait here.", actionTitle: "Run now", isPrimary: true) {}
                        LoadingState()
                        ErrorState(title: "Can't reach the agent", actionTitle: "Restart agent", action: {})
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
                    ScreenHeader("Review", summary: "3 ready · Mode: Review")
                    HStack(spacing: Space.gutter) {
                        Surface("Applied today") {
                            MetricText(9, size: .xl)
                            Sparkline(values: [2, 3, 5, 3, 6, 7, 9]).frame(height: 28)
                        }
                        Surface("Needs You") {
                            HStack(alignment: .firstTextBaseline) {
                                MetricText(6, size: .xl, color: Palette.needsYou)
                                Text("questions · 14 jobs waiting").font(Typography.callout)
                            }
                        }
                    }
                    Surface("Daily limits") {
                        VStack(spacing: Space.s) {
                            CapBar(title: "Applications", used: 13, limit: 15)
                            CapBar(title: "LinkedIn visits", used: 3, limit: 3)
                        }
                    }
                    HStack { ForEach(StatusKind.allCases, id: \.self) { Badge(status: $0, compact: true) } }
                    HStack(spacing: Space.s) {
                        Badge(status: .needsYou); Badge(status: .interview); Badge(score: 91); Badge(score: 64); Badge(site: .greenhouse)
                        Badge(origin: .cv); Badge(origin: .neverGuess); Badge(origin: .user)
                        ConfidenceDot(level: .high); ConfidenceDot(level: .medium)
                    }
                    HStack(spacing: Space.l) {
                        Button("Approve & submit") {}.buttonStyle(.primaryPill)
                        Button("Skip") {}.buttonStyle(.secondaryLink)
                        Text("Selected row").selectableRow(isSelected: true)
                    }
                    Text("A quote in a well").padding(Space.m).well()
                    BulkActionBar(selectionCount: 2, actions: [
                        BulkAction(id: "approve", title: "Approve & submit", shortcut: .approve, isProminent: true) {},
                        BulkAction(id: "skip", title: "Skip", shortcut: .skip) {},
                    ], onClear: {})
                    LockedField(title: "Notice period") { Text("60 days") }
                    AgentPill(status: AgentStatus(kind: .applying, title: "Applying", detail: "3 of 12 today", progress: 0.25))
                    Banner(issues: [AppIssue(id: "x", severity: .warning, message: "LinkedIn session expired.", fixTitle: "Reconnect", fix: nil)],
                           onFix: { _ in }, onShowAll: {})
                    HStack {
                        StepRail(steps: [.init(id: 1, title: "System check"), .init(id: 2, title: "Resumes"), .init(id: 3, title: "Preferences"),
                                         .init(id: 4, title: "Story bank", isOptional: true)], current: 2)
                        Spacer()
                        EmptyState(symbol: "tray", title: "All clear", message: "14 jobs are back in the queue.")
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

    /// The answer composer with "Draft with AI": a stored agent draft in the editor, a drafted
    /// answer, the not-grounded warning, the drafting state (with and without Reduce Motion) and
    /// an error, in light and dark.
    @Test func answerComposerDraftWithAIRenders() async throws {
        let store = await makeStore(.idle)
        let inbox = InboxModel.shared(for: store)
        let why = try #require(store.inbox.clusters.first { $0.clusterId == "c_why" })
        var stored = why
        stored.clusterId = "c_stored"
        stored.reason = .lowConfidence
        stored.suggestedAnswer = "I have worked remotely for three years and write things down."
        stored.suggestedConfidence = 0.55
        stored.suggestedNote = "Add how many time zones your team spans."
        await inbox.draftWithAI(for: why)
        inbox.updateAIDraft(for: why) { $0.instruction = "Add a metric" }
        await inbox.reviseWithAI(for: why)
        let states: [(String, AIDraftState.Phase?)] = [("drafted", nil), ("drafting", .drafting(revising: true)),
                                                     ("failed", .failed("The agent took too long to write a draft. Try again."))]
        for scheme in [ColorScheme.light, .dark] {
            for (name, phase) in states {
                if let phase { inbox.updateAIDraft(for: why) { $0.phase = phase } }
                for reduce in [true, false] {
                    let image = render("composer-ai-\(name)\(reduce ? "-reduced" : "")", width: 900, height: 1100, scheme: scheme) {
                        AnswerComposer(model: inbox, cluster: why, undoManager: nil, embedded: true)
                            .padding(Space.l)
                            .appEnvironment(store, simulateReduceMotion: reduce)
                    }
                    #expect(image != nil, "\(name)")
                }
            }
            #expect(render("composer-stored-draft", width: 900, height: 900, scheme: scheme) {
                AnswerComposer(model: inbox, cluster: stored, undoManager: nil, embedded: true)
                    .padding(Space.l)
                    .appEnvironment(store, simulateReduceMotion: true)
            } != nil)
        }
        #expect(inbox.draft(for: stored).text == stored.suggestedAnswer, "the stored draft starts in the editor")
        await store.stop()
    }
}
