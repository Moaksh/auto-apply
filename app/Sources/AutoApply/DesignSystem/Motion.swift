// Motion.swift — AutoApply's motion language, and the ONLY place animation curves are defined
// (docs/DESIGN_AWARD_VISION.md §6, docs/UI_UX_PLAN.md §2). Views never inline a curve: they use
// `Motion.*`, `.motion(_:value:)`, `withMotion`, `.motionTransition(_:)` and the helpers below.
// `DesignSystemTests.motionGoesThroughTheLanguage` enforces it.
//
// ## When things may move (the motion budget)
//
// Motion is a receipt: something moves because something happened.
//
// - **Tier 0 · Still.** Reading surfaces (lists, Job detail, Settings, Profile, Library) are still
//   at rest. Nothing loops, pulses or breathes there.
// - **Tier 1 · Response.** Feedback to a user action or a real state change: hover, press,
//   selection, a row arriving or leaving, a number rolling, a badge changing. ≤ 0.3 s
//   (`Budget.response`), one element leads, never a loop. Allowed everywhere.
// - **Tier 2 · Live.** Continuous motion driven by a real event stream: the Dashboard hero (lively
//   all the time, owner decision 2026-10-22), live agent activity (pipeline particles, the
//   live Chrome frame, the step ticker, thinking dots), countdown rings that are really counting
//   (send hold, undo toasts) and a loading skeleton while data is genuinely on its way. Only
//   in the files listed in `MotionPolicy.continuousAllowed`; capped frame rates; paused while the
//   window is hidden (`trackWindowVisibility`) or Reduce Motion is on.
// - **Tier 3 · Moment.** The signature moments (cascade, send hold, interview landed, inbox zero),
//   onboarding and easter eggs. Rare, skippable, ≤ 2.5 s (`Budget.moment`).
//
// ## Choreography
//
// One leader; followers 30 ms apart, at most 8 staggered (`Motion.staggered`). Arriving is a
// little slower than leaving (`enter` vs `exit`). The agent's work moves left to right; closing
// things moves down and folds (`.collapse`). Numbers roll (`numericRoll`), words cross-fade
// (`.contentTransition(.interpolate)`), text never slides. Springs for movement, linear only for
// time (`hold`).
//
// ## Reduce Motion
//
// Every curve resolves through `Motion.resolve` (a 0.18 s cross-fade, no movement or overshoot)
// and every transition through `MotionTransition.resolved(reduced:)` (a plain fade). Read the
// setting from `\.motionReduced`, never from `accessibilityReduceMotion` directly.
import SwiftUI

enum Motion {
    // MARK: Springs (the physics, for keyframes and `Animation.spring(_:)`)

    enum Springs {
        static let snappy = Spring(duration: 0.28, bounce: 0)
        static let press = Spring(duration: 0.16, bounce: 0)
        static let enter = Spring(duration: 0.3, bounce: 0)
        static let exit = Spring(duration: 0.2, bounce: 0)
        static let move = Spring(duration: 0.35, bounce: 0)
        static let emphasize = Spring(duration: 0.4, bounce: 0.3)
        static let settle = Spring(duration: 0.45, bounce: 0.12)
        static let flight = Spring(duration: 0.55, bounce: 0.05)
        static let flow = Spring(duration: 0.70, bounce: 0)
        static let celebrate = Spring(duration: 0.55, bounce: 0.32)
    }

    // MARK: Tier 1 · Response

    /// Selection, hover, toggles, disclosure. The default for most UI.
    static let snappy = Animation.spring(Springs.snappy)
    /// A button going down and coming back up. Quicker than anything else so a click feels physical.
    static let press = Animation.spring(Springs.press)
    /// Something arriving: a row inserting, a screen appearing, a popover or panel opening.
    static let enter = Animation.spring(Springs.enter)
    /// Something leaving: a row removed, a panel closing. Faster than `enter`, so departures never linger.
    static let exit = Animation.spring(Springs.exit)
    /// The same thing changing place: list reorders, the selection highlight travelling, the inspector sliding.
    static let move = Animation.spring(Springs.move)
    /// A change worth a glance: a count going up, a badge appearing, a card landing after a drop.
    static let emphasize = Animation.spring(Springs.emphasize)
    /// Words and states swapping in place: status badges, skeleton → content, labels.
    static let fade = Animation.easeInOut(duration: 0.2)
    /// Paired with `.contentTransition(.numericText(value:))`.
    static let numeric = snappy

    // MARK: Larger movement and moments

    /// Cards entering, kanban drop landing, sheets.
    static let settle = Animation.spring(Springs.settle)
    /// Matched-geometry flights (Job card → Job detail) and the cascade's monograms.
    static let flight = Animation.spring(Springs.flight)
    /// Jobs moving between pipeline stages, particles.
    static let flow = Animation.spring(Springs.flow)
    /// Submitted check, inbox zero, offer moved. Moments only; rare by design.
    static let celebrate = Animation.spring(Springs.celebrate)
    /// Chart data changes, mesh gradient shifts.
    static let gentle = Animation.smooth(duration: 0.9)
    /// Charts and sparklines drawing in from the leading edge.
    static let drawIn = Animation.easeInOut(duration: 0.9)
    /// A one-off reveal (onboarding's ignition, a connected-check settling in).
    static let reveal = Animation.easeOut(duration: 0.4)
    /// A hairline flash on a live tile: up quickly …
    static let flashIn = Animation.easeOut(duration: 0.3)
    /// … and away slowly.
    static let flashOut = Animation.easeIn(duration: 0.6)
    /// The brand field coming to rest.
    static let settleField = Animation.easeOut(duration: 1.2)
    /// Undo rings and send-hold countdowns: linear, because time is linear (honest).
    static func hold(_ seconds: TimeInterval) -> Animation { .linear(duration: seconds) }
    /// Live-activity ticks (thinking dots): the beat of a loop that only runs while the agent works.
    static let tick = Animation.easeInOut(duration: 0.3)

    /// The Reduce Motion replacement: a short cross-fade, no movement or overshoot.
    static let reducedFade = Animation.easeInOut(duration: 0.18)

    // MARK: Durations and distances

    enum Budget {
        /// Tier 1 responses finish within this.
        static let response: TimeInterval = 0.3
        /// Tier 3 moments finish within this.
        static let moment: TimeInterval = 2.5
        /// One skeleton shimmer sweep (slow on purpose).
        static let shimmerPeriod: TimeInterval = 1.8
        /// A skeleton stops shimmering after this, even if data is still on its way.
        static let shimmerLimit: Duration = .seconds(12)
        /// Rows and screens rise this far as they arrive.
        static let rise: CGFloat = 8
        /// A screen in the detail column rises less than a row: it must never feel slow.
        static let screenRise: CGFloat = 6
    }

    /// Reduce-motion aware: returns a cross-fade instead of movement.
    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedFade : animation
    }

    // MARK: Stagger

    /// Stagger delay for list entrances: 30 ms per item, max 8 staggered then the rest together.
    static func staggerDelay(index: Int, step: Double = 0.03, maxStaggered: Int = 8) -> Double {
        Double(min(index, maxStaggered)) * step
    }

    /// `animation` delayed for the `index`-th follower (one leader, 30 ms apart, ≤ 8 staggered).
    static func staggered(_ animation: Animation, index: Int, step: Double = 0.03, maxStaggered: Int = 8) -> Animation {
        animation.delay(staggerDelay(index: index, step: step, maxStaggered: maxStaggered))
    }

    /// Time-based easing for Canvas particles (`.flow` approximated as ease-in-out cubic).
    static func flowEase(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// 0 → 1 sweep position of a skeleton shimmer at `date` (one sweep per `shimmerPeriod`).
    static func shimmerPhase(at date: Date, period: TimeInterval = Budget.shimmerPeriod) -> Double {
        guard period > 0 else { return 0 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }
}

/// Where continuous (Tier 2) motion may live. `DesignSystemTests` lints `repeatForever`,
/// `PhaseAnimator` and `TimelineView(.animation` against this list; everything else is still at
/// rest. Paths are relative to `Sources/AutoApply`.
enum MotionPolicy {
    static let continuousAllowed: [String] = [
        "DesignSystem/Motion.swift",
        // The Dashboard hero and the live agent (lively all the time; capped, paused when hidden).
        "Features/Dashboard/Hero/",
        "Features/Dashboard/LiveAgent/",
        "DesignSystem/Components/BrandGradient.swift",
        // Live activity: thinking dots while the agent works, the loading skeleton while data is on its way.
        "DesignSystem/Components/States.swift",
        // Countdowns that are really counting: undo toasts, the send hold.
        "DesignSystem/Components/GlassBar.swift",
        "Features/Review/SendHoldViews.swift",
        // Moments: the submission celebration, onboarding's live checks, easter eggs.
        "DesignSystem/Components/Celebration.swift",
        "Features/Onboarding/",
        "Features/EasterEggs/",
    ]

    static func allowsContinuousMotion(_ path: String) -> Bool {
        continuousAllowed.contains { path.hasPrefix($0) }
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

    /// `.animation(_:value:)` that degrades to a cross-fade under Reduce Motion. Scope it tightly:
    /// put it on the smallest view whose layout should animate, never on a whole screen.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionAnimationModifier(animation: animation, value: value))
    }

    /// Numbers that change: monospaced digits + numericText roll + `.numeric` spring.
    func numericRoll(_ value: Double) -> some View {
        monospacedDigit()
            .contentTransition(.numericText(value: value))
            .motion(Motion.numeric, value: value)
    }

    /// Words that change in place (a status label, a summary line): cross-fade, never slide.
    func wordSwap<V: Equatable>(_ value: V) -> some View {
        contentTransition(.interpolate)
            .motion(Motion.fade, value: value)
    }
}

/// `withAnimation` honoring Reduce Motion.
@MainActor
func withMotion<Result>(_ animation: Animation, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.resolve(animation, reduceMotion: reduceMotion), body)
}

// MARK: - Transitions catalog (§2.3)

extension AnyTransition {
    // The standard presets. Prefer `.motionTransition(_:)`, which also picks the curve and the
    // Reduce Motion fade; use these directly only inside a container that already animates.

    /// Arriving content: fades in while rising 8 pt. Leaves with a plain fade.
    static var rise: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: Motion.Budget.rise)), removal: .opacity)
    }

    /// A plain cross-fade (states swapping in place, skeleton → content).
    static var fade: AnyTransition { .opacity }

    /// Panels and bars arriving from an edge (the inspector, the session bar).
    static func slideIn(from edge: Edge) -> AnyTransition {
        .move(edge: edge).combined(with: .opacity)
    }

    /// Floating panels and popovers (⌘K): a slight scale from 96 % with a fade.
    static var scaleIn: AnyTransition {
        .scale(scale: 0.96).combined(with: .opacity)
    }

    /// Something closing: it folds down toward its top edge and fades, and the rows below close
    /// the gap ("closing things moves down and folds").
    static var collapse: AnyTransition {
        .modifier(active: CollapseEffect(progress: 0), identity: CollapseEffect(progress: 1))
    }

    /// A row in a list: rises in, collapses out.
    static var row: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: Motion.Budget.rise)), removal: .collapse)
    }

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

/// Folds a view toward its top edge (y-scale) while fading: the `.collapse` transition.
struct CollapseEffect: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: 0.6 + 0.4 * progress, anchor: .top)
            .opacity(progress)
    }
}

/// The named transitions, each with its curves and its Reduce Motion counterpart.
enum MotionTransition: Equatable {
    case rise
    case fade
    case slideIn(Edge)
    case scaleIn
    case collapse
    /// Rows: rise in, collapse out.
    case row

    /// The transition with its curves attached: arriving uses `enter`, leaving uses `exit`.
    /// Reduce Motion: a cross-fade.
    func resolved(reduced: Bool) -> AnyTransition {
        if reduced { return AnyTransition.opacity.animation(Motion.reducedFade) }
        switch self {
        case .rise:
            return .asymmetric(insertion: AnyTransition.rise.animation(Motion.enter), removal: AnyTransition.opacity.animation(Motion.exit))
        case .fade:
            return AnyTransition.opacity.animation(Motion.fade)
        case .slideIn(let edge):
            return .asymmetric(insertion: AnyTransition.slideIn(from: edge).animation(Motion.move),
                               removal: AnyTransition.slideIn(from: edge).animation(Motion.exit))
        case .scaleIn:
            return .asymmetric(insertion: AnyTransition.scaleIn.animation(Motion.enter),
                               removal: AnyTransition.scaleIn.animation(Motion.exit))
        case .collapse:
            return .asymmetric(insertion: AnyTransition.rise.animation(Motion.enter), removal: AnyTransition.collapse.animation(Motion.exit))
        case .row:
            return .asymmetric(insertion: AnyTransition.rise.animation(Motion.enter), removal: AnyTransition.collapse.animation(Motion.exit))
        }
    }
}

private struct MotionTransitionModifier: ViewModifier {
    var kind: MotionTransition
    @Environment(\.motionReduced) private var reduced

    func body(content: Content) -> some View {
        content.transition(kind.resolved(reduced: reduced))
    }
}

extension View {
    /// Insert / remove this view with one of the standard transitions (curves and Reduce Motion
    /// included). For list rows, also animate the container's layout on the ids
    /// (`.motion(Motion.move, value: ids)`) so the neighbours close the gap.
    func motionTransition(_ kind: MotionTransition) -> some View {
        modifier(MotionTransitionModifier(kind: kind))
    }
}

// MARK: - Screen entrance

/// A screen arriving in the detail column: a quick cross-fade and a 6 pt rise, replayed when
/// `trigger` changes. The rest pose is the finished one, so a renderer that never animates (tests,
/// the first launch) draws the screen in place. Only opacity and offset animate: no relayout.
private struct ScreenEntrance<T: Equatable>: ViewModifier {
    var trigger: T
    @Environment(\.motionReduced) private var reduced

    private struct Pose { var opacity = 1.0; var y: CGFloat = 0 }

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: Pose(), trigger: trigger) { view, pose in
            view.opacity(pose.opacity).offset(y: pose.y)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                MoveKeyframe(reduced ? 0.4 : 0)
                CubicKeyframe(1, duration: reduced ? 0.18 : 0.22)
            }
            KeyframeTrack(\.y) {
                MoveKeyframe(reduced ? 0 : Motion.Budget.screenRise)
                SpringKeyframe(0, duration: 0.32, spring: Motion.Springs.enter)
            }
        }
    }
}

private struct ScreenArrival: ViewModifier {
    @State private var arrivals = 0

    func body(content: Content) -> some View {
        content
            .screenEntrance(trigger: arrivals)
            .onAppear { arrivals += 1 }
    }
}

extension View {
    /// Detail-column screens: a subtle cross-fade and rise whenever `trigger` changes.
    func screenEntrance<T: Equatable>(trigger: T) -> some View {
        modifier(ScreenEntrance(trigger: trigger))
    }

    /// A pushed screen (Job detail, Insights): the same entrance, once, when it appears.
    func screenArrival() -> some View {
        modifier(ScreenArrival())
    }

    /// A screen's or pane's states (loading skeleton → content → empty → error) cross-fade into
    /// each other. Apply to the `Group` holding the `if`/`switch` branches; `phase` names the
    /// branch, so only a change of state animates, never the content inside it.
    func stateCrossFade<V: Equatable>(_ phase: V) -> some View {
        transition(.opacity).motion(Motion.fade, value: phase)
    }
}

// MARK: - Feedback: hover lift, press

/// Interactive cards and rows under the pointer: a 1 pt lift and a slightly stronger hairline.
/// Very subtle, no shadows; nothing under Reduce Motion except the hairline.
private struct HoverResponse: ViewModifier {
    var cornerRadius: CGFloat
    var lifts: Bool
    @Environment(\.motionReduced) private var reduced
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.strokeStrong.opacity(hovering ? 0.55 : 0), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .offset(y: hovering && lifts && !reduced ? -1 : 0)
            .motion(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Hover feedback for interactive cards (Pipeline cards, Cold Email and Resumes cards).
    func hoverResponse(cornerRadius: CGFloat = Radius.inner, lifts: Bool = true) -> some View {
        modifier(HoverResponse(cornerRadius: cornerRadius, lifts: lifts))
    }

    /// Press feedback for buttons: down to 97 % while pressed, back with `press`.
    func pressResponse(_ isPressed: Bool) -> some View {
        modifier(PressResponse(isPressed: isPressed))
    }
}

private struct PressResponse: ViewModifier {
    var isPressed: Bool
    @Environment(\.motionReduced) private var reduced

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduced ? 0.97 : 1)
            .motion(Motion.press, value: isPressed)
    }
}

// MARK: - Selection highlight

extension EnvironmentValues {
    /// Set by `.selectionHighlightGroup`: `.selectableRow` draws its selected fill as one shared
    /// shape in this namespace, so the highlight travels from row to row.
    @Entry var selectionHighlightNamespace: Namespace.ID? = nil
}

private struct SelectionHighlightGroup<V: Equatable>: ViewModifier {
    var namespace: Namespace.ID
    var selection: V

    func body(content: Content) -> some View {
        content
            .environment(\.selectionHighlightNamespace, namespace)
            .motion(Motion.move, value: selection)
    }
}

extension View {
    /// A list whose `.selectableRow`s share one moving selection highlight. Put it on the list's
    /// stack (not the whole screen); `selection` is what changes when the highlight should travel.
    func selectionHighlightGroup<V: Equatable>(_ namespace: Namespace.ID, selection: V) -> some View {
        modifier(SelectionHighlightGroup(namespace: namespace, selection: selection))
    }
}

// MARK: - Appear effects (empty and success states)

/// A symbol that greets you once when its state appears (an empty or success state): a gentle
/// bounce for SF Symbols. Nothing under Reduce Motion, and nothing ever loops.
private struct SymbolGreeting: ViewModifier {
    @Environment(\.motionReduced) private var reduced
    @State private var appeared = 0

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce.down.byLayer, options: .nonRepeating, value: appeared)
            .onAppear { if !reduced { appeared += 1 } }
    }
}

extension View {
    /// Empty / success state symbols: one gentle bounce on appear.
    func symbolGreeting() -> some View { modifier(SymbolGreeting()) }
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
