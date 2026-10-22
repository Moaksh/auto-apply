// LiveAgentCard.swift — what the agent is doing, drawn on the Dashboard hero's brand field: a
// glass status capsule (breathing orb, verb, detail), the glowing pipeline flow, then two glass
// panels that change with the state (idle, discovering, scoring, filling, paused, daily limit,
// unreachable, loading, first run). It never shows an empty box: idle shows the countdown to the
// next run and today's numbers; working shows the live count or the live Chrome view and the
// steps. Run lives in the toolbar; the card offers it only before the very first run.
import SwiftUI

extension AppStore {
    /// The hero state (shared by the hero band and the live agent).
    var heroState: HeroState {
        let caps = caps
        return HeroState.resolve(.init(
            hasSnapshot: hasSnapshot, isConnected: isConnected, isUnreachable: isDaemonUnreachable,
            lastSeen: lastConnectedAt, paused: isPaused, activity: live.activity,
            hasAnyJobs: !jobs.all.isEmpty, hasLastRun: live.lastRun != nil, capReached: live.capReached,
            dailyUsed: caps.dailyUsed, dailyLimit: caps.dailyLimit))
    }

    var heroActiveJob: JobItem? { live.activeJobID.flatMap { jobs.job(id: $0) } }

    var heroVerb: HeroVerb {
        HeroVerb.resolve(state: heroState, activeJobState: heroActiveJob?.state, lastStepAction: live.ticker.last?.action,
                         openClusters: inbox.openCount, hasError: live.lastError != nil)
    }
}

struct LiveAgentCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced

    var isWindowVisible: Bool = true

    @State private var announcer = AnnouncementThrottle()
    @State private var celebrationGate = CelebrationGate()
    @State private var celebrationTrigger = 0

    private var activeJob: JobItem? { store.heroActiveJob }

    var body: some View {
        let state = store.heroState
        let verb = store.heroVerb
        GlassEffectContainer(spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.l) {
                switch state {
                case .unreachable(let lastSeen):
                    unreachablePanel(lastSeen: lastSeen)
                case .firstRun:
                    firstRunPanel
                default:
                    statusCapsule(state, verb: verb)
                    flow(state, verb: verb)
                        .frame(height: 150)
                    if state != .loading {
                        lowerRow(state, verb: verb)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            if state == .paused {
                PausedBar { Task { await store.resume() } }
            }
        }
        .overlay(alignment: .topTrailing) {
            ZStack {
                RadialBurst(trigger: celebrationTrigger, color: Palette.applied, radius: 46)
                    .frame(width: 120, height: 120)
                SubmittedCheck(trigger: celebrationTrigger)
                    .opacity(celebrationTrigger == 0 ? 0 : 1)
            }
            .offset(x: 24, y: -36)
            .allowsHitTesting(false)
        }
        .onChange(of: store.live.submittedEventCount) { old, new in
            guard new > old else { return }
            let now = Date()
            if celebrationGate.shouldFire(at: now) { celebrationTrigger += 1 }
            if announcer.shouldAnnounce(at: now) {
                let company = store.live.lastSubmittedFrame.flatMap { store.jobs.job(id: $0.jobID)?.company } ?? activeJob?.company
                AccessibilityNotification.Announcement(company.map { "Applied to \($0)" } ?? "Application sent").post()
            }
        }
    }

    // MARK: Status capsule

    private func orbColor(_ state: HeroState, verb: HeroVerb) -> Color {
        if state.isRunning { return Palette.Brand.signal }
        switch verb {
        case .needsYou: return Palette.Brand.coral
        case .error: return Palette.error
        case .paused, .doneForToday, .connecting: return Color.white.opacity(0.55)
        default: return Palette.Brand.signal.opacity(0.8)
        }
    }

    private func statusCapsule(_ state: HeroState, verb: HeroVerb) -> some View {
        let tint: Color? = state.isRunning ? Palette.Brand.signal : (verb == .needsYou ? Palette.Brand.coral : nil)
        return HStack(spacing: Space.s) {
            HeroStatusOrb(color: orbColor(state, verb: verb), isWorking: state.isRunning)
            Text(verb.rawValue)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .id(verb)
                .transition(reduced ? AnyTransition.opacity : AnyTransition(.blurReplace))
            detail(state)
            Spacer(minLength: Space.s)
            trailing(state, verb: verb)
        }
        .padding(.leading, Space.s)
        .padding(.trailing, Space.l)
        .padding(.vertical, Space.s)
        .heroGlass(in: Capsule(), tint: tint)
        .motion(Motion.snappy, value: verb)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func detail(_ state: HeroState) -> some View {
        if case .capReached(let used, let limit) = state {
            Text("· \(used)/\(limit) today · daily limit reached")
                .font(Typography.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
        } else if state.isRunning, let job = activeJob {
            Text("·").foregroundStyle(Palette.textTertiary)
            Button { router.openJobFromDashboard(job.id) } label: {
                Text(job.displayName).font(Typography.body).lineLimit(1)
            }
            .buttonStyle(.secondaryLink)
            .help("Open job detail")
        } else if state.isRunning, let message = store.live.message {
            Text("· \(message)").font(Typography.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
                .contentTransition(.interpolate)
        }
    }

    @ViewBuilder
    private func trailing(_ state: HeroState, verb: HeroVerb) -> some View {
        if state.isRunning {
            if store.live.runCounts.needsYou > 0 {
                Badge("\(store.live.runCounts.needsYou) waiting for you", symbol: StatusKind.needsYou.symbol, tone: .warning)
            }
            if let since = store.live.activeSince {
                TimelineView(.periodic(from: since, by: 1)) { timeline in
                    Text(DashboardFormat.elapsed(timeline.date.timeIntervalSince(since)))
                        .font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                }
                .accessibilityLabel("Elapsed")
            }
        } else if verb == .needsYou {
            let open = store.inbox.openCount
            Button { router.go(.needsYou) } label: {
                HStack(spacing: Space.xs) {
                    Text("Answer \(open)")
                    Image(systemName: "arrow.right").imageScale(.small)
                }
                .font(Typography.bodyEmph)
                .foregroundStyle(Palette.Brand.coral)
            }
            .buttonStyle(.plain)
            .help("Open Needs You")
        }
    }

    // MARK: Flow

    private func flow(_ state: HeroState, verb: HeroVerb) -> some View {
        PipelineFlowView(
            snapshot: store.live.flowSnapshot,
            isRunning: state.isRunning,
            isIdle: !state.isRunning,
            isSkeleton: state == .loading,
            threshold: store.preferences.matchThreshold,
            verb: verb.rawValue,
            isVisible: isWindowVisible,
            onBrand: true,
            focus: HeroFocus.stage(for: state),
            onSelectStage: { stage in
                if let filter = FlowNavigation.pipelineFilter(for: stage) {
                    router.showPipeline(filter: filter)
                } else {
                    router.go(.needsYou)
                }
            },
            jobsAtStage: { stage in FlowNavigation.jobs(at: stage, in: store.jobs.all) })
    }

    // MARK: Lower row

    private func lowerRow(_ state: HeroState, verb: HeroVerb) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.l) {
                leading(state, verb: verb).frame(width: 400)
                trailingPanel(state).frame(minWidth: 320, maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.l) {
                leading(state, verb: verb)
                trailingPanel(state)
            }
        }
    }

    @ViewBuilder
    private func leading(_ state: HeroState, verb: HeroVerb) -> some View {
        let counts = store.live.runCounts
        switch state {
        case .filling:
            if store.live.frame != nil {
                thumbnail()
                    .heroPanel(tint: Palette.Brand.signal, padding: Space.s)
            } else {
                HeroRunPulsePanel(eyebrow: "Opening the application", value: counts.submitted, unit: "applied this run",
                                  since: store.live.activeSince, message: activeJob.map { "\($0.company) · \($0.ats.label)" })
            }
        case .discovering:
            HeroRunPulsePanel(eyebrow: "Discovering", value: counts.discovered, unit: "found this run", since: store.live.currentRun?.startedAt,
                              message: store.live.message)
        case .scoring:
            HeroRunPulsePanel(eyebrow: "Scoring", value: counts.scored, unit: "scored this run", since: store.live.currentRun?.startedAt,
                              message: store.live.message)
        case .prepping:
            HeroRunPulsePanel(eyebrow: "Collecting questions", value: counts.needsYou, unit: "questions for you", since: store.live.currentRun?.startedAt,
                              message: store.live.message)
        case .capReached(let used, let limit):
            nextRunPanel(.doneForToday(used: used, limit: limit))
        case .paused:
            nextRunPanel(.paused)
        default:
            nextRunPanel(verb == .needsYou ? .needsYou : .idle)
        }
    }

    private func nextRunPanel(_ kind: HeroNextRunPanel.Kind) -> some View {
        HeroNextRunPanel(kind: kind, nextRun: store.nextRunAt,
                         since: store.live.lastRun.flatMap { $0.finishedAt ?? $0.startedAt },
                         mode: store.mode)
    }

    @ViewBuilder
    private func trailingPanel(_ state: HeroState) -> some View {
        if state.isRunning {
            StepTicker(steps: store.live.ticker, isActive: state == .filling, fallbackLines: fallbackLines(state))
                .heroPanel()
        } else {
            todayPanel
        }
    }

    private var todayPanel: some View {
        let counts = store.counts
        return HeroTodayPanel(applied: counts.submittedToday, found: counts.discoveredToday,
                              needYou: store.inbox.openCount, queued: counts.queued,
                              lastApplied: lastAppliedToday, lastFrame: store.live.lastSubmittedFrame,
                              onOpenLast: { router.openJobFromDashboard($0) })
    }

    /// The most recent application sent today (DB-backed, so it survives a relaunch).
    private var lastAppliedToday: HeroTodayPanel.LastApplied? {
        let calendar = Calendar.current
        let now = Date()
        var best: (JobItem, Date)?
        for job in store.jobs.all where job.state == .submitted {
            guard let at = job.submittedAt ?? job.stateUpdatedAt, calendar.isDate(at, inSameDayAs: now) else { continue }
            if best == nil || at > best!.1 { best = (job, at) }
        }
        return best.map { .init(jobID: $0.0.id, company: $0.0.company, title: $0.0.title, at: $0.1) }
    }

    private func thumbnail() -> some View {
        let frame = store.live.frame
        let job = activeJob
        var description = "Live view of Chrome"
        if let job {
            description += ", \(job.company) application"
            if let p = store.live.stepProgress { description += ", step \(p.index) of \(p.total)" }
        }
        return LiveBrowserThumb(frame: frame, isLive: true, siteLabel: job?.ats.label, caption: nil,
                                accessibilityDescription: description) {
            Task { await store.openAgentChrome() }
        }
    }

    private func fallbackLines(_ state: HeroState) -> [String] {
        let log = store.live.liveLog.suffix(StepTicker.visibleLines).map(\.message)
        switch state {
        case .discovering, .scoring, .prepping:
            if !log.isEmpty { return Array(log) }
            return [store.live.message ?? "\(store.heroVerb.rawValue)…"]
        default:
            return Array(log)
        }
    }

    /// Before the very first run: the dashboard's one primary action.
    private var firstRunPanel: some View {
        VStack(spacing: 0) {
            EmptyState(symbol: "play.circle", title: "Your agent hasn't run yet",
                       message: "It finds jobs that match your preferences, scores them, and fills in applications. "
                           + "Questions only you can answer wait in Needs You.",
                       actionTitle: store.isConnected ? "Run now" : nil, isPrimary: true) {
                Task { await store.runNow() }
            }
            if store.isConnected {
                Button("Or collect questions first, without applying") { Task { await store.runPrepPass() } }
                    .buttonStyle(.secondaryLink)
                    .font(Typography.callout)
                    .padding(.bottom, Space.l)
            }
        }
        .frame(maxWidth: .infinity)
        .heroGlass(in: HeroPanel.shape)
    }

    private func unreachablePanel(lastSeen: Date?) -> some View {
        ErrorState(title: "Can't reach the agent",
                   message: lastSeen.map { "Last seen \($0.formatted(date: .abbreviated, time: .shortened)). It runs in the background on this Mac." }
                       ?? "The agent runs in the background on this Mac and isn't responding.",
                   actionTitle: "Restart agent",
                   action: { Task { await store.fix(AppIssue(id: "daemon_down", severity: .error, message: "", fix: .restartDaemon)) } },
                   secondaryTitle: "View log",
                   secondaryAction: { DaemonControl.openLogs() })
            .frame(maxWidth: .infinity, minHeight: 220)
            .heroGlass(in: HeroPanel.shape)
    }
}

extension Router {
    /// Dashboard → Job detail: show it on top of Pipeline so ⌘←/⌘→ and the details panel work.
    func openJobFromDashboard(_ id: Int) {
        selection = .pipeline
        openJob(id: id)
    }
}
