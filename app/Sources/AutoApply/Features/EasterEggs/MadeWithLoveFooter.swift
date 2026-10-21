// MadeWithLoveFooter.swift — "Made with ♥ by Moaksh Kakkar" in the Settings footer. The heart
// has a secret: each tap pumps it a little bigger and redder (with a count from the second tap
// and a tiny heart floating off), and the seventh tap in a row bursts it. Pause and it calms down.
import SwiftUI

struct MadeWithLoveFooter: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @State private var taps = 0
    @State private var cooldown: Task<Void, Never>?
    @State private var floaters: [UUID] = []

    private typealias Meter = EasterEggs.HeartMeter

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Made with")
            // A tap gesture (not a Button) so the burst can start right where the click landed.
            heart
                .onTapGesture(coordinateSpace: .global) { tap(at: $0) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { tap(at: nil) }
                .help("Psst… this heart likes attention. ⌘K knows a few secrets too: try “secret”.")
                .accessibilityLabel("love")
                .accessibilityHint("Tap it a few times")
            let p = store.library.profile
            let accent = GreetingAccent.lines(fullName: p.fullName, firstName: p.firstName, lastName: p.lastName)
            // An accent line that starts with "by " takes the byline's place; others sit beside it.
            if let footer = accent?.footer, footer.hasPrefix("by ") {
                Text(footer)
            } else {
                Text("by Moaksh Kakkar")
                if let footer = accent?.footer {
                    AccentMark(text: footer, seenKey: "settings.accent.seen")
                }
            }
            Spacer()
        }
        .font(Typography.callout)
        .foregroundStyle(Palette.textTertiary)
        .padding(.vertical, Space.s)
    }

    private var heart: some View {
        Image(systemName: "heart.fill")
            .foregroundStyle(EggTone.color(.love).opacity(Meter.intensity(taps: taps)))
            .scaleEffect(reduced ? 1 : Meter.scale(taps: taps))
            .modifier(TapBounce(trigger: taps, enabled: !reduced))
            .overlay {
                ForEach(floaters, id: \.self) { id in
                    HeartFloater().id(id)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge = Meter.badge(taps: taps) {
                    Text(badge)
                        .font(Typography.monoSmall)
                        .foregroundStyle(EggTone.color(.love))
                        .contentTransition(.numericText(value: Double(taps)))
                        .fixedSize()
                        .offset(x: 16, y: -9)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
    }

    private func tap(at location: CGPoint?) {
        cooldown?.cancel()
        let next = taps + 1
        if next >= Meter.tapsToBurst {
            withMotion(Motion.celebrate, reduceMotion: reduced) { taps = 0 }
            EasterEggs.reveal(.heart, origin: location)
            return
        }
        withMotion(Motion.celebrate, reduceMotion: reduced) { taps = next }
        Sounds.play(.tap)
        if next >= 4 { Haptics.alignment() }  // "getting warmer"
        if !reduced {
            let id = UUID()
            floaters.append(id)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                floaters.removeAll { $0 == id }
            }
        }
        cooldown = Task { @MainActor in
            try? await Task.sleep(for: Meter.cooldown)
            guard !Task.isCancelled else { return }
            withMotion(Motion.gentle, reduceMotion: reduced) { taps = 0 }
        }
    }
}

/// A quick squash-and-stretch on every tap.
private struct TapBounce: ViewModifier {
    var trigger: Int
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, s in
                view.scaleEffect(s)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.35, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                }
            }
        } else {
            content
        }
    }
}

/// A small heart drifting up and away from the big one.
private struct HeartFloater: View {
    @State private var away = false
    private let drift = Double.random(in: -10...10)

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(EggTone.color(.love))
            .offset(x: away ? drift : 0, y: away ? -22 : 0)
            .opacity(away ? 0 : 0.9)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.8)) { away = true } }
    }
}
