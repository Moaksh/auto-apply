// ReviewView.swift — the Review queue (docs/UI_UX_PLAN.md §5.6): list (flagged first) on the
// left, screenshot + every Q&A side by side on the right with hover-linked field highlights,
// inline ✎ edits, and the floating morphing glass BulkActionBar with the inline safeguard and
// skip-reason picker. Keys: ↑↓/J K focus, X select, ⌘A select all, A approve, S skip, Space
// Quick Look.
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
            if queue.isEmpty && model.departing.isEmpty {
                EmptyState(symbol: "checkmark.rectangle.stack", title: "Nothing to review",
                           message: store.mode == .review
                               ? "Filled applications wait here for your OK before they're submitted."
                               : "You're in Auto mode. Jobs only land here for ATSes or jobs set to Review.",
                           prominent: true)
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
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text("Review").font(Typography.title1)
            HStack(spacing: Space.xs) {
                Text("\(count)").numericRoll(Double(count))
                Text("ready ·")
                Text(model.modeSummary)
            }
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            Spacer()
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
        .padding(.horizontal, Space.contentPadding)
        .padding(.vertical, Space.l)
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
                .padding(.bottom, 80)
                .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: queue.map(\.id))
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
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
        .background(Palette.surface.opacity(0.4))
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
            HStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.needsYou)
                Text(loading
                     ? "Some answers are still loading. Include the \(flagged) unchecked?"
                     : (flagged == 1 ? "Include the flagged one?" : "Include the \(flagged) flagged ones?"))
                    .font(Typography.bodyEmph)
                Button("Yes") { Task { await model.confirmApprove(includeFlagged: true) } }.buttonStyle(.glassProminent)
                Button("Only the \(clean) clean one\(clean == 1 ? "" : "s")") { Task { await model.confirmApprove(includeFlagged: false) } }
                    .buttonStyle(.glass)
                Button("Cancel") { model.cancelBar() }.buttonStyle(.glass)
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .glassEffect(.regular, in: Capsule())
        case .confirmAllFlagged(let targets):
            HStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.needsYou)
                Text(model.anyLoading(targets)
                     ? "Answers are still loading, so confidence isn't checked yet. Approve anyway?"
                     : (targets.count == 1 ? "This one has low-confidence answers. Approve anyway?" : "All \(targets.count) have low-confidence answers. Approve anyway?"))
                    .font(Typography.bodyEmph)
                Button("Approve anyway") { Task { await model.confirmApprove(includeFlagged: true) } }.buttonStyle(.glassProminent)
                Button("Cancel") { model.cancelBar() }.buttonStyle(.glass)
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .glassEffect(.regular, in: Capsule())
        case .skipReason:
            HStack(spacing: Space.s) {
                Text("Skip because…").font(Typography.bodyEmph)
                ForEach(ReviewSkipReason.allCases) { reason in
                    Button(reason.title) { Task { await model.skip(reason: reason) } }.buttonStyle(.glass)
                }
                Button("Cancel") { model.cancelBar() }.buttonStyle(.glass)
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .glassEffect(.regular, in: Capsule())
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
                if let score = job.score { ScorePill(score: score, threshold: store.preferences.matchThreshold) }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(isFocused ? Palette.accent.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .contentShape(Rectangle())
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
                if let score = job.score { ScorePill(score: score, threshold: store.preferences.matchThreshold) }
                Menu {
                    Button("Inherit (\(store.effectiveMode(for: withoutOverride(job)).rawValue.capitalized))") { Task { await model.setMode(nil, for: job) } }
                    Button("Always Auto for this job") { Task { await model.setMode(.auto, for: job) } }
                    Button("Always Review for this job") { Task { await model.setMode(.review, for: job) } }
                } label: {
                    Text(job.modeOverride.map { "Job: \($0.rawValue.capitalized)" } ?? "Mode: inherit")
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

    /// This job's own Approve / Skip: always visible, independent of the multi-selection (the
    /// floating bar handles batches).
    private var actions: some View {
        let busy = model.departing[job.id] != nil || model.isApproving
        let flagged = model.needsLook(job)
        // The A / S keys act on the selection when there is one, so only hint them when they mean this job.
        let keysMeanThisJob = model.selection.isEmpty
        return HStack(spacing: Space.s) {
            if flagged {
                Label(model.answersLoaded(job) ? "Some answers need a look before you submit" : "Answers are still loading",
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
            .buttonStyle(.glass)
            .disabled(busy)
            Button {
                Task { await model.requestApprove(only: [job.id]) }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "paperplane.fill")
                    Text(flagged ? "Approve (needs a look)" : "Approve & submit")
                    if keysMeanThisJob { KeyCap("A") }
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(busy || !store.isConnected)
            .help(store.isConnected ? "Submit this application now" : "The agent isn't connected")
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
