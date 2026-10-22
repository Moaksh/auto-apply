// SampleModeTests.swift — "Explore with sample data" (DESIGN_AWARD_VISION 1I): the sample
// dataset, choosing sample mode (backend swap + persistence across relaunch), "Set up for real"
// (back to onboarding on the live backend, sample values cleared), live-only command guards, and
// render checks for the welcome link and the toolbar chip's card.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Sample mode", .serialized)
struct SampleModeTests {
    func isolatedDefaults() -> UserDefaults {
        let name = "SampleModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A store on the fresh-install mock (what the welcome screen sees before setup).
    func makeOnboardingStore() async -> AppStore {
        let daemon = MockDaemon(scenario: .onboarding, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository)
        store.start()
        _ = await waitUntil { store.isConnected && store.hasSnapshot }
        return store
    }

    /// Stand-in for the live agent in tests: a fresh install, reported as live (no mock name).
    static func fakeLive(_ store: AppStore) async {
        let daemon = MockDaemon(scenario: .onboarding, speed: 50)
        await store.replaceBackend(client: daemon, repository: daemon.repository, mockScenarioName: nil)
    }

    // MARK: Data

    @Test func sampleDataIsABelievableIndianJobHunt() {
        let setup = MockScenario.sample.makeSetup()
        let data = setup.data
        #expect(data.profile.fullName == "Asha Rao")
        #expect(data.profile.location == "Bengaluru, India")
        #expect(data.neverGuess.workAuth["IN"] == "citizen")
        #expect(setup.state.preferences.mode == .review)
        #expect(setup.state.usesSamplePool)
        // Only Indian employers and cities.
        let allowed = Set(MockSample.discoveryPool.map(\.name))
        #expect(data.jobs.allSatisfy { allowed.contains($0.company) }, "\(Set(data.jobs.map(\.company)).subtracting(allowed))")
        #expect(data.jobs.allSatisfy { ($0.location ?? "").contains("India") || ($0.location ?? "").contains("·") })
        // The person's own answers everywhere, never the baseline persona.
        let answers = data.applicationAnswers.values.flatMap { $0 }
        #expect(!answers.isEmpty)
        #expect(!answers.contains { $0.answer.contains("Moaksh") })
        #expect(answers.contains { $0.answer == "Asha Rao" })
        #expect(answers.filter { $0.question == "Requires sponsorship?" }.allSatisfy { $0.answer == "No" })
        #expect(!data.activity.contains { $0.message.contains("stripe/") })
        // Replies, cold email and something to prepare an interview for.
        #expect(!data.applicationReplies.isEmpty)
        #expect(!data.outreach.threads.isEmpty)
        #expect(data.outreach.threads.allSatisfy { allowed.contains($0.company) })
        #expect(data.jobs.contains { $0.status == .interview })
        #expect(data.jobs.filter { $0.state == .awaitingReview }.count >= 2)
        #expect(!MockScenario.sample.script.isEmpty)
    }

    @Test func otherScenariosKeepTheirPersona() {
        let answers = MockScenario.idle.makeSetup().data.applicationAnswers.values.flatMap { $0 }
        #expect(answers.contains { $0.answer == "Moaksh Kakkar" })
        #expect(answers.contains { $0.question == "Requires sponsorship?" && $0.answer == "Yes" })
    }

    @Test func theAgentVisiblyWorksInSampleMode() async {
        let (client, repository) = AppBootstrap.makeMockBackend(.sample, speed: 40)
        let store = AppStore(client: client, repository: repository, mockScenarioName: MockScenario.sample.rawValue)
        store.start()
        _ = await waitUntil { store.isConnected && store.jobs.isLoaded }
        let before = store.jobs.all.count
        let reviewBefore = store.jobs.count(.awaitingReview)
        #expect(await waitUntil(timeout: .seconds(10)) { store.jobs.count(.awaitingReview) >= reviewBefore + 2 && store.inbox.openCount > 0 })
        #expect(store.jobs.all.count >= before + 8)
        let found = store.jobs.all.filter { $0.id > 10_000 }
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { MockSample.discoveryPool.map(\.name).contains($0.company) })
        // Answers recorded by the run belong to the sample persona.
        let filled = found.filter { $0.state == .awaitingReview }.compactMap(\.applicationID)
        let recorded = repository.read { data in filled.flatMap { data.applicationAnswers[$0] ?? [] } }
        #expect(recorded.contains { $0.answer == "Asha Rao" })
        await store.stop()
    }

    // MARK: Choosing sample mode

    @Test func choosingSampleModeSwitchesBackendAndPersists() async {
        let defaults = isolatedDefaults()
        let store = await makeOnboardingStore()
        #expect(store.needsOnboarding)
        #expect(!SampleMode.isActive(store))

        await SampleMode.enter(store: store, defaults: defaults, speed: 50)
        #expect(SampleMode.isActive(store))
        #expect(store.client is SampleModeClient)
        #expect(SampleMode.isPersisted(defaults))
        #expect(store.router.selection == .dashboard)
        #expect(await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.library.profile.fullName == "Asha Rao" })
        #expect(!store.needsOnboarding)
        #expect(!OnboardingGate.shouldPresent(store: store))

        // Relaunch: the app comes back in sample mode, on the guarded mock (never the socket or DB).
        let relaunched = AppBootstrap.makeStore(environment: [:], defaults: defaults)
        #expect(SampleMode.isActive(relaunched))
        #expect(relaunched.client is SampleModeClient)
        #expect(relaunched.repository is InMemoryRepository)
        await store.stop()
    }

    @Test func setUpForRealReturnsToOnboardingOnTheLiveBackend() async {
        let defaults = isolatedDefaults()
        let store = await makeOnboardingStore()
        await SampleMode.enter(store: store, defaults: defaults, speed: 50)
        _ = await waitUntil { store.hasSnapshot && store.library.profile.fullName == "Asha Rao" }

        await SampleMode.exit(store: store, defaults: defaults, goLive: Self.fakeLive)
        #expect(!SampleMode.isPersisted(defaults))
        #expect(!SampleMode.isActive(store))
        #expect(store.mockScenarioName == nil, "live backend")
        #expect(!(store.client is SampleModeClient))
        // Nothing sample-made carries into the real setup.
        #expect(store.library.profile.fullName == nil)
        #expect(store.preferences.roles.isEmpty)
        #expect(store.library.stories.isEmpty)
        #expect(await waitUntil { store.hasSnapshot && store.isConnected })
        #expect(store.needsOnboarding)
        #expect(OnboardingGate.shouldPresent(store: store))
        let model = OnboardingModel(store: store, checker: FakeChecker(items: []), defaults: defaults)
        model.load()
        #expect(model.step == .ignition, "onboarding starts from the welcome screen")
        #expect(model.profileDraft.fullName == nil)
        await store.stop()
    }

    @Test func debugSwitchToAnotherBackendEndsSampleMode() async {
        let defaults = isolatedDefaults()
        let store = await makeOnboardingStore()
        await SampleMode.enter(store: store, defaults: defaults, speed: 50)
        await AppBootstrap.switchToMock(.idle, speed: 50, store: store, defaults: defaults)
        #expect(!SampleMode.isPersisted(defaults))
        #expect(!(store.client is SampleModeClient))
        await AppBootstrap.switchToMock(.sample, speed: 50, store: store, defaults: defaults)
        #expect(store.client is SampleModeClient, "the Debug menu's sample scenario is guarded too")
        await store.stop()
    }

    // MARK: Live-only guards

    @Test func liveOnlyCommandsAreRefusedWithAClearMessage() {
        let blocked: [Command] = [
            .openAgentChrome(OpenAgentChromePayload()),
            .onboardingConnectSource(OnboardingConnectSourcePayload(source: .linkedin)),
            .checkSourceLogin(CheckSourceLoginPayload(source: .linkedin)),
            .revealSiteAccountPassword(RevealSiteAccountPasswordPayload(host: "acme.example.com")),
            .setMailAccount(SetMailAccountPayload(email: "a@b.c", appPassword: "x")),
            .clearMailAccount(ClearMailAccountPayload()),
            .deleteSiteAccount(DeleteSiteAccountPayload(host: "acme.example.com")),
            .setProviderKey(SetProviderKeyPayload(provider: .hunter, apiKey: "k")),
        ]
        for command in blocked {
            #expect(SampleMode.blockedMessage(for: command) != nil, "\(command.type)")
        }
        #expect(SampleMode.blockedMessage(for: .pauseAll(PauseAllPayload())) == nil)
        #expect(SampleMode.blockedMessage(for: .runNow(RunNowPayload())) == nil)
    }

    @Test func liveOnlyActionsShowTheMessageInSampleMode() async {
        let (client, repository) = AppBootstrap.makeMockBackend(.sample, speed: 50)
        let store = AppStore(client: client, repository: repository, mockScenarioName: MockScenario.sample.rawValue)
        store.start()
        _ = await waitUntil { store.isConnected && store.hasSnapshot }

        await store.openAgentChrome()
        guard case .daemon(let payload)? = store.lastCommandError else {
            Issue.record("openAgentChrome wasn't refused")
            return
        }
        #expect(payload.code == .unavailable)
        #expect(payload.message.contains("sample data"))
        #expect(store.toasts.current?.message == payload.message)

        #expect(await store.revealSiteAccountPassword(host: "acme.wd5.myworkdayjobs.com") == nil, "no password from sample mode")
        #expect(store.lastCommandError != nil)

        // Everything else still works against the sample agent.
        let result = await store.perform(.pauseAll(PauseAllPayload()), silent: true)
        if case .failure(let error) = result { Issue.record("pause_all was refused: \(error)") }
        #expect(store.lastCommandError == nil)
        await store.stop()
    }

    // MARK: Rendering

    /// Renders offscreen; with AUTOAPPLY_SNAPSHOT_DIR set, also writes `<name>-<scheme>.png` there.
    private func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme = .light,
                                 audit: ProminenceAudit? = nil, @ViewBuilder _ view: () -> V) -> CGImage? {
        let content = view()
            .environment(\.prominenceAudit, audit)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.cgImage
        if let image, let dir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        return image
    }

    @Test func welcomeOffersSampleDataWithOnePrimary() {
        let audit = ProminenceAudit()
        let image = render("sample-welcome", width: 880, height: 620, audit: audit) {
            IgnitionView(onGetStarted: {}, onExploreSample: {}).environment(\.motionReduced, true)
        }
        #expect(image != nil)
        #expect(audit.count == 1, "Get started stays the one primary; sample data is a link")
    }

    @Test func sampleChipAndCardRender() async {
        let (client, repository) = AppBootstrap.makeMockBackend(.sample, speed: 1)
        let store = AppStore(client: client, repository: repository, mockScenarioName: MockScenario.sample.rawValue)
        for scheme in [ColorScheme.light, .dark] {
            let audit = ProminenceAudit()
            let card = render("sample-card", width: 340, height: 200, scheme: scheme, audit: audit) {
                SampleDataCard {}.appEnvironment(store, simulateReduceMotion: true)
            }
            #expect(card != nil)
            #expect(audit.count == 1, "Set up for real is the card's one primary")
            #expect(render("sample-chip", width: 160, height: 32, scheme: scheme) { SampleDataChip() } != nil)
        }
        #expect(SampleDataCard.message.contains("Keychain"))
    }

    @Test func sampleDashboardHasAtMostOnePrimary() async {
        let (client, repository) = AppBootstrap.makeMockBackend(.sample, speed: 1)
        let store = AppStore(client: client, repository: repository, mockScenarioName: MockScenario.sample.rawValue)
        store.statsDebounce = .milliseconds(1)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.isConnected }
        store.recomputeStats()
        let audit = ProminenceAudit()
        let image = render("sample-dashboard", width: 1200, height: 1500, audit: audit) {
            DashboardView().appEnvironment(store, simulateReduceMotion: true)
        }
        #expect(image != nil)
        #expect(audit.count <= 1)
        await store.stop()
    }
}
