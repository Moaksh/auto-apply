// LiveRunStore.swift — ephemeral live state driven by the socket: what the agent is doing
// right now (hero card, sidebar Agent Pill, menu bar). Never persisted; replaced wholesale
// by each `snapshot`.
import Foundation
import Observation

/// One line of the hero's step ticker.
struct TickerStep: Identifiable, Sendable, Hashable {
    var id: String { "\(applicationID)-\(index)" }
    var applicationID: Int
    var jobID: Int
    var index: Int
    var total: Int?
    var action: String
    var detail: String?
    var confidence: Double?
    var at: Date

    var isLowConfidence: Bool { (confidence ?? 1) < 0.6 }
}

/// A job moving between pipeline-flow stages (particles are derived from these; §8.4 rule 4).
struct StageTransition: Identifiable, Sendable, Hashable {
    let id: UUID
    var jobID: Int
    /// nil = appeared (a newly discovered job).
    var from: FlowStage?
    var to: FlowStage
    var start: Date

    init(jobID: Int, from: FlowStage?, to: FlowStage, start: Date) {
        self.id = UUID()
        self.jobID = jobID
        self.from = from
        self.to = to
        self.start = start
    }
}

/// Immutable value handed to the pipeline Canvas.
struct FlowSnapshot: Sendable, Hashable {
    var counts: RunStats
    var transitions: [StageTransition]
    var activeJobID: Int?
}

@MainActor
@Observable
final class LiveRunStore {
    static let maxTransitions = 60
    static let transitionLifetime: TimeInterval = 1.0
    static let maxTickerSteps = 5
    static let maxLiveLog = 500

    enum PauseRequest: Equatable, Sendable { case pausing, resuming }

    private(set) var activity: DaemonActivity = .idle
    var paused = false
    /// Optimistic pause/resume in flight (pill shows "Pausing…").
    var pauseRequest: PauseRequest?
    private(set) var progress: Progress?
    private(set) var message: String?
    private(set) var runID: String?
    private(set) var activeApplicationID: Int?
    private(set) var activeJobID: Int?
    /// When the active application started (hero elapsed timer).
    private(set) var activeSince: Date?
    private(set) var currentRun: RunInfo?
    private(set) var lastRun: RunInfo?
    /// Live counts for the current run (pipeline flow nodes).
    private(set) var runCounts = RunStats()
    private(set) var ticker: [TickerStep] = []
    private(set) var frame: DecodedFrame?
    /// Last frame of the most recently submitted application ("Last: Ramp · 13:58").
    private(set) var lastSubmittedFrame: DecodedFrame?
    private(set) var transitions: [StageTransition] = []
    /// Monotonic counter of submissions seen live (celebrations key off changes).
    private(set) var submittedEventCount = 0
    private(set) var lastSubmittedAt: Date?
    private(set) var capReached: CapReachedPayload?
    /// Most recent unsolicited daemon error (login expired, CAPTCHA, crash in a run).
    private(set) var lastError: ErrorPayload?
    private(set) var lastErrorAt: Date?
    private(set) var liveLog: [LogPayload] = []
    /// True while disconnected: the hero greys out rather than showing stale data as live.
    var isStale = true

    init() {}

    var isRunning: Bool { activity != .idle && !paused }

    var flowSnapshot: FlowSnapshot {
        FlowSnapshot(counts: runCounts, transitions: transitions, activeJobID: activeJobID)
    }

    var stepProgress: (index: Int, total: Int)? {
        guard let last = ticker.last, let total = last.total else { return nil }
        return (last.index + 1, total)
    }

    // MARK: Reducer

    func reset(from snapshot: SnapshotPayload, now: Date = Date()) {
        apply(state: snapshot.state, now: now)
        currentRun = snapshot.currentRun
        lastRun = snapshot.lastRun
        runCounts = snapshot.currentRun?.stats ?? snapshot.lastRun?.stats ?? RunStats()
        transitions = []
        ticker = []
        pauseRequest = nil
        capReached = nil
        isStale = false
    }

    func apply(state s: StatePayload, now: Date = Date()) {
        // The preview shows a live browser page; phases without a browser (scoring) must not keep
        // showing the last page from an earlier phase.
        if s.daemon != activity && (s.daemon == .scoring || s.daemon == .prepping) { frame = nil }
        activity = s.daemon
        paused = s.paused
        if pauseRequest == .pausing && s.paused { pauseRequest = nil }
        if pauseRequest == .resuming && !s.paused { pauseRequest = nil }
        progress = s.progress
        message = s.message
        runID = s.runId
        if s.activeApplicationId != activeApplicationID {
            activeApplicationID = s.activeApplicationId
            activeSince = s.activeApplicationId == nil ? nil : now
            ticker = ticker.filter { $0.applicationID == s.activeApplicationId }
            if s.activeApplicationId != nil, frame?.applicationID != s.activeApplicationId {
                frame = nil
            }
        }
        activeJobID = s.activeJobId
    }

    func apply(_ event: DaemonEvent, replyTo: String?, now: Date = Date()) {
        switch event {
        case .snapshot(let snap):
            reset(from: snap, now: now)
        case .state(let s):
            apply(state: s, now: now)
        case .runStarted(let p):
            frame = nil
            currentRun = p.run
            runID = p.run.runId
            runCounts = p.run.stats
            transitions = []
            capReached = nil
        case .runFinished(let p):
            lastRun = p.run
            if currentRun?.runId == p.run.runId || currentRun == nil { currentRun = nil }
            runCounts = p.run.stats
        case .jobDiscovered(let p):
            runCounts.discovered += 1
            addTransition(StageTransition(jobID: p.job.id, from: nil, to: .discovered, start: now))
        case .applicationState(let p):
            applyTransition(p, now: now)
        case .agentStep(let step):
            applyStep(step)
        case .capReached(let p):
            capReached = p
        case .error(let p) where replyTo == nil:
            lastError = p
            lastErrorAt = now
        case .log(let p):
            liveLog.append(p)
            if liveLog.count > Self.maxLiveLog { liveLog.removeFirst(liveLog.count - Self.maxLiveLog) }
        default:
            break
        }
    }

    func apply(frame newFrame: DecodedFrame) {
        frame = newFrame
    }

    func clearError() {
        lastError = nil
        lastErrorAt = nil
    }

    /// Drop transitions whose particle animation has finished.
    func pruneTransitions(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.transitionLifetime)
        if transitions.contains(where: { $0.start < cutoff }) {
            transitions.removeAll { $0.start < cutoff }
        }
    }

    private func applyTransition(_ p: ApplicationStatePayload, now: Date) {
        switch p.toState {
        case .scored: runCounts.scored += 1
        case .skipped: runCounts.skipped += 1
        case .queued where p.fromState == .scored || p.fromState == .skipped: runCounts.queued += 1
        case .needsYou: runCounts.needsYou += 1
        case .awaitingReview: runCounts.awaitingReview += 1
        case .submitted:
            runCounts.submitted += 1
            submittedEventCount += 1
            lastSubmittedAt = p.at
            if let frame, frame.applicationID == p.applicationId { lastSubmittedFrame = frame }
        case .failed: runCounts.failed += 1
        default: break
        }
        let from = p.fromState?.flowStage
        let to = p.toState.flowStage
        if from != to {
            addTransition(StageTransition(jobID: p.jobId, from: from, to: to, start: now))
        }
    }

    private func applyStep(_ step: AgentStepPayload) {
        if let active = activeApplicationID, active != step.applicationId { return }
        if activeApplicationID == nil {
            activeApplicationID = step.applicationId
            activeJobID = step.jobId
            activeSince = step.at
        }
        let line = TickerStep(applicationID: step.applicationId, jobID: step.jobId, index: step.index, total: step.total,
                              action: step.action, detail: step.detail, confidence: step.confidence, at: step.at)
        if let i = ticker.firstIndex(where: { $0.id == line.id }) {
            ticker[i] = line
        } else {
            ticker.append(line)
            if ticker.count > Self.maxTickerSteps { ticker.removeFirst(ticker.count - Self.maxTickerSteps) }
        }
    }

    private func addTransition(_ t: StageTransition) {
        transitions.append(t)
        if transitions.count > Self.maxTransitions { transitions.removeFirst(transitions.count - Self.maxTransitions) }
    }
}
