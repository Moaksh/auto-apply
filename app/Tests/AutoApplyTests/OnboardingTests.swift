// OnboardingTests.swift — the onboarding flow against MockDaemon with a fake local checker:
// system-check merge, every step's command, persistence, and completion.
import Foundation
import Testing
@testable import AutoApply

struct FakeChecker: SystemChecking {
    var items: [SystemCheckItem]
    func checkLocalTools() async -> [SystemCheckItem] { items }
}

@MainActor
@Suite("Onboarding", .serialized)
struct OnboardingTests {
    func makeModel(localOK: Bool = true) async -> (OnboardingModel, AppStore, MockDaemon) {
        UserDefaults.standard.removeObject(forKey: OnboardingModel.stepDefaultsKey)
        let daemon = MockDaemon(scenario: .onboarding, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository)
        store.commandTimeout = .seconds(2)
        store.start()
        _ = await waitUntil { store.isConnected && store.hasSnapshot }
        let checker = FakeChecker(items: [
            SystemCheckItem(name: .claudeCli, ok: localOK, required: true, version: "2.4.1", detail: localOK ? "found" : "not found",
                            fixCommand: localOK ? nil : "npm install -g @anthropic-ai/claude-code"),
            SystemCheckItem(name: .uv, ok: true, required: true, version: "0.6.2"),
            SystemCheckItem(name: .node, ok: true, required: true, version: "v22.1.0"),
        ])
        let model = OnboardingModel(store: store, checker: checker)
        model.load()
        return (model, store, daemon)
    }

    @Test func resumeSuggestionPrefillsButKeepsEdits() async {
        let (model, _, daemon) = await makeModel()
        model.preferencesDraft.roles = []
        model.preferencesDraft.seniority = []
        model.preferencesDraft.locations = ["Remote"]
        model.profileDraft.yearsExperience = nil
        let first = SuggestedPreferences(roles: ["AI Engineer"], seniority: [.junior, .mid], locations: ["India"], yearsExperience: 2.3)
        model.applySuggestion(first)
        #expect(model.preferencesDraft.roles == ["AI Engineer"])
        #expect(model.preferencesDraft.seniority == [.junior, .mid])
        #expect(model.preferencesDraft.locations == ["Remote"])  // user's own value kept
        #expect(model.profileDraft.yearsExperience == 2.3)
        // A new resume refreshes untouched fields but not ones the user edited.
        model.preferencesDraft.roles = ["ML Engineer"]
        model.applySuggestion(SuggestedPreferences(roles: ["Data Scientist"], seniority: [.mid, .senior], locations: [], yearsExperience: 5))
        #expect(model.preferencesDraft.roles == ["ML Engineer"])
        #expect(model.preferencesDraft.seniority == [.mid, .senior])
        #expect(model.profileDraft.yearsExperience == 5)
        #expect(OnboardingModel.seniority(forYears: 0.5) == [.junior])
        #expect(OnboardingModel.seniority(forYears: 10) == [.senior, .staff])
        _ = daemon
    }

    @Test func storeNeedsOnboardingForFreshInstall() async {
        let (_, store, daemon) = await makeModel()
        #expect(store.needsOnboarding)
        #expect(OnboardingGate.shouldPresent(store: store))
        await store.stop()
        _ = daemon
    }

    @Test func systemCheckMergesLocalAndDaemonResults() async {
        let (model, store, _) = await makeModel()
        model.begin()
        #expect(model.step == .systemCheck)
        await model.runSystemCheck()
        #expect(model.checks.map(\.name) == [.claudeCli, .uv, .node, .autoapplyd, .chrome])
        #expect(model.checks.allSatisfy { $0.state == .done })
        #expect(model.checks.first { $0.name == .autoapplyd }?.item?.ok == true, "daemon-reported")
        #expect(model.canContinue)
        await store.stop()
    }

    @Test func failingRequiredCheckBlocksContinueAndShakes() async {
        let (model, store, _) = await makeModel(localOK: false)
        model.begin()
        await model.runSystemCheck()
        #expect(!model.canContinue)
        let before = model.shakeTrigger
        await model.primaryAction()
        #expect(model.step == .systemCheck)
        #expect(model.shakeTrigger == before + 1)
        #expect(model.validationMessage != nil)
        await store.stop()
    }

    @Test func mergerPrefersDaemonForClaudeLogin() {
        let local = [SystemCheckItem(name: .claudeCli, ok: true, required: true, version: "2.4.1")]
        let daemon = SystemCheckResult(items: [SystemCheckItem(name: .claudeCli, ok: false, required: true, detail: "not logged in", fixCommand: "claude login")],
                                       allRequiredOk: false)
        let merged = SystemCheckMerger.merge(local: local, daemon: daemon, daemonReachable: true)
        #expect(merged.first { $0.name == .claudeCli }?.ok == false)
        #expect(merged.first { $0.name == .claudeCli }?.fixCommand == "claude login")
        let offline = SystemCheckMerger.merge(local: local, daemon: nil, daemonReachable: false)
        #expect(offline.first { $0.name == .autoapplyd }?.ok == false)
    }

    @Test func versionParsing() {
        #expect(LocalSystemChecker.parseVersion("2.4.1 (Claude Code)") == "2.4.1")
        #expect(LocalSystemChecker.parseVersion("uv 0.6.2 (abc 2025-01-01)") == "0.6.2")
        #expect(LocalSystemChecker.parseVersion("v22.11.0") == "v22.11.0")
        #expect(LocalSystemChecker.majorVersion("v18.2.0") == 18)
    }

    @Test func fullFlowSendsEveryCommandAndCompletes() async throws {
        let (model, store, daemon) = await makeModel()
        model.begin()
        await model.runSystemCheck()
        await model.primaryAction()
        #expect(model.step == .resumes)
        #expect(await waitUntil { daemon.world.read { $0.onboarding.step } == 2 }, "onboarding_set_step persisted")

        // Resume upload → parse → profile prefill.
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("Backend-\(UUID().uuidString.prefix(4)).pdf")
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdf)
        model.addResumes([pdf])
        #expect(await waitUntil { model.resumes.first?.status == .parsed })
        #expect(model.profileDraft.fullName == "Moaksh Kakkar")
        #expect(model.uncertainFields.contains("phone"))
        await model.primaryAction()                // → confirm profile
        #expect(model.showProfileConfirm)
        model.profileDraft.headline = "Payments engineer"
        await model.primaryAction()                // save profile → preferences
        #expect(model.step == .preferences)
        #expect(daemon.repository.read { $0.profile.headline } == "Payments engineer")

        // Resume pre-filled the job filters; preferences still require a role.
        #expect(model.preferencesDraft.roles == MockCommandHandler.mockSuggestion.roles)
        model.preferencesDraft.roles = []
        await model.primaryAction()
        #expect(model.step == .preferences)
        model.preferencesDraft.roles = ["Backend Engineer"]
        model.preferencesDraft.seniority = [.senior, .staff]
        model.preferencesDraft.dailyCap = 12
        model.preferencesDraft.matchThreshold = 75
        await model.primaryAction()
        #expect(model.step == .neverGuess)
        #expect(daemon.world.read { $0.preferences.roles } == ["Backend Engineer"])
        #expect(daemon.world.read { $0.preferences.matchThreshold } == 75)
        #expect(store.preferences.dailyCap == 12)

        // Never-guess: blank → null ("always ask me").
        model.neverGuessDraft.noticePeriod = "60 days"
        model.neverGuessDraft.sponsorship = nil
        await model.primaryAction()
        #expect(model.step == .stories)
        #expect(daemon.repository.read { $0.neverGuess.noticePeriod } == "60 days")
        #expect(daemon.repository.read { $0.neverGuess.sponsorship } == nil)

        // Stories: one filled draft is saved.
        model.stories[0].title = "Ledger at scale"
        model.stories[0].result = "12k TPS"
        await model.primaryAction()
        #expect(model.step == .sources)
        #expect(daemon.repository.read { d in d.stories.contains { $0.title == "Ledger at scale" } })

        // Sources: career URL validation, LinkedIn connect flips via source_status.
        model.careerURLDraft = "not a url"
        model.addCareerURL()
        #expect(model.careerURLs.isEmpty)
        model.careerURLDraft = "stripe.com/jobs"
        model.addCareerURL()
        #expect(model.careerURLs == ["https://stripe.com/jobs"])
        await model.connect(.linkedin)
        #expect(await waitUntil { store.sources[.linkedin]?.connected == true })
        await model.primaryAction()
        #expect(model.step == .mode)
        #expect(daemon.world.read { $0.preferences.careerPageUrls } == ["https://stripe.com/jobs"])
        #expect(daemon.world.read { $0.preferences.sourcesEnabled["linkedin"] } == true)

        // Mode → Ready → complete.
        model.selectedMode = .review
        await model.primaryAction()
        #expect(model.step == .ready)
        #expect(store.mode == .review)
        let done = await model.finish(runPrep: false)
        #expect(done)
        #expect(daemon.world.read { $0.onboarding.completed })
        #expect(!store.needsOnboarding)
        try? FileManager.default.removeItem(at: pdf)
        await store.stop()
    }

    @Test func backNavigatesAndResumesPersistedStep() async {
        let (model, store, _) = await makeModel()
        model.go(to: .neverGuess)
        model.back()
        #expect(model.step == .preferences)
        #expect(UserDefaults.standard.integer(forKey: OnboardingModel.stepDefaultsKey) == OnboardingModel.Step.preferences.rawValue)
        let resumed = OnboardingModel(store: store, checker: FakeChecker(items: []))
        resumed.load()
        #expect(resumed.step == .preferences)
        UserDefaults.standard.removeObject(forKey: OnboardingModel.stepDefaultsKey)
        await store.stop()
    }

    @Test func profileMergeOnlyFillsGaps() {
        var base = Profile()
        base.fullName = "Typed Name"
        var parsed = Profile()
        parsed.fullName = "Parsed Name"
        parsed.email = "p@example.com"
        parsed.skills = ["go"]
        let merged = OnboardingModel.mergeProfile(base, with: parsed)
        #expect(merged.fullName == "Typed Name")
        #expect(merged.email == "p@example.com")
        #expect(merged.skills == ["go"])
    }

    @Test func failedSaveKeepsUserOnStepWithInlineDaemonError() async {
        UserDefaults.standard.removeObject(forKey: OnboardingModel.stepDefaultsKey)
        let daemon = StubDaemon()
        let errors: JSONValue = .array([.object(["loc": .array([.string("preferences"), .string("daily_cap")]),
                                                 "msg": .string("Input should be less than or equal to 100"),
                                                 "type": .string("less_than_equal")])])
        daemon.responder = { command in
            if case .updatePreferences = command {
                return .error(ErrorPayload(code: .invalidPayload, message: "invalid payload", details: ["errors": errors]))
            }
            return .ack(AckPayload())
        }
        let store = AppStore(client: daemon, repository: InMemoryRepository(RepositoryData()))
        store.commandTimeout = .milliseconds(200)
        let model = OnboardingModel(store: store, checker: FakeChecker(items: []))
        model.go(to: .preferences)
        model.preferencesDraft.roles = ["Backend Engineer"]
        let before = model.shakeTrigger
        await model.primaryAction()
        #expect(model.step == .preferences, "must not advance when the save failed")
        #expect(model.shakeTrigger == before + 1)
        #expect(model.validationMessage == "Couldn't save: daily_cap: Input should be less than or equal to 100")

        // Mode step: a timeout also blocks Ready (so onboarding_complete is never reachable).
        daemon.responder = { _ in nil }
        model.go(to: .mode)
        await model.primaryAction()
        #expect(model.step == .mode)
        #expect(model.validationMessage?.contains("didn't respond") == true)
        UserDefaults.standard.removeObject(forKey: OnboardingModel.stepDefaultsKey)
    }

    @Test func processRunnerDrainsLargeStderrWithoutDeadlock() async {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await ProcessRunner.run("/bin/zsh", ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo done"],
                                             timeout: .seconds(20))
        #expect(result.status == 0)
        #expect(result.stdout == "done")
        #expect(result.stderr.count == 200_000)
        #expect(clock.now - start < .seconds(10))
    }
}
