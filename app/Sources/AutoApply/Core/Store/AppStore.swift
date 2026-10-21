// AppStore.swift — the root @Observable store (docs/UI_UX_PLAN.md §8.4).
//
//   DaemonConnecting.events ─▶ EventCoalescer (off-main, ≤1 batch/frame) ─▶ apply(batch:)
//   AppRepository streams (SQLite, read-only) ───────────────────────────▶ jobs / library / activity
//
// Socket events drive ephemeral live state and optimistic updates; the DB always wins
// (repository emissions overwrite optimistic edits). Sub-stores are split so a ticker
// update doesn't invalidate charts: views read only the store/properties they render.
import Foundation
import Observation

/// One global issue for the single dashboard banner (§4.4).
struct AppIssue: Identifiable, Sendable, Hashable {
    enum Severity: Sendable { case warning, error }
    enum Fix: Sendable, Hashable {
        case restartDaemon
        case reconnectSource(SourceName)
        case openActivity
        case dismissError
    }

    var id: String
    var severity: Severity
    var message: String
    var fixTitle: String?
    var fix: Fix?
}

/// Compact live status for the Agent Pill (sidebar footer, menu bar, hero compact).
struct AgentStatus: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case loading, disconnected, idle, discovering, scoring, prepping, applying, paused, pausing, resuming, needsYou, capReached, error
    }

    var kind: Kind
    /// "Applying", "Idle", "Paused"…
    var title: String
    /// "3 of 12 today", "next run 14:00"…
    var detail: String?
    /// 0…1 when determinate.
    var progress: Double?

    var isActive: Bool { [.discovering, .scoring, .prepping, .applying].contains(kind) }
    var sentence: String { [title, detail].compactMap { $0 }.joined(separator: " · ") }
}

@MainActor
@Observable
final class AppStore {
    // MARK: Collaborators
    let router: Router
    let toasts: ToastCenter
    let live = LiveRunStore()
    let inbox = InboxStore()
    let jobs = JobsStore()
    let library = LibraryStore()
    let activity = ActivityStore()
    private(set) var stats = DashboardStats()

    @ObservationIgnored private(set) var client: any DaemonConnecting
    @ObservationIgnored private(set) var repository: any AppRepository
    /// Name of the active mock scenario (nil = live daemon).
    private(set) var mockScenarioName: String?

    // MARK: Connection
    private(set) var connection: DaemonConnectionState = .disconnected
    private(set) var hasSnapshot = false
    @ObservationIgnored private var lastAppliedSnapshot: SnapshotPayload?
    private(set) var daemonVersion: String?
    private(set) var lastConnectedAt: Date?
    /// Set when the daemon has been unreachable for > 5 s (hero swaps to the error panel).
    private(set) var isDaemonUnreachable = false

    // MARK: Snapshot-derived settings
    private(set) var preferences = Preferences()
    private(set) var onboarding = OnboardingState()
    private(set) var sources: [SourceName: SourceStatus] = [:]
    private(set) var snapshotCounts = Counts()
    private(set) var snapshotCaps = CapsStatus()
    private(set) var nextRunAt: Date?
    private(set) var dismissedIssueIDs: Set<String> = []

    // MARK: Tasks
    @ObservationIgnored private var coalescer: EventCoalescer?
    @ObservationIgnored private var streamTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var unreachableTask: Task<Void, Never>?
    @ObservationIgnored private var isHealingDaemon = false
    @ObservationIgnored private var lastHealAttempt = Date.distantPast
    @ObservationIgnored private var didReconcileDaemonVersion = false
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isStarted = false

    /// Ack timeout for commands (§8.4 rule 6).
    @ObservationIgnored var commandTimeout: Duration = .seconds(2)
    /// `approve` gets longer: the daemon may be busy starting submissions when it acks.
    @ObservationIgnored var approvalTimeout: Duration = .seconds(5)
    /// The failure of the most recent `perform` (nil after a success) — lets callers such as
    /// onboarding show the daemon's validation message inline.
    @ObservationIgnored var lastCommandError: DaemonClientError?
    /// Delay before the "can't reach autoapplyd" panel replaces stale live state.
    @ObservationIgnored var unreachableDelay: Duration = .seconds(5)
    /// Minimum spacing between stats recomputes.
    @ObservationIgnored var statsDebounce: Duration = .milliseconds(400)

    init(client: any DaemonConnecting, repository: any AppRepository, mockScenarioName: String? = nil,
         router: Router = Router(), toasts: ToastCenter = ToastCenter()) {
        self.client = client
        self.repository = repository
        self.mockScenarioName = mockScenarioName
        self.router = router
        self.toasts = toasts
    }

    // MARK: Lifecycle

    /// Subscribe to the daemon and the DB, then connect. Idempotent.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        let coalescer = EventCoalescer { [weak self] batch in self?.apply(batch: batch) }
        self.coalescer = coalescer
        coalescer.start(client.events)
        subscribeRepository()
        if let observing = client as? any DaemonConnectionObserving {
            let states = observing.connectionStates
            streamTasks.append(Task { [weak self] in
                for await state in states { self?.setConnection(state) }
            })
        }
        // Poll 2 of 2 (documented, Rams audit #9): every 500 ms, drop finished pipeline-flow
        // particles. Pure in-memory bookkeeping, no I/O; it keeps the flow's transition list from
        // growing while the agent runs. (Poll 1 is GRDBRepository's data_version check.)
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.live.pruneTransitions()
            }
        }
        let client = self.client
        streamTasks.append(Task { [weak self] in
            self?.setConnection(.connecting)
            do {
                let snapshot = try await client.connect()
                // The snapshot may also arrive on `events` (before or after this line runs);
                // applying here guarantees it even if a client never echoes it, and
                // `applySnapshot` drops the duplicate copy so it can't clobber state that
                // changed in between (optimistic pause, removed clusters, ticker, ...).
                self?.applySnapshot(snapshot)
                self?.setConnection(.connected)
            } catch {
                let state = await client.connectionState
                self?.setConnection(state.isConnected ? .connected : state)
            }
        })
    }

    func stop() async {
        isStarted = false
        lastAppliedSnapshot = nil
        coalescer?.stop()
        coalescer = nil
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
        pruneTask?.cancel()
        unreachableTask?.cancel()
        statsTask?.cancel()
        await client.disconnect()
    }

    /// Swap the daemon client / repository (Debug ▸ Mock scenario, reconnect to live).
    func replaceBackend(client: any DaemonConnecting, repository: any AppRepository, mockScenarioName: String?) async {
        await stop()
        self.client = client
        self.repository = repository
        self.mockScenarioName = mockScenarioName
        hasSnapshot = false
        lastAppliedSnapshot = nil
        live.isStale = true
        inbox.reset([])
        jobs.replaceAll([])
        activity.apply(ActivityDelta(appended: [], isInitial: true))
        start()
    }

    private func subscribeRepository() {
        let repo = repository
        func pump<T: Sendable>(_ stream: AsyncStream<T>, _ apply: @escaping @MainActor (AppStore, T) -> Void) {
            streamTasks.append(Task { [weak self] in
                for await value in stream {
                    guard let self else { return }
                    apply(self, value)
                }
            })
        }
        pump(repo.jobs()) { store, jobs in
            store.jobs.replaceAll(jobs)
            store.scheduleStats()
        }
        pump(repo.resumeVariants()) { store, v in store.library.resumeVariants = v; store.scheduleStats() }
        pump(repo.stories()) { store, v in store.library.stories = v }
        pump(repo.memoryAnswers()) { store, v in store.library.memoryAnswers = v }
        pump(repo.easyApply()) { store, v in store.library.easyApply = v }
        pump(repo.companySuggestions()) { store, v in store.library.companySuggestions = v }
        pump(repo.profile()) { store, v in store.library.profile = v }
        pump(repo.neverGuess()) { store, v in store.library.neverGuess = v }
        pump(repo.runs(limit: 50)) { store, v in store.library.runs = v }
        pump(repo.activity(initialLimit: activity.maxRows)) { store, delta in store.activity.apply(delta) }
    }

    // MARK: Event reducer

    /// Apply one coalesced batch (one Observation transaction per frame).
    func apply(batch: EventBatch, now: Date = Date()) {
        jobs.performBatch {
            for envelope in batch.envelopes { apply(envelope, now: now) }
        }
        if let frame = batch.frame { live.apply(frame: frame) }
    }

    func apply(_ envelope: EventEnvelope, now: Date = Date()) {
        let event = envelope.event
        if case .snapshot(let snap) = event {
            // Handled entirely by applySnapshot (which de-duplicates the hello echo); the
            // sub-store reducers must not reset on a duplicate copy.
            applySnapshot(snap)
            return
        }
        live.apply(event, replyTo: envelope.replyTo, now: now)
        inbox.apply(event, now: now)
        AppNotifier.shared.handle(event, store: self)
        switch event {
        case .snapshot:
            break // handled above
        case .state(let s):
            if s.paused != live.paused { live.paused = s.paused }
        case .jobDiscovered(let p):
            jobs.applyDiscovered(p.job)
        case .jobScored(let p):
            jobs.applyScored(p)
        case .applicationState(let p):
            jobs.applyState(p)
            scheduleStats()
        case .applicationStatus(let p):
            jobs.applyStatus(p)
            scheduleStats()
        case .sourceStatus(let p):
            sources[p.source.source] = p.source
        case .capReached(let p):
            switch p.cap {
            case .daily: snapshotCaps.dailyUsed = p.used; snapshotCaps.dailyLimit = p.limit
            case .linkedinBudget: snapshotCaps.linkedinSessionsUsed = p.used; snapshotCaps.linkedinSessionsLimit = p.limit
            case .glassdoorBudget: snapshotCaps.glassdoorSessionsUsed = p.used; snapshotCaps.glassdoorSessionsLimit = p.limit
            case .companyCooldown: snapshotCaps.companiesCoolingDown = max(snapshotCaps.companiesCoolingDown, 1)
            case .googleBudget: break  // Google Jobs sessions: shown in the activity log only
            case .outreachDaily: snapshotCaps.outreachSentToday = p.used; snapshotCaps.outreachDailyLimit = p.limit
            }
        case .runFinished:
            scheduleStats()
        default:
            break
        }
    }

    /// Apply a hello snapshot. The same snapshot can reach the store twice (the `connect()`
    /// return value and the broadcast copy on `events`, in either order); an identical copy
    /// of the last applied snapshot is ignored so it cannot roll back state that moved on.
    /// A reconnect yields a fresh snapshot, which is applied in full.
    func applySnapshot(_ snap: SnapshotPayload) {
        if hasSnapshot, snap == lastAppliedSnapshot { return }
        lastAppliedSnapshot = snap
        live.reset(from: snap)
        inbox.reset(snap.openClusters)
        hasSnapshot = true
        daemonVersion = snap.daemonVersion
        reconcileDaemonVersion(snap.daemonVersion)
        preferences = snap.preferences
        preferences.mode = snap.mode
        onboarding = snap.onboarding
        sources = Dictionary(snap.sources.map { ($0.source, $0) }, uniquingKeysWith: { _, b in b })
        snapshotCounts = snap.counts
        snapshotCaps = snap.caps
        nextRunAt = snap.nextRunAt
    }

    private func setConnection(_ state: DaemonConnectionState) {
        guard connection != state else { return }
        connection = state
        if state.isConnected {
            lastConnectedAt = Date()
            live.isStale = false
            isDaemonUnreachable = false
            unreachableTask?.cancel()
            unreachableTask = nil
        } else {
            live.isStale = true
            if unreachableTask == nil && !isDaemonUnreachable {
                let delay = unreachableDelay
                unreachableTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self, !self.connection.isConnected else { return }
                    self.isDaemonUnreachable = true
                    self.unreachableTask = nil
                    await self.selfHealDaemon()
                }
            }
        }
    }

    /// A daemon on a different version than this app is left over from before an update (or its
    /// re-install failed): move it onto this build, once per launch. Real .app builds only.
    private func reconcileDaemonVersion(_ version: String) {
        guard mockScenarioName == nil, !didReconcileDaemonVersion, Bundle.main.bundleURL.pathExtension == "app",
              version != AppInfo.version else { return }
        didReconcileDaemonVersion = true
        Task { [weak self] in
            self?.toasts.show("Updating the agent to v\(AppInfo.version)…", symbol: "arrow.triangle.2.circlepath", style: .info, duration: .seconds(3))
            await DaemonControl.refreshAfterUpdate(force: true)
        }
    }

    /// Try to bring a down daemon back on its own (install/start the LaunchAgent), at most once per
    /// 60 s, and never against a mock backend. The banner's "Restart daemon" stays as the manual path.
    private func selfHealDaemon() async {
        guard mockScenarioName == nil, !isHealingDaemon, Date().timeIntervalSince(lastHealAttempt) > 60 else { return }
        isHealingDaemon = true
        lastHealAttempt = Date()
        defer { isHealingDaemon = false }
        toasts.show("Agent stopped. Restarting it…", symbol: "arrow.clockwise", style: .info, duration: .seconds(3))
        let ok = await DaemonControl.ensureRunning()
        if ok {
            toasts.show("Agent is back.", symbol: "checkmark.circle.fill", style: .info, duration: .seconds(2))
        }
    }

    private func scheduleStats() {
        guard statsTask == nil else { return }
        let delay = statsDebounce
        statsTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.statsTask = nil
            self.recomputeStats()
        }
    }

    /// Recompute dashboard aggregates now (normally debounced automatically).
    func recomputeStats(now: Date = Date()) {
        let jobs = self.jobs.all
        let variants = library.resumeVariants
        stats = StatsCalculator.compute(jobs: jobs, variants: variants, now: now)
    }

    // MARK: Derived state

    var mode: Mode { preferences.mode }
    var isPaused: Bool { live.paused }
    var isConnected: Bool { connection.isConnected }

    /// Badge/hero counters: derived from the DB when loaded (self-consistent with live
    /// updates), otherwise the snapshot's.
    var counts: Counts {
        guard jobs.isLoaded else {
            var c = snapshotCounts
            c.needsYouClusters = inbox.openCount
            return c
        }
        let today = Date()
        var c = Counts()
        c.queued = jobs.count(.queued)
        c.needsYouClusters = inbox.openCount
        c.needsYouJobs = jobs.count(.needsYou)
        c.awaitingReview = jobs.count(.awaitingReview)
        c.easyApplyOpen = library.easyApplyOpenCount
        c.unknownVerify = jobs.count(.unknownVerify)
        c.failed = jobs.count(.failed)
        c.submittedToday = stats.computedAt == .distantPast ? jobs.submittedCount(on: today) : stats.appliedToday
        c.discoveredToday = stats.computedAt == .distantPast ? jobs.discoveredCount(on: today) : stats.discoveredToday
        c.submittedTotal = jobs.count(.submitted)
        return c
    }

    var caps: CapsStatus {
        var c = snapshotCaps
        c.dailyLimit = preferences.dailyCap
        if jobs.isLoaded { c.dailyUsed = max(c.dailyUsed, counts.submittedToday) }
        return c
    }

    var needsOnboarding: Bool { hasSnapshot && !onboarding.completed }

    /// Title for the active job (hero / menu bar), falling back to the daemon's message.
    var activeJobTitle: String? {
        if let id = live.activeJobID, let job = jobs.job(id: id) { return job.displayName }
        return live.message
    }

    var agentStatus: AgentStatus {
        if !hasSnapshot && !isDaemonUnreachable && !connection.isConnected {
            if case .failed = connection { return AgentStatus(kind: .disconnected, title: "Can't reach the agent") }
            return AgentStatus(kind: .loading, title: "Connecting…")
        }
        if !connection.isConnected && (isDaemonUnreachable || hasSnapshot) {
            return AgentStatus(kind: .disconnected, title: "Can't reach the agent",
                               detail: lastConnectedAt.map { "last seen \($0.formatted(date: .omitted, time: .shortened))" })
        }
        if live.pauseRequest == .pausing { return AgentStatus(kind: .pausing, title: "Pausing…") }
        if live.pauseRequest == .resuming { return AgentStatus(kind: .resuming, title: "Resuming…") }
        if live.paused { return AgentStatus(kind: .paused, title: "Paused") }
        let progress = live.progress.map { $0.total > 0 ? Double($0.done) / Double($0.total) : 0 }
        let progressText = live.progress.map { "\($0.done) of \($0.total)" }
        switch live.activity {
        case .discovering:
            return AgentStatus(kind: .discovering, title: "Discovering", detail: live.message ?? progressText, progress: progress)
        case .scoring:
            return AgentStatus(kind: .scoring, title: "Scoring", detail: progressText, progress: progress)
        case .prepping:
            return AgentStatus(kind: .prepping, title: "Collecting questions", detail: progressText, progress: progress)
        case .applying:
            let c = caps
            return AgentStatus(kind: .applying, title: "Applying",
                               detail: "\(c.dailyUsed) of \(c.dailyLimit) today",
                               progress: c.dailyLimit > 0 ? min(1, Double(c.dailyUsed) / Double(c.dailyLimit)) : progress)
        case .idle:
            if let cap = live.capReached, cap.cap == .daily {
                return AgentStatus(kind: .capReached, title: "Done for today", detail: "\(cap.used)/\(cap.limit) · daily limit reached")
            }
            if live.lastError != nil {
                return AgentStatus(kind: .error, title: "Needs attention", detail: live.lastError?.message)
            }
            if inbox.openCount > 0 {
                return AgentStatus(kind: .needsYou, title: "Needs You", detail: inbox.summary)
            }
            return AgentStatus(kind: .idle, title: "Idle", detail: nextRunAt.map { "next run \($0.formatted(date: .omitted, time: .shortened))" })
        }
    }

    /// Global issues for the single banner (never more than one shown; "2 issues · View").
    var issues: [AppIssue] {
        var out: [AppIssue] = []
        if isDaemonUnreachable {
            out.append(AppIssue(id: "daemon_down", severity: .error, message: "Can't reach the agent.",
                                fixTitle: "Restart agent", fix: .restartDaemon))
        }
        for source in [SourceName.linkedin, .glassdoor] {
            if let s = sources[source], s.enabled, !s.connected, s.checkedAt != nil {
                let name = source == .linkedin ? "LinkedIn" : "Glassdoor"
                out.append(AppIssue(id: "source_\(source.rawValue)", severity: .warning,
                                    message: s.detail ?? "\(name) session expired.",
                                    fixTitle: "Reconnect", fix: .reconnectSource(source)))
            }
        }
        if let error = live.lastError, !isDaemonUnreachable {
            out.append(AppIssue(id: "error_\(error.code.rawValue)", severity: error.code == .unavailable ? .warning : .error,
                                message: error.message, fixTitle: "View log", fix: .openActivity))
        }
        return out.filter { !dismissedIssueIDs.contains($0.id) }
    }

    func dismissIssue(_ id: String) {
        dismissedIssueIDs.insert(id)
        if id.hasPrefix("error_") { live.clearError() ; dismissedIssueIDs.remove(id) }
    }

    /// Effective mode for a job: per-job override > per-company > per-ATS > global.
    func effectiveMode(for job: JobItem) -> Mode {
        if let m = job.modeOverride { return m }
        if let m = preferences.perCompanyMode[String(job.companyID)] { return m }
        if let m = preferences.perAtsMode[job.ats.rawValue] { return m }
        return preferences.mode
    }

    // MARK: Test/Preview hooks

    /// Seed preferences directly (previews, onboarding drafts after an ack).
    func setPreferences(_ prefs: Preferences) { preferences = prefs }
    func setOnboarding(_ state: OnboardingState) { onboarding = state }
}
