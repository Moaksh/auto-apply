// InboxModelTests.swift — answer-once flow: optimistic removal, the Undo window (command held
// until it closes), auto-advance, failure restore, skip, per-job, inbox zero, and an end-to-end
// run against MockDaemon's needsYouStorm scenario.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Inbox model", .serialized)
struct InboxModelTests {
    private func setup(_ clusters: [QuestionCluster]) async -> (AppStore, C3StubDaemon, InboxModel) {
        var data = RepositoryData()
        data.jobs = [1, 2, 3, 4, 5].map { C3Fixtures.job(id: $0, company: ["Stripe", "Ramp", "Notion", "Figma", "Linear"][$0 - 1], state: .needsYou) }
        let (store, daemon, _) = await makeC3Store(data: data, clusters: clusters)
        let model = InboxModel(store: store)
        model.clipboard = RecordingClipboard()
        model.undoWindow = .milliseconds(150)
        _ = await c3WaitUntil { store.inbox.openCount == clusters.count }
        return (store, daemon, model)
    }

    @Test func clustersAreImpactFirstAndSelectionFollows() async {
        let (_, _, model) = await setup([
            C3Fixtures.cluster("small", jobs: [1], question: "Portfolio URL?", fieldType: .url),
            C3Fixtures.cluster("big", jobs: [1, 2, 3], question: "Notice period?"),
        ])
        #expect(model.clusters.map(\.clusterId) == ["big", "small"])
        #expect(model.jobsWaiting == 3)
        model.ensureSelection()
        #expect(model.selectedClusterID == "big")
        #expect(!model.isUnread(model.clusters[0]))
        #expect(model.isUnread(model.clusters[1]))
        model.moveSelection(by: 1)
        #expect(model.selectedClusterID == "small")
        model.moveSelection(by: 5)
        #expect(model.selectedClusterID == "small")
    }

    @Test func answerIsHeldForTheUndoWindowThenSent() async throws {
        let (store, daemon, model) = await setup([
            C3Fixtures.cluster("a", jobs: [1, 2], question: "Notice period?"),
            C3Fixtures.cluster("b", jobs: [3], question: "Portfolio URL?", fieldType: .url),
        ])
        model.ensureSelection()
        let a = try #require(model.selectedCluster)
        model.updateDraft(for: a) { $0.text = "60 days" }
        #expect(model.submitSelected())
        // Left the list at once, auto-advanced, logged as pending; nothing sent yet.
        #expect(model.clusters.map(\.clusterId) == ["b"])
        #expect(model.selectedClusterID == "b")
        #expect(model.answered.first?.isPending == true)
        #expect(daemon.sent("answer_question").isEmpty)
        #expect(store.toasts.current?.actionTitle == "Undo")
        // After the window the command goes out with the right payload.
        #expect(await c3WaitUntil { daemon.sent("answer_question").count == 1 })
        let payload = try #require(daemon.sent("answer_question").first?.answerPayload)
        #expect(payload.clusterId == "a")
        #expect(payload.answer == "60 days")
        #expect(payload.saveToMemory)
        #expect(!payload.saveToProfile)
        #expect(await c3WaitUntil { model.answered.first?.isPending == false })
        #expect(model.resumedToday == 2)
    }

    @Test func undoInsideWindowCancelsAndRestoresDraft() async throws {
        let (_, daemon, model) = await setup([C3Fixtures.cluster("a", jobs: [1, 2]), C3Fixtures.cluster("b", jobs: [3], question: "Notice period?")])
        model.undoWindow = .seconds(5)
        model.ensureSelection()
        let a = try #require(model.selectedCluster)
        model.updateDraft(for: a) { $0.text = "I'm drawn to {company}" }
        model.submitSelected()
        #expect(model.clusters.count == 1)
        #expect(model.undo())
        #expect(model.clusters.map(\.clusterId) == ["a", "b"])
        #expect(model.selectedClusterID == "a")
        #expect(model.draft(for: a).text == "I'm drawn to {company}")
        #expect(model.answered.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(daemon.sent("answer_question").isEmpty)
        #expect(!model.undo())
    }

    @Test func failedCommandRestoresTheCluster() async throws {
        let (_, daemon, model) = await setup([C3Fixtures.cluster("a", jobs: [1])])
        daemon.responder = { cmd in
            if case .answerQuestion = cmd { return .error(ErrorPayload(code: .notFound, message: "cluster gone")) }
            return .ack(AckPayload())
        }
        model.ensureSelection()
        let a = try #require(model.selectedCluster)
        model.updateDraft(for: a) { $0.text = "yes" }
        model.submitSelected()
        #expect(model.clusters.isEmpty)
        #expect(await c3WaitUntil { model.clusters.map(\.clusterId) == ["a"] })
        #expect(model.answered.isEmpty)
        #expect(model.draft(for: a).text == "yes")
    }

    @Test func invalidInputDoesNotSubmit() async throws {
        let (_, daemon, model) = await setup([C3Fixtures.cluster("n", jobs: [1], question: "Years of Go?", fieldType: .number)])
        model.ensureSelection()
        let n = try #require(model.selectedCluster)
        model.updateDraft(for: n) { $0.text = "lots" }
        #expect(!model.submitSelected())
        #expect(model.validationMessage == AnswerValidationError.notANumber.message)
        #expect(model.clusters.count == 1)
        model.updateDraft(for: n) { $0.text = "4" }
        #expect(model.validationMessage == nil)
        #expect(model.submitSelected())
        await model.flushPending()
        #expect(daemon.sent("answer_question").first?.answerPayload?.answer == "4")
    }

    @Test func skipSendsSkipQuestion() async throws {
        let (_, daemon, model) = await setup([C3Fixtures.cluster("a", jobs: [1, 2])])
        model.ensureSelection()
        model.skipSelected()
        #expect(model.answered.first?.status == .skipped)
        await model.flushPending()
        let skip = try #require(daemon.sent("skip_question").first)
        guard case .skipQuestion(let p) = skip else { Issue.record("wrong command"); return }
        #expect(p.clusterId == "a")
        #expect(daemon.sent("answer_question").isEmpty)
    }

    @Test func neverGuessSavesToProfileAndPerJobSendsEachAnswer() async throws {
        let (_, daemon, model) = await setup([
            C3Fixtures.cluster("ng", jobs: [1, 2, 3, 4], question: "Notice period?", neverGuessKey: "notice_period"),
            C3Fixtures.cluster("pj", jobs: [4, 5], question: "Willing to work PST hours?"),
        ])
        model.ensureSelection()
        let ng = try #require(model.selectedCluster)
        #expect(ng.clusterId == "ng")
        model.updateDraft(for: ng) { $0.text = "60 days" }
        model.submitSelected()
        let pj = try #require(model.selectedCluster)
        model.updateDraft(for: pj) { d in
            d.perJob = true
            d.perJobAnswers = [4: "Yes", 5: "No"]
        }
        model.submitSelected()
        await model.flushPending()
        let payloads = daemon.sent("answer_question").compactMap(\.answerPayload)
        let ngPayload = try #require(payloads.first { $0.clusterId == "ng" })
        #expect(ngPayload.saveToProfile && !ngPayload.saveToMemory)
        let pjPayload = try #require(payloads.first { $0.clusterId == "pj" })
        #expect(pjPayload.perJobAnswers == [PerJobAnswer(jobId: 4, answer: "Yes"), PerJobAnswer(jobId: 5, answer: "No")])
        #expect(!pjPayload.saveToMemory)
    }

    @Test func inboxZeroTriggersOnceOnTheLastAnswer() async throws {
        let (_, _, model) = await setup([C3Fixtures.cluster("a", jobs: [1]), C3Fixtures.cluster("b", jobs: [2], question: "Notice period?")])
        model.ensureSelection()
        for _ in 0..<2 {
            let c = try #require(model.selectedCluster)
            model.updateDraft(for: c) { $0.text = "answer" }
            model.submitSelected()
        }
        #expect(model.isInboxZero)
        #expect(model.inboxZeroTrigger == 1)
        #expect(model.selectedClusterID == nil)
        await model.flushPending()
    }

    @Test func templatePreviewUsesBlockedJobs() async throws {
        let (_, _, model) = await setup([C3Fixtures.cluster("a", jobs: [2, 3], question: "Why do you want to work here?", companies: [])])
        let c = try #require(model.clusters.first)
        #expect(model.kind(for: c) == .longText)
        #expect(model.jobs(for: c).map(\.company) == ["Ramp", "Notion"])
        #expect(model.companiesLine(c) == "Ramp, Notion")
    }

    @Test func endToEndWithMockDaemon() async throws {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        #expect(await c3WaitUntil(timeout: .seconds(10)) { store.inbox.openCount >= 1 && store.jobs.isLoaded })
        let model = InboxModel(store: store)
        model.undoWindow = .milliseconds(50)
        model.ensureSelection()
        let cluster = try #require(model.selectedCluster)
        let kind = model.kind(for: cluster)
        model.updateDraft(for: cluster) { d in
            switch kind {
            case .yesNo: d.yesNo = true
            case .choice: d.choices = [cluster.options[0]]
            case .number: d.text = "4"
            case .url: d.text = "https://github.com/example"
            case .email: d.text = "me@example.com"
            default: d.text = "Thoughtful answer for {company}"
            }
        }
        #expect(model.submitSelected())
        let memoryBefore = store.library.memoryAnswers.count
        // Daemon resolves the cluster (question_resolved) and saves the answer to memory.
        #expect(await c3WaitUntil(timeout: .seconds(10)) { store.inbox.resolvedToday.contains { $0.clusterID == cluster.clusterId } })
        #expect(store.inbox.cluster(id: cluster.clusterId) == nil)
        if cluster.neverGuessKey == nil {
            #expect(await c3WaitUntil(timeout: .seconds(5)) { store.library.memoryAnswers.count == memoryBefore + 1 })
        }
        await store.stop()
    }
}
