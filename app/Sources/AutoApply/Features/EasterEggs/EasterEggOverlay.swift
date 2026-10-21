// EasterEggOverlay.swift — plays easter-egg moments over a window: a small glass reveal card
// (flavored symbol animation, headline, line, secrets-found pips) plus a confetti burst. Never
// blocks: hit-testing is off, focus is untouched, and the dismiss monitor passes every event on.
// Dismisses on any click, Esc, or after a few seconds. Reduce Motion: the card cross-fades,
// symbols hold still and there's no confetti.
import AppKit
import SwiftUI

/// Kept for the existing `.overlay { ConfettiOverlay() }` hooks in RootView and SettingsView.
typealias ConfettiOverlay = EasterEggOverlay

struct EasterEggOverlay: View {
    @Environment(\.motionReduced) private var reduced
    @Environment(\.appearsActive) private var appearsActive
    @State private var moment: EasterEggs.Moment?
    @State private var confetti: ConfettiSpec?
    @State private var dismissal = MomentDismissal()

    /// Card top inset — clears the toolbar / tab bar.
    private static let cardTop: CGFloat = Space.xxxl + Space.l

    var body: some View {
        ZStack(alignment: .top) {
            if let confetti, !reduced {
                ConfettiCanvas(spec: confetti, fallbackOrigin: { CGPoint(x: $0.width / 2, y: Self.cardTop + 36) })
                    .id(confetti.id)
                    .transition(.opacity)
            }
            if let moment {
                RevealCard(moment: moment)
                    .id(moment.id)
                    .padding(.top, Self.cardTop)
                    .transition(.reduced(.revealIn, reduced))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: EasterEggs.momentNotification)) { note in
            guard appearsActive, let m = note.object as? EasterEggs.Moment, EasterEggs.claim(m.id) else { return }
            present(m)
        }
    }

    private func present(_ m: EasterEggs.Moment) {
        withMotion(Motion.celebrate, reduceMotion: reduced) { moment = m }
        if m.script.burst != .none && !reduced {
            let spec = ConfettiSpec(style: m.script.burst, origin: m.origin, seed: UInt64.random(in: 0...UInt64.max))
            confetti = spec
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(ConfettiBurst.maxLifetime))
                if confetti?.id == spec.id { confetti = nil }
            }
        }
        dismissal.arm(after: m.duration) { dismiss(m.id) }
    }

    private func dismiss(_ id: UUID) {
        dismissal.stop()
        guard moment?.id == id else { return }
        withMotion(Motion.snappy, reduceMotion: reduced) { moment = nil }
    }
}

extension AnyTransition {
    /// Reveal card: drops in from above with a slight scale; leaves by lifting and fading.
    static var revealIn: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -14)).combined(with: .scale(scale: 0.92)),
                    removal: .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.97)))
    }
}

/// Esc / click / timeout → dismiss. The monitor only watches: it returns every event untouched.
@MainActor
final class MomentDismissal {
    private var monitor: Any?
    private var timer: Task<Void, Never>?

    func arm(after seconds: Double, _ dismiss: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            if event.type != .keyDown || event.keyCode == 53 {  // 53 = esc
                Task { @MainActor in dismiss() }
            }
            return event
        }
        timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { dismiss() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.cancel()
        timer = nil
    }
}

// MARK: Tones

/// Palette tokens for each tone, plus the confetti mixes.
enum EggTone {
    static func color(_ tone: EasterEggs.Tone) -> Color {
        switch tone {
        case .accent: Palette.accent
        case .love: Palette.categorical[3]
        case .amber: Palette.needsYou
        case .cosmic: Palette.assessment
        case .mint: Palette.applied
        case .alert: Palette.error
        case .gold: Palette.offer
        }
    }

    static let confetti: [Color] = Palette.categorical + [Palette.applied, Palette.offer, Palette.assessment, Palette.interview, Palette.coral]
    static let hearts: [Color] = [Palette.categorical[3], Palette.rejected, Palette.assessment]
}

// MARK: Reveal card

/// The glass card: medallion, eyebrow, headline, line, optional mono line and secrets-found pips.
struct RevealCard: View {
    let moment: EasterEggs.Moment
    @Environment(\.motionReduced) private var reduced
    @State private var shake = 0

    private var tint: Color { EggTone.color(moment.script.tone) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            EggMedallion(flavor: moment.flavor, symbol: moment.script.symbol, tint: tint)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(moment.eyebrow).eyebrowStyle()
                    if moment.isNew {
                        Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                    }
                }
                Text(moment.script.headline).font(Typography.title2).foregroundStyle(Palette.textPrimary)
                Text(moment.script.line)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let mono = moment.script.mono {
                    Text(mono).font(Typography.monoSmall).foregroundStyle(tint).padding(.top, Space.xxs)
                }
                SecretPips(found: moment.found, total: moment.total, tint: tint, highlightLast: moment.isNew)
                    .padding(.top, Space.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.l)
        .frame(width: 372)
        .glassChrome(in: RoundedRectangle(cornerRadius: Radius.palette, style: .continuous))
        .errorShake(trigger: shake)
        .onAppear {
            guard moment.flavor == .sudo else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                shake += 1
                try? await Task.sleep(for: .milliseconds(420))
                shake += 1
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// "3 of 8" as dots; the newest one pops in.
private struct SecretPips: View {
    var found: Int
    var total: Int
    var tint: Color
    var highlightLast: Bool
    @Environment(\.motionReduced) private var reduced
    @State private var landed = false

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<total, id: \.self) { i in
                let isNewest = highlightLast && i == found - 1
                Circle()
                    .fill(i < found && (!isNewest || landed) ? tint : Palette.hairline)
                    .frame(width: 6, height: 6)
                    .scaleEffect(isNewest && !landed && !reduced ? 0.3 : 1)
            }
            Text("\(found)/\(total)").font(Typography.metricSmall).foregroundStyle(Palette.textTertiary)
                .padding(.leading, Space.xxs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(found) of \(total) secrets found")
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                withMotion(Motion.celebrate, reduceMotion: reduced) { landed = true }
            }
        }
    }
}

// MARK: Medallion

/// The tinted circle with the flavor's symbol and its little act.
struct EggMedallion: View {
    var flavor: EasterEggs.Flavor?
    var symbol: String
    var tint: Color
    @Environment(\.motionReduced) private var reduced
    @State private var go = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            if !reduced { decor }
            icon
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduced else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                go = true
            }
        }
    }

    private var base: some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(tint)
    }

    @ViewBuilder private var icon: some View {
        switch flavor {
        case .wave?:
            base.keyframeAnimator(initialValue: 0.0, trigger: go) { view, angle in
                view.rotationEffect(.degrees(angle), anchor: .bottomTrailing)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(18, duration: 0.18)
                    SpringKeyframe(-10, duration: 0.18)
                    SpringKeyframe(18, duration: 0.18)
                    SpringKeyframe(-10, duration: 0.18)
                    SpringKeyframe(18, duration: 0.18)
                    SpringKeyframe(-10, duration: 0.18)
                    SpringKeyframe(0, duration: 0.25)
                }
            }
        case .sudo?:
            base.symbolEffect(.wiggle.left, options: .repeat(2), value: go)
        case .answer?:
            base.symbolEffect(.variableColor.iterative.reversing, isActive: go)
        case .coffee?:
            base.offset(y: 5).symbolEffect(.breathe, isActive: go)
        case .heart?, .maker?:
            base.symbolEffect(.bounce.up, options: .repeat(.periodic(4, delay: 0.25)), value: go)
        case .konami?, .hire?:
            base.symbolEffect(.bounce.up.byLayer, options: .repeat(3), value: go)
        case nil:
            base.symbolEffect(.wiggle, options: .repeat(2), value: go)
        }
    }

    @ViewBuilder private var decor: some View {
        switch flavor {
        case .coffee?: SteamDecor(tint: tint)
        case .answer?: OrbitDecor(tint: tint)
        case .konami?: PrismRing()
        default: EmptyView()
        }
    }
}

/// Three wisps of steam curling up out of the cup.
private struct SteamDecor: View {
    var tint: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for wisp in 0..<3 {
                    let baseX = size.width / 2 + Double(wisp - 1) * 7
                    for puff in 0..<3 {
                        let f = (t * 0.7 + Double(wisp) * 0.31 + Double(puff) / 3).truncatingRemainder(dividingBy: 1)
                        let y = size.height * 0.42 - f * 20
                        let x = baseX + sin(f * 7 + Double(wisp) * 2) * 2.5
                        let r = 1.4 + f * 2.4
                        ctx.fill(Circle().path(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(tint.opacity(0.45 * (1 - f) * min(1, f * 5))))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A tiny galaxy: dots orbiting at a few radii and speeds.
private struct OrbitDecor: View {
    var tint: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<9 {
                    let radius = 17 + Double(i % 3) * 4.5
                    let speed = 0.9 + Double(i % 4) * 0.35
                    let a = t * speed + Double(i) * 0.7
                    let p = CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius * 0.55)
                    let s = i.isMultiple(of: 3) ? 2.2 : 1.4
                    ctx.fill(Circle().path(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                             with: .color(tint.opacity(0.4 + 0.4 * sin(t * 3 + Double(i)))))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A slowly spinning rainbow ring for the achievement.
private struct PrismRing: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Circle()
                .strokeBorder(AngularGradient(colors: EggTone.confetti + [EggTone.confetti[0]], center: .center), lineWidth: 2)
                .rotationEffect(.degrees(t * 120))
        }
        .allowsHitTesting(false)
    }
}
