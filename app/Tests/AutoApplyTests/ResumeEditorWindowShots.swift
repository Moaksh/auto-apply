// ResumeEditorWindowShots.swift — opt-in visual review of "Edit with Claude": hosts the editor
// (with Claude's suggestions waiting) and the Resumes inspector in an offscreen NSWindow with the
// mock dataset and writes a PNG per surface. Skipped unless AUTOAPPLY_RESUME_SHOTS names a folder.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Resume editor window shots", .serialized)
struct ResumeEditorWindowShots {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["AUTOAPPLY_RESUME_SHOTS"]

    func shoot<V: View>(_ name: String, store: AppStore, scheme: ColorScheme, width: CGFloat, height: CGFloat,
                        @ViewBuilder _ view: () -> V) async {
        let root = view()
            .appEnvironment(store, simulateReduceMotion: true)
            .environment(\.colorScheme, scheme)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        let end = Date().addingTimeInterval(0.8)
        while Date() < end {
            WindowHost.spin()
            await Task.yield()
        }
        if let dir = Self.outDir, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        window.orderOut(nil)
        window.close()
    }

    @Test(.enabled(if: outDir != nil)) func shots() async throws {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: MockScenario.idle.rawValue)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && !store.library.resumeVariants.isEmpty }
        // AUTOAPPLY_RESUME_SHOTS_PDF: a real PDF for the preview pane (the fixtures' path doesn't exist).
        if let pdf = ProcessInfo.processInfo.environment["AUTOAPPLY_RESUME_SHOTS_PDF"] {
            daemon.repository.update { data in
                if let i = data.resumeVariants.firstIndex(where: { $0.id == 1 }) { data.resumeVariants[i].filePath = pdf }
            }
            _ = await waitUntil { store.library.resume(id: 1)?.filePath == pdf }
        }
        let model = ResumeEditorModel(store: store, variantID: 1)
        await model.load()
        model.input = "Tighten every bullet and add a metric"
        await model.send()
        if let first = model.pending.first(where: { $0.unsupportedClaims.isEmpty }) { model.accept(first) }
        for scheme in [ColorScheme.light, .dark] {
            await shoot("resume-editor", store: store, scheme: scheme, width: 1520, height: 900) {
                ResumeEditorView(model: model, onClose: {})
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            await shoot("whats-new", store: store, scheme: scheme, width: 380, height: 560) {
                WhatsNewPopover(center: WhatsNewCenter.shared) {}
            }
        }
        await shoot("secrets-locked", store: store, scheme: .light, width: 680, height: 120) {
            VStack(alignment: .leading, spacing: Space.l) { SecretsSettingsRow() }.padding(Space.l)
        }
        let found = EasterEggs.discoveries
        EasterEggs.discoveries = EasterEggs.Discoveries(found: Set(EasterEggs.Flavor.allCases))
        SecretRewards.shared.refresh()
        AccentTheme.shared.set(AccentChoice(hue: 0.82, vibrance: 0.9), persist: false)
        defer {
            EasterEggs.discoveries = found
            SecretRewards.shared.refresh()
            AccentTheme.shared.set(nil, persist: false)
        }
        for scheme in [ColorScheme.light, .dark] {
            await shoot("accent-pad", store: store, scheme: scheme, width: 680, height: 420) {
                VStack(alignment: .leading, spacing: Space.l) { SecretsSettingsRow() }.padding(Space.l)
            }
        }
        await shoot("hero-tones", store: store, scheme: .dark, width: 600, height: 200) {
            LinearGradient(colors: BrandMesh.colors(at: 0), startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 0) {
                        ForEach(AccentTheme.toneHexes, id: \.self) { AccentTheme.shared.tone($0).frame(height: 40) }
                    }
                }
        }
        if let dir = Self.outDir {
            try SecretIcon.draw(pixels: 1024).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("midnight-gold.png"))
        }
        let resumes = ResumesModel.shared(for: store)
        resumes.selectedID = 1
        await shoot("resume-inspector", store: store, scheme: .light, width: 360, height: 760) {
            ResumeInspector()
        }
    }
}
