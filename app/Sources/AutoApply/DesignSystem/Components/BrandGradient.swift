// BrandGradient.swift — the brand media field: deep green → ink → navy with a hint of coral.
// Used only behind onboarding (the one place the app is "media"); never on ordinary screens or
// controls.
//
// Calm by default: the field is a static frame. It drifts (a 3×3 `MeshGradient` on long,
// co-prime periods, ≤ 20 fps) only when the caller says the agent is working (`isActive`), the
// window is visible, and Reduce Motion is off.
import SwiftUI

struct BrandGradientField: View {
    /// Drift only while the agent is actually working. Static otherwise.
    var isActive: Bool = false
    /// 0…1 — scales the colour against the ink ground (Ignition fades it in).
    var brightness: Double = 1

    @Environment(\.motionReduced) private var reduced
    @State private var isWindowVisible = true

    var body: some View {
        let animate = isActive && isWindowVisible && !reduced
        ZStack {
            Palette.Brand.ink
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animate)) { timeline in
                let t = animate ? timeline.date.timeIntervalSinceReferenceDate : 0
                MeshGradient(width: 3, height: 3,
                             points: BrandMesh.points(at: t),
                             colors: BrandMesh.colors(at: t),
                             smoothsColors: true)
            }
            .opacity(brightness)
        }
        .trackWindowVisibility($isWindowVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Pure geometry/colour for the brand mesh, so the static frame is deterministic and testable.
enum BrandMesh {
    /// Slow sinusoidal drift: `period` seconds per cycle, `amp` in unit space.
    private static func drift(_ t: Double, period: Double, phase: Double, amp: Double) -> Float {
        Float(sin(t * 2 * .pi / period + phase) * amp)
    }

    static func points(at t: Double) -> [SIMD2<Float>] {
        [
            [0, 0], [0.45 + drift(t, period: 29, phase: 0.0, amp: 0.12), 0], [1, 0],
            [0, 0.55 + drift(t, period: 31, phase: 1.1, amp: 0.14)],
            [0.42 + drift(t, period: 23, phase: 2.0, amp: 0.14), 0.48 + drift(t, period: 37, phase: 0.5, amp: 0.12)],
            [1, 0.45 + drift(t, period: 27, phase: 3.0, amp: 0.14)],
            [0, 1], [0.6 + drift(t, period: 41, phase: 4.0, amp: 0.12), 1], [1, 1],
        ]
    }

    static func colors(at t: Double) -> [Color] {
        let ink = Palette.Brand.ink2
        // The coral hint breathes between 18% and 30% over ~34 s; it never dominates.
        let coralAmount = 0.24 + Double(drift(t, period: 34, phase: 0.7, amp: 0.06))
        let coralHint = ink.mix(with: Palette.Brand.coral, by: coralAmount)
        return [
            Palette.Brand.deepGreen, Color(hex: 0x062A27), Palette.Brand.navy,
            Color(hex: 0x0A0E10), Color(hex: 0x00483D), Color(hex: 0x0B223A),
            Palette.Brand.navy, ink, coralHint,
        ]
    }
}

extension View {
    /// Content on the brand field (onboarding only), dark appearance so every token resolves to
    /// its on-dark value. Static unless `isActive`.
    func brandHeroBand(isActive: Bool = false, cornerRadius: CGFloat = Radius.hero) -> some View {
        self
            .background { BrandGradientField(isActive: isActive) }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
            }
            .environment(\.colorScheme, .dark)
    }
}

#Preview("Brand field") {
    VStack(alignment: .leading, spacing: Space.s) {
        Text("Tuesday 21 October").eyebrowStyle()
        Text("Good morning, Moaksh.").heroDisplayStyle()
    }
    .padding(Space.xl)
    .frame(width: 720, alignment: .leading)
    .brandHeroBand()
    .padding()
}
