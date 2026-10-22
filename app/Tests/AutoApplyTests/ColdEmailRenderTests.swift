// ColdEmailRenderTests.swift — renders the Cold Email tabs (ready, loading, error, empty), the
// Outbox editor in each state, the Send N… sheet with conflicts, Needs You ▸ Replies, the job
// inspector's outreach section and Settings ▸ Outreach offscreen, in light and dark. Asserts an
// image is produced; AUTOAPPLY_SNAPSHOT_DIR writes PNGs for visual review.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Cold Email render", .serialized)
struct ColdEmailRenderTests {
    let outputDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    @discardableResult
    func render<V: View>(_ name: String, store: AppStore, width: CGFloat = 1200, height: CGFloat = 820, scheme: ColorScheme,
                         @ViewBuilder _ view: () -> V) -> CGImage? {
        let content = view()
            .appEnvironment(store, simulateReduceMotion: true)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = renderer.cgImage
        if let image, let dir = outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("coldemail-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        return image
    }

    /// Render, then let other main-actor work run (other suites wait on the main actor too).
    func check<V: View>(_ name: String, store: AppStore, width: CGFloat = 1200, height: CGFloat = 820, scheme: ColorScheme,
                        @ViewBuilder _ view: () -> V) async {
        #expect(render(name, store: store, width: width, height: height, scheme: scheme, view) != nil, "\(name)")
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    func mockStore(_ scenario: MockScenario = .idle) async -> AppStore {
        let daemon = MockDaemon(scenario: scenario, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.outreach.isLoaded && store.outreach.repliesLoaded }
        return store
    }

    /// A store whose outreach tables are readable but empty.
    func emptyStore() async -> AppStore {
        let daemon = StubDaemon()
        var data = RepositoryData()
        data.jobs = [Samples.job(id: 1, state: .queued)]
        let store = AppStore(client: daemon, repository: InMemoryRepository(data))
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.outreach.isLoaded }
        return store
    }

    static let schemes: [ColorScheme] = [.light, .dark]

    @Test func everyTabRendersWithData() async {
        let store = await mockStore()
        for tab in ColdEmailTab.allCases {
            for scheme in Self.schemes {
                let model = ColdEmailModel(store: store)
                model.tab = tab
                if tab == .outbox { model.toggle(store.outreach.drafts[0].id); model.focusedMessageID = store.outreach.drafts[0].id }
                await check("tab-\(tab.rawValue)", store: store, width: 1040, height: 680, scheme: scheme) { ColdEmailView(modelOverride: model) }
            }
        }
        await store.stop()
    }

    @Test func everyTabHasLoadingErrorAndEmptyStates() async {
        let store = await mockStore()
        let empty = await emptyStore()
        for tab in ColdEmailTab.allCases {
            for scheme in Self.schemes {
                for phase in [ColdEmailPhase.loading, .error("Can't read your outreach yet.")] {
                    let model = ColdEmailModel(store: store)
                    model.tab = tab
                    model.phaseOverride = phase
                    let name = phase == .loading ? "loading" : "error"
                    await check("\(tab.rawValue)-\(name)", store: store, width: 800, height: 420, scheme: scheme) { ColdEmailView(modelOverride: model) }
                }
                let model = ColdEmailModel(store: empty)
                model.tab = tab
                #expect(model.phase == .ready)
                await check("\(tab.rawValue)-empty", store: empty, width: 900, height: 480, scheme: scheme) { ColdEmailView(modelOverride: model) }
            }
        }
        await store.stop()
        await empty.stop()
    }

    @Test func outboxEditorStatesRender() async {
        let store = await mockStore()
        let o = store.outreach
        let clean = o.drafts.first { !$0.needsClaimsFix && (o.contact(id: o.thread(id: $0.threadID)?.contactID)?.emailConfidence ?? 0) >= 60 }!
        let ungrounded = o.drafts.first(where: \.needsClaimsFix)!
        let lowConfidence = o.drafts.first { (o.contact(id: o.thread(id: $0.threadID)?.contactID)?.emailConfidence ?? 100) < 60 }!
        let states: [(String, OutreachMessageItem, Bool)] = [
            ("clean", clean, false), ("ungrounded", ungrounded, false), ("low-confidence", lowConfidence, false), ("editing", clean, true),
        ]
        for scheme in Self.schemes {
            for (name, message, editing) in states {
                let model = ColdEmailModel(store: store)
                await check("editor-\(name)", store: store, width: 760, height: 900, scheme: scheme) {
                    // ImageRenderer draws no ScrollView content: render the editor itself.
                    DraftEditor(message: message, model: model, startEditing: editing).padding(Space.contentPadding)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        for scheme in [ColorScheme.light] {
            // Scheduled, possibly sent, sent and a reply in the Outbox detail pane.
            let others = [o.scheduled.first?.id, o.unknownSends.first?.id, o.sent.first?.id,
                          o.replyThreads.first.flatMap { o.latestReply(threadID: $0.id)?.id }].compactMap { $0 }
            #expect(others.count == 4)
            for (i, id) in others.enumerated() {
                let model = ColdEmailModel(store: store)
                model.tab = .outbox
                model.focusedMessageID = id
                await check("outbox-detail-\(i)", store: store, scheme: scheme) { ColdEmailView(modelOverride: model) }
            }
        }
        await store.stop()
    }

    @Test func sendSheetRendersWithConflictsAndSendingOff() async {
        let store = await mockStore()
        let model = ColdEmailModel(store: store)
        model.selectAllDrafts()
        model.beginSend()
        await model.approveSelected()
        if case .conflicts = model.approveState {} else { Issue.record("expected conflicts from the mock, got \(model.approveState)") }
        for scheme in Self.schemes {
            await check("send-sheet-conflicts", store: store, width: 560, height: 720, scheme: scheme) { SendConfirmSheet(model: model) }
            await check("enable-sheet", store: store, width: 480, height: 420, scheme: scheme) { EnableSendingSheet(model: model) }
            await check("add-contact", store: store, width: 480, height: 560, scheme: scheme) { AddContactSheet() }
            await check("add-referral", store: store, width: 480, height: 560, scheme: scheme) { AddReferralSheet() }
        }
        // Sending off: Up next's floating bar becomes the one-time setup.
        (store.repository as? InMemoryRepository)?.update { $0.outreach.mailAccount.sendEnabled = false }
        _ = await waitUntil { !store.outreach.sendEnabled }
        let off = ColdEmailModel(store: store)
        off.tab = .outbox
        await check("sending-off-outbox", store: store, scheme: .light) { ColdEmailView(modelOverride: off) }
        await check("send-bar-setup", store: store, width: 640, height: 80, scheme: .light) { SendBar(model: off) }
        await store.stop()
    }

    /// People ▸ Could refer you (the three-step referral checklist) and an applied job with no
    /// note yet, rendered directly (ImageRenderer leaves ScrollView content blank).
    @Test func peopleReferralsAndAppliedJobRender() async {
        let store = await mockStore()
        let model = ColdEmailModel(store: store)
        model.showPeople(.couldRefer)
        #expect(model.tab == .people && model.peopleFilter == .couldRefer)
        let referrals = store.outreach.data.referrals.filter { $0.state != .dismissed }
        #expect(!referrals.isEmpty)
        let job = model.jobsAwaitingNote.first
        #expect(job != nil, "the mock has applications nobody has been written to yet")
        for scheme in Self.schemes {
            await check("people-could-refer", store: store, width: 1040, height: 680, scheme: scheme) { ColdEmailView(modelOverride: model) }
            for r in referrals.prefix(4) {
                await check("referral-\(r.state.rawValue)", store: store, width: 760, height: 360, scheme: scheme) {
                    ReferralCard(referral: r, model: model).padding(Space.l).frame(maxHeight: .infinity, alignment: .top)
                }
            }
            if let job {
                await check("applied-no-note", store: store, width: 760, height: 560, scheme: scheme) {
                    AppliedJobPanel(job: job, model: model).padding(Space.l).frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        await store.stop()
    }

    @Test func needsYouRepliesRender() async {
        let store = await mockStore()
        let inbox = InboxModel.shared(for: store)
        for item in inbox.replyItems {
            inbox.selectReply(item.key)
            for scheme in Self.schemes {
                await check("needs-you-\(item.key)", store: store, scheme: scheme) { InboxView() }
            }
        }
        await store.stop()
    }

    @Test func jobOutreachAndSettingsRender() async {
        let store = await mockStore()
        let replied = store.outreach.unreadReplyThreads.first.flatMap { store.jobs.job(applicationID: $0.applicationID ?? -1) }!
        let suggested = store.outreach.pendingSuggestions.first.flatMap { store.jobs.job(applicationID: $0.applicationID) }!
        let settings = SettingsModel(store: store)
        for scheme in Self.schemes {
            await check("inspector-replied", store: store, width: LayoutMetrics.inspectorWidth, height: 900, scheme: scheme) {
                JobInspector(jobID: replied.id)
            }
            await check("inspector-suggestion", store: store, width: LayoutMetrics.inspectorWidth, height: 900, scheme: scheme) {
                JobInspector(jobID: suggested.id)
            }
            await check("job-detail-suggestion", store: store, width: 1200, height: 900, scheme: scheme) { JobDetailView(jobID: suggested.id) }
            // The pieces themselves (the inspector and detail scroll, which ImageRenderer leaves blank).
            await check("job-outreach-pieces", store: store, width: LayoutMetrics.inspectorWidth, height: 520, scheme: scheme) {
                VStack(alignment: .leading, spacing: Space.l) {
                    ReplySuggestionCard(reply: store.outreach.pendingSuggestions[0])
                    JobOutreachSection(job: replied)
                    JobOutreachSection(job: suggested)
                }
                .padding(Space.l)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            await check("settings-outreach", store: store, width: 680, height: 1400, scheme: scheme) {
                VStack(alignment: .leading, spacing: Space.l) { OutreachSettingsTab(model: settings) }.padding(Space.xl)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        await store.stop()
    }
}
