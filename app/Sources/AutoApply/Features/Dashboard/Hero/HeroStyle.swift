// HeroStyle.swift — the Dashboard hero's own motion and material vocabulary.
//
// The Dashboard hero is the one deliberate exception to the calm-at-rest rules of the rest of
// the app (owner decision, 2026-10-22: "beautiful with animations and liveliness"). Everything
// here is scoped to the Dashboard:
// - `heroGlass(in:)` — the only Liquid Glass on content, used by panels floating on the brand
//   field. Opaque fallback under Reduce Transparency. (The design-system lint allowlists this
//   file for `.glassEffect(` and checks `heroGlass(` is only used under Features/Dashboard/.)
// - `HeroBreath` — a soft radial glow that breathes (idle: one breath per 6 s; working: faster).
// - the once-per-launch staggered entrance, the per-day count-up, hover lift and sparkline
//   draw-in for the tiles under the hero.
//
// Safeguards: every continuous animation is a `TimelineView` capped at ≤ 20 fps (ambient) or
// ≤ 30 fps (flows), and reads `heroMotionActive`, which the Dashboard sets to false when the
// window is occluded or hidden, under Reduce Motion, or while the agent is paused. Under Reduce
// Motion everything renders its static mid-frame.
import SwiftUI

extension EnvironmentValues {
    /// True while the Dashboard hero may run continuous motion: window visible, Reduce Motion
    /// off, agent not paused. Set by `DashboardView`; false everywhere else.
    @Entry var heroMotionActive = false
    /// First appearance of the day: numbers show 0 for a beat, then roll up to their value.
    @Entry var dashboardCountUp = false
    /// The staggered entrance: false only for the instant before the once-per-launch entrance.
    @Entry var dashboardEntered = true
    /// Draw hero glass as its opaque fallback. Set by offscreen renders (ImageRenderer can't
    /// draw Liquid Glass and drops the content inside it).
    @Entry var heroGlassOpaque = false
}

/// Once-per-launch bookkeeping for the Dashboard entrance.
@MainActor
enum HeroEntrance {
    static var hasPlayed = false

    /// Whether this appearance should play the entrance (and mark it played).
    static func claim(reduceMotion: Bool) -> Bool {
        guard !hasPlayed, !reduceMotion else { return false }
        hasPlayed = true
        return true
    }
}

/// Frame-rate caps for the hero's continuous motion.
enum HeroFrameRate {
    /// The brand field drifting at rest.
    static let ambientIdle: Double = 10
    /// The brand field while the agent works; breathing glows.
    static let ambient: Double = 20
    /// Pipeline particles and edge flow.
    static let flow: Double = 30
}

/// Pure breathing curve (unit-tested): 0…1, sinusoidal, `period` seconds per breath.
enum HeroBreathCurve {
    static func phase(at t: TimeInterval, period: Double) -> Double {
        guard period > 0 else { return 0.5 }
        return (sin(t * 2 * .pi / period - .pi / 2) + 1) / 2
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass for panels floating on the Dashboard's brand field. Dashboard hero only.
    func heroGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(HeroGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }
}

private struct HeroGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.heroGlassOpaque) private var opaque

    func body(content: Content) -> some View {
        if reduceTransparency || opaque {
            content
                .background(Color.white.opacity(0.07), in: shape)
                .background(Color(hex: 0x0E1416).opacity(0.55), in: shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.5))
        } else {
            let glass = Glass.regular.tint(tint?.opacity(0.22))
            content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        }
    }
}

// MARK: - Breathing glow

/// A soft radial glow that breathes. Static (mid-breath) when hero motion is off.
struct HeroBreath: View {
    var color: Color
    /// Seconds per breath: 6 at rest, ~2 while working.
    var period: Double = 6
    var radius: CGFloat = 40
    var minOpacity: Double = 0.16
    var maxOpacity: Double = 0.42

    @Environment(\.heroMotionActive) private var active

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / HeroFrameRate.ambient, paused: !active)) { timeline in
            let phase = active ? HeroBreathCurve.phase(at: timeline.date.timeIntervalSinceReferenceDate, period: period) : 0.5
            RadialGradient(colors: [color.opacity(minOpacity + (maxOpacity - minOpacity) * phase), color.opacity(0)],
                           center: .center, startRadius: 0, endRadius: radius * (0.88 + 0.16 * phase))
        }
        .frame(width: radius * 2.2, height: radius * 2.2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The agent's status as a glowing orb: a solid core with a breathing halo.
struct HeroStatusOrb: View {
    var color: Color
    var isWorking: Bool

    var body: some View {
        ZStack {
            HeroBreath(color: color, period: isWorking ? 2 : 6, radius: 14, minOpacity: 0.25, maxOpacity: 0.6)
            Circle().fill(color).frame(width: 10, height: 10)
            Circle().stroke(.white.opacity(0.4), lineWidth: 0.5).frame(width: 10, height: 10)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Entrance, hover lift, draw-in

private struct DashboardEntranceModifier: ViewModifier {
    var index: Int
    @Environment(\.dashboardEntered) private var entered
    @Environment(\.motionReduced) private var reduced

    func body(content: Content) -> some View {
        content
            .opacity(entered ? 1 : 0)
            .offset(y: entered || reduced ? 0 : 16)
            .scaleEffect(entered || reduced ? 1 : 0.985, anchor: .top)
            .animation(reduced ? Motion.reducedFade : Motion.settle.delay(Motion.staggerDelay(index: index, step: 0.06)), value: entered)
    }
}

private struct HoverLiftModifier: ViewModifier {
    var cornerRadius: CGFloat
    var glowTrigger: Int
    @Environment(\.motionReduced) private var reduced
    @State private var hovering = false
    @State private var glow = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(glow ? 0.55 : (hovering ? 0.3 : 0)), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .scaleEffect(hovering && !reduced ? 1.012 : 1)
            .offset(y: hovering && !reduced ? -2 : 0)
            .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: hovering)
            .onHover { hovering = $0 }
            .onChange(of: glowTrigger) { old, new in
                guard new > old else { return }
                withMotion(Motion.flashIn, reduceMotion: reduced) { glow = true }
                withMotion(Motion.flashOut.delay(0.5), reduceMotion: reduced) { glow = false }
            }
    }
}

private struct DrawInModifier: ViewModifier {
    var delay: Double
    @Environment(\.dashboardEntered) private var entered
    @Environment(\.motionReduced) private var reduced

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: entered ? 1 : 0.001, anchor: .leading)
            }
            .animation(reduced ? nil : Motion.drawIn.delay(delay), value: entered)
    }
}

extension View {
    /// Rise and fade in once per launch, staggered by `index`.
    func dashboardEntrance(index: Int) -> some View {
        modifier(DashboardEntranceModifier(index: index))
    }

    /// Stat tiles: lift slightly under the pointer; an accent hairline flashes when
    /// `glowTrigger` grows (a new application went out). No shadows.
    func hoverLift(cornerRadius: CGFloat = Radius.card, glowTrigger: Int = 0) -> some View {
        modifier(HoverLiftModifier(cornerRadius: cornerRadius, glowTrigger: glowTrigger))
    }

    /// Sparklines and charts draw in from the leading edge with the entrance.
    func drawIn(delay: Double = 0.25) -> some View {
        modifier(DrawInModifier(delay: delay))
    }
}
