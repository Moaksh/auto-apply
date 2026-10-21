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
                      "Can't reach autoapplyd", "Restart daemon", "Tokens · ", "pick %.2f", "Skip (reject)", "Receipts",
                      // Cold outreach: honest about what happens (owner decisions 2026-10-21).
                      "never a sequence of follow-ups", "Not built yet", "get you replies", "guaranteed", "land you", "Join waitlist",
                      "sample · not sent", "auto-send", "sends automatically"]
        // One pass over the sources (this suite runs on the main actor; keep it cheap).
        var hits: [String: [String]] = [:]
        for file in Self.sources() {
            for (i, line) in file.lines.enumerated() where line.contains("\"") {
                for phrase in banned where line.contains("\"" + phrase) || line.contains(" " + phrase + "\"") || line.contains(phrase + "\"") {
                    hits[phrase, default: []].append("\(file.path):\(i + 1)")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    /// The glossary inside the UI strings of the outreach screens: Needs You (never Inbox), Agent
    /// (never daemon / autoapplyd), Application site (never ATS), Pipeline (never board / tracker),
    /// Applied (never Submitted).
    @Test func outreachScreensUseTheGlossary() {
        let files = ["Features/ColdEmail/", "Features/Inbox/RepliesSection.swift", "Features/Settings/OutreachSettingsTab.swift",
                     "Core/Models/OutreachModels.swift", "Core/Store/OutreachStore.swift", "Core/Store/AppStore+Outreach.swift"]
        let banned = ["Inbox", "inbox", "daemon", "autoapplyd", "ATS", "board", "Board", "tracker", "Submitted", "submitted", "LaunchAgent"]
        let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var hits: [String] = []
        for file in Self.sources() where files.contains(where: { file.path.hasPrefix($0) }) {
            for (i, line) in file.lines.enumerated() {
                let ns = line as NSString
                for match in literal.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let text = ns.substring(with: match.range(at: 1))
                    for word in banned where text.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
                        hits.append("\(file.path):\(i + 1): \(word) in \"\(text)\"")
                    }
                }
            }
        }
        #expect(hits.isEmpty, "\(hits.joined(separator: "\n"))")
        #expect(Self.sources().contains { $0.path == "Features/ColdEmail/OutboxTab.swift" }, "the lint found the new screens")
    }

    @Test func outreachNeverDrivesLinkedIn() {
        // The referral copilot hands links to the user's browser; nothing opens LinkedIn in the agent.
        let offenders = Self.sources().filter { $0.path.hasPrefix("Features/ColdEmail/") }.flatMap { file in
            file.lines.enumerated().filter { $0.element.contains("openAgentChrome") }.map { "\(file.path):\($0.offset + 1)" }
        }
        #expect(offenders.isEmpty)
    }

    // MARK: One prominent action per screen

    private func makeStore(_ scenario: MockScenario) async -> AppStore {
        let daemon = MockDaemon(scenario: scenario, speed: 1)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
        store.statsDebounce = .milliseconds(1)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.isConnected }
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

    @Test func coldEmailHasAtMostOnePrimaryPerTab() async {
        let store = await makeStore(.idle)
        _ = await waitUntil { store.outreach.isLoaded && store.outreach.repliesLoaded }
        for sendingOn in [true, false] {
            if !sendingOn {
                (store.repository as? InMemoryRepository)?.update { $0.outreach.mailAccount.sendEnabled = false }
                _ = await waitUntil { !store.outreach.sendEnabled }
            }
            for tab in ColdEmailTab.allCases {
                let model = ColdEmailModel(store: store)
                model.tab = tab
                if tab == .outbox, let first = store.outreach.drafts.first {
                    model.selectAllDrafts()
                    model.focusedMessageID = first.id
                }
                let count = prominentCount(store: store) { ColdEmailView(modelOverride: model) }
                await Task.yield()
                #expect(count <= 1, "Cold Email ▸ \(tab.title) (sending \(sendingOn ? "on" : "off")) shows \(count) primary actions")
            }
        }
        let model = ColdEmailModel(store: store)
        model.selectAllDrafts()
        #expect(prominentCount(store: store, width: 560, height: 720) { SendConfirmSheet(model: model) } == 1, "Send N… sheet")
        #expect(prominentCount(store: store, width: 480, height: 420) { EnableSendingSheet(model: model) } == 1, "Enable sending sheet")
        #expect(prominentCount(store: store, width: 480, height: 560) { AddContactSheet() } == 1, "Add contact sheet")
        #expect(prominentCount(store: store, width: 680, height: 1400) {
            ScrollView { VStack { OutreachSettingsTab(model: SettingsModel(store: store)) } }
        } == 0, "Settings ▸ Outreach has no primary")
        await store.stop()
    }

    @Test func needsYouRepliesKeepOnePrimary() async {
        let store = await makeStore(.idle)
        _ = await waitUntil { store.outreach.isLoaded && store.outreach.repliesLoaded }
        let inbox = InboxModel.shared(for: store)
        #expect(!inbox.replyItems.isEmpty)
        for item in inbox.replyItems {
            inbox.selectReply(item.key)
            let count = prominentCount(store: store) { InboxView() }
            await Task.yield()
            #expect(count <= 1, "Needs You with \(item.key) selected shows \(count) primary actions")
        }
        if let suggested = store.outreach.pendingSuggestions.first.flatMap({ store.jobs.job(applicationID: $0.applicationID) }) {
            #expect(prominentCount(store: store) { JobDetailView(jobID: suggested.id) } == 0, "a reply suggestion on an applied job stays secondary")
            #expect(prominentCount(store: store, width: LayoutMetrics.inspectorWidth) { JobInspector(jobID: suggested.id) } == 0)
        }
        await store.stop()
    }
}
