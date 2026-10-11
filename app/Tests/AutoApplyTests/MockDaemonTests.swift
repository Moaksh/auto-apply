// MockDaemonTests.swift — every scenario's setup and script outcomes, command semantics, and
// end-to-end store wiring (MockDaemon → EventCoalescer → AppStore).
import Foundation
import Testing
@testable import AutoApply

@Suite("MockDaemon scenarios", .serialized)
struct MockDaemonTests {
    /// Run a scenario's script to completion at high speed and return the daemon.
    func runScript(_ scenario: MockScenario, speed: Double = 400) async throws -> MockDaemon {
        let daemon = MockDaemon(scenario: scenario, speed: speed)
        try await daemon.connect()
        return daemon
    }

    func waitForIdleAfterRun(_ daemon: MockDaemon, timeout: Duration = .seconds(20)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if daemon.world.read({ $0.lastRun?.runId.hasPrefix("mockrun") == true && $0.currentRun == nil }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func scenarioNamesResolveFromEnvironment() {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        #expect(MockDaemon.requestedScenario(environment: [:], defaults: defaults) == nil)
        #expect(MockDaemon.requestedScenario(environment: ["AUTOAPPLY_MOCK": "needs_you_storm"], defaults: defaults) == .needsYouStorm)
        #expect(MockDaemon.requestedScenario(environment: ["AUTOAPPLY_MOCK": "reviewMode"], defaults: defaults) == .reviewMode)
        #expect(MockDaemon.requestedScenario(environment: ["AUTOAPPLY_MOCK": "1"], defaults: defaults) == .happyRun)
        #expect(MockDaemon.requestedScenario(environment: ["AUTOAPPLY_MOCK": "0"], defaults: defaults) == nil)
        defaults.set("stress", forKey: "AUTOAPPLY_MOCK")
        #expect(MockDaemon.requestedScenario(environment: ["AUTOAPPLY_MOCK": "idle"], defaults: defaults) == .stress, "launch arg wins")
        #expect(MockDaemon.requestedSpeed(environment: ["AUTOAPPLY_MOCK_SPEED": "4"], defaults: defaults) == 4)
    }

    @Test func baselineFixturesAreRichAndConsistent() {
        let data = MockFixtures.baseline(now: Date())
        #expect(data.jobs.count == 229)
        #expect(Set(data.jobs.map(\.id)).count == data.jobs.count, "unique ids")
        let states = Set(data.jobs.map(\.state))
        for s in [AppState.skipped, .submitted, .queued, .needsYou, .scored] { #expect(states.contains(s), "missing \(s)") }
        let statuses = Set(data.jobs.compactMap(\.status))
        #expect(statuses.isSuperset(of: [.applied, .rejected, .interview]))
        #expect(data.jobs.allSatisfy { $0.status == nil || $0.state == .submitted }, "status only when submitted (schema CHECK)")
        #expect(data.jobs.allSatisfy { $0.state != .submitted || $0.submittedAt != nil })
        #expect(data.easyApply.count == 9)
        #expect(!data.activity.isEmpty)
        #expect(zip(data.activity, data.activity.dropFirst()).allSatisfy { $0.id < $1.id && $0.ts <= $1.ts })
        // Deterministic across runs.
        let again = MockFixtures.baseline(now: Date())
        #expect(again.jobs.map(\.title) == data.jobs.map(\.title))
    }

    @Test func happyRunProducesSpecCounts() async throws {
        let daemon = try await runScript(.happyRun, speed: 600)
        #expect(await waitForIdleAfterRun(daemon))
        let stats = try #require(daemon.world.read { $0.lastRun?.stats })
        #expect(stats.discovered == 40)
        #expect(stats.skipped == 27)
        #expect(stats.queued == 12)
        #expect(stats.submitted == 9)
        #expect(stats.needsYou == 2)
        #expect(stats.failed == 1)
        let runJobs = daemon.repository.read { d in d.jobs.filter { MockScripts.happyJobIDs.contains($0.id) } }
        #expect(runJobs.filter { $0.state == .submitted }.count == 9)
        #expect(runJobs.filter { $0.state == .queued }.count == 1)
        let answered = runJobs.filter { $0.state == .submitted }.allSatisfy { job in daemon.repository.read { d in d.applicationAnswers[job.id] } != nil }
        #expect(answered)
        #expect(daemon.world.read { $0.daemon.daemon } == .idle)
        await daemon.disconnect()
    }

    @Test func needsYouStormCollapsesToSixClusters() async throws {
        let daemon = try await runScript(.needsYouStorm, speed: 400)
        #expect(await waitForIdleAfterRun(daemon))
        let stormClusters = daemon.world.read { $0.openClusters }.filter { c in c.jobIds.contains { MockScripts.stormJobIDs.contains($0) } }
        #expect(stormClusters.count == 6)
        let stormJobsInClusters = stormClusters.flatMap(\.jobIds).filter { MockScripts.stormJobIDs.contains($0) }
        #expect(stormJobsInClusters.count == 14)
        #expect(daemon.repository.read { d in d.jobs.filter { MockScripts.stormJobIDs.contains($0.id) }.allSatisfy { $0.state == .needsYou } })
        await daemon.disconnect()
    }

    @Test func reviewModeLeavesFiveAwaitingReviewOneLowConfidence() async throws {
        let daemon = try await runScript(.reviewMode, speed: 400)
        #expect(await waitForIdleAfterRun(daemon))
        let awaiting = daemon.repository.read { d in d.jobs.filter { $0.state == .awaitingReview } }
        #expect(awaiting.count == 5)
        let lowConfidence = awaiting.filter { job in
            daemon.repository.read { d in d.applicationAnswers[job.id]?.contains { ($0.confidence ?? 1) < 0.6 } ?? false }
        }
        #expect(lowConfidence.count == 1)
        #expect(daemon.world.read { $0.preferences.mode } == .review)

        // Approve two → submitting → submitted.
        let ids = Array(awaiting.prefix(2).compactMap(\.applicationID))
        let reply = try await daemon.request(.approve(ApprovePayload(applicationIds: ids)), timeout: .seconds(2))
        if case .ack = reply.event {} else { Issue.record("approve should ack") }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if daemon.repository.read({ d in ids.allSatisfy { id in d.jobs.first { $0.applicationID == id }?.state == .submitted } }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(daemon.repository.read { d in ids.allSatisfy { id in d.jobs.first { $0.applicationID == id }?.state == .submitted } })
        // Approving something not awaiting review is an illegal transition.
        await #expect(throws: DaemonClientError.self) {
            _ = try await daemon.request(.approve(ApprovePayload(applicationIds: ids)), timeout: .seconds(1))
        }
        await daemon.disconnect()
    }

    @Test func daemonDownNeverConnects() async {
        let daemon = MockDaemon(scenario: .daemonDown, speed: 20)
        let states = daemon.connectionStates
        await #expect(throws: DaemonClientError.notConnected) { try await daemon.connect() }
        let seen = await collect(states, count: 4, timeout: .seconds(3))
        #expect(seen.contains { if case .reconnecting = $0 { true } else { false } })
        #expect(!seen.contains(.connected))
        await #expect(throws: DaemonClientError.notConnected) { _ = try await daemon.request(.ping(PingPayload()), timeout: .seconds(1)) }
        #expect(daemon.repository.read { !$0.jobs.isEmpty }, "DB-driven screens still have data")
        await daemon.disconnect()
    }

    @Test func loginExpiredEmitsSourceStatusAndUnsolicitedError() async throws {
        let daemon = MockDaemon(scenario: .loginExpired, speed: 50)
        let stream = daemon.events
        try await daemon.connect()
        let events = await collect(stream, count: 6, timeout: .seconds(3))
        #expect(events.contains { if case .sourceStatus(let p) = $0.event { return p.source.source == .linkedin && !p.source.connected }; return false })
        #expect(events.contains { if case .error(let p) = $0.event { return $0.replyTo == nil && p.code == .unavailable }; return false })
        await daemon.disconnect()
    }

    @Test func capReachedEmitsDailyCap() async throws {
        let daemon = MockDaemon(scenario: .capReached, speed: 200)
        let stream = daemon.events
        try await daemon.connect()
        let events = await collect(stream, count: 200, timeout: .seconds(4))
        let cap = events.compactMap { env -> CapReachedPayload? in if case .capReached(let p) = env.event { return p }; return nil }.first
        #expect(cap?.cap == .daily)
        #expect(cap.map { $0.used >= $0.limit } == true)
        await daemon.disconnect()
    }

    @Test func burstSubmitsFiveQuickly() async throws {
        let daemon = try await runScript(.burstSubmit, speed: 100)
        #expect(await waitForIdleAfterRun(daemon))
        #expect(daemon.repository.read { d in d.jobs.filter { MockScripts.burstJobIDs.contains($0.id) && $0.state == .submitted }.count } == 5)
        await daemon.disconnect()
    }

    @Test func stressScenarioHasFiveThousandJobsAndStreams() async throws {
        let setup = MockScenario.stress.makeSetup()
        #expect(setup.data.jobs.count >= 5_000)
        #expect(setup.data.activity.count >= 95_000)
        let daemon = MockDaemon(scenario: .stress, speed: 4)
        let stream = daemon.events
        try await daemon.connect()
        let events = await collect(stream, count: 80, timeout: .seconds(3))
        #expect(events.count >= 40, "stress emits a steady event stream")
        await daemon.disconnect()
    }

    @Test func firstRunAndOnboardingScenarios() {
        let empty = MockScenario.firstRunEmpty.makeSetup()
        #expect(empty.data.jobs.isEmpty)
        #expect(empty.state.onboarding.completed)
        let fresh = MockScenario.onboarding.makeSetup()
        #expect(!fresh.state.onboarding.completed)
        #expect(fresh.data.resumeVariants.isEmpty)
    }

    @Test func commandSemantics() async throws {
        let daemon = MockDaemon(scenario: .idle, speed: 100)
        try await daemon.connect()

        // Pause blocks run_now; resume allows it.
        _ = try await daemon.request(.pauseAll(PauseAllPayload()), timeout: .seconds(1))
        try await Task.sleep(for: .milliseconds(30))
        await #expect(throws: DaemonClientError.self) { _ = try await daemon.request(.runNow(RunNowPayload()), timeout: .seconds(1)) }
        _ = try await daemon.request(.resume(ResumePayload()), timeout: .seconds(1))
        try await Task.sleep(for: .milliseconds(30))

        // Preferences patch merges and returns the full object; invalid values are rejected.
        var patch = PreferencesPatch()
        try patch.set(.dailyCap, 22)
        let prefs = try await daemon.requestResult(.updatePreferences(UpdatePreferencesPayload(preferences: patch)),
                                                   as: [String: Preferences].self)
        #expect(prefs["preferences"]?.dailyCap == 22)
        #expect(prefs["preferences"]?.matchThreshold == 70)
        var bad = PreferencesPatch()
        bad.values["mode"] = .string("yolo")
        await #expect(throws: DaemonClientError.self) {
            _ = try await daemon.request(.updatePreferences(UpdatePreferencesPayload(preferences: bad)), timeout: .seconds(1))
        }

        // Never-guess null = "always ask me".
        var ng = NeverGuessPatch()
        try ng.set(.noticePeriod, Optional<String>.none)
        _ = try await daemon.request(.updateNeverGuess(UpdateNeverGuessPayload(values: ng)), timeout: .seconds(1))
        #expect(daemon.repository.read { $0.neverGuess.noticePeriod } == nil)

        // Answering an open cluster re-queues its parked jobs.
        let cluster = try #require(daemon.world.read { $0.openClusters.first })
        let parked = cluster.jobIds
        _ = try await daemon.request(.answerQuestion(AnswerQuestionPayload(clusterId: cluster.clusterId, answer: "Because {company}")), timeout: .seconds(1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(daemon.world.cluster(id: cluster.clusterId) == nil)
        #expect(daemon.repository.read { d in d.memoryAnswers.contains { $0.answer == "Because {company}" && $0.isTemplate } })
        let otherOpenJobs = Set(daemon.world.read { $0.openClusters.flatMap(\.jobIds) })
        let requeued = daemon.repository.read { d in parked.filter { id in d.jobs.first { $0.id == id }?.state == .queued } }
        #expect(Set(requeued) == Set(parked).subtracting(otherOpenJobs))
        await #expect(throws: DaemonClientError.self) {
            _ = try await daemon.request(.answerQuestion(AnswerQuestionPayload(clusterId: cluster.clusterId, answer: "x")), timeout: .seconds(1))
        }

        // set_status only on submitted applications.
        let submitted = try #require(daemon.repository.read { $0.jobs.first { $0.state == .submitted } })
        _ = try await daemon.request(.setStatus(SetStatusPayload(applicationId: submitted.applicationID!, status: .offer)), timeout: .seconds(1))
        #expect(daemon.repository.read { d in d.jobs.first { $0.id == submitted.id }?.status } == .offer)
        let queued = try #require(daemon.repository.read { $0.jobs.first { $0.state == .queued } })
        await #expect(throws: DaemonClientError.self) {
            _ = try await daemon.request(.setStatus(SetStatusPayload(applicationId: queued.applicationID!, status: .offer)), timeout: .seconds(1))
        }

        // Easy Apply done → manual submitted application.
        let easy = try #require(daemon.repository.read { $0.easyApply.first { $0.isOpen } })
        _ = try await daemon.request(.markEasyApplyDone(MarkEasyApplyDonePayload(jobId: easy.jobID)), timeout: .seconds(1))
        let manual = daemon.repository.read { d in d.jobs.first { $0.id == easy.jobID } }
        #expect(manual?.state == .submitted)
        #expect(manual?.mode == .manual)
        #expect(daemon.repository.read { d in d.easyApply.first { $0.jobID == easy.jobID }?.done } == true)

        // Stories CRUD.
        struct StoryResult: Decodable { var story_id: Int }
        let created = try await daemon.requestResult(.upsertStory(UpsertStoryPayload(title: "New", situation: "s")), as: StoryResult.self)
        #expect(daemon.repository.read { d in d.stories.contains { $0.id == created.story_id && $0.title == "New" } })
        _ = try await daemon.request(.deleteStory(DeleteStoryPayload(id: created.story_id)), timeout: .seconds(1))
        #expect(daemon.repository.read { d in !d.stories.contains { $0.id == created.story_id } })

        // Onboarding commands.
        let check = try await daemon.requestResult(.onboardingSystemCheck(OnboardingSystemCheckPayload()), as: SystemCheckResult.self, timeout: .seconds(2))
        #expect(check.allRequiredOk)
        let parsed = try await daemon.requestResult(.onboardingParseResume(OnboardingParseResumePayload(filePath: "/tmp/Backend.pdf")),
                                                    as: ParseResumeResult.self, timeout: .seconds(2))
        #expect(parsed.profile.fullName == "Moaksh Kakkar")
        #expect(daemon.repository.read { d in d.resumeVariants.contains { $0.id == parsed.resumeVariantId && $0.label == "Backend" } })
        await daemon.disconnect()
    }

    @Test func runNowRunsAMiniPipeline() async throws {
        let daemon = MockDaemon(scenario: .firstRunEmpty, speed: 200)
        try await daemon.connect()
        let reply = try await daemon.request(.runNow(RunNowPayload(kind: .full)), timeout: .seconds(1))
        guard case .ack(let ack) = reply.event, case .string(let runID)? = ack.result?["run_id"] else {
            Issue.record("run_now should ack with run_id")
            return
        }
        #expect(runID.hasPrefix("mockrun"))
        #expect(await waitForIdleAfterRun(daemon))
        #expect(daemon.repository.read { d in d.jobs.count } == 5)
        #expect(daemon.repository.read { d in d.jobs.filter { $0.state == .submitted }.count } == 2)
        await daemon.disconnect()
    }

    @Test func connectSourceFlipsToConnected() async throws {
        let daemon = MockDaemon(scenario: .onboarding, speed: 50)
        let stream = daemon.events
        try await daemon.connect()
        _ = try await daemon.request(.onboardingConnectSource(OnboardingConnectSourcePayload(source: .linkedin)), timeout: .seconds(1))
        let events = await collect(stream, count: 4, timeout: .seconds(3))
        let statuses = events.compactMap { env -> SourceStatus? in if case .sourceStatus(let p) = env.event { return p.source }; return nil }
        #expect(statuses.last?.connected == true)
        #expect(statuses.first?.connected == false)
        _ = try await daemon.request(.onboardingComplete(OnboardingCompletePayload(runPrep: false)), timeout: .seconds(1))
        #expect(daemon.world.read { $0.onboarding.completed })
        await daemon.disconnect()
    }
}

@MainActor
@Suite("Store + MockDaemon end to end", .serialized)
struct StoreMockIntegrationTests {
    @Test func storeFollowsHappyRun() async throws {
        let daemon = MockDaemon(scenario: .happyRun, speed: 300)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "happyRun")
        store.statsDebounce = .milliseconds(10)
        store.start()
        #expect(await waitUntil { store.isConnected && store.hasSnapshot })
        #expect(await waitUntil(timeout: .seconds(20)) { store.live.lastRun?.runId.hasPrefix("mockrun") == true && store.live.currentRun == nil })
        #expect(store.live.runCounts.submitted == 9)
        #expect(store.live.runCounts.discovered == 40)
        #expect(await waitUntil { store.jobs.all.filter { MockScripts.happyJobIDs.contains($0.id) && $0.state == .submitted }.count == 9 })
        #expect(store.inbox.clusters.contains { $0.jobIds.contains(MockScripts.happyJobIDs[37]) })
        #expect(store.activity.isLoaded)
        #expect(await waitUntil { store.stats.computedAt != .distantPast })
        await store.stop()
    }

    @Test func pauseKillSwitchRoundTripsThroughMock() async throws {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository)
        store.start()
        #expect(await waitUntil { store.isConnected })
        await store.togglePause()
        #expect(store.live.paused)
        #expect(await waitUntil { daemon.world.isPaused })
        #expect(store.agentStatus.kind == .paused)
        await store.togglePause()
        #expect(await waitUntil { !store.live.paused && !daemon.world.isPaused })
        await store.stop()
    }

    @Test func daemonDownMarksUnreachableButKeepsDBData() async throws {
        let daemon = MockDaemon(scenario: .daemonDown, speed: 20)
        let store = AppStore(client: daemon, repository: daemon.repository)
        store.unreachableDelay = .milliseconds(100)
        store.start()
        #expect(await waitUntil { store.isDaemonUnreachable })
        #expect(store.agentStatus.kind == .disconnected)
        #expect(store.issues.first?.fix == .restartDaemon)
        #expect(await waitUntil { store.jobs.isLoaded && !store.jobs.all.isEmpty })
        await store.stop()
    }

    @Test func answeringInStoreRequeuesInMock() async throws {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository)
        store.start()
        #expect(await waitUntil { store.isConnected && !store.inbox.clusters.isEmpty })
        let cluster = try #require(store.inbox.clusters.first)
        let ok = await store.answerQuestion(clusterID: cluster.clusterId, answer: "4")
        #expect(ok)
        #expect(store.inbox.cluster(id: cluster.clusterId) == nil)
        #expect(await waitUntil { store.inbox.resolvedToday.contains { $0.clusterID == cluster.clusterId } })
        await store.stop()
    }
}
