// SecretRewardsTests.swift — what finding every secret unlocks: accent picks that always stay
// readable, the pad's geometry, and the Midnight Gold icon only after the last secret.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@Suite("Secret rewards")
struct SecretRewardsTests {
    private func ratio(_ a: AccentMath.RGB, _ hex: UInt32) -> Double {
        AccentMath.ratio(a.luminance, AccentMath.RGB(hex: hex).luminance)
    }

    @Test func everyPickMeetsContrastInEveryAppearance() {
        for h in stride(from: 0.0, to: 1.0, by: 1.0 / 36) {
            for v in stride(from: 0.0, through: 1.0, by: 0.25) {
                let c = AccentChoice(hue: h, vibrance: v).variants
                for variant in [c.light, c.dark, c.highContrastLight, c.highContrastDark] { #expect(variant.inGamut) }
                // Against the backgrounds it's drawn on…
                for bg: UInt32 in [0xFFFFFF, 0xEEECE7, AccentMath.lightBackground] {
                    #expect(ratio(c.light, bg) >= 4.5, "light h=\(h) v=\(v) on \(String(bg, radix: 16))")
                    #expect(ratio(c.highContrastLight, bg) >= 7, "hc light h=\(h) v=\(v)")
                }
                for bg: UInt32 in [0x1A1A1F, 0x111114, AccentMath.darkBackground] {
                    #expect(ratio(c.dark, bg) >= 4.5, "dark h=\(h) v=\(v) on \(String(bg, radix: 16))")
                    #expect(ratio(c.highContrastDark, bg) >= 7, "hc dark h=\(h) v=\(v)")
                }
                // …and for text on an accent fill (Palette.onAccent: white on light, ink on dark).
                #expect(ratio(c.light, 0xFFFFFF) >= 4.5)
                #expect(ratio(c.dark, 0x17171C) >= 4.5)
            }
        }
    }

    @Test func vibranceMakesItMoreColorful() {
        for h in [0.0, 0.3, 0.6] {
            let soft = AccentMath.oklch(hex: AccentChoice(hue: h, vibrance: 0).variants.light.hex)
            let vivid = AccentMath.oklch(hex: AccentChoice(hue: h, vibrance: 1).variants.light.hex)
            #expect(vivid.c > soft.c + 0.05)
        }
    }

    @Test func homeIsTheBrandGreen() {
        let home = AccentChoice.home
        let back = AccentMath.oklch(hex: 0x0F5C4F)
        #expect(abs(home.hue * 360 - back.h) < 0.5)
        #expect((0...1).contains(home.vibrance))
    }

    @Test func theHeroFieldFollowsThePickAtTheSameDepth() {
        // At home, the field's greens come back as themselves.
        for hex in AccentTheme.toneHexes {
            let same = AccentMath.retoned(hex, to: .home).hex
            for shift in [16, 8, 0] { #expect(abs(Int((same >> shift) & 0xFF) - Int((hex >> shift) & 0xFF)) <= 3) }
        }
        // A purple pick moves the hue and keeps the lightness.
        let o = AccentMath.oklch(hex: 0x00483D)
        let moved = AccentMath.oklch(hex: AccentMath.retoned(0x00483D, to: AccentChoice(hue: 0.82, vibrance: 0.9)).hex)
        #expect(abs(moved.l - o.l) < 0.01)
        let turned = (o.h + (0.82 - AccentChoice.home.hue) * 360).truncatingRemainder(dividingBy: 360)
        #expect(abs(moved.h - (turned < 0 ? turned + 360 : turned)) < 4)
    }

    @Test func backgroundsTakeOnAWhisperOfTheHueAtTheSameLightness() {
        for (hex, dark) in [(UInt32(0xFFFFFF), false), (0xEEECE7, false), (0x1A1A1F, true), (0x111114, true)] {
            for hue in [AccentChoice.home.hue * 360, 300.0] {
                let base = AccentMath.oklch(hex: hex)
                let t = AccentMath.oklch(hex: AccentMath.tint(AccentMath.RGB(hex: hex), hue: hue, dark: dark).hex)
                #expect(abs(t.l - base.l) < 0.01, "lightness kept for \(String(hex, radix: 16))")
                #expect(t.c <= 0.016, "subtle: chroma \(t.c)")
            }
        }
    }

    @Test func padMapsPointsToPicksAndBack() {
        let size = CGSize(width: 420, height: AccentPad.height)
        for c in [AccentChoice(hue: 0, vibrance: 1), AccentChoice(hue: 0.5, vibrance: 0.5), AccentChoice(hue: 0.9, vibrance: 0)] {
            let back = AccentPad.choice(at: AccentPad.point(for: c, in: size), in: size)
            #expect(abs(back.hue - c.hue) < 0.001 && abs(back.vibrance - c.vibrance) < 0.001)
        }
        // Past the edges it clamps instead of wrapping.
        let far = AccentPad.choice(at: CGPoint(x: 9999, y: -50), in: size)
        #expect(far.hue > 0.99 && far.vibrance == 1)
        #expect(AccentPad.choice(at: CGPoint(x: -50, y: 9999), in: size) == AccentChoice(hue: 0, vibrance: 0))
    }

    @Test func theAccentPickPersistsAndClears() throws {
        let defaults = try #require(UserDefaults(suiteName: "SecretRewardsTests.accent"))
        defaults.removePersistentDomain(forName: "SecretRewardsTests.accent")
        let theme = AccentTheme(defaults: defaults)
        #expect(theme.choice == nil)
        theme.set(AccentChoice(hue: 0.82, vibrance: 0.9), persist: false)
        #expect(AccentTheme(defaults: defaults).choice == nil, "a drag in progress isn't saved")
        theme.set(theme.choice)
        #expect(AccentTheme(defaults: defaults).choice == AccentChoice(hue: 0.82, vibrance: 0.9))
        theme.set(nil)
        #expect(AccentTheme(defaults: defaults).choice == nil)
    }

    @MainActor
    @Test func theIconUnlocksWithTheLastSecret() throws {
        let saved = UserDefaults.standard.stringArray(forKey: "easterEggs.found")
        defer { UserDefaults.standard.set(saved, forKey: "easterEggs.found") }
        let defaults = try #require(UserDefaults(suiteName: "SecretRewardsTests.icon"))
        defaults.removePersistentDomain(forName: "SecretRewardsTests.icon")

        EasterEggs.discoveries = EasterEggs.Discoveries(found: [.heart, .wave])
        let rewards = SecretRewards(defaults: defaults)
        #expect(!rewards.isUnlocked && rewards.found == 2)
        rewards.setIcon(.midnightGold)
        #expect(rewards.icon == .standard, "locked until every secret is found")

        EasterEggs.discoveries = EasterEggs.Discoveries(found: Set(EasterEggs.Flavor.allCases))
        rewards.refresh()
        #expect(rewards.isUnlocked)
        rewards.setIcon(.midnightGold)
        #expect(rewards.icon == .midnightGold && defaults.string(forKey: SecretRewards.iconKey) == "midnightGold")
        rewards.setIcon(.standard)
        NSApplication.shared.applicationIconImage = nil
    }

    @MainActor
    @Test func theIconDrawsAtEverySize() {
        for px in [16, 32, 64, 1024] {
            let rep = SecretIcon.draw(pixels: px)
            #expect(rep.pixelsWide == px)
            // The centre of the tile is painted (not transparent).
            #expect((rep.colorAt(x: px / 2, y: px / 2)?.alphaComponent ?? 0) > 0.9)
        }
        #expect(SecretIcon.constellation.count == EasterEggs.Flavor.allCases.count, "one star per secret")
    }
}
