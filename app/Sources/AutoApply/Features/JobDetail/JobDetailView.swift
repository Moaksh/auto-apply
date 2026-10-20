// JobDetailView.swift — Job detail (docs/UI_UX_PLAN.md §5.4), pushed in the detail column or
// in its own window: header with status menu, match breakdown + resume + overrides on the
// left, and Overview (JD) | Questions (this job's open Needs You questions, answered in place;
// only while it has some) | Application (Q&A audit + submitted page) | Screenshots | Timeline.
import SwiftUI

@objc(JobDetailFeature)
final class JobDetailFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.registerJobDetail { id in JobDetailView(jobID: id) }
    }
}

enum JobDetailTab: String, CaseIterable, Sendable {
    case overview, questions, application, screenshots, timeline

    var title: String {
        switch self {
        case .overview: "Overview"
        case .questions: "Questions"
        case .application: "Application"
        case .screenshots: "Screenshots"
        case .timeline: "Timeline"
        }
    }

    /// A job blocked on questions opens on them; submitted/reviewable jobs on their receipts;
    /// others on the JD.
    static func initial(for job: JobItem, openQuestions: Int = 0) -> JobDetailTab {
        if openQuestions > 0 { return .questions }
        return switch job.state {
        case .submitted, .awaitingReview, .unknownVerify, .failed: .application
        default: .overview
        }
    }
}

struct JobDetailView: View {
    var jobID: Int
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var loader = JobDetailLoader()
    @State private var tab: JobDetailTab?
    @State private var highlighted: ApplicationAnswerItem?
    @State private var events: [ActivityEvent] = []
    @State private var width: CGFloat = 1000
    @State private var actions = JobDetailActions()
    @State private var quickLookURL: URL?
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        if let job = store.jobs.job(id: jobID) {
            content(job)
                .task(id: job.applicationID) { await loader.streamAnswers(applicationID: job.applicationID, repository: store.repository) }
                .task(id: jobID) { await loader.loadDescription(jobID: jobID, fallback: job.description, repository: store.repository) }
                .task(id: store.activity.events.count) { events = store.activity.events(forJob: jobID) }
                .onAppear {
                    if tab == nil { tab = JobDetailTab.initial(for: job, openQuestions: openClusters(job).count) }
                    router.focusedJobID = jobID
                }
                .onChange(of: job.state) { _, state in
                    actions.reset()
                    // Became reviewable while open: show the receipts to review.
                    if state == .awaitingReview { tab = .application }
                }
                .onChange(of: router.jobApproveRequest) { _, request in
                    if request?.jobID == jobID { requestApprove(job) }
                }
                .quickLookPreview($quickLookURL)
        } else if !store.jobs.isLoaded {
            SkeletonBlock(lines: 8).padding(Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            EmptyState(symbol: "questionmark.folder", title: "Job not found", message: "Job #\(jobID) isn't in the local database.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ job: JobItem) -> some View {
        VStack(spacing: 0) {
            JobDetailHeader(job: job, actions: actions,
                            needsLook: ReviewSafeguard.needsLook(answers: loader.answers, loaded: loader.answersLoaded),
                            approve: { requestApprove(job) },
                            copyAll: { copyAll(job) })
                .padding(.horizontal, Space.contentPadding)
                .padding(.vertical, Space.l)
            if actions.prompt != .none {
                JobDetailPromptBar(job: job, actions: actions, reviewAnswers: {
                    actions.cancelPrompt()
                    tab = .application
                })
                .padding(.horizontal, Space.contentPadding)
                .padding(.bottom, Space.m)
                .transition(reduced ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            Divider()
            ScrollView {
                let narrow = width < 860
                let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xl))
                                    : AnyLayout(HStackLayout(alignment: .top, spacing: Space.xl))
                layout {
                    sidebar(job).frame(width: narrow ? nil : 300, alignment: .topLeading)
                    main(job).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(Space.contentPadding)
            }
        }
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: actions.prompt)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Palette.windowBackground)
        .navigationTitle(job.company)
    }

    // MARK: Left column

    private func sidebar(_ job: JobItem) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if let banner = JobDetailRules.skippedBanner(job, threshold: store.preferences.matchThreshold) {
                HStack(spacing: Space.s) {
                    Image(systemName: StatusKind.skipped.symbol)
                    Text(banner).font(Typography.callout)
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.skipped.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            if job.state == .failed || job.state == .unknownVerify, let reason = job.stateReason {
                HStack(spacing: Space.s) {
                    Image(systemName: StatusKind.error.symbol).foregroundStyle(Palette.error)
                    Text(reason).font(Typography.callout)
                }
                .padding(Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.error.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            MatchBreakdown(job: job, threshold: store.preferences.matchThreshold)
            resumeSection(job)
            overrides(job)
            JobNotesEditor(jobID: job.id, notes: job.notes, onEditingChanged: actions.editingChanged)
            if job.tokensIn + job.tokensOut > 0 {
                Text("Tokens · \(job.tokensIn.formatted()) in · \(job.tokensOut.formatted()) out")
                    .font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func resumeSection(_ job: JobItem) -> some View {
        if let resume = store.library.resume(id: job.resumeVariantID) {
            HStack(spacing: Space.s) {
                Text("Resume").eyebrowStyle()
                Text((resume.filePath as NSString).lastPathComponent).font(Typography.body)
                if let pick = job.resumePickScore {
                    Text("picked: \(pick.formatted(.number.precision(.fractionLength(2))))")
                        .font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                        .help("Similarity between this resume and the job description; the highest-scoring approved variant is used.")
                }
            }
        }
    }

    private func overrides(_ job: JobItem) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Overrides").eyebrowStyle()
            HStack {
                Text("Mode").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Picker("Mode", selection: Binding(get: { job.modeOverride }, set: { m in Task { await store.setJobMode(jobID: job.id, mode: m) } })) {
                    Text("Inherit (\(inheritedModeLabel(job)))").tag(Mode?.none)
                    Text("Auto").tag(Mode?.some(.auto))
                    Text("Review").tag(Mode?.some(.review))
                }
                .labelsHidden()
                .fixedSize()
                .disabled(job.state == .submitted || job.state == .skipped || !store.isConnected)
            }
        }
    }

    private func inheritedModeLabel(_ job: JobItem) -> String {
        var j = job
        j.modeOverride = nil
        return store.effectiveMode(for: j) == .auto ? "Auto" : "Review"
    }

    // MARK: Main column

    /// Open Needs You questions blocking this job (answers still in their Undo window excluded).
    private func openClusters(_ job: JobItem) -> [QuestionCluster] {
        let pendingFree = Set(InboxModel.shared(for: store).clusters.map(\.clusterId))
        return JobDetailRules.openClusters(forJob: job.id, in: store.inbox.clusters).filter { pendingFree.contains($0.clusterId) }
    }

    private func main(_ job: JobItem) -> some View {
        let questions = openClusters(job)
        let tabs = JobDetailTab.allCases.filter { $0 != .questions || !questions.isEmpty }
        // The Questions tab leaves once its last question is answered.
        let chosen = tab ?? JobDetailTab.initial(for: job, openQuestions: questions.count)
        let current = tabs.contains(chosen) ? chosen : JobDetailTab.initial(for: job)
        return VStack(alignment: .leading, spacing: Space.l) {
            Picker("Section", selection: Binding(get: { current }, set: { tab = $0 })) {
                ForEach(tabs, id: \.self) { t in
                    Text(t == .questions ? "Questions (\(questions.count))" : t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: questions.isEmpty ? 420 : 540)

            switch current {
            case .overview: overview(job)
            case .questions: JobQuestionsPane(job: job, clusters: questions)
            case .application: application(job)
            case .screenshots: ScreenshotViewer(shots: JobDetailRules.screenshots(for: job), highlighted: nil)
            case .timeline: JobTimeline(items: JobDetailRules.timeline(job: job, events: events))
            }
        }
    }

    private func overview(_ job: JobItem) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Job description").eyebrowStyle()
            if !loader.descriptionLoaded {
                SkeletonBlock(lines: 8)
            } else if let text = loader.jobDescription, !text.isEmpty {
                Text(text).font(Typography.body).textSelection(.enabled).lineSpacing(3)
                    .frame(maxWidth: 720, alignment: .leading)
            } else {
                Text("No description was captured for this job.").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func application(_ job: JobItem) -> some View {
        if job.state == .awaitingReview {
            review(job)
        } else {
            audit(job)
        }
    }

    /// Awaiting review: the Review queue's screenshot + Q&A panel, with ✎ edits.
    private func review(_ job: JobItem) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack {
                Text("Review before submitting").eyebrowStyle()
                Spacer()
                Button { copyAll(job) } label: {
                    HStack(spacing: Space.xs) { Text("Copy all"); KeyCap(.copyAll) }
                }
                .buttonStyle(.borderless)
                .disabled(loader.answers.isEmpty)
            }
            ReviewQAPanel(job: job, answers: loader.answers, answersLoaded: loader.answersLoaded, embedded: true,
                          onEdit: { answer, text in await loader.editAnswer(answer, to: text, store: store) },
                          onEditingChanged: actions.editingChanged,
                          onQuickLook: { quickLookURL = $0 })
            if let path = job.coverLetterPath, FileManager.default.fileExists(atPath: path) {
                CoverLetterCard(path: path) { store.toasts.show("Copied cover letter", symbol: "checkmark", style: .success) }
            }
        }
    }

    private func audit(_ job: JobItem) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack {
                Text("Application (Q&A audit)").eyebrowStyle()
                Spacer()
                Button { copyAll(job) } label: {
                    HStack(spacing: Space.xs) { Text("Copy all"); KeyCap(.copyAll) }
                }
                .buttonStyle(.borderless)
                .disabled(loader.answers.isEmpty)
            }
            QATable(answers: loader.answers, isLoaded: loader.answersLoaded, library: store.library, highlighted: $highlighted) { question in
                store.toasts.show("Copied · \(question)", symbol: "checkmark", style: .success)
            }
            if let path = job.coverLetterPath, FileManager.default.fileExists(atPath: path) {
                CoverLetterCard(path: path) { store.toasts.show("Copied cover letter", symbol: "checkmark", style: .success) }
            }
            Text("Submitted page").eyebrowStyle()
            ScreenshotViewer(shots: JobDetailRules.screenshots(for: job), highlighted: highlighted)
        }
    }

    private func requestApprove(_ job: JobItem) {
        Task { await actions.requestApprove(job: job, answers: loader.answers, answersLoaded: loader.answersLoaded, store: store) }
    }

    private func copyAll(_ job: JobItem) {
        guard !loader.answers.isEmpty else { return }
        loader.copyAll(job: job)
        store.toasts.show("Copied all answers", symbol: "checkmark", style: .success)
    }
}

/// "[logo] Stripe · Backend Engineer   ● Awaiting review  [Skip] [Approve & submit] [Open posting]".
/// The chip is a menu only for submitted jobs (board moves); everything else the job's state
/// allows is a button, with at most one accent-filled.
private struct JobDetailHeader: View {
    var job: JobItem
    var actions: JobDetailActions
    /// The job's Q&A needs a look (or hasn't loaded): the approve button carries the ⚠.
    var needsLook: Bool
    var approve: () -> Void
    var copyAll: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            CompanyMonogram(name: job.company, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName).font(Typography.title2).lineLimit(1)
                Text(meta).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: Space.s)
            statusMenu
            if let note = JobDetailRules.headerNote(for: job) {
                Text(note).font(Typography.callout).foregroundStyle(Palette.textSecondary).fixedSize()
            }
            ForEach(JobDetailRules.headerActions(for: job), id: \.self) { action in
                actionButton(action)
            }
            if let url = (job.applyURL ?? job.sourceURL).flatMap(URL.init(string:)) {
                Button("Open posting") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help("Open the job posting in your browser")
            }
            Button("") { copyAll() }
                .keyboardShortcut(.copyAll)
                .hidden()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            if job.state == .awaitingReview {
                // ⌘↵ approve. Held while an inline editor is open so ⌘↵ in a text field never
                // submits a half-edited form (and the notes editor keeps its own ⌘↵ Save).
                Button("") { approve() }
                    .keyboardShortcut(.submit)
                    .disabled(actions.isEditing || actions.inFlight || !store.isConnected)
                    .hidden()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: JobDetailRules.HeaderAction) -> some View {
        let button = Button {
            perform(action)
        } label: {
            HStack(spacing: Space.xs) {
                if action == .approve, needsLook {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.needsYou)
                } else if let symbol = action.symbol {
                    Image(systemName: symbol)
                }
                Text(action == .approve && actions.inFlight ? "Approving…" : action.title)
                if let shortcut = action.shortcut { KeyCap(shortcut) }
            }
        }
        .fixedSize()
        .help(action == .approve && needsLook ? "Some answers need a look. You'll be asked before it's submitted." : action.help)
        .disabled(actions.inFlight || (!store.isConnected && action.needsDaemon))
        if action.isPrimary {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private func perform(_ action: JobDetailRules.HeaderAction) {
        switch action {
        case .approve: approve()
        case .skip: actions.requestSkip(job: job)
        case .retry: Task { await actions.retry(job: job, store: store) }
        case .applyAnyway: Task { await actions.applyAnyway(job: job, store: store) }
        case .resolveSent: Task { await actions.resolve(job: job, sent: true, store: store) }
        case .resolveNotSent: Task { await actions.resolve(job: job, sent: false, store: store) }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let location = job.location { parts.append(location) }
        parts.append(job.ats.label)
        parts.append("found via \(job.source.label)")
        parts.append(job.discoveredAt.formatted(.dateTime.day().month(.abbreviated)))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusMenu: some View {
        let moves = JobDetailRules.menuActions(for: job)
        if moves.isEmpty {
            StatusChip(job: job).fixedSize()
        } else {
            Menu {
                ForEach(moves, id: \.self) { action in
                    Button(action.title) {
                        guard case .setStatus(let status) = action else { return }
                        Task { await BoardModel(store: store).move(jobID: job.id, to: status, undoManager: undoManager) }
                    }
                }
            } label: {
                StatusChip(job: job)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change status")
            .disabled(!store.isConnected)
        }
    }
}

/// The inline question under the header (no modal): the low-confidence safeguard before
/// approving, or the skip-reason picker. Same copy as the Review queue's bar.
private struct JobDetailPromptBar: View {
    var job: JobItem
    var actions: JobDetailActions
    var reviewAnswers: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: Space.s) {
            switch actions.prompt {
            case .none:
                EmptyView()
            case .confirmFlagged(let flagged, let loading):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.needsYou)
                Text(loading
                     ? "Answers are still loading, so confidence isn't checked yet. Approve anyway?"
                     : "\(flagged == 1 ? "1 answer needs" : "\(flagged) answers need") a look. Approve anyway?")
                    .font(Typography.bodyEmph)
                Spacer(minLength: Space.s)
                Button("Review answers") { reviewAnswers() }.buttonStyle(.glass)
                Button("Cancel") { actions.cancelPrompt() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Approve anyway") { Task { await actions.confirmApprove(job: job, store: store) } }
                    .buttonStyle(.glassProminent)
            case .skipReason:
                Text("Skip because…").font(Typography.bodyEmph)
                Spacer(minLength: Space.s)
                ForEach(ReviewSkipReason.allCases) { reason in
                    Button(reason.title) { Task { await actions.skip(job: job, reason: reason, store: store) } }
                        .buttonStyle(.glass)
                }
                Button("Cancel") { actions.cancelPrompt() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(actions.prompt == .skipReason ? Palette.sunken : Palette.needsYou.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }
}

/// Free-form notes on a job, saved through `update_job_notes` (the daemon is the only writer).
private struct JobNotesEditor: View {
    var jobID: Int
    var notes: String?
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var isEditing = false
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Notes").eyebrowStyle()
                Spacer()
                if isEditing {
                    Button("Cancel") { isEditing = false }.buttonStyle(.link)
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .buttonStyle(.link)
                        .disabled(isSaving || !store.isConnected)
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button((notes ?? "").isEmpty ? "Add note" : "Edit") {
                        draft = notes ?? ""
                        isEditing = true
                    }
                    .buttonStyle(.link)
                    .disabled(!store.isConnected)
                }
            }
            if isEditing {
                TextEditor(text: $draft)
                    .font(Typography.body)
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(Space.xs)
                    .sunkenWell()
                    .accessibilityLabel("Job notes")
            } else if let notes, !notes.isEmpty {
                Text(notes).font(Typography.body).textSelection(.enabled)
            }
        }
        .onChange(of: jobID) { _, _ in isEditing = false }
        .onChange(of: isEditing) { _, now in onEditingChanged(now) }
        .onDisappear { if isEditing { onEditingChanged(false) } }
    }

    private func save() {
        isSaving = true
        let text = draft
        Task {
            let ok = await store.updateJobNotes(jobID: jobID, notes: text)
            isSaving = false
            if ok { isEditing = false }
        }
    }
}


/// The cover letter the agent wrote (and uploaded / pasted) for this application, readable in place.
private struct CoverLetterCard: View {
    var path: String
    var onCopied: () -> Void
    @State private var expanded = false

    private var text: String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Cover letter").eyebrowStyle()
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    onCopied()
                }
                .buttonStyle(.borderless)
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.borderless)
                    .help("Open the file that was sent")
            }
            Text(text.isEmpty ? "The cover letter file is empty." : text)
                .font(Typography.body)
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.split(separator: "\n").count > 8 || text.count > 600 {
                Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(Typography.callout)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkenWell()
    }
}
