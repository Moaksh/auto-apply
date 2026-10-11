// UpdaterTests.swift — GitHub release tag vs bundle version ordering.
import Testing
@testable import AutoApply

@MainActor
@Suite("Updater")
struct UpdaterTests {
    @Test func comparesDottedVersions() {
        #expect(Updater.isNewer("v0.1.1", than: "0.1.0"))
        #expect(Updater.isNewer("v0.1.10", than: "0.1.9"))
        #expect(Updater.isNewer("1.0", than: "0.9.9"))
        #expect(!Updater.isNewer("v0.1.0", than: "0.1.0"))
        #expect(!Updater.isNewer("v0.1.0", than: "0.1.1"))
        #expect(Updater.compare("0.2.0-beta", "0.2.0") < 0)
        #expect(Updater.compare("v0.2", "0.2.0") == 0)
    }
}
