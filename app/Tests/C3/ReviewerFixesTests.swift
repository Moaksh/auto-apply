// ReviewerFixesTests.swift — regressions for review findings: Review approve in-flight guard and
// fail-closed safeguard while answers load, Inbox held answers vs. remote resolution, and mode
// changes that must not be blocked by unrelated invalid settings.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Reviewer fixes", .serialized)
struct ReviewerFixesTests {
    private func reviewSetup(subscribe: Bool = true) async -> (AppStore, C3StubDaemon, ReviewModel) {
        var data = RepositoryData()
        data.jobs = [
            C3Fixtures.job(id: 1, company: "Stripe", state: .awaitingReview, score: 91),
            C3Fixtures.job(id: 2, company: "Ramp", state: .awaitingReview, score: 86),
        ]
        data.applicationAnswers = [
            1: [C3Fixtures.answer(id: 11, app: 1, question: "Full name")],
            2: [C3Fixtures.answer(id: 21, app: 2, question: "Start date", confidence: 0.4, origin: .generated)],
        ]
        let (store, daemon, _) = await makeC3Store(data: data)
        let model = ReviewModel(store: store)
        model.sendHold.window = .milliseconds(20)
        if subscribe {
            model.syncSubscriptions()
            _ = await c3WaitUntil { model.loadedApplicationIDs.count == 2 }
        }
        return (store, daemon, model)
    }

    private func approves(_ daemon: C3StubDaemon) -> [[Int]] {
        daemon.sent("approve").compactMap { if case .approve(let p) = $0 { p.applicationIds } else { nil } }
    }

    @Test func doubleApproveDuringTheHoldSendsOnce() async {
        let (store, daemon, model) = await reviewSetup()
        model.sendHold.window = .milliseconds(200)
        model.focusedJobID = 1
        model.requestApprove()
        #expect(model.isHeld(1))
        // Focus moved on; pressing again (or approving the held row directly) adds nothing.
        model.focusedJobID = 1
        #expect(model.targets.isEmpty)
        model.requestApprove()
        model.approve([1])
        #expect(await c3WaitUntil { !approves(daemon).isEmpty && !model.sendHold.hasHolds })
        try? await Task.sleep(for: .milliseconds(250))
        #expect(approves(daemon) == [[1]])
        #expect(store.jobs.job(id: 1)?.state == .submitting)
        #expect(store.toasts.current?.style != .error)
    }

    @Test func approveBeforeAnswersLoadAsksInsteadOfSubmitting() async {
        let (_, daemon, model) = await reviewSetup(subscribe: false)
        model.focusedJobID = 1
        let job = try! #require(model.queue.first { $0.id == 1 })
        #expect(!model.answersLoaded(job))
        #expect(model.needsLook(job))
        #expect(model.approveTitle == "Approve (needs a look)")
        model.requestApprove()
        #expect(model.barMode == .confirmAllFlagged(targets: [1]))
        #expect(model.anyLoading([1]))
        #expect(approves(daemon).isEmpty)
        // "Only the clean ones" never includes unknowns.
        model.selectAll()
        model.requestApprove()
        #expect(model.barMode == .confirmAllFlagged(targets: [1, 2]) || model.barMode == .confirmAllFlagged(targets: [2, 1]))
        model.cancelBar()
        // Once loaded, the clean one goes straight through.
        model.clearSelection()
        model.syncSubscriptions()
        #expect(await c3WaitUntil { model.loadedApplicationIDs.count == 2 })
        model.focusedJobID = 1
        model.requestApprove()
        #expect(await c3WaitUntil { approves(daemon) == [[1]] })
    }

    // MARK: Inbox

    private func inboxSetup(_ clusters: [QuestionCluster]) async -> (AppStore, C3StubDaemon, InboxModel) {
        var data = RepositoryData()
        data.jobs = [1, 2, 3].map { C3Fixtures.job(id: $0, state: .needsYou) }
        let (store, daemon, _) = await makeC3Store(data: data, clusters: clusters)
        let model = InboxModel(store: store)
        model.clipboard = RecordingClipboard()
        _ = await c3WaitUntil { store.inbox.openCount == clusters.count }
        return (store, daemon, model)
    }

    @Test func heldAnswerIsDroppedWhenResolvedElsewhere() async throws {
        let (store, daemon, model) = await inboxSetup([C3Fixtures.cluster("a", jobs: [1, 2]), C3Fixtures.cluster("b", jobs: [3])])
        model.undoWindow = .milliseconds(250)
        model.select("a")
        let a = try #require(model.selectedCluster)
        model.updateDraft(for: a) { $0.text = "Because" }
        #expect(model.submitSelected())
        daemon.push(.questionResolved(QuestionResolvedPayload(clusterId: "a", status: .answered, resumedApplicationIds: [1, 2])))
        #expect(await c3WaitUntil { store.inbox.resolvedToday.contains { $0.clusterID == "a" } })
        try await Task.sleep(for: .milliseconds(400))
        #expect(daemon.sent("answer_question").isEmpty)
        #expect(store.inbox.cluster(id: "a") == nil)
        #expect(store.inbox.resolvedToday.contains { $0.clusterID == "a" })
        #expect(model.answeredTodayRows.filter { $0.clusterID == "a" }.count == 1)
    }

    @Test func failedSendRestoresFullDraftButNotWhenResolvedElsewhere() async throws {
        let (store, daemon, model) = await inboxSetup([
            C3Fixtures.cluster("yn", jobs: [1], question: "Authorized to work?", fieldType: .boolean),
            C3Fixtures.cluster("pj", jobs: [2, 3], question: "Why us?"),
        ])
        model.undoWindow = .milliseconds(20)
        daemon.responder = { cmd in
            if case .answerQuestion = cmd { return .error(ErrorPayload(code: .notFound, message: "no such cluster")) }
            return .ack(AckPayload())
        }
        model.select("yn")
        let yn = try #require(model.selectedCluster)
        model.updateDraft(for: yn) { $0.yesNo = false; $0.saveToMemory = false }
        #expect(model.submitSelected())
        #expect(await c3WaitUntil { daemon.sent("answer_question").count == 1 && store.inbox.cluster(id: "yn") != nil })
        #expect(model.draft(for: yn).yesNo == false)
        #expect(model.draft(for: yn).saveToMemory == false)

        // Now a failure for a cluster the daemon resolved meanwhile must not resurrect it.
        daemon.responder = { cmd in
            if case .answerQuestion = cmd {
                return .error(ErrorPayload(code: .notFound, message: "no such cluster"))
            }
            return .ack(AckPayload())
        }
        model.undoWindow = .milliseconds(150)
        model.select("pj")
        let pj = try #require(model.selectedCluster)
        model.updateDraft(for: pj) { $0.text = "Mission" }
        #expect(model.submitSelected())
        // Resolve remotely during the window → never sent and never restored.
        daemon.push(.questionResolved(QuestionResolvedPayload(clusterId: "pj", status: .skipped)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(daemon.sent("answer_question").count == 1)
        #expect(store.inbox.cluster(id: "pj") == nil)
        #expect(store.inbox.resolvedToday.contains { $0.clusterID == "pj" })
    }

    @Test func undoAfterRemoteResolutionDoesNotResurrect() async throws {
        let (store, daemon, model) = await inboxSetup([C3Fixtures.cluster("a", jobs: [1])])
        model.undoWindow = .seconds(5)
        model.select("a")
        let a = try #require(model.selectedCluster)
        model.updateDraft(for: a) { $0.text = "x" }
        #expect(model.submitSelected())
        daemon.push(.questionResolved(QuestionResolvedPayload(clusterId: "a", status: .answered)))
        #expect(await c3WaitUntil { store.inbox.resolvedToday.contains { $0.clusterID == "a" } })
        #expect(!model.undo(clusterID: "a"))
        #expect(store.inbox.cluster(id: "a") == nil)
        await model.flushPending()
        #expect(daemon.sent("answer_question").isEmpty)
    }

    // MARK: Settings

    @Test func modeChangeIsSentEvenWithAnInvalidFieldElsewhere() async throws {
        let (store, daemon, _) = await makeC3Store()
        daemon.responder = { cmd in
            if case .updatePreferences(let p) = cmd {
                var prefs = Preferences()
                if p.preferences.values["mode"] == .string("auto") { prefs.mode = .auto }
                return .ack(AckPayload(ok: true, result: ["preferences": (try? JSONValue.encode(prefs)) ?? .null]))
            }
            return .ack(AckPayload())
        }
        let model = SettingsModel(store: store)
        model.debounce = .milliseconds(20)
        model.preferencesDraft.remotePolicy = []
        #expect(model.issue(for: .remotePolicy) != nil)
        #expect(await model.setGlobalMode(.auto))  // new installs start in Review (schema v13)
        #expect(daemon.sent("update_preferences").map(\.preferencesValues) == [["mode": .string("auto")]])
        #expect(store.preferences.mode == .auto)
        #expect(model.preferencesDraft.mode == .auto)
        #expect(model.preferencesDraft.remotePolicy.isEmpty)   // the invalid edit is still pending
        // An explicit save with the invalid field reports why instead of silently idling.
        #expect(await model.savePreferences() == false)
        guard case .failed = model.preferencesSave else { Issue.record("expected failed save state"); return }
    }

    @Test func failedModeChangeRevertsThePicker() async {
        let (store, daemon, _) = await makeC3Store()
        daemon.responder = { cmd in
            if case .updatePreferences = cmd { return .error(ErrorPayload(code: .invalidPayload, message: "nope")) }
            return .ack(AckPayload())
        }
        let model = SettingsModel(store: store)
        let before = model.preferencesDraft.mode
        let other: Mode = before == .auto ? .review : .auto
        #expect(await model.setGlobalMode(other) == false)
        #expect(model.preferencesDraft.mode == before)
        #expect(store.preferences.mode == before)
        guard case .failed = model.preferencesSave else { Issue.record("expected failed save state"); return }
    }
}
