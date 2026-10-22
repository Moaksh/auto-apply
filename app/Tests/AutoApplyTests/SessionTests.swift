// SessionTests.swift — "Today's ten minutes": the briefing summary and estimates, the guided
// session (order, Next / Skip / End, finishing as work gets done, "Done for today"), the live
// sources and navigation against the mock store, and offscreen renders of the briefing card and
// the session bar in light and dark, with Reduce Motion on and off.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Session")
struct SessionModelTests {
    private func item(_ key: SessionItem.Key, _ kind: SessionKind, seconds: Int = 30) -> SessionItem {
        SessionItem(key: key, kind: kind, subject: "\(key)", seconds: seconds)
    }

    private var sample: [SessionItem] {
        SessionSources(
            blockers: [item(.cluster("b1"), .blocker, seconds: 120)],
            questions: [item(.cluster("q1"), .question, seconds: 10), item(.cluster("q2"), .question, seconds: 90)],
            reviews: [item(.review(jobID: 1), .review, seconds: 40)],
            replies: [item(.reply(.outreach(5)), .reply)],
            preps: [item(.prep(jobID: 2), .prep, seconds: 180)],
            drafts: [item(.draft(messageID: 9), .draft)]
        ).items
    }

    // MARK: Ordering and estimates

    @Test func itemsComeInSessionOrder() {
        // Sources filled out of order still come out blocker → question → review → reply → prep → draft.
        let sources = SessionSources(
            blockers: [item(.cluster("b"), .blocker)],
            questions: [item(.cluster("q1"), .question), item(.cluster("q2"), .question)],
            reviews: [item(.review(jobID: 3), .review)],
            replies: [item(.reply(.employer(4)), .reply)],
            preps: [item(.prep(jobID: 5), .prep)],
            drafts: [item(.draft(messageID: 6), .draft)])
        let kinds = sources.items.map(\.kind)
        #expect(kinds == [.blocker, .question, .question, .review, .reply, .prep, .draft])
        #expect(kinds == kinds.sorted())
        // Each source keeps its own order.
        #expect(sources.items.map(\.key).prefix(3) == [.cluster("b"), .cluster("q1"), .cluster("q2")])
    }

    @Test func duplicateKeysAreDropped() {
        let sources = SessionSources(questions: [item(.cluster("q"), .question), item(.cluster("q"), .question)])
        #expect(sources.items.count == 1)
        #expect(SessionSources().isEmpty)
    }

    @Test func estimatesFollowTheKindOfWork() {
        #expect(SessionEstimate.seconds(for: .yesNo) == 10)
        #expect(SessionEstimate.seconds(for: .choice(multi: false)) == 15)
        #expect(SessionEstimate.seconds(for: .shortText) == 30)
        #expect(SessionEstimate.seconds(for: .longText) == 90)
        #expect(SessionEstimate.seconds(for: .action) == 120)
        #expect(SessionEstimate.review(flagged: true) == 40)
        #expect(SessionEstimate.review(flagged: false) == 15)
        #expect(SessionEstimate.prep == 180)
        #expect(SessionEstimate.draft == 30)
    }

    @Test func estimateLabelsRoundUpAndSayAbout() {
        #expect(SessionEstimate.label(seconds: 0) == "no time")
        #expect(SessionEstimate.label(seconds: 45) == "under a minute")
        #expect(SessionEstimate.label(seconds: 60) == "about 1 min")
        #expect(SessionEstimate.label(seconds: 61) == "about 2 min")
        #expect(SessionEstimate.label(seconds: 540) == "about 9 min")
    }

    @Test func briefingGroupsCountsAndTotals() {
        let summary = BriefingSummary(items: sample)
        #expect(summary.groups.map(\.kind) == [.blocker, .question, .review, .reply, .prep, .draft])
        let questions = summary.groups.first { $0.kind == .question }
        #expect(questions?.count == 2)
        #expect(questions?.seconds == 100)
        #expect(questions?.label == "2 questions to answer")
        #expect(questions?.estimate == "about 2 min")
        #expect(summary.itemCount == 7)
        #expect(summary.totalSeconds == 120 + 100 + 40 + 30 + 180 + 30)
        #expect(summary.totalLabel == "about 9 min")
        #expect(summary.headline == "7 things are waiting for you, about 9 min in all.")
        #expect(summary.startTitle == "Start · 9 min")
        #expect(!summary.isDone)
    }

    @Test func briefingSingularsAndDone() {
        #expect(SessionKind.review.groupLabel(count: 1) == "1 application to look over")
        #expect(SessionKind.reply.groupLabel(count: 3) == "3 replies to read")
        #expect(SessionKind.prep.groupLabel(count: 1) == "1 interview to prepare for")
        #expect(SessionKind.draft.groupLabel(count: 2) == "2 cold-email drafts to check")
        let one = BriefingSummary(items: [item(.cluster("q"), .question, seconds: 10)])
        #expect(one.headline == "1 thing is waiting for you, under a minute in all.")
        #expect(one.startTitle == "Start · under a minute")
        let none = BriefingSummary(items: [])
        #expect(none.isDone)
        #expect(none.headline == "Nothing is waiting for you.")
    }

    // MARK: The session

    @Test func startsOnlyWithWork() {
        let session = SessionModel()
        #expect(session.start([]) == false)
        #expect(session.phase == .idle)
        #expect(session.start(sample))
        #expect(session.phase == .active)
        #expect(session.current?.key == .cluster("b1"))
        #expect(session.progressLabel == "1 of 7")
        #expect(session.navigationSerial == 1)
    }

    @Test func nextAndSkipAdvance() {
        let session = SessionModel()
        session.start(sample)
        session.next()
        #expect(session.current?.key == .cluster("q1"))
        #expect(session.progressLabel == "2 of 7")
        #expect(session.navigationSerial == 2)
        session.skip()
        #expect(session.current?.key == .cluster("q2"))
        #expect(session.finishedCount == 1)
        #expect(session.skippedCount == 1)
        // Time left counts the current item and everything after it.
        #expect(session.remainingSeconds == 90 + 40 + 30 + 180 + 30)
        #expect(session.remainingLabel == "about 7 min left")
    }

    @Test func reconcileFinishesDoneWorkAndAdvancesPastIt() {
        let session = SessionModel()
        session.start(sample)
        let all = Set(sample.map(\.key))
        // Something later finished elsewhere: the current item stays put.
        session.reconcile(open: all.subtracting([.review(jobID: 1)]))
        #expect(session.current?.key == .cluster("b1"))
        // The current item and the next are done: jump over both, and over the finished review.
        session.reconcile(open: all.subtracting([.cluster("b1"), .cluster("q1"), .cluster("q2"), .review(jobID: 1)]))
        #expect(session.current?.key == .reply(.outreach(5)))
        #expect(session.progressLabel == "5 of 7")
        #expect(session.finishedCount == 4)
        // Reconcile does nothing when no session is running.
        let idle = SessionModel()
        idle.reconcile(open: [])
        #expect(idle.phase == .idle)
    }

    @Test func endsOnDoneForToday() {
        let session = SessionModel()
        session.start(Array(sample.prefix(3)))
        session.next()
        session.skip()
        #expect(session.phase == .active)
        session.next()
        #expect(session.phase == .done)
        #expect(session.current == nil)
        #expect(session.doneSerial == 1)
        #expect(session.remainingSeconds == 0)
        #expect(session.doneMessage == "1 item left for later. The agent takes it from here.")
        session.dismissDone()
        #expect(session.phase == .idle)
        #expect(session.items.isEmpty)
    }

    @Test func allWorkDoneElsewhereFinishesTheSession() {
        let session = SessionModel()
        session.start(sample)
        session.reconcile(open: [])
        #expect(session.phase == .done)
        #expect(session.doneMessage == "The agent takes it from here.")
    }

    @Test func endStopsEarlyAndKeepsNothing() {
        let session = SessionModel()
        session.start(sample)
        session.next()
        session.end()
        #expect(session.phase == .idle)
        #expect(session.current == nil)
        #expect(session.doneSerial == 0, "ending early isn't 'Done for today'")
        // Next / Skip / showCurrent are no-ops without a session.
        session.next()
        session.skip()
        let serial = session.navigationSerial
        session.showCurrent()
        #expect(session.navigationSerial == serial)
        #expect(session.phase == .idle)
    }

    @Test func showCurrentAsksToNavigateAgain() {
        let session = SessionModel()
        session.start(sample)
        let serial = session.navigationSerial
        session.showCurrent()
        #expect(session.navigationSerial == serial + 1)
        #expect(session.current?.key == .cluster("b1"))
    }
}

// MARK: - Live sources, navigation and renders

@MainActor
@Suite("Session with the mock store", .serialized)
struct SessionStoreTests {
    let outputDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    private func mockStore(_ scenario: MockScenario = .idle) async -> AppStore {
        FeatureModels.reset()
        let daemon = MockDaemon(scenario: scenario, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
        store.statsDebounce = .milliseconds(1)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.outreach.isLoaded && store.outreach.repliesLoaded }
        store.recomputeStats()
        return store
    }

    @Test func liveSourcesReadEveryStoreInOrder() async {
        let store = await mockStore()
        let items = SessionSources.live(store: store).items
        #expect(!items.isEmpty)
        #expect(items.map(\.kind) == items.map(\.kind).sorted(), "session order")
        let inbox = InboxModel.shared(for: store)
        let review = ReviewModel.shared(for: store)
        #expect(items.filter { $0.kind == .question || $0.kind == .blocker }.count == inbox.clusters.count)
        #expect(items.filter { $0.kind == .review }.map(\.key) == review.queue.map { .review(jobID: $0.id) })
        #expect(items.filter { $0.kind == .reply }.count == inbox.replyItems.count)
        #expect(items.filter { $0.kind == .draft }.count == store.outreach.drafts.count)
        #expect(items.allSatisfy { $0.seconds > 0 && !$0.subject.isEmpty })
        await store.stop()
    }

    @Test func navigatorSelectsEachKindOfItem() async throws {
        let store = await mockStore()
        let items = SessionSources.live(store: store).items
        let router = store.router

        if let q = items.first(where: { $0.kind == .question }), case .cluster(let id) = q.key {
            SessionNavigator.show(q, store: store)
            #expect(router.selection == .needsYou)
            #expect(InboxModel.shared(for: store).selectedClusterID == id)
        }
        if let r = items.first(where: { $0.kind == .review }), case .review(let jobID) = r.key {
            SessionNavigator.show(r, store: store)
            #expect(router.selection == .review)
            #expect(ReviewModel.shared(for: store).focusedJobID == jobID)
        }
        if let reply = items.first(where: { $0.kind == .reply }), case .reply(let key) = reply.key {
            SessionNavigator.show(reply, store: store)
            #expect(router.selection == .needsYou)
            #expect(InboxModel.shared(for: store).selectedReplyKey == key)
        }
        if let d = items.first(where: { $0.kind == .draft }), case .draft(let messageID) = d.key {
            SessionNavigator.show(d, store: store)
            #expect(router.selection == .coldEmail)
            let cold = ColdEmailModel.shared(for: store)
            #expect(cold.tab == .outbox)
            #expect(cold.focusedMessageID == messageID)
        }
        // Interview prep opens the job on its prep tab.
        let job = try #require(store.jobs.all.first { $0.state == .submitted && $0.applicationID != nil })
        SessionNavigator.show(SessionItem(key: .prep(jobID: job.id), kind: .prep, subject: job.displayName, seconds: 180), store: store)
        #expect(router.selection == .pipeline)
        #expect(router.openJobDetailID == job.id)
        // Going back to a list screen drops the pushed job.
        if let q = items.first(where: { $0.kind == .question }) {
            SessionNavigator.show(q, store: store)
            #expect(router.path.isEmpty)
        }
        await store.stop()
    }

    @Test func doneWorkFinishesItsItem() async throws {
        let store = await mockStore()
        let session = SessionModel.shared(for: store)
        let items = SessionSources.live(store: store).items
        #expect(session.start(items))
        let first = try #require(session.current)
        // The first item's work is done (it's gone from its source): the session moves on.
        session.reconcile(open: Set(items.map(\.key)).subtracting([first.key]))
        #expect(session.current?.key != first.key)
        #expect(session.finishedCount == 1)
        session.end()
        await store.stop()
    }

    @Test func prepIsDueOnlyWithoutAPack() async throws {
        let store = await mockStore()
        let prep = InterviewPrepModel.shared(for: store)
        let due = SessionSources.prepDue(store: store, prep: prep)
        #expect(due.allSatisfy { [.assessment, .interview].contains($0.status ?? .applied) && $0.state == .submitted })
        if let job = due.first, let id = job.applicationID {
            await prep.generate(applicationID: id, force: true)
            if prep.pack(id) != nil {
                #expect(!SessionSources.prepDue(store: store, prep: prep).contains { $0.id == job.id })
            }
        }
        await store.stop()
    }

    // MARK: Prominence

    private func primaries<V: View>(store: AppStore, width: CGFloat = 1200, height: CGFloat = 1500, @ViewBuilder _ view: () -> V) -> Int {
        let audit = ProminenceAudit()
        let renderer = ImageRenderer(content: view()
            .appEnvironment(store, simulateReduceMotion: true)
            .environment(\.prominenceAudit, audit)
            .frame(width: width, height: height)
            .background(Palette.windowBackground))
        _ = renderer.cgImage
        return audit.count
    }

    @Test func startIsTheDashboardsOnePrimaryWhenThereIsWork() async {
        let store = await mockStore()
        #expect(!BriefingSummary(items: SessionSources.live(store: store).items).isDone)
        #expect(primaries(store: store, width: 900, height: 500) { BriefingCard() } == 1, "Start")
        #expect(primaries(store: store) { DashboardView() } == 1, "Dashboard: Start only")
        // While a session runs the bar carries the action; the card has none.
        let session = SessionModel.shared(for: store)
        session.start(SessionSources.live(store: store).items)
        #expect(primaries(store: store, width: 900, height: 500) { BriefingCard() } == 0)
        session.end()
        await store.stop()
    }

    // MARK: Renders

    private func render<V: View>(_ name: String, store: AppStore, width: CGFloat = 900, height: CGFloat = 420,
                                 scheme: ColorScheme, reduceMotion: Bool, @ViewBuilder _ view: () -> V) async {
        let content = view()
            .appEnvironment(store, simulateReduceMotion: reduceMotion)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = renderer.cgImage
        #expect(image != nil, "\(name)")
        if let image, let dir = outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let suffix = "\(scheme == .dark ? "dark" : "light")\(reduceMotion ? "-reduced" : "")"
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("session-\(name)-\(suffix).png"))
            }
        }
        await Task.yield()
    }

    @Test func rendersBriefingAndBarInBothSchemesAndMotionSettings() async {
        let store = await mockStore()
        let session = SessionModel.shared(for: store)
        for scheme in [ColorScheme.light, .dark] {
            for reduced in [true, false] {
                await render("briefing", store: store, scheme: scheme, reduceMotion: reduced) { BriefingCard().padding() }
                await render("dashboard", store: store, width: 1200, height: 1600, scheme: scheme, reduceMotion: reduced) { DashboardView() }
                session.start(SessionSources.live(store: store).items)
                session.next()
                await render("briefing-in-progress", store: store, height: 200, scheme: scheme, reduceMotion: reduced) { BriefingCard().padding() }
                await render("bar", store: store, height: 100, scheme: scheme, reduceMotion: reduced) { SessionBar(session: session) }
                session.reconcile(open: [])
                #expect(session.phase == .done)
                await render("bar-done", store: store, height: 100, scheme: scheme, reduceMotion: reduced) { SessionBar(session: session) }
                session.end()
            }
        }
        await store.stop()
    }

    @Test func rendersDoneForToday() async {
        let store = await mockStore(.firstRunEmpty)
        let summary = BriefingSummary(items: SessionSources.live(store: store).items)
        #expect(summary.isDone, "first run: nothing waiting")
        for scheme in [ColorScheme.light, .dark] {
            for reduced in [true, false] {
                await render("briefing-done", store: store, height: 200, scheme: scheme, reduceMotion: reduced) { BriefingCard().padding() }
            }
        }
        #expect(primaries(store: store, width: 900, height: 300) { BriefingCard() } == 0, "nothing to start")
        await store.stop()
    }
}
