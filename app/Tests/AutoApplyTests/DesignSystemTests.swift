// DesignSystemTests.swift — guards for the redesign (Rams audit 2026-10-22):
// - token contrast (text ≥ 4.5:1, status inks ≥ 3:1, text on the accent ≥ 4.5:1) in both modes;
// - a source lint: no glass or prominent system buttons in content, no shadows, no breathing
//   symbols, the mode switch never approves, and none of the retired jargon in UI strings;
// - each primary screen draws at most one prominent (primary pill) action.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Design system", .serialized)
struct DesignSystemTests {

    // MARK: Contrast

    private func resolve(_ color: Color, dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return out
    }

    private func luminance(_ c: NSColor) -> Double {
        func channel(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    private func contrast(_ a: Color, _ b: Color, dark: Bool) -> Double {
        let la = luminance(resolve(a, dark: dark)), lb = luminance(resolve(b, dark: dark))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test func textTokensMeetAA() {
        for dark in [false, true] {
            for ground in [Palette.surface, Palette.sunken] {
                #expect(contrast(Palette.textTertiary, ground, dark: dark) >= 4.5, "textTertiary, dark: \(dark)")
                #expect(contrast(Palette.textSecondary, ground, dark: dark) >= 4.5, "textSecondary, dark: \(dark)")
            }
            #expect(contrast(Palette.onAccent, Palette.accent, dark: dark) >= 4.5, "text on the accent, dark: \(dark)")
            #expect(contrast(Palette.onPrimaryFill, Palette.primaryFill, dark: dark) >= 4.5, "primary pill, dark: \(dark)")
        }
    }

    @Test func statusInksMeetThreeToOne() {
        for dark in [false, true] {
            for ground in [Palette.surface, Palette.sunken] {
                for kind in StatusKind.allCases where kind != .filling {
                    #expect(contrast(kind.color, ground, dark: dark) >= 3, "\(kind) ink, dark: \(dark)")
                }
            }
        }
    }

    // MARK: Source lint

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AutoApply")
    }

    /// Every Swift source except the generated protocol file, as (relative path, code lines
    /// without `//` comment lines). Read once.
    private static let cachedSources = loadSources()

    private static func sources() -> [(path: String, lines: [String])] { cachedSources }

    private static func loadSources() -> [(path: String, lines: [String])] {
        let root = sourcesRoot
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.hasSuffix("Core/Protocol/Messages.swift") } ?? []
        return files.map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            return (String(url.path.dropFirst(root.path.count + 1)), lines)
        }
    }

    private func offenders(_ needle: String, allowedIn allowed: [String] = []) -> [String] {
        Self.sources().flatMap { file in
            allowed.contains(where: { file.path.hasPrefix($0) }) ? [] :
                file.lines.enumerated().filter { $0.element.contains(needle) }.map { "\(file.path):\($0.offset + 1)" }
        }
    }

    @Test func sourcesFound() {
        #expect(Self.sources().count > 50)
    }

    @Test func noGlassOrSystemProminentButtonsInContent() {
        #expect(offenders(".glassProminent").isEmpty)
        #expect(offenders(".borderedProminent").isEmpty)
        #expect(offenders("buttonStyle(.glass)").isEmpty)
        #expect(offenders(".regularMaterial").isEmpty)
        // Glass is applied in exactly one place (the control-layer helper).
        #expect(offenders(".glassEffect(", allowedIn: ["DesignSystem/Materials.swift"]).isEmpty)
    }

    @Test func flatSurfacesAndCalmMotion() {
        #expect(offenders(".shadow(").isEmpty, "no drop shadows")
        #expect(offenders(".breathe", allowedIn: ["Features/EasterEggs/"]).isEmpty, "nothing breathes at rest")
        #expect(offenders("focusEffectDisabled", allowedIn: ["Features/Onboarding/Ignition/"]).isEmpty, "system focus rings stay on")
    }

    @Test func modeSwitchNeverApproves() {
        let root = Self.sources().first { $0.path == "App/RootView.swift" }
        #expect(root != nil)
        #expect(root?.lines.contains { $0.contains(".approve(") } == false)
        #expect(ModeSwitchConfirm.message(pending: 3).contains("stay in Review"))
    }

    @Test func retiredJargonIsGone() {
        let banned = ["Prep pass", "Never-guess", "never-guess fact", "kill switch", "get you hired", "Everything stays on this Mac",
                      "no invented facts", "jobs resumed", "Join beta", "Mode: inherit", "Inherit (", "Q&A audit", "Step ticker",
                      "Can't reach autoapplyd", "Restart daemon", "Tokens · ", "pick %.2f", "Skip (reject)", "Receipts"]
        for phrase in banned {
            #expect(offenders("\"" + phrase).isEmpty && offenders(" " + phrase + "\"").isEmpty && offenders(phrase + "\"").isEmpty,
                    "\(phrase): \(offenders(phrase))")
        }
    }

    // MARK: One prominent action per screen

    private func makeStore(_ scenario: MockScenario) async -> AppStore {
        let daemon = MockDaemon(scenario: scenario, speed: 1)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
        store.statsDebounce = .milliseconds(1)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded }
        store.recomputeStats()
        return store
    }

    /// Distinct primary pills drawn while rendering `view` offscreen.
    private func prominentCount<V: View>(store: AppStore, width: CGFloat = 1200, height: CGFloat = 900,
                                         @ViewBuilder _ view: () -> V) -> Int {
        let audit = ProminenceAudit()
        let content = view()
            .appEnvironment(store, simulateReduceMotion: true)
            .environment(\.prominenceAudit, audit)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
        let renderer = ImageRenderer(content: content)
        _ = renderer.cgImage
        return audit.count
    }

    @Test func dashboardHasAtMostOnePrimary() async {
        for scenario in [MockScenario.idle, .happyRun, .firstRunEmpty, .capReached] {
            let store = await makeStore(scenario)
            let count = prominentCount(store: store, height: 1500) { DashboardView() }
            #expect(count <= 1, "Dashboard (\(scenario.rawValue)) shows \(count) primary actions")
            await store.stop()
        }
    }

    @Test func firstRunDashboardOffersRunNow() async {
        let store = await makeStore(.firstRunEmpty)
        #expect(prominentCount(store: store, height: 1500) { DashboardView() } == 1)
        await store.stop()
    }

    @Test func workScreensHaveAtMostOnePrimary() async {
        let store = await makeStore(.reviewMode)
        #expect(prominentCount(store: store) { InboxView() } <= 1, "Needs You")
        #expect(prominentCount(store: store) { ReviewQueueView() } <= 1, "Review")
        let board = BoardModel(store: store)
        board.defaults = C2.isolatedDefaults()
        #expect(prominentCount(store: store, width: 1300) { BoardView(model: board) } == 0, "Pipeline has no primary")
        #expect(prominentCount(store: store, width: LayoutMetrics.menuBarWidth, height: 700) { MenuBarPanel() } == 1, "Menu bar")
        await store.stop()
    }

    @Test func jobDetailHasOnePrimaryWhileReviewable() async {
        // Mock mode ships two reviewable jobs (see C2RenderTests).
        let store = await makeStore(.idle)
        let reviewable = MockScripts.reviewSampleJobIDs.compactMap { store.jobs.job(id: $0) }.filter { $0.state == .awaitingReview }
        #expect(!reviewable.isEmpty)
        for job in reviewable {
            // Exactly one: Approve & submit.
            #expect(prominentCount(store: store) { JobDetailView(jobID: job.id) } == 1, "Job detail \(job.id)")
        }
        if let applied = store.jobs.all.first(where: { $0.state == .submitted }) {
            #expect(prominentCount(store: store) { JobDetailView(jobID: applied.id) } == 0, "Job detail (applied)")
        }
        await store.stop()
    }
}
