// ReviewTicketTests.swift — Review's ticket (Approve style ▸ Ticket): tearing the stub past the
// commit point is exactly Approve (the send hold, nothing sent inside its window), short of it
// nothing happens, a ticket held for your answer refuses, Undo re-attaches the stub, focus moves on
// within the response budget, the printed facts come from real fields, Classic still draws the old
// UI, and the ticket renders in light and dark (intact, held for an answer, torn).
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Review ticket", .serialized)
struct ReviewTicketTests {
    /// Jobs 1, 2, 3 await review (clean, different companies); job 4 has a low-confidence answer.
    private func setup(window: Duration = .milliseconds(300), shared: Bool = false) async -> (AppStore, C3StubDaemon, ReviewModel) {
        var data = RepositoryData()
        data.jobs = [
            C3Fixtures.job(id: 1, company: "Stripe", state: .awaitingReview, score: 91),
            C3Fixtures.job(id: 2, company: "Ramp", state: .awaitingReview, score: 86),
            C3Fixtures.job(id: 3, company: "Notion", state: .awaitingReview, score: 80),
            C3Fixtures.job(id: 4, company: "Figma", state: .awaitingReview, score: 70),
        ]
        data.jobs[0].coverLetterPath = "/tmp/letter.md"
        data.jobs[0].postedAt = C3Fixtures.now.addingTimeInterval(-2 * 86_400)
        data.applicationAnswers = [
            1: [C3Fixtures.answer(id: 11, app: 1, question: "Full name"), C3Fixtures.answer(id: 12, app: 1, question: "Email"),
                C3Fixtures.answer(id: 13, app: 1, question: "Why Stripe?", confidence: 0.9, origin: .memory)],
            2: [C3Fixtures.answer(id: 21, app: 2, question: "Full name")],
            3: [C3Fixtures.answer(id: 31, app: 3, question: "Full name")],
            4: [C3Fixtures.answer(id: 41, app: 4, question: "Start date", confidence: 0.4, origin: .generated)],
        ]
        let (store, daemon, _) = await makeC3Store(data: data)
        let model = shared ? ReviewModel.shared(for: store) : ReviewModel(store: store)
        model.sendHold.window = window
        model.syncSubscriptions()
        _ = await c3WaitUntil { model.loadedApplicationIDs.count == 4 }
        return (store, daemon, model)
    }

    private func approves(_ daemon: C3StubDaemon) -> [[Int]] {
        daemon.sent("approve").compactMap { if case .approve(let p) = $0 { p.applicationIds } else { nil } }
    }

    // MARK: Tear = consent

    @Test func tearPastTheCommitPointHoldsAndSendsNothingInsideTheWindow() async {
        // A window well past the advance beat, so the beat always fires while the job is held.
        let (store, daemon, model) = await setup(window: .seconds(2))
        model.focusedJobID = 1
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(model.releaseStub(jobID: 1, translation: Motion.Budget.tearCommit + 12, undoManager: undo) == .torn)
        undo.endUndoGrouping()
        // Exactly the send hold: held, undoable, nothing sent, not even optimistic.
        let entry = model.sendHold.entry(for: 1)
        #expect(entry != nil && entry?.isSending == false)
        #expect(undo.canUndo && undo.undoActionName == "Approve")
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview)
        #expect(approves(daemon).isEmpty, "nothing is sent at the tear")
        // The stamp lands first: focus stays a beat, then the next ticket is live. The beat sits inside
        // the response budget by design; wall-clock timing isn't asserted, since a parallel test run
        // can starve the main actor for longer than the beat.
        #expect(Motion.Budget.tearAdvance < Motion.Budget.response)
        #expect(model.focusedJobID == 1)
        #expect(await c3WaitUntil(timeout: .seconds(10)) { model.focusedJobID != 1 })
        #expect(model.focusedJobID == 4 || model.focusedJobID == 2, "the next unheld job in queue order")
        // A second tear of the same job never holds (or sends) it twice.
        #expect(model.tear(jobID: 1) == .ignored)
        #expect(await c3WaitUntil { approves(daemon) == [[1]] })
        #expect(await c3WaitUntil { !model.sendHold.hasHolds })
    }

    @Test func aClickOrKeyTearsTheSameWay() async {
        let (_, daemon, model) = await setup(window: .milliseconds(200))
        model.focusedJobID = 2
        #expect(model.tear(jobID: 2) == .torn)
        #expect(model.isHeld(2))
        #expect(approves(daemon).isEmpty)
        #expect(await c3WaitUntil { approves(daemon) == [[2]] })
    }

    @Test func tearShortOfTheCommitPointDoesNothing() async {
        let (store, daemon, model) = await setup(window: .milliseconds(100))
        model.focusedJobID = 1
        #expect(model.releaseStub(jobID: 1, translation: Motion.Budget.tearCommit - 1) == .springBack)
        #expect(model.releaseStub(jobID: 1, translation: 12) == .springBack)
        #expect(model.releaseStub(jobID: 1, translation: -40) == .springBack)
        #expect(!model.sendHold.hasHolds)
        #expect(model.focusedJobID == 1)
        #expect(model.tearRefusals == 0, "a clean ticket springs back without a shake")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(approves(daemon).isEmpty)
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview)
    }

    @Test func aTicketHeldForYourAnswerRefusesToTear() async {
        let (_, daemon, model) = await setup(window: .milliseconds(100))
        model.focusedJobID = 4
        #expect(model.needsLook(store(model).jobs.job(id: 4)!))
        #expect(model.releaseStub(jobID: 4, translation: 200) == .refused)
        #expect(model.releaseStub(jobID: 4, translation: 20) == .refused, "it gives a little, then won't")
        #expect(model.tear(jobID: 4) == .refused)
        #expect(!model.isHeld(4))
        #expect(model.tearRefusals == 3, "the ticket shakes each time")
        #expect(model.flaggedJumpSerial == 3, "and spotlights the answer to release it")
        #expect(model.barMode == .actions, "the stub never opens the override; A does")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(approves(daemon).isEmpty)
        // Answering (editing) the flagged one releases it.
        let flagged = model.flaggedAnswers(for: store(model).jobs.job(id: 4)!)
        await model.editAnswer(flagged[0], to: "Two weeks")
        #expect(model.tear(jobID: 4) == .torn)
        model.sendHold.abandonAll()
    }

    @Test func undoReattachesTheStubAndSendsNothing() async {
        let (store, daemon, model) = await setup(window: .milliseconds(300))
        model.focusedJobID = 1
        #expect(model.tear(jobID: 1) == .torn)
        model.undoHold(jobID: 1)
        #expect(!model.isHeld(1))
        #expect(model.focusedJobID == 1)
        #expect(model.reattachJobID == 1, "the ticket plays the tear backwards")
        #expect(model.takeReattach(1))
        #expect(!model.takeReattach(1), "once")
        // The delayed advance doesn't pull focus off the job put back.
        try? await Task.sleep(for: .milliseconds(450))
        #expect(model.focusedJobID == 1)
        #expect(approves(daemon).isEmpty)
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview)
    }

    // MARK: Facts

    @Test func printedFactsComeFromRealFields() async {
        let (store, _, model) = await setup()
        let job = store.jobs.job(id: 1)!
        let fields = TicketFacts.fields(job: job, answers: model.answers(for: job), answersLoaded: true, threshold: 70)
        #expect(fields.map(\.label) == ["Match", "Posted", "Site", "Enclosed"])
        #expect(fields[0].value == "91")
        #expect(fields[2].value == "Greenhouse")
        #expect(fields[3].value == "Letter + 3 answers")
        // Missing fields are left off; answers not loaded yet print nothing enclosed.
        let bare = store.jobs.job(id: 2)!
        #expect(TicketFacts.fields(job: bare, answers: [], answersLoaded: false, threshold: 70).map(\.label) == ["Match", "Site"])
        #expect(TicketFacts.enclosed(job: bare, answers: model.answers(for: bare)) == "1 answer")
        #expect(TicketFacts.rowFields(job: job, threshold: 70).map(\.label) == ["Match", "Site"])
        var other = bare
        other.ats = .other
        other.score = nil
        #expect(TicketFacts.rowFields(job: other, threshold: 70).isEmpty)
    }

    // MARK: Rendering

    private func render<V: View>(_ store: AppStore, reduced: Bool = true, scheme: ColorScheme = .light, style: ApproveStyle? = nil,
                                 probe: ReviewRenderProbe? = nil, audit: ProminenceAudit? = nil,
                                 width: CGFloat = 1200, height: CGFloat = 760, @ViewBuilder _ view: () -> V) -> CGImage? {
        let content = view()
            .appEnvironment(store, simulateReduceMotion: reduced)
            .environment(\.colorScheme, scheme)
            .environment(\.approveStyleOverride, style)
            .environment(\.reviewRenderProbe, probe)
            .environment(\.prominenceAudit, audit)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
        return ImageRenderer(content: content).cgImage
    }

    @Test func classicStyleDrawsTheOldUI() async {
        let (store, _, model) = await setup(shared: true)
        model.focusedJobID = 1
        let classic = ReviewRenderProbe()
        let classicAudit = ProminenceAudit()
        #expect(render(store, style: .classic, probe: classic, audit: classicAudit) { ReviewQueueView() } != nil)
        #expect(classic.classicActions > 0 && classic.tickets == 0, "Classic: the Approve & send button, no ticket")
        #expect(classicAudit.count == 1, "Classic's Approve & send pill is the one primary")
        let ticket = ReviewRenderProbe()
        let ticketAudit = ProminenceAudit()
        #expect(render(store, style: .ticket, probe: ticket, audit: ticketAudit) { ReviewQueueView() } != nil)
        #expect(ticket.tickets > 0 && ticket.classicActions == 0, "Ticket: the ticket, no button")
        #expect(ticketAudit.count == 1, "the stub is the one primary")
        // Held for an answer: the stub isn't a primary (nothing to tear yet).
        model.focusedJobID = 4
        let heldAudit = ProminenceAudit()
        _ = render(store, style: .ticket, audit: heldAudit) { ReviewQueueView() }
        #expect(heldAudit.count == 0)
        // Torn (on the hold): its countdown replaces the stub; still at most one primary on screen.
        model.focusedJobID = 1
        #expect(model.tear(jobID: 1) == .torn)
        let tornAudit = ProminenceAudit()
        _ = render(store, style: .ticket, audit: tornAudit) { ReviewQueueView() }
        #expect(tornAudit.count <= 1)
        model.sendHold.abandonAll()
    }

    @Test func ticketRendersInLightAndDark() async {
        let (store, _, model) = await setup(window: .seconds(30), shared: true)
        for scheme in [ColorScheme.light, .dark] {
            for reduced in [false, true] {
                for id in [1, 4] {
                    #expect(render(store, reduced: reduced, scheme: scheme, width: 720, height: 160) {
                        ReviewTicket(model: model, job: store.jobs.job(id: id)!).padding()
                    } != nil, "ticket \(id) \(scheme) reduced: \(reduced)")
                }
                #expect(render(store, reduced: reduced, scheme: scheme, width: 320, height: 60) {
                    ReviewRowFacts(job: store.jobs.job(id: 1)!, threshold: 70)
                } != nil)
            }
        }
        #expect(model.tear(jobID: 1) == .torn)
        let entry = model.sendHold.entry(for: 1)!
        for scheme in [ColorScheme.light, .dark] {
            #expect(render(store, scheme: scheme, width: 720, height: 160) {
                ReviewTicket(model: model, job: store.jobs.job(id: 1)!).padding()
            } != nil)
            #expect(render(store, scheme: scheme, width: 200, height: 40) { SendHoldStubCountdown(entry: entry, compact: true) {} } != nil)
            #expect(render(store, scheme: scheme, style: .ticket, width: 1200, height: 760) { ReviewQueueView() } != nil)
        }
        model.sendHold.abandonAll()
    }

    @Test func ticketShapeHasDieCutNotches() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let body = TicketPart(side: .body).path(in: rect)
        let stub = TicketPart(side: .stub).path(in: rect)
        // The notch centres (on the perforation edge) are cut away; the middles are paper.
        #expect(!body.contains(CGPoint(x: 198, y: 2)) && !body.contains(CGPoint(x: 198, y: 98)))
        #expect(body.contains(CGPoint(x: 100, y: 50)) && body.contains(CGPoint(x: 198, y: 50)))
        #expect(!stub.contains(CGPoint(x: 2, y: 2)) && !stub.contains(CGPoint(x: 2, y: 98)))
        #expect(stub.contains(CGPoint(x: 2, y: 50)))
    }

    private func store(_ model: ReviewModel) -> AppStore { model.store }
}
