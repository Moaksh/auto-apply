// Tokens.swift — color, typography, spacing and radius tokens (docs/UI_UX_PLAN.md §1.2–1.4).
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
enum Palette {
    /// "Signal Indigo" — the only accent. Respects a non-multicolor system accent choice.
    static var accent: Color {
        UserDefaults.standard.object(forKey: "AppleAccentColor") != nil ? .accentColor : signalIndigo
    }
    static let signalIndigo = Color(light: 0x4F5BD5, dark: 0x7C86FF, highContrastLight: 0x3A44B8, highContrastDark: 0xA3AAFF)

    // Neutrals
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let surfaceRaised = Color(light: 0xFAFAFB, dark: 0x242427)
    static let sunken = Color(light: 0xF2F2F5, dark: 0x141416)
    static let hairline = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08),
                                                  highContrastLight: NSColor(white: 0, alpha: 0.14), highContrastDark: NSColor(white: 1, alpha: 0.14)))
    static let strokeStrong = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.14)))
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    /// Ground for the onboarding / Ignition canvas (both themes).
    static let ignitionGround = Color(hex: 0x0B0B12)

    // Status (hue + symbol; see StatusKind)
    static let discovered = Color(light: 0x8E8E93, dark: 0x98989F)
    static let skipped = Color(light: 0xAEAEB2, dark: 0x636366)
    static let queued = Color(light: 0x5E9EFF, dark: 0x6AA8FF)
    static let needsYou = Color(light: 0xF5A524, dark: 0xFFB940)
    static let applied = Color(light: 0x30B06E, dark: 0x3CCB7F)
    static let assessment = Color(light: 0xA970FF, dark: 0xB98BFF)
    static let interview = Color(light: 0x16A3B8, dark: 0x2DC6DC)
    static let offer = Color(light: 0xE8B500, dark: 0xFFD43B)
    /// Rejections are deliberately desaturated (~70% sat) so the board isn't a wall of failure.
    static let rejected = Color(light: 0xD8696C, dark: 0xFF6369)
    static let ghosted = Color(light: 0xC7C7CC, dark: 0x48484A)
    static let error = Color(light: 0xE5484D, dark: 0xFF6369)

    /// Categorical chart palette (sources, resume variants) — shares the accent's luminance.
    static let categorical: [Color] = [
        Color(hex: 0x7C86FF), Color(hex: 0x2DC6DC), Color(hex: 0xFFB940), Color(hex: 0xF27BA6), Color(hex: 0x8E9AAF),
    ]

    /// Single-series indigo ramp (accent at 100 / 70 / 45 / 25 %).
    static func accentRamp(_ step: Int) -> Color {
        let opacities = [1.0, 0.7, 0.45, 0.25]
        return accent.opacity(opacities[max(0, min(opacities.count - 1, step))])
    }
}

// MARK: - Typography

/// Type tokens. Rounded is reserved for numbers; mono for what the machine says.
enum Typography {
    static let display = Font.system(size: 34, weight: .bold).width(.standard)
    static let title1 = Font.system(.largeTitle, weight: .semibold)       // 26
    static let title2 = Font.system(.title2, weight: .semibold)           // 17
    static let body = Font.system(.body)                                  // 13
    static let bodyEmph = Font.system(.body, weight: .medium)
    static let callout = Font.system(.callout)                            // 12
    static let caption = Font.system(.subheadline, weight: .medium)       // 11 (use with .eyebrowStyle())
    static let metricXL = Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
    static let metric = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    static let metricSmall = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, weight: .medium, design: .monospaced)
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
    /// Eyebrow style: 11pt medium, uppercase, +0.6 tracking, secondary ("TODAY", "PIPELINE").
    func eyebrowStyle() -> some View {
        font(Typography.caption).textCase(.uppercase).tracking(0.6).foregroundStyle(Palette.textSecondary)
    }

    /// Display headline tracking (−0.4).
    func displayStyle() -> some View {
        font(Typography.display).tracking(-0.4)
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
    static let card: CGFloat = 14
    static let inner: CGFloat = 8
    static let thumb: CGFloat = 6
    static let palette: CGFloat = 18
    static let logo: CGFloat = 5

    /// Concentric rule: inner = outer − padding, clamped to ≥ 6.
    static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat { max(6, outer - padding) }
}

/// Window and pane sizes (§1.4).
enum LayoutMetrics {
    static let minWindow = CGSize(width: 1040, height: 680)
    static let defaultWindow = CGSize(width: 1320, height: 860)
    static let sidebarWidth: CGFloat = 220
    static let inspectorMin: CGFloat = 320
    static let inspectorMax: CGFloat = 420
    static let boardColumnWidth: CGFloat = 248
    static let paletteWidth: CGFloat = 640
    static let menuBarWidth: CGFloat = 340
    static let onboardingSize = CGSize(width: 880, height: 620)
}

extension Shape where Self == RoundedRectangle {
    static var card: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.card, style: .continuous) }
    static var inner: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.inner, style: .continuous) }
    static var thumb: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous) }
}
