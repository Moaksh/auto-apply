// C3LogicTests.swift — pure logic: JSON diff patches, the adaptive answer composer, template
// rendering, story suggestions, fuzzy matching, palette scopes, schedule times, validators,
// launchctl parsing, CSV export, story import.
import Foundation
import Testing
@testable import AutoApply

@Suite("C3 · JSON diff patches")
struct JSONDiffTests {
    @Test func onlyChangedKeysAreIncluded() {
        var a = Preferences()
        var b = a
        b.dailyCap = 20
        b.roles = ["Backend Engineer"]
        let patch = JSONDiff.preferencesPatch(from: a, to: b)
        #expect(Set(patch.values.keys) == ["daily_cap", "roles"])
        #expect(patch.values["daily_cap"] == .int(20))
        #expect(patch.values["roles"] == .array([.string("Backend Engineer")]))
        a = b
        #expect(JSONDiff.preferencesPatch(from: a, to: b).isEmpty)
    }

    @Test func clearedOptionalBecomesExplicitNull() {
        var a = NeverGuess()
        a.noticePeriod = "60 days"
        var b = a
        b.noticePeriod = nil
        let patch = JSONDiff.neverGuessPatch(from: a, to: b)
        #expect(patch.values == ["notice_period": .null])
    }

    @Test func numbersCompareByValue() {
        #expect(JSONDiff.equivalent(.int(5), .double(5.0)))
        #expect(!JSONDiff.equivalent(.int(5), .double(5.5)))
        #expect(JSONDiff.equivalent(.object(["a": .array([.int(1)])]), .object(["a": .array([.double(1)])])))
    }

    @Test func profilePatchIgnoresDerivedFields() {
        var a = Profile()
        a.email = "a@example.com"
        var b = a
        b.updatedAt = Date()
        b.rawText = "resume text"
        b.extra = ["x": .int(1)]
        #expect(JSONDiff.profilePatch(from: a, to: b).isEmpty)
        b.email = "b@example.com"
        #expect(JSONDiff.profilePatch(from: a, to: b).values == ["email": .string("b@example.com")])
    }

    @Test func dictionaryKeysDiffAsWholeValue() {
        var a = Preferences()
        var b = a
        b.perAtsMode["lever"] = .review
        let patch = JSONDiff.preferencesPatch(from: a, to: b)
        #expect(patch.values["per_ats_mode"] == .object(["workday": .string("review"), "lever": .string("review")]))
        a.perAtsMode = [:]
        b.perAtsMode = [:]
        #expect(JSONDiff.preferencesPatch(from: a, to: b).isEmpty)
    }
}

@Suite("C3 · Answer composer")
struct AnswerComposerTests {
    @Test func kindAdaptsToTheQuestion() {
        #expect(AnswerKind(cluster: C3Fixtures.cluster("a", jobs: [1], question: "Why do you want to work here?")) == .longText)
        #expect(AnswerKind(cluster: C3Fixtures.cluster("b", jobs: [1], question: "Notice period?")) == .shortText)
        #expect(AnswerKind(cluster: C3Fixtures.cluster("c", jobs: [1], question: "Years of Go?", fieldType: .number)) == .number)
        #expect(AnswerKind(cluster: C3Fixtures.cluster("d", jobs: [1], question: "PST hours?", fieldType: .boolean)) == .yesNo)
        #expect(AnswerKind(cluster: C3Fixtures.cluster("e", jobs: [1], question: "Pick", fieldType: .select, options: ["A", "B"])) == .choice(multi: false))
        #expect(AnswerKind(cluster: C3Fixtures.cluster("f", jobs: [1], question: "Pick", fieldType: .multiselect, options: ["A"])) == .choice(multi: true))
        #expect(AnswerKind(cluster: C3Fixtures.cluster("g", jobs: [1], question: "Pick", fieldType: .select)) == .shortText)
        #expect(AnswerKind(cluster: C3Fixtures.cluster("h", jobs: [1], question: "Portfolio", fieldType: .url)) == .url)
        var captcha = C3Fixtures.cluster("i", jobs: [1], question: "Solve CAPTCHA")
        captcha.reason = .captcha
        #expect(AnswerKind(cluster: captcha) == .captcha)
    }

    @Test func draftDefaultsDependOnNeverGuess() {
        let normal = AnswerDraft(cluster: C3Fixtures.cluster("a", jobs: [1]))
        #expect(normal.saveToMemory && !normal.saveToProfile)
        let locked = AnswerDraft(cluster: C3Fixtures.cluster("b", jobs: [1], question: "Notice period?", neverGuessKey: "notice_period"))
        #expect(locked.saveToProfile && !locked.saveToMemory)
    }

    @Test func resolvesEachKind() throws {
        var d = AnswerDraft()
        d.yesNo = true
        #expect(try AnswerComposerLogic.resolve(d, kind: .yesNo, jobIDs: [1]).get().answer == "Yes")
        d.choices = ["A", "C"]
        #expect(try AnswerComposerLogic.resolve(d, kind: .choice(multi: true), jobIDs: [1]).get().answer == "A, C")
        d.text = "  4 years "
        #expect(try AnswerComposerLogic.resolve(d, kind: .number, jobIDs: [1]).get().answer == "4 years")
        #expect(try AnswerComposerLogic.resolve(AnswerDraft(), kind: .captcha, jobIDs: [1]).get().answer == "solved")
    }

    @Test func rejectsInvalidValues() {
        var d = AnswerDraft()
        #expect(AnswerComposerLogic.resolve(d, kind: .shortText, jobIDs: [1]) == .failure(.empty))
        #expect(AnswerComposerLogic.resolve(d, kind: .yesNo, jobIDs: [1]) == .failure(.empty))
        d.text = "four"
        #expect(AnswerComposerLogic.resolve(d, kind: .number, jobIDs: [1]) == .failure(.notANumber))
        d.text = "not a url"
        #expect(AnswerComposerLogic.resolve(d, kind: .url, jobIDs: [1]) == .failure(.invalidURL))
        d.text = "github.com/me"
        #expect((try? AnswerComposerLogic.resolve(d, kind: .url, jobIDs: [1]).get()) != nil)
        d.text = "me@nowhere"
        #expect(AnswerComposerLogic.resolve(d, kind: .email, jobIDs: [1]) == .failure(.invalidEmail))
    }

    @Test func saveToProfileWinsOverMemory() throws {
        var d = AnswerDraft()
        d.text = "60 days"
        d.saveToMemory = true
        d.saveToProfile = true
        let r = try AnswerComposerLogic.resolve(d, kind: .shortText, jobIDs: [1]).get()
        #expect(r.saveToProfile && !r.saveToMemory)
    }

    @Test func perJobAnswersNeedEveryJobAndPickRepresentative() throws {
        var d = AnswerDraft()
        d.perJob = true
        d.perJobAnswers = [1: "Yes", 2: ""]
        #expect(AnswerComposerLogic.resolve(d, kind: .shortText, jobIDs: [1, 2, 3]) == .failure(.missingPerJob(count: 2)))
        d.perJobAnswers = [1: "Yes", 2: "No", 3: "Yes"]
        let r = try AnswerComposerLogic.resolve(d, kind: .shortText, jobIDs: [1, 2, 3]).get()
        #expect(r.answer == "Yes")
        #expect(r.perJobAnswers.map(\.jobId) == [1, 2, 3])
        #expect(!r.saveToMemory && !r.saveToProfile)
    }

    @Test func templateRendering() {
        let t = "I'm drawn to {company} as a {role}."
        #expect(AnswerComposerLogic.usesTokens(t))
        #expect(AnswerComposerLogic.render(template: t, company: "Ramp", role: "Platform Engineer") == "I'm drawn to Ramp as a Platform Engineer.")
        #expect(!AnswerComposerLogic.usesTokens("plain"))
    }

    @Test func storySuggestionsRankByOverlap() {
        let stories = MockFixtures.stories(now: C3Fixtures.now)
        let ranked = StorySuggester.rank(question: "Describe a conflict with another team and how you resolved it", stories: stories)
        #expect(ranked.first?.title == "Resolving an API design conflict")
        #expect(StorySuggester.rank(question: "Why?", stories: stories).isEmpty)
        #expect(!StorySuggester.snippet(stories[0]).isEmpty)
    }
}

@Suite("C3 · Palette matching")
struct PaletteMatchingTests {
    @Test func fuzzySubsequence() {
        #expect(FuzzyMatcher.score("strp", "Stripe") != nil)
        #expect(FuzzyMatcher.score("xyz", "Stripe") == nil)
        #expect(FuzzyMatcher.score("", "anything") == 0)
    }

    @Test func prefixAndBoundaryHitsRankHigher() throws {
        let prefix = try #require(FuzzyMatcher.score("str", "Stripe · Backend"))
        let scattered = try #require(FuzzyMatcher.score("str", "Senior Platform Engineer, Infra"))
        #expect(prefix > scattered)
        let boundary = try #require(FuzzyMatcher.score("sf", "Salary floor"))
        let inside = try #require(FuzzyMatcher.score("sf", "Glassdoor sessions finder"))
        #expect(boundary > inside)
    }

    @Test func scopePrefixes() {
        #expect(PaletteScope.parse("> pause").scope == .actions && PaletteScope.parse("> pause").text == "pause")
        #expect(PaletteScope.parse("@stripe").scope == .companies && PaletteScope.parse("@stripe").text == "stripe")
        #expect(PaletteScope.parse("?notice").scope == .questions && PaletteScope.parse("?notice").text == "notice")
        #expect(PaletteScope.parse("/ salary").scope == .settings && PaletteScope.parse("/ salary").text == "salary")
        #expect(PaletteScope.parse("  ramp ").scope == .all && PaletteScope.parse("  ramp ").text == "ramp")
        #expect(PaletteScope.parse("").scope == .all && PaletteScope.parse("").text == "")
    }
}

@Suite("C3 · Settings logic")
struct SettingsLogicTests {
    @Test func scheduleToggleKeepsSortedUnique() {
        var s = ["13:00", "09:00"]
        s = ScheduleTimes.toggle(hour: 18, in: s)
        #expect(s == ["09:00", "13:00", "18:00"])
        s = ScheduleTimes.toggle(hour: 9, in: s)
        #expect(s == ["13:00", "18:00"])
        #expect(ScheduleTimes.sorted(["9:30", "09:30", "07:00"]) == ["07:00", "09:30"])
        #expect(ScheduleTimes.parse("24:00") == nil)
        #expect(ScheduleTimes.hours(["09:15", "18:00"]) == [9, 18])
    }

    @Test func validatorCatchesBadValues() {
        #expect(PreferencesValidator.validate(Preferences()).isEmpty)
        var p = Preferences()
        p.remotePolicy = []
        p.dailyCap = 0
        p.nudgeDays = [14, 7]
        p.schedule = ["9am"]
        p.careerPageUrls = ["ftp://x"]
        p.salaryFloor = -1
        let keys = Set(PreferencesValidator.validate(p).map(\.key))
        #expect(keys == [.remotePolicy, .dailyCap, .nudgeDays, .schedule, .careerPageUrls, .salaryFloor])
        var q = Preferences()
        q.nudgeDays = [7, 30]
        q.ghostAfterDays = 21
        #expect(PreferencesValidator.validate(q).map(\.key) == [.nudgeDays])
    }

    @Test func careerURLs() {
        #expect(CareerURL.isValid("https://acme.com/careers"))
        #expect(!CareerURL.isValid("acme"))
        #expect(CareerURL.normalize("acme.com/jobs") == "https://acme.com/jobs")
    }

    @Test func launchctlParsing() {
        let out = """
        gui/501/com.autoapply.daemon = {
        \tactive count = 1
        \tstate = running
        \tpid = 4242
        \tlast exit code = 0
        }
        """
        let s = LaunchAgentStatus.parse(printOutput: out, exitCode: 0, plistExists: true)
        #expect(s.running && s.loaded && s.installed)
        #expect(s.pid == 4242)
        #expect(s.lastExitCode == 0)
        #expect(s.summary == "Running · pid 4242")
        let notLoaded = LaunchAgentStatus.parse(printOutput: "", exitCode: 113, plistExists: false)
        #expect(!notLoaded.loaded && notLoaded.summary == "Not installed")
        let waiting = LaunchAgentStatus.parse(printOutput: "state = waiting\nlast exit code = 78: EX_CONFIG", exitCode: 0, plistExists: true)
        #expect(!waiting.running && waiting.lastExitCode == 78)
    }

    @Test func trackerCSVEscapesAndFilters() {
        var a = C3Fixtures.job(id: 1, company: "Acme, Inc.", title: "Eng \"II\"", state: .submitted)
        a.status = .interview
        a.submittedAt = C3Fixtures.now
        let b = C3Fixtures.job(id: 2, state: .queued)
        let csv = TrackerCSV.make(jobs: [a, b])
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("company,title"))
        #expect(lines[1].hasPrefix("\"Acme, Inc.\",\"Eng \"\"II\"\"\""))
        #expect(lines[1].contains("interview"))
        #expect(TrackerCSV.make(jobs: [a, b], includeAll: true).split(separator: "\n").count == 3)
    }
}

@Suite("C3 · Story import")
struct StoryImportTests {
    @Test func labeledSections() {
        let text = """
        Payments ledger rewrite
        Situation: Ledger writes failed at peak.
        Task: Own the redesign.
        Action: Event sourcing
        and partitioned topics.
        Result: 12k TPS.
        """
        let d = StoryImporter.parse(text)
        #expect(d.title == "Payments ledger rewrite")
        #expect(d.situation == "Ledger writes failed at peak.")
        #expect(d.task == "Own the redesign.")
        #expect(d.action == "Event sourcing and partitioned topics.")
        #expect(d.result == "12k TPS.")
    }

    @Test func shortLabelsAndHeadings() {
        let d = StoryImporter.parse("## S\nContext here\n**A:** Did things\nR - Shipped")
        #expect(d.situation == "Context here")
        #expect(d.action == "Did things")
        #expect(d.result == "Shipped")
        #expect(!d.title.isEmpty)
    }

    @Test func paragraphsFillStarInOrder() {
        let d = StoryImporter.parse("On-call hero\n\nCheckout was slow.\n\nI led the incident.\n\nI rolled back.\n\nRestored in 22 minutes.")
        #expect(d.title == "On-call hero")
        #expect(d.situation == "Checkout was slow.")
        #expect(d.task == "I led the incident.")
        #expect(d.action == "I rolled back.")
        #expect(d.result == "Restored in 22 minutes.")
    }
}
