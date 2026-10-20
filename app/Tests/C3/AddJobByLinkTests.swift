// AddJobByLinkTests.swift — "Add job by link": link validation, the ⌘K row for a pasted link,
// and the mock daemon's `add_job_url` (new job queued; same link again is not duplicated).
import Testing
@testable import AutoApply

@Suite("Add job by link")
struct AddJobLinkTests {
    @Test func validatesLinks() {
        #expect(AddJobLink.problem("https://jobs.lever.co/acme/1") == nil)
        #expect(AddJobLink.problem("ats.rippling.com/alaan-careers/jobs/x") == nil)
        #expect(AddJobLink.problem("") != nil)
        #expect(AddJobLink.problem("hello") != nil)
        #expect(AddJobLink.problem("https://www.linkedin.com/jobs/view/1")?.contains("LinkedIn") == true)
        #expect(AddJobLink.isLink("https://boards.greenhouse.io/stripe/jobs/1"))
        #expect(!AddJobLink.isLink("stripe backend"))
    }

    @Test func mockDaemonQueuesAndDedupes() async throws {
        let daemon = MockDaemon(scenario: .idle, speed: 100)
        try await daemon.connect()
        let payload = AddJobUrlPayload(url: "https://jobs.ashbyhq.com/ramp/123", title: "Platform Engineer", company: "Ramp")
        let first = try await daemon.requestResult(.addJobUrl(payload), as: AppStore.AddedJob.self)
        #expect(first.created && first.company == "Ramp" && first.title == "Platform Engineer")
        try await Task.sleep(for: .milliseconds(50))
        let again = try await daemon.requestResult(.addJobUrl(payload), as: AppStore.AddedJob.self)
        #expect(!again.created && again.jobId == first.jobId && again.state == .queued)
        await #expect(throws: DaemonClientError.self) {
            _ = try await daemon.request(.addJobUrl(AddJobUrlPayload(url: "https://linkedin.com/jobs/view/9")), timeout: .seconds(1))
        }
    }
}

@MainActor
@Suite("Add job by link · palette", .serialized)
struct AddJobPaletteTests {
    @Test func pastedLinkOffersAddThisJobFirst() async throws {
        let (store, _, _) = await makeC3Store(data: RepositoryData(), clusters: [])
        let model = PaletteModel(store: store)
        model.query = "https://jobs.lever.co/acme/42"
        let first = try #require(model.results.first)
        #expect(first.title == "Add this job" && first.kind == .addJobLink("https://jobs.lever.co/acme/42"))
        #expect(await model.run(first))
        #expect(store.router.isAddJobPresented && store.router.addJobSeed == "https://jobs.lever.co/acme/42")
    }
}
