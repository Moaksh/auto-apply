// ReviewView.swift — Review: approve applications before they're sent. List (flagged first) on
// the left, screenshot + every answer side by side on the right with hover-linked field
// highlights and inline ✎ edits. One primary action: Approve & send (this job, or the floating
// glass bulk bar when several are ticked; never both at once). The low-confidence safeguard and
// skip reasons ask inline. Approving starts the send hold: the row shows "Sending in 5…" with
// Undo (⌘Z) and nothing goes to the agent until the window closes. Keys: ↑↓/J K focus,
// X select, ⌘A select all, A approve, S skip, F next flagged answer, Space Quick Look, ⌘Z undo.
// Approve style (Settings ▸ General): Ticket (default) prints the focused job as a ticket whose
// stub you tear to approve (ReviewTicket.swift; also ⌘↵); Classic is the button, as it was.
import QuickLook
import SwiftUI

@objc(ReviewFeature)
final class ReviewFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.review) { ReviewQueueView() }
    }
}

struct ReviewQueueView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @Environment(\.undoManager) private var undoManager
    @FocusState private var listFocused: Bool
    @State private var quickLookURL: URL?
    @Namespace private var selectionNS
    @AppStorage(ApproveStyle.storageKey) private var storedStyle = ApproveStyle.ticket
    @Environment(\.approveStyleOverride) private var styleOverride

    private var model: ReviewModel { ReviewModel.shared(for: store) }
    private var style: ApproveStyle { styleOverride ?? storedStyle }

    var body: some View {
        let model = self.model
        let queue = model.queue
        VStack(spacing: 0) {
            header(model, count: queue.count)
            Divider()
            if !store.hasSnapshot && store.isDaemonUnreachable {
                ErrorState(title: "Can't reach the agent", message: "Applications to review show here once the agent is running.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.hasSnapshot || !store.jobs.isLoaded {
                LoadingState(message: "Loading applications…")
            } else if queue.isEmpty {
                EmptyState(symbol: "checkmark.rectangle.stack", title: "Nothing to review",
                           message: store.mode == .review
                               ? "Filled applications wait here for your OK before they're sent."
                               : "You're in Auto mode. Applications wait here only for sites, companies or jobs you set to Review.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list(model, queue: queue)
                        .frame(width: 320)
                    Divider()
                    Group {
                        if let job = model.focusedJob {
                            ReviewDetail(model: model, job: job, style: style, quickLookURL: $quickLookURL)
                                .id(job.id)
                                .transition(.opacity)
                        } else {
                            EmptyState(symbol: "rectangle.on.rectangle", title: "Select an application")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    // Ticket: the next ticket cross-fades in while the torn one leaves (live at once).
                    .motion(Motion.exit, value: style == .ticket ? model.focusedJobID : nil)
                }
            }
        }
        .background(Palette.windowBackground)
        .overlay(alignment: .bottom) { bar(model) }
        .quickLookPreview($quickLookURL)
        .task { model.syncSubscriptions() }
        .onChange(of: store.jobs.revision) { model.syncSubscriptions() }
        .onChange(of: model.sendHold.lastUndo) { _, event in if let event { model.didUndo(event.jobIDs) } }
    }

    // MARK: Header

    private func header(_ model: ReviewModel, count: Int) -> some View {
        // Jobs the agent can't send yet (their company) aren't "ready": they're waiting.
        let waiting = model.queue.filter { model.isBlocked($0.id) }.count
        return ScreenHeader("Review", summary: "\(count - waiting) ready\(waiting > 0 ? " · \(waiting) waiting" : "") · \(model.modeSummary)") {
            if count > 1 {
                Text(model.selection.isEmpty ? "Tick jobs to approve several at once" : "\(model.selection.count) of \(count) selected")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            if count > 0 {
                Button {
                    if model.selection.count == count { model.clearSelection() } else { model.selectAll() }
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: model.selection.count == count ? "checkmark.square.fill" : "square")
                        Text("Select all")
                        KeyCap("⌘A")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: List

    private func list(_ model: ReviewModel, queue: [JobItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(queue) { job in
                        ReviewRow(model: model, job: job, style: style,
                                  isFocused: job.id == model.focusedJobID,
                                  isSelected: model.selection.contains(job.id),
                                  hold: model.sendHold.entry(for: job.id),
                                  notSent: model.sendHold.wasNotSent(job.id))
                            .id(job.id)
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.command) {
                                    model.toggleSelection(job.id)
                                } else {
                                    model.focusedJobID = job.id
                                }
                                listFocused = true
                            }
                            // Arrives with a rise; an approved row leaves off to the right once its hold sends.
                            .transition(.reduced(.asymmetric(insertion: .rise, removal: .slideIn(from: .trailing)), reduced))
                    }
                }
                .padding(Space.s)
                .padding(.bottom, Space.xxxl * 2)
                // The focus highlight travels from row to row.
                .selectionHighlightGroup(selectionNS, selection: model.focusedJobID)
                .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: queue.map(\.id))
            }
            .focusable()
            // The selected row / card shows keyboard focus; the system ring would outline the whole pane.
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { model.moveFocus(by: 1); return .handled }
            .onKeyPress(.upArrow) { model.moveFocus(by: -1); return .handled }
            .onKeyPress("j") { model.moveFocus(by: 1); return .handled }
            .onKeyPress("k") { model.moveFocus(by: -1); return .handled }
            .onShortcut(.toggleSelection) { model.toggleFocusedSelection() }
            .onShortcut(.selectAll) { model.selectAll() }
            .onShortcut(.approve) { approveKey(model) }
            // ⌘↵ tears the focused ticket (Classic keeps A only).
            .onShortcut(.submit) {
                guard style == .ticket, let id = model.focusedJobID else { return }
                model.tear(jobID: id, undoManager: undoManager)
            }
            .onShortcut(.skip) { model.requestSkip() }
            .onKeyPress("f", phases: .down) { press in
                guard press.modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { return .ignored }
                model.jumpToNextFlagged()
                return .handled
            }
            .onShortcut(.quickLook) { quickLookURL = model.focusedJob.flatMap { LocalFiles.existing($0.screenshotPath) } }
            .onKeyPress(.escape) {
                if model.barMode != .actions { model.cancelBar(); return .handled }
                if !model.selection.isEmpty { model.clearSelection(); return .handled }
                return .ignored
            }
            .onChange(of: model.focusedJobID) { _, id in
                if let id { withMotion(Motion.snappy, reduceMotion: reduced) { proxy.scrollTo(id) } }
            }
            .onAppear { listFocused = true }
        }
    }

    /// A: in ticket style with nothing ticked, tear the focused ticket (a ticket held for your
    /// answer keeps the classic "Approve anyway?" question, the deliberate override). Otherwise
    /// the classic approve of the selection / focused row.
    private func approveKey(_ model: ReviewModel) {
        if style == .ticket, model.selection.isEmpty, let job = model.focusedJob, !model.needsLook(job) {
            model.tear(jobID: job.id, undoManager: undoManager)
        } else {
            model.requestApprove(undoManager: undoManager)
        }
    }

    // MARK: Floating bar

    @ViewBuilder
    private func bar(_ model: ReviewModel) -> some View {
        let showing = !model.selection.isEmpty || model.barMode != .actions
        ZStack {
            if showing {
                BulkActionBar(selectionCount: barCount(model), actions: barActions(model),
                              onClear: { model.clearSelection() }) {
                    barAccessory(model)
                }
                .transition(.reduced(.slideIn(from: .bottom), reduced))
            }
        }
        .padding(.bottom, Space.xl)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: showing)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: model.barMode)
    }

    /// The jobs the bar is about: the ones a confirm / skip prompt is asking about, else the selection.
    private func barCount(_ model: ReviewModel) -> Int {
        switch model.barMode {
        case .confirmFlagged(let t), .confirmAllFlagged(let t), .skipReason(let t): t.count
        case .actions: max(model.selection.count, model.targets.count)
        }
    }

    private func barActions(_ model: ReviewModel) -> [BulkAction] {
        guard model.barMode == .actions else { return [] }
        // Rows already on hold are left out of the targets, so a repeated press never holds
        // (or sends) them twice.
        return [
            BulkAction(id: "approve", title: model.approveTitle, symbol: "paperplane.fill",
                       shortcut: .approve, isProminent: true, isDisabled: model.targets.isEmpty) {
                model.requestApprove(undoManager: undoManager)
            },
            BulkAction(id: "skip", title: "Skip", shortcut: .skip) { model.requestSkip() },
        ]
    }

    @ViewBuilder
    private func barAccessory(_ model: ReviewModel) -> some View {
        switch model.barMode {
        case .actions:
            EmptyView()
        case .confirmFlagged(let targets):
            let clean = targets.filter { id in !(store.jobs.job(id: id).map(model.needsLook) ?? false) }.count
            let flagged = targets.count - clean
            let loading = model.anyLoading(targets)
            GlassBarPrompt(symbol: "exclamationmark.triangle.fill",
                           message: loading
                               ? "Some answers are still loading. Include the \(flagged) unchecked?"
                               : (flagged == 1 ? "Include the one that needs a look?" : "Include the \(flagged) that need a look?")) {
                Button("Cancel") { model.cancelBar() }.buttonStyle(.secondaryLink)
                Button("Only the \(clean) without issues") { model.confirmApprove(includeFlagged: false, undoManager: undoManager) }
                    .buttonStyle(.secondaryLink)
                Button("Include them") { model.confirmApprove(includeFlagged: true, undoManager: undoManager) }.buttonStyle(.primaryPill)
            }
        case .confirmAllFlagged(let targets):
            GlassBarPrompt(symbol: "exclamationmark.triangle.fill",
                           message: model.anyLoading(targets)
                               ? "Answers are still loading, so they haven't been checked yet. Approve anyway?"
                               : (targets.count == 1 ? "The agent wasn't sure about some answers. Approve anyway?"
                                  : "The agent wasn't sure about some answers in all \(targets.count). Approve anyway?")) {
                Button("Cancel") { model.cancelBar() }.buttonStyle(.secondaryLink)
                Button("Approve anyway") { model.confirmApprove(includeFlagged: true, undoManager: undoManager) }.buttonStyle(.primaryPill)
            }
        case .skipReason:
            GlassBarPrompt(symbol: nil, message: "Skip because…") {
                ForEach(ReviewSkipReason.allCases) { reason in
                    Button(reason.title) { Task { await model.skip(reason: reason) } }.buttonStyle(.secondaryLink)
                }
                Button("Cancel") { model.cancelBar() }.buttonStyle(.secondaryLink)
            }
        }
    }
}

// MARK: - Row

private struct ReviewRow: View {
    var model: ReviewModel
    var job: JobItem
    var style: ApproveStyle = .classic
    var isFocused: Bool
    var isSelected: Bool
    /// On the send hold: the row compresses to its name + "Sending in 5…  Undo".
    var hold: SendHoldModel.Entry?
    /// A hold the app quit during: never sent.
    var notSent: Bool
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        let flagged = model.isFlagged(job)
        let block = hold == nil ? model.sendBlock(for: job.id) : nil
        let blocked = block?.blocksSend == true
        HStack(spacing: Space.s) {
            if hold == nil {
                Button {
                    model.toggleSelection(job.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Deselect" : "Select")
            } else {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(Palette.accent)
                    .symbolEffect(.drawOn, isActive: false)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.company).font(Typography.bodyEmph).lineLimit(1)
                if hold == nil {
                    Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                if notSent { NotSentBadge() }
            }
            Spacer(minLength: Space.xs)
            if let hold {
                Group {
                    if style == .ticket {
                        // The torn stub's countdown, compact.
                        SendHoldStubCountdown(entry: hold, compact: true) { model.undoHold(jobID: job.id) }
                    } else {
                        SendHoldCapsule(entry: hold) { model.undoHold(jobID: job.id) }
                    }
                }
                .transition(.opacity)
            } else if let block, block.blocksSend {
                // Can't be sent yet: say until when (or that it needs your word) instead of the score.
                SendBlockRowMark(block: block)
                    .help(ReviewSendability.message(block, in: store.jobs.all))
            } else {
                if flagged {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.needsYou)
                        .help("\(model.flaggedAnswers(for: job).count) answer(s) need a look")
                        .accessibilityLabel("Needs a look")
                }
                if style == .ticket {
                    ReviewRowFacts(job: job, threshold: store.preferences.matchThreshold)
                } else if let score = job.score {
                    Badge(score: score, threshold: store.preferences.matchThreshold)
                }
            }
        }
        .selectableRow(isSelected: isFocused)
        .opacity(hold?.isSending == true ? 0.6 : 1)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: hold)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.displayName)\(hold != nil ? ", approved, sending soon" : "")\(notSent ? ", not sent" : "")\(blocked ? ", can't send yet" : "")\(flagged ? ", needs a look" : "")\(isSelected ? ", selected" : "")")
    }
}

// MARK: - Detail

private struct ReviewDetail: View {
    var model: ReviewModel
    var job: JobItem
    var style: ApproveStyle = .classic
    @Binding var quickLookURL: URL?
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @Environment(\.reviewRenderProbe) private var probe

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if style == .ticket {
                ReviewTicket(model: model, job: job)
                if let block = model.sendBlock(for: job.id) {
                    if block.blocksSend {
                        SendBlockNotice(model: model, job: job, block: block, isPrimary: noticeIsPrimary, showsSkip: false)
                            .transition(.opacity)
                    } else {
                        SameCompanyHint(block: block)
                    }
                }
                ticketFooter
            } else {
                classicHeader
                actions
            }
            ReviewQAPanel(job: job, answers: model.answers(for: job), answersLoaded: model.answersLoaded(job),
                          jumpSerial: model.flaggedJumpSerial,
                          onEdit: { answer, text in await model.editAnswer(answer, to: text) },
                          onQuickLook: { quickLookURL = $0 })
        }
        .padding(Space.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A "can't send yet" notice carries the screen's one primary while nothing else asks.
    private var noticeIsPrimary: Bool { model.selection.isEmpty && model.barMode == .actions }

    /// Under the ticket: why it's held, Skip, the job's mode and the posting.
    private var ticketFooter: some View {
        let held = model.isHeld(job.id)
        let flagged = !held && !model.isBlocked(job.id) && model.needsLook(job)
        let keysMeanThisJob = model.selection.isEmpty
        return HStack(spacing: Space.s) {
            if model.sendHold.wasNotSent(job.id) { NotSentBadge() }
            if flagged {
                Text(model.answersLoaded(job) ? "Answer or edit the flagged ones to release it, or press A to approve anyway."
                                              : "Answers are still loading.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if held {
                Text("Approved. If you quit before it sends, it won't be sent.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            modeMenu
            postingLink
            Button {
                model.requestSkip(only: [job.id])
            } label: {
                HStack(spacing: Space.xs) { Text("Skip"); if keysMeanThisJob { KeyCap("S") } }
            }
            .buttonStyle(.secondaryLink)
            .disabled(held)
        }
    }

    private var classicHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.company).font(Typography.title2)
                Text(job.title).font(Typography.body).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if let score = job.score { Badge(score: score, threshold: store.preferences.matchThreshold) }
            modeMenu
            postingLink
        }
    }

    private var modeMenu: some View {
        Menu {
            Button("Use app setting (\(store.effectiveMode(for: withoutOverride(job)).rawValue.capitalized))") { Task { await model.setMode(nil, for: job) } }
            Button("Always Auto for this job") { Task { await model.setMode(.auto, for: job) } }
            Button("Always Review for this job") { Task { await model.setMode(.review, for: job) } }
        } label: {
            Text(job.modeOverride.map { "This job: \($0.rawValue.capitalized)" } ?? "Mode: app setting")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var postingLink: some View {
        if let url = (job.applyURL ?? job.sourceURL).flatMap(URL.init(string:)) {
            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless)
                .help("Open the posting")
        }
    }

    /// This job's own Approve / Skip. Approve is the screen's primary pill only while the
    /// floating bar is away (no ticked jobs, no question open); otherwise it steps down to a plain
    /// button so one prominent action shows at a time.
    @ViewBuilder
    private var actions: some View {
        if let hold = model.sendHold.entry(for: job.id) {
            // On hold: the countdown and Undo replace Approve / Skip (nothing is sent yet).
            HStack(spacing: Space.s) {
                Text(hold.isSending ? "Approved. Sending to the agent now." : "Approved. If you quit before it sends, it won't be sent.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer()
                SendHoldCapsule(entry: hold) { model.undoHold(jobID: job.id) }
            }
        } else if let block = model.sendBlock(for: job.id), block.blocksSend {
            // The agent would refuse it now: say why and until when, instead of a doomed Approve.
            let _ = probe?.classic()
            SendBlockNotice(model: model, job: job, block: block, isPrimary: noticeIsPrimary)
                .transition(.opacity)
        } else {
            approveActions
        }
    }

    private var approveActions: some View {
        let _ = probe?.classic()
        let busy = model.isHeld(job.id)
        let flagged = model.needsLook(job)
        // The A / S keys act on the selection when there is one, so only hint them when they mean this job.
        let keysMeanThisJob = model.selection.isEmpty
        let isPrimary = keysMeanThisJob && model.barMode == .actions
        return HStack(spacing: Space.s) {
            if model.sendHold.wasNotSent(job.id) { NotSentBadge() }
            if !flagged, let block = model.sendBlock(for: job.id) { SameCompanyHint(block: block) }
            if flagged {
                Label(model.answersLoaded(job) ? "Some answers need a look before you send this" : "Answers are still loading",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.needsYou)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.requestSkip(only: [job.id])
            } label: {
                HStack(spacing: Space.xs) { Text("Skip"); if keysMeanThisJob { KeyCap("S") } }
            }
            .buttonStyle(.secondaryLink)
            .disabled(busy)
            let approve = Button {
                model.requestApprove(only: [job.id], undoManager: undoManager)
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "paperplane.fill")
                    Text(flagged ? "Approve (needs a look)" : "Approve & send")
                    if keysMeanThisJob { KeyCap("A") }
                }
            }
            Group {
                if isPrimary { approve.buttonStyle(.primaryPill) } else { approve.buttonStyle(.bordered) }
            }
            .disabled(busy || !store.isConnected)
            .help(store.isConnected ? "Sends after a \(Int(SendHoldTiming.seconds(model.sendHold.window))) s hold you can undo" : "The agent isn't running, so nothing can send.")
        }
    }

    private func withoutOverride(_ job: JobItem) -> JobItem {
        var j = job
        j.modeOverride = nil
        return j
    }
}

#Preview("Review") {
    let daemon = MockDaemon(scenario: .reviewMode)
    let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "reviewMode")
    store.start()
    return ReviewQueueView()
        .environment(store)
        .environment(store.router)
        .frame(width: 1200, height: 760)
}
