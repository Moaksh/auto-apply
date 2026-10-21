// LiveAgentCard.swift — what the agent is doing: a status line, the pipeline flow, the live
// Chrome view and the steps, for every state (idle, discovering, scoring, filling, paused, daily
// limit, unreachable, loading, first run). A flat surface: no gradient, nothing breathing. The
// flow only moves while the agent works and the window is visible. Run lives in the toolbar;
// the card offers it only before the very first run.
import SwiftUI

struct LiveAgentCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced

    var isWindowVisible: Bool = true

    @State private var announcer = AnnouncementThrottle()
    @State private var celebrationGate = CelebrationGate()
    @State private var celebrationTrigger = 0

    private var heroState: HeroState {
        let caps = store.caps
        return HeroState.resolve(.init(
            hasSnapshot: store.hasSnapshot, isConnected: store.isConnected, isUnreachable: store.isDaemonUnreachable,
            lastSeen: store.lastConnectedAt, paused: store.isPaused, activity: store.live.activity,
            hasAnyJobs: !store.jobs.all.isEmpty, hasLastRun: store.live.lastRun != nil, capReached: store.live.capReached,
            dailyUsed: caps.dailyUsed, dailyLimit: caps.dailyLimit))
    }

    private var activeJob: JobItem? { store.live.activeJobID.flatMap { store.jobs.job(id: $0) } }

    private var verb: HeroVerb {
        HeroVerb.resolve(state: heroState, activeJobState: activeJob?.state, lastStepAction: store.live.ticker.last?.action,
                         openClusters: store.inbox.openCount, hasError: store.live.lastError != nil)
    }

    var body: some View {
        let state = heroState
        VStack(alignment: .leading, spacing: Space.l) {
            SectionHeader("Live agent")
            switch state {
            case .unreachable(let lastSeen):
                unreachablePanel(lastSeen: lastSeen)
            case .firstRun:
                firstRunPanel
            default:
                statusLine(state)
                flow(state)
                    .frame(height: 150)
                if state != .loading {
                    lowerRow(state)
                }
            }
        }
        .padding(Space.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .overlay {
            if state == .paused {
                PausedBar { Task { await store.resume() } }
            }
        }
        .overlay(alignment: .topTrailing) {
            SubmittedCheck(trigger: celebrationTrigger)
                .opacity(celebrationTrigger == 0 ? 0 : 1)
                .padding(Space.s)
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

    // MARK: Status line

    private func statusLine(_ state: HeroState) -> some View {
        HStack(spacing: Space.s) {
            AgentStatusDot(kind: store.agentStatus.kind, size: 10)
            Text(verb.rawValue).font(Typography.title2)
            if case .capReached(let used, let limit) = state {
                Text("· \(used)/\(limit) today · daily limit reached\(store.nextRunAt.map { ", next run " + $0.formatted(date: .omitted, time: .shortened) } ?? "")")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary)
            } else if state == .idle, let next = store.nextRunAt {
                Text("· next run \(next.formatted(date: .omitted, time: .shortened))")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary)
            }
            if state.isRunning, let job = activeJob {
                Text("·").foregroundStyle(Palette.textTertiary)
                Button { router.openJobFromDashboard(job.id) } label: {
                    Text(job.displayName).font(Typography.body).lineLimit(1)
                }
                .buttonStyle(.secondaryLink)
                .help("Open job detail")
            } else if state.isRunning, let message = store.live.message {
                Text("· \(message)").font(Typography.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            if state.isRunning, store.live.runCounts.needsYou > 0 {
                Badge("\(store.live.runCounts.needsYou) waiting for you", symbol: StatusKind.needsYou.symbol, tone: .warning)
            }
            if let since = store.live.activeSince, state.isRunning {
                TimelineView(.periodic(from: since, by: 1)) { timeline in
                    Text(DashboardFormat.elapsed(timeline.date.timeIntervalSince(since)))
                        .font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                }
                .accessibilityLabel("Elapsed")
            }
        }
    }

    // MARK: Flow

    private func flow(_ state: HeroState) -> some View {
        PipelineFlowView(
            snapshot: store.live.flowSnapshot,
            isRunning: state.isRunning,
            isIdle: !state.isRunning,
            isSkeleton: state == .loading,
            threshold: store.preferences.matchThreshold,
            verb: verb.rawValue,
            isVisible: isWindowVisible,
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

    @ViewBuilder
    private func lowerRow(_ state: HeroState) -> some View {
        let thumb = thumbnail(state)
        let ticker = StepTicker(steps: store.live.ticker, isActive: state == .filling, fallbackLines: fallbackLines(state))
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.xl) {
                thumb.frame(width: 360)
                ticker.frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Space.l) {
                thumb.frame(maxWidth: 360)
                ticker
            }
        }
    }

    private func thumbnail(_ state: HeroState) -> some View {
        let live = state == .filling && store.live.frame != nil
        let frame = live ? store.live.frame : (store.live.lastSubmittedFrame ?? store.live.frame)
        var caption: String?
        if !live, let last = store.live.lastSubmittedFrame, let job = store.jobs.job(id: last.jobID) {
            caption = "Last: \(job.company) · \(last.receivedAt.formatted(date: .omitted, time: .shortened))"
        }
        let job = activeJob
        var description = "Live view of Chrome"
        if let job, live {
            description += ", \(job.company) application"
            if let p = store.live.stepProgress { description += ", step \(p.index) of \(p.total)" }
        } else if caption != nil {
            description = "Last page the agent applied on"
        }
        return LiveBrowserThumb(frame: frame, isLive: live, siteLabel: live ? job?.ats.label : nil, caption: caption,
                                accessibilityDescription: description) {
            Task { await store.openAgentChrome() }
        }
    }

    private func fallbackLines(_ state: HeroState) -> [String] {
        let log = store.live.liveLog.suffix(StepTicker.visibleLines).map(\.message)
        switch state {
        case .discovering, .scoring, .prepping:
            if !log.isEmpty { return Array(log) }
            return [store.live.message ?? "\(verb.rawValue)…"]
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
    }

    private func unreachablePanel(lastSeen: Date?) -> some View {
        ErrorState(title: "Can't reach the agent",
                   message: lastSeen.map { "Last seen \($0.formatted(date: .abbreviated, time: .shortened)). It runs in the background on this Mac." }
                       ?? "The agent runs in the background on this Mac and isn't responding.",
                   actionTitle: "Restart agent",
                   action: { Task { await store.fix(AppIssue(id: "daemon_down", severity: .error, message: "", fix: .restartDaemon)) } },
                   secondaryTitle: "View log",
                   secondaryAction: { DaemonControl.openLogs() })
            .frame(minHeight: 220)
    }
}

extension Router {
    /// Dashboard → Job detail: show it on top of Pipeline so ⌘←/⌘→ and the details panel work.
    func openJobFromDashboard(_ id: Int) {
        selection = .pipeline
        openJob(id: id)
    }
}
