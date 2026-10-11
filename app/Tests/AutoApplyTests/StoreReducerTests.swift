// StoreReducerTests.swift — AppStore / sub-store reducers, optimistic commands with rollback,
// derived status, and stats aggregation.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("Store reducers")
struct StoreReducerTests {
    func makeStore(_ daemon: StubDaemon = StubDaemon(), jobs: [JobItem] = []) -> (AppStore, StubDaemon) {
        var data = RepositoryData()
        data.jobs = jobs
        let store = AppStore(client: daemon, repository: InMemoryRepository(data))
        store.commandTimeout = .milliseconds(100)
        store.jobs.replaceAll(jobs)
        return (store, daemon)
    }

    func env(_ e: DaemonEvent, replyTo: String? = nil) -> EventEnvelope { EventEnvelope(replyTo: replyTo, event: e) }

    @Test func snapshotSeedsSettingsInboxAndLiveState() {
        let (store, _) = makeStore()
        var snap = Samples.snapshot(paused: true, activity: .applying, clusters: [Samples.cluster("a", jobs: [1]), Samples.cluster("b", jobs: [2, 3])])
        snap.preferences.dailyCap = 20
        snap.mode = .review
        snap.sources = [SourceStatus(source: .linkedin, enabled: true, connected: true)]
        store.apply(env(.snapshot(snap), replyTo: "hello"))
        #expect(store.hasSnapshot)
        #expect(store.live.paused)
        #expect(store.live.activity == .applying)
        #expect(store.mode == .review)
        #expect(store.preferences.dailyCap == 20)
        #expect(store.inbox.clusters.map(\.clusterId) == ["b", "a"], "sorted by impact")
        #expect(store.sources[.linkedin]?.connected == true)
    }

    @Test func applicationStateUpdatesJobAndRunCountsAndTransitions() {
        let (store, _) = makeStore(jobs: [Samples.job(id: 1, state: .filling)])
        store.apply(env(.applicationState(ApplicationStatePayload(applicationId: 1, jobId: 1, fromState: .submitting, toState: .submitted, at: Samples.now))))
        let job = store.jobs.job(id: 1)
        #expect(job?.state == .submitted)
        #expect(job?.status == .applied)
        #expect(job?.submittedAt == Samples.now)
        #expect(store.live.runCounts.submitted == 1)
        #expect(store.live.submittedEventCount == 1)
        #expect(store.live.transitions.last?.to == .submitted)
        #expect(store.jobs.jobs(in: .applied).map(\.id) == [1])
    }

    @Test func jobDiscoveredAndScoredInsertOptimistically() {
        let (store, _) = makeStore()
        store.apply(env(.jobDiscovered(JobDiscoveredPayload(job: JobSummary(id: 9, applicationId: 9, companyId: 2, company: "Ramp",
                                                                              title: "Platform Eng", source: .ashby, ats: .ashby, discoveredAt: Samples.now)))))
        store.apply(env(.jobScored(JobScoredPayload(jobId: 9, applicationId: 9, score: 86,
                                                    reasons: ["summary": .string("good"), "factors": .object(["skills": .int(90)])], queued: true))))
        let job = store.jobs.job(id: 9)
        #expect(job?.company == "Ramp")
        #expect(job?.score == 86)
        #expect(job?.scoreFactors["skills"] == 90)
        #expect(job?.scoreSummary == "good")
        #expect(store.live.runCounts.discovered == 1)
    }

    @Test func questionOpenedAndResolvedMaintainInbox() {
        let (store, _) = makeStore()
        store.apply(env(.questionOpened(QuestionOpenedPayload(cluster: Samples.cluster("k", jobs: [1])))))
        #expect(store.inbox.openCount == 1)
        #expect(store.inbox.arrivalCount == 1)
        // Growing an existing cluster replaces it, no new arrival.
        store.apply(env(.questionOpened(QuestionOpenedPayload(cluster: Samples.cluster("k", jobs: [1, 2, 3])))))
        #expect(store.inbox.openCount == 1)
        #expect(store.inbox.arrivalCount == 1)
        #expect(store.inbox.jobsWaiting == 3)
        store.apply(env(.questionResolved(QuestionResolvedPayload(clusterId: "k", status: .answered, resumedApplicationIds: [1, 2, 3]))))
        #expect(store.inbox.openCount == 0)
        #expect(store.inbox.resolvedToday.first?.jobCount == 3)
    }

    @Test func tickerKeepsLastFiveStepsOfActiveApplication() {
        let (store, _) = makeStore()
        store.apply(env(.state(StatePayload(daemon: .applying, activeApplicationId: 5, activeJobId: 5))))
        for i in 0..<7 {
            store.apply(env(.agentStep(AgentStepPayload(applicationId: 5, jobId: 5, index: i, total: 7, action: "step \(i)", at: Samples.now))))
        }
        store.apply(env(.agentStep(AgentStepPayload(applicationId: 6, jobId: 6, index: 0, action: "other app", at: Samples.now))))
        #expect(store.live.ticker.map(\.index) == [2, 3, 4, 5, 6])
        #expect(store.live.stepProgress?.index == 7)
        // Switching the active application clears the ticker.
        store.apply(env(.state(StatePayload(daemon: .applying, activeApplicationId: 6, activeJobId: 6))))
        #expect(store.live.ticker.isEmpty)
    }

    @Test func unsolicitedErrorBecomesIssueButRepliesDoNot() {
        let (store, _) = makeStore()
        store.apply(env(.error(ErrorPayload(code: .conflict, message: "run in progress")), replyTo: "cmd1"))
        #expect(store.live.lastError == nil)
        store.apply(env(.error(ErrorPayload(code: .unavailable, message: "LinkedIn session expired"))))
        #expect(store.live.lastError?.message == "LinkedIn session expired")
        #expect(store.issues.contains { $0.message == "LinkedIn session expired" })
    }

    @Test func pauseIsOptimisticAndConfirmed() async {
        let daemon = StubDaemon()
        let (store, _) = makeStore(daemon)
        await store.pauseAll()
        #expect(store.live.paused)
        #expect(store.live.pauseRequest == nil)
        #expect(daemon.sent.contains { $0.type == "pause_all" })
    }

    @Test func pauseRetriesOnTimeoutThenRollsBack() async {
        let daemon = StubDaemon()
        daemon.responder = { _ in nil }   // never replies
        let (store, _) = makeStore(daemon)
        await store.pauseAll()
        #expect(daemon.sent.filter { $0.type == "pause_all" }.count == 3, "retries while unacknowledged")
        #expect(store.live.paused == false, "rolled back after retries exhausted")
        #expect(store.toasts.current?.style == .error)
    }

    @Test func answerQuestionRemovesClusterAndRestoresOnError() async {
        let daemon = StubDaemon()
        let (store, _) = makeStore(daemon)
        store.apply(env(.questionOpened(QuestionOpenedPayload(cluster: Samples.cluster("k", jobs: [1])))))
        daemon.responder = { _ in .error(ErrorPayload(code: .notFound, message: "gone")) }
        let ok = await store.answerQuestion(clusterID: "k", answer: "Yes")
        #expect(!ok)
        #expect(store.inbox.cluster(id: "k") != nil, "rolled back")
        daemon.responder = { _ in .ack(AckPayload(result: ["resumed_application_ids": .array([.int(1)])])) }
        let ok2 = await store.answerQuestion(clusterID: "k", answer: "Yes")
        #expect(ok2)
        #expect(store.inbox.cluster(id: "k") == nil)
        if case .answerQuestion(let p)? = daemon.sent.last {
            #expect(p.clusterId == "k")
            #expect(p.saveToMemory)
        } else {
            Issue.record("last command should be answer_question")
        }
    }

    @Test func setStatusOnlyForSubmittedAndRollsBack() async {
        let daemon = StubDaemon()
        let (store, _) = makeStore(daemon, jobs: [Samples.job(id: 1, state: .submitted, status: .applied, submittedAt: Samples.now),
                                                Samples.job(id: 2, state: .queued)])
        #expect(await store.setStatus(applicationID: 2, status: .interview) == false)
        #expect(daemon.sent.isEmpty)
        daemon.responder = { _ in nil }
        #expect(await store.setStatus(applicationID: 1, status: .interview) == false)
        #expect(store.jobs.job(id: 1)?.status == .applied)
        daemon.responder = { _ in .ack(AckPayload()) }
        #expect(await store.setStatus(applicationID: 1, status: .interview))
        #expect(store.jobs.job(id: 1)?.status == .interview)
        #expect(store.toasts.current?.actionTitle == "Undo" || store.toasts.queue.contains { $0.actionTitle == "Undo" })
    }

    @Test func updatePreferencesAppliesAckResult() async throws {
        let daemon = StubDaemon()
        var full = Preferences()
        full.mode = .review
        full.dailyCap = 9
        let encoded = try JSONValue.encode(full)
        daemon.responder = { _ in .ack(AckPayload(result: ["preferences": encoded])) }
        let (store, _) = makeStore(daemon)
        await store.setMode(.review)
        #expect(store.mode == .review)
        #expect(store.preferences.dailyCap == 9)
        guard case .updatePreferences(let p)? = daemon.sent.last else { Issue.record("expected update_preferences"); return }
        #expect(p.preferences.values["mode"] == .string("review"))
    }

    @Test func agentStatusReflectsActivityPauseAndConnection() {
        let (store, _) = makeStore()
        #expect(store.agentStatus.kind == .loading)
        var snap = Samples.snapshot(activity: .applying)
        snap.state.progress = Progress(done: 3, total: 12)
        store.apply(env(.snapshot(snap)))
        // Not yet "connected" (no connection observer on the stub) → shows disconnected after snapshot.
        #expect(store.agentStatus.kind == .disconnected)
        store.apply(env(.state(StatePayload(daemon: .idle, paused: true))))
        #expect(store.live.paused)
    }

    @Test func countsDeriveFromJobsWhenLoaded() {
        let today = Date()
        let (store, _) = makeStore(jobs: [
            Samples.job(id: 1, state: .queued), Samples.job(id: 2, state: .needsYou), Samples.job(id: 3, state: .awaitingReview),
            Samples.job(id: 4, state: .submitted, status: .applied, submittedAt: today),
        ])
        let c = store.counts
        #expect(c.queued == 1)
        #expect(c.needsYouJobs == 1)
        #expect(c.awaitingReview == 1)
        #expect(c.submittedToday == 1)
        #expect(c.submittedTotal == 1)
    }

    @Test func effectiveModePrecedence() {
        let (store, _) = makeStore()
        var prefs = Preferences()
        prefs.mode = .auto
        prefs.perAtsMode = ["workday": .review]
        prefs.perCompanyMode = ["7": .review]
        store.setPreferences(prefs)
        var job = Samples.job(id: 1)
        #expect(store.effectiveMode(for: job) == .auto)
        job.ats = .workday
        #expect(store.effectiveMode(for: job) == .review)
        job.ats = .greenhouse
        job.companyID = 7
        #expect(store.effectiveMode(for: job) == .review)
        job.modeOverride = .auto
        #expect(store.effectiveMode(for: job) == .auto)
    }

    @Test func batchApplyRecomputesOnce() {
        let (store, _) = makeStore(jobs: (1...50).map { Samples.job(id: $0, state: .queued) })
        let before = store.jobs.revision
        let envelopes = (1...50).map { env(.applicationState(ApplicationStatePayload(applicationId: $0, jobId: $0, fromState: .queued, toState: .prepping, at: Samples.now))) }
        store.apply(batch: EventBatch(envelopes: envelopes, frame: nil))
        #expect(store.jobs.revision == before + 1)
        #expect(store.jobs.count(.prepping) == 50)
    }
}

@Suite("State machine & stats")
struct StateMachineAndStatsTests {
    @Test func transitionTableMatchesContract() {
        #expect(AppState.awaitingReview.canTransition(to: .submitting, actor: .user))
        #expect(!AppState.awaitingReview.canTransition(to: .submitting, actor: .agent))
        #expect(AppState.filling.canTransition(to: .submitting, actor: .agent))
        #expect(!AppState.submitted.canTransition(to: .queued, actor: .user))
        #expect(!AppState.submitting.canTransition(to: .queued, actor: .user), "no auto retry of submits")
        #expect(AppState.unknownVerify.canTransition(to: .submitted, actor: .user))
        #expect(!AppState.unknownVerify.canTransition(to: .submitted, actor: .agent))
        let edgeCount = AppState.allowedTransitions.values.reduce(0) { $0 + $1.count }
        #expect(edgeCount == 32, "protocol.md §7 lists 32 edges")
        #expect(Set(AppState.allowedTransitions.keys) == Set(AppState.allCases))
    }

    @Test func boardColumnsAndStatusOrder() {
        #expect(BoardColumn(job: Samples.job(id: 1, state: .submitted, status: .interview)) == .interview)
        #expect(BoardColumn(job: Samples.job(id: 1, state: .submitted)) == .applied)
        #expect(BoardColumn(job: Samples.job(id: 1, state: .needsYou)) == .needsYou)
        #expect(BoardStatus.applied.next == .assessment)
        #expect(BoardStatus.ghosted.next == nil)
        #expect(BoardStatus.applied.previous == nil)
        #expect(!BoardStatus.ghosted.isResponse)
    }

    @Test func statsAggregates() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        var jobs: [JobItem] = []
        for i in 0..<12 {
            var j = Samples.job(id: i, state: .submitted, status: i < 3 ? .interview : (i < 5 ? .rejected : .applied),
                                submittedAt: now.addingTimeInterval(-Double(i % 3) * 86_400))
            j.resumeVariantID = i % 2 == 0 ? 1 : 2
            j.score = 80
            j.discoveredAt = now
            jobs.append(j)
        }
        var skipped = Samples.job(id: 100, state: .skipped)
        skipped.score = 52
        skipped.discoveredAt = now
        skipped.stateUpdatedAt = now
        jobs.append(skipped)
        let variants = [ResumeVariantItem(id: 1, label: "Backend", filePath: "", createdAt: now, updatedAt: now)]
        let stats = StatsCalculator.compute(jobs: jobs, variants: variants, now: now, calendar: cal)
        #expect(stats.appliedToday == 4)
        #expect(stats.appliedLast7.reduce(0, +) == 12)
        #expect(stats.appliedLast30 == 12)
        #expect(stats.responseRate30 == 5.0 / 12.0)
        #expect(stats.funnel30.first { $0.stage == .interview }?.count == 3)
        #expect(stats.funnel30.first { $0.stage == .responded }?.count == 5)
        #expect(stats.byVariant.first { $0.variantID == 1 }?.label == "Backend")
        #expect(stats.byVariant.first { $0.variantID == 2 }?.label == "Resume #2")
        #expect(stats.scoreHistogram[16].applied == 12)
        #expect(stats.scoreHistogram[10].skipped == 1)
        #expect(stats.heatmap.count == 182)
        #expect(stats.daily30.count == 30)
        #expect(stats.daily30.last?.applied == 4)
    }

    @Test func responseRateNeedsTenApplications() {
        let jobs = (0..<5).map { Samples.job(id: $0, state: .submitted, status: .interview, submittedAt: Date()) }
        #expect(StatsCalculator.compute(jobs: jobs, variants: []).responseRate30 == nil)
    }

}

extension StoreReducerTests {
    // MARK: Hello snapshot de-duplication

    @Test func duplicateHelloSnapshotDoesNotClobberNewerState() {
        let (store, _) = makeStore()
        let snap = Samples.snapshot(paused: false, clusters: [Samples.cluster("a", jobs: [1]), Samples.cluster("b", jobs: [2])])
        store.applySnapshot(snap)                      // the connect() return value
        store.live.paused = true                       // optimistic kill switch
        store.live.pauseRequest = .pausing
        _ = store.inbox.removeOptimistically(clusterID: "a")
        store.apply(env(.snapshot(snap), replyTo: "hello"))   // the same snapshot echoed on `events`
        #expect(store.live.paused, "echo must not undo the optimistic pause")
        #expect(store.live.pauseRequest == .pausing)
        #expect(store.inbox.cluster(id: "a") == nil, "echo must not resurrect a removed cluster")
        // A genuinely new snapshot (e.g. after a reconnect) is applied in full.
        let fresh = Samples.snapshot(paused: false, activity: .discovering, clusters: [Samples.cluster("c", jobs: [3])])
        store.apply(env(.snapshot(fresh), replyTo: "hello2"))
        #expect(!store.live.paused)
        #expect(store.live.activity == .discovering)
        #expect(store.inbox.clusters.map(\.clusterId) == ["c"])
    }

    @Test func echoArrivingBeforeDirectApplyIsAlsoDeduplicated() {
        let (store, _) = makeStore()
        let snap = Samples.snapshot(clusters: [Samples.cluster("a", jobs: [1])])
        store.apply(env(.snapshot(snap), replyTo: "hello"))
        _ = store.inbox.removeOptimistically(clusterID: "a")
        store.applySnapshot(snap)
        #expect(store.inbox.cluster(id: "a") == nil)
    }

    // MARK: Approve / reject

    @Test func approveIsOptimisticAndConfirmedOnAck() async {
        let daemon = StubDaemon()
        let (store, _) = makeStore(daemon, jobs: [Samples.job(id: 1, state: .awaitingReview), Samples.job(id: 2, state: .awaitingReview)])
        #expect(await store.approve(applicationIDs: [1, 2]))
        #expect(store.jobs.job(id: 1)?.state == .submitting)
        #expect(store.jobs.job(id: 2)?.state == .submitting)
        guard case .approve(let p)? = daemon.sent.last else { Issue.record("expected approve"); return }
        #expect(p.applicationIds == [1, 2])
        #expect(store.toasts.current == nil)
        #expect(await store.approve(applicationIDs: []) == false)
        #expect(daemon.sent.count == 1, "empty approve sends nothing")
    }

    @Test func approveRollsBackOnErrorReply() async {
        let daemon = StubDaemon()
        daemon.responder = { _ in .error(ErrorPayload(code: .illegalTransition, message: "application 1 is not awaiting review")) }
        let (store, _) = makeStore(daemon, jobs: [Samples.job(id: 1, state: .awaitingReview)])
        #expect(await store.approve(applicationIDs: [1]) == false)
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview)
        #expect(store.toasts.current?.style == .error)
    }

    @Test func approveTimeoutKeepsSubmittingAndShowsCalmToast() async {
        let daemon = StubDaemon()
        daemon.responder = { _ in nil }   // no ack in time
        let (store, _) = makeStore(daemon, jobs: [Samples.job(id: 1, state: .awaitingReview)])
        store.approvalTimeout = .milliseconds(100)
        #expect(await store.approve(applicationIDs: [1]) == false)
        #expect(store.jobs.job(id: 1)?.state == .submitting, "daemon may already be submitting; DB poll reconciles")
        #expect(store.toasts.current?.style == .info)
        #expect(store.toasts.current?.message.contains("waiting") == true)
    }

    @Test func rejectIsOptimisticAndRollbackRestoresStateAndReason() async {
        let daemon = StubDaemon()
        var job = Samples.job(id: 1, state: .awaitingReview)
        job.stateReason = "low_confidence"
        let (store, _) = makeStore(daemon, jobs: [job])
        daemon.responder = { _ in .error(ErrorPayload(code: .notFound, message: "gone")) }
        #expect(await store.reject(applicationID: 1, reason: "not a fit") == false)
        #expect(store.jobs.job(id: 1)?.state == .awaitingReview)
        #expect(store.jobs.job(id: 1)?.stateReason == "low_confidence")
        daemon.responder = { _ in .ack(AckPayload()) }
        #expect(await store.reject(applicationID: 1, reason: "not a fit"))
        #expect(store.jobs.job(id: 1)?.state == .skipped)
        #expect(store.jobs.job(id: 1)?.stateReason == "not a fit")
    }

    @Test func updatePreferencesReportsFailureAndRecordsError() async {
        let daemon = StubDaemon()
        daemon.responder = { _ in .error(ErrorPayload(code: .invalidPayload, message: "bad")) }
        let (store, _) = makeStore(daemon)
        #expect(await store.setMode(.review) == false)
        #expect(store.mode == .auto, "rolled back")
        if case .daemon(let p)? = store.lastCommandError { #expect(p.code == .invalidPayload) } else { Issue.record("lastCommandError not set") }
    }
}
