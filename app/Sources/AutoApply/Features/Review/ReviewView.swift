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
                               : "You're in Auto mode. Jobs only land here for ATSes or jobs set to Review.")
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
                BulkActionBar(selectionCount: max(model.selection.count, model.targets.count), actions: barActions(model),
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
    @State private var hoveredAnswerID: Int?

    var body: some View {
        let answers = model.answers(for: job)
        let flagged = model.flaggedAnswers(for: job)
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
            HStack(alignment: .top, spacing: Space.l) {
                ReviewScreenshotPane(path: job.screenshotPath, highlight: answers.first { $0.id == hoveredAnswerID }?.bbox) { url in
                    quickLookURL = url
                }
                .frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack {
                        Text("Q&A (\(answers.count))").eyebrowStyle()
                        Spacer()
                        if !flagged.isEmpty {
                            Label("\(flagged.count) need\(flagged.count == 1 ? "s" : "") a look", systemImage: "exclamationmark.triangle.fill")
                                .font(Typography.callout)
                                .foregroundStyle(Palette.needsYou)
                        }
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            if answers.isEmpty {
                                SkeletonBlock(lines: 5).padding(.vertical, Space.m)
                            }
                            ForEach(answers) { answer in
                                ReviewAnswerRow(model: model, answer: answer, isHovered: hoveredAnswerID == answer.id)
                                    .onHover { inside in hoveredAnswerID = inside ? answer.id : (hoveredAnswerID == answer.id ? nil : hoveredAnswerID) }
                                Divider()
                            }
                            ReviewAttachmentRows(job: job)
                        }
                        .padding(.bottom, 90)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(Space.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func withoutOverride(_ job: JobItem) -> JobItem {
        var j = job
        j.modeOverride = nil
        return j
    }
}

/// One audited answer: question, answer, provenance, confidence, inline ✎ edit.
private struct ReviewAnswerRow: View {
    var model: ReviewModel
    var answer: ApplicationAnswerItem
    var isHovered: Bool
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            HStack(spacing: 3) {
                Text(answer.question).font(Typography.body).lineLimit(2)
                if answer.isLocked { Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(Palette.textSecondary) }
            }
            .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xs) {
                if editing {
                    if answer.fieldType == .textarea || answer.answer.count > 80 {
                        TextEditor(text: $draft)
                            .font(Typography.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80)
                            .padding(Space.xs)
                            .sunkenWell()
                            .focused($fieldFocused)
                    } else {
                        TextField("Answer", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .focused($fieldFocused)
                            .onSubmit(save)
                    }
                    HStack {
                        Button("Save", action: save).buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { editing = false }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    Text(answer.answer)
                        .font(Typography.body)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    HStack(spacing: Space.xs) {
                        ProvenanceTag(origin: answer.origin)
                        if let c = answer.confidence {
                            Text(String(format: "%.2f", c)).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            ConfidenceDot(level: answer.confidenceLevel).padding(.top, 4)
            if !answer.isLocked && answer.fieldType != .file && !editing {
                Button {
                    draft = answer.answer
                    editing = true
                    fieldFocused = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit this answer")
                .accessibilityLabel("Edit \(answer.question)")
            }
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.xs)
        .background(isHovered ? Palette.accent.opacity(0.06) : Color.clear)
        .background(answer.confidenceLevel == .low || answer.confidenceLevel == .medium ? Palette.needsYou.opacity(0.06) : Color.clear)
    }

    private func save() {
        let text = draft
        editing = false
        Task { await model.editAnswer(answer, to: text) }
    }
}

/// Resume + cover letter rows under the Q&A.
private struct ReviewAttachmentRows: View {
    var job: JobItem
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let resume = store.library.resume(id: job.resumeVariantID) ?? store.library.defaultResume {
                HStack(spacing: Space.s) {
                    Text("Resume").font(Typography.body).frame(width: 170, alignment: .leading)
                    Image(systemName: "doc.richtext")
                    Text("\(resume.label).pdf").font(Typography.body)
                    if let pick = job.resumePickScore {
                        Text(String(format: "pick %.2f", pick)).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    let alternatives = store.library.resumeVariants.filter { $0.enabled && $0.id != resume.id }
                    if !alternatives.isEmpty, let appID = job.applicationID {
                        Menu {
                            ForEach(alternatives) { variant in
                                Button(variant.label) {
                                    Task { await store.setApplicationResume(applicationID: appID, resumeVariantID: variant.id) }
                                }
                            }
                        } label: {
                            Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Use a different resume (the form is re-filled before it can be approved)")
                        .disabled(!store.isConnected)
                    }
                    if let url = LocalFiles.existing(resume.filePath) {
                        Button("Reveal") { LocalFiles.reveal(url) }.buttonStyle(.link)
                    }
                }
                .padding(.vertical, Space.s)
                Divider()
            }
            if let path = job.coverLetterPath {
                HStack(spacing: Space.s) {
                    Text("Cover letter").font(Typography.body).frame(width: 170, alignment: .leading)
                    Image(systemName: "envelope.open")
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(Typography.body).lineLimit(1)
                    Spacer()
                    if let url = LocalFiles.existing(path) {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                    }
                }
                .padding(.vertical, Space.s)
            }
        }
    }
}

/// Full-page pre-submit screenshot: scrollable, solid well (never glass), highlights the field
/// of the hovered answer. Decoded off-main. Click / Space opens Quick Look.
struct ReviewScreenshotPane: View {
    var path: String?
    var highlight: CGRect?
    var onQuickLook: (URL) -> Void
    @State private var image: DecodedImage?
    @State private var originalSize: CGSize?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                ScrollView {
                    let scaleBase = originalSize ?? image.size
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                if let highlight, scaleBase.width > 0 {
                                    let s = geo.size.width / scaleBase.width
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .stroke(Palette.accent, lineWidth: 2)
                                        .background(Palette.accent.opacity(0.12))
                                        .frame(width: highlight.width * s, height: highlight.height * s)
                                        .offset(x: highlight.minX * s, y: highlight.minY * s)
                                        .transition(.opacity)
                                }
                            }
                        }
                        .onTapGesture { if let url = LocalFiles.existing(path) { onQuickLook(url) } }
                }
                .clipShape(.thumb)
            } else {
                VStack(spacing: Space.s) {
                    Image(systemName: loaded ? "photo.on.rectangle.angled" : "photo")
                        .font(.system(size: 28)).foregroundStyle(Palette.textTertiary)
                    Text(loaded ? "No screenshot recorded" : "Loading screenshot…")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        .padding(Space.xs)
        .sunkenWell()
        .accessibilityLabel("Pre-submit screenshot")
        .task(id: path) {
            loaded = false
            image = nil
            guard let url = LocalFiles.existing(path) else { loaded = true; return }
            image = await C3Thumbnails.shared.image(url, maxPixel: 1600)
            originalSize = await C3Thumbnails.shared.originalSize(url)
            loaded = true
        }
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
