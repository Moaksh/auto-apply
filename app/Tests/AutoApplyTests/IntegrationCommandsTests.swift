// IntegrationCommandsTests.swift — commands added at integration time (apply_anyway,
// update_job_notes, set_application_resume) through the store and the MockDaemon, plus the
// set_status Undo for fresh submissions.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("Integration commands")
struct IntegrationCommandsTests {
    func makeStore(_ daemon: StubDaemon = StubDaemon(), jobs: [JobItem] = []) -> AppStore {
        var data = RepositoryData()
        data.jobs = jobs
        let store = AppStore(client: daemon, repository: InMemoryRepository(data))
        store.commandTimeout = .milliseconds(100)
        store.jobs.replaceAll(jobs)
        return store
    }

    @Test func applyAnywayIsOptimisticAndRollsBack() async {
        let daemon = StubDaemon()
        var job = Samples.job(id: 1, state: .skipped)
        job.stateReason = "below_threshold"
        let store = makeStore(daemon, jobs: [job])
        daemon.responder = { _ in .error(ErrorPayload(code: .illegalTransition, message: "not skipped")) }
        #expect(await store.applyAnyway(applicationID: 1) == false)
        #expect(store.jobs.job(id: 1)?.state == .skipped)
        #expect(store.jobs.job(id: 1)?.stateReason == "below_threshold")
        daemon.responder = { _ in .ack(AckPayload()) }
        #expect(await store.applyAnyway(applicationID: 1))
        #expect(store.jobs.job(id: 1)?.state == .queued)
        guard case .applyAnyway(let p)? = daemon.sent.last else { Issue.record("expected apply_anyway"); return }
        #expect(p.applicationId == 1)
    }

    @Test func updateJobNotesTrimsAndClears() async {
        let daemon = StubDaemon()
        daemon.responder = { _ in .ack(AckPayload()) }
        let store = makeStore(daemon, jobs: [Samples.job(id: 3)])
        #expect(await store.updateJobNotes(jobID: 3, notes: "  Referred by Sam \n"))
        #expect(store.jobs.job(id: 3)?.notes == "Referred by Sam")
        guard case .updateJobNotes(let p)? = daemon.sent.last else { Issue.record("expected update_job_notes"); return }
        #expect(p.jobId == 3 && p.notes == "Referred by Sam")
        #expect(await store.updateJobNotes(jobID: 3, notes: "   "))
        #expect(store.jobs.job(id: 3)?.notes == nil)
        guard case .updateJobNotes(let cleared)? = daemon.sent.last else { Issue.record("expected update_job_notes"); return }
        #expect(cleared.notes == nil, "whitespace-only clears")
    }

    @Test func setApplicationResumeRollsBackOnConflict() async {
        let daemon = StubDaemon()
        var job = Samples.job(id: 4, state: .awaitingReview)
        job.resumeVariantID = 1
        let store = makeStore(daemon, jobs: [job])
        daemon.responder = { _ in .error(ErrorPayload(code: .conflict, message: "filling")) }
        #expect(await store.setApplicationResume(applicationID: 4, resumeVariantID: 2) == false)
        #expect(store.jobs.job(id: 4)?.resumeVariantID == 1)
        daemon.responder = { _ in .ack(AckPayload(result: ["requeued": .bool(true)])) }
        #expect(await store.setApplicationResume(applicationID: 4, resumeVariantID: 2))
        #expect(store.jobs.job(id: 4)?.resumeVariantID == 2)
    }

    @Test func setStatusOffersUndoBackToAppliedForFreshSubmissions() async {
        let daemon = StubDaemon()
        daemon.responder = { _ in .ack(AckPayload()) }
        let store = makeStore(daemon, jobs: [Samples.job(id: 5, state: .submitted, status: nil, submittedAt: Date())])
        #expect(await store.setStatus(applicationID: 5, status: .interview))
        #expect(store.toasts.current?.actionTitle == "Undo", "nil status reads as Applied, so Undo is offered")
    }

    @Test func companySuggestionsAddAndDismiss() async throws {
        let mock = MockDaemon(scenario: .idle)
        _ = try await mock.connect()
        let pending = mock.world.repository.read { $0.companySuggestions.filter { $0.status == .pending } }
        #expect(pending.count == 2)
        let library = await MainActor.run { () -> LibraryStore in
            let l = LibraryStore()
            l.companySuggestions = mock.world.repository.read { $0.companySuggestions }
            return l
        }
        #expect(await MainActor.run { library.pendingSuggestionCount } == 2)
        #expect(await MainActor.run { library.autoAddedCompanies.map(\.companyName) } == ["Plivo"])

        let add = try await mock.request(.acceptCompanySuggestion(AcceptCompanySuggestionPayload(suggestionId: pending[0].id)), timeout: .seconds(2))
        guard case .ack = add.event else { Issue.record("expected ack, got \(add.event)"); return }
        let dismiss = try await mock.request(.dismissCompanySuggestion(DismissCompanySuggestionPayload(suggestionId: pending[1].id)), timeout: .seconds(2))
        guard case .ack = dismiss.event else { Issue.record("expected ack, got \(dismiss.event)"); return }
        let statuses = mock.world.repository.read { d in d.companySuggestions.map(\.status) }
        #expect(statuses == [.accepted, .dismissed, .auto])
        do {
            _ = try await mock.request(.dismissCompanySuggestion(DismissCompanySuggestionPayload(suggestionId: 999)), timeout: .seconds(2))
            Issue.record("expected not_found")
        } catch let DaemonClientError.daemon(e) {
            #expect(e.code == .notFound)
        }
        await mock.disconnect()
    }

    @Test func mockDaemonHonoursNewCommands() async throws {
        let mock = MockDaemon(scenario: .idle)
        _ = try await mock.connect()
        let skipped = mock.world.repository.read { $0.jobs.first { $0.state == .skipped && $0.applicationID != nil } }
        let queued = mock.world.repository.read { $0.jobs.first { $0.state == .queued && $0.applicationID != nil } }
        if let skipped, let appID = skipped.applicationID {
            let reply = try await mock.request(.applyAnyway(ApplyAnywayPayload(applicationId: appID)), timeout: .seconds(2))
            guard case .ack = reply.event else { Issue.record("expected ack, got \(reply.event)"); return }
            #expect(await waitUntil { mock.world.repository.read { $0.jobs.first { $0.id == skipped.id }?.state } == .queued })
        }
        if let queued, let appID = queued.applicationID {
            // queued is not skipped: illegal.
            do {
                _ = try await mock.request(.applyAnyway(ApplyAnywayPayload(applicationId: appID)), timeout: .seconds(2))
                Issue.record("expected an illegal_transition error")
            } catch let DaemonClientError.daemon(e) {
                #expect(e.code == .illegalTransition)
            }
            let notes = try await mock.request(.updateJobNotes(UpdateJobNotesPayload(jobId: queued.id, notes: "hi")), timeout: .seconds(2))
            guard case .ack = notes.event else { Issue.record("expected ack"); return }
            #expect(mock.world.repository.read { $0.jobs.first { $0.id == queued.id }?.notes } == "hi")
        }
        await mock.disconnect()
    }
}
