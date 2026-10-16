// QuickFillTests.swift — quick-fill suggestion filtering and profile-aware ordering.
import Testing
@testable import AutoApply

@Suite("QuickFill")
struct QuickFillTests {
    @Test func filterSkipsChosenAndRanksPrefixFirst() {
        let s = ["Backend Engineer", "Data Engineer", "Engineering Manager", "AI Engineer"]
        #expect(QuickFillLists.filter(s, query: "", excluding: ["ai engineer"]) == ["Backend Engineer", "Data Engineer", "Engineering Manager"])
        #expect(QuickFillLists.filter(s, query: "eng", excluding: []).first == "Engineering Manager")
        #expect(QuickFillLists.filter(s, query: "eng", excluding: []).count == 4)
        #expect(QuickFillLists.filter(s, query: "zzz", excluding: []).isEmpty)
    }

    @Test func returnPicksTopMatchOnlyWhenTyping() {
        #expect(ChipField.pick(draft: "back", matches: ["Backend Engineer"]) == "Backend Engineer")
        #expect(ChipField.pick(draft: "Rust wizard", matches: []) == nil)
        #expect(ChipField.pick(draft: "a, b", matches: ["Alpha"]) == nil)
    }

    @Test func rolesPutProfileFamilyFirst() {
        var p = Profile()
        p.headline = "AI Engineer building LLM agents"
        let roles = QuickFillLists.roles(for: p)
        #expect(roles.first == "AI Engineer")
        #expect(roles.firstIndex(of: "LLM Engineer")! < roles.firstIndex(of: "iOS Engineer")!)
        #expect(Set(roles).count == roles.count)
    }

    @Test func locationsStartWithRemoteAndHome() {
        var p = Profile()
        p.location = "Bengaluru, Karnataka, India"
        let locs = QuickFillLists.locations(for: p)
        #expect(Array(locs.prefix(3)) == ["Remote", "Bengaluru", "India"])
        #expect(locs.contains("Hyderabad"))
    }

    @Test func countriesHomeFirstAndSearchable() {
        var p = Profile()
        p.location = "Berlin, Germany"
        let list = QuickFillLists.countries(for: p, excluding: ["IN"])
        #expect(list.first?.code == "DE")
        #expect(!list.contains { $0.code == "IN" })
        #expect(QuickFillLists.searchCountries("gb", in: list).first?.code == "GB")
        #expect(QuickFillLists.searchCountries("king", in: list).first?.name == "United Kingdom")
        #expect(QuickFillLists.countryName("usa") == "United States")
    }
}
