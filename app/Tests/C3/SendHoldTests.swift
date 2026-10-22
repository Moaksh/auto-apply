// SendHoldTests.swift — the send hold on Approve (item 1E): hold then send, Undo (row and ⌘Z)
// inside the window, batches, Job detail, quitting / the model going away during a hold (never
// sent, "Not sent — approve again" next launch), plus the confidence lens's "next flagged"
// rule and render checks for the countdown capsule and the flagged Q&A panel.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Send hold", .serialized)
struct SendHoldTests {
    /// Jobs 1, 2, 3 await review (all clean, different companies); job 4 is flagged.
    private func setup(window: Duration = .milliseconds(20)) async -> (AppStore, C3StubDaemon, ReviewModel) {
        var data = RepositoryData()
        data.jobs = [
            C3Fixtures.job(id: 1, company: "Stripe", state: .awaitingReview, score: 91),
            C3Fixtures.job(id: 2, company: "Ramp", state: .awaitingReview, score: 86),
            C3Fixtures.job(id: 3, company: "Notion", state: .awaitingReview, score: 80),
            C3Fixtures.job(id: 4, company: "Figma", state: .awaitingReview, score: 70),
        ]
        data.applicationAnswers = [
            1: [C3Fixtures.answer(id: 11, app: 1, question: "Full name")],
            2: [C3Fixtures.answer(id: 21, app: 2, question: "Full name")],
            3: [C3Fixtures.answer(id: 31, app: 3, question: "Full name")],
            4: [C3Fixtures.answer(id: 41, app: 4, question: "Start date", confidence: 0.4, origin: .generated)],
        ]
        let (store, daemon, _) = await makeC3Store(data: data)
        let model = ReviewModel(store: store)
        model.sendHold.window = window
        model.syncSubscriptions()
        _ = await c3WaitUntil { model.loadedApplicationIDs.count == 4 }
        return (store, daemon, model)
    }

    private func approves(_ daemon: C3StubDaemon) -> [[Int]] {
        daemon.sent("approve").compactMap { if case .approve(let p) = $0 { p.applicationIds } else { nil } }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "SendHoldTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultWindowIsAboutFiveSeconds() {
        #expect(SendHoldTiming.window == .seconds(5))
        let start = Date(timeIntervalSince1970: 1000)
        let deadline = start.addingTimeInterval(5)
        #expect(SendHoldTiming.secondsLeft(until: deadline, now: start) == 5)
        #expect(SendHoldTiming.secondsLeft(until: deadline, now: start.addingTimeInterval(0.2)) == 5)
        #expect(SendHoldTiming.secondsLeft(until: deadline, now: start.addingTimeInterval(4.5)) == 1)
        #expect(SendHoldTiming.secondsLeft(until: deadline, now: start.addingTimeInterval(9)) == 0)
        #expect(SendHoldTiming.fraction(until: deadline, window: 5, now: start) == 1)
        #expect(abs(SendHoldTiming.fraction(until: deadline, window: 5, now: start.addingTimeInterval(2.5)) - 0.5) < 0.0001)
        #expect(SendHoldTiming.fraction(until: deadline, window: 5, now: start.addingTimeInterval(6)) == 0)
    }

    @Test func holdThenSend() async {
        let (store, daemon, model) = await setup(window: .milliseconds(150))
        model.focusedJobID = 1
        model.requestApprove()
        let entry = model.sendHold.entry(for: 1)
        #expect(entry != nil && entry?.isSending == false)
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview, "not even optimistic until it's sent")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(approves(daemon).isEmpty, "still inside the window")
        #expect(await c3WaitUntil { approves(daemon) == [[1]] })
        #expect(await c3WaitUntil { !model.sendHold.hasHolds })
        #expect(store.jobs.job(id: 1)?.state == .submitting)
        #expect(store.toasts.current?.message == "Approved · sending now")
    }

    @Test func undoWithinTheHoldSendsNothing() async {
        let (store, daemon, model) = await setup(window: .milliseconds(200))
        model.focusedJobID = 1
        model.requestApprove()
        #expect(model.focusedJobID != 1)
        model.undoHold(jobID: 1)
        #expect(!model.isHeld(1))
        #expect(model.focusedJobID == 1, "the job put back is focused again")
        #expect(model.sendHold.lastUndo?.jobIDs == [1])
        try? await Task.sleep(for: .milliseconds(350))
        #expect(approves(daemon).isEmpty)
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview)
        // It can be approved again.
        model.requestApprove(only: [1])
        #expect(await c3WaitUntil { approves(daemon) == [[1]] })
    }

    @Test func commandZUndoesTheLatestBatch() async {
        let (_, daemon, model) = await setup(window: .milliseconds(300))
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.approve([1, 2], undoManager: undo)
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Approve 2")
        undo.undo()
        #expect(!model.isHeld(1) && !model.isHeld(2))
        #expect(model.sendHold.lastUndo?.jobIDs == [1, 2])
        try? await Task.sleep(for: .milliseconds(450))
        #expect(approves(daemon).isEmpty)
    }

    @Test func sentBatchLeavesNothingToUndo() async {
        let (_, daemon, model) = await setup()
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.approve([1], undoManager: undo)
        undo.endUndoGrouping()
        #expect(await c3WaitUntil { approves(daemon) == [[1]] })
        #expect(!undo.canUndo, "⌘Z can't pretend to unsend")
    }

    @Test func batchHoldsTogetherAndSendsOneCommand() async {
        let (_, daemon, model) = await setup(window: .milliseconds(150))
        model.toggleSelection(1)
        model.toggleSelection(2)
        model.toggleSelection(3)
        #expect(model.approveTitle == "Approve 3 & send")
        model.requestApprove()
        #expect(model.selection.isEmpty)
        let batches = Set([1, 2, 3].compactMap { model.sendHold.entry(for: $0)?.batch })
        #expect(batches.count == 1, "one countdown for the batch")
        // Undo one row: the other two still go.
        model.undoHold(jobID: 2)
        #expect(await c3WaitUntil { !approves(daemon).isEmpty })
        #expect(approves(daemon).count == 1)
        #expect(Set(approves(daemon)[0]) == [1, 3])
    }

    @Test func batchUndoEveryRowCancelsTheSend() async {
        let (_, daemon, model) = await setup(window: .milliseconds(150))
        model.approve([1, 2])
        model.undoHold(jobID: 1)
        model.undoHold(jobID: 2)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(approves(daemon).isEmpty)
    }

    @Test func lowConfidenceSafeguardStillAsksFirst() async {
        let (_, daemon, model) = await setup()
        model.focusedJobID = 4
        model.requestApprove()
        #expect(model.barMode == .confirmAllFlagged(targets: [4]))
        #expect(!model.isHeld(4), "no hold until the user says yes")
        model.confirmApprove(includeFlagged: true)
        #expect(model.isHeld(4))
        #expect(await c3WaitUntil { approves(daemon) == [[4]] })
    }

    @Test func skippedDuringTheHoldIsNotSent() async {
        let (store, daemon, model) = await setup(window: .milliseconds(150))
        model.approve([1, 2])
        store.jobs.mutate(jobID: 2) { $0.state = .skipped }
        #expect(await c3WaitUntil { !approves(daemon).isEmpty })
        #expect(approves(daemon) == [[1]])
    }

    @Test func fromJobDetailGoesThroughTheSameHold() async {
        let (store, daemon, model) = await setup(window: .milliseconds(200))
        let actions = JobDetailActions()
        let clean = [C3Fixtures.answer(id: 11, app: 1, question: "Full name")]
        await actions.requestApprove(job: store.jobs.job(id: 1)!, answers: clean, answersLoaded: true, store: store)
        #expect(model.isHeld(1), "Review sees the same hold")
        // ⌘↵ again during the hold is ignored.
        await actions.requestApprove(job: store.jobs.job(id: 1)!, answers: clean, answersLoaded: true, store: store)
        actions.undoHold(job: store.jobs.job(id: 1)!, store: store)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(approves(daemon).isEmpty)
        await actions.requestApprove(job: store.jobs.job(id: 1)!, answers: clean, answersLoaded: true, store: store)
        #expect(await c3WaitUntil { approves(daemon) == [[1]] })
    }

    @Test func paletteApproveRoutesToJobDetailAndTheHold() async {
        let (store, daemon, _) = await setup(window: .milliseconds(200))
        store.router.go(.pipeline)
        store.router.openJob(id: 1)
        await store.perform(.approveOpenJob)
        #expect(store.router.jobApproveRequest?.jobID == 1, "⌘K hands off to Job detail, whose approve is held")
        #expect(approves(daemon).isEmpty, "the palette never sends directly")
    }

    @Test func quitDuringTheHoldSendsNothingAndSaysSo() async {
        let (store, daemon, _) = await setup(window: .milliseconds(150))
        let defaults = freshDefaults()
        let hold = SendHoldModel(store: store, defaults: defaults)
        hold.window = .milliseconds(150)
        hold.hold(jobIDs: [1, 2])
        // What the willTerminate observer runs (posting the real notification would also reach
        // other suites' models running in parallel).
        hold.abandonAll()
        #expect(!hold.hasHolds)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(approves(daemon).isEmpty, "a quit never flushes a held approval")
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview)
        #expect(hold.wasNotSent(1) && hold.wasNotSent(2))
        // Next launch: still marked "Not sent — approve again".
        let relaunched = SendHoldModel(store: store, defaults: defaults)
        #expect(relaunched.wasNotSent(1) && relaunched.wasNotSent(2))
        // Approving again clears the mark.
        relaunched.window = .seconds(30)
        relaunched.hold(jobIDs: [1])
        #expect(!relaunched.wasNotSent(1))
        relaunched.abandonAll()
    }

    @Test func crashDuringTheHoldIsReportedAsNotSent() async {
        let (store, daemon, _) = await setup()
        let defaults = freshDefaults()
        let hold = SendHoldModel(store: store, defaults: defaults)
        hold.window = .seconds(30)
        hold.hold(jobIDs: [3])
        // No quit notification: the process just goes away. The next launch reads the held mark.
        let relaunched = SendHoldModel(store: store, defaults: defaults)
        #expect(relaunched.wasNotSent(3))
        #expect(!relaunched.isHeld(3))
        hold.abandonAll()
        #expect(approves(daemon).isEmpty)
    }

    @Test func holdOwnerGoingAwaySendsNothing() async {
        let (store, daemon, _) = await setup()
        weak var released: SendHoldModel?
        do {
            let hold = SendHoldModel(store: store, defaults: nil)
            hold.window = .milliseconds(100)
            hold.hold(jobIDs: [1])
            released = hold
        }
        try? await Task.sleep(for: .milliseconds(250))
        #expect(released == nil)
        #expect(approves(daemon).isEmpty, "a hold whose model is gone (window closed, store torn down) is not sent")
    }

    @Test func sendingEntriesAreNotUndoable() async {
        let (_, daemon, model) = await setup()
        daemon.responder = { cmd in
            if case .approve = cmd { return .ack(AckPayload()) }
            return .ack(AckPayload())
        }
        model.approve([1])
        #expect(await c3WaitUntil { !approves(daemon).isEmpty })
        #expect(!model.sendHold.undo(jobID: 1))
    }

    // MARK: Confidence lens

    @Test func nextFlaggedCyclesInFormOrder() {
        let answers = [
            C3Fixtures.answer(id: 1, app: 1, question: "Name"),
            C3Fixtures.answer(id: 2, app: 1, question: "Start", confidence: 0.4),
            C3Fixtures.answer(id: 3, app: 1, question: "Phone", confidence: 0.95),
            C3Fixtures.answer(id: 4, app: 1, question: "Why us", confidence: 0.7),
        ]
        #expect(ReviewSafeguard.nextFlagged(after: nil, in: answers) == 2)
        #expect(ReviewSafeguard.nextFlagged(after: 2, in: answers) == 4)
        #expect(ReviewSafeguard.nextFlagged(after: 4, in: answers) == 2, "wraps")
        #expect(ReviewSafeguard.nextFlagged(after: 3, in: answers) == 4, "from a clean row: the next one below")
        #expect(ReviewSafeguard.nextFlagged(after: nil, in: [answers[0]]) == nil)
        #expect(ReviewSafeguard.flagLabel(.low) == "Low confidence")
        #expect(ReviewSafeguard.flagLabel(.medium) == "Check this")
        #expect(ReviewSafeguard.flagLabel(.high) == nil && ReviewSafeguard.flagLabel(.notApplicable) == nil)
        #expect(ReviewSafeguard.flagHelp(answers[1])?.contains("wasn't sure") == true)
        #expect(ReviewSafeguard.flagHelp(answers[1])?.contains("40%") == true)
        #expect(ReviewSafeguard.flagHelp(answers[0]) == nil)
    }

    @Test func jumpToNextFlaggedOnlyWhenThereIsOne() async {
        let (_, _, model) = await setup()
        model.focusedJobID = 1
        model.jumpToNextFlagged()
        #expect(model.flaggedJumpSerial == 0)
        model.focusedJobID = 4
        model.jumpToNextFlagged()
        model.jumpToNextFlagged()
        #expect(model.flaggedJumpSerial == 2)
    }

    // MARK: Rendering

    private func render<V: View>(_ store: AppStore, reduced: Bool, width: CGFloat = 900, height: CGFloat = 600,
                                 @ViewBuilder _ view: () -> V) -> CGImage? {
        let content = view()
            .appEnvironment(store, simulateReduceMotion: reduced)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
        let renderer = ImageRenderer(content: content)
        return renderer.cgImage
    }

    @Test func rendersHeldRowsAndFlaggedAnswers() async {
        let (store, _, model) = await setup(window: .seconds(30))
        model.approve([1])
        let entry = model.sendHold.entry(for: 1)!
        for reduced in [false, true] {
            #expect(render(store, reduced: reduced, width: 300, height: 40) { SendHoldCapsule(entry: entry) {} } != nil)
            var sending = entry
            sending.isSending = true
            #expect(render(store, reduced: reduced, width: 300, height: 40) { SendHoldCapsule(entry: sending) {} } != nil)
            #expect(render(store, reduced: reduced, width: 300, height: 40) { NotSentBadge() } != nil)
            #expect(render(store, reduced: reduced, width: 1200, height: 760) { ReviewQueueView() } != nil)
            let flagged = [
                C3Fixtures.answer(id: 41, app: 4, question: "Start date", answer: "2 months", confidence: 0.4, origin: .generated),
                C3Fixtures.answer(id: 42, app: 4, question: "Why Figma?", confidence: 0.7, origin: .memory),
                C3Fixtures.answer(id: 43, app: 4, question: "Full name", confidence: 0.98),
            ]
            #expect(render(store, reduced: reduced, width: 1000, height: 700) {
                ReviewQAPanel(job: store.jobs.job(id: 4)!, answers: flagged, answersLoaded: true, jumpSerial: 1,
                              onEdit: { _, _ in }, onQuickLook: { _ in })
            } != nil)
            #expect(render(store, reduced: reduced, width: 1200, height: 900) { JobDetailView(jobID: 1) } != nil)
        }
        model.sendHold.abandonAll()
    }
}
