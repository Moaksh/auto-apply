// DashboardModelTests.swift — greeting, next-run countdown, KPI captions, hero state/verb,
// count-up policy, throttles, layout breakpoint, ticker chips, flow navigation.
import Foundation
import Testing
@testable import AutoApply

@Suite("C2 · Dashboard model")
struct DashboardModelTests {
    let cal = C2.utc

    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour, minute: minute))!
    }

    @Test func greetingByTimeOfDay() {
        #expect(DashboardFormat.greeting(at: at(9), name: "Moaksh", calendar: cal) == "Good morning, Moaksh.")
        #expect(DashboardFormat.greeting(at: at(14), name: "Moaksh", calendar: cal) == "Good afternoon, Moaksh.")
        #expect(DashboardFormat.greeting(at: at(19), name: nil, calendar: cal) == "Good evening.")
        #expect(DashboardFormat.greeting(at: at(2), name: "", calendar: cal) == "Working late.")
    }

    @Test func nextRunShowsClockThenCountsDownInLastTenMinutes() {
        let next = at(14)
        let far = DashboardFormat.nextRunLabel(nextRun: next, now: at(12), calendar: cal)
        #expect(far?.hasPrefix("Next run ") == true)
        #expect(far?.contains("in") == false)
        #expect(DashboardFormat.nextRunLabel(nextRun: next, now: at(13, 56), calendar: cal) == "Next run in 4 min")
        #expect(DashboardFormat.nextRunLabel(nextRun: next, now: next.addingTimeInterval(-10), calendar: cal) == "Next run starting")
        #expect(DashboardFormat.nextRunLabel(nextRun: nil, now: at(12)) == nil)
        #expect(!DashboardFormat.needsCountdownRefresh(nextRun: next, now: at(12)))
        #expect(DashboardFormat.needsCountdownRefresh(nextRun: next, now: at(13, 55)))
    }

    @Test func kpiCaptionsAndDeltas() {
        #expect(DashboardFormat.deltaVsAverage(4.2) == "+4 vs avg")
        #expect(DashboardFormat.deltaVsAverage(-2.4) == "−2 vs avg")
        #expect(DashboardFormat.deltaVsAverage(0.3) == "On your average")
        #expect(DashboardFormat.responseRateDelta(current: 0.18, previous: 0.15) == MetricDelta(text: "3pt", isPositive: true))
        #expect(DashboardFormat.responseRateDelta(current: 0.10, previous: 0.15) == MetricDelta(text: "5pt", isPositive: false))
        #expect(DashboardFormat.responseRateDelta(current: nil, previous: 0.2) == nil)
    }

    @Test func submittedGlyphsCapAtTwelve() {
        #expect(DashboardFormat.submittedGlyphs(0) == "")
        #expect(DashboardFormat.submittedGlyphs(3) == "✓✓✓")
        #expect(DashboardFormat.submittedGlyphs(12) == String(repeating: "✓", count: 12))
        #expect(DashboardFormat.submittedGlyphs(21) == "✓ × 21")
        #expect(DashboardFormat.skippedLabel(27, threshold: 70) == "27 skipped")
        #expect(DashboardFormat.needsYouLabel(1) == "1 needs you")
        #expect(DashboardFormat.needsYouLabel(2) == "2 need you")
    }

    @Test func elapsedAndTickerTime() {
        #expect(DashboardFormat.elapsed(42) == "00:42")
        #expect(DashboardFormat.elapsed(3_729) == "1:02:09")
        #expect(DashboardFormat.elapsed(-5) == "00:00")
        #expect(DashboardFormat.tickerTime(at(14, 2).addingTimeInterval(11), calendar: cal) == "14:02:11")
    }

    func inputs(snapshot: Bool = true, connected: Bool = true, unreachable: Bool = false, paused: Bool = false,
                activity: DaemonActivity = .idle, jobs: Bool = true, lastRun: Bool = true, cap: CapReachedPayload? = nil) -> HeroState.Inputs {
        .init(hasSnapshot: snapshot, isConnected: connected, isUnreachable: unreachable, lastSeen: nil, paused: paused,
              activity: activity, hasAnyJobs: jobs, hasLastRun: lastRun, capReached: cap)
    }

    @Test func heroStateResolution() {
        #expect(HeroState.resolve(inputs(snapshot: false, connected: false)) == .loading)
        #expect(HeroState.resolve(inputs(connected: false, unreachable: true)) == .unreachable(lastSeen: nil))
        #expect(HeroState.resolve(inputs(paused: true, activity: .applying)) == .paused)
        #expect(HeroState.resolve(inputs(activity: .discovering)) == .discovering)
        #expect(HeroState.resolve(inputs(activity: .scoring)) == .scoring)
        #expect(HeroState.resolve(inputs(activity: .applying)) == .filling)
        #expect(HeroState.resolve(inputs()) == .idle)
        #expect(HeroState.resolve(inputs(jobs: false, lastRun: false)) == .firstRun)
        #expect(HeroState.resolve(inputs(cap: CapReachedPayload(cap: .daily, used: 15, limit: 15))) == .capReached(used: 15, limit: 15))
        #expect(HeroState.resolve(inputs(cap: CapReachedPayload(cap: .linkedinBudget, used: 3, limit: 3))) == .idle)
        // After a relaunch the live cap_reached event is gone; the snapshot caps still say "done".
        var relaunched = inputs()
        relaunched.dailyUsed = 15; relaunched.dailyLimit = 15
        #expect(HeroState.resolve(relaunched) == .capReached(used: 15, limit: 15))
        relaunched.dailyUsed = 14
        #expect(HeroState.resolve(relaunched) == .idle)
        relaunched.dailyUsed = 3; relaunched.dailyLimit = 0
        #expect(HeroState.resolve(relaunched) == .idle, "no limit configured")
        #expect(HeroState.filling.isRunning && !HeroState.idle.isRunning && !HeroState.paused.isRunning)
    }

    @Test func heroVerbs() {
        #expect(HeroVerb.resolve(state: .filling, activeJobState: .filling, lastStepAction: "fill_field", openClusters: 0, hasError: false) == .filling)
        #expect(HeroVerb.resolve(state: .filling, activeJobState: .submitting, lastStepAction: nil, openClusters: 0, hasError: false) == .submitting)
        #expect(HeroVerb.resolve(state: .filling, activeJobState: .filling, lastStepAction: "wait_for_page", openClusters: 0, hasError: false) == .waitingOnPage)
        #expect(HeroVerb.resolve(state: .idle, activeJobState: nil, lastStepAction: nil, openClusters: 2, hasError: false) == .needsYou)
        #expect(HeroVerb.resolve(state: .idle, activeJobState: nil, lastStepAction: nil, openClusters: 2, hasError: true) == .error)
        #expect(HeroVerb.resolve(state: .idle, activeJobState: nil, lastStepAction: nil, openClusters: 0, hasError: false) == .idle)
        #expect(HeroVerb.resolve(state: .paused, activeJobState: nil, lastStepAction: nil, openClusters: 0, hasError: false) == .paused)
        #expect(HeroVerb.resolve(state: .capReached(used: 1, limit: 1), activeJobState: nil, lastStepAction: nil, openClusters: 0, hasError: false) == .doneForToday)
    }

    @Test func announcementsThrottledToOnePerTenSeconds() {
        var t = AnnouncementThrottle()
        let start = at(9)
        let results = [0, 4, 9.9, 10].map { t.shouldAnnounce(at: start.addingTimeInterval($0)) }
        #expect(results == [true, false, false, true])
    }

    @Test func burstSubmitsCoalesceIntoOneCelebration() {
        var gate = CelebrationGate()
        let start = at(9)
        let fired = (0..<5).map { gate.shouldFire(at: start.addingTimeInterval(Double($0) * 0.4)) }
        #expect(fired == [true, false, false, false, false])
        let later = gate.shouldFire(at: start.addingTimeInterval(6))
        #expect(later)
    }

    @Test func adaptiveColumnsFitTheWidth() {
        #expect(AdaptiveColumns.columns(for: 1200, minColumnWidth: 220, maxColumns: 4, spacing: 12) == 4)
        #expect(AdaptiveColumns.columns(for: 800, minColumnWidth: 220, maxColumns: 4, spacing: 12) == 3)
        #expect(AdaptiveColumns.columns(for: 300, minColumnWidth: 220, maxColumns: 4, spacing: 12) == 1)
        #expect(AdaptiveColumns.columns(for: 0, minColumnWidth: 220, maxColumns: 4, spacing: 12) == 1)
    }

    @Test func tickerChipsCheckOffFromSteps() {
        func step(_ i: Int, _ action: String, _ detail: String? = nil) -> TickerStep {
            TickerStep(applicationID: 1, jobID: 1, index: i, total: 7, action: action, detail: detail, confidence: nil, at: Samples.now)
        }
        #expect(TickerChips.completed(steps: []).isEmpty)
        #expect(TickerChips.completed(steps: [step(0, "write_cover_letter")]) == ["cover letter"])
        #expect(TickerChips.completed(steps: [step(0, "generate", "cover letter · 212 words"), step(1, "submit")]) == ["cover letter", "submit"])
    }

    @Test func flowStageNavigation() {
        #expect(FlowNavigation.pipelineFilter(for: .needsYou) == nil, "needs-you opens the inbox")
        #expect(FlowNavigation.pipelineFilter(for: .skipped)?.columns == [.skipped])
        #expect(FlowNavigation.pipelineFilter(for: .skipped)?.showSkipped == true)
        #expect(FlowNavigation.pipelineFilter(for: .submitted)?.columns == [.applied])
        #expect(FlowNavigation.pipelineFilter(for: .queued)?.columns == [.queued])

        var old = C2.job(id: 1, state: .queued)
        old.stateUpdatedAt = Samples.now.addingTimeInterval(-3 * 86_400)
        var fresh = C2.job(id: 2, state: .prepping)
        fresh.stateUpdatedAt = Samples.now.addingTimeInterval(-60)
        var newer = C2.job(id: 3, state: .queued)
        newer.stateUpdatedAt = Samples.now.addingTimeInterval(-10)
        let skipped = C2.job(id: 4, state: .skipped)
        let jobs = FlowNavigation.jobs(at: .queued, in: [old, fresh, newer, skipped], now: Samples.now, calendar: cal)
        #expect(jobs.map(\.id) == [3, 2])
    }

    @Test func widgetDataState() {
        #expect(WidgetDataState.resolve(isLoaded: true, isAvailable: false) == .content)
        #expect(WidgetDataState.resolve(isLoaded: false, isAvailable: true) == .loading)
        #expect(WidgetDataState.resolve(isLoaded: false, isAvailable: false) == .error(message: "Couldn't read stats"))
    }
}
