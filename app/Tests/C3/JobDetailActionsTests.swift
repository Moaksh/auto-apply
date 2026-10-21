// JobDetailActionsTests.swift — Job detail's state actions: approve with the low-confidence
// safeguard (shared with Review), skip with a reason, ⌘↵ held while editing, retry / apply
// anyway / resolve unknown, "Answer N questions" → Needs You, and the ⌘K approve entry.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Job detail actions", .serialized)
struct JobDetailActionsTests {
    /// 1 clean + 2 flagged awaiting review, 3 failed, 4 skipped, 5 unknown_verify, 6 needs_you.
    private func setup(clusters: [QuestionCluster] = []) async -> (AppStore, C3StubDaemon) {
        var data = RepositoryData()
        data.jobs = [
            C3Fixtures.job(id: 1, company: "Stripe", state: .awaitingReview),
            C3Fixtures.job(id: 2, company: "Ramp", state: .awaitingReview),
            C3Fixtures.job(id: 3, company: "Notion", state: .failed),
            C3Fixtures.job(id: 4, company: "Figma", state: .skipped),
            C3Fixtures.job(id: 5, company: "Linear", state: .unknownVerify),
            C3Fixtures.job(id: 6, company: "Vercel", state: .needsYou),
        ]
        let (store, daemon, _) = await makeC3Store(data: data, clusters: clusters)
        return (store, daemon)
    }

    private let clean = [C3Fixtures.answer(id: 11, app: 1, question: "Full name"),
                         C3Fixtures.answer(id: 12, app: 1, question: "Years w/ Go", confidence: 0.93, origin: .cv)]
    private let flagged = [C3Fixtures.answer(id: 21, app: 2, question: "Start date", answer: "2 months", confidence: 0.4, origin: .generated),
                           C3Fixtures.answer(id: 22, app: 2, question: "Why Ramp?", confidence: 0.7, origin: .memory)]

    private func approvedIDs(_ daemon: C3StubDaemon) -> [Int] {
        daemon.sent("approve").flatMap { cmd -> [Int] in if case .approve(let p) = cmd { p.applicationIds } else { [] } }
    }

    @Test func cleanApproveSubmitsAndStaysWithAToast() async {
        let (store, daemon) = await setup()
        let actions = JobDetailActions()
        await actions.requestApprove(job: store.jobs.job(id: 1)!, answers: clean, answersLoaded: true, store: store)
        #expect(actions.prompt == .none)
        #expect(approvedIDs(daemon) == [1])
        #expect(store.jobs.job(id: 1)?.state == .submitting, "chip updates in place")
        #expect(store.router.selection == .dashboard && store.router.path.isEmpty, "no navigation")
        #expect(store.toasts.current?.message == "Approved · sending now")
        #expect(!actions.inFlight)
    }

    @Test func flaggedApproveAsksInlineThenApprovesAnyway() async {
        let (store, daemon) = await setup()
        let actions = JobDetailActions()
        let job = store.jobs.job(id: 2)!
        await actions.requestApprove(job: job, answers: flagged, answersLoaded: true, store: store)
        #expect(actions.prompt == .confirmFlagged(flagged: 2, loading: false))
        #expect(approvedIDs(daemon).isEmpty, "nothing sent before the user confirms")
        actions.cancelPrompt()
        #expect(actions.prompt == .none)

        await actions.requestApprove(job: job, answers: flagged, answersLoaded: true, store: store)
        await actions.confirmApprove(job: job, store: store)
        #expect(approvedIDs(daemon) == [2])
        #expect(actions.prompt == .none)
    }

    @Test func unloadedAnswersAreNeverClean() async {
        let (store, daemon) = await setup()
        let actions = JobDetailActions()
        await actions.requestApprove(job: store.jobs.job(id: 1)!, answers: [], answersLoaded: false, store: store)
        #expect(actions.prompt == .confirmFlagged(flagged: 0, loading: true))
        #expect(approvedIDs(daemon).isEmpty)
    }

    @Test func approveIsHeldWhileAnEditorIsOpen() async {
        let (store, daemon) = await setup()
        let actions = JobDetailActions()
        actions.editingChanged(true)
        await actions.requestApprove(job: store.jobs.job(id: 1)!, answers: clean, answersLoaded: true, store: store)
        #expect(approvedIDs(daemon).isEmpty, "⌘↵ while typing must not submit")
        actions.editingChanged(false)
        actions.editingChanged(false)
        #expect(actions.openEditors == 0, "never negative")
        await actions.requestApprove(job: store.jobs.job(id: 1)!, answers: clean, answersLoaded: true, store: store)
        #expect(approvedIDs(daemon) == [1])
    }

    @Test func approveIgnoresJobsNoLongerAwaitingReview() async {
        let (store, daemon) = await setup()
        let actions = JobDetailActions()
        let stale = store.jobs.job(id: 1)!
        store.jobs.mutate(jobID: 1) { $0.state = .submitting }
        await actions.requestApprove(job: stale, answers: clean, answersLoaded: true, store: store)
        #expect(approvedIDs(daemon).isEmpty, "already approved elsewhere: no duplicate approve")
    }

    @Test func skipAsksForAReasonThenRejects() async {
        let (store, daemon) = await setup()
        let actions = JobDetailActions()
        let job = store.jobs.job(id: 1)!
        actions.requestSkip(job: job)
        #expect(actions.prompt == .skipReason)
        await actions.skip(job: job, reason: .wrongAnswers, store: store)
        let reasons = daemon.sent("reject").compactMap { cmd -> String? in if case .reject(let p) = cmd { p.reason } else { nil } }
        #expect(reasons == ["wrong_answers"])
        #expect(store.jobs.job(id: 1)?.state == .skipped)
        #expect(store.toasts.current?.message == "Skipped · Wrong answers")
        #expect(actions.prompt == .none)
    }

    @Test func failedSkippedAndUnknownActionsSendTheirCommands() async {
        let (store, daemon) = await setup()
        let actions = JobDetailActions()
        await actions.retry(job: store.jobs.job(id: 3)!, store: store)
        #expect(daemon.sent("retry_application").count == 1)
        await actions.applyAnyway(job: store.jobs.job(id: 4)!, store: store)
        #expect(daemon.sent("apply_anyway").count == 1)
        #expect(store.jobs.job(id: 4)?.state == .queued)
        await actions.resolve(job: store.jobs.job(id: 5)!, sent: true, store: store)
        let resolved = daemon.sent("resolve_unknown").compactMap { cmd -> Bool? in if case .resolveUnknown(let p) = cmd { p.submitted } else { nil } }
        #expect(resolved == [true])
        #expect(store.toasts.current != nil)
    }

    @Test func needsYouJobHasNoHeaderActionItsQuestionsAreATab() async {
        let clusters = [C3Fixtures.cluster("c_other", jobs: [9]), C3Fixtures.cluster("c_mine", jobs: [6, 9])]
        let (store, _) = await setup(clusters: clusters)
        _ = await c3WaitUntil { store.inbox.clusters.count == 2 }
        let job = store.jobs.job(id: 6)!
        #expect(JobDetailRules.headerActions(for: job).isEmpty)
        let mine = JobDetailRules.openClusters(forJob: 6, in: store.inbox.clusters)
        #expect(mine.map(\.clusterId) == ["c_mine"])
        #expect(JobDetailTab.initial(for: job, openQuestions: mine.count) == .questions)
    }

    @Test func paletteOffersApproveOnlyForAnOpenAwaitingReviewJob() async {
        let (store, _) = await setup()
        let palette = PaletteModel(store: store)
        palette.query = "> approve"
        #expect(!palette.results.contains { $0.kind == .action(.approveOpenJob) }, "no job open")

        store.router.go(.pipeline)
        store.router.openJob(id: 3)
        #expect(!palette.results.contains { $0.kind == .action(.approveOpenJob) }, "failed job isn't approvable")

        store.router.openJob(id: 1)
        let item = palette.results.first { $0.kind == .action(.approveOpenJob) }
        #expect(item?.title == "Approve & submit Stripe")
        #expect(item?.shortcut == .submit)
        await store.perform(.approveOpenJob)
        #expect(store.router.jobApproveRequest?.jobID == 1, "routed to the detail so the safeguard applies")
    }
}
