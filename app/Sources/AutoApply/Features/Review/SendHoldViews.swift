// SendHoldViews.swift — what a held approval looks like: a capsule with a draining ring,
// "Sending in 5…" and Undo (Review rows, the Review detail, Job detail's header), plus the
// "Not sent — approve again" badge for holds a quit cut short.
import SwiftUI

/// "◔ Sending in 4…  Undo". The ring drains linearly over the window (an honest countdown);
/// under Reduce Motion the ring stays still and only the number counts down, once a second.
struct SendHoldCapsule: View {
    var entry: SendHoldModel.Entry
    var onUndo: () -> Void
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        HStack(spacing: Space.s) {
            if entry.isSending {
                ProgressView().controlSize(.mini)
                Text("Sending…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            } else {
                countdown
                Button("Undo", action: onUndo)
                    .buttonStyle(.secondaryLink)
                    .help("Don't send it (⌘Z). Quitting now also stops it from being sent.")
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xxs)
        .background(Palette.sunken, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var countdown: some View {
        if reduced {
            TimelineView(.periodic(from: entry.heldAt, by: 1)) { context in
                label(now: context.date, fraction: 1)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                label(now: context.date,
                      fraction: SendHoldTiming.fraction(until: entry.deadline, window: entry.window, now: context.date))
            }
        }
    }

    private func label(now: Date, fraction: Double) -> some View {
        let seconds = max(1, SendHoldTiming.secondsLeft(until: entry.deadline, now: now))
        return HStack(spacing: Space.xs) {
            SendHoldRing(fraction: fraction)
            Text("Sending in \(seconds)…")
                .font(Typography.callout)
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sending in \(seconds) seconds")
    }
}

/// A 12 pt ring that drains from full (1) to empty (0).
struct SendHoldRing: View {
    var fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// Shown on a job whose approval was held when the app quit: it was never sent.
struct NotSentBadge: View {
    var body: some View {
        Badge("Not sent — approve again", symbol: "exclamationmark.arrow.circlepath", tone: .warning,
              accessibilityText: "Not sent. The app quit before this approval went out. Approve again to send it.")
            .help("The app quit while this approval was on hold, so it wasn't sent. Approve again to send it.")
    }
}
