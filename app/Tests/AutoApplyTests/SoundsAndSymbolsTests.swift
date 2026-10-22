// SoundsAndSymbolsTests.swift — 1G/1J: the "Moments only" sound levels, migration from the old
// "Play sounds" toggle, and a render smoke test for the custom aa.* symbols.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@Suite("Sounds")
struct SoundsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "SoundsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func levelMapping() {
        // Moments only: the moments, never routine.
        #expect(Sounds.shouldPlay(.celebrate, at: .moments))
        for cue in [Sounds.Cue.tap, .pop, .send] { #expect(!Sounds.shouldPlay(cue, at: .moments)) }
        // All: everything except the retired failure sound.
        for cue in [Sounds.Cue.tap, .pop, .send, .celebrate] { #expect(Sounds.shouldPlay(cue, at: .all)) }
        // Off: nothing. Failure never makes a sound at any level.
        for cue in Sounds.Cue.allCases { #expect(!Sounds.shouldPlay(cue, at: .off)) }
        for level in Sounds.Level.allCases { #expect(!Sounds.shouldPlay(.denied, at: level)) }
    }

    @Test func defaultIsMomentsOnly() {
        #expect(Sounds.level(in: freshDefaults()) == .moments)
        #expect(Sounds.defaultLevel == .moments)
    }

    @Test func migratesFromOldToggle() {
        let off = freshDefaults()
        off.set(false, forKey: Sounds.legacyEnabledKey)
        #expect(Sounds.level(in: off) == .off)  // turned sounds off → stays off

        let on = freshDefaults()
        on.set(true, forKey: Sounds.legacyEnabledKey)
        #expect(Sounds.level(in: on) == .moments)  // the old default on → the new default

        let chosen = freshDefaults()
        chosen.set(false, forKey: Sounds.legacyEnabledKey)
        chosen.set(Sounds.Level.all.rawValue, forKey: Sounds.levelKey)
        #expect(Sounds.level(in: chosen) == .all)  // a saved level wins over the old toggle

        let junk = freshDefaults()
        junk.set("loud", forKey: Sounds.levelKey)
        #expect(Sounds.level(in: junk) == .moments)
    }

    @Test func levelTitles() {
        #expect(Sounds.Level.allCases.map(\.title) == ["Off", "Moments only", "All"])
    }
}

@MainActor
@Suite("Custom symbols")
struct AASymbolTests {
    @Test func everySymbolHasInkInsideItsFrame() {
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        for symbol in AASymbol.allCases {
            let path = symbol.shape(progress: 0.6).path(in: rect)
            #expect(!path.isEmpty, "\(symbol.rawValue) is empty")
            let box = path.boundingRect
            #expect(box.width > 32 && box.height > 32, "\(symbol.rawValue) too small: \(box)")
            #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(box), "\(symbol.rawValue) spills out: \(box)")
        }
    }

    @Test func trailDrawsWithProgress() {
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let empty = AAPlaneTrailShape(progress: 0).path(in: rect).boundingRect
        let full = AAPlaneTrailShape(progress: 1).path(in: rect).boundingRect
        #expect(full.minX < empty.minX - 10 && full.maxY > empty.maxY + 10)
    }

    @Test func symbolsRender() {
        let outputDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for scheme in [ColorScheme.light, .dark] {
            let view = HStack(spacing: 16) {
                ForEach(AASymbol.allCases, id: \.self) { AASymbolView($0, size: 32, progress: 0.7) }
                AASymbolView(.planeFill, size: 16)
                AASymbolView(.plane, size: 16)
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(16)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = renderer.cgImage
            #expect(image != nil)
            if let image, let dir = outputDir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try? data?.write(to: dir.appendingPathComponent("aa-symbols-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        // Template images for AppKit hosts (menu bar).
        for symbol in AASymbol.allCases {
            let image = AASymbol.image(symbol, pointSize: 18)
            #expect(image.isTemplate && image.size == NSSize(width: 18, height: 18))
            #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        }
    }
}
