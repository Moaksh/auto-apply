// Motion.swift — the only place animation values are defined (docs/UI_UX_PLAN.md §2).
// Views never inline springs: use `Motion.*`, `.motion(_:value:)` and `withMotion`.
import SwiftUI

enum Motion {
    /// Selection, hover, toggles, list reorders. Default for most UI.
    static let snappy = Animation.spring(duration: 0.28, bounce: 0.0)
    /// Cards entering, kanban drop landing, inspector open.
    static let settle = Animation.spring(duration: 0.45, bounce: 0.12)
    /// Jobs moving between pipeline stages, matched-geometry flights.
    static let flow = Animation.spring(duration: 0.70, bounce: 0.0)
    /// Submitted check, inbox zero, offer moved. Rare by design.
    static let celebrate = Animation.spring(duration: 0.55, bounce: 0.32)
    /// Chart data changes, mesh gradient shifts.
    static let gentle = Animation.smooth(duration: 0.9)
    /// Button press scale 0.97.
    static let press = Animation.spring(duration: 0.16, bounce: 0.0)
    /// Paired with `.contentTransition(.numericText(value:))`.
    static let numeric = snappy
    /// The Reduce Motion replacement: a short cross-fade, no movement or overshoot.
    static let reducedFade = Animation.easeInOut(duration: 0.18)

    /// Reduce-motion aware: returns a cross-fade instead of movement.
    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedFade : animation
    }

    /// Stagger delay for list entrances: 30 ms per item, max 8 staggered then the rest together.
    static func staggerDelay(index: Int, step: Double = 0.03, maxStaggered: Int = 8) -> Double {
        Double(min(index, maxStaggered)) * step
    }

    /// Time-based easing for Canvas particles (`.flow` approximated as ease-in-out cubic).
    static func flowEase(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

// MARK: - MotionEnvironment

private struct MotionReducedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Effective Reduce Motion (system setting OR the Debug menu's simulation). Read this,
    /// never `accessibilityReduceMotion` directly (§2.6: read in one place, propagated).
    var motionReduced: Bool {
        get { self[MotionReducedKey.self] }
        set { self[MotionReducedKey.self] = newValue }
    }
}

/// Install once at each scene root.
struct MotionEnvironment: ViewModifier {
    var simulateReduceMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        content.environment(\.motionReduced, systemReduceMotion || simulateReduceMotion)
    }
}

private struct MotionAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.motionReduced) private var reduced

    func body(content: Content) -> some View {
        content.animation(Motion.resolve(animation, reduceMotion: reduced), value: value)
    }
}

extension View {
    func motionEnvironment(simulateReduceMotion: Bool = false) -> some View {
        modifier(MotionEnvironment(simulateReduceMotion: simulateReduceMotion))
    }

    /// `.animation(_:value:)` that degrades to a cross-fade under Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionAnimationModifier(animation: animation, value: value))
    }

    /// Numbers that change: monospaced digits + numericText roll + `.numeric` spring.
    func numericRoll(_ value: Double) -> some View {
        monospacedDigit()
            .contentTransition(.numericText(value: value))
            .motion(Motion.numeric, value: value)
    }
}

/// `withAnimation` honoring Reduce Motion.
@MainActor
func withMotion<Result>(_ animation: Animation, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.resolve(animation, reduceMotion: reduceMotion), body)
}

// MARK: - Transitions catalog (§2.3)

extension AnyTransition {
    /// Dashboard cards on first load (pair with `Motion.settle` + `Motion.staggerDelay`).
    static var cardIn: AnyTransition {
        .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.98))
    }

    /// New log lines / inbox items.
    static var rowInsert: AnyTransition {
        .push(from: .top).combined(with: .opacity)
    }

    /// Answered inbox cluster collapsing.
    static var inboxCollapse: AnyTransition {
        .scale(scale: 0.96).combined(with: .opacity)
    }

    /// Onboarding step content: forward slides from trailing 24pt, back reverses.
    static func step(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 24 : -24)),
            removal: .opacity.combined(with: .offset(x: forward ? -24 : 24)))
    }

    /// Reduce-motion aware variant: plain fade when reduced.
    static func reduced(_ transition: AnyTransition, _ reduced: Bool) -> AnyTransition {
        reduced ? .opacity : transition
    }
}

// MARK: - Press feedback

/// Button style giving the `.press` scale (0.97) without changing the system look.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.motionReduced) private var reduced

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Error shake (§2.4 #6): offset x 0 → −6 → 5 → −3 → 0 over 0.35 s. Only for invalid input.
struct ErrorShake: ViewModifier {
    var trigger: Int
    @Environment(\.motionReduced) private var reduced

    func body(content: Content) -> some View {
        if reduced {
            content
        } else {
            content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-6, duration: 0.08)
                    LinearKeyframe(5, duration: 0.09)
                    LinearKeyframe(-3, duration: 0.09)
                    LinearKeyframe(0, duration: 0.09)
                }
            }
        }
    }
}

extension View {
    func errorShake(trigger: Int) -> some View { modifier(ErrorShake(trigger: trigger)) }
}
