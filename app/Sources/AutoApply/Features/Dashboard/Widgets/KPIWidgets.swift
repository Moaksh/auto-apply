// KPIWidgets.swift — the four number tiles: Applied today, Needs You, Response rate, Daily
// limits. Each is a Surface with one number that counts up on the first Dashboard appearance of
// the day; tiles lift slightly under the pointer, the trend line draws in with the entrance, and
// Applied today flashes an accent hairline when an application goes out (Hero/HeroStyle.swift).
import SwiftUI

/// A change in a metric ("3pt", up).
struct MetricDelta: Equatable {
    var text: String
    var isPositive: Bool
}

/// Shared loading / error resolution for DB-backed widgets.
enum WidgetDataState {
    static func resolve(isLoaded: Bool, isAvailable: Bool) -> SurfaceState {
        if isLoaded { return .content }
        return isAvailable ? .loading : .error(message: "Couldn't read stats")
    }
}

/// A tile: big number, optional trend line, one caption.
private struct MetricTile<Extra: View>: View {
    var title: String
    var state: SurfaceState = .content
    var value: MetricText
    var caption: String?
    var glowTrigger: Int = 0
    @ViewBuilder var extra: () -> Extra

    @Environment(\.dashboardCountUp) private var countUp

    var body: some View {
        Surface(title, state: state) {
            VStack(alignment: .leading, spacing: Space.s) {
                countUp && value.format != .placeholder ? MetricText(0, format: value.format, size: value.size, color: value.color) : value
                extra()
                if let caption {
                    Text(caption).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .hoverLift(glowTrigger: glowTrigger)
        .accessibilityElement(children: .combine)
    }
}

/// Applications sent today, a 7-day trend, and the difference from the 14-day average.
struct AppliedTodayCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let stats = store.stats
        let value = store.counts.submittedToday
        MetricTile(title: "Applied today",
                   state: WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable),
                   value: MetricText(value, size: .xl),
                   caption: value == 0 ? "Nothing yet today" : DashboardFormat.deltaVsAverage(stats.appliedTodayDeltaVsAverage),
                   glowTrigger: store.live.submittedEventCount) {
            Sparkline(values: stats.appliedLast7).frame(height: 28).drawIn()
        }
        .accessibilityLabel("Applied today: \(value). \(DashboardFormat.deltaVsAverage(stats.appliedTodayDeltaVsAverage))")
    }
}

/// Open questions and tasks, and the jobs waiting on them. "All clear" when there are none.
struct NeedsYouCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dashboardCountUp) private var countUp

    var body: some View {
        let open = store.inbox.openCount
        let waiting = store.counts.needsYouJobs
        Surface("Needs You") {
            if open > 0 {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        MetricText(countUp ? 0 : open, size: .xl, color: Palette.needsYou)
                        Text(open == 1 ? "question or task" : "questions and tasks").font(Typography.body)
                    }
                    Text("\(waiting) job\(waiting == 1 ? "" : "s") waiting for you").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Button {
                        router.go(.needsYou)
                    } label: {
                        HStack(spacing: Space.xs) { Text("Answer"); KeyCap(.nextQuestion) }
                    }
                    .buttonStyle(.secondaryLink)
                }
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label("All clear", systemImage: "checkmark.circle")
                        .font(Typography.title2)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Nothing needs you right now.").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .hoverLift()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(open > 0 ? "Needs You: \(open) questions or tasks, \(waiting) jobs waiting" : "Needs You: all clear")
    }
}

/// Responses ÷ applications over 30 days, vs the previous 30. Ghosted isn't a response. "—"
/// until there are 10+ applications.
struct ResponseRateCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let stats = store.stats
        let rate = stats.responseRate30
        let delta = DashboardFormat.responseRateDelta(current: rate, previous: stats.responseRatePrevious30)
        MetricTile(title: "Response rate",
                   state: WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable),
                   value: rate.map { MetricText($0, format: .percent(decimals: 0), size: .xl) } ?? MetricText(0, format: .placeholder, size: .xl),
                   caption: rate == nil ? "Shown after 10 applications" : "Last 30 days\(delta.map { " · \($0.isPositive ? "up" : "down") \($0.text)" } ?? "")") {
            EmptyView()
        }
        .help("Responses of any kind (assessment, interview, offer or rejection) ÷ applications, last 30 days. Ghosted doesn't count.")
    }
}

/// Daily limits: applications today, per-company cooldown, LinkedIn / Glassdoor visits. Never red.
struct CapsCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dashboardCountUp) private var countUp

    var body: some View {
        let caps = store.caps
        Surface("Daily limits") {
            VStack(alignment: .leading, spacing: Space.s) {
                CapBar(title: "Applications", used: countUp ? 0 : caps.dailyUsed, limit: max(1, caps.dailyLimit))
                HStack {
                    Text("Per company").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text(caps.companiesCoolingDown > 0
                         ? "\(caps.companiesCoolingDown) waiting out the \(store.preferences.perCompanyCooldownDays)-day gap"
                         : "1 every \(store.preferences.perCompanyCooldownDays) days")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
                if caps.linkedinSessionsLimit > 0 {
                    CapBar(title: "LinkedIn visits", used: caps.linkedinSessionsUsed, limit: caps.linkedinSessionsLimit)
                }
                if caps.glassdoorSessionsLimit > 0 {
                    CapBar(title: "Glassdoor visits", used: caps.glassdoorSessionsUsed, limit: caps.glassdoorSessionsLimit)
                }
            }
        }
        .hoverLift()
    }
}
