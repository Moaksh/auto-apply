// PaletteAndRegistrationTests.swift — ⌘K results/sections/scopes and inline actions, feature
// registration via ScreenRegistry, and offscreen render smoke tests of every C3 screen against
// MockDaemon data (light + dark).
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Command palette", .serialized)
struct PaletteModelTests {
    private func setup() async -> (AppStore, C3StubDaemon, PaletteModel, Box<[URL]>) {
        var data = RepositoryData()
        var stripe = C3Fixtures.job(id: 1, company: "Stripe", title: "Backend Engineer, Payments", state: .submitted)
        stripe.status = .applied
        stripe.submittedAt = Date().addingTimeInterval(-3 * 86_400)
        data.jobs = [stripe, C3Fixtures.job(id: 2, company: "Stripe", title: "Staff Engineer, Infra", state: .skipped, score: 68),
                     C3Fixtures.job(id: 3, company: "Ramp", title: "Platform Engineer")]
        data.stories = MockFixtures.stories(now: C3Fixtures.now)
        let clusters = [C3Fixtures.cluster("np", jobs: [3], question: "Notice period?")]
        let (store, daemon, _) = await makeC3Store(data: data, clusters: clusters)
        let model = PaletteModel(store: store)
        let opened = Box<[URL]>([])
        model.openURL = { opened.value.append($0) }
        return (store, daemon, model, opened)
    }

    @Test func emptyQueryShowsActionsAndNavigation() async {
        let (_, _, model, _) = await setup()
        let sections = Set(model.results.map(\.section))
        #expect(sections.isSuperset(of: [.actions, .navigate, .questions]))
        #expect(!sections.contains(.jobs))
        #expect(model.results.filter { $0.section == .navigate }.count == 9)
    }

    @Test func searchFindsJobsWithTrailingStatus() async throws {
        let (_, _, model, _) = await setup()
        model.query = "stripe"
        let first = try #require(model.results.first)
        #expect(first.section == .jobs)
        let jobs = model.results.filter { $0.section == .jobs }
        #expect(jobs.count == 2)
        let applied = try #require(jobs.first { $0.kind == .job(1) })
        #expect(applied.trailing == "Applied · 3d")
        #expect(jobs.first { $0.kind == .job(2) }?.trailing == "Skipped (68)")
    }

    @Test func scopesRestrictSections() async {
        let (_, _, model, _) = await setup()
        model.query = ">pause"
        #expect(model.results.allSatisfy { $0.section == .actions || $0.section == .navigate })
        #expect(model.results.first?.title == "Pause agent")
        model.query = "@ramp"
        #expect(model.results.map(\.kind) == [.job(3)])
        model.query = "?notice"
        #expect(model.results.map(\.kind) == [.question("np")])
        model.query = "/salary"
        #expect(model.results.first?.kind == .setting(.preferences, "salary_floor"))
        model.query = "/"
        #expect(model.results.count == PaletteModel.limits[.settings])
    }

    @Test func storiesAndSettingsAreSearchable() async {
        let (_, _, model, _) = await setup()
        model.query = "conflict"
        #expect(model.results.contains { if case .story(2) = $0.kind { true } else { false } })
        model.query = "visa"
        #expect(model.results.contains { $0.kind == .setting(.guardrails, "never_guess") })
    }

    @Test func selectionWrapsAndResetsOnQueryChange() async {
        let (_, _, model, _) = await setup()
        let count = model.results.count
        model.moveSelection(by: -1)
        #expect(model.selection == count - 1)
        model.moveSelection(by: 1)
        #expect(model.selection == 0)
        model.moveSelection(by: 2)
        model.query = "x"
        #expect(model.selection == 0)
    }

    @Test func runningItemsNavigates() async throws {
        let (store, daemon, model, opened) = await setup()
        let router = store.router
        router.isPalettePresented = true
        model.query = "ramp platform"
        let job = try #require(model.results.first { $0.kind == .job(3) })
        #expect(await model.run(job, .open))
        #expect(router.selection == .pipeline)
        #expect(router.path == [.job(id: 3)])
        #expect(!router.isPalettePresented)

        router.isPalettePresented = true
        #expect(await model.run(job, .showInPipeline))
        #expect(router.focusedJobID == 3)

        #expect(await model.run(job, .openPosting))
        #expect(opened.value == [URL(string: "https://jobs.example.com/3")!])

        model.query = "?notice"
        #expect(await model.run())
        #expect(router.selection == .needsYou)
        #expect(InboxModel.shared(for: store).selectedClusterID == "np")

        model.query = "/daily limit"
        #expect(await model.run())
        #expect(SettingsNavigation.shared.tab == .schedule)

        model.query = ">run now"
        #expect(await model.run())
        #expect(await c3WaitUntil { daemon.sent("run_now").count == 1 })
    }
}

@MainActor
@Suite("C3 · Registration & rendering", .serialized)
struct C3RegistrationTests {
    @Test func featuresRegisterTheirScreens() {
        let registry = ScreenRegistry()
        registry.discoverFeatures()
        for name in ["InboxFeature", "ReviewFeature", "EasyApplyFeature", "ProfileFeature", "ResumesFeature", "SettingsFeature", "CommandPaletteFeature"] {
            #expect(registry.discoveredFeatures.contains(name), "\(name) not discovered")
        }
        for id in [ScreenID.inbox, .review, .easyApply, .profile, .stories, .resumes, .settings, .commandPalette] {
            #expect(registry.isRegistered(id), "\(id) not registered")
        }
        #expect(registry.hasInspector(for: .resumes))
    }

    @Test(arguments: [MockScenario.idle, .reviewMode, .needsYouStorm])
    func screensRenderOffscreen(scenario: MockScenario) async {
        FeatureModels.reset()
        let daemon = MockDaemon(scenario: scenario, speed: 20)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
        store.start()
        _ = await c3WaitUntil(timeout: .seconds(10)) { store.hasSnapshot && store.jobs.isLoaded && !store.library.resumeVariants.isEmpty }
        let screens: [(String, AnyView)] = [
            ("inbox", AnyView(InboxView())),
            ("review", AnyView(ReviewQueueView())),
            ("easyApply", AnyView(EasyApplyView())),
            ("profile", AnyView(ProfileView())),
            ("stories", AnyView(StoryBankView())),
            ("resumes", AnyView(ResumesView())),
            ("resumeInspector", AnyView(ResumeInspector())),
            ("settings", AnyView(SettingsView())),
            ("palette", AnyView(CommandPaletteView().frame(width: 640))),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, view) in screens {
                let content = view
                    .environment(store)
                    .environment(store.router)
                    .environment(ScreenRegistry.shared)
                    .frame(width: 1100, height: 720)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1
                let image = renderer.cgImage
                #expect(image != nil, "\(name) failed to render (\(scenario.rawValue), \(scheme))")
                // C3_SNAPSHOT_DIR=/some/dir writes PNGs for visual review.
                if let dir = ProcessInfo.processInfo.environment["C3_SNAPSHOT_DIR"], let image {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(scenario.rawValue)-\(name)-\(scheme == .dark ? "dark" : "light").png")
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
        await store.stop()
    }
}
