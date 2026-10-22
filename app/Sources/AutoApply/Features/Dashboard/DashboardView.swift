// DashboardView.swift — what the agent did and what needs you, at a glance. The living hero
// band (date, greeting, mode and the live agent on Liquid Glass), the one global banner, then the
// number tiles and charts. Under the hero, "Today's ten minutes" (Briefing/) lists what's waiting
// with estimates; its Start is the Dashboard's one primary while there is work. Under it, the day
// line (DayLine/) runs across today: a chip per event and a coral now marker. Run lives in the
// toolbar, ⌘K and the Agent menu (the live agent shows "Run now" only before the very first run).
//
// The Dashboard is the owner's deliberate exception to the app's calm-at-rest rule
// (2026-10-22): cards rise and fade in once per launch, numbers count up on the first appearance
// of the day, sparklines draw in, tiles lift under the pointer. All of it honours Reduce Motion
// and stops when the window is hidden (see Hero/HeroStyle.swift).
// "What's working" opens the advisory insights report (Dashboard ▸ What's working).
import SwiftUI

@objc(DashboardFeature)
final class DashboardFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.dashboard) { DashboardView() }
    }
}

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @AppStorage(CountUpPolicy.storageKey) private var lastCountUpDay = ""

    @State private var isWindowVisible = true
    @State private var entered = true
    @State private var countUp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.gutter) {
                DashboardHero(isWindowVisible: isWindowVisible)
                    .dashboardEntrance(index: 0)
                    .padding(.bottom, Space.s)
                // "Today's ten minutes": what's waiting, with estimates, and Start (the one primary).
                BriefingCard().dashboardEntrance(index: 1)
                // "Today so far": the day line, what happened and what's waiting, left to right.
                DayLineCard().dashboardEntrance(index: 2)
                DashboardBanner()
                AdaptiveColumns(minColumnWidth: 220, maxColumns: 4) {
                    AppliedTodayCard().dashboardEntrance(index: 1)
                    NeedsYouCard().dashboardEntrance(index: 2)
                    ResponseRateCard().dashboardEntrance(index: 3)
                    CapsCard().dashboardEntrance(index: 4)
                }
                .environment(\.surfaceFillsHeight, true)
                ApplicationsChart().dashboardEntrance(index: 5)
                AdaptiveColumns(minColumnWidth: 380, maxColumns: 2) {
                    FunnelChart().dashboardEntrance(index: 6)
                    SourcesChart().dashboardEntrance(index: 7)
                    VariantChart().dashboardEntrance(index: 8)
                    ScoreHistogram().dashboardEntrance(index: 8)
                }
                .environment(\.surfaceFillsHeight, true)
                InsightsCard().dashboardEntrance(index: 8)
                ActivityHeatmap().dashboardEntrance(index: 8)
            }
            .padding(Space.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.windowBackground)
        .environment(\.dashboardEntered, entered)
        .environment(\.dashboardCountUp, countUp)
        .trackWindowVisibility($isWindowVisible)
        .onAppear(perform: startEntrance)
    }

    /// Once per launch: hide for a frame, then rise in with the stagger. Once per day: numbers
    /// sit at 0 for a beat, then roll up to their values.
    private func startEntrance() {
        if HeroEntrance.claim(reduceMotion: reduced) {
            var hide = Transaction()
            hide.disablesAnimations = true
            withTransaction(hide) { entered = false }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                entered = true
            }
        }
        let now = Date()
        if CountUpPolicy.shouldCountUp(lastStamp: lastCountUpDay, now: now, reduceMotion: reduced) {
            lastCountUpDay = CountUpPolicy.dayStamp(now)
            countUp = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                countUp = false
            }
        }
    }
}

/// The global banner, minus "can't reach the agent": the live agent already says that once.
private struct DashboardBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.issues.contains(where: { $0.id != "daemon_down" }) {
            IssueBannerView(excluding: ["daemon_down"])
        }
    }
}
