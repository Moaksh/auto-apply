// JobDetailTests.swift — factor ordering, skipped banner, status actions, copy-all text,
// timeline merging, screenshots, the answer loader.
import Foundation
import Testing
@testable import AutoApply

@Suite("C2 · Job detail")
struct JobDetailTests {
    @Test func factorsFollowSpecOrderThenAlphabetical() {
        let f = JobDetailRules.orderedFactors(["domain": 90, "zeta": 50, "skills": 95, "salary": 130, "alpha_fit": 40, "location": 100, "seniority": 85])
        #expect(f.map(\.name) == ["Skills", "Seniority", "Location", "Salary", "Domain", "Alpha Fit", "Zeta"])
        #expect(f.first { $0.name == "Salary" }?.value == 100, "clamped to 0…100")
    }

    @Test func skippedBanner() {
        let below = C2.job(id: 1, state: .skipped, score: 64, skipReason: "below_threshold")
        #expect(JobDetailRules.skippedBanner(below, threshold: 70) == "Skipped · below threshold (64 < 70)")
        let kw = C2.job(id: 2, state: .skipped, score: 88, skipReason: "excluded_keyword:crypto")
        #expect(JobDetailRules.skippedBanner(kw, threshold: 70) == "Skipped · excluded keyword · crypto")
        #expect(JobDetailRules.skippedBanner(C2.job(id: 3, state: .queued), threshold: 70) == nil)
    }

    @Test func statusActionsMirrorTheStateMachine() {
        #expect(JobDetailRules.statusActions(for: C2.job(id: 1, state: .submitted, status: .applied)).first == .setStatus(.assessment))
        #expect(JobDetailRules.statusActions(for: C2.job(id: 1, state: .submitted, status: .applied)).count == 5)
        #expect(JobDetailRules.statusActions(for: C2.job(id: 1, state: .failed)) == [.retry])
        #expect(JobDetailRules.statusActions(for: C2.job(id: 1, state: .unknownVerify)) == [.resolveSubmitted, .resolveFailed])
        #expect(JobDetailRules.statusActions(for: C2.job(id: 1, state: .awaitingReview)) == [.approve, .reject])
        #expect(JobDetailRules.statusActions(for: C2.job(id: 1, state: .queued)).isEmpty, "agent-owned")
        #expect(JobDetailRules.statusActions(for: C2.job(id: 1, state: .skipped)) == [.applyAnyway], "user-only skipped → queued")
    }

    @Test func headerActionsFollowTheJobState() {
        typealias A = JobDetailRules.HeaderAction
        func actions(_ state: AppState) -> [A] {
            JobDetailRules.headerActions(for: C2.job(id: 1, state: state))
        }
        #expect(actions(.awaitingReview) == [.approve, .skip])
        #expect(actions(.needsYou) == [], "questions are answered in the Questions tab, not from the header")
        #expect(actions(.failed) == [.retry])
        #expect(actions(.skipped) == [.applyAnyway])
        #expect(actions(.unknownVerify) == [.resolveSent, .resolveNotSent])
        for state in [AppState.queued, .discovered, .scored, .prepping, .filling, .submitting, .submitted] {
            #expect(actions(state).isEmpty, "\(state) has no header action")
        }
        // Actions that need an application row disappear without one.
        var bare = C2.job(id: 2, state: .awaitingReview)
        bare.applicationID = nil
        #expect(JobDetailRules.headerActions(for: bare).isEmpty)
        bare.state = .failed
        #expect(JobDetailRules.headerActions(for: bare).isEmpty)
    }

    @Test func headerActionPresentation() {
        typealias A = JobDetailRules.HeaderAction
        #expect(A.approve.title == "Approve & send")
        #expect(A.resolveSent.title == "It was sent" && A.resolveNotSent.title == "It wasn't sent")
        #expect(A.approve.shortcut == .submit && AppShortcut.submit.displayString == "⌘↵")
        #expect(A.skip.shortcut == nil)
        // One accent-filled button per state.
        for state in AppState.allCases {
            let primaries = JobDetailRules.headerActions(for: C2.job(id: 1, state: state)).filter(\.isPrimary)
            #expect(primaries.count <= 1, "\(state)")
        }
        #expect(A.approve.needsDaemon)
    }

    @Test func queuedShowsANoteInsteadOfAButton() {
        #expect(JobDetailRules.headerNote(for: C2.job(id: 1, state: .queued)) == "Queued · next run")
        #expect(JobDetailRules.headerNote(for: C2.job(id: 1, state: .awaitingReview)) == nil)
    }

    @Test func openClustersAreThoseBlockingTheJob() {
        let at = Samples.now
        let clusters = [
            QuestionCluster(clusterId: "a", canonicalQuestion: "Why?", jobIds: [1, 2], jobCount: 2, createdAt: at),
            QuestionCluster(clusterId: "b", canonicalQuestion: "Start?", jobIds: [3], jobCount: 1, createdAt: at),
            QuestionCluster(clusterId: "c", canonicalQuestion: "PST?", jobIds: [2, 3], jobCount: 2, createdAt: at),
        ]
        #expect(JobDetailRules.openClusters(forJob: 2, in: clusters).map(\.clusterId) == ["a", "c"])
        #expect(JobDetailRules.openClusters(forJob: 9, in: clusters).isEmpty)
    }

    @Test func statusMenuOnlyOffersBoardMoves() {
        #expect(JobDetailRules.menuActions(for: C2.job(id: 1, state: .submitted, status: .applied)).count == 5)
        for state in [AppState.awaitingReview, .failed, .skipped, .unknownVerify] {
            #expect(JobDetailRules.menuActions(for: C2.job(id: 1, state: state)).isEmpty, "\(state) uses header buttons")
        }
    }

    @Test func reviewSafeguardRules() {
        let clean = [ApplicationAnswerItem(id: 1, applicationID: 1, question: "Name", answer: "M", confidence: nil, origin: .profile),
                     ApplicationAnswerItem(id: 2, applicationID: 1, question: "Go", answer: "4", confidence: 0.93, origin: .cv)]
        let medium = clean + [ApplicationAnswerItem(id: 3, applicationID: 1, question: "Why", answer: "…", confidence: 0.7, origin: .memory)]
        let low = medium + [ApplicationAnswerItem(id: 4, applicationID: 1, question: "Start", answer: "2m", confidence: 0.4, origin: .generated)]
        #expect(ReviewSafeguard.flagRank(clean) == 0 && ReviewSafeguard.flagRank(medium) == 1 && ReviewSafeguard.flagRank(low) == 2)
        #expect(ReviewSafeguard.flaggedAnswers(low).map(\.id) == [3, 4])
        #expect(!ReviewSafeguard.needsLook(answers: clean, loaded: true))
        #expect(ReviewSafeguard.needsLook(answers: clean, loaded: false), "unknown confidence is never clean")
        #expect(ReviewSafeguard.needsLook(answers: medium, loaded: true))
    }

    @Test func copyAllFormatsEveryAnswer() {
        let job = C2.job(id: 1, company: "Stripe", title: "Backend Engineer")
        let answers = MockFixtures.applicationAnswers(applicationID: 1, company: "Stripe", startID: 1)
        let text = JobDetailRules.copyAllText(job: job, answers: answers)
        #expect(text.hasPrefix("Stripe · Backend Engineer\n\nFull name\nMoaksh Kakkar"))
        #expect(text.contains("Years with Go?\n4"))
        #expect(!text.hasSuffix("\n"))
    }

    @Test func timelineMergesLogWithMilestones() {
        var job = C2.job(id: 7, state: .submitted, status: .interview, score: 91, submittedAt: Samples.now.addingTimeInterval(-15 * 86_400))
        job.discoveredAt = Samples.now.addingTimeInterval(-16 * 86_400)
        job.scoredAt = job.discoveredAt.addingTimeInterval(120)
        job.nudgesSent = 2
        job.statusUpdatedAt = Samples.now.addingTimeInterval(-86_400)
        let events = [
            C2.event(id: 1, ts: job.discoveredAt, kind: "discover", jobID: 7, message: "found via LinkedIn"),
            C2.event(id: 2, ts: job.submittedAt!, kind: "submit", jobID: 7, message: "submitted stripe/7"),
        ]
        let items = JobDetailRules.timeline(job: job, events: events, now: Samples.now)
        #expect(items.map(\.title) == ["Discovered", "Scored 91", "Applied", "Nudge · day 7", "Nudge · day 14", "Moved to Interview"])
        #expect(items.last?.actor == .user)
        #expect(items.first?.id == "e1", "logged events win over milestones")
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.at <= $1.at })
    }

    @Test func timelineForSkippedAndErrors() {
        let job = C2.job(id: 3, state: .skipped, score: 60, skipReason: "below_threshold")
        let items = JobDetailRules.timeline(job: job, events: [C2.event(id: 9, kind: "error", level: .error, jobID: 3, message: "boom")])
        #expect(items.contains { $0.title == "Skipped" && $0.detail == "Below threshold" })
        #expect(items.contains { $0.isError && $0.title == "Error" })
    }

    @Test func screenshotsAndInitialTab() {
        var job = C2.job(id: 1, state: .submitted)
        job.screenshotPath = "/tmp/pre.png"
        job.confirmationScreenshotPath = "/tmp/post.png"
        #expect(JobDetailRules.screenshots(for: job).map(\.label) == ["Before sending", "Confirmation"])
        #expect(JobDetailRules.screenshots(for: C2.job(id: 2)).isEmpty)
        #expect(JobDetailTab.initial(for: job) == .application)
        #expect(JobDetailTab.initial(for: C2.job(id: 2, state: .queued)) == .overview)
        #expect(JobDetailTab.initial(for: C2.job(id: 3, state: .needsYou), openQuestions: 2) == .questions)
        #expect(JobDetailTab.initial(for: C2.job(id: 3, state: .needsYou)) == .overview)
    }

    @Test @MainActor func loaderStreamsAnswersAndDescription() async {
        var data = RepositoryData()
        data.applicationAnswers[5] = MockFixtures.applicationAnswers(applicationID: 5, company: "Ramp", startID: 1)
        data.jobDescriptions[5] = "Ramp is hiring."
        let repo = InMemoryRepository(data)
        let loader = JobDetailLoader()
        await loader.loadDescription(jobID: 5, fallback: nil, repository: repo)
        #expect(loader.jobDescription == "Ramp is hiring.")
        await loader.loadDescription(jobID: 6, fallback: "fallback", repository: repo)
        #expect(loader.jobDescription == "fallback")

        let task = Task { await loader.streamAnswers(applicationID: 5, repository: repo) }
        #expect(await waitUntil { loader.answersLoaded && loader.answers.count == 10 })
        repo.update { $0.applicationAnswers[5]?.append(ApplicationAnswerItem(id: 99, applicationID: 5, question: "New?", answer: "Yes", origin: .user)) }
        #expect(await waitUntil { loader.answers.count == 11 })
        task.cancel()

        let none = JobDetailLoader()
        await none.streamAnswers(applicationID: nil, repository: repo)
        #expect(none.answersLoaded && none.answers.isEmpty)
    }
}
