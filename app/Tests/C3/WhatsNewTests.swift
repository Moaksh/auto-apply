// WhatsNewTests.swift — the release popover shows once per version after an update, never on a
// fresh install, and Help ▸ What's New reopens it.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · What's new", .serialized)
struct WhatsNewTests {
    private func center(lastSeen: String?) -> WhatsNewCenter {
        let defaults = UserDefaults(suiteName: "whatsnew-\(UUID().uuidString)")!
        if let lastSeen { defaults.set(lastSeen, forKey: WhatsNewCenter.seenKey) }
        let c = WhatsNewCenter()
        c.defaults = defaults
        return c
    }

    @Test func showsOnceAfterAnUpdate() {
        let c = center(lastSeen: "0.1.5")
        c.appear(needsOnboarding: false)
        #expect(c.isPresented)
        c.dismiss()
        #expect(!c.isPresented && c.lastSeen == c.release.version)
        c.appear(needsOnboarding: false)
        #expect(!c.isPresented)  // seen
        c.show()
        #expect(c.isPresented)  // Help ▸ What's New
    }

    @Test func freshInstallsAndOnboardingDontShowIt() {
        let fresh = center(lastSeen: nil)
        fresh.appear(needsOnboarding: true)
        #expect(!fresh.isPresented && fresh.lastSeen == fresh.release.version)
        let onboarding = center(lastSeen: "0.1.4")
        onboarding.appear(needsOnboarding: true)
        #expect(!onboarding.isPresented)
    }

    @Test func pointsAtEasyApply() {
        #expect(WhatsNewRelease.current.anchor == .easyApply && WhatsNewRelease.current.items.count == 3)
    }
}
