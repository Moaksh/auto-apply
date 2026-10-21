// Confetti.swift — physics-y particles for the easter-egg moments: closed-form motion (launch
// velocity, linear drag, gravity) plus a paper flutter and tumble, drawn in one Canvas. No
// per-frame state, capped at `maxParticles`. Never shown under Reduce Motion (the overlay skips it).
import SwiftUI

/// One piece of confetti. Position is a pure function of time since its launch (tested).
struct ConfettiParticle: Sendable {
    enum Shape: Sendable, CaseIterable { case strip, square, circle, triangle, heart, star }

    var start: CGPoint
    var velocity: CGVector
    /// Points per second² (negative floats upward).
    var gravity: Double
    /// Linear drag coefficient (1/s); terminal fall speed is gravity / drag.
    var drag: Double
    var angle: Double
    var spin: Double
    /// Paper tumble speed (rad/s); 0 for shapes that shouldn't flip (hearts, stars).
    var flip: Double
    var flutter: Double
    var phase: Double
    var size: Double
    var shape: Shape
    var color: Color
    var delay: Double
    var life: Double
    /// Stars twinkle instead of holding steady.
    var twinkle = false

    func position(at t: Double) -> CGPoint {
        let decay = (1 - exp(-drag * t)) / drag
        let sway = sin(t * flutter + phase) * 7 * min(1, t * 2)
        return CGPoint(x: start.x + velocity.dx * decay + sway,
                       y: start.y + velocity.dy * decay + gravity * (t - decay) / drag)
    }

    /// Quick fade-in, hold, fade over the last 30% of life.
    func opacity(at t: Double) -> Double {
        guard t >= 0, t < life else { return 0 }
        let fadeIn = min(1, t / 0.08)
        let fadeOut = min(1, (life - t) / (life * 0.3))
        let base = fadeIn * fadeOut
        return twinkle ? base * (0.55 + 0.45 * sin(t * 14 + phase)) : base
    }
}

/// A launched set of particles.
struct ConfettiBurst: Sendable, Identifiable {
    let id = UUID()
    var particles: [ConfettiParticle]
    var start: Date

    static let maxParticles = 180
    /// Upper bound on `lifetime` for any style (longest delay + longest life).
    static let maxLifetime = 4.2

    /// When the last particle is gone (seconds after `start`).
    var lifetime: Double { particles.map { $0.delay + $0.life }.max() ?? 0 }

    /// Builds the particles for `style` (deterministic for a given seed; tested).
    static func make(_ style: EasterEggs.Burst, origin: CGPoint, in size: CGSize, colors: [Color], love: [Color],
                     seed: UInt64, start: Date = .now) -> ConfettiBurst {
        var rng = SeededRandom(seed: seed)
        let w = Double(max(size.width, 1)), h = Double(max(size.height, 1))
        var out: [ConfettiParticle] = []
        let paper: [ConfettiParticle.Shape] = [.strip, .strip, .square, .circle, .triangle]

        func piece(_ start: CGPoint, angle: Double, speed: Double, gravity: Double, drag: Double,
                   life: ClosedRange<Double>, delay: ClosedRange<Double>, shapes: [ConfettiParticle.Shape],
                   palette: [Color], size: ClosedRange<Double> = 5...9) -> ConfettiParticle {
            let shape = rng.pick(shapes)
            let flat = shape == .heart || shape == .star
            return ConfettiParticle(
                start: start, velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                gravity: gravity, drag: drag, angle: rng.double(0...(2 * .pi)),
                spin: flat ? rng.double(-1.5...1.5) : rng.double(-7...7), flip: flat ? 0 : rng.double(4...11),
                flutter: rng.double(2...5), phase: rng.double(0...(2 * .pi)), size: rng.double(size),
                shape: shape, color: rng.pick(palette), delay: rng.double(delay), life: rng.double(life),
                twinkle: shape == .star)
        }

        func rain(_ n: Int) {
            for _ in 0..<n {
                out.append(piece(CGPoint(x: rng.double(0...w), y: -rng.double(10...80)), angle: .pi / 2 + rng.double(-0.4...0.4),
                                 speed: rng.double(20...140), gravity: 520, drag: 1.6, life: 2.6...3.4, delay: 0...0.7,
                                 shapes: paper, palette: colors))
            }
        }

        func cannon(_ n: Int, from p: CGPoint, aim: Double, spread: Double, speed: ClosedRange<Double>, shapes: [ConfettiParticle.Shape]) {
            for _ in 0..<n {
                out.append(piece(p, angle: aim + rng.double(-spread...spread), speed: rng.double(speed), gravity: 900, drag: 1.4,
                                 life: 2.2...3.0, delay: 0...0.08, shapes: shapes, palette: colors))
            }
        }

        let up = -Double.pi / 2
        switch style {
        case .none:
            break
        case .rain:
            rain(120)
        case .cannon:
            cannon(110, from: origin, aim: up, spread: 0.85, speed: 420...820, shapes: paper)
        case .storm:
            rain(80)
            let reach: ClosedRange<Double> = 650...max(651, min(1150, Double(h) * 1.35))
            cannon(50, from: CGPoint(x: 0, y: h), aim: up + 0.55, spread: 0.3, speed: reach, shapes: paper)
            cannon(50, from: CGPoint(x: w, y: h), aim: up - 0.55, spread: 0.3, speed: reach, shapes: paper)
        case .hearts:
            for _ in 0..<26 {
                out.append(piece(origin, angle: up + rng.double(-0.9...0.9), speed: rng.double(120...280), gravity: 40, drag: 1.1,
                                 life: 1.8...2.6, delay: 0...0.35, shapes: [.heart], palette: love, size: 8...15))
            }
            cannon(34, from: origin, aim: up, spread: 1.0, speed: 260...520, shapes: paper)
        case .stars:
            for _ in 0..<36 {
                out.append(piece(origin, angle: rng.double(0...(2 * .pi)), speed: rng.double(90...300), gravity: 50, drag: 2.2,
                                 life: 1.6...2.4, delay: 0...0.25, shapes: [.star, .circle], palette: colors, size: 4...9))
            }
        }
        return ConfettiBurst(particles: Array(out.prefix(maxParticles)), start: start)
    }
}

/// What to launch; the canvas turns it into particles once it knows its own size.
struct ConfettiSpec: Sendable, Identifiable {
    let id = UUID()
    var style: EasterEggs.Burst
    /// Trigger point in window (`.global`) coordinates; nil = `fallbackOrigin`.
    var origin: CGPoint?
    var seed: UInt64
    var start = Date.now
}

/// Draws a burst until its last particle fades. Hit-testing off; pure decoration. Geometry is
/// read with a GeometryReader (not onGeometryChange) so offscreen renders never write state.
struct ConfettiCanvas: View {
    var spec: ConfettiSpec
    var fallbackOrigin: (CGSize) -> CGPoint

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let origin = spec.origin.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) } ?? fallbackOrigin(frame.size)
            let burst = ConfettiBurst.make(spec.style, origin: origin, in: frame.size, colors: EggTone.confetti,
                                           love: EggTone.hearts, seed: spec.seed, start: spec.start)
            particles(burst)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func particles(_ burst: ConfettiBurst) -> some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(burst.start)
            Canvas { ctx, size in
                for p in burst.particles {
                    let local = t - p.delay
                    let alpha = p.opacity(at: local)
                    guard alpha > 0.01 else { continue }
                    let pos = p.position(at: local)
                    guard pos.x > -40, pos.x < size.width + 40, pos.y > -200, pos.y < size.height + 40 else { continue }
                    var g = ctx
                    g.opacity = alpha
                    g.translateBy(x: pos.x, y: pos.y)
                    g.rotate(by: .radians(p.angle + p.spin * local))
                    if p.flip != 0 { g.scaleBy(x: 1, y: max(0.15, abs(cos(local * p.flip + p.phase)))) }
                    g.fill(Self.path(p.shape, size: p.size), with: .color(p.color))
                }
            }
        }
    }

    static func path(_ shape: ConfettiParticle.Shape, size s: Double) -> Path {
        switch shape {
        case .strip:
            return Path(roundedRect: CGRect(x: -s / 2, y: -s / 5, width: s, height: s * 0.4), cornerRadius: 1)
        case .square:
            return Path(CGRect(x: -s / 2.6, y: -s / 2.6, width: s / 1.3, height: s / 1.3))
        case .circle:
            return Path(ellipseIn: CGRect(x: -s / 3, y: -s / 3, width: s / 1.5, height: s / 1.5))
        case .triangle:
            var p = Path()
            p.move(to: CGPoint(x: 0, y: -s / 2))
            p.addLine(to: CGPoint(x: s / 2, y: s / 2.5))
            p.addLine(to: CGPoint(x: -s / 2, y: s / 2.5))
            p.closeSubpath()
            return p
        case .heart:
            // Two lobes over the top (angles grow clockwise on screen), tapering to a point.
            var p = Path()
            let r = s * 0.27
            p.move(to: CGPoint(x: 0, y: s * 0.42))
            p.addCurve(to: CGPoint(x: -2 * r, y: -s * 0.08), control1: CGPoint(x: -s * 0.12, y: s * 0.28), control2: CGPoint(x: -2 * r, y: s * 0.12))
            p.addArc(center: CGPoint(x: -r, y: -s * 0.08), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addArc(center: CGPoint(x: r, y: -s * 0.08), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addCurve(to: CGPoint(x: 0, y: s * 0.42), control1: CGPoint(x: 2 * r, y: s * 0.12), control2: CGPoint(x: s * 0.12, y: s * 0.28))
            p.closeSubpath()
            return p
        case .star:
            var p = Path()
            for i in 0..<10 {
                let radius = i.isMultiple(of: 2) ? s / 2 : s / 4.5
                let a = Double(i) * .pi / 5 - .pi / 2
                let pt = CGPoint(x: cos(a) * radius, y: sin(a) * radius)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
    }
}
