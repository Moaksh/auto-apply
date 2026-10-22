// BlankWindowRegressionTests.swift — the main window went completely blank (sidebar and detail)
// on Cold Email ▸ Follow-ups with real data: two submitted applications and sending off. The
// "Sending is off" notice's wrapped text was `.fixedSize(vertical:)` above a ScrollView, so when
// the split view probed a near-zero width it reported a ~2000pt minimum height; AppKit then laid
// the whole NavigationSplitView out taller than the window and off-screen. Hosts the real
// RootView in an offscreen NSWindow (AppKit-drawn, unlike ImageRenderer) with a synthetic dataset.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Blank window regression", .serialized)
struct BlankWindowRegressionTests {
    /// The trigger: submitted applications (Follow-ups shows its list) and sending off (the notice).
    func triggerStore() async -> AppStore {
        var data = RepositoryData()
        data.jobs = [Samples.job(id: 311, state: .submitted, status: .applied, submittedAt: Samples.now),
                     Samples.job(id: 417, state: .submitted, status: .applied, submittedAt: Samples.now)]
        let store = AppStore(client: StubDaemon(), repository: InMemoryRepository(data))
        ScreenRegistry.shared.discoverFeatures()
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.outreach.isLoaded }
        return store
    }

    func pump(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            WindowHost.spin()
            await Task.yield()
        }
    }

    @Test func coldEmailFollowUpsKeepsTheSplitViewInsideTheWindow() async {
        let store = await triggerStore()
        #expect(!store.outreach.sendEnabled)
        ColdEmailModel.shared(for: store).tab = .followUps
        for item in [SidebarItem.coldEmail, .dashboard, .needsYou, .pipeline] {
            let host = WindowHost(store: store)
            store.router.selection = item
            host.show()
            await pump(seconds: 0.6)
            let content = host.window.contentView!
            let split = content.subviews.first
            #expect(split != nil)
            if let split {
                // Blank window: the split view was 2131pt tall at y = -563 in a 900pt window.
                #expect(split.frame.minY >= 0, "\(item): split view starts off-screen at \(split.frame)")
                #expect(split.frame.height <= content.bounds.height + 1, "\(item): split view taller than the window \(split.frame)")
            }
            #expect(!host.snapshot(name: "regression-\(item.rawValue)"), "\(item) rendered blank")
            host.close()
        }
        await store.stop()
    }

    /// The screen itself, without RootView's guard: its minimum height can't depend on how narrow
    /// a width it is probed with.
    @Test func sendingOffNoticeDoesNotInflateTheScreenMinimumHeight() async {
        let store = await triggerStore()
        let model = ColdEmailModel(store: store)
        model.tab = .followUps
        let controller = NSHostingController(rootView: ColdEmailView(modelOverride: model).appEnvironment(store, simulateReduceMotion: true))
        _ = controller.view
        let narrow = controller.sizeThatFits(in: CGSize(width: 1, height: 0))
        #expect(narrow.height < 1000, "Cold Email reports \(narrow.height)pt tall at a 1pt width")
        await store.stop()
    }
}
