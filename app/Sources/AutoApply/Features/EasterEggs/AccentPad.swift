// AccentPad.swift — the accent picker unlocked by finding every easter egg: a gradient pad (hue
// across, vibrance up) with a knob you drag, like Arc's theme picker. The whole app recolors live
// while you drag. The trackpad ticks at each twelfth of the color wheel and clicks when the knob
// snaps home onto the brand green; a few swatches below are one-click picks.
import SwiftUI

struct AccentPad: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.motionReduced) private var reduced
    @State private var dragging = false
    @State private var lastDetent: Int?
    @State private var snappedHome = false

    private var theme: AccentTheme { AccentTheme.shared }

    static let height: CGFloat = 132
    static let knob: CGFloat = 22
    /// Hue detents felt on the trackpad while dragging.
    static let detents = 12
    /// How close (pt) the knob has to come to the brand green to snap onto it.
    static let homeRadius: CGFloat = 10

    struct Preset: Identifiable, Sendable {
        var name: String
        var choice: AccentChoice
        var id: String { name }
    }

    /// Named after the secrets that inspired them.
    static let presets: [Preset] = [
        Preset(name: "Heart", choice: AccentChoice(hue: 0.0, vibrance: 0.9)),
        Preset(name: "Gold", choice: AccentChoice(hue: 0.22, vibrance: 1)),
        Preset(name: "Mint", choice: AccentChoice(hue: 0.43, vibrance: 0.85)),
        Preset(name: "Ocean", choice: AccentChoice(hue: 0.66, vibrance: 0.8)),
        Preset(name: "Cosmic", choice: AccentChoice(hue: 0.82, vibrance: 0.95)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GeometryReader { geo in
                let size = geo.size
                let current = theme.choice ?? .home
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in AccentPad.paint(ctx, size: size, variant: variant) }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.hairline))
                    // Home: where the brand green sits.
                    Circle()
                        .strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                        .frame(width: Self.knob - 4, height: Self.knob - 4)
                        .position(Self.point(for: .home, in: size))
                        .opacity(theme.choice == nil ? 0 : 1)
                        .help("The original green")
                    Circle()
                        .fill(Palette.accent)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: 0.5).padding(-0.5))
                        .frame(width: Self.knob, height: Self.knob)
                        .scaleEffect(dragging && !reduced ? 1.3 : 1)
                        .motion(Motion.press, value: dragging)
                        .position(Self.point(for: current, in: size))
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag(to: $0.location, in: size) }.onEnded { _ in endDrag() })
            }
            .frame(height: Self.height)
            .accessibilityElement()
            .accessibilityLabel("Accent color")
            .accessibilityValue(theme.choice == nil ? "The original green" : "Hue \(Int((theme.choice?.hue ?? 0) * 360)) degrees")
            .accessibilityAdjustableAction { direction in
                let base = theme.choice ?? .home
                let step = direction == .increment ? 1.0 / Double(Self.detents) : -1.0 / Double(Self.detents)
                theme.set(AccentChoice(hue: base.hue + step, vibrance: base.vibrance))
            }

            HStack(spacing: Space.s) {
                swatch(name: "Original", choice: nil)
                ForEach(Self.presets) { swatch(name: $0.name, choice: $0.choice) }
            }
        }
    }

    private var variant: Variant {
        switch (scheme, contrast) {
        case (.dark, .increased): .highContrastDark
        case (.dark, _): .dark
        case (_, .increased): .highContrastLight
        default: .light
        }
    }

    private func swatch(name: String, choice: AccentChoice?) -> some View {
        let selected = theme.choice == choice
        let fill = choice.map(AccentTheme.color(for:)) ?? Palette.brandAccent
        return Button {
            theme.set(choice)
            Haptics.alignment()
        } label: {
            Circle()
                .fill(fill)
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Palette.textPrimary : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Dragging

    private func drag(to location: CGPoint, in size: CGSize) {
        if !dragging { dragging = true }
        let home = Self.point(for: .home, in: size)
        if hypot(location.x - home.x, location.y - home.y) <= Self.homeRadius {
            if !snappedHome {
                snappedHome = true
                Haptics.levelChange()
            }
            theme.set(nil, persist: false)
            return
        }
        snappedHome = false
        let choice = Self.choice(at: location, in: size)
        let detent = Int(choice.hue * Double(Self.detents))
        if let lastDetent, lastDetent != detent { Haptics.alignment() }
        lastDetent = detent
        theme.set(choice, persist: false)
    }

    private func endDrag() {
        dragging = false
        lastDetent = nil
        snappedHome = false
        theme.set(theme.choice)
    }

    // MARK: Geometry (pure; tested)

    /// Hue runs left → right, vibrance bottom → top. The knob stays a radius inside the edges.
    static func choice(at p: CGPoint, in size: CGSize) -> AccentChoice {
        let inset = knob / 2
        let x = (p.x - inset) / max(size.width - knob, 1)
        let y = (p.y - inset) / max(size.height - knob, 1)
        return AccentChoice(hue: min(max(x, 0), 0.9999), vibrance: 1 - min(max(y, 0), 1))
    }

    static func point(for c: AccentChoice, in size: CGSize) -> CGPoint {
        let inset = knob / 2
        return CGPoint(x: inset + c.hue * (size.width - knob), y: inset + (1 - c.vibrance) * (size.height - knob))
    }

    // MARK: Painting

    enum Variant: Int, Sendable { case light, dark, highContrastLight, highContrastDark }

    static let columns = 96

    /// Each column's (vivid, soft) color for a variant, worked out once.
    nonisolated(unsafe) private static var stripCache: [Variant: [(Color, Color)]] = [:]

    @MainActor
    private static func strips(_ variant: Variant) -> [(Color, Color)] {
        if let cached = stripCache[variant] { return cached }
        let strips = (0..<columns).map { i -> (Color, Color) in
            let hue = (Double(i) + 0.5) / Double(columns)
            func pick(_ v: AccentMath.Variants) -> AccentMath.RGB {
                switch variant {
                case .light: v.light
                case .dark: v.dark
                case .highContrastLight: v.highContrastLight
                case .highContrastDark: v.highContrastDark
                }
            }
            return (Color(nsColor: pick(AccentMath.variants(AccentChoice(hue: hue, vibrance: 1))).nsColor),
                    Color(nsColor: pick(AccentMath.variants(AccentChoice(hue: hue, vibrance: 0))).nsColor))
        }
        stripCache[variant] = strips
        return strips
    }

    @MainActor
    static func paint(_ ctx: GraphicsContext, size: CGSize, variant: Variant) {
        let strips = strips(variant)
        let w = size.width / CGFloat(columns)
        for (i, strip) in strips.enumerated() {
            // Overlap by a point so no seams show between columns.
            let rect = CGRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: size.height)
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [strip.0, strip.1]),
                                                       startPoint: CGPoint(x: rect.midX, y: knob / 2),
                                                       endPoint: CGPoint(x: rect.midX, y: size.height - knob / 2)))
        }
    }
}

/// Settings ▸ General: the rewards for finding every secret, or how many are left until then.
struct SecretsSettingsRow: View {
    private var rewards: SecretRewards { SecretRewards.shared }

    var body: some View {
        if rewards.isUnlocked {
            SettingsRow("Accent", help: "Drag the knob, or pick a swatch. It recolors everything; each color is adjusted to stay readable in light and dark.") {
                AccentPad().frame(maxWidth: 420)
                    .alignmentGuide(.firstTextBaseline) { $0[.top] + 13 }
            }
            SettingsRow("App icon", help: "Shows in the Dock and the app switcher. Finder keeps the original.") {
                HStack(spacing: Space.l) {
                    ForEach(SecretRewards.Icon.allCases) { icon in
                        IconTile(icon: icon, selected: rewards.icon == icon) {
                            rewards.setIcon(icon)
                            Haptics.levelChange()
                        }
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[.top] + 13 }
            }
        } else {
            SettingsRow("Secrets", help: "Find every easter egg to unlock your own accent color and a new app icon. ⌘K knows a hint: try “secret”.") {
                HStack(spacing: Space.xs) {
                    Image(systemName: "lock.fill").foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
                    Text("\(rewards.found) of \(rewards.total) found").monospacedDigit()
                }
            }
        }
    }
}

private struct IconTile: View {
    var icon: SecretRewards.Icon
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .padding(Space.xs)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(selected ? Palette.accent : Color.clear, lineWidth: 2))
                Text(icon.title).font(Typography.callout).foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var image: NSImage {
        switch icon {
        case .standard: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        case .midnightGold: SecretIcon.image
        }
    }
}
