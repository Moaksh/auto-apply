// InsightsModel.swift — Dashboard ▸ What's working (contract/protocol.md §5.3): loads the
// advisory report (served from the agent's 6-hour cache), Refresh (`force`), and the optional
// Summarize (`summarize`, one Claude request). Nothing here changes a setting.
import Foundation
import Observation

@MainActor
@Observable
final class InsightsModel {
    enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let store: AppStore
    private(set) var insights: Insights?
    private(set) var phase: Phase = .idle
    private(set) var isRefreshing = false
    private(set) var isSummarizing = false
    /// A refresh or summary that failed while an earlier report stays on screen.
    private(set) var actionError: String?

    static func shared(for store: AppStore) -> InsightsModel {
        FeatureModels.model(InsightsModel.self, for: store) { InsightsModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

    /// Tests / previews: show a report without asking the agent.
    func show(_ insights: Insights) {
        self.insights = insights
        phase = .loaded
    }

    func loadIfNeeded() async {
        guard insights == nil, phase != .loading else { return }
        await load()
    }

    /// The report; `force` recomputes instead of using the cache.
    func load(force: Bool = false) async {
        if insights == nil { phase = .loading }
        if force { isRefreshing = true }
        actionError = nil
        defer { isRefreshing = false }
        if let result = await store.fetchInsights(force: force) {
            insights = result
            phase = .loaded
        } else if insights == nil {
            phase = .failed(store.lastOutreachErrorMessage)
        } else {
            actionError = "Couldn't refresh: \(store.lastOutreachErrorMessage)"
        }
    }

    /// Ask the model for a short summary of the upskill hints (costs tokens; cached with the report).
    func summarize() async {
        guard !isSummarizing else { return }
        isSummarizing = true
        actionError = nil
        defer { isSummarizing = false }
        if let result = await store.fetchInsights(force: false, summarize: true) {
            insights = result
            phase = .loaded
        } else {
            actionError = "Couldn't summarize: \(store.lastOutreachErrorMessage)"
        }
    }
}

/// Plain-language formatting for the report (kept out of the views so it is testable).
enum InsightsFormat {
    static let notEnoughData = "Not enough data yet"

    /// "40% replied · 12% interviews", or "Not enough data yet" below the sample floor.
    static func bandRates(_ band: ScoreBand) -> String {
        guard band.enoughData, let response = band.responseRate else { return notEnoughData }
        var text = "\(ChartMath.percent(response)) heard back"
        if let interview = band.interviewRate { text += " · \(ChartMath.percent(interview)) interviews" }
        return text
    }

    /// "Applied 14 · heard back from 6"
    static func bandCounts(_ band: ScoreBand) -> String {
        "\(band.applications) applied · \(band.responses) heard back"
    }

    /// The fine print under the bands.
    static func calibrationFootnote(_ c: ScoreCalibration) -> String {
        var parts = ["Rates show from \(c.minBandSample) applications in a score range"]
        if c.inFlight > 0 { parts.append("\(c.inFlight) applied in the last 14 days aren't counted yet") }
        if c.unscored > 0 { parts.append("\(c.unscored) without a score left out") }
        parts.append("your match threshold is \(c.matchThreshold)")
        return parts.joined(separator: " · ") + "."
    }

    /// The agent's per-variant counts in the Dashboard chart's shape.
    static func variantStats(_ v: VariantInsights) -> [VariantStat] {
        v.variants.map { VariantStat(variantID: $0.resumeVariantId, label: $0.label, applications: $0.applications,
                                     responses: $0.responses, interviews: $0.interviews) }
    }

    /// "Updated 2 hours ago" (+ " · saved copy" when served from the cache).
    static func updated(_ insights: Insights, now: Date = Date()) -> String {
        let rel = insights.computedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        let when = abs(now.timeIntervalSince(insights.computedAt)) < 60 ? "just now" : rel
        return "Updated \(when)" + (insights.cached ? " · saved copy, refreshed every 6 hours" : "")
    }

    static func kindLabel(_ kind: RequirementBlocker.Kind) -> String {
        switch kind {
        case .skill: "Skill"
        case .theme: "Theme"
        case .requirement: "Requirement"
        }
    }

    static let upskillAdvice = "Learn it if it fits your direction; never claim a skill you don't have."
    static let advisory = "Advisory only. This reads your own results; nothing is changed automatically."
}
