// RealDataWindowHarness.swift — opt-in diagnostic: hosts the real RootView in an offscreen
// NSWindow against a copy of a real AutoApply database and snapshots every sidebar screen with
// AppKit's cacheDisplay (draws Lists / ScrollViews, unlike ImageRenderer). Skipped unless
// AUTOAPPLY_REAL_DB points at a database copy; PNGs go to AUTOAPPLY_SNAPSHOT_DIR.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Real-data window harness", .serialized)
struct RealDataWindowHarness {
    nonisolated static let dbPath = ProcessInfo.processInfo.environment["AUTOAPPLY_REAL_DB"]
    nonisolated static let outDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"]

    @Test(.enabled(if: dbPath != nil)) func snapshotEveryScreen() async throws {
        let repo = GRDBRepository(path: Self.dbPath!)
        let env = ProcessInfo.processInfo.environment
        // AUTOAPPLY_HARNESS_SOCKET: talk to a live daemon (read commands only: hello, stats, insights).
        let client: any DaemonConnecting = env["AUTOAPPLY_HARNESS_SOCKET"].map {
            UnixSocketDaemonClient(paths: AppPaths(home: URL(fileURLWithPath: $0, isDirectory: true)))
        } ?? StubDaemon()
        let store = AppStore(client: client, repository: repo)
        ScreenRegistry.shared.discoverFeatures()
        store.start()
        _ = await waitUntil(timeout: .seconds(20)) { store.hasSnapshot && store.jobs.isLoaded && store.outreach.isLoaded }
        print("HARNESS loaded snapshot=\(store.hasSnapshot) jobs=\(store.jobs.isLoaded) \(store.jobs.all.count) outreach=\(store.outreach.isLoaded) replies=\(store.outreach.repliesLoaded) repoErr=\(repo.lastOpenError ?? "-")")

        let only = ProcessInfo.processInfo.environment["AUTOAPPLY_HARNESS_ONLY"]
        let items = SidebarItem.allCases.filter { only == nil || $0.rawValue == only }
        for item in items {
            let window = WindowHost(store: store)
            store.router.selection = item
            window.show()
            await pump(seconds: 2)
            let blank = window.snapshot(name: item.rawValue)
            print("HARNESS \(item.rawValue): \(blank ? "BLANK" : "ok")")
            window.close()
        }
        if ProcessInfo.processInfo.environment["AUTOAPPLY_HARNESS_TABS"] != nil {
            for tab in ColdEmailTab.allCases {
                ColdEmailModel.shared(for: store).tab = tab
                let window = WindowHost(store: store)
                store.router.selection = .coldEmail
                window.show()
                await pump(seconds: 2)
                let blank = window.snapshot(name: "coldEmail-\(tab.rawValue)")
                print("HARNESS coldEmail/\(tab.rawValue): \(blank ? "BLANK" : "ok")")
                window.close()
            }
        }
        if let jobID = env["AUTOAPPLY_HARNESS_JOB"].flatMap(Int.init) {
            let window = WindowHost(store: store)
            store.router.selection = .pipeline
            window.show()
            await pump(seconds: 1)
            for tab in JobDetailTab.allCases {
                store.router.openJob(id: jobID, tab: tab.rawValue)
                await pump(seconds: 1.5)
                let blank = window.snapshot(name: "job-\(jobID)-\(tab.rawValue)")
                print("HARNESS job \(jobID)/\(tab.rawValue): \(blank ? "BLANK" : "ok")")
            }
            store.router.selection = .dashboard
            await pump(seconds: 1)
            store.router.showInsights()
            await pump(seconds: 3)
            print("HARNESS path=\(store.router.path)")
            print("HARNESS insights: \(window.snapshot(name: "insights") ? "BLANK" : "ok")")
            window.close()
        }
        await store.stop()
    }

    func pump(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            WindowHost.spin()
            await Task.yield()
        }
    }
}

@MainActor
final class WindowHost {
    let window: NSWindow

    /// Turn the main run loop briefly so AppKit / SwiftUI lay out and draw.
    static func spin() { _ = CFRunLoopRunInMode(.defaultMode, 0.02, false) }

    init(store: AppStore) {
        let root = RootView()
            .appEnvironment(store, simulateReduceMotion: true)
            .frame(width: 1400, height: 900)
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
    }

    func show() { window.orderBack(nil) }
    func close() { window.orderOut(nil); window.close() }

    /// Writes a PNG; returns true when the content looks blank (almost all one colour).
    func snapshot(name: String) -> Bool {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return true }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let dir = RealDataWindowHarness.outDir, let data = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        var colors = Set<UInt32>()
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for y in stride(from: 0, to: h, by: 17) {
            for x in stride(from: 0, to: w, by: 13) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
        }
        return colors.count < 8
    }
}

