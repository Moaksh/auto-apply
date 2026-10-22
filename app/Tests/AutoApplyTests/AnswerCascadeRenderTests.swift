// AnswerCascadeRenderTests.swift — Needs You's 1D pieces render offscreen in light and dark, with
// Reduce Motion on and off: the composer with its monogram row and ghost drafts (stored, AI,
// not grounded, confirming), the flight overlay at launch and at landing, the Pipeline badge
// mid-cascade, and the toast with its draining Undo ring. Answer stays the one primary.
// AUTOAPPLY_SNAPSHOT_DIR=/some/dir writes PNGs for visual review.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Answer cascade render", .serialized)
struct AnswerCascadeRenderTests {
    let outputDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    @discardableResult
    private func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme, @ViewBuilder _ view: () -> V) -> CGImage? {
        let renderer = ImageRenderer(content: view()
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = renderer.cgImage
        if let image, let dir = outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
        return image
    }

    private func makeStore() async -> AppStore {
        let daemon = MockDaemon(scenario: .idle, speed: 1)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.statsDebounce = .milliseconds(1)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && !store.inbox.clusters.isEmpty }
        return store
    }

    private func prominent<V: View>(_ store: AppStore, _ view: () -> V) -> Int {
        let audit = ProminenceAudit()
        let renderer = ImageRenderer(content: view()
            .appEnvironment(store, simulateReduceMotion: true)
            .environment(\.prominenceAudit, audit)
            .frame(width: 900, height: 1100))
        _ = renderer.cgImage
        return audit.count
    }

    @Test func composerWithGhostDraftsAndMonograms() async throws {
        let store = await makeStore()
        let inbox = InboxModel.shared(for: store)
        let why = try #require(store.inbox.clusters.first { $0.clusterId == "c_why" })
        var stored = why
        stored.clusterId = "c_ghost_stored"
        stored.reason = .lowConfidence
        stored.suggestedAnswer = "I have worked remotely for three years and write things down."
        stored.suggestedConfidence = 0.55
        var short = why
        short.clusterId = "c_ghost_short"
        short.fieldType = .text
        short.canonicalQuestion = "Preferred name?"
        short.suggestedAnswer = "Asha"

        func shots(_ name: String, _ cluster: QuestionCluster) {
            for scheme in [ColorScheme.light, .dark] {
                for reduce in [false, true] {
                    #expect(render("ghost-\(name)\(reduce ? "-reduced" : "")", width: 900, height: 1100, scheme: scheme) {
                        AnswerComposer(model: inbox, cluster: cluster, undoManager: nil, embedded: true)
                            .padding(Space.l)
                            .appEnvironment(store, simulateReduceMotion: reduce)
                    } != nil, "\(name) \(scheme) reduce: \(reduce)")
                }
            }
            #expect(prominent(store) { AnswerComposer(model: inbox, cluster: cluster, undoManager: nil, embedded: true) } == 1,
                    "Answer stays the only primary (\(name))")
        }

        #expect(inbox.ghost(for: stored) != nil && inbox.ghost(for: short) != nil)
        shots("stored-long", stored)
        shots("stored-short", short)
        await inbox.draftWithAI(for: why)
        #expect(inbox.ghost(for: why)?.grounded == true)
        shots("ai", why)
        inbox.updateAIDraft(for: why) { $0.instruction = "Add a metric" }
        await inbox.reviseWithAI(for: why)
        #expect(inbox.ghost(for: why)?.grounded == false)
        shots("ungrounded", why)
        #expect(inbox.acceptGhost(for: why) == .needsConfirmation)
        shots("ungrounded-confirming", why)
        #expect(inbox.acceptGhost(for: why) == .accepted)
        shots("taken", why)
        await store.stop()
    }

    @Test func flightBadgeAndToast() async throws {
        let store = await makeStore()
        let inbox = InboxModel.shared(for: store)
        inbox.cascadeLauncher = { _, _ in }   // hold it mid-flight
        let cluster = try #require(store.inbox.clusters.max { $0.jobCount < $1.jobCount })
        #expect(cluster.jobCount >= AnswerCascade.minimumJobs)
        inbox.select(cluster.clusterId)
        inbox.updateDraft(for: cluster) { $0.text = "60 days" }
        if case .choice = inbox.kind(for: cluster) { inbox.updateDraft(for: cluster) { $0.choices = [cluster.options[0]] } }
        if inbox.kind(for: cluster) == .yesNo { inbox.updateDraft(for: cluster) { $0.yesNo = true } }
        inbox.undoWindow = .seconds(30)
        #expect(inbox.submitSelected())
        let cascade = try #require(inbox.cascade)
        let toast = try #require(store.toasts.current)
        #expect(toast.countdown)

        let items: [CascadeFlight.Item] = cascade.flyers.enumerated().map { i, f in
            .init(id: f.id, company: f.company, overflow: 0, from: CGRect(x: 420 + CGFloat(i) * 18, y: 360, width: 22, height: 22), size: 22)
        } + (cascade.overflow > 0 ? [.init(id: Int.min, company: nil, overflow: cascade.overflow,
                                          from: CGRect(x: 580, y: 360, width: 22, height: 22), size: 22)] : [])
        for scheme in [ColorScheme.light, .dark] {
            for reduce in [false, true] {
                let suffix = reduce ? "-reduced" : ""
                for (pose, progress) in [("launch", 0.0), ("midflight", 0.5), ("landed", 1.0)] {
                    #expect(render("cascade-flight-\(pose)\(suffix)", width: 900, height: 560, scheme: scheme) {
                        CascadeFlightView(items: items, target: CGPoint(x: 90, y: 140), progress: progress)
                            .appEnvironment(store, simulateReduceMotion: reduce)
                    } != nil)
                }
                inbox.landCascade(id: cascade.id, jobs: 1)
                #expect(render("cascade-badge\(suffix)", width: 240, height: 40, scheme: scheme) {
                    HStack { Text("Pipeline"); Spacer(); PipelineCascadeBadge(model: inbox) }
                        .padding(.horizontal, Space.m)
                        .appEnvironment(store, simulateReduceMotion: reduce)
                } != nil)
                #expect(render("cascade-toast\(suffix)", width: 520, height: 80, scheme: scheme) {
                    HUDToast(toast: toast) {}
                        .appEnvironment(store, simulateReduceMotion: reduce)
                } != nil)
                #expect(render("cascade-needs-you\(suffix)", width: 1100, height: 720, scheme: scheme) {
                    InboxView().appEnvironment(store, simulateReduceMotion: reduce)
                } != nil)
            }
        }
        #expect(prominent(store) { InboxView() } <= 1, "Needs You mid-cascade")
        #expect(inbox.undo(clusterID: cluster.clusterId))
        #expect(inbox.cascade == nil)
        await store.stop()
    }
}
