// ColdEmailWindowShots.swift — opt-in visual review: hosts the Cold Email screen in an offscreen
// NSWindow (AppKit's cacheDisplay draws ScrollViews and Lists, unlike ImageRenderer) with the mock
// dataset and writes a PNG per surface. Skipped unless AUTOAPPLY_COLDEMAIL_SHOTS names a folder.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Cold Email window shots", .serialized)
struct ColdEmailWindowShots {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["AUTOAPPLY_COLDEMAIL_SHOTS"]

    func mockStore() async -> AppStore {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: MockScenario.idle.rawValue)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.outreach.isLoaded && store.outreach.repliesLoaded }
        return store
    }

    func emptyStore() async -> AppStore {
        var data = RepositoryData()
        data.jobs = [Samples.job(id: 1, state: .queued)]
        let store = AppStore(client: StubDaemon(), repository: InMemoryRepository(data))
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.outreach.isLoaded }
        return store
    }

    func shoot<V: View>(_ name: String, store: AppStore, scheme: ColorScheme = .light, width: CGFloat = 1200, height: CGFloat = 800,
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

    @Test(.enabled(if: outDir != nil)) func everySurface() async {
        let store = await mockStore()
        let o = store.outreach
        for scheme in [ColorScheme.light, .dark] {
            for tab in ColdEmailTab.allCases {
                let model = ColdEmailModel(store: store)
                model.tab = tab
                if tab == .outbox { model.ensureFocus() }
                await shoot("tab-\(tab.rawValue)", store: store, scheme: scheme) { ColdEmailView(modelOverride: model) }
            }
            let refer = ColdEmailModel(store: store)
            refer.showPeople(.couldRefer)
            await shoot("people-could-refer", store: store, scheme: scheme) { ColdEmailView(modelOverride: refer) }
        }
        // Up next, focused on each kind of item.
        let focused: [(String, (ColdEmailModel) -> Void)] = [
            ("draft-ticked", { m in m.selectAllDrafts(); m.focus(o.drafts.first?.id) }),
            ("draft-claim", { m in m.focus(o.drafts.first(where: \.needsClaimsFix)?.id) }),
            ("reply", { m in m.focus(o.replyThreads.first.flatMap { o.latestReply(threadID: $0.id)?.id }) }),
            ("applied-no-note", { m in if let j = m.jobsAwaitingNote.first { m.focusJob(j.id) } }),
            ("possibly-sent", { m in m.focus(o.unknownSends.first?.id) }),
        ]
        for (name, setup) in focused {
            let model = ColdEmailModel(store: store)
            setup(model)
            await shoot("upnext-\(name)", store: store) { ColdEmailView(modelOverride: model) }
        }
        let model = ColdEmailModel(store: store)
        model.selectAllDrafts()
        model.beginSend()
        await model.approveSelected()
        await shoot("send-sheet", store: store, width: 560, height: 820) { SendConfirmSheet(model: model) }
        (store.repository as? InMemoryRepository)?.update { $0.outreach.mailAccount.sendEnabled = false }
        _ = await waitUntil { !store.outreach.sendEnabled }
        let off = ColdEmailModel(store: store)
        off.ensureFocus()
        await shoot("sending-off-outbox", store: store) { ColdEmailView(modelOverride: off) }
        await store.stop()
        let empty = await emptyStore()
        for tab in ColdEmailTab.allCases {
            let m = ColdEmailModel(store: empty)
            m.tab = tab
            await shoot("empty-\(tab.rawValue)", store: empty) { ColdEmailView(modelOverride: m) }
        }
        let emptyRefer = ColdEmailModel(store: empty)
        emptyRefer.showPeople(.couldRefer)
        await shoot("empty-could-refer", store: empty) { ColdEmailView(modelOverride: emptyRefer) }
        await empty.stop()
    }
}
