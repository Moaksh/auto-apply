// Celebration.swift — the rare, tied-to-an-achievement moments (§2.4, §6). Reduce Motion:
// a single symbol draw-on only.
import SwiftUI

/// Submitted moment: check scale 0.6 → 1.12 → 1.0, opacity 0 → 1, plus a ring expanding
/// 10 → 28 while fading 0.5 → 0. Total 0.6 s. Plays each time `trigger` changes.
struct SubmittedCheck: View {
    var trigger: Int
    var color: Color = Palette.applied
    @Environment(\.motionReduced) private var reduced

    struct Values {
        var scale = 1.0
        var opacity = 1.0
        var ringRadius = 10.0
        var ringOpacity = 0.0
    }

    var body: some View {
        if reduced {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(color)
                .symbolEffect(.drawOn, isActive: false)
                .id(trigger)
                .accessibilityLabel("Applied")
        } else {
            KeyframeAnimator(initialValue: Values(), trigger: trigger) { v in
                ZStack {
                    Circle()
                        .stroke(color.opacity(v.ringOpacity), lineWidth: 1.5)
                        .frame(width: v.ringRadius * 2, height: v.ringRadius * 2)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                        .scaleEffect(v.scale)
                        .opacity(v.opacity)
                }
                .frame(width: 56, height: 56)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.6, duration: 0.0)
                    SpringKeyframe(1.12, duration: 0.25, spring: Motion.Springs.snappy)
                    SpringKeyframe(1.0, duration: 0.35, spring: Motion.Springs.move)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: 0.0)
                    LinearKeyframe(1, duration: 0.2)
                    LinearKeyframe(1, duration: 0.4)
                }
                KeyframeTrack(\.ringRadius) {
                    LinearKeyframe(10, duration: 0.0)
                    CubicKeyframe(28, duration: 0.6)
                }
                KeyframeTrack(\.ringOpacity) {
                    LinearKeyframe(0.5, duration: 0.0)
                    LinearKeyframe(0, duration: 0.6)
                }
            }
            .accessibilityLabel("Applied")
        }
    }
}

/// 12 accent dots bursting radially (inbox zero): Canvas, 0.8 s, fade + decelerate, no gravity.
struct RadialBurst: View {
    var trigger: Int
    var color: Color = Palette.accent
    var count = 12
    var radius: CGFloat = 70
    @State private var start: Date?
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: start == nil || reduced)) { timeline in
            Canvas { ctx, size in
                guard let start else { return }
                let t = timeline.date.timeIntervalSince(start) / 0.8
                guard t < 1 else { return }
                let eased = 1 - pow(1 - t, 3)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<count {
                    let angle = Double(i) / Double(count) * 2 * .pi
                    let p = CGPoint(x: center.x + cos(angle) * radius * eased, y: center.y + sin(angle) * radius * eased)
                    ctx.fill(Circle().path(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(color.opacity(1 - t)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            start = Date()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(850))
                start = nil
            }
        }
    }
}

/// Needs You is empty: a calm check and one honest line.
struct InboxZeroCelebration: View {
    var resumedJobs: Int
    var trigger: Int

    var body: some View {
        EmptyState(symbol: "checkmark.circle", title: "All clear",
                   message: InboxZeroCelebration.message(requeued: resumedJobs))
    }

    /// Jobs only go back to the queue; they apply on the agent's next run.
    static func message(requeued: Int) -> String {
        requeued > 0
            ? "\(requeued) job\(requeued == 1 ? " is" : "s are") back in the queue for the agent's next run."
            : "Nothing needs you right now."
    }
}

#Preview("Celebrations") {
    @Previewable @State var n = 0
    VStack(spacing: Space.xl) {
        SubmittedCheck(trigger: n)
        InboxZeroCelebration(resumedJobs: 14, trigger: n)
        Button("Celebrate") { n += 1 }
    }
    .padding()
}
