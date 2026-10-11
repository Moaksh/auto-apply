// KPIWidgets.swift — W3 Applied Today, W4 Needs You, W5 Response Rate, W6 Caps
// (docs/UI_UX_PLAN.md §4.3), built on C1's Card / KPICard / MetricText / CapBar.
import SwiftUI

/// Shared loading / error resolution for DB-backed widgets (§4.4).
enum WidgetDataState {
    static func resolve(isLoaded: Bool, isAvailable: Bool) -> CardState {
        if isLoaded { return .content }
        return isAvailable ? .loading : .error(message: "Couldn't read stats")
    }
}

/// W3 — submissions today, 7-day sparkline, delta vs the 14-day average; glows once per new
/// submission.
struct AppliedTodayCard: View {
    @Environment(AppStore.self) private var store
    var countUp: Bool

    var body: some View {
        let stats = store.stats
        let state = WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable)
        let value = countUp ? 0 : store.counts.submittedToday
        KPICard(title: "Applied today",
                value: MetricText(value, size: .xl),
                caption: value == 0 && !countUp ? "Nothing yet today" : DashboardFormat.deltaVsAverage(stats.appliedTodayDeltaVsAverage),
                delta: DashboardFormat.appliedTodayDelta(stats.appliedTodayDeltaVsAverage),
                sparkline: stats.appliedLast7,
                state: state,
                glowTrigger: store.live.submittedEventCount)
            .accessibilityLabel("Applied today: \(store.counts.submittedToday). \(DashboardFormat.deltaVsAverage(stats.appliedTodayDeltaVsAverage))")
    }
}

/// W4 — open question clusters + parked jobs. The one loud card: amber when > 0, neutral
/// "All clear" otherwise; plays the arrival PhaseAnimator when a new cluster lands.
struct NeedsYouCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced
    @State private var arrivals = 0

    var body: some View {
        let open = store.inbox.openCount
        let parked = store.counts.needsYouJobs
        Card("Needs you", tint: open > 0 ? Palette.needsYou : nil) {
            if open > 0 {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        badge(open)
                        Text(open == 1 ? "question" : "questions").font(Typography.body)
                    }
                    Text("\(parked) job\(parked == 1 ? "" : "s") parked").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Button {
                        router.go(.needsYou)
                    } label: {
                        HStack(spacing: Space.xs) { Text("Answer"); KeyCap(.nextQuestion) }
                    }
                    .buttonStyle(.glass)
                }
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(Palette.applied)
                        Text("All clear").font(Typography.title2)
                    }
                    Text("Nothing needs you right now.").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .onChange(of: open) { old, new in if new > old { arrivals += 1 } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(open > 0 ? "Needs you: \(open) questions, \(parked) jobs parked" : "Needs you: all clear")
    }

    @ViewBuilder
    private func badge(_ open: Int) -> some View {
        let metric = MetricText(open, size: .xl, color: Palette.needsYou)
        if reduced {
            metric
        } else {
            // §2.4 #2: scale 1 → 1.25 → 1 with an amber flash, once per arrival.
            metric.phaseAnimator([0, 1, 0], trigger: arrivals) { view, phase in
                view.scaleEffect(phase == 1 ? 1.25 : 1, anchor: .leading)
                    .background(Palette.needsYou.opacity(phase == 1 ? 0.2 : 0), in: RoundedRectangle(cornerRadius: 6))
            } animation: { _ in .spring(duration: 0.25, bounce: 0.2) }
        }
    }
}

/// W5 — responses ÷ applied (rolling 30 days), delta vs the previous 30. Ghosted isn't a
/// response. "—" until 10+ applications.
struct ResponseRateCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let stats = store.stats
        let state = WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable)
        let rate = stats.responseRate30
        KPICard(title: "Response rate",
                value: rate.map { MetricText($0, format: .percent(decimals: 0), size: .xl) } ?? MetricText(0, format: .placeholder, size: .xl),
                caption: rate == nil ? "Needs 10+ applications" : "30-day window",
                delta: DashboardFormat.responseRateDelta(current: rate, previous: stats.responseRatePrevious30),
                state: state)
            .help("Responses of any kind (assessment, interview, offer or rejection) ÷ applications, last 30 days. Ghosted doesn't count.")
    }
}

/// W6 — daily cap, company cooldowns, LinkedIn/Glassdoor read budgets. Never red.
struct CapsCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let caps = store.caps
        Card("Caps") {
            VStack(alignment: .leading, spacing: Space.s) {
                CapBar(title: "Applications", used: caps.dailyUsed, limit: max(1, caps.dailyLimit))
                HStack {
                    Text("Per company").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    if caps.companiesCoolingDown > 0 {
                        Text("\(caps.companiesCoolingDown) cooling down").font(Typography.callout)
                    } else {
                        Label("1 / \(store.preferences.perCompanyCooldownDays)d", systemImage: "checkmark")
                            .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                if caps.linkedinSessionsLimit > 0 {
                    CapBar(title: "LinkedIn reads", used: caps.linkedinSessionsUsed, limit: caps.linkedinSessionsLimit)
                }
                if caps.glassdoorSessionsLimit > 0 {
                    CapBar(title: "Glassdoor reads", used: caps.glassdoorSessionsUsed, limit: caps.glassdoorSessionsLimit)
                }
            }
        }
    }
}
