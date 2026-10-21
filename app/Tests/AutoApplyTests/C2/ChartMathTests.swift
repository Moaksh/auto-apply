// ChartMathTests.swift — moving average, threshold snapping/preview, heatmap layout and
// summaries, funnel/source labels, flow geometry, screenshot geometry, JSON highlighting.
import CoreGraphics
import Foundation
import Testing
@testable import AutoApply

@Suite("C2 · Chart math & geometry")
struct ChartMathTests {
    let cal = C2.utc

    @Test func movingAverageIsTrailing() {
        let avg = ChartMath.movingAverage([7, 0, 0, 0, 0, 0, 0, 7], window: 7)
        #expect(avg.count == 8)
        #expect(avg[0] == 7)
        #expect(avg[1] == 3.5)
        #expect(abs(avg[6] - 1.0) < 1e-9)
        #expect(abs(avg[7] - 1.0) < 1e-9, "the first 7 dropped out of the window")
        #expect(ChartMath.movingAverage([]).isEmpty)
    }

    @Test func thresholdSnapsToFivesWithinRange() {
        #expect(ChartMath.snapThreshold(67.4) == 65)
        #expect(ChartMath.snapThreshold(67.6) == 70)
        #expect(ChartMath.snapThreshold(-12) == 0)
        #expect(ChartMath.snapThreshold(140) == 100)
    }

    @Test func thresholdPreviewCountsJobsPerWeek() {
        // 28 days of scores: 8 at 66, 12 at 72, 8 at 90 → 28 jobs over 4 weeks.
        let scores = (Array(repeating: 66, count: 8) + Array(repeating: 72, count: 12) + Array(repeating: 90, count: 8)).sorted()
        #expect(ChartMath.qualifyingPerWeek(sortedScores: scores, threshold: 70) == 5)
        #expect(ChartMath.qualifyingPerWeek(sortedScores: scores, threshold: 65) == 7)
        #expect(ChartMath.qualifyingPerWeek(sortedScores: scores, threshold: 95) == 0)
        #expect(ChartMath.thresholdPreview(sortedScores: scores, current: 70, proposed: 65) == "At 65: +2 jobs/week would qualify")
        #expect(ChartMath.thresholdPreview(sortedScores: scores, current: 70, proposed: 80) == "At 80: −3 jobs/week would qualify")
        #expect(ChartMath.thresholdPreview(sortedScores: scores, current: 70, proposed: 70) == nil)
    }

    @Test func recentScoresKeepsLast28DaysSorted() {
        let now = Samples.now
        let jobs = [
            C2.job(id: 1, score: 90, discoveredAt: now.addingTimeInterval(-86_400)),
            C2.job(id: 2, score: 40, discoveredAt: now.addingTimeInterval(-2 * 86_400)),
            C2.job(id: 3, score: 99, discoveredAt: now.addingTimeInterval(-40 * 86_400)),
            C2.job(id: 4, score: nil, discoveredAt: now),
        ]
        #expect(ChartMath.recentScores(jobs: jobs, now: now) == [40, 90])
    }

    @Test func heatLevelsUseFiveSteps() {
        #expect(ChartMath.heatLevel(count: 0, max: 10) == 0)
        #expect(ChartMath.heatLevel(count: 1, max: 10) == 1)
        #expect(ChartMath.heatLevel(count: 5, max: 10) == 2)
        #expect(ChartMath.heatLevel(count: 7, max: 10) == 3)
        #expect(ChartMath.heatLevel(count: 10, max: 10) == 4)
        #expect(ChartMath.heatLevel(count: 3, max: 0) == 0)
    }

    @Test func heatmapCellsLayIntoMondayFirstWeeks() {
        // 2026-10-07 is a Wednesday.
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        let days = (0..<10).map { DayCount(day: cal.date(byAdding: .day, value: $0, to: start)!, applied: $0) }
        let cells = ChartMath.heatmapCells(days, calendar: cal)
        #expect(cells.count == 10)
        #expect(cells[0].weekday == 2 && cells[0].week == 0, "Wednesday in the first column")
        #expect(cells[4].weekday == 6 && cells[4].week == 0, "Sunday closes week 0")
        #expect(cells[5].weekday == 0 && cells[5].week == 1, "Monday starts week 1")
        #expect(ChartMath.weekCount(cells) == 2)
        #expect(cells[9].level == 4)
        #expect(ChartMath.mondayIndex(start, calendar: cal) == 2)
    }

    @Test func weekSummaryAndTooltip() {
        let monday = cal.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let days = [3, 11, 0, 5, 2, 0, 0].enumerated().map { DayCount(day: cal.date(byAdding: .day, value: $0.offset, to: monday)!, applied: $0.element) }
        let cells = ChartMath.heatmapCells(days, calendar: cal)
        let summary = ChartMath.weekSummary(cells)
        #expect(summary.contains("21 applications"))
        #expect(summary.contains("with 11"))
        #expect(ChartMath.weekSummary([]) == "")
        let tip = ChartMath.cellTooltip(cells[1], interviewsLater: 2)
        #expect(tip.hasSuffix("11 applications · 2 interviews later"))
        #expect(!ChartMath.cellTooltip(cells[0], interviewsLater: 0).contains("interview"))
    }

    @Test func interviewsByDayCountsLaterInterviews() {
        let day = cal.startOfDay(for: Samples.now)
        let jobs = [
            C2.job(id: 1, state: .submitted, status: .interview, submittedAt: Samples.now),
            C2.job(id: 2, state: .submitted, status: .offer, submittedAt: Samples.now),
            C2.job(id: 3, state: .submitted, status: .rejected, submittedAt: Samples.now),
        ]
        #expect(ChartMath.interviewsByDay(jobs: jobs, calendar: cal)[day] == 2)
    }

    @Test func funnelLabelsAndColumns() {
        let steps = StatsCalculator.funnel([
            C2.job(id: 1, state: .submitted, status: .interview), C2.job(id: 2, state: .submitted, status: .rejected),
            C2.job(id: 3, state: .submitted, status: .applied), C2.job(id: 4, state: .submitted, status: .applied),
        ])
        #expect(ChartMath.funnelShareLabel(steps[0], applied: 4) == "")
        #expect(ChartMath.funnelShareLabel(steps[1], applied: 4) == ChartMath.percent(0.5))
        #expect(ChartMath.funnelTitle(.responded) == "Responded")
        #expect(ChartMath.funnelColumns(.interview) == [.interview])
        #expect(ChartMath.funnelColumns(.responded).contains(.rejected))
        let tiny = FunnelStep(stage: .offer, count: 1, conversion: nil)
        #expect(ChartMath.funnelShareLabel(tiny, applied: 142).contains("0.7"))
    }

    @Test func sourceSegmentsSplitOutEasyApply() {
        let stats = [SourceStat(source: .greenhouse, discovered: 46, applied: 30), SourceStat(source: .linkedin, discovered: 60, applied: 10),
                     SourceStat(source: .lever, discovered: 0, applied: 0)]
        let segments = ChartMath.sourceSegments(stats, easyApply: 45)
        #expect(segments.map(\.label) == ["Greenhouse", "LinkedIn", "LinkedIn Easy Apply (manual)"])
        #expect(segments.map(\.count) == [46, 15, 45])
        #expect(segments.last?.isManual == true)
        #expect(abs(segments.reduce(0) { $0 + $1.share } - 1) < 1e-9)
        #expect(ChartMath.sourceSegments([], easyApply: 0).isEmpty)
    }

    @Test func nearestDaySnapsScrubbing() {
        let d0 = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let days = (0..<3).map { DayCount(day: cal.date(byAdding: .day, value: $0, to: d0)!, applied: $0) }
        let probe = d0.addingTimeInterval(86_400 * 1.2)
        #expect(ChartMath.nearestDay(to: probe, in: days, calendar: cal)?.applied == 1)
        #expect(ChartMath.dayAnnotation(DayCount(day: d0, applied: 12, skipped: 3)).hasSuffix("12 applied · 3 skipped"))
    }

    // MARK: Flow geometry

    @Test func flowNodesAreEvenlySpacedOnTheRail() {
        let g = FlowGeometry(size: CGSize(width: 1000, height: 150))
        let xs = FlowStage.main.map { g.node($0).x }
        #expect(xs.first == g.inset)
        #expect(abs(xs.last! - (1000 - g.inset)) < 0.001)
        let gaps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - g.spacing) < 0.001 })
        #expect(FlowStage.main.allSatisfy { g.node($0).y == g.railY })
        #expect(g.node(.skipped).y == g.branchY)
        #expect(g.node(.skipped).x > g.node(.scored).x)
        #expect(FlowGeometry.branchParent(.needsYou) == .filling)
    }

    @Test func particlePathsStartAndEndOnNodes() {
        let g = FlowGeometry(size: CGSize(width: 800, height: 150))
        #expect(g.point(from: .scored, to: .queued, progress: 0) == g.node(.scored))
        #expect(g.point(from: .scored, to: .queued, progress: 1) == g.node(.queued))
        let mid = g.point(from: .scored, to: .queued, progress: 0.5)
        #expect(abs(mid.x - (g.node(.scored).x + g.node(.queued).x) / 2) < 0.001)
        // Branch: starts at the parent, ends at the branch end, dips below the rail.
        #expect(g.point(from: .scored, to: .skipped, progress: 0) == g.node(.scored))
        let end = g.point(from: .scored, to: .skipped, progress: 1)
        #expect(abs(end.x - g.branchEnd(.skipped).x) < 0.001 && abs(end.y - g.branchY) < 0.001)
        #expect(g.point(from: .scored, to: .skipped, progress: 0.5).y > g.railY)
        // Appearing jobs drift in from the left into Discovered.
        #expect(g.point(from: nil, to: .discovered, progress: 0).x < g.node(.discovered).x)
        #expect(g.point(from: nil, to: .discovered, progress: 1) == g.node(.discovered))
        // Progress is clamped.
        #expect(g.point(from: .queued, to: .filling, progress: 3) == g.node(.filling))
    }

    @Test func particleTimingIsStatelessFromStartAndNow() {
        let t = StageTransition(jobID: 1, from: .queued, to: .filling, start: Samples.now)
        #expect(FlowGeometry.progress(of: t, at: Samples.now) == 0)
        let half = FlowGeometry.progress(of: t, at: Samples.now.addingTimeInterval(0.35))!
        #expect(abs(half - 0.5) < 0.01)
        #expect(FlowGeometry.progress(of: t, at: Samples.now.addingTimeInterval(0.7)) == 1)
        #expect(FlowGeometry.progress(of: t, at: Samples.now.addingTimeInterval(2)) == nil, "pruned after arrival + fade")
        #expect(FlowGeometry.opacity(of: t, at: Samples.now.addingTimeInterval(0.3)) == 1)
        #expect(FlowGeometry.opacity(of: t, at: Samples.now.addingTimeInterval(0.95)) == 0)
    }

    @Test func flowAccessibilityText() {
        var c = RunStats()
        c.discovered = 41; c.scored = 38; c.skipped = 27; c.queued = 12; c.submitted = 9; c.needsYou = 2
        #expect(FlowAccessibility.summary(verb: "Applying", counts: c, filling: 1, isRunning: true)
            == "Agent applying. Current run: 41 discovered, 38 scored, 12 queued, 1 filling, 9 applied")
        #expect(FlowAccessibility.summary(verb: "Idle", counts: c, filling: 0, isRunning: false).hasPrefix("Last run:"))
        #expect(FlowAccessibility.stage(.scored, counts: c, filling: 0, threshold: 70) == "Scored, 38 jobs, 27 skipped below threshold 70")
        #expect(FlowAccessibility.stage(.filling, counts: c, filling: 1, threshold: 70) == "Filling, 1 job, 2 need you")
    }

    // MARK: Screenshot geometry

    @Test func screenshotScaleViewportAndTargets() {
        let scale = ScreenshotGeometry.scale(imagePixelWidth: 1440, viewWidth: 720, zoom: 1)
        #expect(scale == 0.5)
        #expect(ScreenshotGeometry.scale(imagePixelWidth: 1440, viewWidth: 720, zoom: 2) == 1)
        // Content 2000pt tall, 500pt visible, minimap 200pt.
        let vp = ScreenshotGeometry.viewport(contentOffsetY: 1000, visibleHeight: 500, contentHeight: 2000, minimapHeight: 200)
        #expect(vp.y == 100 && vp.height == 50)
        let clamped = ScreenshotGeometry.viewport(contentOffsetY: 5000, visibleHeight: 500, contentHeight: 2000, minimapHeight: 200)
        #expect(clamped.y == 150)
        #expect(ScreenshotGeometry.contentOffset(forMinimapY: 100, minimapHeight: 200, contentHeight: 2000, visibleHeight: 500) == 750)
        #expect(ScreenshotGeometry.contentOffset(forMinimapY: 0, minimapHeight: 200, contentHeight: 2000, visibleHeight: 500) == 0)
        // bbox at pixel y 1000..1100, scale 0.5 → mid 525pt → offset 275 to center in 500pt.
        let bbox = CGRect(x: 40, y: 1000, width: 640, height: 100)
        #expect(ScreenshotGeometry.scrollTarget(for: bbox, scale: 0.5, visibleHeight: 500, contentHeight: 2000) == 275)
        #expect(ScreenshotGeometry.displayRect(for: bbox, scale: 0.5) == CGRect(x: 20, y: 500, width: 320, height: 50))
        #expect(ScreenshotGeometry.zoom(1, step: 1) == 1.25)
        #expect(ScreenshotGeometry.zoom(3, step: 1) == 3)
        #expect(ScreenshotGeometry.zoom(0.5, step: -1) == 0.5)
    }

    // MARK: JSON highlighting

    @Test func jsonTokensDistinguishKeysStringsAndLiterals() {
        let json = ActivityRules.prettyJSON(.object(["step": .int(4), "field": .string("Years with Go"), "ok": .bool(true), "x": .null]))
        let tokens = JSONHighlighter.tokens(json)
        #expect(tokens.map(\.0).joined() == json, "tokenization is lossless")
        #expect(tokens.contains { $0.0 == "\"field\"" && $0.1 == .key })
        #expect(tokens.contains { $0.0 == "\"Years with Go\"" && $0.1 == .string })
        #expect(tokens.contains { $0.0 == "4" && $0.1 == .literal })
        #expect(tokens.contains { $0.0 == "true" && $0.1 == .literal })
        #expect(tokens.contains { $0.0 == "null" && $0.1 == .literal })
    }
}
