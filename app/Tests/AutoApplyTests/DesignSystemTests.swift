// DesignSystemTests.swift — guards for the redesign (Rams audit 2026-10-22):
// - token contrast (text ≥ 4.5:1, status inks ≥ 3:1, text on the accent ≥ 4.5:1) in both modes;
// - a source lint: no glass or prominent system buttons in content, no shadows, no breathing
//   symbols, the mode switch never approves, and none of the retired jargon in UI strings
//   (one documented exception: the Dashboard hero's glass, `dashboardHeroGlassFile`);
// - each primary screen draws at most one prominent (primary pill) action; the floating session
//   bar (Features/Session) is chrome with its own primary that never counts against a screen.
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

    /// The Dashboard hero exception (owner decision 2026-10-22: "beautiful with animations and
    /// liveliness"). The hero band is the one place where content floats on Liquid Glass over the
    /// living brand field. The exemption is narrow: glass is applied by ONE helper
    /// (`heroGlass(in:)` in this file), and only Dashboard code may call it. Everything else in
    /// the app keeps the calm rules below. The hero's continuous motion lives in the same file
    /// and is gated by `heroMotionActive` (window visible, Reduce Motion off, ≤ 20/30 fps).
    static let dashboardHeroGlassFile = "Features/Dashboard/Hero/HeroStyle.swift"

    @Test func noGlassOrSystemProminentButtonsInContent() {
        #expect(offenders(".glassProminent").isEmpty)
        #expect(offenders(".borderedProminent").isEmpty)
        #expect(offenders("buttonStyle(.glass)").isEmpty)
        #expect(offenders(".regularMaterial").isEmpty)
        // Glass is applied in exactly two places: the control-layer helper, and the Dashboard
        // hero's helper (the documented exception above).
        #expect(offenders(".glassEffect(", allowedIn: ["DesignSystem/Materials.swift", Self.dashboardHeroGlassFile]).isEmpty)
    }

    @Test func glassMorphsOnlyInTheSessionBar() {
        // The session bar morphs into "Done for today" (glassEffectID). It's control-layer glass
        // applied through `glassChrome` (GlassBar); no other feature morphs glass yet.
        #expect(offenders("glassEffectID(", allowedIn: ["Features/Session/"]).isEmpty)
        #expect(offenders("GlassEffectContainer", allowedIn: ["Features/Session/", "Features/Dashboard/"]).isEmpty)
    }

    @Test func heroGlassStaysOnTheDashboard() {
        // `heroGlass(` may only be called from the Dashboard (the hero band and its live agent).
        #expect(offenders("heroGlass(", allowedIn: ["Features/Dashboard/"]).isEmpty)
        #expect(offenders("heroPanel(", allowedIn: ["Features/Dashboard/"]).isEmpty)
        #expect(offenders("HeroBreath(", allowedIn: ["Features/Dashboard/"]).isEmpty)
        #expect(offenders("heroMotionActive", allowedIn: ["Features/Dashboard/"]).isEmpty)
        #expect(Self.sources().contains { $0.path == Self.dashboardHeroGlassFile }, "the lint found the hero helper")
    }

    @Test func heroMotionIsCapped() {
        // Ambient fields ≤ 20 fps, flows ≤ 30 fps; the brand field clamps its own rate.
        #expect(HeroFrameRate.ambientIdle <= 20 && HeroFrameRate.ambient <= 20)
        #expect(HeroFrameRate.flow <= 30)
        // No 60 fps timelines in the hero or the live agent.
        let heroFiles = Self.sources().filter { $0.path.hasPrefix("Features/Dashboard/Hero/") || $0.path.hasPrefix("Features/Dashboard/LiveAgent/") }
        let sixty = heroFiles.flatMap { file in
            file.lines.enumerated().filter { $0.element.contains("TimelineView(.animation(") && !$0.element.contains("HeroFrameRate") }
                .map { "\(file.path):\($0.offset + 1)" }
        }
        // The one exception is the 0.4 s scan line drawn once per new Chrome frame.
        #expect(sixty.allSatisfy { $0.hasPrefix("Features/Dashboard/LiveAgent/LiveBrowserThumb.swift") }, "\(sixty)")
        // The menu bar never runs continuous animation.
        #expect(offenders("TimelineView(.animation", allowedIn: []).filter { $0.hasPrefix("Features/MenuBar/") }.isEmpty)
    }

    @Test func flatSurfacesAndCalmMotion() {
        #expect(offenders(".shadow(").isEmpty, "no drop shadows")
        #expect(offenders(".breathe", allowedIn: ["Features/EasterEggs/"]).isEmpty, "nothing breathes at rest")
        #expect(offenders("focusEffectDisabled", allowedIn: [
            "Features/Onboarding/Ignition/",
            // Whole-pane keyboard containers whose selected row / card already shows focus: the
            // system ring would draw a stray outline across the window (e.g. a line under the header).
            "Features/Board/BoardView.swift", "Features/Review/ReviewView.swift", "Features/Inbox/InboxView.swift",
            "Features/EasyApply/EasyApplyView.swift", "Features/JobDetail/ScreenshotViewer.swift",
        ]).isEmpty, "system focus rings stay on")
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

    /// The glossary inside the UI strings of the outreach and career screens: Needs You (never
    /// Inbox), Agent (never daemon / autoapplyd), Application site (never ATS), Pipeline (never
    /// board / tracker), Applied (never Submitted).
    @Test func outreachScreensUseTheGlossary() {
        let files = ["Features/ColdEmail/", "Features/Inbox/RepliesSection.swift", "Features/Settings/OutreachSettingsTab.swift",
                     "Core/Models/OutreachModels.swift", "Core/Store/OutreachStore.swift", "Core/Store/AppStore+Outreach.swift",
                     // What's working, Interview prep, requirement evidence, writing voice, LinkedIn import.
                     "Features/Dashboard/Insights/", "Features/JobDetail/InterviewPrep", "Features/JobDetail/MatchBreakdown.swift",
                     "Features/Settings/WritingVoiceSection.swift", "Core/Store/AppStore+Career.swift", "Core/Models/ScoreEvidence.swift",
                     "Mock/MockCareer.swift"]
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
        #expect(Self.sources().contains { $0.path == "Features/Dashboard/Insights/InsightsView.swift" }, "the lint found the career screens")
    }

    /// The career helpers are honest about what they are: insights are advisory and change
    /// nothing, prep is grounded in your own stories, drafts are never sent, the LinkedIn file
    /// stays on this Mac. None of their strings promise otherwise.
    @Test func careerScreensStayHonest() {
        let files = ["Features/Dashboard/Insights/", "Features/JobDetail/InterviewPrep", "Features/JobDetail/MatchBreakdown.swift",
                     "Features/Settings/WritingVoiceSection.swift", "Features/ColdEmail/LinkedInImport.swift", "Mock/MockCareer.swift"]
        let banned = ["we'll send", "will be sent", "sent automatically", "sends it for you", "automatically adjust", "we adjusted",
                      "threshold was changed", "AI-powered", "magic", "scrape", "scraping", "guarantee", "ace the interview",
                      "land the job", "sync your LinkedIn", "connect your LinkedIn", "Insights engine"]
        var hits: [String] = []
        for file in Self.sources() where files.contains(where: { file.path.hasPrefix($0) }) {
            for (i, line) in file.lines.enumerated() where line.contains("\"") {
                for phrase in banned where line.range(of: phrase, options: .caseInsensitive) != nil {
                    hits.append("\(file.path):\(i + 1): \(phrase)")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits.joined(separator: "\n"))")
        // And the promises that must be there.
        let text = Self.sources().filter { f in files.contains { f.path.hasPrefix($0) } }.flatMap(\.lines).joined(separator: "\n")
        for promise in ["nothing is changed automatically", "never claim a skill you don't have", "Nothing is sent", "Never sent",
                        "never shared", "never opens LinkedIn", "never adds facts", "Uses one Claude request"] {
            #expect(text.contains(promise), "missing honest copy: \(promise)")
        }
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

    @Test func dashboardStartIsThePrimaryWhenThereIsWork() async {
        // "Today's ten minutes": Start is the one primary while something waits (idle mock has work).
        let store = await makeStore(.idle)
        #expect(!BriefingSummary(items: SessionSources.live(store: store).items).isDone)
        #expect(prominentCount(store: store, height: 1500) { DashboardView() } == 1)
        await store.stop()
    }

    @Test func sessionBarIsFloatingChromeWithItsOwnPrimary() async {
        // The session bar floats over every screen: its Next is its own primary and is never
        // counted against the screen underneath (SessionHost clears the audit).
        let store = await makeStore(.idle)
        let session = SessionModel()
        session.start(SessionSources.live(store: store).items)
        #expect(prominentCount(store: store, height: 120) { SessionBar(session: session) } == 1)
        let shared = SessionModel.shared(for: store)
        shared.start(SessionSources.live(store: store).items)
        #expect(prominentCount(store: store, height: 120) { SessionHost() } == 0)
        shared.end()
        await store.stop()
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
            // Exactly one: Approve & send.
            #expect(prominentCount(store: store) { JobDetailView(jobID: job.id) } == 1, "Job detail \(job.id)")
        }
        if let applied = store.jobs.all.first(where: { $0.state == .submitted }) {
            #expect(prominentCount(store: store) { JobDetailView(jobID: applied.id) } == 0, "Job detail (applied)")
        }
        await store.stop()
    }

    @Test func sendHoldKeepsOnePrimary() async {
        // While an approval is on the send hold, its countdown + Undo replace the Approve pill.
        let store = await makeStore(.idle)
        let reviewable = MockScripts.reviewSampleJobIDs.compactMap { store.jobs.job(id: $0) }.filter { $0.state == .awaitingReview }
        guard let job = reviewable.first else { Issue.record("no reviewable sample job"); return }
        let hold = SendHoldModel.shared(for: store)
        hold.window = .seconds(60)
        #expect(hold.hold(jobIDs: [job.id]) == [job.id])
        #expect(prominentCount(store: store) { JobDetailView(jobID: job.id) } == 0, "held: no Approve pill")
        #expect(prominentCount(store: store) { ReviewQueueView() } <= 1, "Review with a held row")
        hold.abandonAll()
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
                // Up next with drafts waiting: exactly one — Send N… (sending on) or the one-time
                // Turn on sending… (sending off). Never both.
                if tab == .outbox {
                    #expect(count == 1, "Up next with drafts (sending \(sendingOn ? "on" : "off")) shows \(count) primary actions")
                }
            }
            // People ▸ Could refer you: Add referral is the one primary (Add contact steps aside).
            let people = ColdEmailModel(store: store)
            people.showPeople(.couldRefer)
            #expect(prominentCount(store: store) { ColdEmailView(modelOverride: people) } == 1, "People ▸ Could refer you")
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

    @Test func careerScreensHaveOnePrimary() async throws {
        let store = await makeStore(.idle)
        // What's working: Refresh is the one primary, loaded or loading.
        let insights = InsightsModel(store: store)
        insights.show(CareerFixtures.insights())
        #expect(prominentCount(store: store) { InsightsView(modelOverride: insights) } == 1, "What's working")
        #expect(prominentCount(store: store) { InsightsView(modelOverride: InsightsModel(store: store)) } == 1, "What's working (loading)")
        // The Dashboard's card is a link, not another primary.
        #expect(prominentCount(store: store, height: 1700) { DashboardView() } <= 1, "Dashboard with What's working")

        // Interview prep: "Prepare" before a pack, then "Write debrief".
        let job = try #require(store.jobs.all.first { $0.state == .submitted && $0.applicationID != nil })
        let id = try #require(job.applicationID)
        let prep = InterviewPrepModel.shared(for: store)
        await prep.load(applicationID: id, force: true)
        if prep.pack(id) == nil {
            #expect(prominentCount(store: store, width: 760, height: 1200) { InterviewPrepPane(job: job, model: prep) } == 1, "Prep, no pack")
        }
        await prep.generate(applicationID: id, force: true)
        prep.notes[id] = "Spoke with Priya."
        await prep.debrief(applicationID: id)
        #expect(prominentCount(store: store, width: 760, height: 2400) { InterviewPrepPane(job: job, model: prep) } == 1, "Prep with a pack")
        // Job detail of an applied job still has at most one primary (the prep tab isn't the default).
        #expect(prominentCount(store: store) { JobDetailView(jobID: job.id) } <= 1, "Job detail (applied)")

        // The LinkedIn import sheet: one primary in every state.
        let cold = ColdEmailModel(store: store)
        let done = LinkedInImportResult(imported: 3, merged: 0, skipped: 0,
                                        matchedCompanies: [.init(companyId: 1, name: "Stripe", why: "You applied", connections: 1)],
                                        referralSuggestions: 1)
        for state: LinkedInImportState in [.idle, .importing, .failed("Bad file"), .done(done),
                                           .done(LinkedInImportResult(imported: 1, merged: 0, skipped: 0, matchedCompanies: [], referralSuggestions: 0))] {
            cold.linkedInImport = state
            #expect(prominentCount(store: store, width: 520, height: 560) { LinkedInImportSheet(model: cold) } == 1, "LinkedIn import \(state)")
        }

        // Settings ▸ Outreach with the writing voice loaded: still no primary.
        let voice = VoiceProfileModel.shared(for: store)
        await voice.load()
        #expect(voice.phase == .loaded)
        #expect(prominentCount(store: store, width: 680, height: 1900) {
            ScrollView { VStack { OutreachSettingsTab(model: SettingsModel(store: store)) } }
        } == 0, "Settings ▸ Outreach with Writing voice has no primary")
        await store.stop()
    }

    /// "Draft with AI" and "Tell the agent what to change…" are secondary: the composer's one
    /// primary stays Answer in every state (idle, stored draft, drafted, not grounded, failed).
    @Test func needsYouDraftWithAIKeepsOnePrimary() async throws {
        #expect(offenders(".primaryPill").filter { $0.hasPrefix("Features/Inbox/AIDraftControls.swift") }.isEmpty)
        let store = await makeStore(.idle)
        let inbox = InboxModel.shared(for: store)
        let why = try #require(store.inbox.clusters.first { $0.clusterId == "c_why" })
        inbox.select(why.clusterId)
        #expect(inbox.supportsAIDraft(why))
        func composerCount() -> Int {
            prominentCount(store: store, width: 900, height: 1200) {
                AnswerComposer(model: inbox, cluster: why, undoManager: nil, embedded: true)
            }
        }
        #expect(composerCount() == 1, "before drafting")
        await inbox.draftWithAI(for: why)
        #expect(!inbox.draft(for: why).text.isEmpty)
        #expect(composerCount() == 1, "drafted")
        inbox.updateAIDraft(for: why) { $0.instruction = "Add a metric" }
        await inbox.reviseWithAI(for: why)
        #expect(!inbox.aiDraft(for: why).unsupportedClaims(in: inbox.draft(for: why).text).isEmpty)
        #expect(composerCount() == 1, "not grounded")
        inbox.updateAIDraft(for: why) { $0.phase = .drafting(revising: true) }
        #expect(composerCount() == 1, "drafting")
        inbox.updateAIDraft(for: why) { $0.phase = .failed("The agent took too long to write a draft. Try again.") }
        #expect(composerCount() == 1, "failed")
        // A stored draft in the editor, labelled as the agent's.
        var stored = why
        stored.clusterId = "c_stored"
        stored.reason = .lowConfidence
        stored.suggestedAnswer = "I have worked remotely for three years."
        stored.suggestedConfidence = 0.55
        #expect(prominentCount(store: store, width: 900, height: 1200) {
            AnswerComposer(model: inbox, cluster: stored, undoManager: nil, embedded: true)
        } == 1, "stored draft")
        #expect(prominentCount(store: store) { InboxView() } <= 1, "Needs You with Draft with AI")
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
