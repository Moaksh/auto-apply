// BoardTests.swift — Pipeline rules (columns, filters, legal drops, keyboard moves, nudges,
// skip groups) and BoardModel behavior against a stub daemon (set_status, undo, rollback,
// celebrations, ghosting toast).
import Foundation
import Testing
@testable import AutoApply

@Suite("C2 · Board rules")
struct BoardRulesTests {
    @Test func visibleColumnsDefaultSkippedAndExplicit() {
        #expect(BoardRules.visibleColumns(filter: PipelineFilter()) == BoardColumn.defaultVisible)
        let skipped = BoardRules.visibleColumns(filter: PipelineFilter(showSkipped: true))
        #expect(skipped.prefix(2) == [.discovered, .skipped])
        #expect(skipped.count == BoardColumn.defaultVisible.count + 2)
        #expect(BoardRules.visibleColumns(filter: PipelineFilter(columns: [.interview, .applied])) == [.applied, .interview],
                "explicit columns keep board order")
    }

    @Test func filtersBySourceScoreStatusReasonAndText() {
        let jobs = [
            C2.job(id: 1, company: "Stripe", title: "Backend Engineer", state: .submitted, status: .interview, score: 91, source: .greenhouse),
            C2.job(id: 2, company: "Ramp", title: "Platform Engineer", state: .queued, score: 72, source: .ashby, ats: .ashby),
            C2.job(id: 3, company: "Acme", title: "SRE", state: .skipped, score: 60, skipReason: "excluded_keyword:crypto"),
        ]
        func ids(_ f: PipelineFilter) -> [Int] { BoardRules.filtered(jobs, filter: f).map(\.id) }
        #expect(ids(PipelineFilter()) == [1, 2, 3])
        #expect(ids(PipelineFilter(source: .ashby)) == [2])
        #expect(ids(PipelineFilter(minScore: 70)) == [1, 2])
        #expect(ids(PipelineFilter(status: .interview)) == [1])
        #expect(ids(PipelineFilter(skipReason: "excluded_keyword")) == [3])
        #expect(ids(PipelineFilter(searchText: "stripe back")) == [1])
        #expect(ids(PipelineFilter(searchText: "ashby")) == [2], "matches ATS label too")
        #expect(ids(PipelineFilter(searchText: "nope")) == [])
    }

    @Test func dropRulesByState() {
        let applied = C2.job(id: 1, state: .submitted, status: nil)
        let queued = C2.job(id: 2, state: .queued)
        let needsYou = C2.job(id: 3, state: .needsYou)
        let filling = C2.job(id: 4, state: .filling)
        var skipped = C2.job(id: 5, state: .skipped)
        skipped.applyURL = "https://boards.greenhouse.io/stripe/jobs/1"
        var easy = C2.job(id: 6, state: .scored)
        easy.easyApply = true
        // submitted: moves between post-apply statuses only
        #expect(BoardRules.isDraggable(applied))
        #expect(BoardRules.canDrop(applied, on: .interview))
        #expect(!BoardRules.canDrop(applied, on: .applied), "nil status counts as Applied")
        #expect(!BoardRules.canDrop(applied, on: .queued) && !BoardRules.canDrop(applied, on: .needsYou))
        #expect(BoardRules.legalTargets(for: applied) == [.assessment, .interview, .offer, .rejected, .ghosted])
        // not applied yet: Queued = the agent applies (needs a company form); Applied and later = applied by you
        #expect(BoardRules.dropAction(skipped, on: .queued) == .queue)
        #expect(BoardRules.dropAction(skipped, on: .ghosted) == .markApplied(.ghosted))
        #expect(BoardRules.dropAction(easy, on: .queued) == nil, "Easy Apply has no form for the agent")
        #expect(BoardRules.dropAction(easy, on: .applied) == .markApplied(.applied))
        #expect(BoardRules.dropAction(queued, on: .interview) == .markApplied(.interview))
        #expect(BoardRules.dropAction(needsYou, on: .applied) == .markApplied(.applied))
        #expect(!BoardRules.canDrop(queued, on: .queued) && !BoardRules.canDrop(needsYou, on: .queued))
        // the agent is working on it: hands off
        #expect(!BoardRules.isDraggable(filling))
        #expect(BoardRules.legalTargets(for: queued).isEmpty)
    }

    @Test func keyboardMovesWalkStatusOrder() {
        let applied = C2.job(id: 1, state: .submitted, status: .applied)
        #expect(BoardRules.keyboardTarget(for: applied, delta: 1) == .assessment)
        #expect(BoardRules.keyboardTarget(for: applied, delta: -1) == nil)
        let ghosted = C2.job(id: 2, state: .submitted, status: .ghosted)
        #expect(BoardRules.keyboardTarget(for: ghosted, delta: 1) == nil)
        #expect(BoardRules.keyboardTarget(for: ghosted, delta: -1) == .rejected)
        #expect(BoardRules.keyboardTarget(for: C2.job(id: 3, state: .queued), delta: 1) == nil)
    }

    @Test func nudgeFromFirstNudgeDayUntilGhosting() {
        let cal = C2.utc
        func applied(daysAgo: Double, status: BoardStatus = .applied) -> JobItem {
            C2.job(id: 1, state: .submitted, status: status, submittedAt: Samples.now.addingTimeInterval(-daysAgo * 86_400))
        }
        #expect(BoardRules.nudge(for: applied(daysAgo: 3), now: Samples.now, nudgeDays: [7, 14], ghostAfterDays: 21, calendar: cal) == nil)
        #expect(BoardRules.nudge(for: applied(daysAgo: 7.2), now: Samples.now, nudgeDays: [7, 14], ghostAfterDays: 21, calendar: cal) == .heardBack(days: 7))
        #expect(BoardRules.nudge(for: applied(daysAgo: 15), now: Samples.now, nudgeDays: [7, 14], ghostAfterDays: 21, calendar: cal) == .heardBack(days: 15))
        #expect(BoardRules.nudge(for: applied(daysAgo: 22), now: Samples.now, nudgeDays: [7, 14], ghostAfterDays: 21, calendar: cal) == nil)
        #expect(BoardRules.nudge(for: applied(daysAgo: 9, status: .interview), now: Samples.now, nudgeDays: [7, 14], ghostAfterDays: 21, calendar: cal) == nil)
    }

    @Test func ageText() {
        let now = Samples.now
        #expect(BoardRules.ageText(since: now.addingTimeInterval(-30), now: now) == "1m")
        #expect(BoardRules.ageText(since: now.addingTimeInterval(-5 * 3_600), now: now) == "5h")
        #expect(BoardRules.ageText(since: now.addingTimeInterval(-3 * 86_400), now: now) == "3d")
        #expect(BoardRules.ageText(since: now.addingTimeInterval(-42 * 86_400), now: now) == "6w")
    }

    @Test func skipReasonGroupsAndLabels() {
        let jobs = [
            C2.job(id: 1, state: .skipped, skipReason: "below_threshold"), C2.job(id: 2, state: .skipped, skipReason: "below_threshold"),
            C2.job(id: 3, state: .skipped, skipReason: "excluded_keyword:crypto"), C2.job(id: 4, state: .skipped, skipReason: "excluded_keyword:gambling"),
            C2.job(id: 5, state: .skipped, skipReason: "below_threshold"), C2.job(id: 6, state: .skipped, skipReason: "company_cooldown"),
            C2.job(id: 7, state: .queued),
        ]
        let groups = BoardRules.skipReasonGroups(jobs)
        #expect(groups.map(\.label) == ["Below threshold", "Excluded keyword", "Company cooldown"])
        #expect(groups.map(\.count) == [3, 2, 1])
        #expect(BoardRules.skipReasonKey("excluded_keyword:crypto") == "excluded_keyword")
        #expect(BoardRules.skipReasonLabel("weird_new_reason") == "Weird New Reason")
        #expect(BoardRules.skipReasonLabel(nil) == "Other")
    }

    @Test func keyboardSelectionMovesWithinAndAcrossColumns() {
        let a1 = C2.job(id: 1), a2 = C2.job(id: 2), b1 = C2.job(id: 3)
        let jobs: [BoardColumn: [JobItem]] = [.queued: [a1, a2], .needsYou: [], .applied: [b1]]
        let cols: [BoardColumn] = [.queued, .needsYou, .applied]
        #expect(BoardRules.moveSelection(from: nil, columns: cols, jobs: jobs, dx: 0, dy: 1) == 1, "first card when nothing selected")
        #expect(BoardRules.moveSelection(from: 1, columns: cols, jobs: jobs, dx: 0, dy: 1) == 2)
        #expect(BoardRules.moveSelection(from: 2, columns: cols, jobs: jobs, dx: 0, dy: 1) == 2, "clamped at the bottom")
        #expect(BoardRules.moveSelection(from: 2, columns: cols, jobs: jobs, dx: 1, dy: 0) == 3, "skips empty columns, clamps row")
        #expect(BoardRules.moveSelection(from: 3, columns: cols, jobs: jobs, dx: -1, dy: 0) == 1)
        #expect(BoardRules.moveSelection(from: 1, columns: cols, jobs: [:], dx: 1, dy: 0) == nil)
    }

    @Test func questionCountsAndGhosting() {
        let clusters = [Samples.cluster("a", jobs: [1, 2]), Samples.cluster("b", jobs: [2, 2])]
        #expect(BoardRules.questionCounts(clusters) == [1: 1, 2: 2])
        var g = C2.job(id: 1, state: .submitted, status: .ghosted)
        g.statusUpdatedAt = Samples.now
        var old = C2.job(id: 2, state: .submitted, status: .ghosted)
        old.statusUpdatedAt = Samples.now.addingTimeInterval(-10 * 86_400)
        #expect(BoardRules.newlyGhosted([g, old], since: Samples.now.addingTimeInterval(-3_600)).map(\.id) == [1])
    }

    @Test func dragPayloadRoundTrips() {
        #expect(BoardModel.jobID(fromPayload: BoardModel.payload(for: 42)) == 42)
        #expect(BoardModel.jobID(fromPayload: "job:42") == nil)
        #expect(BoardModel.jobID(fromPayload: "autoapply-job:x") == nil)
        #expect(BoardColumn(status: .offer) == .offer)
    }

    @Test func tableRowFlattensForSorting() {
        var j = C2.job(id: 1, state: .submitted, status: .interview, score: 91, submittedAt: Samples.now)
        j.resumeVariantID = 2
        let row = PipelineTableRow(job: j, resumeLabels: [2: "ML"])
        #expect(row.status == "Interview")
        #expect(row.resume == "ML")
        #expect(row.score == 91)
        let skipped = PipelineTableRow(job: C2.job(id: 2, state: .skipped, skipReason: "salary_floor"), resumeLabels: [:])
        #expect(skipped.reason == "Salary floor")
        #expect(skipped.score == -1)
        #expect(skipped.applied == .distantPast)
        #expect(row.statusOrder > skipped.statusOrder, "post-apply statuses sort after pipeline states")
    }
}

@MainActor
@Suite("C2 · Board model", .serialized)
struct BoardModelTests {
    func makeModel(jobs: [JobItem], daemon: StubDaemon = StubDaemon()) -> (BoardModel, AppStore, StubDaemon) {
        let (store, daemon) = C2.store(jobs: jobs, daemon: daemon)
        let model = BoardModel(store: store)
        model.defaults = C2.isolatedDefaults()
        return (model, store, daemon)
    }

    @Test func moveSendsSetStatusAndOffersUndo() async {
        let (model, store, daemon) = makeModel(jobs: [C2.job(id: 1, state: .submitted, status: nil)])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(await model.move(jobID: 1, to: .interview, undoManager: undo))
        undo.endUndoGrouping()
        #expect(C2.sentStatuses(daemon) == [.interview])
        #expect(store.jobs.job(id: 1)?.status == .interview)
        #expect(store.toasts.current?.message == "Moved to Interview")
        #expect(store.toasts.current?.actionTitle == "Undo")
        #expect(undo.canUndo)

        // Undo from the toast moves it back to Applied (even though status was nil before).
        store.toasts.performAction()
        #expect(await waitUntil { C2.sentStatuses(daemon) == [.interview, .applied] })
        #expect(await waitUntil { store.jobs.job(id: 1)?.status == .applied })
    }

    @Test func undoManagerRevertsMove() async {
        let (model, store, daemon) = makeModel(jobs: [C2.job(id: 1, state: .submitted, status: .applied)])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(await model.move(jobID: 1, to: .rejected, undoManager: undo))
        undo.endUndoGrouping()
        undo.undo()
        #expect(await waitUntil { C2.sentStatuses(daemon) == [.rejected, .applied] })
        #expect(await waitUntil { store.jobs.job(id: 1)?.status == .applied })
    }

    @Test func undoSurvivesTheModelThatMoved() async {
        // Job detail / inspector move through short-lived models; ⌘Z and the toast's Undo must
        // still work (and not crash) after that model is gone.
        let (store, daemon) = C2.store(jobs: [C2.job(id: 1, state: .submitted, status: .applied)])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(await BoardModel(store: store).move(jobID: 1, to: .interview, undoManager: undo))
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        undo.undo()
        #expect(await waitUntil { C2.sentStatuses(daemon) == [.interview, .applied] })
        #expect(await waitUntil { store.jobs.job(id: 1)?.status == .applied })
    }

    @Test func toastUndoSurvivesTheModelThatMoved() async {
        let (store, daemon) = C2.store(jobs: [C2.job(id: 1, state: .submitted, status: .applied)])
        #expect(await BoardModel(store: store).move(jobID: 1, to: .offer))
        store.toasts.performAction()
        #expect(await waitUntil { C2.sentStatuses(daemon) == [.offer, .applied] })
    }

    @Test func illegalMovesNeverReachTheDaemon() async {
        let (model, _, daemon) = makeModel(jobs: [C2.job(id: 1, state: .filling), C2.job(id: 2, state: .submitted, status: .offer),
                                                   C2.job(id: 3, state: .queued)])
        #expect(await model.move(jobID: 1, to: .interview) == false)
        #expect(await model.move(jobID: 3, to: .interview) == false, "not applied yet: that's \"applied by you\", not a status move")
        #expect(await model.move(jobID: 2, to: .offer) == false, "same column")
        #expect(await model.move(jobID: 99, to: .offer) == false)
        #expect(model.performDrop(payload: BoardModel.payload(for: 1), on: .applied, undoManager: nil) == false, "the agent is filling it")
        #expect(model.performDrop(payload: "garbage", on: .interview, undoManager: nil) == false)
        #expect(daemon.sent.isEmpty)
    }

    @Test func daemonErrorRollsBackWithoutUndoToast() async {
        let daemon = StubDaemon()
        daemon.responder = { _ in .error(ErrorPayload(code: .illegalTransition, message: "not submitted")) }
        let (model, store, _) = makeModel(jobs: [C2.job(id: 1, state: .submitted, status: .applied)], daemon: daemon)
        #expect(await model.move(jobID: 1, to: .interview) == false)
        #expect(store.jobs.job(id: 1)?.status == .applied)
        #expect(store.toasts.current?.actionTitle == nil, "error toast, not undo")
    }

    @Test func dragStateAndLegalTargets() async {
        let (model, store, daemon) = makeModel(jobs: [C2.job(id: 1, state: .submitted, status: .applied)])
        model.beginDrag(jobID: 1)
        #expect(store.router.focusedJobID == 1)
        #expect(model.isLegalTarget(.interview))
        #expect(!model.isLegalTarget(.applied))
        #expect(!model.isLegalTarget(.queued))
        #expect(model.performDrop(payload: BoardModel.payload(for: 1), on: .assessment, undoManager: nil))
        #expect(model.draggingJobID == nil)
        #expect(await waitUntil { C2.sentStatuses(daemon) == [.assessment] })
    }

    @Test func keyboardMoveUsesFocusedJob() async {
        let (model, store, daemon) = makeModel(jobs: [C2.job(id: 1, state: .submitted, status: .assessment)])
        store.router.selection = .pipeline
        store.router.focusedJobID = 1
        #expect(await model.moveFocused(by: 1))
        #expect(await model.moveFocused(by: -1))
        #expect(C2.sentStatuses(daemon) == [.interview, .assessment])
    }

    @Test func firstInterviewCelebratesOnceEver() async {
        let (model, _, _) = makeModel(jobs: [C2.job(id: 1, state: .submitted, status: .applied), C2.job(id: 2, state: .submitted, status: .applied)])
        #expect(await model.move(jobID: 1, to: .interview))
        #expect(model.celebratedJobID == 1)
        #expect(model.firstInterviewNoteJobID == 1)
        #expect(await model.move(jobID: 2, to: .interview))
        #expect(model.celebratedJobID == 2)
        #expect(model.firstInterviewNoteJobID == 1, "the note doesn't move to the second interview")
        #expect(model.celebrationSerial == 2)
        let before = model.celebrationSerial
        #expect(await model.move(jobID: 2, to: .rejected))
        #expect(model.celebrationSerial == before, "rejections aren't celebrated")
    }

    @Test func ghostedSinceLastVisitToast() {
        var ghost = C2.job(id: 1, state: .submitted, status: .ghosted)
        ghost.statusUpdatedAt = Samples.now
        let (model, store, _) = makeModel(jobs: [ghost])
        model.announceGhostedSinceLastVisit(now: Samples.now.addingTimeInterval(-86_400))
        #expect(store.toasts.current == nil, "first visit only stamps")
        model.announceGhostedSinceLastVisit(now: Samples.now.addingTimeInterval(60))
        #expect(store.toasts.current?.message == "Closed 1 · no reply in 21 days")
    }
}

@MainActor
@Suite("Board · queue & applied by you")
struct BoardQueueAndManualTests {
    @Test func dropOnQueuedHandsTheJobToTheAgent() async {
        var job = C2.job(id: 7, state: .skipped)
        job.applyURL = "https://boards.greenhouse.io/stripe/jobs/7"
        let (store, daemon) = C2.store(jobs: [job])
        let model = BoardModel(store: store)
        model.beginDrag(jobID: 7)
        #expect(model.performDrop(payload: BoardModel.payload(for: 7), on: .queued, undoManager: nil))
        #expect(await waitUntil { daemon.sent.contains { if case .queueApplication(let p) = $0 { p.applicationId == 7 && p.applyNow } else { false } } })
        #expect(store.jobs.job(id: 7)?.state == .queued)
    }

    @Test func applyingYourselfAsksFirst() async {
        let (store, daemon) = C2.store(jobs: [C2.job(id: 8, state: .queued)])
        let model = BoardModel(store: store)
        model.beginDrag(jobID: 8)
        #expect(model.performDrop(payload: BoardModel.payload(for: 8), on: .interview, undoManager: nil))
        #expect(model.pendingManualApply == BoardModel.ManualApply(jobID: 8, status: .interview))
        #expect(daemon.sent.isEmpty, "nothing is sent before the OK")
        #expect(await model.confirmManualApply())
        #expect(daemon.sent.contains { if case .markApplied(let p) = $0 { p.applicationId == 8 && p.status == .interview } else { false } })
        #expect(store.jobs.job(id: 8)?.state == .submitted && store.jobs.job(id: 8)?.status == .interview)
        #expect(model.pendingManualApply == nil)
    }
}

@MainActor
@Suite("Apply queued only")
struct ApplyQueuedTests {
    @Test func applyQueuedRunsOnlyTheApplyStep() async {
        let (store, daemon) = C2.store(jobs: [C2.job(id: 1, state: .queued), C2.job(id: 2, state: .queued),
                                              C2.job(id: 3, state: .filling), C2.job(id: 4, state: .needsYou)])
        #expect(store.queuedCount == 2)
        await store.perform(.applyQueued)
        #expect(daemon.sent.contains { if case .runNow(let p) = $0 { p.kind == .apply } else { false } })
        #expect(AppAction.paletteActions.contains(.applyQueued))
    }
}
