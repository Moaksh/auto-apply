// MockScenario.swift — the scenarios from docs/UI_UX_PLAN.md §8.5, each a dataset + initial
// daemon state + a timed script. Times are scenario seconds (scaled by MockDaemon.speed).
import Foundation

/// One timed script action.
struct ScriptStep: Sendable {
    var at: Double
    var action: @Sendable (MockWorld) async -> Void
}

enum MockScenario: String, CaseIterable, Sendable, Identifiable {
    /// Rich history, agent idle, next run scheduled. Good default for screen work.
    case idle
    /// 40 discovered, 27 skipped, 12 queued, 9 submitted (+2 need you) over ~3 minutes.
    case happyRun
    /// Prep pass producing 14 questions that collapse into 6 clusters.
    case needsYouStorm
    /// Mode Review: 5 jobs filled and awaiting review, 1 low-confidence.
    case reviewMode
    /// Socket unreachable (DB-driven screens keep working).
    case daemonDown
    /// LinkedIn session expires → banner + source status.
    case loginExpired
    /// Daily cap hit mid-run ("Done for today").
    case capReached
    /// Brand-new install after onboarding: no jobs, no runs.
    case firstRunEmpty
    /// 5 submits in 2 s (celebration coalescing).
    case burstSubmit
    /// 5,000 jobs, ~100k log rows, ~50 events/s.
    case stress
    /// Fresh install: onboarding not completed.
    case onboarding

    var id: String { rawValue }

    init?(name: String) {
        let normalized = name.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").lowercased()
        guard let match = MockScenario.allCases.first(where: { $0.rawValue.lowercased() == normalized }) else { return nil }
        self = match
    }

    var title: String {
        switch self {
        case .idle: "Idle (rich data)"
        case .happyRun: "Happy run"
        case .needsYouStorm: "Needs-you storm"
        case .reviewMode: "Review mode"
        case .daemonDown: "Daemon down"
        case .loginExpired: "Login expired"
        case .capReached: "Cap reached"
        case .firstRunEmpty: "First run (empty)"
        case .burstSubmit: "Burst submit"
        case .stress: "Stress (5k jobs)"
        case .onboarding: "Onboarding (fresh install)"
        }
    }

    var daemonIsDown: Bool { self == .daemonDown }

    struct Setup: Sendable {
        var data: RepositoryData
        var state: MockWorld.State
    }

    func makeSetup(now: Date = Date()) -> Setup {
        var state = MockWorld.State()
        state.nextRunAt = MockScripts.nextScheduledRun(after: now)
        var data: RepositoryData
        switch self {
        case .stress:
            data = MockFixtures.baseline(now: now, jobCount: 5_000, extraActivity: 95_000, seed: 7)
        case .firstRunEmpty:
            data = RepositoryData()
            data.profile = MockFixtures.profile
            data.neverGuess = MockFixtures.neverGuess
            data.resumeVariants = MockFixtures.resumeVariants
            data.stories = MockFixtures.stories(now: now)
        case .onboarding:
            data = RepositoryData()
            state.onboarding = OnboardingState(completed: false, step: 0)
            state.sources = MockWorld.defaultSources.map { s in
                var s = s
                if s.source == .linkedin { s.connected = false; s.enabled = false; s.detail = nil; s.checkedAt = nil }
                return s
            }
            state.nextRunAt = nil
        default:
            data = MockFixtures.baseline(now: now)
        }

        switch self {
        case .needsYouStorm:
            MockScripts.addJobs(&data, ids: MockScripts.stormJobIDs, state: .queued, now: now)
        case .reviewMode:
            state.preferences.mode = .review
            MockScripts.addJobs(&data, ids: MockScripts.reviewJobIDs, state: .queued, now: now)
        case .capReached:
            MockScripts.addJobs(&data, ids: [MockScripts.capJobID], state: .queued, now: now)
            state.caps.dailyUsed = 14
        case .burstSubmit:
            MockScripts.addJobs(&data, ids: MockScripts.burstJobIDs, state: .filling, now: now)
        default:
            break
        }
        // Every rich-data scenario has applications waiting for review (one with a low-confidence
        // answer), with a Q&A audit and a real pre-submit screenshot, so Review and Job detail render.
        // Review mode builds its own queue through the script instead.
        switch self {
        case .stress, .firstRunEmpty, .onboarding, .reviewMode: break
        default: MockScripts.addReviewSamples(&data, now: now)
        }
        // Cold outreach on the applied jobs (drafts, a reply, prospects, referrals, employer replies).
        switch self {
        case .stress, .firstRunEmpty, .onboarding: break
        default: MockOutreach.seed(&data, now: now)
        }
        // Requirement evidence on most scores (some keep the older shape without it).
        MockCareer.seedScoreEvidence(&data)

        let submittedToday = data.jobs.filter { $0.submittedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false }.count
        state.caps.dailyUsed = max(state.caps.dailyUsed, submittedToday)
        state.openClusters = MockScripts.baselineClusters(for: data, now: now)
        state.lastRun = data.runs.last.map { r in
            RunInfo(runId: r.runUID, kind: r.kind, trigger: r.trigger, startedAt: r.startedAt, finishedAt: r.finishedAt,
                    outcome: r.outcome, stats: r.stats, tokensIn: r.tokensIn, tokensOut: r.tokensOut)
        }
        return Setup(data: data, state: state)
    }

    var script: [ScriptStep] {
        switch self {
        case .idle, .daemonDown, .firstRunEmpty, .onboarding: []
        case .happyRun: MockScripts.happyRun()
        case .needsYouStorm: MockScripts.needsYouStorm()
        case .reviewMode: MockScripts.reviewMode()
        case .loginExpired: MockScripts.loginExpired()
        case .capReached: MockScripts.capReached()
        case .burstSubmit: MockScripts.burstSubmit()
        case .stress: MockScripts.stress()
        }
    }
}

/// Script builders and scenario data helpers.
enum MockScripts {
    static let happyJobIDs = Array(20_001...20_040)
    static let stormJobIDs = Array(21_001...21_014)
    static let reviewJobIDs = Array(22_001...22_005)
    static let capJobID = 23_001
    static let burstJobIDs = Array(24_001...24_005)

    static let fillSteps = [
        "opened application form", "uploaded Backend.pdf (match 0.91)", "filled 9 standard fields",
        "answering \"Years with Go?\" → \"4\"", "cover letter generated · 212 words", "reviewed answers", "submit",
    ]

    static func nextScheduledRun(after now: Date) -> Date? {
        let cal = Calendar.current
        for dayOffset in 0...1 {
            for hour in [9, 13, 18] {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: now),
                      let slot = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
                if slot > now { return slot }
            }
        }
        return nil
    }

    /// Deterministic job for scripted ids.
    static func scriptedJob(id: Int, now: Date) -> JobItem {
        let companies = MockFixtures.companies
        let company = companies[id % companies.count]
        let title = MockFixtures.titles[(id / 3) % MockFixtures.titles.count]
        let location = MockFixtures.locations[id % MockFixtures.locations.count]
        return MockFixtures.job(id: id, company: company, title: title, location: location, discoveredAt: now)
    }

    static func addJobs(_ data: inout RepositoryData, ids: [Int], state: AppState, now: Date) {
        for id in ids {
            var job = scriptedJob(id: id, now: now.addingTimeInterval(-3_600))
            job.state = state
            job.score = 72 + id % 24
            job.scoreSummary = "Strong match: skills and seniority line up."
            job.resumeVariantID = 1
            data.jobs.append(job)
            data.jobDescriptions[id] = MockFixtures.description(company: job.company, title: job.title)
        }
    }

    static let reviewSampleJobIDs = [25_001, 25_002]

    static func screenshotName(_ applicationID: Int, _ company: String) -> String {
        "\(applicationID)-\(company.lowercased().filter { $0.isLetter || $0.isNumber })-pre"
    }

    /// Two filled applications awaiting review: one clean, one with a low-confidence answer.
    static func addReviewSamples(_ data: inout RepositoryData, now: Date) {
        addJobs(&data, ids: reviewSampleJobIDs, state: .awaitingReview, now: now)
        for (k, id) in reviewSampleJobIDs.enumerated() {
            guard let i = data.jobs.firstIndex(where: { $0.id == id }) else { continue }
            let company = data.jobs[i].company
            let answers = MockFixtures.applicationAnswers(applicationID: id, company: company, lowConfidence: k == 1,
                                                          startID: 90_000 + k * 20)
            data.applicationAnswers[id] = answers
            data.jobs[i].stateReason = "review_mode"
            data.jobs[i].stateUpdatedAt = now.addingTimeInterval(-Double(20 + k * 25) * 60)
            data.jobs[i].resumePickScore = 0.91
            data.jobs[i].screenshotPath = MockFrames.preSubmitScreenshot(company: company, answers: answers, name: screenshotName(id, company))
                ?? "/mock/screenshots/\(id)-pre.png"
            data.activity.append(ActivityEvent(id: (data.activity.last?.id ?? 0) + 1, ts: data.jobs[i].stateUpdatedAt ?? now, kind: "review",
                                               actor: .agent, level: .info, jobID: id, applicationID: id,
                                               message: "filled \(answers.count) fields · waiting for your review"))
        }
    }

    // MARK: Clusters

    struct ClusterTemplate: Sendable {
        var id: String
        var question: String
        var fieldType: FieldType
        var options: [String] = []
        var neverGuessKey: String?
        var reason: QuestionReason
        /// "question" (type an answer) or "action" (the agent is blocked: do it, then retry).
        var kind = "question"
        var actionType: String?
        var variant: @Sendable (String) -> String
    }

    static let clusterTemplates: [ClusterTemplate] = [
        ClusterTemplate(id: "c_why", question: "Why do you want to work here?", fieldType: .textarea, reason: .unknown,
                        variant: { "Why \($0)?" }),
        ClusterTemplate(id: "c_start", question: "Earliest start date?", fieldType: .text, neverGuessKey: "start_date", reason: .neverGuess,
                        variant: { _ in "When can you start?" }),
        ClusterTemplate(id: "c_k8s", question: "Years of Kubernetes experience?", fieldType: .number, reason: .unknown,
                        variant: { _ in "How many years have you used Kubernetes?" }),
        ClusterTemplate(id: "c_pst", question: "Willing to work PST hours?", fieldType: .boolean, options: ["Yes", "No"], reason: .lowConfidence,
                        variant: { _ in "Can you overlap with Pacific time?" }),
        ClusterTemplate(id: "c_portfolio", question: "Portfolio URL?", fieldType: .url, reason: .unknown,
                        variant: { _ in "Link to your portfolio" }),
        ClusterTemplate(id: "c_conflict", question: "Describe a conflict with a teammate and how you resolved it.", fieldType: .textarea,
                        reason: .alwaysAsk, variant: { _ in "Tell us about a disagreement at work." }),
        // Agent blockers (kind "action"): no answer box, "Done, retry" instead.
        ClusterTemplate(id: "a_account", question: "Account required to apply at careers.oraclecloud.com", fieldType: .text,
                        reason: .unknown, kind: "action", actionType: "account", variant: { _ in "Choose Password" }),
        ClusterTemplate(id: "a_captcha", question: "Solve the CAPTCHA on the application", fieldType: .text,
                        reason: .captcha, kind: "action", actionType: "captcha", variant: { "Solve the CAPTCHA on the \($0) application" }),
    ]

    static func cluster(_ t: ClusterTemplate, jobs: [JobItem], now: Date, questionIDBase: Int) -> QuestionCluster {
        QuestionCluster(
            clusterId: t.id, canonicalQuestion: t.question, fieldType: t.fieldType, options: t.options,
            neverGuessKey: t.neverGuessKey, reason: t.reason,
            questionIds: jobs.indices.map { questionIDBase + $0 },
            variants: Array(Set(jobs.map { t.variant($0.company) })).sorted(),
            jobIds: jobs.map(\.id), jobCount: jobs.count,
            companies: Array(Set(jobs.map(\.company))).sorted(),
            createdAt: now.addingTimeInterval(-Double(questionIDBase)),
            kind: t.kind, actionType: t.actionType)
    }

    /// Clusters covering the baseline's parked (needs_you) jobs.
    static func baselineClusters(for data: RepositoryData, now: Date) -> [QuestionCluster] {
        let parked = data.jobs.filter { $0.state == .needsYou }
        guard !parked.isEmpty else { return [] }
        var groups: [Int: [JobItem]] = [:]
        for (i, job) in parked.enumerated() {
            // Skew toward the first templates so impact sorting is visible.
            let t = [0, 0, 0, 6, 1, 1, 2, 3, 7, 4, 5][i % 11]
            groups[t, default: []].append(job)
        }
        return groups.keys.sorted().map { cluster(clusterTemplates[$0], jobs: groups[$0]!, now: now, questionIDBase: 500 + $0 * 50) }
    }

    // MARK: Fill helpers

    /// Fill one queued application: steps with frames, then submit (or park, or wait for review).
    enum FillOutcome { case submit, park(templateIndex: Int), review(lowConfidence: Bool) }

    static func fill(_ world: MockWorld, jobID: Int, index: Int, of total: Int, outcome: FillOutcome, stepDuration: Double = 1.1) async {
        guard let job = world.repository.read({ $0.jobs.first { $0.id == jobID } }), let appID = job.applicationID else { return }
        world.transition(applicationID: appID, to: .filling)
        world.setState(.applying, message: "Filling \(job.company) · \(job.title)", progress: Progress(done: index, total: total),
                       activeApplicationID: appID, activeJobID: jobID)
        let steps = fillSteps
        let lastStep: Int
        switch outcome {
        case .park: lastStep = 3
        case .review: lastStep = 5
        case .submit: lastStep = steps.count - 1
        }
        for i in 0...lastStep {
            await world.sleepRespectingPause(stepDuration)
            if case .park = outcome, i == 3 {
                world.step(applicationID: appID, jobID: jobID, index: i, total: steps.count, action: "answering",
                           detail: "low confidence → asking you", confidence: 0.42, company: job.company, frame: true)
            } else {
                world.step(applicationID: appID, jobID: jobID, index: i, total: steps.count, action: steps[i],
                           confidence: i == 3 ? 0.93 : nil, company: job.company, frame: true)
            }
        }
        switch outcome {
        case .submit:
            world.recordAnswers(applicationID: appID, company: job.company)
            world.transition(applicationID: appID, to: .submitting)
            await world.sleepRespectingPause(0.6)
            world.transition(applicationID: appID, to: .submitted)
            world.log("submitted \(job.company.lowercased())/\(jobID)", jobID: jobID, applicationID: appID, kind: "submit")
        case .park(let t):
            let existing = world.cluster(id: clusterTemplates[t].id)
            var jobs = existing.map { c in c.jobIds.compactMap { id in world.repository.read { $0.jobs.first { $0.id == id } } } } ?? []
            jobs.append(job)
            world.openCluster(cluster(clusterTemplates[t], jobs: jobs, now: Date(), questionIDBase: 900 + t * 50))
            world.transition(applicationID: appID, to: .needsYou, reason: "low_confidence")
        case .review(let low):
            world.recordAnswers(applicationID: appID, company: job.company, lowConfidence: low)
            world.transition(applicationID: appID, to: .awaitingReview, reason: "review_mode")
        }
    }

    // MARK: Scripts

    static func happyRun() -> [ScriptStep] {
        var steps: [ScriptStep] = []
        let ids = happyJobIDs
        steps.append(ScriptStep(at: 0) { world in
            world.startRun(.full, trigger: .scheduled)
            world.setState(.discovering, message: "LinkedIn · 'backend engineer' · page 1", progress: Progress(done: 0, total: 40))
        })
        for (i, id) in ids.enumerated() {
            // Bursty discovery: groups of 5 arrive close together.
            let t = 1.0 + Double(i / 5) * 5.0 + Double(i % 5) * 0.35
            steps.append(ScriptStep(at: t) { world in
                world.discover(scriptedJob(id: id, now: Date()))
                if i % 5 == 4 {
                    world.setState(.discovering, message: "LinkedIn · 'backend engineer' · page \(i / 5 + 2)", progress: Progress(done: i + 1, total: 40))
                }
            })
        }
        steps.append(ScriptStep(at: 42) { world in world.setState(.scoring, progress: Progress(done: 0, total: 40)) })
        steps.append(ScriptStep(at: 42.2) { world in
            world.transition(applicationID: ids[0], to: .failed, reason: "posting_unavailable")
        })
        for i in 1..<40 {
            let id = ids[i]
            let t = 42.5 + Double(i) * 0.95
            steps.append(ScriptStep(at: t) { world in
                switch i {
                case 1: world.score(jobID: id, score: nil, skipReason: "excluded_keyword:crypto")
                case 2: world.score(jobID: id, score: nil, skipReason: "location_mismatch")
                case 3...27: world.score(jobID: id, score: 45 + (i * 7) % 25)
                default: world.score(jobID: id, score: 72 + (i * 5) % 24)
                }
                world.setState(.scoring, progress: Progress(done: i + 1, total: 40))
            })
        }
        // 12 queued (indices 28…39): 9 submit, 2 park, 1 stays queued.
        let plan: [(Int, FillOutcome)] = (28...36).map { ($0, .submit) } + [(37, .park(templateIndex: 3)), (38, .park(templateIndex: 2))]
        let ordered = [plan[0], plan[1], plan[2], plan[9], plan[3], plan[4], plan[5], plan[10], plan[6], plan[7], plan[8]]
        steps.append(ScriptStep(at: 82) { world in
            for (n, item) in ordered.enumerated() {
                await fill(world, jobID: ids[item.0], index: n, of: ordered.count, outcome: item.1)
                await world.sleepRespectingPause(0.6)
            }
            world.setState(.applying, message: "Wrapping up", progress: Progress(done: ordered.count, total: ordered.count))
            await world.sleepRespectingPause(1)
            world.finishRun(.completed)
        })
        return steps
    }

    static func needsYouStorm() -> [ScriptStep] {
        // 14 items → 6 questions + 2 agent actions: 4 + 3 + 2 + 2 + 1 + 1 questions, 1 + 1 actions.
        let assignment = [0, 1, 6, 2, 0, 3, 1, 0, 4, 2, 3, 7, 1, 5]
        var steps: [ScriptStep] = [ScriptStep(at: 0) { world in
            world.startRun(.prep)
            world.setState(.prepping, message: "Collecting questions from 14 queued jobs…", progress: Progress(done: 0, total: 14))
        }]
        for (k, id) in stormJobIDs.enumerated() {
            steps.append(ScriptStep(at: 1 + Double(k) * 1.5) { world in
                guard let job = world.repository.read({ $0.jobs.first { $0.id == id } }), let appID = job.applicationID else { return }
                world.transition(applicationID: appID, to: .prepping)
                let t = assignment[k]
                let template = clusterTemplates[t]
                let existing = world.cluster(id: template.id)
                var jobs = existing.map { c in c.jobIds.compactMap { jid in world.repository.read { $0.jobs.first { $0.id == jid } } } } ?? []
                jobs.append(job)
                world.openCluster(cluster(template, jobs: jobs, now: Date(), questionIDBase: 1_000 + t * 50))
                world.transition(applicationID: appID, to: .needsYou, reason: "unknown_question")
                world.setState(.prepping, message: "Collecting questions from 14 queued jobs… \(k + 1)/14", progress: Progress(done: k + 1, total: 14))
            })
        }
        steps.append(ScriptStep(at: 23) { world in world.finishRun(.completed) })
        return steps
    }

    static func reviewMode() -> [ScriptStep] {
        [ScriptStep(at: 0) { world in
            world.startRun(.apply)
            for (n, id) in reviewJobIDs.enumerated() {
                await fill(world, jobID: id, index: n, of: reviewJobIDs.count, outcome: .review(lowConfidence: n == 2), stepDuration: 0.7)
            }
            world.finishRun(.completed)
        }]
    }

    static func loginExpired() -> [ScriptStep] {
        [ScriptStep(at: 2) { world in
            world.setSource(.linkedin, connected: false, detail: "LinkedIn session expired")
            world.emit(.error(ErrorPayload(code: .unavailable, message: "LinkedIn session expired. Log in again in agent Chrome.",
                                           details: ["source": .string("linkedin")])))
            world.log("LinkedIn session expired", level: .error, kind: "error")
        }]
    }

    static func capReached() -> [ScriptStep] {
        [ScriptStep(at: 0.5) { world in
            world.startRun(.apply)
            await fill(world, jobID: capJobID, index: 0, of: 1, outcome: .submit, stepDuration: 0.6)
            let (used, limit) = world.read { ($0.caps.dailyUsed, $0.caps.dailyLimit) }
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()).flatMap {
                Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0)
            }
            world.emit(.capReached(CapReachedPayload(cap: .daily, used: max(used, limit), limit: limit, resetsAt: tomorrow)))
            world.log("daily cap reached (\(max(used, limit))/\(limit)); resuming tomorrow", level: .warning, kind: "cap")
            world.finishRun(.capReached)
        }]
    }

    static func burstSubmit() -> [ScriptStep] {
        var steps = [ScriptStep(at: 0.5) { world in
            world.startRun(.apply)
            world.setState(.applying, message: "Submitting 5 applications", progress: Progress(done: 0, total: 5))
        }]
        for (k, id) in burstJobIDs.enumerated() {
            steps.append(ScriptStep(at: 1 + Double(k) * 0.4) { world in
                world.recordAnswers(applicationID: id, company: scriptedJob(id: id, now: Date()).company)
                world.transition(applicationID: id, to: .submitting)
                world.transition(applicationID: id, to: .submitted)
            })
        }
        steps.append(ScriptStep(at: 3.5) { world in world.finishRun(.completed) })
        return steps
    }

    /// ~50 events/s until cancelled: discover → score → steps → logs.
    static func stress() -> [ScriptStep] {
        [ScriptStep(at: 0) { world in
            world.startRun(.full)
            var n = 0
            var pendingScore: Int?
            while !Task.isCancelled {
                let id = 30_000 + n
                world.discover(scriptedJob(id: id, now: Date()))
                if let prev = pendingScore { world.score(jobID: prev, score: 40 + (prev * 13) % 60) }
                pendingScore = id
                world.step(applicationID: id, jobID: id, index: n % 7, total: 7, action: fillSteps[n % 7], company: nil, frame: false)
                world.log("stress tick \(n)")
                world.setState(.applying, message: "Stress run", progress: Progress(done: n % 100, total: 100))
                n += 1
                await world.sleep(0.12)
            }
        }]
    }

    /// Short run used for `run_now` and the post-onboarding Prep pass.
    static func miniRun(_ world: MockWorld, kind: RunKind) async {
        world.startRun(kind)
        world.setState(.discovering, message: "Greenhouse · watchlist", progress: Progress(done: 0, total: 5))
        var ids: [Int] = []
        for k in 0..<5 {
            await world.sleepRespectingPause(0.6)
            let id = world.nextJobID()
            ids.append(id)
            world.discover(scriptedJob(id: id, now: Date()))
            world.setState(.discovering, message: "Greenhouse · watchlist", progress: Progress(done: k + 1, total: 5))
        }
        world.setState(.scoring, progress: Progress(done: 0, total: 5))
        for (k, id) in ids.enumerated() {
            await world.sleepRespectingPause(0.4)
            world.score(jobID: id, score: k < 2 ? 84 - k * 6 : 55 + k)
        }
        if kind == .full || kind == .apply {
            for (k, id) in ids.prefix(2).enumerated() {
                await fill(world, jobID: id, index: k, of: 2, outcome: .submit, stepDuration: 0.5)
            }
        }
        world.finishRun(.completed)
    }
}
