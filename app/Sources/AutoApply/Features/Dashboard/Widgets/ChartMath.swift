// ChartMath.swift — pure helpers behind the dashboard charts (moving averages, heatmap grid,
// threshold preview, funnel/source labels). Kept out of `body` per §2.7 ("no chart is
// computed from raw rows in body") and unit-tested.
import Foundation

enum ChartMath {
    // MARK: Applications · 30 days

    /// Trailing moving average (window `w`, shorter at the start).
    static func movingAverage(_ values: [Int], window w: Int = 7) -> [Double] {
        guard w > 0 else { return values.map(Double.init) }
        var out: [Double] = []
        out.reserveCapacity(values.count)
        var sum = 0
        for (i, v) in values.enumerated() {
            sum += v
            if i >= w { sum -= values[i - w] }
            out.append(Double(sum) / Double(min(i + 1, w)))
        }
        return out
    }

    /// "Tue 7 Oct · 12 applied · 3 skipped by cap" scrub annotation.
    static func dayAnnotation(_ day: DayCount) -> String {
        let date = day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        var parts = [date, "\(day.applied) applied"]
        if day.skipped > 0 { parts.append("\(day.skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    /// Nearest day in `days` to `date` (chart scrubbing snaps to whole days).
    static func nearestDay(to date: Date, in days: [DayCount], calendar: Calendar = .current) -> DayCount? {
        let target = calendar.startOfDay(for: date)
        return days.min { abs($0.day.timeIntervalSince(target)) < abs($1.day.timeIntervalSince(target)) }
    }

    // MARK: Match score histogram / threshold

    /// Threshold rule snaps to multiples of 5 within 0…100.
    static func snapThreshold(_ raw: Double) -> Int {
        let clamped = min(100, max(0, raw))
        return Int((clamped / 5).rounded()) * 5
    }

    /// Scores of jobs discovered in the last 28 days, ascending (precomputed once per stats
    /// refresh so dragging the threshold is a binary search, not a scan).
    static func recentScores(jobs: [JobItem], now: Date = Date(), days: Int = 28) -> [Int] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return jobs.compactMap { $0.discoveredAt >= since ? $0.score : nil }.sorted()
    }

    /// Jobs per week that would clear `threshold`, from ascending 28-day scores.
    static func qualifyingPerWeek(sortedScores: [Int], threshold: Int, days: Int = 28) -> Int {
        // First index with score >= threshold.
        var lo = 0, hi = sortedScores.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedScores[mid] < threshold { lo = mid + 1 } else { hi = mid }
        }
        let n = sortedScores.count - lo
        return Int((Double(n) / (Double(days) / 7)).rounded())
    }

    /// "At 65: +23 jobs/week would qualify" (or "−8 jobs/week"). nil when unchanged.
    static func thresholdPreview(sortedScores: [Int], current: Int, proposed: Int) -> String? {
        guard proposed != current else { return nil }
        let delta = qualifyingPerWeek(sortedScores: sortedScores, threshold: proposed)
            - qualifyingPerWeek(sortedScores: sortedScores, threshold: current)
        let sign = delta >= 0 ? "+" : "−"
        return "At \(proposed): \(sign)\(abs(delta)) jobs/week would qualify"
    }

    // MARK: Funnel

    static func percent(_ value: Double?, decimals: Int = 0) -> String {
        guard let value else { return "" }
        return value.formatted(.percent.precision(.fractionLength(decimals)))
    }

    /// Share of Applied for each step (direct label in the funnel: "18%", "0.7%").
    static func funnelShareLabel(_ step: FunnelStep, applied: Int) -> String {
        guard step.stage != .applied, applied > 0 else { return "" }
        let share = Double(step.count) / Double(applied)
        return percent(share, decimals: share > 0 && share < 0.01 ? 1 : 0)
    }

    static func funnelTitle(_ stage: FunnelStep.Stage) -> String {
        switch stage {
        case .applied: "Applied"
        case .responded: "Responded"
        case .assessment: "Assessment"
        case .interview: "Interview"
        case .offer: "Offer"
        }
    }

    /// Board status a funnel bar opens in Pipeline (Responded opens all post-apply responses).
    static func funnelColumns(_ stage: FunnelStep.Stage) -> Set<BoardColumn> {
        switch stage {
        case .applied: [.applied, .assessment, .interview, .offer, .rejected, .ghosted]
        case .responded: [.assessment, .interview, .offer, .rejected]
        case .assessment: [.assessment]
        case .interview: [.interview]
        case .offer: [.offer]
        }
    }

    // MARK: Sources

    struct SourceSegment: Identifiable, Hashable, Sendable {
        var id: String
        var label: String
        var count: Int
        var share: Double
        var paletteIndex: Int
        var isManual: Bool
    }

    /// One 100% stacked bar: ATS sources (LinkedIn/Glassdoor shown as "→ATS"), plus the Easy
    /// Apply manual segment, in descending order. Zero-count sources are omitted.
    static func sourceSegments(_ sources: [SourceStat], easyApply: Int) -> [SourceSegment] {
        var raw: [(String, String, Int, Bool)] = sources.map { stat in
            let label: String = switch stat.source {
            case .linkedin: "LinkedIn→ATS"
            case .glassdoor: "Glassdoor→ATS"
            case .google: "Google Jobs"
            default: stat.source.label
            }
            // Easy Apply jobs are counted in their LinkedIn source; show them separately.
            let count = stat.source == .linkedin ? max(0, stat.discovered - easyApply) : stat.discovered
            return (stat.source.rawValue, label, count, false)
        }
        if easyApply > 0 { raw.append(("easy_apply", "LinkedIn Easy Apply (manual)", easyApply, true)) }
        raw = raw.filter { $0.2 > 0 }
        let total = raw.reduce(0) { $0 + $1.2 }
        guard total > 0 else { return [] }
        let ordered = raw.sorted { ($0.3 ? 1 : 0, -$0.2) < ($1.3 ? 1 : 0, -$1.2) }
        return ordered.enumerated().map { i, r in
            SourceSegment(id: r.0, label: r.1, count: r.2, share: Double(r.2) / Double(total),
                          paletteIndex: i % 5, isManual: r.3)
        }
    }

    // MARK: Heatmap

    struct HeatCell: Identifiable, Hashable, Sendable {
        var id: Date { day }
        var day: Date
        var count: Int
        /// 0…4 (0 = sunken).
        var level: Int
        var week: Int
        /// 0 = Monday … 6 = Sunday.
        var weekday: Int
    }

    /// 5-step level for a count relative to the busiest day.
    static func heatLevel(count: Int, max maxCount: Int) -> Int {
        guard count > 0, maxCount > 0 else { return 0 }
        let ratio = Double(count) / Double(maxCount)
        return min(4, max(1, Int((ratio * 4).rounded(.up))))
    }

    /// Lay days (oldest first) into week columns, Monday-first rows.
    static func heatmapCells(_ days: [DayCount], calendar: Calendar = .current) -> [HeatCell] {
        guard let first = days.first else { return [] }
        let maxCount = days.map(\.applied).max() ?? 0
        let firstWeekday = mondayIndex(first.day, calendar: calendar)
        return days.enumerated().map { i, d in
            let slot = i + firstWeekday
            return HeatCell(day: d.day, count: d.applied, level: heatLevel(count: d.applied, max: maxCount),
                            week: slot / 7, weekday: slot % 7)
        }
    }

    static func mondayIndex(_ date: Date, calendar: Calendar = .current) -> Int {
        // Calendar weekday: 1 = Sunday … 7 = Saturday → 0 = Monday … 6 = Sunday.
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    static func weekCount(_ cells: [HeatCell]) -> Int { (cells.map(\.week).max() ?? -1) + 1 }

    /// VoiceOver row per week: "Week of 6 October: 41 applications, busiest Tuesday with 11".
    static func weekSummary(_ cells: [HeatCell]) -> String {
        guard let first = cells.min(by: { $0.day < $1.day }) else { return "" }
        let total = cells.reduce(0) { $0 + $1.count }
        let start = first.day.formatted(.dateTime.day().month(.wide))
        guard total > 0, let busiest = cells.max(by: { $0.count < $1.count }) else {
            return "Week of \(start): no applications"
        }
        let weekday = busiest.day.formatted(.dateTime.weekday(.wide))
        return "Week of \(start): \(total) application\(total == 1 ? "" : "s"), busiest \(weekday) with \(busiest.count)"
    }

    /// Hover tooltip: "Mon 6 Oct · 11 applications · 2 interviews later".
    static func cellTooltip(_ cell: HeatCell, interviewsLater: Int) -> String {
        let date = cell.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        var s = "\(date) · \(cell.count) application\(cell.count == 1 ? "" : "s")"
        if interviewsLater > 0 { s += " · \(interviewsLater) interview\(interviewsLater == 1 ? "" : "s") later" }
        return s
    }

    /// Interviews/offers that eventually came from applications submitted on each day.
    static func interviewsByDay(jobs: [JobItem], calendar: Calendar = .current) -> [Date: Int] {
        var out: [Date: Int] = [:]
        for job in jobs where job.state == .submitted && (job.status == .interview || job.status == .offer) {
            guard let s = job.submittedAt else { continue }
            out[calendar.startOfDay(for: s), default: 0] += 1
        }
        return out
    }

    // MARK: Variant chart

    static func variantCaption(_ v: VariantStat) -> String {
        v.isLowSample ? "n=\(v.applications) · low sample" : "n=\(v.applications)"
    }
}
