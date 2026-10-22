// ReviewAndEasyApplyTests.swift — Review queue (flag-first ordering, the low-confidence
// safeguard, staggered approve, skip reasons, inline edits) and the Easy Apply list (filters,
// copy rows, copy-all, open + mark opened, mark applied).
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Review queue", .serialized)
struct ReviewModelTests {
    /// Jobs 1–3 await review; job 2 has a low-confidence answer, job 3 a medium one.
    private func setup() async -> (AppStore, C3StubDaemon, ReviewModel) {
        var data = RepositoryData()
        data.jobs = [
            C3Fixtures.job(id: 1, company: "Stripe", state: .awaitingReview, score: 91),
            C3Fixtures.job(id: 2, company: "Ramp", state: .awaitingReview, score: 86),
            C3Fixtures.job(id: 3, company: "Notion", state: .awaitingReview, score: 95),
            C3Fixtures.job(id: 4, company: "Figma", state: .queued, score: 99),
        ]
        data.applicationAnswers = [
            1: [C3Fixtures.answer(id: 11, app: 1, question: "Full name"), C3Fixtures.answer(id: 12, app: 1, question: "Years w/ Go", confidence: 0.93, origin: .cv)],
            2: [C3Fixtures.answer(id: 21, app: 2, question: "Start date", answer: "2 months", confidence: 0.4, origin: .generated)],
            3: [C3Fixtures.answer(id: 31, app: 3, question: "Why Notion?", confidence: 0.7, origin: .memory)],
        ]
        let (store, daemon, _) = await makeC3Store(data: data)
        let model = ReviewModel(store: store)
        // A short send hold: approvals still wait for it, the tests just don't wait 5 s.
        model.sendHold.window = .milliseconds(20)
        model.syncSubscriptions()
        _ = await c3WaitUntil { model.answers.count == 3 }
        return (store, daemon, model)
    }

    /// Wait out the send hold.
    private func settled(_ model: ReviewModel) async {
        _ = await c3WaitUntil { !model.sendHold.hasHolds }
    }

    private func approvedIDs(_ daemon: C3StubDaemon) -> [Int] {
        daemon.sent("approve").flatMap { cmd -> [Int] in if case .approve(let p) = cmd { p.applicationIds } else { [] } }
    }

    @Test func flaggedSortToTheTopThenScore() async {
        let (_, _, model) = await setup()
        #expect(model.queue.map(\.id) == [2, 3, 1])
        #expect(model.flaggedAnswers(for: model.queue[0]).map(\.id) == [21])
        #expect(!model.isFlagged(model.queue[2]))
    }

    @Test func cleanApproveHoldsThenSends() async {
        let (store, daemon, model) = await setup()
        model.focusedJobID = 1
        #expect(model.approveTitle == "Approve & send")
        model.requestApprove()
        #expect(model.barMode == .actions)
        #expect(model.isHeld(1), "on the send hold first")
        #expect(approvedIDs(daemon).isEmpty, "nothing is sent during the hold")
        #expect(model.focusedJobID != 1, "focus moves on")
        await settled(model)
        #expect(approvedIDs(daemon) == [1])
        #expect(store.jobs.job(id: 1)?.state == .submitting)
        #expect(store.toasts.current?.message == "Approved · sending now")
    }

    @Test func mixedSelectionAsksInlineAndCanApproveOnlyClean() async {
        let (_, daemon, model) = await setup()
        model.selectAll()
        #expect(model.approveTitle == "Approve 3 (2 need a look)")
        model.requestApprove()
        #expect(model.barMode == .confirmFlagged(targets: [2, 3, 1]))
        #expect(approvedIDs(daemon).isEmpty)
        model.confirmApprove(includeFlagged: false)
        #expect(model.barMode == .actions)
        #expect(model.selection == [2, 3])
        await settled(model)
        #expect(approvedIDs(daemon) == [1])
    }

    @Test func approveSendsOneJobPerCompanyAndKeepsTheRest() async {
        let (store, daemon, model) = await setup()
        let stripeID = store.jobs.job(id: 1)!.companyID
        store.jobs.mutate(applicationID: 2) { $0.companyID = stripeID; $0.company = "Stripe" }
        model.approve([1, 2, 3])
        #expect(store.toasts.current?.message.contains("Kept 1 in Review") == true)
        await settled(model)
        #expect(Set(approvedIDs(daemon)) == [1, 3])
        #expect(store.jobs.job(id: 2)?.state == .awaitingReview)
    }

    @Test func perCompanyCountsJobsAlreadyOnHold() async {
        let (store, daemon, model) = await setup()
        model.sendHold.window = .seconds(30)
        let stripeID = store.jobs.job(id: 1)!.companyID
        store.jobs.mutate(applicationID: 2) { $0.companyID = stripeID; $0.company = "Stripe" }
        model.approve([1])
        model.approve([2])
        #expect(model.isHeld(1) && !model.isHeld(2), "a second Stripe job isn't held while the first one is")
        #expect(store.toasts.current?.message.contains("Kept 1 in Review") == true)
        model.sendHold.abandonAll()
        #expect(approvedIDs(daemon).isEmpty)
    }

    @Test func includeFlaggedApprovesEverything() async {
        let (_, daemon, model) = await setup()
        model.toggleSelection(1)
        model.toggleSelection(2)
        model.requestApprove()
        model.confirmApprove(includeFlagged: true)
        await settled(model)
        #expect(Set(approvedIDs(daemon)) == [1, 2])
    }

    @Test func allFlaggedAsksApproveAnyway() async {
        let (_, daemon, model) = await setup()
        model.focusedJobID = 2
        model.requestApprove()
        #expect(model.barMode == .confirmAllFlagged(targets: [2]))
        model.cancelBar()
        #expect(model.barMode == .actions)
        #expect(approvedIDs(daemon).isEmpty)
    }

    @Test func errorReplyRollsBackState() async {
        let (store, daemon, model) = await setup()
        daemon.responder = { cmd in
            if case .approve = cmd { return .error(ErrorPayload(code: .paused, message: "Agent is paused")) }
            return .ack(AckPayload())
        }
        model.focusedJobID = 1
        model.requestApprove()
        await settled(model)
        #expect(daemon.sent("approve").count == 1)
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview)
        #expect(model.queue.contains { $0.id == 1 })
        #expect(!model.isHeld(1), "can be approved again")
    }

    @Test func skipAsksForReasonThenRejects() async throws {
        let (store, daemon, model) = await setup()
        model.focusedJobID = 3
        model.requestSkip()
        #expect(model.barMode == .skipReason(targets: [3]))
        await model.skip(reason: .wrongAnswers)
        let reject = try #require(daemon.sent("reject").first)
        guard case .reject(let p) = reject else { Issue.record("expected reject"); return }
        #expect(p.applicationId == 3)
        #expect(p.reason == "wrong_answers")
        #expect(store.jobs.job(id: 3)?.state == .skipped)
        #expect(model.barMode == .actions)
    }

    @Test func inlineEditIsOptimisticAndSent() async throws {
        let (_, daemon, model) = await setup()
        let answer = try #require(model.answers[2]?.first)
        await model.editAnswer(answer, to: "  3 months ")
        #expect(model.answers[2]?.first?.answer == "3 months")
        #expect(model.answers[2]?.first?.origin == .user)
        let edit = try #require(daemon.sent("edit_application_answer").first)
        guard case .editApplicationAnswer(let p) = edit else { Issue.record("expected edit"); return }
        #expect(p.applicationAnswerId == 21 && p.answer == "3 months")
        // Unchanged / empty edits send nothing.
        await model.editAnswer(answer, to: "")
        #expect(daemon.sent("edit_application_answer").count == 1)
    }

    @Test func modeSummaryListsOverrides() async {
        let (store, _, model) = await setup()
        var p = store.preferences
        p.mode = .auto  // new installs start in Review (schema v13)
        store.setPreferences(p)
        #expect(model.modeSummary == "Mode: Auto (Workday: Review)")
        p.mode = .review
        store.setPreferences(p)
        #expect(model.modeSummary == "Mode: Review")
    }

    @Test func approvingWithMockDaemonSubmits() async throws {
        let daemon = MockDaemon(scenario: .reviewMode, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "reviewMode")
        store.start()
        // The scenario fills 5 applications one after another (the 3rd is low-confidence).
        #expect(await c3WaitUntil(timeout: .seconds(20)) { store.jobs.awaitingReview.count >= 5 })
        let model = ReviewModel(store: store)
        model.sendHold.window = .milliseconds(20)
        model.syncSubscriptions()
        #expect(await c3WaitUntil { model.answers.count == store.jobs.awaitingReview.count })
        // The low-confidence application sorts first.
        let first = try #require(model.queue.first)
        #expect(model.isFlagged(first))
        let clean = try #require(model.queue.last)
        #expect(!model.isFlagged(clean))
        model.focusedJobID = clean.id
        model.requestApprove()
        #expect(await c3WaitUntil(timeout: .seconds(10)) { store.jobs.job(id: clean.id)?.state == .submitted })
        await store.stop()
    }
}

@MainActor
@Suite("C3 · Easy Apply", .serialized)
struct EasyApplyModelTests {
    private func setup() async -> (AppStore, C3StubDaemon, EasyApplyModel, RecordingClipboard, Box<[URL]>) {
        var data = RepositoryData()
        var a = C3Fixtures.job(id: 1, company: "Razorpay", title: "Backend SDE", state: .discovered, score: 88)
        a.easyApply = true
        var b = C3Fixtures.job(id: 2, company: "CRED", title: "Platform Eng", state: .discovered, score: 84)
        b.easyApply = true
        var c = C3Fixtures.job(id: 3, company: "Zepto", title: "Backend", state: .submitted, score: 79)
        c.easyApply = true
        data.jobs = [a, b, c]
        let answers = [
            DraftedAnswer(question: "Phone", answer: "+91 98765 43210", origin: "profile"),
            DraftedAnswer(question: "Notice period", answer: "60 days", origin: "never_guess", locked: true),
            DraftedAnswer(question: "Expected CTC", answer: "", askMe: true),
        ]
        data.easyApply = [
            EasyApplyItem(id: 1, jobID: 1, url: "https://www.linkedin.com/jobs/view/1", draftedAnswers: answers, createdAt: C3Fixtures.now),
            EasyApplyItem(id: 2, jobID: 2, url: "https://www.linkedin.com/jobs/view/2", draftedAnswers: answers, opened: true, createdAt: C3Fixtures.now),
            EasyApplyItem(id: 3, jobID: 3, url: "https://www.linkedin.com/jobs/view/3", draftedAnswers: answers, done: true, createdAt: C3Fixtures.now),
        ]
        let (store, daemon, _) = await makeC3Store(data: data)
        let model = EasyApplyModel(store: store)
        let clipboard = RecordingClipboard()
        model.clipboard = clipboard
        let opened = Box<[URL]>([])
        model.openURL = { opened.value.append($0) }
        return (store, daemon, model, clipboard, opened)
    }

    @Test func filters() async {
        let (_, _, model, _, _) = await setup()
        #expect(model.entries(for: .unopened).map(\.id) == [1])
        #expect(model.entries(for: .all).map(\.id) == [1, 2, 3])
        #expect(model.entries(for: .done).map(\.id) == [3])
        #expect(model.toDoCount == 2)
        model.ensureSelection()
        #expect(model.selectedJobID == 1)
    }

    @Test func copyRowsAndCopyAll() async throws {
        let (store, _, model, clipboard, _) = await setup()
        model.ensureSelection()
        let entry = try #require(model.selected)
        #expect(model.copyableAnswers(entry).map(\.question) == ["Phone", "Notice period"])
        #expect(model.askMeAnswers(entry).map(\.question) == ["Expected CTC"])
        model.moveFocusedRow(by: 1)
        model.copyFocused()
        #expect(clipboard.last == "60 days")
        #expect(model.copiedRowID == "Notice period")
        #expect(store.toasts.current?.message == "Copied · Notice period")
        model.moveFocusedRow(by: 5)
        #expect(model.focusedRow == 1)
        model.copyAll()
        #expect(clipboard.last == "Razorpay · Backend SDE\n\nPhone: +91 98765 43210\nNotice period: 60 days")
        #expect(await c3WaitUntil(timeout: .seconds(3)) { model.copiedRowID == nil })
    }

    @Test func openPostingUsesBrowserAndMarksOpened() async throws {
        let (_, daemon, model, _, opened) = await setup()
        model.ensureSelection()
        model.openPosting()
        #expect(opened.value == [URL(string: "https://www.linkedin.com/jobs/view/1")!])
        #expect(await c3WaitUntil { daemon.sent("mark_easy_apply_opened").count == 1 })
        model.select(2)
        model.openPosting()
        try await Task.sleep(for: .milliseconds(50))
        #expect(daemon.sent("mark_easy_apply_opened").count == 1)
    }

    @Test func markAppliedSendsCommandAndAdvances() async throws {
        let (_, daemon, model, _, _) = await setup()
        model.filter = .all
        model.select(1)
        await model.markApplied()
        let cmd = try #require(daemon.sent("mark_easy_apply_done").first)
        guard case .markEasyApplyDone(let p) = cmd else { Issue.record("expected mark done"); return }
        #expect(p.jobId == 1)
        #expect(model.selectedJobID == 2)
        await model.dismiss()
        #expect(daemon.sent("dismiss_easy_apply").count == 1)
    }

    @Test func formattedSkipsAskMeRows() {
        let entry = EasyApplyEntry(item: EasyApplyItem(id: 9, jobID: 9, url: "u", draftedAnswers: [
            DraftedAnswer(question: "A", answer: "1"), DraftedAnswer(question: "B", answer: "", askMe: true),
        ], createdAt: C3Fixtures.now), job: nil)
        #expect(EasyApplyModel.formatted(entry) == "Job #9\n\nA: 1")
    }
}

/// Mutable box for capturing values in @MainActor closures.
@MainActor
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
