// InboxCascadeTests.swift — "One answer, many doors" (docs/DESIGN_AWARD_VISION.md §3.2, 1D):
// which jobs fly (at most 8, list order, the rest as "+N"), the counts landing on Pipeline, one
// pulse at the end, the toast's copy and countdown ring, Undo taking it all back, the window
// closing it, and what doesn't cascade (one job, skips).
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Inbox answer cascade", .serialized)
struct InboxCascadeTests {
    static let companies = ["Stripe", "Ramp", "Notion", "Figma", "Linear", "Vercel", "Razorpay", "Zerodha", "CRED", "Swiggy"]

    final class Launches { var cascades: [AnswerCascade] = [] }

    private func setup(_ clusters: [QuestionCluster], undo: Duration = .milliseconds(150))
        async -> (AppStore, C3StubDaemon, InboxModel, Launches) {
        var data = RepositoryData()
        data.jobs = (1...10).map { C3Fixtures.job(id: $0, company: Self.companies[$0 - 1], state: .needsYou) }
        let (store, daemon, _) = await makeC3Store(data: data, clusters: clusters)
        let model = InboxModel(store: store)
        model.undoWindow = undo
        let launches = Launches()
        model.cascadeLauncher = { cascade, _ in launches.cascades.append(cascade) }
        _ = await c3WaitUntil { store.inbox.openCount == clusters.count && store.jobs.isLoaded }
        model.ensureSelection()
        return (store, daemon, model, launches)
    }

    private static func notice(_ jobs: [Int]) -> QuestionCluster {
        C3Fixtures.cluster("notice", jobs: jobs, question: "Notice period?", companies: jobs.map { companies[$0 - 1] })
    }

    @Test func monogramRowShowsWhoIsWaiting() async throws {
        let (_, _, model, _) = await setup([Self.notice(Array(1...10))])
        let c = try #require(model.selectedCluster)
        let (flyers, overflow) = model.waitingFlyers(for: c)
        #expect(flyers.map(\.id) == Array(1...8))
        #expect(flyers.map(\.company) == Array(Self.companies.prefix(8)))
        #expect(overflow == 2)
        #expect(WaitingMonogramRow.caption(10) == "10 jobs are waiting on this answer")
        #expect(WaitingMonogramRow.caption(1) == "1 job is waiting on this answer")
        #expect(WaitingMonogramRow.caption(3, task: true) == "3 jobs are waiting on this")
    }

    @Test func answeringManyJobsFliesThemToPipelineAndCountsThemIn() async throws {
        let (store, _, model, launches) = await setup([Self.notice(Array(1...10)), C3Fixtures.cluster("other", jobs: [1])], undo: .seconds(5))
        let c = try #require(model.selectedCluster)
        #expect(c.clusterId == "notice")
        model.updateDraft(for: c) { $0.text = "60 days" }
        #expect(model.submitSelected())

        // Which jobs fly: the first 8 in list order, the other 2 as "+2".
        let cascade = try #require(model.cascade)
        #expect(launches.cascades == [cascade])
        #expect(cascade.clusterID == "notice" && cascade.jobCount == 10)
        #expect(cascade.flyers.map(\.id) == Array(1...8) && cascade.overflow == 2)
        #expect(cascade.landedJobs == 0 && !cascade.isLanded && cascade.hapticOnLanding)
        // Honest copy (queued, not resumed) with the countdown ring on Undo.
        let toast = try #require(store.toasts.current)
        #expect(toast.message == "Answered · 10 jobs back in the queue")
        #expect(toast.actionTitle == "Undo" && toast.countdown && toast.presentedAt != nil)
        #expect(toast.duration == .seconds(5))

        // The count rolls up as monograms land; one pulse when the last one does.
        for _ in 0..<8 { model.landCascade(id: cascade.id, jobs: 1) }
        #expect(model.cascade?.landedJobs == 8 && model.cascadePulse == 0)
        model.landCascade(id: cascade.id, jobs: cascade.overflow)
        #expect(model.cascade?.isLanded == true && model.cascadePulse == 1)
        model.landCascade(id: cascade.id, jobs: 3)
        #expect(model.cascade?.landedJobs == 10 && model.cascadePulse == 1, "never more than the jobs, never a second pulse")
    }

    @Test func undoTakesTheJobsBack() async throws {
        let (store, daemon, model, _) = await setup([Self.notice([1, 2, 3])], undo: .milliseconds(300))
        let c = try #require(model.selectedCluster)
        model.updateDraft(for: c) { $0.text = "60 days" }
        model.submitSelected()
        let cascade = try #require(model.cascade)
        model.landCascade(id: cascade.id, jobs: 3)
        #expect(model.cascade?.isLanded == true)
        #expect(store.toasts.current?.action != nil)
        store.toasts.performAction()   // the toast's Undo
        #expect(model.cascade == nil, "the Pipeline badge goes")
        #expect(model.clusters.map(\.clusterId) == ["notice"] && model.selectedClusterID == "notice")
        #expect(model.draft(for: c).text == "60 days")
        // A late landing from the cancelled flight changes nothing.
        model.landCascade(id: cascade.id, jobs: 1)
        #expect(model.cascade == nil)
        try await Task.sleep(for: .milliseconds(450))
        #expect(daemon.sent("answer_question").isEmpty)
    }

    @Test func theWindowClosingEndsTheCascade() async throws {
        let (_, daemon, model, _) = await setup([Self.notice([1, 2, 3])])
        let c = try #require(model.selectedCluster)
        model.updateDraft(for: c) { $0.text = "60 days" }
        model.submitSelected()
        #expect(model.cascade != nil)
        #expect(await c3WaitUntil { daemon.sent("answer_question").count == 1 })
        #expect(await c3WaitUntil { model.cascade == nil })
    }

    @Test func oneJobOrASkipDoesNotCascade() async throws {
        let (store, _, model, launches) = await setup([Self.notice([1, 2, 3]), C3Fixtures.cluster("single", jobs: [4], question: "Portfolio?")],
                                                      undo: .seconds(5))
        model.select("single")
        let single = try #require(model.selectedCluster)
        model.updateDraft(for: single) { $0.text = "https://asha.dev" }
        model.submitSelected()
        #expect(model.cascade == nil && launches.cascades.isEmpty)
        #expect(store.toasts.current?.countdown == true, "the ring still drains on a single answer's Undo")
        model.select("notice")
        model.skipSelected()
        #expect(model.cascade == nil && launches.cascades.isEmpty)
    }

    @Test func doneTryAgainOnATaskCascadesToo() async throws {
        var task = C3Fixtures.cluster("captcha", jobs: [1, 2], question: "Solve the CAPTCHA")
        task.kind = "action"
        let (store, _, model, launches) = await setup([task], undo: .seconds(5))
        model.completeSelectedAction()
        #expect(launches.cascades.first?.jobCount == 2)
        #expect(store.toasts.current?.message == "Done · 2 jobs back in the queue")
        // It was the last one: inbox zero plays the haptic, so landing doesn't play another.
        #expect(launches.cascades.first?.hapticOnLanding == false)
    }

    @Test func aNewAnswerReplacesTheCascadeAndIgnoresTheOldFlight() async throws {
        let (_, _, model, launches) = await setup([Self.notice([1, 2]), C3Fixtures.cluster("b", jobs: [3, 4, 5], question: "Salary?")],
                                                  undo: .seconds(5))
        for _ in 0..<2 {
            let c = try #require(model.selectedCluster)
            model.updateDraft(for: c) { $0.text = "x" }
            model.submitSelected()
        }
        #expect(launches.cascades.count == 2)
        let first = launches.cascades[0], second = launches.cascades[1]
        #expect(first.id != second.id && model.cascade?.id == second.id)
        model.landCascade(id: first.id, jobs: 5)
        #expect(model.cascade?.landedJobs == 0)
    }

    @Test func withNothingToFlyItLandsAtOnce() async throws {
        // The app's launcher, but no window to fly in (as under Reduce Motion): the badge just
        // fades in with the full count.
        let (_, _, model, _) = await setup([Self.notice([1, 2, 3])], undo: .seconds(5))
        model.cascadeLauncher = { cascade, model in CascadeFlight.launch(cascade, model: model) }
        let c = try #require(model.selectedCluster)
        model.updateDraft(for: c) { $0.text = "60 days" }
        model.submitSelected()
        #expect(model.cascade?.isLanded == true && model.cascade?.landedJobs == 3)
        #expect(model.cascadePulse == 1)
        #expect(CascadeFlight.plan(for: try #require(model.cascade)) == nil)
    }

    @Test func flightGeometryAndTheRing() {
        let from = CGPoint(x: 600, y: 400), to = CGPoint(x: 80, y: 150)
        #expect(ArcFlight.point(from: from, to: to, progress: 0) == from)
        #expect(ArcFlight.point(from: from, to: to, progress: 1) == to)
        // The arc rises above both ends on the way.
        #expect(ArcFlight.point(from: from, to: to, progress: 0.5).y < to.y)
        // Stagger: 30 ms apart, capped at 8.
        #expect(AnswerCascade.delay(index: 0) == 0)
        #expect(abs(AnswerCascade.delay(index: 3) - 0.09) < 1e-9)
        #expect(AnswerCascade.delay(index: 20) == AnswerCascade.delay(index: 8))
        let start = Date()
        #expect(UndoRing.remaining(start: start, duration: .seconds(10), now: start) == 1)
        #expect(abs(UndoRing.remaining(start: start, duration: .seconds(10), now: start.addingTimeInterval(2.5)) - 0.75) < 1e-9)
        #expect(UndoRing.remaining(start: start, duration: .seconds(10), now: start.addingTimeInterval(12)) == 0)
    }
}
