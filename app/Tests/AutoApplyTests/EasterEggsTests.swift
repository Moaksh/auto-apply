// EasterEggsTests.swift — the Konami matcher, secret palette phrases, discoveries/hints, the
// heart meter and the confetti physics.
import CoreGraphics
import SwiftUI
import Testing
@testable import AutoApply

@Suite("EasterEggs")
struct EasterEggsTests {
    @Test func konamiMatchesOnlyTheFullSequence() {
        var m = EasterEggs.SequenceMatcher(EasterEggs.konami)
        let hits = EasterEggs.konami.map { m.feed($0) }
        #expect(hits.last == true && hits.dropLast().allSatisfy { !$0 })
        // A wrong key resets; a stray extra ↑ before the sequence still matches.
        var n = EasterEggs.SequenceMatcher(EasterEggs.konami)
        _ = n.feed(126); _ = n.feed(5)
        #expect(!([126] + EasterEggs.konami).map { n.feed($0) }.dropLast().contains(true))
    }

    @Test func phrasesMatchExactlyIgnoringCaseAndSpaces() {
        #expect(EasterEggs.phrase(for: "  Hire   ME ")?.trigger == "hire me")
        #expect(EasterEggs.phrase(for: "42")?.title == "42")
        #expect(EasterEggs.phrase(for: "hire") == nil)
    }

    @Test func everyPhraseHasItsOwnFlavor() {
        let flavors = EasterEggs.phrases.map(\.flavor)
        #expect(Set(flavors).count == flavors.count)
        #expect(!flavors.contains(.konami) && !flavors.contains(.heart))
    }

    @Test func discoveriesCountOnceAndHintTheNextSecret() {
        var d = EasterEggs.Discoveries()
        #expect(d.nextHint == EasterEggs.Flavor.heart.riddle)
        let first = d.record(.heart), again = d.record(.heart)
        #expect(first && !again)
        #expect(d.count == 1 && d.nextHint == EasterEggs.Flavor.wave.riddle)
        #expect(d.eyebrow(for: .konami, isNew: true) == "Achievement unlocked")
        for f in EasterEggs.Flavor.allCases { _ = d.record(f) }
        #expect(d.isComplete && d.nextHint == nil)
        #expect(d.eyebrow(for: .coffee, isNew: true) == "All secrets found")
    }

    @Test func paletteRowsForPhrasesAndTheHint() {
        let none = EasterEggs.Discoveries()
        #expect(EasterEggs.paletteRow(for: "Coffee", discoveries: none)?.subtitle == "Psst…")
        #expect(EasterEggs.paletteRow(for: "coffee", discoveries: .init(found: [.coffee]))?.subtitle == "Psst… again?")
        let hint = EasterEggs.paletteRow(for: " Easter  Egg ", discoveries: .init(found: [.heart, .wave]))
        #expect(hint?.trigger == EasterEggs.hintTrigger && hint?.title == "Secrets found: 2 of 8")
        #expect(EasterEggs.paletteRow(for: "secretary", discoveries: none) == nil)
    }

    @Test func heartMeterEscalatesThenCaps() {
        typealias M = EasterEggs.HeartMeter
        let scales = (0..<M.tapsToBurst).map(M.scale(taps:))
        #expect(zip(scales, scales.dropFirst()).allSatisfy { $0 < $1 })
        #expect(M.scale(taps: 99) == M.scale(taps: M.tapsToBurst - 1))
        #expect(M.intensity(taps: M.tapsToBurst - 1) == 1)
        #expect(M.badge(taps: 1) == nil && M.badge(taps: 3) == "×3" && M.badge(taps: M.tapsToBurst) == nil)
    }

    @Test func confettiIsCappedDeterministicAndFalls() {
        let size = CGSize(width: 1200, height: 800)
        let styles: [EasterEggs.Burst] = [.none, .rain, .cannon, .storm, .hearts, .stars]
        for style in styles {
            let b = ConfettiBurst.make(style, origin: CGPoint(x: 600, y: 400), in: size, colors: [.red], love: [.pink], seed: 7)
            #expect(b.particles.count <= ConfettiBurst.maxParticles)
            #expect(b.lifetime <= ConfettiBurst.maxLifetime)
            #expect((style == .none) == b.particles.isEmpty)
        }
        let a = ConfettiBurst.make(.storm, origin: .zero, in: size, colors: [.red], love: [.pink], seed: 42)
        let b = ConfettiBurst.make(.storm, origin: .zero, in: size, colors: [.red], love: [.pink], seed: 42)
        #expect(a.particles.map(\.start) == b.particles.map(\.start))

        // A cannon piece rises first, then gravity wins; it's gone by the end of its life.
        let p = ConfettiBurst.make(.cannon, origin: CGPoint(x: 600, y: 700), in: size, colors: [.red], love: [.pink], seed: 1).particles[0]
        #expect(p.position(at: 0).y == 700)
        #expect(p.position(at: 0.15).y < 700)
        #expect(p.position(at: p.life).y > p.position(at: 0.5).y)
        #expect(p.opacity(at: p.life) == 0 && p.opacity(at: p.life / 2) > 0)
    }
}
