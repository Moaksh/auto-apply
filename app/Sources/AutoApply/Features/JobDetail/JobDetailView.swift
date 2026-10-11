// JobDetailView.swift — Job detail (docs/UI_UX_PLAN.md §5.4), pushed in the detail column or
// in its own window: header with status menu, match breakdown + resume + overrides on the
// left, and Overview (JD) | Application (Q&A audit + submitted page) | Screenshots | Timeline.
import SwiftUI

@objc(JobDetailFeature)
final class JobDetailFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.registerJobDetail { id in JobDetailView(jobID: id) }
    }
}

enum JobDetailTab: String, CaseIterable, Sendable {
    case overview, application, screenshots, timeline

    var title: String {
        switch self {
        case .overview: "Overview"
        case .application: "Application"
        case .screenshots: "Screenshots"
        case .timeline: "Timeline"
        }
    }

    /// Submitted/reviewable jobs open on their receipts; others on the JD.
    static func initial(for job: JobItem) -> JobDetailTab {
        switch job.state {
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

    var body: some View {
        if let job = store.jobs.job(id: jobID) {
            content(job)
                .task(id: job.applicationID) { await loader.streamAnswers(applicationID: job.applicationID, repository: store.repository) }
                .task(id: jobID) { await loader.loadDescription(jobID: jobID, fallback: job.description, repository: store.repository) }
                .task(id: store.activity.events.count) { events = store.activity.events(forJob: jobID) }
                .onAppear {
                    if tab == nil { tab = JobDetailTab.initial(for: job) }
                    router.focusedJobID = jobID
                }
        } else if !store.jobs.isLoaded {
            SkeletonBlock(lines: 8).padding(Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            EmptyState(symbol: "questionmark.folder", title: "Job not found", message: "Job #\(jobID) isn't in the local database.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ job: JobItem) -> some View {
        VStack(spacing: 0) {
            JobDetailHeader(job: job, copyAll: { copyAll(job) })
                .padding(.horizontal, Space.contentPadding)
                .padding(.vertical, Space.l)
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
            JobNotesEditor(jobID: job.id, notes: job.notes)
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

    private func main(_ job: JobItem) -> some View {
        let current = tab ?? JobDetailTab.initial(for: job)
        return VStack(alignment: .leading, spacing: Space.l) {
            Picker("Section", selection: Binding(get: { current }, set: { tab = $0 })) {
                ForEach(JobDetailTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            switch current {
            case .overview: overview(job)
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

    private func application(_ job: JobItem) -> some View {
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

    private func copyAll(_ job: JobItem) {
        guard !loader.answers.isEmpty else { return }
        loader.copyAll(job: job)
        store.toasts.show("Copied all answers", symbol: "checkmark", style: .success)
    }
}

/// "[logo] Stripe · Backend Engineer, Payments            ● Applied ▾  [Open posting]".
private struct JobDetailHeader: View {
    var job: JobItem
    var copyAll: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            CompanyMonogram(name: job.company, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName).font(Typography.title2).lineLimit(1)
                Text(meta).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            statusMenu
            if let url = (job.applyURL ?? job.sourceURL).flatMap(URL.init(string:)) {
                Button("Open posting") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.glass)
                    .help("Open the job posting in your browser")
            }
            Button("") { copyAll() }
                .keyboardShortcut(.copyAll)
                .hidden()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
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
        let actions = JobDetailRules.statusActions(for: job)
        if actions.isEmpty {
            StatusChip(job: job)
        } else {
            Menu {
                ForEach(actions, id: \.self) { action in
                    Button(action.title) { perform(action) }
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

    private func perform(_ action: JobDetailRules.StatusAction) {
        Task {
            switch action {
            case .setStatus(let status):
                await BoardModel(store: store).move(jobID: job.id, to: status, undoManager: undoManager)
            case .retry:
                if let id = job.applicationID { await store.retryApplication(applicationID: id) }
            case .resolveSubmitted:
                if let id = job.applicationID { await store.resolveUnknown(applicationID: id, submitted: true) }
            case .resolveFailed:
                if let id = job.applicationID { await store.resolveUnknown(applicationID: id, submitted: false) }
            case .approve:
                if let id = job.applicationID { await store.approve(applicationIDs: [id]) }
            case .reject:
                if let id = job.applicationID { await store.reject(applicationID: id, reason: "user") }
            case .applyAnyway:
                if let id = job.applicationID { await store.applyAnyway(applicationID: id) }
            }
        }
    }
}


/// Free-form notes on a job, saved through `update_job_notes` (the daemon is the only writer).
private struct JobNotesEditor: View {
    var jobID: Int
    var notes: String?
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
