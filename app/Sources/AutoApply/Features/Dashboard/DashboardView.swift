// DashboardView.swift — what the agent did and what needs you, at a glance. A flat header
// (date, greeting, next run · mode), the one global banner, the live agent, then a calm grid of
// numbers and charts. Status only: Run lives in the toolbar, ⌘K and the Agent menu (the live
// agent shows "Run now" only before the very first run). Nothing animates on arrival or at rest.
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
    @State private var isWindowVisible = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.gutter) {
                DashboardHeader()
                    .padding(.bottom, Space.s)
                DashboardBanner()
                LiveAgentCard(isWindowVisible: isWindowVisible)
                AdaptiveColumns(minColumnWidth: 220, maxColumns: 4) {
                    AppliedTodayCard()
                    NeedsYouCard()
                    ResponseRateCard()
                    CapsCard()
                }
                .environment(\.surfaceFillsHeight, true)
                ApplicationsChart()
                AdaptiveColumns(minColumnWidth: 380, maxColumns: 2) {
                    FunnelChart()
                    SourcesChart()
                    VariantChart()
                    ScoreHistogram()
                }
                .environment(\.surfaceFillsHeight, true)
                InsightsCard()
                ActivityHeatmap()
            }
            .padding(Space.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.windowBackground)
        .trackWindowVisibility($isWindowVisible)
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

/// Date, greeting (computed once per session), and on the right the next run and the mode.
private struct DashboardHeader: View {
    @Environment(AppStore.self) private var store
    @State private var greeting: String?

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(DashboardFormat.dateEyebrow(Date())).eyebrowStyle()
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(greeting ?? DashboardFormat.greeting(at: Date(), name: store.library.firstName))
                        .displayStyle()
                        .accessibilityAddTraits(.isHeader)
                    let p = store.library.profile
                    if let lines = GreetingAccent.lines(fullName: p.fullName, firstName: p.firstName, lastName: p.lastName) {
                        AccentMark(text: lines.header)
                    }
                }
            }
            Spacer()
            trailing
        }
        .onAppear {
            if greeting == nil { greeting = DashboardFormat.greeting(at: Date(), name: store.library.firstName) }
        }
        .onChange(of: store.library.firstName) { old, new in
            if old == nil, new != nil { greeting = DashboardFormat.greeting(at: Date(), name: new) }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if store.isPaused {
            Text("Paused · press \(AppShortcut.togglePause.displayString) to resume")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
        } else if !store.isDaemonUnreachable {
            let next = store.nextRunAt
            let refresh = DashboardFormat.needsCountdownRefresh(nextRun: next, now: Date())
            TimelineView(.periodic(from: .now, by: refresh ? 15 : 300)) { timeline in
                HStack(spacing: Space.s) {
                    if let label = DashboardFormat.nextRunLabel(nextRun: next, now: timeline.date) {
                        Text(label)
                        Text("·")
                    }
                    Text(store.mode == .auto ? "Auto: sends on its own" : "Review: waits for your OK")
                }
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

/// A small coral ✦ next to the greeting that opens a short note. Static.
struct AccentMark: View {
    var text: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text("✦").font(Typography.callout).foregroundStyle(Palette.coral)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Note")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text)
                .font(Typography.body)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(Space.l)
        }
    }
}
