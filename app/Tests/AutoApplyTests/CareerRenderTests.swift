// CareerRenderTests.swift — renders What's working (loaded, loading, failed, empty sections),
// the Dashboard with its What's working card, Job detail ▸ Interview prep (no pack, a pack with
// stories and gaps, a grounded and an ungrounded debrief), the requirements table, the LinkedIn
// import sheet (instructions, failure, result) and Settings ▸ Outreach with the writing voice,
// offscreen in light and dark. Asserts an image; AUTOAPPLY_SNAPSHOT_DIR writes PNGs for review.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Career render", .serialized)
struct CareerRenderTests {
    let outputDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    static let schemes: [ColorScheme] = [.light, .dark]

    func check<V: View>(_ name: String, store: AppStore, width: CGFloat = 1100, height: CGFloat = 900, scheme: ColorScheme,
                        @ViewBuilder _ view: () -> V) async {
        let content = view()
            .appEnvironment(store, simulateReduceMotion: true)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = renderer.cgImage
        #expect(image != nil, "\(name)")
        if let image, let dir = outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("career-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        await Task.yield()
    }

    func mockStore() async -> AppStore {
        FeatureModels.reset()
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.statsDebounce = .milliseconds(1)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.outreach.isLoaded }
        store.recomputeStats()
        return store
    }

    @Test func insightsStates() async {
        let store = await mockStore()
        let loaded = InsightsModel(store: store)
        loaded.show(CareerFixtures.insights(summary: "Kubernetes keeps coming up."))
        let mock = InsightsModel(store: store)
        await mock.load()
        #expect(mock.phase == .loaded)
        var sparse = CareerFixtures.insights()
        sparse.skipBlockers = SkipBlockers(windowDays: 30)
        sparse.upskill.hints = []
        sparse.variants = VariantInsights(finding: "Not enough data yet.")
        let empty = InsightsModel(store: store)
        empty.show(sparse)
        for scheme in Self.schemes {
            await check("insights", store: store, scheme: scheme) { InsightsView(modelOverride: loaded) }
            await check("insights-mock", store: store, scheme: scheme) { InsightsView(modelOverride: mock) }
            await check("insights-sparse", store: store, scheme: scheme) { InsightsView(modelOverride: empty) }
            await check("insights-loading", store: store, scheme: scheme) { InsightsView(modelOverride: InsightsModel(store: store)) }
            await check("dashboard", store: store, height: 1700, scheme: scheme) { DashboardView() }
        }
        await store.stop()
    }

    @Test func insightsFailedState() async {
        FeatureModels.reset()
        let daemon = StubDaemon()
        daemon.responder = { _ in .error(ErrorPayload(code: .internal, message: "database is locked")) }
        let store = AppStore(client: daemon, repository: InMemoryRepository(CareerFixtures.data()))
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded }
        let model = InsightsModel(store: store)
        await model.load()
        for scheme in Self.schemes {
            await check("insights-failed", store: store, scheme: scheme) { InsightsView(modelOverride: model) }
        }
        await store.stop()
    }

    @Test func interviewPrepStates() async throws {
        let store = await mockStore()
        let job = try #require(store.jobs.all.first { $0.state == .submitted && $0.applicationID != nil })
        let id = try #require(job.applicationID)
        let model = InterviewPrepModel(store: store)
        await model.load(applicationID: id, force: true)
        if model.pack(id) == nil {
            for scheme in Self.schemes {
                await check("prep-empty", store: store, width: 760, height: 900, scheme: scheme) { InterviewPrepPane(job: job, model: model) }
            }
        }
        await model.generate(applicationID: id, force: true)
        #expect(model.pack(id) != nil)
        model.notes[id] = "It went fine."
        await model.debrief(applicationID: id)
        #expect(model.latestDebrief(id)?.thankYou.grounded == false)
        for scheme in Self.schemes {
            await check("prep-pack-ungrounded", store: store, width: 760, height: 2200, scheme: scheme) { ScrollView { InterviewPrepPane(job: job, model: model) } }
        }
        model.notes[id] = "Spoke with Priya about payments."
        await model.debrief(applicationID: id)
        for scheme in Self.schemes {
            await check("prep-pack", store: store, width: 760, height: 2200, scheme: scheme) { InterviewPrepPane(job: job, model: model) }
            await check("job-detail", store: store, scheme: scheme) { JobDetailView(jobID: job.id) }
        }
        await store.stop()
    }

    @Test func requirementsTable() async throws {
        let store = await mockStore()
        let reqs = MockCareer.requirements(title: "Platform Engineer", score: 74, seed: 3)
        #expect(reqs.contains { $0.dealbreaker && $0.jdQuote != nil })
        #expect(reqs.contains { $0.status == .missing })
        var job = Samples.job(id: 1, state: .scored)
        job.score = 74
        job.scoreFactors = ["skills": 80, "seniority": 70]
        job.scoreRequirements = reqs
        job.scoreGrounding = ScoreGrounding(evidenceDropped: 1)
        var old = job
        old.scoreRequirements = nil
        old.scoreGrounding = nil
        for scheme in Self.schemes {
            await check("match-requirements", store: store, width: 300, height: 760, scheme: scheme) { MatchBreakdown(job: job, threshold: 70) }
            await check("match-old-score", store: store, width: 300, height: 300, scheme: scheme) { MatchBreakdown(job: old, threshold: 70) }
        }
        await store.stop()
    }

    @Test func linkedInImportSheetStates() async {
        let store = await mockStore()
        let model = ColdEmailModel(store: store)
        let result = LinkedInImportResult(imported: 312, merged: 4, skipped: 2,
                                          matchedCompanies: [.init(companyId: 1, name: "Stripe", why: "You applied", connections: 3)],
                                          referralSuggestions: 3)
        let states: [(String, LinkedInImportState)] = [("idle", .idle), ("importing", .importing),
                                                       ("failed", .failed("That doesn't look like Connections.csv")), ("done", .done(result)),
                                                       ("done-none", .done(LinkedInImportResult(imported: 2, merged: 0, skipped: 0, matchedCompanies: [], referralSuggestions: 0)))]
        for (name, state) in states {
            model.linkedInImport = state
            for scheme in Self.schemes {
                await check("linkedin-\(name)", store: store, width: 520, height: 560, scheme: scheme) { LinkedInImportSheet(model: model) }
            }
        }
        let contacts = ColdEmailModel(store: store)
        contacts.tab = .people
        for scheme in Self.schemes {
            await check("coldemail-contacts", store: store, width: 1200, height: 700, scheme: scheme) { ColdEmailView(modelOverride: contacts) }
        }
        await store.stop()
    }

    @Test func writingVoiceSection() async {
        let store = await mockStore()
        let voice = VoiceProfileModel.shared(for: store)
        await voice.load()
        #expect(voice.phase == .loaded)
        voice.draft.avoidPhrases = ["I hope this finds you well", "delve"]
        voice.draft.maxWords = 20
        for scheme in Self.schemes {
            await check("settings-outreach-voice", store: store, width: 680, height: 1900, scheme: scheme) {
                ScrollView { VStack(alignment: .leading, spacing: Space.l) { OutreachSettingsTab(model: SettingsModel(store: store)) } }
            }
        }
        await store.stop()
    }
}
