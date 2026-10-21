// ReviewView.swift — Review: approve applications before they're sent. List (flagged first) on
// the left, screenshot + every answer side by side on the right with hover-linked field
// highlights and inline ✎ edits. One primary action: Approve & submit (this job, or the floating
// glass bulk bar when several are ticked; never both at once). The low-confidence safeguard and
// skip reasons ask inline. Keys: ↑↓/J K focus, X select, ⌘A select all, A approve, S skip,
// Space Quick Look.
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
    @FocusState private var listFocused: Bool
    @State private var quickLookURL: URL?

    private var model: ReviewModel { ReviewModel.shared(for: store) }

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
            } else if queue.isEmpty && model.departing.isEmpty {
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
                    if let job = model.focusedJob {
                        ReviewDetail(model: model, job: job, quickLookURL: $quickLookURL)
                            .id(job.id)
                            .transition(.opacity)
                    } else {
                        EmptyState(symbol: "rectangle.on.rectangle", title: "Select an application")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Palette.windowBackground)
        .overlay(alignment: .bottom) { bar(model) }
        .quickLookPreview($quickLookURL)
        .task { model.syncSubscriptions() }
        .onChange(of: store.jobs.revision) { model.syncSubscriptions() }
    }

    // MARK: Header

    private func header(_ model: ReviewModel, count: Int) -> some View {
        ScreenHeader("Review", summary: "\(count) ready · \(model.modeSummary)") {
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
                        ReviewRow(model: model, job: job,
                                  isFocused: job.id == model.focusedJobID,
                                  isSelected: model.selection.contains(job.id),
                                  departIndex: model.departing[job.id])
                            .id(job.id)
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.command) {
                                    model.toggleSelection(job.id)
                                } else {
                                    model.focusedJobID = job.id
                                }
                                listFocused = true
                            }
                            .transition(reduced ? .opacity : .asymmetric(insertion: .opacity,
                                                                          removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }
                .padding(Space.s)
                .padding(.bottom, Space.xxxl * 2)
                .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: queue.map(\.id))
            }
            .focusable()
            .focused($listFocused)
            .onKeyPress(.downArrow) { model.moveFocus(by: 1); return .handled }
            .onKeyPress(.upArrow) { model.moveFocus(by: -1); return .handled }
            .onKeyPress("j") { model.moveFocus(by: 1); return .handled }
            .onKeyPress("k") { model.moveFocus(by: -1); return .handled }
            .onShortcut(.toggleSelection) { model.toggleFocusedSelection() }
            .onShortcut(.selectAll) { model.selectAll() }
            .onShortcut(.approve) { Task { await model.requestApprove() } }
            .onShortcut(.skip) { model.requestSkip() }
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
                .transition(reduced ? .opacity : .move(edge: .bottom).combined(with: .opacity))
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
        // Approve is disabled while an approve is in flight; the model's in-flight guard also
        // ignores repeated presses / the A shortcut.
        return [
            BulkAction(id: "approve", title: model.isApproving ? "Approving…" : model.approveTitle, symbol: "paperplane.fill",
                       shortcut: .approve, isProminent: true, isDisabled: model.isApproving) {
                Task { await model.requestApprove() }
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
                Button("Only the \(clean) without issues") { Task { await model.confirmApprove(includeFlagged: false) } }
                    .buttonStyle(.secondaryLink)
                Button("Include them") { Task { await model.confirmApprove(includeFlagged: true) } }.buttonStyle(.primaryPill)
            }
        case .confirmAllFlagged(let targets):
            GlassBarPrompt(symbol: "exclamationmark.triangle.fill",
                           message: model.anyLoading(targets)
                               ? "Answers are still loading, so they haven't been checked yet. Approve anyway?"
                               : (targets.count == 1 ? "The agent wasn't sure about some answers. Approve anyway?"
                                  : "The agent wasn't sure about some answers in all \(targets.count). Approve anyway?")) {
                Button("Cancel") { model.cancelBar() }.buttonStyle(.secondaryLink)
                Button("Approve anyway") { Task { await model.confirmApprove(includeFlagged: true) } }.buttonStyle(.primaryPill)
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
    var isFocused: Bool
    var isSelected: Bool
    var departIndex: Int?
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        let flagged = model.isFlagged(job)
        HStack(spacing: Space.s) {
            Button {
                model.toggleSelection(job.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect" : "Select")
            VStack(alignment: .leading, spacing: 2) {
                Text(job.company).font(Typography.bodyEmph).lineLimit(1)
                Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            if departIndex != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.applied)
                    .symbolEffect(.drawOn, isActive: false)
                    .transition(.scale.combined(with: .opacity))
            } else {
                if flagged {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.needsYou)
                        .help("\(model.flaggedAnswers(for: job).count) answer(s) need a look")
                        .accessibilityLabel("Needs a look")
                }
                if let score = job.score { Badge(score: score, threshold: store.preferences.matchThreshold) }
            }
        }
        .selectableRow(isSelected: isFocused)
        .offset(x: departIndex != nil && !reduced ? 24 : 0)
        .opacity(departIndex != nil ? 0.6 : 1)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: departIndex)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.displayName)\(flagged ? ", needs a look" : "")\(isSelected ? ", selected" : "")")
    }
}

// MARK: - Detail

private struct ReviewDetail: View {
    var model: ReviewModel
    var job: JobItem
    @Binding var quickLookURL: URL?
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.company).font(Typography.title2)
                    Text(job.title).font(Typography.body).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                if let score = job.score { Badge(score: score, threshold: store.preferences.matchThreshold) }
                Menu {
                    Button("Use app setting (\(store.effectiveMode(for: withoutOverride(job)).rawValue.capitalized))") { Task { await model.setMode(nil, for: job) } }
                    Button("Always Auto for this job") { Task { await model.setMode(.auto, for: job) } }
                    Button("Always Review for this job") { Task { await model.setMode(.review, for: job) } }
                } label: {
                    Text(job.modeOverride.map { "This job: \($0.rawValue.capitalized)" } ?? "Mode: app setting")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if let url = (job.applyURL ?? job.sourceURL).flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless)
                        .help("Open the posting")
                }
            }
            actions
            ReviewQAPanel(job: job, answers: model.answers(for: job), answersLoaded: model.answersLoaded(job),
                          onEdit: { answer, text in await model.editAnswer(answer, to: text) },
                          onQuickLook: { quickLookURL = $0 })
        }
        .padding(Space.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// This job's own Approve / Skip. Approve is the screen's primary pill only while the
    /// floating bar is away (no ticked jobs, no question open); otherwise it steps down to a plain
    /// button so one prominent action shows at a time.
    private var actions: some View {
        let busy = model.departing[job.id] != nil || model.isApproving
        let flagged = model.needsLook(job)
        // The A / S keys act on the selection when there is one, so only hint them when they mean this job.
        let keysMeanThisJob = model.selection.isEmpty
        let isPrimary = keysMeanThisJob && model.barMode == .actions
        return HStack(spacing: Space.s) {
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
                Task { await model.requestApprove(only: [job.id]) }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "paperplane.fill")
                    Text(flagged ? "Approve (needs a look)" : "Approve & submit")
                    if keysMeanThisJob { KeyCap("A") }
                }
            }
            Group {
                if isPrimary { approve.buttonStyle(.primaryPill) } else { approve.buttonStyle(.bordered) }
            }
            .disabled(busy || !store.isConnected)
            .help(store.isConnected ? "Send this application now" : "The agent isn't connected")
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
