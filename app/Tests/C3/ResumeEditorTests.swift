// ResumeEditorTests.swift — "Edit with Claude" (protocol.md §5.6): the mock agent end to end (load
// the source, ask, accept / reject, save as the next version), what the editor sends (only changed
// segments, the session's earlier requests, the job to tailor for), errors, and tailored copies
// staying out of the grid, the swap menu and the board filter while their outcomes count for the
// resume they came from.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Resume editor", .serialized)
struct ResumeEditorTests {
    private func mockStore() async -> AppStore {
        let daemon = MockDaemon(scenario: .idle, speed: 1)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await c3WaitUntil { store.hasSnapshot && store.jobs.isLoaded && !store.library.resumeVariants.isEmpty }
        return store
    }

    @Test func mockAgentEndToEnd() async throws {
        let store = await mockStore()
        let backend = try #require(store.library.resume(id: 1))
        #expect(backend.canEdit && backend.version == 1)
        let model = ResumeEditorModel(store: store, variantID: 1)
        await model.load()
        #expect(model.phase == .idle && !model.segments.isEmpty && model.messages.first?.role == .claude)
        #expect(!model.canSave)  // nothing changed yet

        model.input = "Tighten every bullet and add a metric"
        await model.send()
        #expect(model.input.isEmpty && model.history == ["Tighten every bullet and add a metric"])
        #expect(!model.pending.isEmpty)
        // The invented number is flagged in the chat and on the change, and isn't taken by Accept all.
        let flagged = try #require(model.pending.first { !$0.unsupportedClaims.isEmpty })
        #expect(model.messages.last?.warning?.contains("30%") == true)
        model.acceptAllGrounded()
        #expect(model.pending.map(\.segmentId) == [flagged.segmentId])
        model.reject(flagged)
        #expect(model.pending.isEmpty && model.text(flagged.segmentId) == flagged.before)
        #expect(model.canSave && !model.changedIDs.isEmpty)

        // A hand edit counts as a change too, and can be undone.
        let first = try #require(model.segments.first?.id)
        model.setText("A. Rao", for: first)
        #expect(model.changedIDs.contains(first))
        model.revert(first)
        #expect(!model.changedIDs.contains(first))

        let resumes = ResumesModel.shared(for: store)
        #expect(await model.save())
        let saved = try #require(model.saved)
        #expect(saved.version == 2)
        _ = await c3WaitUntil { store.library.resume(id: saved.resumeVariantId) != nil }
        let v2 = try #require(store.library.resume(id: saved.resumeVariantId))
        #expect(v2.version == 2 && v2.label == "Backend" && v2.canEdit)
        // Saving selects the new version. Another suite's `FeatureModels.reset()` can swap the shared
        // model out mid-test under a parallel run; the check only means something on the same instance.
        if ResumesModel.shared(for: store) === resumes { #expect(resumes.selectedID == v2.id) }
        #expect(!ResumesModel.shared(for: store).variants.contains { $0.id == 1 })  // the old version is replaced
    }

    @Test func tailoringForAJobSendsTheJobAndReordersSkills() async throws {
        let store = await mockStore()
        let model = ResumeEditorModel(store: store, variantID: 1)
        await model.load()
        let job = try #require(model.tailorCandidates.first)
        model.tailorJobID = job.id
        await model.send()
        #expect(model.messages.contains { $0.role == .user && $0.text.contains(job.company) })
        #expect(model.tailorJobID == nil)  // one request per pick
        #expect(model.phase == .idle)
    }

    @Test func sendsOnlyChangedSegmentsAndHistory() async throws {
        var data = RepositoryData()
        data.resumeVariants = [ResumeVariantItem(id: 7, label: "Backend", filePath: "/tmp/r.pdf", isDefault: true,
                                                 createdAt: Date(), updatedAt: Date(), sourceKind: "html")]
        let (store, daemon, _) = await makeC3Store(data: data)
        let source = ResumeSource(resumeVariantId: 7, kind: .html, fileName: "resume.html",
                                  segments: [ResumeSegment(id: "s1", text: "Asha Rao"), ResumeSegment(id: "s2", text: "Backend engineer.")],
                                  renderer: "Chromium")
        let proposal = ResumeEditProposal(resumeVariantId: 7, summary: "Shorter.", edits: [
            ResumeEdit(segmentId: "s2", before: "Backend engineer.", after: "Payments engineer.", reason: "Lead with payments")],
                                          grounded: true)
        daemon.responder = { command in
            switch command {
            case .getResumeSource: MockCommandHandler.ack(encoding: source)
            case .proposeResumeEdits: MockCommandHandler.ack(encoding: proposal)
            case .saveResumeEdit: MockCommandHandler.ack(encoding: SaveResumeEditResult(resumeVariantId: 8, filePath: "/tmp/r.pdf", version: 2))
            default: .ack(AckPayload())
            }
        }
        let model = ResumeEditorModel(store: store, variantID: 7)
        await model.load()
        model.setText("A. Rao", for: "s1")
        model.input = "Lead with payments"
        await model.send()
        model.input = "Shorter"
        await model.send()
        let asks = daemon.sent.compactMap { if case .proposeResumeEdits(let p) = $0 { p } else { nil } }
        #expect(asks.count == 2)
        #expect(asks[0].working.map(\.segmentId) == ["s1"] && asks[0].history.isEmpty)
        #expect(asks[1].history == ["Lead with payments"])
        // The second suggestion for s2 replaced the first instead of stacking.
        #expect(model.pending.count == 1)
        model.accept(try #require(model.pending.first))
        #expect(await model.save(asNew: true, label: "Payments"))
        let save = try #require(daemon.sent.compactMap { if case .saveResumeEdit(let p) = $0 { p } else { nil } }.last)
        #expect(save.asNew && save.label == "Payments")
        #expect(Set(save.edits.map(\.segmentId)) == ["s1", "s2"])
    }

    @Test func livePreviewFollowsEditsAndSuggestions() async throws {
        var data = RepositoryData()
        data.resumeVariants = [ResumeVariantItem(id: 7, label: "Backend", filePath: "/tmp/r.pdf", isDefault: true,
                                                 createdAt: Date(), updatedAt: Date(), sourceKind: "latex")]
        let (store, daemon, _) = await makeC3Store(data: data)
        daemon.responder = { command in
            switch command {
            case .getResumeSource:
                MockCommandHandler.ack(encoding: ResumeSource(resumeVariantId: 7, kind: .latex, fileName: "r.tex",
                                                              segments: [ResumeSegment(id: "s1", text: "Asha"), ResumeSegment(id: "s2", text: "Go")],
                                                              renderer: "tectonic"))
            case .proposeResumeEdits:
                MockCommandHandler.ack(encoding: ResumeEditProposal(resumeVariantId: 7, summary: "ok", edits: [
                    ResumeEdit(segmentId: "s2", before: "Go", after: "Go, Kafka")], grounded: true))
            case .previewResumeEdit(let p):
                p.edits.isEmpty ? MockCommandHandler.ack(encoding: ResumePreview(filePath: "/tmp/r.pdf", pages: 1))
                    : .error(ErrorPayload(code: .invalidPayload, message: "pdflatex failed:\n! LaTeX Error: File `titlesec.sty' not found."))
            default: .ack(AckPayload())
            }
        }
        let model = ResumeEditorModel(store: store, variantID: 7)
        model.previewDebounce = .milliseconds(20)
        await model.load()
        #expect(model.previewPath == "/tmp/r.pdf")  // the saved PDF until something changes

        // Typing renders once, after the pause, with the changed line only.
        model.setText("A", for: "s1")
        model.setText("A.", for: "s1")
        _ = await c3WaitUntil { !daemon.sent("preview_resume_edit").isEmpty && !model.previewRendering }
        var previews = daemon.sent.compactMap { if case .previewResumeEdit(let p) = $0 { p } else { nil } }
        #expect(previews.count == 1 && previews[0].edits.map(\.text) == ["A."])
        #expect(model.previewError?.contains("titlesec.sty") == true)  // the build log shows in the pane

        // Pending suggestions are in the preview while the toggle is on, and leave it when off.
        model.input = "Add Kafka"
        await model.send()
        _ = await c3WaitUntil { daemon.sent("preview_resume_edit").count == 2 && !model.previewRendering }
        previews = daemon.sent.compactMap { if case .previewResumeEdit(let p) = $0 { p } else { nil } }
        #expect(Set(previews[1].edits.map(\.segmentId)) == ["s1", "s2"])
        model.previewSuggestions = false
        model.revert("s1")
        _ = await c3WaitUntil { daemon.sent("preview_resume_edit").count == 3 && !model.previewRendering }
        previews = daemon.sent.compactMap { if case .previewResumeEdit(let p) = $0 { p } else { nil } }
        #expect(previews[2].edits.isEmpty)
        #expect(model.previewError == nil && model.previewPath == "/tmp/r.pdf")
    }

    @Test func errorsAreShownInPlainWords() async throws {
        var data = RepositoryData()
        data.resumeVariants = [ResumeVariantItem(id: 7, label: "Backend", filePath: "/tmp/r.pdf", createdAt: Date(), updatedAt: Date(),
                                                 sourceKind: "latex")]
        let (store, daemon, _) = await makeC3Store(data: data)
        daemon.responder = { command in
            switch command {
            case .getResumeSource:
                MockCommandHandler.ack(encoding: ResumeSource(resumeVariantId: 7, kind: .latex, fileName: "r.tex",
                                                              segments: [ResumeSegment(id: "s1", text: "x")],
                                                              renderHint: "Install a TeX engine: `brew install tectonic`."))
            case .proposeResumeEdits: .error(ErrorPayload(code: .unavailable, message: "No model is available."))
            default: .ack(AckPayload())
            }
        }
        let model = ResumeEditorModel(store: store, variantID: 7)
        await model.load()
        #expect(model.messages.contains { $0.role == .note && $0.text.contains("tectonic") })
        model.setText("y", for: "s1")
        #expect(!model.canSave)  // nothing can render the PDF here
        model.input = "Shorter"
        await model.send()
        #expect(model.messages.last?.role == .note && model.messages.last?.text == "No model is available.")
        #expect(model.phase == .idle && model.history.isEmpty)
    }

    @Test func tailoredCopiesStayOutOfPickersAndCountForTheirParent() async throws {
        let base = Date()
        var data = RepositoryData()
        data.resumeVariants = [
            ResumeVariantItem(id: 1, label: "Backend", filePath: "/tmp/b.pdf", isDefault: true, createdAt: base, updatedAt: base, sourceKind: "docx"),
            ResumeVariantItem(id: 2, label: "ML", filePath: "/tmp/m.pdf", createdAt: base, updatedAt: base),
            ResumeVariantItem(id: 9, label: "Backend · Stripe", filePath: "/tmp/b2.pdf", createdAt: base, updatedAt: base,
                              sourceKind: "docx", parentID: 1, tailoredForJobID: 5, autoTailor: false),
        ]
        var job = C3Fixtures.job(id: 5, company: "Stripe", state: .submitted)
        job.resumeVariantID = 9
        job.submittedAt = base
        job.status = .interview
        data.jobs = [job]
        let (store, _, _) = await makeC3Store(data: data)
        #expect(store.library.baseResumes.map(\.id).sorted() == [1, 2])
        #expect(store.library.tailoredCopies(of: 1).map(\.id) == [9])
        let copy = try #require(store.library.resume(id: 9))
        #expect(copy.isTailored && !copy.canEdit)
        let resumes = ResumesModel(store: store)
        #expect(resumes.variants.map(\.id) == [1, 2])
        #expect(resumes.jobs(usedBy: try #require(store.library.resume(id: 1))).map(\.id) == [5])
        let stats = StatsCalculator.compute(jobs: store.jobs.all, variants: store.library.resumeVariants, now: base)
        #expect(stats.byVariant.map(\.variantID) == [1] && stats.byVariant.first?.interviews == 1)
    }
}
