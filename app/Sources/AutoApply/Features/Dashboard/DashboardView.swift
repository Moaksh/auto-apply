// DashboardView.swift — the instrument panel (docs/UI_UX_PLAN.md §4): greeting header with the
// single global banner, the Live Agent hero, then a calm adaptive grid of widgets. Cards stagger
// in once (`cardIn`, 30 ms, max 8); numbers count up from 0 only on the first launch of the day.
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

    @State private var contentWidth: CGFloat = 1200
    @State private var appeared = false
    @State private var countUp = false
    @State private var isWindowVisible = true

    var body: some View {
        let layout = DashboardLayout(contentWidth: contentWidth)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.gutter) {
                DashboardHeader()
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.xl + Space.s)
                    .padding(.bottom, Space.xl)
                    .brandHeroBand(isActive: isWindowVisible)
                    .entrance(index: 0, appeared: appeared, reduced: reduced)
                IssueBannerView()
                LiveAgentCard(layout: layout, isWindowVisible: isWindowVisible)
                    .entrance(index: 1, appeared: appeared, reduced: reduced)
                kpiRow(layout)
                    .entrance(index: 2, appeared: appeared, reduced: reduced)
                charts(layout)
                ActivityHeatmap()
                    .entrance(index: 8, appeared: appeared, reduced: reduced)
            }
            .padding(Space.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - Space.contentPadding * 2 } action: { contentWidth = $0 }
        .background(Palette.windowBackground)
        .trackWindowVisibility($isWindowVisible)
        .onAppear(perform: startEntrance)
    }

    // MARK: Rows

    @ViewBuilder
    private func kpiRow(_ layout: DashboardLayout) -> some View {
        if layout == .wide {
            HStack(alignment: .top, spacing: Space.gutter) {
                AppliedTodayCard(countUp: countUp)
                NeedsYouCard()
                ResponseRateCard()
                CapsCard()
            }
        } else {
            Grid(horizontalSpacing: Space.gutter, verticalSpacing: Space.gutter) {
                GridRow { AppliedTodayCard(countUp: countUp); NeedsYouCard() }
                GridRow { ResponseRateCard(); CapsCard() }
            }
        }
    }

    @ViewBuilder
    private func charts(_ layout: DashboardLayout) -> some View {
        if layout == .wide {
            HStack(alignment: .top, spacing: Space.gutter) {
                VStack(spacing: Space.gutter) {
                    ApplicationsChart().entrance(index: 3, appeared: appeared, reduced: reduced)
                    HStack(alignment: .top, spacing: Space.gutter) {
                        VariantChart().entrance(index: 5, appeared: appeared, reduced: reduced)
                        ScoreHistogram().entrance(index: 6, appeared: appeared, reduced: reduced)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: Space.gutter) {
                    FunnelChart().entrance(index: 4, appeared: appeared, reduced: reduced)
                    SourcesChart().entrance(index: 7, appeared: appeared, reduced: reduced)
                }
                .frame(width: max(320, contentWidth * 0.36))
            }
        } else {
            VStack(spacing: Space.gutter) {
                ApplicationsChart().entrance(index: 3, appeared: appeared, reduced: reduced)
                FunnelChart().entrance(index: 4, appeared: appeared, reduced: reduced)
                VariantChart().entrance(index: 5, appeared: appeared, reduced: reduced)
                ScoreHistogram().entrance(index: 6, appeared: appeared, reduced: reduced)
                SourcesChart().entrance(index: 7, appeared: appeared, reduced: reduced)
            }
        }
    }

    private func startEntrance() {
        let now = Date()
        if CountUpPolicy.shouldCountUp(lastStamp: lastCountUpDay, now: now, reduceMotion: reduced) {
            countUp = true
            lastCountUpDay = CountUpPolicy.dayStamp(now)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                countUp = false   // MetricText's numericText roll animates 0 → value
            }
        }
        guard !appeared else { return }
        if reduced {
            appeared = true
        } else {
            withAnimation(Motion.settle) { appeared = true }
        }
    }
}

/// W1 — date eyebrow, time-of-day greeting (computed once per session), next run, mode.
/// Sits on the live brand gradient band (`brandHeroBand`), so it always renders on dark.
private struct DashboardHeader: View {
    @Environment(AppStore.self) private var store
    @State private var greeting: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(DashboardFormat.dateEyebrow(Date())).eyebrowStyle()
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(greeting ?? DashboardFormat.greeting(at: Date(), name: store.library.firstName))
                        .heroDisplayStyle()
                    let p = store.library.profile
                    if let lines = GreetingAccent.lines(fullName: p.fullName, firstName: p.firstName, lastName: p.lastName) {
                        AccentMark(text: lines.header, seenKey: "dashboard.accent.seen")
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
            Text("Paused · resumes when you press \(AppShortcut.togglePause.displayString)")
                .font(Typography.callout).foregroundStyle(Palette.needsYou)
        } else if store.isDaemonUnreachable {
            StatusChip(.error, label: "Daemon down")
        } else {
            let next = store.nextRunAt
            let refresh = DashboardFormat.needsCountdownRefresh(nextRun: next, now: Date())
            TimelineView(.periodic(from: .now, by: refresh ? 15 : 300)) { timeline in
                HStack(spacing: Space.s) {
                    if let label = DashboardFormat.nextRunLabel(nextRun: next, now: timeline.date) {
                        Text(label)
                    }
                    Text("·").foregroundStyle(Palette.textTertiary)
                    Text(store.mode == .auto ? "Auto" : "Review")
                    Circle().fill(store.mode == .auto ? Palette.applied : Palette.accent).frame(width: 7, height: 7)
                }
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

private struct EntranceModifier: ViewModifier {
    var index: Int
    var appeared: Bool
    var reduced: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduced ? 0 : 8)
            .scaleEffect(appeared || reduced ? 1 : 0.98)
            .animation(reduced ? nil : Motion.settle.delay(Motion.staggerDelay(index: index)), value: appeared)
    }
}

private extension View {
    /// `cardIn` with the 30 ms stagger (max 8 staggered).
    func entrance(index: Int, appeared: Bool, reduced: Bool) -> some View {
        modifier(EntranceModifier(index: index, appeared: appeared, reduced: reduced))
    }
}

/// A faint ✦ that opens a short note; shimmers once the first time it appears.
struct AccentMark: View {
    var text: String
    var seenKey: String
    @Environment(\.motionReduced) private var reduced
    @State private var open = false
    @State private var glow = false

    var body: some View {
        Button { open.toggle() } label: {
            Text("✦")
                .font(Typography.callout)
                .foregroundStyle(Palette.coral.opacity(glow ? 1 : 0.6))
                .scaleEffect(glow ? 1.35 : 1)
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
        .task {
            guard !UserDefaults.standard.bool(forKey: seenKey), !reduced else { return }
            UserDefaults.standard.set(true, forKey: seenKey)
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true)) { glow = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.4)) { glow = false }
        }
    }
}
