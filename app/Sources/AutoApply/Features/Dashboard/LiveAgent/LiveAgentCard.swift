// LiveAgentCard.swift — the signature widget (§4.3 W2): status line, pipeline flow, live
// Chrome thumbnail and step ticker, with every hero state (idle, discovering, scoring,
// filling, paused, cap reached, unreachable, loading, first run).
import SwiftUI

struct LiveAgentCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var layout: DashboardLayout = .wide
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
            HStack {
                Text("Live agent").eyebrowStyle()
                Spacer()
            }
            switch state {
            case .unreachable(let lastSeen):
                unreachablePanel(lastSeen: lastSeen)
            default:
                statusLine(state)
                    .id(verb)
                    .transition(reduced ? AnyTransition.opacity : AnyTransition(.blurReplace))
                flow(state)
                    .frame(height: 150)
                if state == .firstRun {
                    firstRunMessage
                } else if state != .loading {
                    lowerRow(state)
                }
            }
        }
        .padding(Space.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { meshBackground(isRunning: state.isRunning) }
        .surfaceCard()
        .saturation(state == .paused ? 0.6 : 1)
        .overlay {
            if state == .paused {
                PausedCapsule { Task { await store.resume() } }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            SubmittedCheck(trigger: celebrationTrigger)
                .opacity(celebrationTrigger == 0 ? 0 : 1)
                .padding(Space.s)
                .allowsHitTesting(false)
        }
        .motion(Motion.snappy, value: verb)
        .onChange(of: store.live.submittedEventCount) { old, new in
            guard new > old else { return }
            let now = Date()
            if celebrationGate.shouldFire(at: now) { celebrationTrigger += 1 }
            if announcer.shouldAnnounce(at: now) {
                let company = store.live.lastSubmittedFrame.flatMap { store.jobs.job(id: $0.jobID)?.company } ?? activeJob?.company
                AccessibilityNotification.Announcement(company.map { "Submitted to \($0)" } ?? "Application submitted").post()
            }
        }
    }

    // MARK: Status line

    private func statusLine(_ state: HeroState) -> some View {
        HStack(spacing: Space.s) {
            AgentStatusDot(kind: store.agentStatus.kind, size: 10)
            Text(verb.rawValue).font(Typography.title2)
            if case .capReached(let used, let limit) = state {
                Text("· \(used)/\(limit) · resumes tomorrow\(store.nextRunAt.map { " " + $0.formatted(date: .omitted, time: .shortened) } ?? "")")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary)
                Image(systemName: "moon.zzz").symbolEffect(.breathe, options: .repeating, isActive: !reduced)
                    .foregroundStyle(Palette.textTertiary)
            } else if state == .idle, let next = store.nextRunAt {
                Text("· next run \(next.formatted(date: .omitted, time: .shortened))")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary)
                Image(systemName: "clock").symbolEffect(.breathe, options: .repeating, isActive: !reduced)
                    .foregroundStyle(Palette.textTertiary)
            }
            if state.isRunning, let job = activeJob {
                Text("·").foregroundStyle(Palette.textTertiary)
                Button { router.openJobFromDashboard(job.id) } label: {
                    Text(job.displayName).font(Typography.body).lineLimit(1)
                }
                .buttonStyle(.link)
                .help("Open job detail")
            } else if state.isRunning, let message = store.live.message {
                Text("· \(message)").font(Typography.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            if state.isRunning, store.live.runCounts.needsYou > 0 {
                Label("\(store.live.runCounts.needsYou) parked", systemImage: StatusKind.needsYou.symbol)
                    .font(Typography.callout)
                    .padding(.horizontal, Space.s).padding(.vertical, 2)
                    .background(Palette.needsYou.opacity(0.12), in: Capsule())
                    .foregroundStyle(Palette.textPrimary)
            }
            if let since = store.live.activeSince, state.isRunning {
                TimelineView(.periodic(from: since, by: 1)) { timeline in
                    Text(DashboardFormat.elapsed(timeline.date.timeIntervalSince(since)))
                        .font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                }
                .accessibilityLabel("Elapsed")
            }
            heroButton(state)
        }
    }

    @ViewBuilder
    private func heroButton(_ state: HeroState) -> some View {
        switch state {
        case .idle, .capReached:
            HStack(spacing: Space.s) {
                if store.queuedCount > 0 {
                    Button { Task { await store.applyQueued() } } label: {
                        Label("Apply \(store.queuedCount) queued", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.glass)
                    .disabled(!store.isConnected)
                    .help("Fill and submit just the queued jobs, no new search (\(AppShortcut.applyQueued.displayString))")
                }
                Button { Task { await store.runNow() } } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(.glassProminent)
                    .disabled(!store.isConnected)
                    .help("Run now: search, score and apply (\(AppShortcut.runNow.displayString))")
            }
        case .discovering, .scoring, .prepping, .filling:
            Button {
                Haptics.levelChange()
                Task { await store.pauseAll() }
            } label: {
                Image(systemName: "pause.fill").contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .help("Pause agent (\(AppShortcut.togglePause.displayString))")
            .accessibilityLabel("Pause agent")
        default:
            EmptyView()
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
        if layout == .wide {
            HStack(alignment: .top, spacing: Space.xl) {
                thumb.frame(width: 360)
                ticker.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
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
            description = "Last submitted page"
        }
        return LiveBrowserThumb(frame: frame, isLive: live, atsLabel: live ? job?.ats.label : nil, caption: caption,
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

    private var firstRunMessage: some View {
        HStack(spacing: Space.s) {
            Text("Your agent hasn't run yet.").font(Typography.body)
            Button("Run a Prep pass") { Task { await store.runPrepPass() } }.buttonStyle(.link)
            Text("to collect questions first, or").font(Typography.body).foregroundStyle(Palette.textSecondary)
            Button("Run now") { Task { await store.runNow() } }.buttonStyle(.link)
        }
        .disabled(!store.isConnected)
    }

    private func unreachablePanel(lastSeen: Date?) -> some View {
        ErrorState(title: "Can't reach autoapplyd",
                   message: lastSeen.map { "Last seen \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "The background agent isn't responding.",
                   actionTitle: "Restart daemon",
                   action: { Task { await store.fix(AppIssue(id: "daemon_down", severity: .error, message: "", fix: .restartDaemon)) } },
                   secondaryTitle: "View log",
                   secondaryAction: { DaemonControl.openLogs() })
            .frame(minHeight: 220)
    }

    // MARK: Background

    /// Accent mesh gradient (0–10% opacity) that slowly shifts only while running.
    @ViewBuilder
    private func meshBackground(isRunning: Bool) -> some View {
        if !reduceTransparency {
            let animate = isRunning && !reduced && isWindowVisible
            TimelineView(.animation(minimumInterval: 1 / 15, paused: !animate)) { timeline in
                let t = animate ? timeline.date.timeIntervalSinceReferenceDate / 6 : 0
                let wobble = Float(sin(t) * 0.08)
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5 + wobble, 0], [1, 0],
                    [0, 0.5 - wobble], [0.5 - wobble, 0.5 + wobble], [1, 0.5 + wobble],
                    [0, 1], [0.5 + wobble, 1], [1, 1],
                ], colors: [
                    Palette.accent.opacity(0.08), .clear, Palette.accent.opacity(0.04),
                    .clear, Palette.accent.opacity(isRunning ? 0.10 : 0.03), .clear,
                    Palette.accent.opacity(0.03), .clear, Palette.accent.opacity(0.06),
                ])
            }
            .clipShape(.card)
            .allowsHitTesting(false)
        }
    }
}

extension Router {
    /// Dashboard → Job detail: show it on top of Pipeline so ⌘←/⌘→ and the inspector work.
    func openJobFromDashboard(_ id: Int) {
        selection = .pipeline
        openJob(id: id)
    }
}
