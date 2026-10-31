// Tokens.swift — color, typography, spacing and radius tokens.
// Views never use raw colors or sizes: everything goes through these names.
import AppKit
import SwiftUI

// MARK: - Color helpers

extension NSColor {
    /// sRGB color from a 0xRRGGBB literal.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Appearance-aware color with optional Increase Contrast variants.
    static func dynamic(light: NSColor, dark: NSColor, highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: dark
            case .accessibilityHighContrastAqua?: highContrastLight ?? light
            case .accessibilityHighContrastDarkAqua?: highContrastDark ?? dark
            default: light
            }
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil) {
        self.init(nsColor: .dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark),
                                    highContrastLight: highContrastLight.map { NSColor(hex: $0) },
                                    highContrastDark: highContrastDark.map { NSColor(hex: $0) }))
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: opacity))
    }
}

// MARK: - Palette

/// Semantic color tokens. Every token adapts to light/dark and Increase Contrast.
///
/// Quiet ink-and-stone content with one deep-green accent. Coral is only for small "needs you"
/// markers. Text tokens meet 4.5:1 and status inks 3:1 on every surface in both modes.
enum Palette {
    /// The only UI accent (selection, toggles, links, the needs-a-look rule): deep green in light
    /// mode, a lighter green-teal in dark mode. Deliberately ignores the system accent.
    static var accent: Color { brandAccent }
    static let brandAccent = Color(light: 0x0F5C4F, dark: 0x29AB8B, highContrastLight: 0x003C33, highContrastDark: 0x5FD9B9)
    /// Text or symbols drawn on an accent fill: white on the light-mode green, ink on the
    /// dark-mode green (white on #29AB8B is only 2.9:1; ink is 6.2:1).
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x17171C)

    /// Raw brand swatches. Use for media (the onboarding canvas), not ordinary UI chrome.
    enum Brand {
        static let ink = Color(hex: 0x000000)
        static let ink2 = Color(hex: 0x17171C)
        static let deepGreen = Color(hex: 0x003C33)
        static let navy = Color(hex: 0x071829)
        static let coral = Color(hex: 0xFF7759)
        /// Green-teal signal for marks drawn on always-dark media (onboarding trail).
        static let signal = Color(hex: 0x5FD9B9)
    }

    /// Small warm markers only (the greeting accent). Never surfaces or buttons.
    static let coral = Color(light: 0xC2461F, dark: 0xFF7759, highContrastLight: 0xB23A1C, highContrastDark: 0xFFAD9B)
    /// The in-content primary action: an ink pill on light, a white pill on dark.
    static let primaryFill = Color(light: 0x17171C, dark: 0xFFFFFF)
    static let onPrimaryFill = Color(light: 0xFFFFFF, dark: 0x17171C)

    // Neutrals: flat. Depth comes from surface vs. window + a hairline, never shadows.
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1A1A1F)
    static let sunken = Color(light: 0xEEECE7, dark: 0x111114)
    static let hairline = Color(nsColor: .dynamic(light: NSColor(hex: 0x17171C, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.08),
                                                  highContrastLight: NSColor(hex: 0x17171C, alpha: 0.18), highContrastDark: NSColor(white: 1, alpha: 0.16)))
    static let strokeStrong = Color(nsColor: .dynamic(light: NSColor(hex: 0x17171C, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.14)))
    static let textPrimary = Color(nsColor: .labelColor)
    /// Slate: secondary lines and labels (≥ 5.5:1).
    static let textSecondary = Color(light: 0x5F5F72, dark: 0x9C9CA8, highContrastLight: 0x3F3F4E, highContrastDark: 0xC2C2CC)
    /// Captions and hints. ≥ 4.5:1 on surface, sunken and window in both modes (was 2.6–3.8).
    static let textTertiary = Color(light: 0x676774, dark: 0x92929E, highContrastLight: 0x4F4F5E, highContrastDark: 0xB4B4BE)
    /// Ground for the onboarding / Ignition canvas (both themes): near-black ink with a green cast.
    static let ignitionGround = Color(hex: 0x05090B)

    // Status (hue + symbol; see StatusKind). Every ink is ≥ 3:1 on surface and sunken.
    static let discovered = Color(light: 0x75758A, dark: 0x9C9CA8)
    static let skipped = Color(light: 0x7A7A86, dark: 0x7E7E8A)
    static let queued = Color(light: 0x52708F, dark: 0x8EA7C2)
    static let needsYou = Color(light: 0xC2461F, dark: 0xFF7759, highContrastLight: 0xB23A1C, highContrastDark: 0xFFAD9B)
    static let applied = Color(light: 0x2F8F46, dark: 0x74CF6B)
    static let assessment = Color(light: 0xB8456E, dark: 0xEC86A8)
    static let interview = Color(light: 0x1863DC, dark: 0x6EA0F5)
    static let offer = Color(light: 0x9A7600, dark: 0xF2C94C)
    /// Rejections are deliberately desaturated so the board isn't a wall of failure.
    static let rejected = Color(light: 0x9C5B5B, dark: 0xC88585)
    static let ghosted = Color(light: 0x828290, dark: 0x8A8A96)
    static let error = Color(light: 0xB30000, dark: 0xFF5C50, highContrastLight: 0x8F0000, highContrastDark: 0xFF8A80)

    /// Categorical chart palette (sources, resume variants): brand green, action blue, coral,
    /// sand and slate. Index 4 is the neutral used for "other / skipped" series.
    static let categorical: [Color] = [
        Color(light: 0x0F5C4F, dark: 0x29AB8B), Color(light: 0x1863DC, dark: 0x6EA0F5), Color(light: 0xE0603F, dark: 0xFF8B70),
        Color(light: 0xA88A4E, dark: 0xD9BC82), Color(light: 0x75758A, dark: 0x93939F),
    ]

    /// Single-series accent ramp (accent at 100 / 70 / 45 / 25 %).
    static func accentRamp(_ step: Int) -> Color {
        let opacities = [1.0, 0.7, 0.45, 0.25]
        return accent.opacity(opacities[max(0, min(opacities.count - 1, step))])
    }
}

// MARK: - Typography

/// Type tokens. Restrained: tight display, calm body, no heavy bold. Rounded is
/// reserved for numbers; SF Mono for what the machine says and for uppercase category labels.
enum Typography {
    static let display = Font.system(size: 34, weight: .medium).width(.standard)
    /// Large hero display (dashboard greeting band, onboarding).
    static let hero = Font.system(size: 40, weight: .medium)
    static let title1 = Font.system(.largeTitle, weight: .medium)         // 26
    static let title2 = Font.system(.title2, weight: .semibold)           // 17
    static let body = Font.system(.body)                                  // 13
    static let bodyEmph = Font.system(.body, weight: .medium)
    static let callout = Font.system(.callout)                            // 12
    /// Eyebrow / category label: SF Mono, used uppercase via `.eyebrowStyle()`.
    static let caption = Font.system(size: 10.5, weight: .medium, design: .monospaced) // 10.5
    static let metricXL = Font.system(size: 44, weight: .medium, design: .rounded).monospacedDigit()
    static let metric = Font.system(size: 22, weight: .medium, design: .rounded).monospacedDigit()
    static let metricSmall = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    /// Ticket field label ("MATCH", "CLOSES"): SF Mono caps, wide tracking. Use via `TicketField`.
    static let ticketLabel = Font.system(size: 10, weight: .medium, design: .monospaced)
    /// Ticket field value ("92", "Fri 25"): mono, readable, numbers aligned.
    static let ticketValue = Font.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit()
}

extension Font {
    static let metricXL = Typography.metricXL
    static let metric = Typography.metric
    static let mono = Typography.mono
    static let monoSmall = Typography.monoSmall
    static let eyebrow = Typography.caption
    static let display = Typography.display
}

extension View {
    /// Eyebrow style: SF Mono 10.5 medium, uppercase, +0.8 tracking, secondary ("TODAY", "PIPELINE").
    func eyebrowStyle() -> some View {
        font(Typography.caption).textCase(.uppercase).tracking(0.8).foregroundStyle(Palette.textSecondary)
    }

    /// Display headline: tight tracking, line height ≈ 1.0.
    func displayStyle() -> some View {
        font(Typography.display).tracking(-0.9)
    }

    /// Hero display (onboarding): larger and tighter still.
    func heroDisplayStyle() -> some View {
        font(Typography.hero).tracking(-1.2)
    }
}

// MARK: - Spacing & radii

/// 4pt grid.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48

    /// Detail-pane content padding.
    static let contentPadding: CGFloat = 24
    /// Card internal padding.
    static let cardPadding: CGFloat = 16
    /// Gutter between dashboard cards.
    static let gutter: CGFloat = 12
}

/// Corner radii (always `.continuous`).
enum Radius {
    /// Cards and panels: crisp, editorial.
    static let card: CGFloat = 8
    /// Rows, wells and inputs inside a surface (concentric with `card` at 2pt inset).
    static let inner: CGFloat = 6
    static let thumb: CGFloat = 6
    /// The onboarding canvas cards.
    static let hero: CGFloat = 22
    /// Floating glass panels (⌘K, menu bar).
    static let palette: CGFloat = 18
    static let logo: CGFloat = 5
}

/// Window and pane sizes (§1.4).
enum LayoutMetrics {
    static let minWindow = CGSize(width: 1040, height: 680)
    static let defaultWindow = CGSize(width: 1320, height: 860)
    static let sidebarWidth: CGFloat = 220
    static let inspectorWidth: CGFloat = 340
    static let boardColumnWidth: CGFloat = 248
    static let paletteWidth: CGFloat = 640
    static let menuBarWidth: CGFloat = 340
    static let onboardingSize = CGSize(width: 880, height: 620)
}

extension Shape where Self == RoundedRectangle {
    static var card: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.card, style: .continuous) }
    static var inner: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.inner, style: .continuous) }
    static var thumb: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous) }
    static var hero: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.hero, style: .continuous) }
}
