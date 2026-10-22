// InboxAIDraftTests.swift — the agent's stored draft starts in the editor (and the "drafted
// something" line never shows without one), and "Draft with AI" / "Tell the agent what to
// change…": draft, revise with instructions, Undo, errors, the not-grounded warning, which
// questions offer it, that nothing is ever answered by it, and the mock agent end to end.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Inbox Draft with AI", .serialized)
struct InboxAIDraftTests {
    nonisolated static let asyncQuestion = "Tell us about your experience working in an async and/or remote environment."

    private func setup(_ clusters: [QuestionCluster],
                       responder: @escaping @Sendable (Command) -> DaemonEvent? = { _ in .ack(AckPayload()) })
        async -> (AppStore, C3StubDaemon, InboxModel) {
        var data = RepositoryData()
        data.jobs = [1, 2, 3].map { C3Fixtures.job(id: $0, company: ["Stripe", "Ramp", "Notion"][$0 - 1], state: .needsYou) }
        let (store, daemon, _) = await makeC3Store(data: data, clusters: clusters)
        daemon.responder = responder
        let model = InboxModel(store: store)
        model.undoWindow = .milliseconds(150)
        _ = await c3WaitUntil { store.inbox.openCount == clusters.count }
        model.ensureSelection()
        return (store, daemon, model)
    }

    nonisolated static func longText(_ id: String = "async", suggestion: String? = nil, confidence: Double? = nil) -> QuestionCluster {
        var c = C3Fixtures.cluster(id, jobs: [1], question: asyncQuestion, fieldType: .textarea)
        c.reason = .lowConfidence
        c.suggestedAnswer = suggestion
        c.suggestedConfidence = confidence
        return c
    }

    nonisolated static func result(_ answer: String, cluster: String = "async", grounded: Bool = true, claims: [String] = []) -> DaemonEvent {
        MockCommandHandler.ack(encoding: DraftAnswerResult(clusterId: cluster, jobId: 1, answer: answer, grounded: grounded,
                                                           unsupportedClaims: claims, sources: ["Profile", "Resume"],
                                                           tokensIn: 900, tokensOut: 80))
    }

    // MARK: The stored draft (the bug)

    @Test func storedDraftStartsInTheEditorForTypedAnswersOnly() {
        let text = Self.longText(suggestion: "  I have worked remotely for three years.  ", confidence: 0.55)
        #expect(AnswerDraft(cluster: text).text == "I have worked remotely for three years.")
        #expect(AnswerDraft.prefill(for: text) == "I have worked remotely for three years.")

        var short = C3Fixtures.cluster("s", jobs: [1], question: "Preferred name?")
        short.suggestedAnswer = "Asha"
        #expect(AnswerDraft(cluster: short).text == "Asha")

        // A guessed option stays one click away instead of pre-picked.
        var choice = C3Fixtures.cluster("c", jobs: [1], question: "Willing to work PST hours?", fieldType: .boolean)
        choice.suggestedAnswer = "Yes"
        #expect(AnswerDraft(cluster: choice).text.isEmpty && AnswerDraft(cluster: choice).yesNo == nil)
        #expect(AnswerDraft.prefill(for: choice) == nil)

        // Nothing stored: an empty editor (and no "drafted something" claim; that copy is gone).
        #expect(AnswerDraft(cluster: Self.longText()).text.isEmpty)
        #expect(AnswerDraft(cluster: Self.longText(suggestion: "   ")).text.isEmpty)
    }

    @Test func noDraftNoClaimInTheComposerSource() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AutoApply/Features/Inbox/InboxView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("drafted something but wasn't sure"), "the line claimed a draft that wasn't stored")
    }

    @Test func answeringTheStoredDraftSendsIt() async throws {
        let (_, daemon, model) = await setup([Self.longText(suggestion: "I have worked remotely for three years.")])
        #expect(model.submitSelected())
        #expect(await c3WaitUntil { daemon.sent("answer_question").count == 1 })
        #expect(daemon.sent("answer_question").first?.answerPayload?.answer == "I have worked remotely for three years.")
    }

    // MARK: Which questions offer it

    @Test func offeredForTypedQuestionsOnly() async {
        let (_, _, model) = await setup([])
        #expect(model.supportsAIDraft(Self.longText()))
        #expect(model.supportsAIDraft(C3Fixtures.cluster("t", jobs: [1], question: "Preferred name?")))
        #expect(!model.supportsAIDraft(C3Fixtures.cluster("ng", jobs: [1], question: "Notice period?", neverGuessKey: "notice_period")))
        var always = Self.longText("aa")
        always.reason = .alwaysAsk
        #expect(!model.supportsAIDraft(always))
        #expect(!model.supportsAIDraft(C3Fixtures.cluster("ch", jobs: [1], question: "Level?", options: ["Junior", "Senior"])))
        #expect(!model.supportsAIDraft(C3Fixtures.cluster("b", jobs: [1], question: "Willing to relocate?", fieldType: .boolean)))
        #expect(!model.supportsAIDraft(C3Fixtures.cluster("u", jobs: [1], question: "Portfolio URL?", fieldType: .url)))
        var action = C3Fixtures.cluster("a", jobs: [1], question: "Create an account")
        action.kind = "action"
        #expect(!model.supportsAIDraft(action))
    }

    // MARK: Draft, revise, undo

    @Test func draftReviseUndoAndNeverAnswers() async throws {
        final class Box: @unchecked Sendable { var next = "" }
        let box = Box()
        let (_, daemon, model) = await setup([Self.longText()]) { command in
            if case .draftAnswer = command { return Self.result(box.next) }
            return .ack(AckPayload())
        }
        let cluster = try #require(model.selectedCluster)

        // Draft with AI fills the empty editor; nothing to undo yet.
        box.next = "At Razorpay I worked across three time zones and wrote everything down."
        await model.draftWithAI(for: cluster)
        guard case .draftAnswer(let first)? = daemon.sent("draft_answer").last else { Issue.record("no draft_answer"); return }
        #expect(first.clusterId == "async" && first.instructions == nil && first.currentAnswer == nil)
        #expect(model.draft(for: cluster).text == box.next)
        #expect(model.aiDraft(for: cluster).versions.isEmpty)
        #expect(model.aiDraft(for: cluster).result?.sources == ["Profile", "Resume"])
        #expect(model.aiDraft(for: cluster).phase == .idle)

        // The user edits, then asks for a change: the editor's text and the instruction go out.
        model.updateDraft(for: cluster) { $0.text = "My own words about async work." }
        model.updateAIDraft(for: cluster) { $0.instruction = "  Make it shorter " }
        box.next = "Async work suits me."
        await model.reviseWithAI(for: cluster)
        guard case .draftAnswer(let second)? = daemon.sent("draft_answer").last else { Issue.record("no revise"); return }
        #expect(second.instructions == "Make it shorter")
        #expect(second.currentAnswer == "My own words about async work.")
        #expect(model.draft(for: cluster).text == "Async work suits me.")
        let ai = model.aiDraft(for: cluster)
        #expect(ai.history == ["Make it shorter"] && ai.instruction.isEmpty)
        #expect(ai.versions == ["My own words about async work."])

        // A blank instruction sends nothing.
        model.updateAIDraft(for: cluster) { $0.instruction = "   " }
        await model.reviseWithAI(for: cluster)
        #expect(daemon.sent("draft_answer").count == 2)

        // Undo goes back one version, then there's nothing left.
        #expect(model.undoAIDraft(for: cluster))
        #expect(model.draft(for: cluster).text == "My own words about async work.")
        #expect(model.aiDraft(for: cluster).result == nil)
        #expect(!model.undoAIDraft(for: cluster))

        // The same instruction twice is kept once (newest last).
        model.updateAIDraft(for: cluster) { $0.instruction = "More casual" }
        await model.reviseWithAI(for: cluster)
        model.updateAIDraft(for: cluster) { $0.instruction = "Make it shorter" }
        await model.reviseWithAI(for: cluster)
        #expect(model.aiDraft(for: cluster).history == ["More casual", "Make it shorter"])

        // Never answered by itself.
        try await Task.sleep(for: .milliseconds(200))
        #expect(daemon.sent("answer_question").isEmpty)
        #expect(model.clusters.map(\.clusterId) == ["async"])
    }

    @Test func instructionOnAnEmptyEditorIsAGuidedFirstDraft() async throws {
        let (_, daemon, model) = await setup([Self.longText()]) { command in
            if case .draftAnswer = command { return Self.result("I led a team of 5 across time zones.") }
            return .ack(AckPayload())
        }
        let cluster = try #require(model.selectedCluster)
        model.updateAIDraft(for: cluster) { $0.instruction = "I led a team of 5" }
        await model.reviseWithAI(for: cluster)
        guard case .draftAnswer(let p)? = daemon.sent("draft_answer").last else { Issue.record("no draft"); return }
        #expect(p.instructions == "I led a team of 5" && p.currentAnswer == nil)
        #expect(model.draft(for: cluster).text == "I led a team of 5 across time zones.")
    }

    @Test func errorsKeepTheTextAndSayWhy() async throws {
        let (_, _, model) = await setup([Self.longText()]) { command in
            if case .draftAnswer = command {
                return .error(ErrorPayload(code: .invalidPayload, message: "The agent never guesses this.",
                                           details: ["reason": .string("never_guess")]))
            }
            return .ack(AckPayload())
        }
        let cluster = try #require(model.selectedCluster)
        model.updateDraft(for: cluster) { $0.text = "Mine" }
        model.updateAIDraft(for: cluster) { $0.instruction = "Shorter" }
        await model.reviseWithAI(for: cluster)
        let ai = model.aiDraft(for: cluster)
        #expect(ai.errorMessage == "The agent never guesses this.")
        #expect(ai.instruction == "Shorter", "the instruction stays so it can be retried")
        #expect(ai.history.isEmpty && ai.versions.isEmpty)
        #expect(model.draft(for: cluster).text == "Mine")
        #expect(InboxModel.aiDraftErrorMessage(.timeout(commandID: "x")).contains("too long"))
        #expect(InboxModel.aiDraftErrorMessage(.notConnected).contains("Can't reach the agent"))
    }

    @Test func notGroundedWarnsUntilTheClaimIsGone() async throws {
        let (_, _, model) = await setup([Self.longText()]) { command in
            if case .draftAnswer = command {
                return Self.result("At Google I led 12 engineers.", grounded: false, claims: ["Google", "12"])
            }
            return .ack(AckPayload())
        }
        let cluster = try #require(model.selectedCluster)
        await model.draftWithAI(for: cluster)
        let text = model.draft(for: cluster).text
        #expect(model.aiDraft(for: cluster).unsupportedClaims(in: text) == ["Google", "12"])
        model.updateDraft(for: cluster) { $0.text = "At Google I led the platform team." }
        #expect(model.aiDraft(for: cluster).unsupportedClaims(in: model.draft(for: cluster).text) == ["Google"])
        model.updateDraft(for: cluster) { $0.text = "I led the platform team." }
        #expect(model.aiDraft(for: cluster).unsupportedClaims(in: model.draft(for: cluster).text).isEmpty)
    }

    @Test func aReplyForAnAnsweredQuestionIsDropped() async throws {
        let (_, daemon, model) = await setup([Self.longText(), Self.longText("other")]) { command in
            if case .draftAnswer = command { return Self.result("Late draft") }
            return .ack(AckPayload())
        }
        model.select("async")
        let cluster = try #require(model.selectedCluster)
        model.updateDraft(for: cluster) { $0.text = "Final" }
        model.submitSelected()  // leaves the list now
        await model.draftWithAI(for: cluster)
        #expect(daemon.sent("draft_answer").isEmpty, "not offered for a question that's gone")
        #expect(model.aiDrafts["async"] == nil)
    }

    // MARK: Mock agent

    @Test func mockAgentDraftsRevisesAndRefuses() async throws {
        let daemon = MockDaemon(scenario: .idle, speed: 1)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await c3WaitUntil { store.hasSnapshot && store.jobs.isLoaded && !store.inbox.clusters.isEmpty }
        let model = InboxModel(store: store)
        let why = try #require(store.inbox.clusters.first { $0.clusterId == "c_why" })
        await model.draftWithAI(for: why)
        let first = try #require(model.aiDraft(for: why).result)
        #expect(!first.answer.isEmpty && first.grounded && first.sources.first == "Profile")
        #expect(model.draft(for: why).text == first.answer)

        model.updateAIDraft(for: why) { $0.instruction = "Add a metric" }
        await model.reviseWithAI(for: why)
        let revised = try #require(model.aiDraft(for: why).result)
        #expect(!revised.grounded && revised.unsupportedClaims == ["30%"])
        #expect(model.aiDraft(for: why).unsupportedClaims(in: model.draft(for: why).text) == ["30%"])
        #expect(model.undoAIDraft(for: why) && model.draft(for: why).text == first.answer)

        // The mock refuses never-guess questions like the agent.
        let locked = MockScripts.cluster(MockScripts.clusterTemplates[1], jobs: Array(store.jobs.all.prefix(1)), now: Date(),
                                         questionIDBase: 9_000)
        #expect(locked.neverGuessKey != nil && !model.supportsAIDraft(locked))
        daemon.world.openCluster(locked)
        switch await store.draftAnswer(clusterID: locked.clusterId) {
        case .failure(.daemon(let p)): #expect(p.code == .invalidPayload && p.details?["reason"] == .string("never_guess"))
        default: Issue.record("expected a never-guess refusal")
        }
        await store.stop()
    }
}
