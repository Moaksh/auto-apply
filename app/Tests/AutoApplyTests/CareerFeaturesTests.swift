// CareerFeaturesTests.swift — the career helpers in the store and their models, with a stub
// agent: What's working (load from cache, Refresh = force, Summarize = summarize, failures),
// interview prep (no pack, generate / regenerate, debrief incl. an ungrounded thank-you, blank
// notes), the LinkedIn import result, the writing voice (load, save, validation holds the save),
// requirement evidence in old and new score shapes, ⌘K deep links, and the mock agent end to end.
import Foundation
import Testing
@testable import AutoApply

enum CareerFixtures {
    static let now = Samples.now

    static func insights(cached: Bool = true, summary: String? = nil) -> Insights {
        Insights(
            computedAt: now, cached: cached,
            calibration: ScoreCalibration(
                bands: [
                    ScoreBand(label: "<60", minScore: 0, maxScore: 59, applications: 3, responses: 0, interviews: 0),
                    ScoreBand(label: "70–79", minScore: 70, maxScore: 79, applications: 12, responses: 3, interviews: 1,
                              responseRate: 0.25, interviewRate: 1.0 / 12, enoughData: true),
                    ScoreBand(label: "90+", minScore: 90, maxScore: 100, applications: 10, responses: 6, interviews: 3,
                              responseRate: 0.6, interviewRate: 0.3, enoughData: true),
                ],
                minBandSample: 8, matchThreshold: 70, resolved: 25, inFlight: 4, unscored: 1, verdict: .separating,
                finding: "Your match score predicts replies: jobs scored 90+ heard back 60% of the time vs 25% for 70–79."),
            skipBlockers: SkipBlockers(windowDays: 30, skipped: 14,
                                       reasons: [SkipReasonCount(reason: "below_threshold", label: "Below your match threshold", count: 9,
                                                                 examples: ["Stripe · Backend Engineer", "Ramp · Platform Engineer"])],
                                       requirements: [RequirementBlocker(label: "Kubernetes", kind: .skill, count: 4, wordings: ["k8s in production"],
                                                                         examples: ["Datadog · SRE"])]),
            upskill: UpskillHints(windowDays: 90, jobsConsidered: 20, minJobs: 3,
                                  hints: [UpskillHint(skill: "Terraform", jobs: 5, skipped: 4, rejected: 1, examples: ["Vercel · Infra"])],
                                  summary: summary, note: "Learn it if it fits your direction; never claim a skill you don't have."),
            variants: VariantInsights(variants: [
                VariantPerformance(resumeVariantId: 1, label: "Backend", applications: 18, responses: 7, interviews: 3, responseRate: 7.0 / 18, lowSample: false),
                VariantPerformance(resumeVariantId: 2, label: "ML", applications: 4, responses: 1, interviews: 0, responseRate: 0.25, lowSample: true),
            ], finding: "“Backend” heard back 39% of the time."))
    }

    static func pack(applicationID: Int = 1, gap: Bool = true) -> InterviewPrepPack {
        var questions = [
            InterviewQuestion(kind: .technical, question: "How would you make a payment write idempotent?"),
            InterviewQuestion(kind: .behavioural, question: "Tell us about scaling a system.", basis: "High-throughput role",
                              storyId: 1, storyTitle: "Payments ledger at scale",
                              star: StarOutline(situation: "Ledger writes failing", task: "Redesign", action: "Event sourcing", result: "12k TPS"),
                              starSource: .story),
            InterviewQuestion(kind: .role, question: "Why Stripe?"),
        ]
        if gap {
            questions.append(InterviewQuestion(kind: .behavioural, question: "Tell us about a disagreement.", storyGap: "Add a story about a disagreement."))
        }
        return InterviewPrepPack(applicationId: applicationID, jobId: applicationID, company: "Stripe", title: "Backend Engineer",
                                 status: .interview, generatedAt: now, trigger: .statusChange, questions: questions,
                                 questionsToAsk: ["What does success look like in 90 days?"],
                                 companyBrief: CompanyBrief(name: "Stripe", domain: "stripe.com", careersUrl: "https://stripe.com/jobs",
                                                            summary: "Payments infrastructure.", otherRoles: ["Platform Engineer"]),
                                 checklist: [ChecklistItem(text: "Join the Zoom call", url: "https://zoom.us/j/1", source: .employerReply),
                                             ChecklistItem(text: "Test your camera", source: .general)],
                                 unsupportedClaims: ["Led a team of 12"])
    }

    static func debrief(grounded: Bool) -> InterviewDebrief {
        InterviewDebrief(applicationId: 1, createdAt: now, wentWell: ["System design"], gaps: ["Kafka internals"],
                         followUps: ["Send the doc"],
                         thankYou: ThankYouDraft(subject: "Thank you", body: grounded ? "Hi Priya, thanks." : "Hi [Name], thanks.",
                                                 grounded: grounded, unsupportedClaims: grounded ? [] : ["[Name]"]))
    }

    static func ack<T: Encodable>(_ value: T) -> DaemonEvent { MockCommandHandler.ack(encoding: value) }

    static func data(interviewStage: Bool = true) -> RepositoryData {
        var d = RepositoryData()
        var j = Samples.job(id: 1, state: .submitted, status: interviewStage ? .interview : .applied, submittedAt: now)
        j.statusUpdatedAt = now
        d.jobs = [j, Samples.job(id: 2, state: .queued)]
        return d
    }
}

@MainActor
@Suite("Career features", .serialized)
struct CareerFeaturesTests {

    func makeStore(_ data: RepositoryData = CareerFixtures.data(), responder: @escaping @Sendable (Command) -> DaemonEvent? = { _ in .ack(AckPayload()) })
        async -> (AppStore, StubDaemon) {
        FeatureModels.reset()
        let daemon = StubDaemon()
        daemon.responder = responder
        let store = AppStore(client: daemon, repository: InMemoryRepository(data))
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded }
        return (store, daemon)
    }

    // MARK: Requirement evidence

    @Test func oldScoreShapeHasNoRequirementTable() throws {
        let reasons: JSONValue = .object(["summary": .string("Good fit"), "factors": .object(["skills": .int(80), "domain": .double(71.6)]),
                                          "concerns": .array([.string("No Kafka")])])
        var job = Samples.job(id: 1)
        ScoreEvidence.apply(reasons, to: &job)
        #expect(job.scoreSummary == "Good fit")
        #expect(job.scoreFactors == ["skills": 80, "domain": 72])
        #expect(job.scoreRequirements == nil, "older scores hide the table")
        #expect(job.scoreGrounding == nil)
        #expect(RequirementsTable.groundingNote(nil) == nil)
    }

    @Test func newScoreShapeParsesRequirementsAndGrounding() throws {
        let raw = #"""
        {"summary": "Strong", "factors": {"skills": 90},
         "requirements": [
           {"requirement": "Go", "status": "met", "evidence": "Built services in Go", "confidence": "high", "dealbreaker": false},
           {"requirement": "On-call", "status": "partial", "evidence": "", "confidence": "low", "dealbreaker": true, "jd_quote": "Must join on-call"},
           {"requirement": "Rust", "status": "weird", "evidence": "", "confidence": "?", "dealbreaker": true},
           {"requirement": "  ", "status": "met"},
           {"status": "met"}
         ],
         "grounding": {"evidence_dropped": 2, "dealbreakers_dropped": 1}}
        """#
        let reasons = try ProtocolCoding.makeDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        var job = Samples.job(id: 1)
        ScoreEvidence.apply(reasons, to: &job)
        let reqs = try #require(job.scoreRequirements)
        #expect(reqs.map(\.requirement) == ["Go", "On-call", "Rust"], "blank and missing requirements are dropped")
        #expect(reqs.map(\.index) == [0, 1, 2])
        #expect(reqs[0].status == .met && reqs[0].evidence == "Built services in Go" && reqs[0].confidence == .high && !reqs[0].dealbreaker)
        #expect(reqs[1].dealbreaker && reqs[1].jdQuote == "Must join on-call")
        #expect(reqs[2].status == .missing && reqs[2].confidence == .low, "unknown values read conservatively")
        #expect(!reqs[2].dealbreaker, "a dealbreaker without the job's own words isn't shown as one")
        #expect(job.scoreGrounding == ScoreGrounding(evidenceDropped: 2, dealbreakersDropped: 1))
        #expect(RequirementsTable.groundingNote(job.scoreGrounding)?.contains("2 quotes couldn't be found") == true)
        #expect(RequirementsTable.groundingNote(ScoreGrounding(evidenceDropped: 0, dealbreakersDropped: 3)) == nil, "quiet unless evidence was dropped")
        #expect(RequirementsTable.tone(.met) == .status(.applied))
    }

    @Test func emptyRequirementListIsKeptButNotShown() {
        var job = Samples.job(id: 1)
        ScoreEvidence.apply(.object(["requirements": .array([])]), to: &job)
        #expect(job.scoreRequirements == [])
    }

    @Test func jobScoredEventCarriesRequirements() async {
        let (store, daemon) = await makeStore()
        daemon.push(.jobScored(JobScoredPayload(jobId: 2, applicationId: 2, score: 81, reasons: [
            "summary": .string("Fit"),
            "requirements": .array([.object(["requirement": .string("Go"), "status": .string("met"), "evidence": .string("go"),
                                             "confidence": .string("high"), "dealbreaker": .bool(false)])]),
        ])))
        #expect(await waitUntil { store.jobs.job(id: 2)?.scoreRequirements?.count == 1 })
        await store.stop()
    }

    // MARK: Insights

    @Test func insightsLoadRefreshAndSummarize() async throws {
        let (store, daemon) = await makeStore(responder: { command in
            if case .getInsights(let p) = command {
                return CareerFixtures.ack(CareerFixtures.insights(cached: !p.force && !p.summarize, summary: p.summarize ? "Short summary" : nil))
            }
            return .ack(AckPayload())
        })
        let model = InsightsModel(store: store)
        await model.loadIfNeeded()
        #expect(model.phase == .loaded)
        #expect(model.insights?.cached == true)
        guard case .getInsights(let first)? = daemon.sent.last else { Issue.record("no get_insights"); return }
        #expect(!first.force && !first.summarize)

        await model.loadIfNeeded()
        #expect(daemon.sent.filter { $0.type == "get_insights" }.count == 1, "loaded once")

        await model.load(force: true)
        guard case .getInsights(let refresh)? = daemon.sent.last else { Issue.record("no refresh"); return }
        #expect(refresh.force && !refresh.summarize)
        #expect(model.insights?.cached == false)
        #expect(!model.isRefreshing)

        await model.summarize()
        guard case .getInsights(let summarize)? = daemon.sent.last else { Issue.record("no summarize"); return }
        #expect(summarize.summarize && !summarize.force)
        #expect(model.insights?.upskill.summary == "Short summary")
        #expect(model.actionError == nil)
        await store.stop()
    }

    @Test func insightsFailures() async {
        final class Flag: @unchecked Sendable { var fail = true }
        let flag = Flag()
        let (store, _) = await makeStore(responder: { command in
            if case .getInsights = command {
                return flag.fail ? .error(ErrorPayload(code: .internal, message: "database is locked")) : CareerFixtures.ack(CareerFixtures.insights())
            }
            return .ack(AckPayload())
        })
        let model = InsightsModel(store: store)
        await model.load()
        guard case .failed(let message) = model.phase else { Issue.record("expected failed, got \(model.phase)"); return }
        #expect(message.contains("Database is locked"))
        flag.fail = false
        await model.load()
        #expect(model.phase == .loaded)
        flag.fail = true
        await model.load(force: true)
        #expect(model.phase == .loaded, "an earlier report stays on screen")
        #expect(model.insights != nil)
        #expect(model.actionError?.hasPrefix("Couldn't refresh") == true)
        await model.summarize()
        #expect(model.actionError?.hasPrefix("Couldn't summarize") == true)
        await store.stop()
    }

    @Test func insightsFormatting() {
        let i = CareerFixtures.insights()
        #expect(InsightsFormat.bandRates(i.calibration.bands[0]) == "Not enough data yet")
        #expect(InsightsFormat.bandRates(i.calibration.bands[2]).hasPrefix("60%"))
        // A band flagged as enough data but missing its rate still says so rather than "0%".
        var odd = i.calibration.bands[1]
        odd.responseRate = nil
        #expect(InsightsFormat.bandRates(odd) == "Not enough data yet")
        let foot = InsightsFormat.calibrationFootnote(i.calibration)
        #expect(foot.contains("from 8 applications") && foot.contains("4 applied in the last 14 days") && foot.contains("threshold is 70"))
        let stats = InsightsFormat.variantStats(i.variants)
        #expect(stats.map(\.label) == ["Backend", "ML"])
        #expect(stats[1].isLowSample && !stats[0].isLowSample)
        #expect(InsightsFormat.updated(i, now: CareerFixtures.now.addingTimeInterval(10)).hasPrefix("Updated just now"))
        #expect(InsightsFormat.updated(i).contains("saved copy"))
        #expect(InsightsFormat.upskillAdvice.contains("never claim a skill you don't have"))
        #expect(InsightsFormat.advisory.contains("nothing is changed automatically"))
    }

    // MARK: Interview prep

    @Test func prepGetGenerateRegenerate() async {
        final class Box: @unchecked Sendable { var stored: InterviewPrepPack? }
        let box = Box()
        let (store, daemon) = await makeStore(responder: { command in
            switch command {
            case .getInterviewPrep: return box.stored.map(CareerFixtures.ack) ?? .ack(AckPayload())
            case .generateInterviewPrep(let p):
                var pack = CareerFixtures.pack(applicationID: p.applicationId)
                pack.trigger = .user
                if p.force { pack.questionsToAsk = ["Regenerated?"] }
                box.stored = pack
                return CareerFixtures.ack(pack)
            default: return .ack(AckPayload())
            }
        })
        let model = InterviewPrepModel(store: store)
        #expect(model.state(1) == .unknown)
        await model.load(applicationID: 1)
        #expect(model.state(1) == .empty, "null result = no pack yet")
        #expect(model.pack(1) == nil)
        let job = store.jobs.job(id: 1)!
        #expect(model.showsTab(for: job), "interview stage shows the tab")
        #expect(!model.showsTab(for: store.jobs.job(id: 2)!), "a queued job doesn't")

        await model.generate(applicationID: 1, force: false)
        #expect(model.state(1) == .ready)
        #expect(model.pack(1)?.trigger == .user)
        guard case .generateInterviewPrep(let g)? = daemon.sent.last else { Issue.record("no generate"); return }
        #expect(g.applicationId == 1 && !g.force)

        await model.generate(applicationID: 1, force: true)
        guard case .generateInterviewPrep(let r)? = daemon.sent.last else { Issue.record("no regenerate"); return }
        #expect(r.force)
        #expect(model.pack(1)?.questionsToAsk == ["Regenerated?"])

        // A re-check keeps the pack (no flash of "Looking…").
        await model.load(applicationID: 1, force: true)
        #expect(model.state(1) == .ready)
        await store.stop()
    }

    @Test func prepGenerateFailureKeepsPackAndSaysWhy() async {
        let (store, _) = await makeStore(responder: { command in
            switch command {
            case .getInterviewPrep: return CareerFixtures.ack(CareerFixtures.pack())
            case .generateInterviewPrep: return .error(ErrorPayload(code: .unavailable, message: "the model is unavailable"))
            default: return .ack(AckPayload())
            }
        })
        let model = InterviewPrepModel(store: store)
        await model.load(applicationID: 1)
        await model.generate(applicationID: 1, force: true)
        #expect(model.state(1) == .ready)
        #expect(model.generateErrors[1] == "The model is unavailable")
        #expect(model.generating.isEmpty)
        await store.stop()
    }

    @Test func packWithAPackShowsTabForAnyStatus() async {
        let (store, _) = await makeStore(CareerFixtures.data(interviewStage: false), responder: { command in
            if case .getInterviewPrep = command { return CareerFixtures.ack(CareerFixtures.pack()) }
            return .ack(AckPayload())
        })
        let model = InterviewPrepModel(store: store)
        let job = store.jobs.job(id: 1)!
        #expect(!model.showsTab(for: job))
        await model.load(applicationID: 1)
        #expect(model.showsTab(for: job), "whenever a pack exists")
        await store.stop()
    }

    @Test func questionsGroupByKindInOrder() {
        let groups = InterviewPrepModel.grouped(CareerFixtures.pack().questions)
        #expect(groups.map(\.kind) == [.behavioural, .technical, .role])
        #expect(groups[0].questions.count == 2)
        #expect(groups[0].questions[1].storyGap != nil && groups[0].questions[1].star == nil)
        #expect(InterviewQuestion.Kind.role.title == "About the role")
    }

    @Test func debriefGroundedAndNot() async {
        final class Flag: @unchecked Sendable { var grounded = true }
        let flag = Flag()
        let (store, daemon) = await makeStore(responder: { command in
            if case .interviewDebrief = command { return CareerFixtures.ack(CareerFixtures.debrief(grounded: flag.grounded)) }
            return .ack(AckPayload())
        })
        let model = InterviewPrepModel(store: store)

        // Blank notes never reach the agent.
        model.notes[1] = "   \n"
        await model.debrief(applicationID: 1)
        #expect(!daemon.sent.contains { $0.type == "interview_debrief" })
        #expect(model.debriefErrors[1] != nil)
        #expect(InterviewPrepModel.notesIssue(String(repeating: "a", count: 20_001)) == .tooLong)

        model.notes[1] = "  Spoke with Priya about Kafka. "
        await model.debrief(applicationID: 1)
        guard case .interviewDebrief(let p)? = daemon.sent.last else { Issue.record("no debrief"); return }
        #expect(p.applicationId == 1 && p.notes == "Spoke with Priya about Kafka.")
        #expect(model.latestDebrief(1)?.thankYou.grounded == true)
        #expect(model.notes[1] == "", "notes clear once the debrief is back")
        #expect(model.debriefErrors[1] == nil)

        flag.grounded = false
        model.notes[1] = "It went fine"
        await model.debrief(applicationID: 1)
        let latest = model.latestDebrief(1)
        #expect(latest?.thankYou.grounded == false)
        #expect(latest?.thankYou.unsupportedClaims == ["[Name]"])
        #expect(model.debriefs[1]?.count == 2, "newest last")
        #expect(InterviewPrepModel.clipboardText(latest!.thankYou) == "Subject: Thank you\n\nHi [Name], thanks.")
        await store.stop()
    }

    @Test func debriefFailureKeepsNotes() async {
        let (store, _) = await makeStore(responder: { command in
            if case .interviewDebrief = command { return .error(ErrorPayload(code: .invalidPayload, message: "notes must not be blank")) }
            return .ack(AckPayload())
        })
        let model = InterviewPrepModel(store: store)
        model.notes[1] = "Notes"
        await model.debrief(applicationID: 1)
        #expect(model.notes[1] == "Notes")
        #expect(model.debriefErrors[1] == "Notes must not be blank")
        await store.stop()
    }

    @Test func storedDebriefsDecodeFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aa-prep-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("interview_prep"), withIntermediateDirectories: true)
        let data = try ProtocolCoding.makeEncoder().encode([CareerFixtures.debrief(grounded: true)])
        try data.write(to: dir.appendingPathComponent("interview_prep/7.debriefs.json"))
        #expect(InterviewPrepModel.readDebriefs(applicationID: 7, home: dir).count == 1)
        #expect(InterviewPrepModel.readDebriefs(applicationID: 8, home: dir).isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: LinkedIn import

    @Test func linkedInImportResultHandling() async throws {
        let json = #"""
        {"imported": 312, "merged": 4, "skipped": 2, "referral_suggestions": 5,
         "matched_companies": [{"company_id": 7, "name": "Acme", "why": "You applied", "connections": 3},
                               {"company_id": 9, "name": "Globex", "connections": 2}]}
        """#
        let result = try ProtocolCoding.makeDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        let (store, daemon) = await makeStore(responder: { command in
            if case .importLinkedinConnections(let p) = command {
                return p.filePath.hasSuffix("bad.csv")
                    ? .error(ErrorPayload(code: .invalidPayload, message: "that doesn't look like Connections.csv"))
                    : .ack(AckPayload(ok: true, result: result))
            }
            return .ack(AckPayload())
        })
        let model = ColdEmailModel(store: store)
        model.tab = .outbox
        model.beginLinkedInImport()
        #expect(model.isLinkedInImportPresented && model.tab == .people && model.peopleFilter == .everyone && model.linkedInImport == .idle)

        await model.importLinkedIn(filePath: "/tmp/Connections.csv")
        guard case .importLinkedinConnections(let p)? = daemon.sent.last else { Issue.record("no import"); return }
        #expect(p.filePath == "/tmp/Connections.csv")
        guard case .done(let r) = model.linkedInImport else { Issue.record("not done: \(model.linkedInImport)"); return }
        #expect(r.imported == 312 && r.merged == 4 && r.skipped == 2 && r.referralSuggestions == 5)
        #expect(r.matchedCompanies.map(\.name) == ["Acme", "Globex"])
        #expect(r.matchedCompanies[1].why == "", "missing optional keys decode")
        #expect(ColdEmailModel.linkedInSummary(r) == "312 new contacts · 4 updated · 2 skipped")
        #expect(ColdEmailModel.linkedInReferralLine(r) == "5 new referral suggestions at 2 companies.")
        model.showReferralsAfterImport()
        #expect(!model.isLinkedInImportPresented && model.tab == .people && model.peopleFilter == .couldRefer)

        await model.importLinkedIn(filePath: "/tmp/bad.csv")
        #expect(model.linkedInImport == .failed("That doesn't look like Connections.csv"))

        let none = LinkedInImportResult(imported: 3, merged: 0, skipped: 0, matchedCompanies: [], referralSuggestions: 0)
        #expect(ColdEmailModel.linkedInSummary(none) == "3 new contacts")
        #expect(ColdEmailModel.linkedInReferralLine(none).hasPrefix("None of your connections"))
        await store.stop()
    }

    // MARK: Writing voice

    @Test func voiceLoadSaveAndValidation() async {
        final class Box: @unchecked Sendable { var profile = VoiceProfile() }
        let box = Box()
        let (store, daemon) = await makeStore(responder: { command in
            switch command {
            case .getVoiceProfile: return CareerFixtures.ack(box.profile)
            case .updateVoiceProfile(let p):
                var v = box.profile
                if let s = p.signOff { v.signOff = s.isEmpty ? "Best regards" : s }
                if let f = p.formality { v.formality = f }
                if let m = p.maxWords { v.maxWords = m }
                if let a = p.avoidPhrases { v.avoidPhrases = a }
                if let w = p.writingSample { v.writingSample = w.isEmpty ? nil : w }
                box.profile = v
                return CareerFixtures.ack(v)
            default: return .ack(AckPayload())
            }
        })
        let model = VoiceProfileModel(store: store)
        model.debounce = .milliseconds(5)
        #expect(model.phase == .idle)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.draft == VoiceProfile())
        #expect(!model.hasUnsavedChanges)

        model.draft.signOff = "Thanks"
        model.draft.formality = .casual
        model.draft.avoidPhrases = ["I hope this finds you well", "  "]
        model.draft.writingSample = "Short and direct."
        #expect(await waitUntil { model.save == .saved })
        guard case .updateVoiceProfile(let p)? = daemon.sent.last else { Issue.record("no update"); return }
        #expect(p.signOff == "Thanks" && p.formality == .casual && p.maxWords == 250)
        #expect(p.avoidPhrases == ["I hope this finds you well"], "blank chips are dropped")
        #expect(p.writingSample == "Short and direct.")
        #expect(model.draft.avoidPhrases == ["I hope this finds you well"], "adopts the agent's copy")

        // Clearing the sample sends "" (the agent resets it).
        #expect(VoiceProfileModel.payload(VoiceProfile()).writingSample == "")

        // An invalid field holds the save and says so.
        let sentBefore = daemon.sent.count
        model.draft.maxWords = 20
        #expect(model.issues[.maxWords] != nil)
        if case .failed(let message) = model.save { #expect(message.hasPrefix("Not saved")) } else { Issue.record("expected Not saved") }
        #expect(await model.saveNow() == false)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(daemon.sent.count == sentBefore, "nothing sent while invalid")

        #expect(VoiceProfileModel.validate(VoiceProfile(signOff: String(repeating: "x", count: 41)))[.signOff] != nil)
        #expect(VoiceProfileModel.validate(VoiceProfile(avoidPhrases: (0..<21).map { "p\($0)" }))[.avoidPhrases] != nil)
        #expect(VoiceProfileModel.validate(VoiceProfile(avoidPhrases: [String(repeating: "x", count: 81)]))[.avoidPhrases] != nil)
        #expect(VoiceProfileModel.validate(VoiceProfile(writingSample: String(repeating: "x", count: 1501)))[.writingSample] != nil)
        #expect(VoiceProfileModel.validate(VoiceProfile()).isEmpty)
        await store.stop()
    }

    @Test func voiceLoadFailureSaysSo() async {
        let (store, _) = await makeStore(responder: { _ in .error(ErrorPayload(code: .internal, message: "boom")) })
        let model = VoiceProfileModel(store: store)
        await model.load()
        guard case .failed = model.phase else { Issue.record("expected failed, got \(model.phase)"); return }
        await store.stop()
    }

    // MARK: ⌘K deep links

    @Test func paletteDeepLinks() async {
        let (store, _) = await makeStore()
        #expect(AppAction.paletteActions.contains(.showInsights))
        #expect(AppAction.paletteActions.contains(.importLinkedInConnections))
        #expect(AppAction.openInterviewPrep.title(in: store) == "Interview prep: Stripe")
        #expect(AppAction.openInterviewPrep.isAvailable(in: store))

        await store.perform(.showInsights)
        #expect(store.router.selection == .dashboard && store.router.path == [.insights])

        await store.perform(.openInterviewPrep)
        #expect(store.router.openJobDetailID == 1)
        #expect(store.router.jobTabRequest?.tab == JobDetailTab.prep.rawValue)

        await store.perform(.importLinkedInConnections)
        #expect(store.router.selection == .coldEmail)
        let cold = ColdEmailModel.shared(for: store)
        #expect(cold.isLinkedInImportPresented && cold.tab == .people)

        let palette = PaletteModel(store: store)
        palette.query = "writing voice"
        #expect(palette.results.contains { $0.kind == .setting(.outreach, "voice_profile") })
        palette.query = "> what's working"
        #expect(palette.results.contains { $0.kind == .action(.showInsights) })
        await store.stop()
    }

    @Test func interviewPrepActionHiddenWithoutAStage() async {
        let (store, _) = await makeStore(CareerFixtures.data(interviewStage: false))
        #expect(!AppAction.openInterviewPrep.isAvailable(in: store))
        await store.stop()
    }

    // MARK: Mock agent end to end

    @Test func mockAgentCareerCommands() async throws {
        FeatureModels.reset()
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded }

        let insights = try #require(await store.fetchInsights())
        #expect(insights.calibration.bands.count == 5)
        #expect(!insights.skipBlockers.reasons.isEmpty)
        #expect(!insights.variants.variants.isEmpty)
        let summarized = try #require(await store.fetchInsights(summarize: true))
        #expect(summarized.upskill.summary != nil && summarized.tokensIn > 0)

        // Some scores carry requirement evidence; some keep the older shape.
        #expect(store.jobs.all.contains { $0.scoreRequirements?.isEmpty == false })
        #expect(store.jobs.all.contains { $0.score != nil && $0.scoreRequirements == nil })

        let applied = try #require(store.jobs.all.first { $0.state == .submitted && $0.applicationID != nil })
        let model = InterviewPrepModel.shared(for: store)
        await model.generate(applicationID: applied.applicationID, force: false)
        let pack = try #require(model.pack(applied.applicationID))
        #expect(pack.questions.contains { $0.kind == .behavioural && $0.star != nil })
        #expect(pack.questions.contains { $0.storyGap != nil }, "no fitting story → a gap, never an invented one")

        model.notes[applied.applicationID!] = "It went well, talked about payments."
        await model.debrief(applicationID: applied.applicationID)
        #expect(model.latestDebrief(applied.applicationID)?.thankYou.grounded == false, "a [Name] placeholder isn't grounded")
        model.notes[applied.applicationID!] = "Spoke with Priya about payments."
        await model.debrief(applicationID: applied.applicationID)
        #expect(model.latestDebrief(applied.applicationID)?.thankYou.body.contains("Hi Priya") == true)

        let csv = FileManager.default.temporaryDirectory.appendingPathComponent("Connections-\(UUID().uuidString.prefix(6)).csv")
        try """
        Notes:
        "When exporting your connection data, you may notice..."

        First Name,Last Name,URL,Email Address,Company,Position,Connected On
        Riya,Shah,https://www.linkedin.com/in/riya,,\(applied.company),Engineer,01 Oct 2026
        Sam,Lee,https://www.linkedin.com/in/sam,,Nowhere Inc,PM,02 Oct 2026
        """.write(to: csv, atomically: true, encoding: .utf8)
        let result = try #require(await store.importLinkedInConnections(filePath: csv.path))
        #expect(result.imported == 2)
        #expect(result.matchedCompanies.first?.name == applied.company)
        #expect(result.referralSuggestions == 1)
        #expect(await store.importLinkedInConnections(filePath: "/nope/Connections.csv") == nil)
        try? FileManager.default.removeItem(at: csv)

        let voice = VoiceProfileModel.shared(for: store)
        await voice.load()
        voice.draft.signOff = "Cheers"
        #expect(await voice.saveNow())
        #expect(await store.voiceProfile()?.signOff == "Cheers")
        await store.stop()
    }
}
