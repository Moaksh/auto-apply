// SettingsProfileTests.swift — Settings auto-save (only changed keys, validation blocks sends,
// never-guess blanks become null, remote sync vs. unsaved edits), Profile save/memory, Story
// bank, Resumes edits.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C3 · Settings model", .serialized)
struct SettingsModelTests {
    private func setup(responder: (@Sendable (Command) -> DaemonEvent?)? = nil) async -> (AppStore, C3StubDaemon, SettingsModel) {
        var data = RepositoryData()
        data.jobs = [C3Fixtures.job(id: 1, company: "Stripe", companyID: 7), C3Fixtures.job(id: 2, company: "Acme", companyID: 3)]
        var ng = NeverGuess()
        ng.noticePeriod = "60 days"
        data.neverGuess = ng
        let (store, daemon, _) = await makeC3Store(data: data)
        _ = await c3WaitUntil { store.library.neverGuess.noticePeriod == "60 days" }
        // Echo the merged preferences / never-guess like autoapplyd does.
        let prefsBox = PrefsEcho(store.preferences, store.library.neverGuess)
        daemon.responder = responder ?? { cmd in
            switch cmd {
            case .updatePreferences(let p):
                let merged = prefsBox.mergePrefs(p.preferences.values)
                return .ack(AckPayload(ok: true, result: ["preferences": (try? JSONValue.encode(merged)) ?? .null]))
            case .updateNeverGuess(let p):
                let merged = prefsBox.mergeNG(p.values.values)
                return .ack(AckPayload(ok: true, result: ["never_guess": (try? JSONValue.encode(merged)) ?? .null]))
            default:
                return .ack(AckPayload())
            }
        }
        let model = SettingsModel(store: store)
        model.debounce = .milliseconds(40)
        return (store, daemon, model)
    }

    @Test func debouncedSaveSendsOnlyChangedKeys() async throws {
        let (store, daemon, model) = await setup()
        model.preferencesDraft.dailyCap = 22
        model.preferencesDraft.dailyCap = 25
        model.preferencesDraft.excludeKeywords = ["crypto"]
        #expect(model.hasUnsavedPreferences)
        #expect(await c3WaitUntil { daemon.sent("update_preferences").count == 1 })
        let values = try #require(daemon.sent("update_preferences").first?.preferencesValues)
        #expect(Set(values.keys) == ["daily_cap", "exclude_keywords"])
        #expect(values["daily_cap"] == .int(25))
        #expect(await c3WaitUntil { model.preferencesSave == .saved })
        #expect(store.preferences.dailyCap == 25)
        #expect(!model.hasUnsavedPreferences)
    }

    @Test func invalidDraftIsNotSent() async throws {
        let (_, daemon, model) = await setup()
        model.preferencesDraft.remotePolicy = []
        #expect(model.issue(for: .remotePolicy) != nil)
        try await Task.sleep(for: .milliseconds(120))
        #expect(daemon.sent("update_preferences").isEmpty)
        #expect(await model.savePreferences() == false)
        model.preferencesDraft.remotePolicy = [.remote]
        #expect(model.issues.isEmpty)
        #expect(await c3WaitUntil { daemon.sent("update_preferences").count == 1 })
    }

    @Test func failedSaveKeepsDraftAndReportsError() async throws {
        let (_, _, model) = await setup(responder: { cmd in
            if case .updatePreferences = cmd { return .error(ErrorPayload(code: .invalidPayload, message: "invalid preferences")) }
            return .ack(AckPayload())
        })
        model.preferencesDraft.matchThreshold = 80
        #expect(await model.savePreferences() == false)
        guard case .failed = model.preferencesSave else { Issue.record("expected failure state"); return }
        #expect(model.preferencesDraft.matchThreshold == 80)
        #expect(model.hasUnsavedPreferences)
    }

    @Test func modesHelpersEditTheRightMaps() async throws {
        let (_, daemon, model) = await setup()
        // Mode overrides are sent immediately, each as its own single-key patch.
        #expect(await model.setAtsMode(.lever, .review))
        #expect(await model.setAtsMode(.workday, nil))
        #expect(daemon.sent("update_preferences").last?.preferencesValues == ["per_ats_mode": .object(["lever": .string("review")])])
        #expect(await model.setCompanyMode(companyID: 7, .auto))
        #expect(daemon.sent("update_preferences").last?.preferencesValues == ["per_company_mode": .object(["7": .string("auto")])])
        #expect(model.knownCompanies.map(\.name) == ["Acme", "Stripe"])
        #expect(model.companyName("7") == "Stripe")
        #expect(!model.hasUnsavedPreferences)
        _ = try #require(daemon.sent("update_preferences").last?.preferencesValues)
        await model.setGlobalMode(.auto)  // new installs start in Review (schema v13)
        #expect(daemon.sent("update_preferences").last?.preferencesValues == ["mode": .string("auto")])
    }

    @Test func sourcesAndScheduleHelpers() async {
        let (_, _, model) = await setup()
        model.toggleSource(.linkedin, true)
        #expect(model.isSourceEnabled(.linkedin))
        #expect(!model.addCareerURL("not a url"))
        #expect(model.addCareerURL("acme.com/careers"))
        #expect(model.preferencesDraft.careerPageUrls == ["https://acme.com/careers"])
        model.toggleScheduleHour(7)
        #expect(model.preferencesDraft.schedule == ["07:00", "09:00", "13:00", "18:00"])
        await model.flush()
    }

    @Test func neverGuessBlanksBecomeNull() async throws {
        let (store, daemon, model) = await setup()
        model.neverGuessDraft.noticePeriod = "  "
        model.neverGuessDraft.salaryExpectation = "₹45L"
        let patch = model.pendingNeverGuessPatch
        #expect(patch.values["notice_period"] == .null)
        #expect(patch.values["salary_expectation"] == .string("₹45L"))
        #expect(await model.saveNeverGuess())
        #expect(daemon.sent("update_never_guess").first?.neverGuessValues?["notice_period"] == .null)
        #expect(store.library.neverGuess.noticePeriod == nil)
        #expect(model.neverGuessBaseline.salaryExpectation == "₹45L")
    }

    @Test func eeoAnswersSaveAndBlankBecomesNull() async throws {
        let (store, daemon, model) = await setup()
        model.neverGuessDraft.eeoPolicy = "fill"
        model.neverGuessDraft.eeoGender = "Male"
        model.neverGuessDraft.eeoRace = "Asian"
        model.neverGuessDraft.eeoVeteran = "  "
        let patch = model.pendingNeverGuessPatch
        #expect(patch.values["eeo_policy"] == .string("fill"))
        #expect(patch.values["eeo_gender"] == .string("Male"))
        #expect(patch.values["eeo_race"] == .string("Asian"))
        #expect(patch.values["eeo_veteran"] == nil)  // blank, and it was already empty: nothing to send
        #expect(await model.saveNeverGuess())
        #expect(daemon.sent("update_never_guess").last?.neverGuessValues?["eeo_gender"] == .string("Male"))
        #expect(store.library.neverGuess.eeoGender == "Male")
        #expect(!model.hasUnsavedNeverGuess)
    }

    @Test func remoteChangesAdoptOnlyWhenClean() async {
        let (store, _, model) = await setup()
        var remote = store.preferences
        remote.dailyCap = 40
        store.setPreferences(remote)
        model.syncFromStore()
        #expect(model.preferencesDraft.dailyCap == 40)
        model.preferencesDraft.roles = ["SRE"]
        remote.dailyCap = 41
        store.setPreferences(remote)
        model.syncFromStore()
        #expect(model.preferencesDraft.dailyCap == 40)
        #expect(model.preferencesDraft.roles == ["SRE"])
        await model.flush()
    }

    @Test func settingsNavigationOpensTab() {
        let router = Router()
        let nav = SettingsNavigation()
        nav.open(.guardrails, key: "never_guess", router: router)
        #expect(nav.tab == .guardrails)
        #expect(nav.highlightedKey == "never_guess")
        #expect(router.settingsRequest == 1)
    }
}

/// Thread-safe echo of the daemon's merge semantics for the stub responder.
final class PrefsEcho: @unchecked Sendable {
    private let lock = NSLock()
    private var prefs: Preferences
    private var ng: NeverGuess

    init(_ prefs: Preferences, _ ng: NeverGuess) {
        self.prefs = prefs
        self.ng = ng
    }

    func mergePrefs(_ patch: [String: JSONValue]) -> Preferences {
        lock.withLock {
            prefs = (try? MockCommandHandler.merge(prefs, patch: patch)) ?? prefs
            return prefs
        }
    }

    func mergeNG(_ patch: [String: JSONValue]) -> NeverGuess {
        lock.withLock {
            ng = (try? MockCommandHandler.merge(ng, patch: patch)) ?? ng
            return ng
        }
    }
}

@MainActor
@Suite("C3 · Profile & stories", .serialized)
struct ProfileAndStoryTests {
    private func setup() async -> (AppStore, C3StubDaemon) {
        var data = RepositoryData()
        data.profile = MockFixtures.profile
        data.stories = MockFixtures.stories(now: C3Fixtures.now)
        data.memoryAnswers = MockFixtures.memoryAnswers(now: C3Fixtures.now)
        let (store, daemon, _) = await makeC3Store(data: data)
        _ = await c3WaitUntil { store.library.profile.fullName != nil && !store.library.memoryAnswers.isEmpty }
        daemon.responder = { cmd in
            switch cmd {
            case .updateProfile(let p):
                let merged = (try? MockCommandHandler.merge(MockFixtures.profile, patch: p.profile.values)) ?? MockFixtures.profile
                return .ack(AckPayload(ok: true, result: ["profile": (try? JSONValue.encode(merged)) ?? .null]))
            case .upsertStory(let p):
                return .ack(AckPayload(ok: true, result: ["story_id": .int(p.id ?? 99)]))
            default:
                return .ack(AckPayload())
            }
        }
        return (store, daemon)
    }

    @Test func profileSaveSendsOnlyEditedFields() async throws {
        let (store, daemon) = await setup()
        let model = ProfileModel(store: store)
        model.beginEditing()
        model.draft?.headline = "  Staff engineer  "
        model.draft?.skills.append(" ")
        model.linkDraftKey = "Portfolio"
        model.linkDraftValue = "me.dev"
        model.addLink()
        let values = model.pendingPatch.values
        #expect(Set(values.keys) == ["headline", "links"])
        #expect(values["headline"] == .string("Staff engineer"))
        #expect(await model.save())
        #expect(!model.isEditing)
        let sent = try #require(daemon.sent("update_profile").first?.profileValues)
        #expect(sent["links"]?["portfolio"] == .string("https://me.dev"))
        #expect(store.library.profile.headline == "Staff engineer")
    }

    @Test func profileValidationBlocksBadEmail() async {
        let (store, daemon) = await setup()
        let model = ProfileModel(store: store)
        model.beginEditing()
        model.draft?.email = "nope"
        #expect(await model.save() == false)
        #expect(daemon.sent("update_profile").isEmpty)
        #expect(model.isEditing)
        #expect(ProfileModel.validate(Profile()) == nil)
    }

    @Test func noChangesClosesWithoutSending() async {
        let (store, daemon) = await setup()
        let model = ProfileModel(store: store)
        model.beginEditing()
        #expect(await model.save())
        #expect(daemon.sent("update_profile").isEmpty)
    }

    @Test func memoryEditFilterAndDelete() async throws {
        let (store, daemon) = await setup()
        let model = ProfileModel(store: store)
        model.memoryFilter = "kubernetes"
        let item = try #require(model.memory.first)
        #expect(model.memory.count == 1)
        model.beginEditingMemory(item)
        model.memoryDraft = "4"
        await model.saveMemory(item)
        guard case .updateAnswer(let p)? = daemon.sent("update_answer").first else { Issue.record("expected update_answer"); return }
        #expect(p.answerId == item.id && p.answer == "4")
        model.confirmingDeleteMemoryID = item.id
        await model.deleteMemory(item)
        #expect(daemon.sent("delete_answer").count == 1)
        #expect(model.confirmingDeleteMemoryID == nil)
    }

    @Test func storyBankCreateEditDelete() async throws {
        let (store, daemon) = await setup()
        let model = StoryBankModel(store: store)
        model.ensureSelection()
        let first = try #require(model.selectedStory)
        #expect(!model.hasUnsavedChanges)
        model.draft?.result = "Even better result."
        #expect(model.hasUnsavedChanges)
        #expect(await model.save())
        guard case .upsertStory(let p)? = daemon.sent("upsert_story").first else { Issue.record("expected upsert"); return }
        #expect(p.id == first.id && p.result == "Even better result.")

        model.newStory()
        #expect(model.draft?.id == nil)
        #expect(await model.save() == false)   // needs a title
        model.importText = "Situation: A\nTask: B\nAction: C\nResult: D"
        model.applyImport()
        #expect(model.draft?.action == "C")
        #expect(await model.save())
        #expect(model.draft?.id == 99)

        model.select(first.id)
        await model.delete()
        guard case .deleteStory(let d)? = daemon.sent("delete_story").first else { Issue.record("expected delete"); return }
        #expect(d.id == first.id)
        #expect(model.usageLine(first) == "used in 7 applications")
    }
}

@MainActor
@Suite("C3 · Resumes", .serialized)
struct ResumesModelTests {
    private func setup() async -> (AppStore, C3StubDaemon, ResumesModel) {
        var data = RepositoryData()
        data.resumeVariants = MockFixtures.resumeVariants
        var j1 = C3Fixtures.job(id: 1, state: .submitted)
        j1.resumeVariantID = 1
        j1.status = .interview
        var j2 = C3Fixtures.job(id: 2, state: .submitted)
        j2.resumeVariantID = 1
        j2.status = .applied
        var j3 = C3Fixtures.job(id: 3, state: .queued)
        j3.resumeVariantID = 2
        data.jobs = [j1, j2, j3]
        let (store, daemon, _) = await makeC3Store(data: data)
        let model = ResumesModel(store: store)
        model.tagCommitDebounce = .milliseconds(30)
        return (store, daemon, model)
    }

    @Test func orderingStatsAndUsage() async throws {
        let (_, _, model) = await setup()
        #expect(model.variants.first?.isDefault == true)
        let backend = try #require(model.variants.first { $0.id == 1 })
        #expect(model.jobs(usedBy: backend).count == 2)
        #expect(model.statLine(for: backend) == "2 sent · 50%")
        let ml = try #require(model.variants.first { $0.id == 2 })
        #expect(model.statLine(for: ml) == "not sent yet")
        model.ensureSelection()
        #expect(model.selectedID == 1)
    }

    @Test func labelsFromFileNames() {
        #expect(ResumesModel.label(for: URL(fileURLWithPath: "/x/Backend_Resume-2026.pdf")) == "Backend Resume 2026")
    }

    @Test func tagEditsAreDebouncedAndOptimistic() async throws {
        let (_, daemon, model) = await setup()
        let backend = try #require(model.variants.first { $0.id == 1 })
        model.setTags(["Go", " Payments ", ""], for: backend)
        model.setTags(["Go", "Payments", "Kafka"], for: backend)
        #expect(model.tags(for: backend) == ["go", "payments", "kafka"])
        #expect(await c3WaitUntil { daemon.sent("update_resume_variant").count == 1 })
        guard case .updateResumeVariant(let p)? = daemon.sent("update_resume_variant").first else { Issue.record("expected update"); return }
        #expect(p.id == 1 && p.tags == ["go", "payments", "kafka"])
    }

    @Test func defaultAndEnabled() async throws {
        let (_, daemon, model) = await setup()
        let backend = try #require(model.variants.first { $0.id == 1 })
        let ml = try #require(model.variants.first { $0.id == 2 })
        await model.setEnabled(false, backend)   // default can't be disabled
        #expect(daemon.sent("update_resume_variant").isEmpty)
        await model.makeDefault(ml)
        guard case .updateResumeVariant(let p)? = daemon.sent("update_resume_variant").first else { Issue.record("expected update"); return }
        #expect(p.id == 2 && p.isDefault == true)
        await model.makeDefault(backend.isDefault ? backend : ml)
        await model.rename(ml, to: "  Machine Learning ")
        guard case .updateResumeVariant(let r)? = daemon.sent("update_resume_variant").last else { Issue.record("expected rename"); return }
        #expect(r.label == "Machine Learning")
    }

    @Test func addSendsAddResumeVariant() async throws {
        let (_, daemon, model) = await setup()
        daemon.responder = { cmd in
            if case .addResumeVariant = cmd { return .ack(AckPayload(ok: true, result: ["resume_variant_id": .int(9)])) }
            return .ack(AckPayload())
        }
        await model.add([URL(fileURLWithPath: "/tmp/Infra_v2.pdf"), URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(daemon.sent("add_resume_variant").count == 1)
        guard case .addResumeVariant(let p)? = daemon.sent("add_resume_variant").first else { Issue.record("expected add"); return }
        #expect(p.filePath == "/tmp/Infra_v2.pdf" && p.label == "Infra v2" && !p.isDefault)
        #expect(model.selectedID == 9)
        #expect(model.adding.isEmpty)
    }
}
