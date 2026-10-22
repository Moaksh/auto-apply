// InboxGhostDraftTests.swift — inline drafts as ghost text (docs/DESIGN_AWARD_VISION.md 1D): shown
// only over an empty editor, Tab takes it, typing replaces it, Esc clears it (and it comes back
// on request), a draft that isn't grounded needs Tab then a confirm (or ⌥Tab), never for choices,
// yes/no or per-job answers, and the provenance chip's words.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Inbox ghost drafts", .serialized)
struct InboxGhostDraftTests {
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

    private static func stored(_ id: String = "s", _ text: String = "Asha", fieldType: FieldType = .text, jobs: [Int] = [1, 2]) -> QuestionCluster {
        var c = C3Fixtures.cluster(id, jobs: jobs, question: "Preferred name?", fieldType: fieldType)
        c.reason = .lowConfidence
        c.suggestedAnswer = text
        c.suggestedConfidence = 0.6
        return c
    }

    @Test func shownOverAnEmptyEditorTabTakesItTypingReplacesIt() async throws {
        let (_, _, model) = await setup([Self.stored()])
        let c = try #require(model.selectedCluster)
        // Shown: tinted text over an empty editor, labelled as the agent's.
        let ghost = try #require(model.ghost(for: c))
        #expect(ghost.text == "Asha" && ghost.grounded && ghost.chip == "Agent's draft · 60% sure")
        #expect(model.draft(for: c).text.isEmpty)

        // Typing replaces it; clearing the box brings it back.
        model.updateDraft(for: c) { $0.text = "A" }
        #expect(model.ghost(for: c) == nil)
        #expect(model.acceptGhost(for: c) == .nothing, "Tab does nothing to typed text")
        #expect(model.draft(for: c).text == "A")
        model.updateDraft(for: c) { $0.text = "  " }
        #expect(model.ghost(for: c)?.text == "Asha")

        // Tab takes it into the editor.
        #expect(model.acceptGhost(for: c) == .accepted)
        #expect(model.draft(for: c).text == "Asha" && model.ghost(for: c) == nil)
    }

    @Test func escClearsItAndRestoreBringsItBack() async throws {
        let (_, _, model) = await setup([Self.stored()])
        let c = try #require(model.selectedCluster)
        model.dismissGhost(for: c)
        #expect(model.ghost(for: c) == nil && model.aiDraft(for: c).ghostDismissed)
        #expect(model.acceptGhost(for: c) == .nothing)
        model.restoreGhost(for: c)
        #expect(model.ghost(for: c)?.text == "Asha")
    }

    @Test func ungroundedNeedsTabThenConfirm() async throws {
        let (_, _, model) = await setup([InboxAIDraftTests.longText()]) { command in
            if case .draftAnswer = command {
                return InboxAIDraftTests.result("At Google I led 12 engineers.", grounded: false, claims: ["Google", "12"])
            }
            return .ack(AckPayload())
        }
        let c = try #require(model.selectedCluster)
        await model.draftWithAI(for: c)
        let ghost = try #require(model.ghost(for: c))
        #expect(!ghost.grounded && ghost.chip == "Draft · not from your facts")
        #expect(GhostDraftBar.warning(ghost, confirming: false) == "Not in your facts: Google, 12.")

        // First Tab: only the warning. Typing cancels the confirm; the next Tab starts over.
        #expect(model.acceptGhost(for: c) == .needsConfirmation)
        #expect(model.draft(for: c).text.isEmpty && model.aiDraft(for: c).confirmingUngrounded)
        model.updateDraft(for: c) { $0.text = "x" }
        #expect(!model.aiDraft(for: c).confirmingUngrounded)
        model.updateDraft(for: c) { $0.text = "" }
        #expect(model.acceptGhost(for: c) == .needsConfirmation)
        // Second Tab takes it, and the taken text keeps warning about its claims.
        #expect(model.acceptGhost(for: c) == .accepted)
        #expect(model.draft(for: c).text == "At Google I led 12 engineers.")
        #expect(!model.aiDraft(for: c).resultIsGhost)
        #expect(model.aiDraft(for: c).unsupportedClaims(in: model.draft(for: c).text) == ["Google", "12"])
    }

    @Test func optionTabTakesAnUngroundedDraftInOneDeliberateStep() async throws {
        let (_, _, model) = await setup([InboxAIDraftTests.longText()]) { command in
            if case .draftAnswer = command { return InboxAIDraftTests.result("I led 12 engineers.", grounded: false, claims: ["12"]) }
            return .ack(AckPayload())
        }
        let c = try #require(model.selectedCluster)
        await model.draftWithAI(for: c)
        #expect(model.acceptGhost(for: c, force: true) == .accepted)
        #expect(model.draft(for: c).text == "I led 12 engineers.")
    }

    @Test func anAIDraftOverTheStoredGhostReplacesItAndUndoRestoresTheEarlierGhost() async throws {
        final class Box: @unchecked Sendable { var next = "" }
        let box = Box()
        let (_, daemon, model) = await setup([Self.stored("s", "Asha K.", fieldType: .text)]) { command in
            if case .draftAnswer = command { return InboxAIDraftTests.result(box.next, cluster: "s") }
            return .ack(AckPayload())
        }
        let c = try #require(model.selectedCluster)
        box.next = "Asha"
        await model.draftWithAI(for: c)
        #expect(model.ghost(for: c)?.text == "Asha")
        #expect(model.ghost(for: c)?.source == .drafted(sources: ["Profile", "Resume"]))
        // Rewriting the ghost sends the ghost's text, and the answer comes back as a ghost.
        box.next = "Asha Kumar"
        model.updateAIDraft(for: c) { $0.instruction = "Use my full name" }
        await model.reviseWithAI(for: c)
        guard case .draftAnswer(let p)? = daemon.sent("draft_answer").last else { Issue.record("no rewrite"); return }
        #expect(p.currentAnswer == "Asha" && p.instructions == "Use my full name")
        #expect(model.ghost(for: c)?.text == "Asha Kumar" && model.draft(for: c).text.isEmpty)
        #expect(model.aiDraft(for: c).canUndo)
        #expect(model.undoAIDraft(for: c))
        #expect(model.ghost(for: c)?.text == "Asha")
        #expect(!model.aiDraft(for: c).canUndo)
        // Esc then a new draft: the ghost is back.
        model.dismissGhost(for: c)
        await model.draftWithAI(for: c)
        #expect(model.ghost(for: c) != nil)
    }

    @Test func neverForChoicesYesNoOrPerJob() async throws {
        var yesNo = Self.stored("yn", "Yes", fieldType: .boolean)
        yesNo.canonicalQuestion = "Willing to relocate?"
        var choice = C3Fixtures.cluster("ch", jobs: [1], question: "Level?", options: ["Junior", "Senior"])
        choice.suggestedAnswer = "Senior"
        let (_, _, model) = await setup([Self.stored(), yesNo, choice])
        #expect(model.ghost(for: yesNo) == nil)
        #expect(model.ghost(for: choice) == nil)
        let c = try #require(model.clusters.first { $0.clusterId == "s" })
        model.updateDraft(for: c) { $0.perJob = true }
        #expect(model.ghost(for: c) == nil)
    }

    @Test func chipWords() {
        func drafted(_ sources: [String], grounded: Bool = true) -> String {
            GhostDraft(text: "x", source: .drafted(sources: sources), grounded: grounded, unsupportedClaims: []).chip
        }
        #expect(drafted(["Profile"]) == "Draft · from your profile")
        #expect(drafted(["Profile", "Resume", "Story: Payments migration"]) == "Draft · from your profile, your resume and Story: Payments migration")
        #expect(drafted([]) == "Draft · from your facts")
        #expect(drafted(["Profile"], grounded: false) == "Draft · not from your facts")
        #expect(GhostDraft(text: "x", source: .stored(confidence: nil), grounded: true, unsupportedClaims: []).chip == "Agent's draft")
    }
}
