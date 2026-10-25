// ReviewSendBlockTests.swift — issue #4: Review knows when the agent can't send a job yet (the
// per-company rule) and says so before any send hold runs: the pre-check (`ReviewSendability`),
// the copy, the queue / tear / approve behaviour, "Keep for <date>", resolving an unconfirmed
// attempt, the agent's `held` reply and precise refusal toast, rendering of each state in light
// and dark with at most one primary, and the sample data reproducing both refusals.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Review can't-send-yet", .serialized)
struct ReviewSendBlockTests {
    private static let day: TimeInterval = 86_400

    /// 1: Prodigal, we applied (job 2) 12 days ago. 3: Acme, job 4 unconfirmed 2 days ago.
    /// 5 and 6: both at Ramp, both waiting. 7: Notion, free.
    private func data() -> RepositoryData {
        let now = Date()
        var data = RepositoryData()
        var cooled = C3Fixtures.job(id: 1, company: "Prodigal", title: "Machine Learning Engineer", state: .awaitingReview, score: 90)
        var sent = C3Fixtures.job(id: 2, company: "Prodigal", title: "Data Scientist", state: .submitted)
        sent.submittedAt = now.addingTimeInterval(-12 * Self.day)
        cooled.companyLastAppliedAt = sent.submittedAt
        sent.companyLastAppliedAt = sent.submittedAt
        let waiting = C3Fixtures.job(id: 3, company: "Acme", title: "Platform Engineer", state: .awaitingReview, score: 88)
        var unsure = C3Fixtures.job(id: 4, company: "Acme", title: "SRE", state: .unknownVerify)
        unsure.stateUpdatedAt = now.addingTimeInterval(-2 * Self.day)
        data.jobs = [cooled, sent, waiting, unsure,
                     C3Fixtures.job(id: 5, company: "Ramp", state: .awaitingReview, score: 95),
                     C3Fixtures.job(id: 6, company: "Ramp", title: "Infra Engineer", state: .awaitingReview, score: 70),
                     C3Fixtures.job(id: 7, company: "Notion", state: .awaitingReview, score: 60)]
        for id in [1, 3, 5, 6, 7] { data.applicationAnswers[id] = [C3Fixtures.answer(id: id * 10, app: id, question: "Full name")] }
        return data
    }

    private func setup() async -> (AppStore, C3StubDaemon, ReviewModel) {
        let (store, daemon, _) = await makeC3Store(data: data())
        let model = ReviewModel.shared(for: store)
        model.sendHold.window = .milliseconds(20)
        model.syncSubscriptions()
        _ = await c3WaitUntil { model.loadedApplicationIDs.count == 5 }
        return (store, daemon, model)
    }

    private func approves(_ daemon: C3StubDaemon) -> [[Int]] {
        daemon.sent("approve").compactMap { if case .approve(let p) = $0 { p.applicationIds } else { nil } }
    }

    // MARK: Pre-check

    @Test func precheckFindsEachKind() {
        let jobs = data().jobs
        let now = Date()
        func block(_ id: Int, held: Set<Int> = [], days: Int = 30) -> SendBlock? {
            ReviewSendability.block(for: jobs.first { $0.id == id }!, in: jobs, cooldownDays: days, heldJobIDs: held, now: now)
        }
        let cooldown = block(1)
        #expect(cooldown?.kind == .cooldown && cooldown?.blocksSend == true)
        #expect(cooldown?.otherJobID == 2 && cooldown?.company == "Prodigal")
        let resets = jobs[1].submittedAt!.addingTimeInterval(30 * Self.day)
        #expect(abs((cooldown?.resetsAt ?? .distantPast).timeIntervalSince(resets)) < 1)
        let unsure = block(3)
        #expect(unsure?.kind == .unconfirmedAttempt(inFlight: false) && unsure?.needsResolution == true && unsure?.otherApplicationID == 4)
        let peer = block(5)
        #expect(peer?.kind == .sameCompanyInReview && peer?.blocksSend == false && peer?.otherJobID == 6)
        // The other Ramp job on the send hold: as good as sent, so this one waits.
        #expect(block(6, held: [5])?.kind == .unconfirmedAttempt(inFlight: true))
        #expect(block(7) == nil)
        #expect(block(1, days: 0) == nil, "0 days turns the rule off")
        #expect(block(1, days: 10) == nil, "12 days ago is outside a 10-day window")
    }

    @Test func copyIsFirstPersonAndSaysWhatHappensNext() {
        let jobs = data().jobs
        let b = ReviewSendability.block(for: jobs[0], in: jobs, cooldownDays: 30)!
        let msg = ReviewSendability.message(b, in: jobs)
        #expect(msg.hasPrefix("You applied to Prodigal on ") && msg.contains("I can send this from "))
        let u = ReviewSendability.block(for: jobs[2], in: jobs, cooldownDays: 30)!
        #expect(ReviewSendability.message(u, in: jobs).contains("I'm not sure your Acme SRE application on"))
        #expect(ReviewSendability.rowLabel(b).hasPrefix("From "))
        let p = ReviewSendability.block(for: jobs[4], in: jobs, cooldownDays: 30)!
        #expect(ReviewSendability.message(p).hasPrefix("One Ramp job at a time: approving this holds the other until "))
    }

    // MARK: Review behaviour

    @Test func blockedJobsWaitAtTheBottomAndAreNotSelected() async {
        let (_, _, model) = await setup()
        let order = model.queue.map(\.id)
        #expect(Set(order.suffix(2)) == [1, 3], "can't-send-yet jobs sink to the bottom")
        #expect(model.isBlocked(1) && model.isBlocked(3) && !model.isBlocked(5))
        model.selectAll()
        #expect(model.selection == [5, 6, 7])
        model.clearSelection()
    }

    @Test func noHoldRunsForAJobTheAgentWouldRefuse() async {
        let (store, daemon, model) = await setup()
        model.focusedJobID = 1
        #expect(model.tear(jobID: 1) == .refused)
        #expect(model.approve([1]).isEmpty)
        #expect(!model.isHeld(1))
        #expect(store.toasts.current?.message.hasPrefix("I kept Prodigal · Machine Learning Engineer in Review: you applied to Prodigal on ") == true)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(approves(daemon).isEmpty, "nothing was sent, and no 5 s wait to learn it")
    }

    @Test func batchWithTwoJobsAtOneCompanySendsTheBetterRankedOne() async {
        let (store, daemon, model) = await setup()
        model.selectAll()
        model.requestApprove()
        #expect(model.isHeld(5) && !model.isHeld(6) && model.isHeld(7))
        #expect(store.toasts.current?.message.contains("one Ramp job at a time") == true)
        _ = await c3WaitUntil { !model.sendHold.hasHolds }
        #expect(approves(daemon).flatMap { $0 }.sorted() == [5, 7])
        #expect(store.jobs.job(id: 6)?.state == .awaitingReview)
    }

    @Test func keepParksTheJobAndFocusMovesOn() async {
        let (_, _, model) = await setup()
        model.focusedJobID = 1
        model.keep(jobID: 1)
        #expect(model.isKept(1))
        #expect(model.focusedJobID != 1 && !model.isBlocked(model.focusedJobID ?? 1))
    }

    @Test func resolvingTheOtherApplicationUsesResolveUnknown() async {
        let (store, daemon, model) = await setup()
        #expect(await model.resolveOther(for: 3, sent: false))
        let sent = daemon.sent("resolve_unknown").compactMap { if case .resolveUnknown(let p) = $0 { p } else { nil } }
        #expect(sent.count == 1 && sent[0].applicationId == 4 && sent[0].submitted == false)
        #expect(store.toasts.current?.message.contains("Acme is free again") == true)
        #expect(await model.resolveOther(for: 1, sent: true) == false, "a cooldown has nothing to resolve")
    }

    // MARK: The agent's word

    @Test func heldReplyPutsTheJobBackAndSaysWhy() async {
        let (store, daemon, model) = await setup()
        let resets = ProtocolCoding.formatDate(Date().addingTimeInterval(30 * Self.day))
        daemon.responder = { cmd in
            guard case .approve = cmd else { return .ack(AckPayload()) }
            let held: JSONValue = .array([.object([
                "application_id": .int(7), "job_id": .int(7), "kind": .string("unconfirmed_attempt"),
                "reason": .string("company_attempt_unconfirmed"), "company": .string("Notion"),
                "since": .string(ProtocolCoding.formatDate(Date())), "resets_at": .string(resets),
                "other_application_id": .int(99), "other_state": .string("unknown_verify"),
            ])])
            return .ack(AckPayload(ok: true, result: ["application_ids": .array([.int(5)]), "held": held]))
        }
        model.approve([5, 7])
        _ = await c3WaitUntil { !model.sendHold.hasHolds }
        _ = await c3WaitUntil { store.jobs.job(id: 7)?.state == .awaitingReview }
        #expect(store.jobs.job(id: 7)?.state == .awaitingReview)
        #expect(store.jobs.job(id: 5)?.state == .submitting)
        let messages = [store.toasts.current?.message] + store.toasts.queue.map(\.message)
        #expect(messages.contains { $0?.hasPrefix("I kept Notion · Backend Engineer in Review: I'm not sure") == true })
    }

    @Test func refusalToastIsPrecise() async {
        let (store, _, _) = await setup()
        let since = Date().addingTimeInterval(-12 * Self.day)
        let p = ErrorPayload(code: .capReached, message: "company_cooldown: cannot submit application 1 now",
                             details: ["cap": .string("company_cooldown"), "kind": .string("cooldown"), "company": .string("Prodigal"),
                                       "since": .string(ProtocolCoding.formatDate(since)),
                                       "resets_at": .string(ProtocolCoding.formatDate(since.addingTimeInterval(30 * Self.day))),
                                       "other_application_id": .int(2)],
                             applicationId: 1)
        let msg = store.approveErrorMessage(.daemon(p)) ?? ""
        #expect(msg.hasPrefix("I didn't send Prodigal · Machine Learning Engineer: you applied to Prodigal on \(ReviewSendability.day(since))"))
        #expect(msg.contains("It stays in Review and I can send it from "))
        #expect(!msg.contains("or picked two"), "no more guessing")
        // An older agent (message prefix only) still reads right.
        let old = ErrorPayload(code: .capReached, message: "company_attempt_unconfirmed: cannot submit application 3 now", applicationId: 3)
        #expect(store.approveErrorMessage(.daemon(old))?.contains("I'm not sure your other Acme application went through") == true)
        let daily = ErrorPayload(code: .capReached, message: "daily_cap: cannot submit application 3 now", applicationId: 3)
        #expect(store.approveErrorMessage(.daemon(daily))?.contains("today's limit") == true)
    }

    // MARK: Rendering

    private func render<V: View>(_ store: AppStore, scheme: ColorScheme, style: ApproveStyle, audit: ProminenceAudit? = nil,
                                 @ViewBuilder _ view: () -> V) -> CGImage? {
        let content = view()
            .appEnvironment(store, simulateReduceMotion: true)
            .environment(\.colorScheme, scheme)
            .environment(\.approveStyleOverride, style)
            .environment(\.prominenceAudit, audit)
            .frame(width: 1200, height: 760)
            .background(Palette.windowBackground)
        return ImageRenderer(content: content).cgImage
    }

    @Test func eachStateRendersInLightAndDarkWithAtMostOnePrimary() async {
        let (store, _, model) = await setup()
        for style in ApproveStyle.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for id in [1, 3, 5] {
                    model.focusedJobID = id
                    let audit = ProminenceAudit()
                    #expect(render(store, scheme: scheme, style: style, audit: audit) { ReviewQueueView() } != nil, "\(style) \(scheme) job \(id)")
                    // Keep for <date> / the stub / Approve; an unconfirmed attempt asks a factual
                    // question whose two answers weigh the same, so nothing is prominent there.
                    #expect(audit.count == (id == 3 ? 0 : 1), "\(style) \(scheme) job \(id): at most one primary")
                }
            }
        }
        // Unconfirmed: the two answers weigh the same, so the notice has no pill of its own.
        let jobs = store.jobs.all
        let unsure = ReviewSendability.block(for: jobs.first { $0.id == 3 }!, in: jobs, cooldownDays: 30)!
        let audit = ProminenceAudit()
        _ = render(store, scheme: .light, style: .classic, audit: audit) {
            SendBlockNotice(model: model, job: jobs.first { $0.id == 3 }!, block: unsure, isPrimary: true)
        }
        #expect(audit.count == 0)
        // Kept: one quiet line.
        model.keep(jobID: 1)
        for scheme in [ColorScheme.light, .dark] {
            model.focusedJobID = 1
            #expect(render(store, scheme: scheme, style: .ticket) { ReviewQueueView() } != nil)
        }
    }

    // MARK: Sample data

    @Test func sampleDataReproducesBothRefusals() async {
        let daemon = MockDaemon(scenario: .idle)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await c3WaitUntil(timeout: .seconds(10)) { store.hasSnapshot && store.jobs.isLoaded }
        let model = ReviewModel.shared(for: store)
        #expect(model.sendBlock(for: MockScripts.cooldownReviewJobID)?.kind == .cooldown)
        #expect(model.sendBlock(for: MockScripts.unconfirmedReviewJobID)?.kind == .unconfirmedAttempt(inFlight: false))
        // The mock agent refuses them like the real one, with the details.
        let appID = store.jobs.job(id: MockScripts.cooldownReviewJobID)!.applicationID!
        do {
            _ = try await daemon.request(.approve(ApprovePayload(applicationIds: [appID])), timeout: .seconds(2))
            Issue.record("the mock agent sent a job in its company's cooldown")
        } catch DaemonClientError.daemon(let p) {
            #expect(p.code == .capReached && p.details?["kind"] == .string("cooldown") && p.details?["resets_at"] != nil)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(store.jobs.job(id: MockScripts.cooldownReviewJobID)?.state == .awaitingReview)
        await store.stop()
    }
}
