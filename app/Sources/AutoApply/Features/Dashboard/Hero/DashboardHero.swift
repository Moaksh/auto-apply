// DashboardHero.swift — the top of the Dashboard: one living brand band (deep green / ink /
// navy mesh with a coral hint, radius 22) carrying the date, a large greeting, the mode, and the
// live agent on Liquid Glass. Always drawn in dark appearance (it is media), in both themes.
//
// Motion with meaning: the field drifts slowly at rest (10 fps) and a little livelier while the
// agent works (20 fps); a faint coral warmth breathes behind the greeting. Everything holds still
// when the window is hidden, the agent is paused or unreachable, or Reduce Motion is on.
import SwiftUI

struct DashboardHero: View {
    var isWindowVisible: Bool

    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced

    /// Whether the hero's continuous motion runs (pure, unit-tested).
    static func motionActive(state: HeroState, windowVisible: Bool, reduceMotion: Bool) -> Bool {
        guard windowVisible, !reduceMotion else { return false }
        switch state {
        case .paused, .unreachable, .loading: return false
        default: return true
        }
    }

    var body: some View {
        let state = store.heroState
        let live = Self.motionActive(state: state, windowVisible: isWindowVisible, reduceMotion: reduced)
        VStack(alignment: .leading, spacing: Space.xl) {
            DashboardHeader()
            LiveAgentCard(isWindowVisible: isWindowVisible)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.xl + Space.s)
        .padding(.bottom, Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            // Coral warmth in the far corner: the brand's warm accent, breathing very slowly.
            HeroBreath(color: Palette.Brand.coral, period: 11, radius: 220, minOpacity: 0.06, maxOpacity: 0.16)
                .offset(x: 120, y: -150)
        }
        .brandHeroBand(isActive: live, frameRate: state.isRunning ? HeroFrameRate.ambient : HeroFrameRate.ambientIdle)
        .saturation(state == .paused ? 0.55 : 1)
        .environment(\.heroMotionActive, live)
    }
}

/// Date, a large greeting (computed once per session), and the mode on a glass capsule.
private struct DashboardHeader: View {
    @Environment(AppStore.self) private var store
    @State private var greeting: String?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(DashboardFormat.dateEyebrow(Date()))
                    .font(Typography.caption).textCase(.uppercase).tracking(1.2)
                    .foregroundStyle(Palette.Brand.coral.opacity(0.9))
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(greeting ?? DashboardFormat.greeting(at: Date(), name: store.library.firstName))
                        .font(.system(size: 46, weight: .semibold))
                        .tracking(-1.4)
                        .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .accessibilityAddTraits(.isHeader)
                    let p = store.library.profile
                    if let lines = GreetingAccent.lines(fullName: p.fullName, firstName: p.firstName, lastName: p.lastName) {
                        AccentMark(text: lines.header, font: .system(size: 20), color: Palette.Brand.coral)
                    }
                }
            }
            Spacer(minLength: Space.l)
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
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Space.m)
                .padding(.vertical, 6)
                .heroGlass(in: Capsule())
        } else if !store.isDaemonUnreachable {
            HStack(spacing: Space.s) {
                Circle()
                    .fill(store.mode == .auto ? Palette.applied : Palette.Brand.signal)
                    .frame(width: 7, height: 7)
                Text(store.mode == .auto ? "Auto · sends on its own" : "Review · waits for your OK")
            }
            .font(Typography.callout)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, Space.m)
            .padding(.vertical, 6)
            .heroGlass(in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }
}

/// A small coral ✦ next to the greeting (and in the Settings footer) that opens a short note.
/// Static.
struct AccentMark: View {
    var text: String
    var font: Font = Typography.callout
    var color: Color = Palette.coral
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text("✦").font(font).foregroundStyle(color)
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
