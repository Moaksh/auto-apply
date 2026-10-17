// EasterEggsTests.swift — the Konami matcher and secret palette phrases.
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
}
