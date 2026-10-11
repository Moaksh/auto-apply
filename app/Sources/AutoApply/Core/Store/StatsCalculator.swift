// StatsCalculator.swift — pre-aggregated dashboard statistics (docs/UI_UX_PLAN.md §2.7:
// "No chart is computed from raw rows in body"). Pure functions; StatsStore runs them off
// the hot path when jobs change.
import Foundation

struct DayCount: Sendable, Hashable, Identifiable {
    var id: Date { day }
    var day: Date
    var applied: Int
    var skipped: Int = 0
}

struct FunnelStep: Sendable, Hashable, Identifiable {
    enum Stage: String, Sendable, CaseIterable { case applied, responded, assessment, interview, offer }
    var id: Stage { stage }
    var stage: Stage
    var count: Int
    /// Conversion from the previous step (nil for the first).
    var conversion: Double?
}

struct VariantStat: Sendable, Hashable, Identifiable {
    var id: Int { variantID }
    var variantID: Int
    var label: String
    var applications: Int
    var responses: Int
    var interviews: Int
    var responseRate: Double { applications == 0 ? 0 : Double(responses) / Double(applications) }
    var interviewRate: Double { applications == 0 ? 0 : Double(interviews) / Double(applications) }
    var isLowSample: Bool { applications < 10 }
}

struct ScoreBin: Sendable, Hashable, Identifiable {
    var id: Int { lower }
    /// Inclusive lower bound (0, 5, … 95).
    var lower: Int
    var skipped: Int
    var applied: Int
    var total: Int { skipped + applied }
}

struct SourceStat: Sendable, Hashable, Identifiable {
    var id: JobSource { source }
    var source: JobSource
    var discovered: Int
    var applied: Int
}

enum StatsWindow: String, CaseIterable, Sendable { case days30, days90, all }

struct DashboardStats: Sendable, Hashable {
    var appliedToday = 0
    var discoveredToday = 0
    /// Last 7 days of submissions, oldest first (today last).
    var appliedLast7: [Int] = Array(repeating: 0, count: 7)
    /// Today's count minus the 14-day daily average.
    var appliedTodayDeltaVsAverage: Double = 0
    var appliedLast30 = 0
    /// Responses ÷ applied over the last 30 days (nil when fewer than 10 applications).
    var responseRate30: Double?
    var responseRatePrevious30: Double?
    var daily30: [DayCount] = []
    var funnel30: [FunnelStep] = []
    var funnel90: [FunnelStep] = []
    var funnelAll: [FunnelStep] = []
    var byVariant: [VariantStat] = []
    var scoreHistogram: [ScoreBin] = []
    var sources: [SourceStat] = []
    var easyApplyCount = 0
    /// Last 26 weeks (182 days) of submissions, oldest first.
    var heatmap: [DayCount] = []
    var totalApplied = 0
    var computedAt = Date.distantPast

    func funnel(_ window: StatsWindow) -> [FunnelStep] {
        switch window {
        case .days30: funnel30
        case .days90: funnel90
        case .all: funnelAll
        }
    }
}

enum StatsCalculator {
    static func compute(jobs: [JobItem], variants: [ResumeVariantItem], now: Date = Date(), calendar: Calendar = .current) -> DashboardStats {
        var stats = DashboardStats()
        stats.computedAt = now
        let today = calendar.startOfDay(for: now)
        func dayOffset(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? Int.max
        }

        var perDay: [Int: Int] = [:]          // days ago -> submissions
        var skippedPerDay: [Int: Int] = [:]
        var applied30 = 0, responded30 = 0, applied60to30 = 0, responded60to30 = 0
        var variantAgg: [Int: (apps: Int, resp: Int, intv: Int)] = [:]
        var bins = Array(repeating: (skipped: 0, applied: 0), count: 20)
        var sourceAgg: [JobSource: (disc: Int, applied: Int)] = [:]
        var submittedJobs: [(offset: Int, job: JobItem)] = []

        for job in jobs {
            let discOffset = dayOffset(job.discoveredAt)
            if discOffset == 0 { stats.discoveredToday += 1 }
            if job.easyApply || job.ats == .linkedinEasyApply { stats.easyApplyCount += 1 }
            var src = sourceAgg[job.source, default: (0, 0)]
            src.disc += 1

            if job.state == .skipped, let at = job.stateUpdatedAt {
                skippedPerDay[dayOffset(at), default: 0] += 1
            }

            if let score = job.score, discOffset < 30 {
                let bin = min(19, max(0, score / 5))
                if job.state == .submitted { bins[bin].applied += 1 } else if job.state == .skipped { bins[bin].skipped += 1 }
            }

            if job.state == .submitted, let submittedAt = job.submittedAt {
                let off = dayOffset(submittedAt)
                stats.totalApplied += 1
                src.applied += 1
                perDay[off, default: 0] += 1
                submittedJobs.append((off, job))
                let responded = job.status?.isResponse ?? false
                if off < 30 {
                    applied30 += 1
                    if responded { responded30 += 1 }
                } else if off < 60 {
                    applied60to30 += 1
                    if responded { responded60to30 += 1 }
                }
                if let v = job.resumeVariantID {
                    var agg = variantAgg[v, default: (0, 0, 0)]
                    agg.apps += 1
                    if responded { agg.resp += 1 }
                    if job.status == .interview || job.status == .offer { agg.intv += 1 }
                    variantAgg[v] = agg
                }
            }
            sourceAgg[job.source] = src
        }

        stats.appliedToday = perDay[0, default: 0]
        stats.appliedLast7 = (0..<7).reversed().map { perDay[$0, default: 0] }
        let last14 = (0..<14).reduce(0) { $0 + perDay[$1, default: 0] }
        stats.appliedTodayDeltaVsAverage = Double(stats.appliedToday) - Double(last14) / 14.0
        stats.appliedLast30 = applied30
        stats.responseRate30 = applied30 >= 10 ? Double(responded30) / Double(applied30) : nil
        stats.responseRatePrevious30 = applied60to30 >= 10 ? Double(responded60to30) / Double(applied60to30) : nil

        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: today) ?? today }
        stats.daily30 = (0..<30).reversed().map { DayCount(day: day($0), applied: perDay[$0, default: 0], skipped: skippedPerDay[$0, default: 0]) }
        stats.heatmap = (0..<182).reversed().map { DayCount(day: day($0), applied: perDay[$0, default: 0]) }

        stats.funnel30 = funnel(submittedJobs.filter { $0.offset < 30 }.map(\.job))
        stats.funnel90 = funnel(submittedJobs.filter { $0.offset < 90 }.map(\.job))
        stats.funnelAll = funnel(submittedJobs.map(\.job))

        let labels = Dictionary(variants.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        stats.byVariant = variantAgg.map { id, agg in
            VariantStat(variantID: id, label: labels[id] ?? "Resume #\(id)", applications: agg.apps, responses: agg.resp, interviews: agg.intv)
        }.sorted { $0.applications > $1.applications }

        stats.scoreHistogram = bins.enumerated().map { ScoreBin(lower: $0.offset * 5, skipped: $0.element.skipped, applied: $0.element.applied) }
        stats.sources = sourceAgg.map { SourceStat(source: $0.key, discovered: $0.value.disc, applied: $0.value.applied) }
            .sorted { $0.discovered > $1.discovered }
        return stats
    }

    static func funnel(_ submitted: [JobItem]) -> [FunnelStep] {
        let applied = submitted.count
        let responded = submitted.filter { $0.status?.isResponse ?? false }.count
        // Reaching a later stage implies passing earlier ones on the funnel.
        let assessment = submitted.filter { $0.status == .assessment || $0.status == .interview || $0.status == .offer }.count
        let interview = submitted.filter { $0.status == .interview || $0.status == .offer }.count
        let offer = submitted.filter { $0.status == .offer }.count
        let counts: [(FunnelStep.Stage, Int)] = [(.applied, applied), (.responded, responded), (.assessment, assessment), (.interview, interview), (.offer, offer)]
        var steps: [FunnelStep] = []
        for (i, (stage, count)) in counts.enumerated() {
            let prev = i == 0 ? nil : counts[i - 1].1
            steps.append(FunnelStep(stage: stage, count: count, conversion: prev.map { $0 == 0 ? 0 : Double(count) / Double($0) }))
        }
        return steps
    }

    /// How many jobs per week would qualify at `threshold` (threshold-slider preview).
    static func weeklyQualifying(jobs: [JobItem], threshold: Int, now: Date = Date()) -> Int {
        let since = now.addingTimeInterval(-28 * 86_400)
        let n = jobs.filter { $0.discoveredAt >= since && ($0.score ?? -1) >= threshold }.count
        return Int((Double(n) / 4.0).rounded())
    }
}
