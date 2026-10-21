// States.swift — the one EmptyState, LoadingState and ErrorState, plus SkeletonBlock (static,
// no shimmer) and ThinkingDots. All calm: no brand field, no animation at rest.
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
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .symbolRenderingMode(.hierarchical)
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

/// Static placeholder lines (no shimmer).
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

/// Three 4pt dots, opacity 0.3/1.0 staggered — loops only while `isActive` (the agent is working).
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
        EmptyState(symbol: "tray", title: "All clear", message: "Nothing needs you right now.")
        EmptyState(symbol: "checkmark.rectangle.stack", title: "Nothing to review", message: "Filled applications wait here.",
                   actionTitle: "Run now", isPrimary: true) {}
        LoadingState()
        ErrorState(title: "Can't reach the agent", message: "Last seen 14:02", actionTitle: "Restart agent", action: {})
        ErrorState(title: "Couldn't read stats", compact: true, actionTitle: "Try again", action: {})
    }
    .padding()
}
