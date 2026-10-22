// States.swift — the one EmptyState, LoadingState and ErrorState, plus SkeletonBlock and
// ThinkingDots. All calm: no brand field, no animation at rest.
//
// Motion: an empty / success state's symbol greets you once on appear (a gentle bounce; custom
// `aa.*` symbols draw on: `aa.plane.trail` draws its trail). A skeleton shimmers slowly while its
// data is on its way, only while the window is visible, at most `Motion.Budget.shimmerLimit`, and
// never under Reduce Motion; when the content arrives it replaces the skeleton with a cross-fade
// (`Surface`, `.motionTransition(.fade)`). ThinkingDots loop only while the agent is working.
import SwiftUI

/// Symbol + title + one line + at most one action. The action is a text link unless the state
/// is a screen's first-run moment (`isPrimary`), when it is the screen's primary pill.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String?
    var actionTitle: String?
    var isPrimary: Bool = false
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.s) {
            Group {
                if let custom = AASymbol(rawValue: symbol) {
                    AASymbolDrawOn(symbol: custom, size: 34)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 32, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .symbolGreeting()
                }
            }
            .foregroundStyle(Palette.textTertiary)
            .padding(.bottom, Space.xs)
            Text(title).font(Typography.title2).multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Group {
                    if isPrimary {
                        Button(actionTitle, action: action).buttonStyle(.primaryPill)
                    } else {
                        Button(actionTitle, action: action).buttonStyle(.secondaryLink)
                    }
                }
                .padding(.top, Space.s)
            }
        }
        .padding(Space.xxl)
        .accessibilityElement(children: .contain)
    }
}

/// "Loading…" for a screen or pane whose data hasn't arrived yet.
struct LoadingState: View {
    var message: String = "Loading…"

    var body: some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text(message).font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A screen- or widget-level error with one fix. `compact` is the inline widget form
/// ("Couldn't read stats · Try again"); the rest of the screen keeps working.
struct ErrorState: View {
    var title: String
    var message: String?
    var compact: Bool = false
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    init(title: String, message: String? = nil, compact: Bool = false, actionTitle: String? = nil, action: (() -> Void)? = nil,
         secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.compact = compact
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        if compact {
            HStack(spacing: Space.s) {
                Image(systemName: StatusKind.error.symbol).foregroundStyle(Palette.error)
                Text(title).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.secondaryLink).font(Typography.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: Space.s) {
                Image(systemName: StatusKind.error.symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Palette.error)
                    .padding(.bottom, Space.xs)
                Text(title).font(Typography.title2).multilineTextAlignment(.center)
                if let message {
                    Text(message).font(Typography.body).foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                HStack(spacing: Space.l) {
                    if let actionTitle, let action {
                        Button(actionTitle, action: action).buttonStyle(.primaryPill)
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction).buttonStyle(.secondaryLink)
                    }
                }
                .padding(.top, Space.s)
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Placeholder lines while data is on its way. A slow, soft sweep runs across them (Tier 2: only
/// while visible, never under Reduce Motion, and it stops after `Motion.Budget.shimmerLimit`).
struct SkeletonBlock: View {
    var lines: Int = 3
    var lineHeight: CGFloat = 10
    @Environment(\.motionReduced) private var reduced
    @State private var windowVisible = true
    @State private var expired = false

    var body: some View {
        let shimmering = !reduced && !expired
        placeholder
            .overlay {
                if shimmering {
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !windowVisible)) { timeline in
                        SkeletonSweep(phase: Motion.shimmerPhase(at: timeline.date))
                    }
                    .mask { placeholder }
                    .allowsHitTesting(false)
                }
            }
            .trackWindowVisibility($windowVisible)
            .task {
                try? await Task.sleep(for: Motion.Budget.shimmerLimit)
                expired = true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(0..<max(1, lines), id: \.self) { i in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Palette.hairline)
                    .frame(height: lineHeight)
                    .frame(maxWidth: i == lines - 1 ? 140 : .infinity, alignment: .leading)
            }
        }
    }
}

/// The shimmer band: a soft highlight crossing from leading to trailing.
private struct SkeletonSweep: View {
    var phase: Double

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            LinearGradient(colors: [.clear, Palette.surface.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(60, w * 0.35))
                .offset(x: -w * 0.35 + (w * 1.35) * phase)
        }
    }
}

/// A custom `aa.*` symbol that draws on once when it appears (`aa.plane.trail` draws its trail;
/// the others fade up). The rest pose is the finished symbol, so a renderer that never animates
/// draws it complete. Nothing under Reduce Motion.
struct AASymbolDrawOn: View {
    var symbol: AASymbol
    var size: CGFloat = 32
    @Environment(\.motionReduced) private var reduced
    @State private var appeared = 0

    var body: some View {
        AASymbolView(symbol, size: size)
            .hidden()
            .overlay {
                Color.clear.keyframeAnimator(initialValue: 1.0, trigger: appeared) { _, progress in
                    AASymbolView(symbol, size: size, progress: symbol == .planeTrail ? progress : 1)
                        .opacity(symbol == .planeTrail ? 1 : 0.4 + 0.6 * progress)
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(0)
                        SpringKeyframe(1, duration: 0.9, spring: Motion.Springs.flow)
                    }
                }
            }
            .onAppear { if !reduced { appeared += 1 } }
            .accessibilityElement()
            .accessibilityLabel(symbol.accessibilityLabel)
    }
}

/// Three 4pt dots, opacity 0.3/1.0 staggered — loops only while `isActive` (the agent is working).
struct ThinkingDots: View {
    var isActive: Bool
    var color: Color = Palette.textSecondary
    @Environment(\.motionReduced) private var reduced
    @State private var windowVisible = true

    var body: some View {
        Group {
            // Paused (still dots) while the window is hidden: no frames for nobody.
            if isActive && !reduced && windowVisible {
                PhaseAnimator([0, 1, 2]) { phase in
                    dots(highlight: phase)
                } animation: { _ in Motion.tick }
            } else {
                dots(highlight: -1)
            }
        }
        .trackWindowVisibility($windowVisible)
    }

    private func dots(highlight: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(color).frame(width: 4, height: 4).opacity(highlight == i || highlight < 0 ? 1 : 0.3)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("States") {
    VStack {
        EmptyState(symbol: "tray", title: "All clear", message: "Nothing needs you right now.")
        EmptyState(symbol: "checkmark.rectangle.stack", title: "Nothing to review", message: "Filled applications wait here.",
                   actionTitle: "Run now", isPrimary: true) {}
        LoadingState()
        ErrorState(title: "Can't reach the agent", message: "Last seen 14:02", actionTitle: "Restart agent", action: {})
        ErrorState(title: "Couldn't read stats", compact: true, actionTitle: "Try again", action: {})
    }
    .padding()
}
