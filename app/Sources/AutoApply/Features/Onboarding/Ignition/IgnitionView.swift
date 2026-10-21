// IgnitionView.swift — the signature opening (§5.1.0, ~3.2 s, click or any key skips): a point
// of light becomes a trajectory, the trajectory becomes the paper-plane mark, the mark settles
// into the welcome screen. One KeyframeAnimator drives IgnitionState; one Canvas draws the trail.
import SwiftUI

/// Every animated value of the opening, interpolated by the keyframe timeline.
struct IgnitionState {
    var dotOpacity = 0.0
    /// 0…1 along the S-curve.
    var dotProgress = 0.0
    /// 0…1: the two "job" dots joining the trail.
    var joinProgress = 0.0
    /// Paper-plane stroke draw-on.
    var trimEnd = 0.0
    var glassOpacity = 0.0
    /// −1…1 specular sweep position.
    var sweep = -1.0
    /// Dotted trail → check mark draw-on.
    var checkProgress = 0.0
    /// 0…1 background brighten into the onboarding gradient.
    var backgroundBrightness = 0.0
    var markScale = 1.0
    var markOffset = 0.0
    /// 0…1 headline word reveal.
    var textPhase = 0.0
    var subheadOpacity = 0.0
    var buttonOpacity = 0.0
    var buttonOffset = 8.0

    /// The fully settled frame (skip / Reduce Motion).
    static var final: IgnitionState {
        var s = IgnitionState()
        s.dotOpacity = 0
        s.dotProgress = 1
        s.joinProgress = 1
        s.trimEnd = 1
        s.glassOpacity = 1
        s.sweep = 1
        s.checkProgress = 1
        s.backgroundBrightness = 1
        s.markScale = 0.62
        s.markOffset = -120
        s.textPhase = 1
        s.subheadOpacity = 1
        s.buttonOpacity = 1
        s.buttonOffset = 0
        return s
    }
}

struct IgnitionView: View {
    var onGetStarted: () -> Void
    @State private var trigger = 0
    @State private var skipped = false
    @Environment(\.motionReduced) private var reduced
    @FocusState private var focused: Bool

    private static let headline = ["Set", "up", "your", "job", "agent."]

    var body: some View {
        Group {
            if skipped || reduced {
                content(.final)
                    .transition(.opacity.animation(.easeOut(duration: 0.4)))
            } else {
                KeyframeAnimator(initialValue: IgnitionState(), trigger: trigger) { state in
                    content(state)
                } keyframes: { _ in
                    KeyframeTrack(\.dotOpacity) {
                        LinearKeyframe(0, duration: 0.15)
                        CubicKeyframe(1, duration: 0.25)
                        LinearKeyframe(1, duration: 0.9)
                        LinearKeyframe(0, duration: 0.3)
                    }
                    KeyframeTrack(\.dotProgress) {
                        LinearKeyframe(0, duration: 0.4)
                        CubicKeyframe(0.55, duration: 0.5)
                        CubicKeyframe(1, duration: 0.4)
                    }
                    KeyframeTrack(\.joinProgress) {
                        LinearKeyframe(0, duration: 0.9)
                        CubicKeyframe(1, duration: 0.4)
                    }
                    KeyframeTrack(\.trimEnd) {
                        LinearKeyframe(0, duration: 1.3)
                        SpringKeyframe(1, duration: 0.6, spring: Spring(duration: 0.7, bounce: 0))
                    }
                    KeyframeTrack(\.glassOpacity) {
                        LinearKeyframe(0, duration: 1.9)
                        LinearKeyframe(1, duration: 0.3)
                    }
                    KeyframeTrack(\.sweep) {
                        LinearKeyframe(-1, duration: 1.9)
                        CubicKeyframe(1, duration: 0.5)
                    }
                    KeyframeTrack(\.checkProgress) {
                        LinearKeyframe(0, duration: 2.2)
                        CubicKeyframe(1, duration: 0.4)
                    }
                    KeyframeTrack(\.backgroundBrightness) {
                        LinearKeyframe(0, duration: 2.45)
                        CubicKeyframe(1, duration: 0.6)
                    }
                    KeyframeTrack(\.markScale) {
                        LinearKeyframe(1, duration: 2.45)
                        SpringKeyframe(0.62, duration: 0.45, spring: Spring(duration: 0.45, bounce: 0.12))
                    }
                    KeyframeTrack(\.markOffset) {
                        LinearKeyframe(0, duration: 2.45)
                        SpringKeyframe(-120, duration: 0.45, spring: Spring(duration: 0.45, bounce: 0.12))
                    }
                    KeyframeTrack(\.textPhase) {
                        LinearKeyframe(0, duration: 2.7)
                        LinearKeyframe(1, duration: 0.3)
                    }
                    KeyframeTrack(\.subheadOpacity) {
                        LinearKeyframe(0, duration: 2.95)
                        CubicKeyframe(1, duration: 0.25)
                    }
                    KeyframeTrack(\.buttonOpacity) {
                        LinearKeyframe(0, duration: 3.2)
                        CubicKeyframe(1, duration: 0.3)
                    }
                    KeyframeTrack(\.buttonOffset) {
                        LinearKeyframe(8, duration: 3.2)
                        SpringKeyframe(0, duration: 0.3, spring: Spring(duration: 0.3, bounce: 0))
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .focusable()
        .focusEffectDisabled()  // a full-window splash, not a control: no ring around the window
        .focused($focused)
        .onKeyPress { press in
            if skipped && press.key == .return { onGetStarted(); return .handled }
            skip()
            return .handled
        }
        .onAppear {
            focused = true
            trigger += 1
            // After the timeline, settle into the static final frame (buttons fully interactive).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3.6))
                skipped = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to AutoApply")
    }

    private func skip() {
        guard !skipped else { return }
        skipped = true
    }

    @ViewBuilder
    private func content(_ s: IgnitionState) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            ZStack {
                IgnitionBackground(brightness: s.backgroundBrightness)

                // Particle trail + joining "job" dots (single Canvas, no per-particle views).
                Canvas { ctx, canvasSize in
                    IgnitionTrail.draw(in: &ctx, size: canvasSize, state: s)
                }
                .allowsHitTesting(false)

                // The mark: plane outline draws on, fills with glass, then the dotted trail → check.
                PaperPlaneMark(trimEnd: s.trimEnd, glassOpacity: s.glassOpacity, sweep: s.sweep, checkProgress: s.checkProgress)
                    .frame(width: 180, height: 140)
                    .scaleEffect(s.markScale)
                    .position(x: center.x, y: center.y + s.markOffset)

                VStack(spacing: Space.m) {
                    HStack(spacing: 10) {
                        ForEach(Array(Self.headline.enumerated()), id: \.offset) { i, word in
                            let wordPhase = min(1, max(0, s.textPhase * Double(Self.headline.count) - Double(i) * 0.8))
                            Text(word)
                                .displayStyle()
                                .foregroundStyle(.white)
                                .opacity(wordPhase)
                                .blur(radius: (1 - wordPhase) * 6)
                        }
                    }
                    Text("AutoApply finds jobs that match what you want and fills in the applications. Questions it can't answer from your profile come to you.")
                        .font(Typography.title2)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                        .opacity(s.subheadOpacity)
                    VStack(spacing: Space.s) {
                        Button(action: onGetStarted) {
                            Text("Get started").font(Typography.title2).padding(.horizontal, Space.xl).padding(.vertical, Space.xs)
                        }
                        .buttonStyle(.primaryPill)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .environment(\.colorScheme, .dark)
                        Label("Your data stays on this Mac. Job pages and form questions go to Claude to draft answers.", systemImage: "lock.fill")
                            .font(Typography.callout)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.top, Space.l)
                    .opacity(s.buttonOpacity)
                    .offset(y: s.buttonOffset)
                    .allowsHitTesting(s.buttonOpacity > 0.5)
                }
                .position(x: center.x, y: center.y + 70)
            }
        }
    }
}

/// Near-black canvas brightening into the brand field (deep green → ink → navy, a hint of
/// coral). The field itself is static: only the brightness fades in, once.
private struct IgnitionBackground: View {
    var brightness: Double

    var body: some View {
        BrandGradientField(brightness: brightness)
            .background(Palette.ignitionGround)
            .ignoresSafeArea()
    }
}

/// Time-free trail drawing: particle positions derive from `dotProgress` alone.
enum IgnitionTrail {
    static let particleCount = 40

    /// Point on the gentle S-curve at `t` (0…1), in canvas coordinates.
    static func curvePoint(_ t: Double, size: CGSize) -> CGPoint {
        let x = size.width * (0.18 + 0.32 * t)
        let y = size.height * 0.5 + sin(t * .pi * 2) * size.height * 0.06 - t * size.height * 0.04
        return CGPoint(x: x, y: y)
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, state s: IgnitionState) {
        guard s.dotOpacity > 0.01 else { return }
        let accent = Palette.Brand.signal
        // Trail: 40 particles behind the head, each fading with age.
        for i in 0..<particleCount {
            let t = s.dotProgress - Double(i) * 0.012
            guard t > 0 else { break }
            let p = curvePoint(t, size: size)
            let alpha = (1 - Double(i) / Double(particleCount)) * s.dotOpacity * 0.8
            let r = 1.2 * (1 - Double(i) / Double(particleCount) * 0.6)
            ctx.fill(Circle().path(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(accent.opacity(alpha)))
        }
        // Head with an 18pt soft glow.
        let head = s.dotProgress > 0 ? curvePoint(s.dotProgress, size: size) : CGPoint(x: size.width / 2, y: size.height / 2)
        var glow = ctx
        glow.addFilter(.blur(radius: 9))
        glow.fill(Circle().path(in: CGRect(x: head.x - 9, y: head.y - 9, width: 18, height: 18)), with: .color(accent.opacity(0.6 * s.dotOpacity)))
        ctx.fill(Circle().path(in: CGRect(x: head.x - 1, y: head.y - 1, width: 2, height: 2)), with: .color(.white.opacity(s.dotOpacity)))
        // Two faint "job" dots joining from the edges, pulsing on contact.
        if s.joinProgress > 0 && s.joinProgress < 1 {
            for (edge, target) in [(CGPoint(x: 0, y: size.height * 0.25), 0.62), (CGPoint(x: 0, y: size.height * 0.8), 0.74)] {
                let dest = curvePoint(target, size: size)
                let k = Motion.flowEase(s.joinProgress)
                let p = CGPoint(x: edge.x + (dest.x - edge.x) * k, y: edge.y + (dest.y - edge.y) * k)
                let pulse = s.joinProgress > 0.85 ? 2.2 : 1.2
                ctx.fill(Circle().path(in: CGRect(x: p.x - pulse, y: p.y - pulse, width: pulse * 2, height: pulse * 2)),
                         with: .color(accent.opacity(0.5)))
            }
        }
    }
}

/// Paper plane outline (trim-drawn), glass interior with a single specular sweep, and the
/// dotted trajectory that ends in a check mark (the app-icon composition).
struct PaperPlaneMark: View {
    var trimEnd: Double
    var glassOpacity: Double
    var sweep: Double
    var checkProgress: Double

    var body: some View {
        ZStack {
            TrajectoryCheck()
                .trim(from: 0, to: checkProgress)
                .stroke(Palette.Brand.signal.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 6]))
            PaperPlaneShape()
                .fill(.white.opacity(0.10 * glassOpacity))
                .overlay {
                    // Specular highlight sweeping −30° → +30°.
                    LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 40)
                        .rotationEffect(.degrees(20))
                        .offset(x: sweep * 110)
                        .mask(PaperPlaneShape())
                        .opacity(glassOpacity > 0 && sweep > -1 && sweep < 1 ? 1 : 0)
                }
            PaperPlaneShape()
                .trim(from: 0, to: trimEnd)
                .stroke(Palette.Brand.signal, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct PaperPlaneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        var path = Path()
        path.move(to: p(0.30, 0.48))      // tail
        path.addLine(to: p(0.98, 0.08))   // nose
        path.addLine(to: p(0.70, 0.88))   // lower wing tip
        path.addLine(to: p(0.55, 0.62))   // fold
        path.closeSubpath()
        path.move(to: p(0.55, 0.62))
        path.addLine(to: p(0.98, 0.08))   // center crease
        path.move(to: p(0.55, 0.62))
        path.addLine(to: p(0.52, 0.80))   // keel
        return path
    }
}

/// Dotted path from the plane's tail curving back into a check mark.
struct TrajectoryCheck: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        var path = Path()
        path.move(to: p(0.30, 0.50))
        // Trajectory bends down-left, then traces a check (✓) backwards: long arm, then short arm.
        path.addCurve(to: p(0.16, 0.70), control1: p(0.24, 0.54), control2: p(0.20, 0.62))
        path.addLine(to: p(0.07, 0.86))
        path.addLine(to: p(0.0, 0.77))
        return path
    }
}

#Preview("Ignition") {
    IgnitionView {}
        .frame(width: 880, height: 620)
}
