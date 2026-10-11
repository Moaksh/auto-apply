// States.swift — EmptyState, SkeletonBlock (static, no shimmer), LoadingState, ErrorState,
// ThinkingDots.
import SwiftUI

/// Symbol + title + body + optional action.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.textTertiary)
            Text(title).font(Typography.title2)
            if let message {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.glassProminent)
            }
        }
        .padding(Space.xxl)
        .accessibilityElement(children: .combine)
    }
}

/// Static placeholder shapes (shimmer is decoration; we don't do it — §4.4).
struct SkeletonBlock: View {
    var lines: Int = 3
    var lineHeight: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(0..<max(1, lines), id: \.self) { i in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Palette.hairline)
                    .frame(height: lineHeight)
                    .frame(maxWidth: i == lines - 1 ? 140 : .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel("Loading")
    }
}

/// Skeleton circle (pipeline nodes, avatars).
struct SkeletonCircle: View {
    var diameter: CGFloat = 24
    var body: some View {
        Circle().stroke(Palette.hairline, lineWidth: 1).frame(width: diameter, height: diameter)
    }
}

/// Full-area error with one fix action (e.g. "Can't reach autoapplyd · Restart daemon").
struct ErrorState: View {
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: StatusKind.error.symbol)
                .font(.system(size: 32))
                .foregroundStyle(Palette.error)
            Text(title).font(Typography.title2)
            if let message {
                Text(message).font(Typography.callout).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
            }
            HStack(spacing: Space.s) {
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction).buttonStyle(.glass)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.glassProminent)
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Three 4pt dots, opacity 0.3/1.0 staggered — loops only while `isActive` (§2.4 #4).
struct ThinkingDots: View {
    var isActive: Bool
    var color: Color = Palette.textSecondary
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        if isActive && !reduced {
            PhaseAnimator([0, 1, 2]) { phase in
                dots(highlight: phase)
            } animation: { _ in .easeInOut(duration: 0.3) }
        } else {
            dots(highlight: -1)
        }
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
        EmptyState(symbol: "tray", title: "All caught up.", message: "14 jobs resumed. The agent's back at it.", actionTitle: "Run Prep pass") {}
        SkeletonBlock().frame(width: 240)
        ErrorState(title: "Can't reach autoapplyd", message: "Last seen 14:02", actionTitle: "Restart daemon", action: {})
        ThinkingDots(isActive: true)
    }
    .padding()
}
