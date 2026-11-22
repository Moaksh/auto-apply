// AccentTheme.swift — the accent color people can pick once every easter egg is found (the
// accent pad in Settings ▸ General). A pick is a point on the pad, hue × vibrance; each
// appearance gets its own lightness so the accent always meets contrast: ≥ 4.5:1 against every
// light / dark background (7:1 with Increase Contrast), which also keeps `Palette.onAccent`
// (white on light, ink on dark) readable. Colors are worked out in OKLCH so equal steps look
// equal. No pick (the default) is the brand green, exactly.
//
// The backgrounds (window, surface, sunken) carry a whisper of the accent's hue for everyone: the
// brand green by default, the pick once there is one. Same lightness as the neutral they replace,
// so text contrast doesn't move; none with Increase Contrast.
import AppKit
import Observation
import SwiftUI

/// A spot on the accent pad.
struct AccentChoice: Sendable, Equatable, Codable {
    /// 0 ..< 1 around the color wheel (OKLCH hue / 360°).
    var hue: Double
    /// 0 (a hint of color) … 1 (as vivid as the screen can show at that lightness).
    var vibrance: Double

    init(hue: Double, vibrance: Double) {
        self.hue = hue - floor(hue)
        self.vibrance = min(max(vibrance, 0), 1)
    }

    /// Where the brand green sits on the pad (the knob's home; snapping there clears the pick).
    static let home: AccentChoice = {
        let lch = AccentMath.oklch(hex: 0x0F5C4F)
        return AccentChoice(hue: lch.h / 360, vibrance: (lch.c - AccentMath.minChroma) / (AccentMath.maxChroma - AccentMath.minChroma))
    }()

    /// The four variants of this pick (light, dark, high-contrast light, high-contrast dark).
    var variants: AccentMath.Variants { AccentMath.variants(self) }
}

/// The current accent. `Palette.accent` reads `color`, so every view drawing the accent redraws
/// when the pick changes (Observation tracks the read).
@Observable
final class AccentTheme: @unchecked Sendable {
    static let shared = AccentTheme()
    static let storageKey = "accent.choice"

    /// nil = the brand green.
    private(set) var choice: AccentChoice?
    private(set) var color: Color = Palette.brandAccent
    /// Background tokens tinted toward the accent hue (`Palette.windowBackground` etc.).
    private(set) var backgrounds: Backgrounds = Backgrounds(hue: AccentChoice.home.hue)
    /// The brand media's greens (hero field, signal) moved to the pick's hue, by original hex.
    private var tones: [UInt32: Color] = [:]

    /// The greens of the brand field that follow a pick.
    static let toneHexes: [UInt32] = [0x003C33, 0x062A27, 0x00483D, 0x5FD9B9]

    @ObservationIgnored var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode(AccentChoice.self, from: data) {
            choice = saved
            color = Self.color(for: saved)
            tones = Self.tones(for: saved)
            backgrounds = Backgrounds(hue: saved.hue)
        }
    }

    /// A brand-field green, or with a pick, the same depth at the pick's hue.
    func tone(_ hex: UInt32) -> Color { tones[hex] ?? Color(hex: hex) }

    /// Sets (or with nil, clears) the pick. `persist: false` while the knob is still moving.
    func set(_ new: AccentChoice?, persist: Bool = true) {
        if new != choice {
            choice = new
            color = new.map(Self.color(for:)) ?? Palette.brandAccent
            tones = new.map(Self.tones(for:)) ?? [:]
            backgrounds = Backgrounds(hue: (new ?? .home).hue)
        }
        guard persist else { return }
        if let new, let data = try? JSONEncoder().encode(new) {
            defaults.set(data, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    /// The three background tokens at one hue.
    struct Backgrounds {
        var window: Color, surface: Color, sunken: Color

        init(hue: Double) {
            let h = hue * 360
            window = Self.tinted(h) { _ in NSColor.windowBackgroundColor }
            surface = Self.tinted(h) { $0 ? NSColor(hex: 0x1A1A1F) : NSColor(hex: 0xFFFFFF) }
            sunken = Self.tinted(h) { $0 ? NSColor(hex: 0x111114) : NSColor(hex: 0xEEECE7) }
        }

        /// `base(isDark)` resolved for each appearance, then tinted (untouched with Increase Contrast).
        private static func tinted(_ hue: Double, _ base: @escaping @Sendable (Bool) -> NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                var resolved = base(dark)
                appearance.performAsCurrentDrawingAppearance { resolved = resolved.usingColorSpace(.sRGB) ?? resolved }
                guard match == .aqua || match == .darkAqua, let rgb = AccentMath.RGB(nsColor: resolved) else { return resolved }
                return AccentMath.tint(rgb, hue: hue, dark: dark).nsColor
            })
        }
    }

    static func tones(for choice: AccentChoice) -> [UInt32: Color] {
        Dictionary(uniqueKeysWithValues: toneHexes.map { hex in
            (hex, Color(nsColor: AccentMath.retoned(hex, to: choice).nsColor))
        })
    }

    static func color(for choice: AccentChoice) -> Color {
        let v = choice.variants
        return Color(nsColor: .dynamic(light: v.light.nsColor, dark: v.dark.nsColor,
                                       highContrastLight: v.highContrastLight.nsColor, highContrastDark: v.highContrastDark.nsColor))
    }
}

// MARK: - Math (pure; tested)

enum AccentMath {
    static let minChroma = 0.025
    static let maxChroma = 0.20
    /// Contrast every accent keeps against the backgrounds it's drawn on.
    static let contrast = 4.5
    static let highContrast = 7.0
    /// The palest light-mode and the brightest dark-mode backgrounds the accent sits on
    /// (sunken / window, rounded toward the harder case).
    static let lightBackground: UInt32 = 0xE8E8E8
    static let darkBackground: UInt32 = 0x323232

    /// Linear-light sRGB, 0…1 per channel.
    struct RGB: Sendable, Equatable {
        var r: Double, g: Double, b: Double

        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        var inGamut: Bool { [r, g, b].allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 } }

        init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

        init(hex: UInt32) {
            func lin(_ v: UInt32) -> Double {
                let c = Double(v & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            self.init(r: lin(hex >> 16), g: lin(hex >> 8), b: lin(hex))
        }

        /// Gamma-encoded sRGB components (clamped).
        var encoded: (Double, Double, Double) {
            func enc(_ v: Double) -> Double {
                let c = min(max(v, 0), 1)
                return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            return (enc(r), enc(g), enc(b))
        }

        /// From any color that converts to sRGB.
        init?(nsColor: NSColor) {
            guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
            func lin(_ v: CGFloat) -> Double { v <= 0.04045 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
            self.init(r: lin(c.redComponent), g: lin(c.greenComponent), b: lin(c.blueComponent))
        }

        var hex: UInt32 {
            let (r, g, b) = encoded
            return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
        }

        var nsColor: NSColor {
            let (r, g, b) = encoded
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    struct Variants: Sendable, Equatable {
        var light: RGB, dark: RGB, highContrastLight: RGB, highContrastDark: RGB
    }

    static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// OKLCH (L 0…1, C, h in degrees) → linear sRGB (may be out of gamut).
    static func rgb(l: Double, c: Double, h: Double) -> RGB {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        return RGB(r: 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                   g: -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                   b: -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
    }

    static func oklch(hex: UInt32) -> (l: Double, c: Double, h: Double) { oklch(rgb: RGB(hex: hex)) }

    static func oklch(rgb p: RGB) -> (l: Double, c: Double, h: Double) {
        let l = cbrt(0.4122214708 * p.r + 0.5363015719 * p.g + 0.0514459929 * p.b)
        let m = cbrt(0.2119034982 * p.r + 0.6806995451 * p.g + 0.1073969566 * p.b)
        let s = cbrt(0.0883024619 * p.r + 0.2817188376 * p.g + 0.6299787005 * p.b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let h = atan2(B, A) * 180 / .pi
        return (L, hypot(A, B), h < 0 ? h + 360 : h)
    }

    /// The color at lightness `l`, with chroma pulled in until it fits the screen.
    static func fitted(l: Double, c: Double, h: Double) -> RGB {
        let full = rgb(l: l, c: c, h: h)
        if full.inGamut { return full }
        var lo = 0.0, hi = c
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if rgb(l: l, c: mid, h: h).inGamut { lo = mid } else { hi = mid }
        }
        return rgb(l: l, c: lo, h: h)
    }

    /// The lightest color darker than `maxLuminance` (light mode), or the darkest one brighter
    /// than `minLuminance` (dark mode), at this hue and chroma.
    static func solve(c: Double, h: Double, maxLuminance: Double? = nil, minLuminance: Double? = nil) -> RGB {
        var lo = 0.0, hi = 1.0
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            let y = fitted(l: mid, c: c, h: h).luminance
            if let maxLuminance {
                if y <= maxLuminance { lo = mid } else { hi = mid }
            } else if let minLuminance {
                if y >= minLuminance { hi = mid } else { lo = mid }
            }
        }
        return fitted(l: maxLuminance != nil ? lo : hi, c: c, h: h)
    }

    /// How much color a background takes on: barely there on light, a touch more on dark.
    static let lightTint = 0.006
    static let darkTint = 0.011

    /// A neutral background with a whisper of `hue` (degrees), at its own lightness (pure; tested).
    static func tint(_ base: RGB, hue: Double, dark: Bool) -> RGB {
        let o = oklch(rgb: base)
        return fitted(l: o.l, c: dark ? darkTint : lightTint, h: hue)
    }

    /// `hex` turned around the wheel as far as the pick is from the brand green: same lightness,
    /// chroma scaled with vibrance, so the field keeps its depth and its own hue spread (pure; tested).
    static func retoned(_ hex: UInt32, to choice: AccentChoice) -> RGB {
        let o = oklch(hex: hex)
        let home = AccentChoice.home
        let scale = (0.35 + choice.vibrance) / (0.35 + home.vibrance)
        return fitted(l: o.l, c: o.c * scale, h: o.h + (choice.hue - home.hue) * 360)
    }

    static func variants(_ choice: AccentChoice) -> Variants {
        let h = choice.hue * 360
        let c = minChroma + choice.vibrance * (maxChroma - minChroma)
        let lightY = RGB(hex: lightBackground).luminance, darkY = RGB(hex: darkBackground).luminance
        func onLight(_ t: Double) -> RGB { solve(c: c, h: h, maxLuminance: (lightY + 0.05) / t - 0.05) }
        func onDark(_ t: Double) -> RGB { solve(c: c, h: h, minLuminance: t * (darkY + 0.05) - 0.05) }
        return Variants(light: onLight(contrast + 0.05), dark: onDark(contrast + 0.05),
                        highContrastLight: onLight(highContrast + 0.05), highContrastDark: onDark(highContrast + 0.05))
    }
}
