// MockWorld.swift — the simulated daemon: live state + the in-memory "DB". Every helper
// mutates the repository the way autoapplyd would write SQLite AND broadcasts the matching
// protocol event, so mock mode exercises exactly the same store paths as the real daemon.
import Foundation
import Synchronization

final class MockWorld: Sendable {
    struct State: Sendable {
        var daemon = StatePayload(daemon: .idle)
        var preferences = Preferences()
        var onboarding = OnboardingState(completed: true, step: 7)
        var sources: [SourceStatus] = MockWorld.defaultSources
        var caps = CapsStatus(dailyUsed: 0, dailyLimit: 15, companiesCoolingDown: 2, linkedinSessionsUsed: 1,
                              linkedinSessionsLimit: 3, glassdoorSessionsUsed: 0, glassdoorSessionsLimit: 3,
                              outreachSentToday: 1, outreachDailyLimit: 10, peopleFinderUsed: 2, peopleFinderLimit: 6)
        var openClusters: [QuestionCluster] = []
        var currentRun: RunInfo?
        var lastRun: RunInfo?
        var nextRunAt: Date?
        var nextJobID = 10_000
        var nextQuestionID = 1
        var nextMemoryID = 1_000
        var nextStoryID = 1_000
        var nextResumeID = 100
        var nextAnswerRowID = 100_000
        var runCounter = 0
        /// Interview prep packs, the writing voice and the insights summary (MockCareer).
        var career = MockCareer.State()
        /// Sample mode: jobs found on demand (Run now) come from the sample's Indian companies.
        var usesSamplePool = false
    }

    /// A deterministic job for `id` from this world's company pool.
    func scriptedJob(id: Int, now: Date = Date()) -> JobItem {
        read { $0.usesSamplePool } ? MockSample.job(id: id, now: now) : MockScripts.scriptedJob(id: id, now: now)
    }

    static let defaultSources: [SourceStatus] = [
        SourceStatus(source: .greenhouse, enabled: true, connected: true),
        SourceStatus(source: .lever, enabled: true, connected: true),
        SourceStatus(source: .ashby, enabled: true, connected: true),
        SourceStatus(source: .careers, enabled: true, connected: true),
        SourceStatus(source: .linkedin, enabled: true, connected: true, checkedAt: Date(), detail: "Session valid"),
        SourceStatus(source: .glassdoor, enabled: false, connected: false),
    ]

    let repository: InMemoryRepository
    let speed: Double
    private let state: Mutex<State>
    private let emitter: EventBroadcaster<EventEnvelope>

    init(repository: InMemoryRepository, state: State, speed: Double, emitter: EventBroadcaster<EventEnvelope>) {
        self.repository = repository
        self.state = Mutex(state)
        self.speed = max(0.01, speed)
        self.emitter = emitter
    }

    // MARK: State access

    func read<T: Sendable>(_ body: (State) -> T) -> T { state.withLock { body($0) } }
    func mutate(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }

    var isPaused: Bool { read { $0.daemon.paused } }
    var isRunning: Bool { read { $0.daemon.daemon != .idle } }

    /// Sleep `seconds` of scenario time (scaled by speed).
    func sleep(_ seconds: Double) async {
        let ns = UInt64(max(0, seconds / speed) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }

    /// Sleep scenario time, but only advance while not paused (kill switch honored).
    func sleepRespectingPause(_ seconds: Double) async {
        var remaining = seconds
        while remaining > 0 && !Task.isCancelled {
            let chunk = min(remaining, 0.05 * speed)
            await sleep(chunk)
            if !isPaused { remaining -= chunk }
        }
    }

    func emit(_ event: DaemonEvent, replyTo: String? = nil) {
        emitter.yield(EventEnvelope(replyTo: replyTo, event: event))
    }

    // MARK: Snapshot

    func snapshot() -> SnapshotPayload {
        let s = read { $0 }
        return SnapshotPayload(
            protocolVersion: 1, daemonVersion: "0.1.0-mock", state: s.daemon, mode: s.preferences.mode,
            nextRunAt: s.nextRunAt, currentRun: s.currentRun, lastRun: s.lastRun, counts: counts(caps: s.caps),
            caps: s.caps, openClusters: InboxStore.sorted(s.openClusters), sources: s.sources,
            onboarding: s.onboarding, preferences: s.preferences)
    }

    func counts(caps: CapsStatus) -> Counts {
        repository.read { data in
            var c = Counts()
            let cal = Calendar.current
            let now = Date()
            for job in data.jobs {
                switch job.state {
                case .queued: c.queued += 1
                case .needsYou: c.needsYouJobs += 1
                case .awaitingReview: c.awaitingReview += 1
                case .unknownVerify: c.unknownVerify += 1
                case .failed: c.failed += 1
                case .submitted:
                    c.submittedTotal += 1
                    if let s = job.submittedAt, cal.isDate(s, inSameDayAs: now) { c.submittedToday += 1 }
                default: break
                }
                if cal.isDate(job.discoveredAt, inSameDayAs: now) { c.discoveredToday += 1 }
            }
            c.easyApplyOpen = data.easyApply.filter { $0.isOpen && !$0.opened }.count
            c.needsYouClusters = read { $0.openClusters.count }
            let live = Set(data.outreach.threads.filter { $0.state != .cancelled }.map(\.id))
            c.outreachDrafts = data.outreach.messages.filter { !$0.isInbound && $0.state == .draft && live.contains($0.threadID) }.count
            c.outreachRepliesUnread = data.outreach.threads.filter(\.unreadReply).count
            c.outreachUnknown = data.outreach.messages.filter { $0.state == .unknown }.count
            c.applicationRepliesUnread = data.applicationReplies.filter(\.isPendingSuggestion).count
            return c
        }
    }

    // MARK: Daemon state

    func setState(_ activity: DaemonActivity, message: String? = nil, progress: Progress? = nil,
                  activeApplicationID: Int? = nil, activeJobID: Int? = nil) {
        let payload: StatePayload = state.withLock { st in
            st.daemon.daemon = activity
            st.daemon.message = message
            st.daemon.progress = progress
            st.daemon.activeApplicationId = activeApplicationID
            st.daemon.activeJobId = activeJobID
            st.daemon.runId = st.currentRun?.runId
            return st.daemon
        }
        emit(.state(payload))
    }

    func setPaused(_ paused: Bool) {
        let payload: StatePayload = state.withLock { st in
            st.daemon.paused = paused
            return st.daemon
        }
        emit(.state(payload))
        repository.update { $0.log("user", paused ? "paused agent" : "resumed agent", actor: .user) }
    }

    @discardableResult
    func startRun(_ kind: RunKind, trigger: RunTrigger = .manual) -> RunInfo {
        let run: RunInfo = state.withLock { st in
            st.runCounter += 1
            let run = RunInfo(runId: String(format: "mockrun%04d", st.runCounter), kind: kind, trigger: trigger, startedAt: Date())
            st.currentRun = run
            st.daemon.runId = run.runId
            return run
        }
        emit(.runStarted(RunStartedPayload(run: run)))
        repository.update { $0.log("run", "\(kind.rawValue) run started (\(trigger.rawValue))") }
        return run
    }

    func bumpRunStat(_ body: (inout RunStats) -> Void) {
        state.withLock { st in
            if var run = st.currentRun {
                body(&run.stats)
                st.currentRun = run
            }
        }
    }

    func finishRun(_ outcome: RunOutcome = .completed) {
        let run: RunInfo? = state.withLock { st in
            guard var run = st.currentRun else { return nil }
            run.finishedAt = Date()
            run.outcome = outcome
            run.tokensIn = 84_000
            run.tokensOut = 11_200
            st.lastRun = run
            st.currentRun = nil
            st.daemon.runId = nil
            return run
        }
        guard let run else { return }
        emit(.runFinished(RunFinishedPayload(run: run)))
        repository.update { data in
            data.runs.append(RunItem(id: (data.runs.map(\.id).max() ?? 0) + 1, runUID: run.runId, kind: run.kind, trigger: run.trigger,
                                     startedAt: run.startedAt, finishedAt: run.finishedAt, outcome: run.outcome, stats: run.stats,
                                     tokensIn: run.tokensIn, tokensOut: run.tokensOut))
            data.log("run", "run finished · \(run.stats.submitted) applied, \(run.stats.needsYou) need you, \(run.stats.skipped) skipped")
        }
        setState(.idle)
    }

    func log(_ message: String, level: LogLevel = .info, jobID: Int? = nil, applicationID: Int? = nil, kind: String = "log") {
        emit(.log(LogPayload(level: level, message: message, logger: "autoapply.mock", jobId: jobID, applicationId: applicationID, at: Date())))
        repository.update { $0.log(kind, message, level: level, jobID: jobID, applicationID: applicationID) }
    }

    // MARK: Jobs

    func nextJobID() -> Int {
        state.withLock { st in
            st.nextJobID += 1
            return st.nextJobID
        }
    }

    /// Persist a discovered job and broadcast `job_discovered` + `application_state`.
    func discover(_ job: JobItem) {
        var job = job
        job.state = .discovered
        job.stateUpdatedAt = Date()
        let j = job
        repository.update { data in
            data.jobs.append(j)
            data.jobDescriptions[j.id] = MockFixtures.description(company: j.company, title: j.title)
            data.log("discover", "found \(j.title) via \(j.source.label)", jobID: j.id, applicationID: j.applicationID)
        }
        bumpRunStat { $0.discovered += 1 }
        emit(.jobDiscovered(JobDiscoveredPayload(
            job: JobSummary(id: j.id, applicationId: j.applicationID, companyId: j.companyID, company: j.company, title: j.title,
                            location: j.location, remote: j.remote, source: j.source, ats: j.ats, applyUrl: j.applyURL,
                            sourceUrl: j.sourceURL, easyApply: j.easyApply, salaryMin: j.salaryMin, salaryMax: j.salaryMax,
                            salaryCurrency: j.salaryCurrency, discoveredAt: j.discoveredAt),
            runId: read { $0.currentRun?.runId })))
    }

    /// Apply a state-machine transition (validated like `db.transition`).
    @discardableResult
    func transition(applicationID: Int, to target: AppState, reason: String? = nil, actor: Actor = .agent) -> Bool {
        let now = Date()
        let result: (from: AppState, jobID: Int)? = repository.update { data in
            guard let i = data.jobIndex(applicationID: applicationID) else { return nil }
            let from = data.jobs[i].state
            guard from.canTransition(to: target, actor: actor) else { return nil }
            data.jobs[i].state = target
            data.jobs[i].stateReason = reason
            data.jobs[i].stateUpdatedAt = now
            if target == .submitted {
                data.jobs[i].submittedAt = now
                data.jobs[i].status = .applied
                data.jobs[i].statusUpdatedAt = now
                data.jobs[i].mode = data.jobs[i].mode ?? .auto
            }
            let job = data.jobs[i]
            data.log("state", "\(job.company.lowercased())/\(job.id) \(from.rawValue) → \(target.rawValue)\(reason.map { " (\($0))" } ?? "")",
                     actor: actor, jobID: job.id, applicationID: applicationID)
            return (from, job.id)
        }
        guard let result else { return false }
        switch target {
        case .scored: bumpRunStat { $0.scored += 1 }
        case .skipped: bumpRunStat { $0.skipped += 1 }
        case .queued where result.from == .scored: bumpRunStat { $0.queued += 1 }
        case .needsYou: bumpRunStat { $0.needsYou += 1 }
        case .awaitingReview: bumpRunStat { $0.awaitingReview += 1 }
        case .submitted:
            bumpRunStat { $0.submitted += 1 }
            mutate { $0.caps.dailyUsed += 1 }
        case .failed: bumpRunStat { $0.failed += 1 }
        default: break
        }
        emit(.applicationState(ApplicationStatePayload(applicationId: applicationID, jobId: result.jobID, fromState: result.from,
                                                       toState: target, reason: reason, actor: actor, at: now)))
        return true
    }

    /// Score a discovered job; below threshold (or hard filter) → skipped, else → queued.
    func score(jobID: Int, score: Int?, skipReason: String? = nil) {
        let threshold = read { $0.preferences.matchThreshold }
        let queued = skipReason == nil && (score ?? 0) >= threshold
        let reason = skipReason ?? (queued ? nil : "below_threshold")
        let appID: Int? = repository.update { data in
            guard let i = data.jobIndex(jobID: jobID) else { return nil }
            data.jobs[i].score = score
            data.jobs[i].skipReason = reason
            data.jobs[i].scoredAt = Date()
            if let score {
                data.jobs[i].scoreSummary = queued ? "Strong match: skills and seniority line up." : "Below your threshold of \(threshold)."
                data.jobs[i].scoreFactors = ["skills": min(100, score + 4), "seniority": max(0, score - 6), "location": 100,
                                             "salary": 70, "domain": min(100, score + 1)]
            }
            return data.jobs[i].applicationID
        }
        guard let appID else { return }
        var reasons: [String: JSONValue] = [:]
        if let score { reasons = ["summary": .string(queued ? "Strong match" : "Below threshold"), "factors": .object(["skills": .int(min(100, score + 4))])] }
        emit(.jobScored(JobScoredPayload(jobId: jobID, applicationId: appID, score: score, reasons: reasons, skipReason: reason,
                                         queued: queued, runId: read { $0.currentRun?.runId })))
        if score == nil {
            transition(applicationID: appID, to: .skipped, reason: reason)
        } else {
            transition(applicationID: appID, to: .scored)
            transition(applicationID: appID, to: queued ? .queued : .skipped, reason: queued ? nil : reason)
        }
    }

    func step(applicationID: Int, jobID: Int, index: Int, total: Int, action: String, detail: String? = nil,
              confidence: Double? = nil, company: String? = nil, frame: Bool = false) {
        let thumb = frame ? company.flatMap { MockFrames.frame(company: $0, step: index, total: total) } : nil
        emit(.agentStep(AgentStepPayload(applicationId: applicationID, jobId: jobID, runId: read { $0.currentRun?.runId },
                                         index: index, total: total, action: action, detail: detail, confidence: confidence,
                                         screenshotThumb: thumb, at: Date())))
    }

    /// Record the Q&A audit for an application (before submit / review).
    func recordAnswers(applicationID: Int, company: String, lowConfidence: Bool = false) {
        let startID: Int = state.withLock { st in
            let id = st.nextAnswerRowID
            st.nextAnswerRowID += 20
            return id
        }
        // Answers come from whoever the dataset's person is (the sample persona in sample mode).
        let (profile, facts) = repository.read { ($0.profile, $0.neverGuess) }
        let answers = MockFixtures.applicationAnswers(applicationID: applicationID, company: company, lowConfidence: lowConfidence,
                                                      startID: startID, profile: profile, neverGuess: facts)
        let shot = MockFrames.preSubmitScreenshot(company: company, answers: answers, name: MockScripts.screenshotName(applicationID, company))
            ?? "/mock/screenshots/\(applicationID)-pre.png"
        repository.update { data in
            data.applicationAnswers[applicationID] = answers
            if let i = data.jobIndex(applicationID: applicationID) {
                data.jobs[i].resumeVariantID = data.jobs[i].resumeVariantID ?? 1
                data.jobs[i].resumePickScore = 0.91
                data.jobs[i].screenshotPath = shot
            }
        }
    }

    // MARK: Inbox

    func openCluster(_ cluster: QuestionCluster) {
        mutate { st in
            if let i = st.openClusters.firstIndex(where: { $0.clusterId == cluster.clusterId }) {
                st.openClusters[i] = cluster
            } else {
                st.openClusters.append(cluster)
            }
        }
        emit(.questionOpened(QuestionOpenedPayload(cluster: cluster)))
    }

    func cluster(id: String) -> QuestionCluster? { read { $0.openClusters.first { $0.clusterId == id } } }

    /// Close a cluster; answered → parked jobs re-queue, skipped → parked jobs are skipped.
    @discardableResult
    func resolveCluster(id: String, status: QuestionResolvedPayload.Status, answerID: Int? = nil) -> [Int] {
        guard let cluster = cluster(id: id) else { return [] }
        mutate { $0.openClusters.removeAll { $0.clusterId == id } }
        let stillBlocked = Set(read { $0.openClusters.flatMap(\.jobIds) })
        let appIDs: [Int] = repository.read { data in
            cluster.jobIds.compactMap { jid in data.jobs.first { $0.id == jid && $0.state == .needsYou }?.applicationID }
        }
        var affected: [Int] = []
        for appID in appIDs {
            let jobID = repository.read { $0.jobs.first { $0.applicationID == appID }?.id } ?? appID
            if status == .answered && stillBlocked.contains(jobID) { continue }
            if transition(applicationID: appID, to: status == .answered ? .queued : .skipped,
                          reason: status == .answered ? "answered" : "user_skipped_question", actor: .user) {
                affected.append(appID)
            }
        }
        emit(.questionResolved(QuestionResolvedPayload(clusterId: id, status: status, answerId: answerID, resumedApplicationIds: status == .answered ? affected : [])))
        return affected
    }

    func setSource(_ source: SourceName, connected: Bool, detail: String?) {
        let status: SourceStatus = state.withLock { st in
            var s = st.sources.first { $0.source == source } ?? SourceStatus(source: source)
            s.enabled = true
            s.connected = connected
            s.checkedAt = Date()
            s.detail = detail
            st.sources.removeAll { $0.source == source }
            st.sources.append(s)
            return s
        }
        emit(.sourceStatus(SourceStatusPayload(source: status)))
    }
}
