// InboxView.swift — the Needs-You inbox screen (docs/UI_UX_PLAN.md §5.5): clusters sorted by
// jobs unblocked on the left, the adaptive answer composer on the right (inline, no modal),
// "Answered today" collapsed at the bottom, and the inbox-zero celebration (§6).
import SwiftUI

@objc(InboxFeature)
final class InboxFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.inbox) { InboxView() }
    }
}

struct InboxView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @Environment(\.undoManager) private var undoManager
    @FocusState private var listFocused: Bool

    private var model: InboxModel { InboxModel.shared(for: store) }

    var body: some View {
        let model = self.model
        VStack(spacing: 0) {
            InboxHeader(model: model)
            Divider()
            if model.isInboxZero {
                InboxZeroView(model: model)
            } else {
                HStack(spacing: 0) {
                    clusterList(model)
                        .frame(width: 340)
                    Divider()
                    Group {
                        if let cluster = model.selectedCluster {
                            AnswerComposer(model: model, cluster: cluster, undoManager: undoManager)
                                .id(cluster.clusterId)
                                .transition(reduced ? AnyTransition.opacity : AnyTransition(.blurReplace))
                        } else {
                            EmptyState(symbol: "hand.raised", title: "Pick a question", message: "Answer once and every job asking it resumes.")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: model.selectedClusterID)
                }
            }
        }
        .background(Palette.windowBackground)
        .onAppear { model.ensureSelection() }
        .onChange(of: store.inbox.clusters.map(\.clusterId)) { model.ensureSelection() }
    }

    private func clusterList(_ model: InboxModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.clusters, id: \.clusterId) { cluster in
                        ClusterRow(model: model, cluster: cluster, isSelected: cluster.clusterId == model.selectedClusterID)
                            .id(cluster.clusterId)
                            .onTapGesture {
                                model.select(cluster.clusterId)
                                listFocused = true
                            }
                            .transition(reduced ? .opacity : .asymmetric(insertion: .rowInsert, removal: .inboxCollapse))
                    }
                    AnsweredTodaySection(model: model)
                        .padding(.top, Space.l)
                }
                .padding(Space.s)
                .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: model.clusters.map(\.clusterId))
                .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: model.clusters.map(\.jobCount))
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
            .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
            .onKeyPress("j") { model.moveSelection(by: 1); return .handled }
            .onKeyPress("k") { model.moveSelection(by: -1); return .handled }
            .onChange(of: model.selectedClusterID) { _, id in
                if let id { withMotion(Motion.snappy, reduceMotion: reduced) { proxy.scrollTo(id) } }
            }
        }
        .background(Palette.surface.opacity(0.4))
        .accessibilityLabel("Questions, sorted by jobs unblocked")
    }
}

// MARK: - Header

private struct InboxHeader: View {
    @Environment(AppStore.self) private var store
    var model: InboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text("Needs You").font(Typography.title1)
                HStack(spacing: Space.xs) {
                    Text("\(model.openCount)").numericRoll(Double(model.openCount))
                    Text(model.openCount == 1 ? "question ·" : "questions ·")
                    Text("\(model.jobsWaiting)").numericRoll(Double(model.jobsWaiting))
                    Text(model.jobsWaiting == 1 ? "job waiting" : "jobs waiting")
                }
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button {
                    Task { await store.runPrepPass() }
                } label: {
                    HStack(spacing: Space.xs) {
                        Text("Run Prep pass")
                        KeyCap(.runPrep)
                    }
                }
                .buttonStyle(.glass)
                .disabled(store.live.activity == .prepping)
                .help("Collect questions from queued jobs before applying")
            }
            if store.live.activity == .prepping {
                let progress = store.live.progress
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(progress.map { "Collecting questions from \($0.total) queued jobs… \($0.done)/\($0.total)" } ?? "Collecting questions from queued jobs…")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                    ProgressView(value: progress.map { $0.total > 0 ? Double($0.done) / Double($0.total) : 0 } ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.contentPadding)
        .padding(.vertical, Space.l)
    }
}

// MARK: - Cluster row

private struct ClusterRow: View {
    var model: InboxModel
    var cluster: QuestionCluster
    var isSelected: Bool

    private var isLocked: Bool { cluster.neverGuessKey != nil || cluster.reason == .neverGuess }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Circle()
                .fill(model.isUnread(cluster) ? Palette.needsYou : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xs) {
                    Text(cluster.canonicalQuestion)
                        .font(Typography.bodyEmph)
                        .lineLimit(2)
                    if isLocked {
                        Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(Palette.textSecondary)
                            .accessibilityLabel("Never-guess fact")
                    }
                    if cluster.reason == .captcha {
                        Image(systemName: "puzzlepiece.extension").imageScale(.small).foregroundStyle(Palette.needsYou)
                    }
                }
                HStack(spacing: Space.xs) {
                    Text(C3Format.plural(cluster.jobCount, "job"))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(cluster.jobCount)))
                    let companies = model.companiesLine(cluster)
                    if !companies.isEmpty {
                        Text("·")
                        Text(companies).lineLimit(1)
                    }
                    if AnswerKind(cluster: cluster) == .longText {
                        Text("· long").foregroundStyle(Palette.textTertiary)
                    }
                }
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(isSelected ? Palette.accent.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy question") { model.copyQuestion(cluster) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cluster.canonicalQuestion), \(C3Format.plural(cluster.jobCount, "job"))\(isLocked ? ", locked" : "")\(model.isUnread(cluster) ? ", unread" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Answered today

private struct AnsweredTodaySection: View {
    var model: InboxModel
    @State private var expanded = false

    var body: some View {
        let rows = model.answeredTodayRows
        if !rows.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(rows) { row in
                        HStack(spacing: Space.s) {
                            Image(systemName: row.status == .answered ? "checkmark.circle.fill" : "arrow.uturn.right.circle")
                                .foregroundStyle(row.status == .answered ? Palette.applied : Palette.textTertiary)
                            Text(row.question).font(Typography.callout).lineLimit(1)
                            Spacer()
                            if row.isPending {
                                Button("Undo") { model.undo(clusterID: row.clusterID) }
                                    .buttonStyle(.link)
                                    .font(Typography.callout)
                            } else {
                                Text(C3Format.plural(row.jobCount, "job")).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, Space.xs)
            } label: {
                HStack(spacing: Space.s) {
                    Text("Answered today").eyebrowStyle()
                    if let latest = rows.first, latest.status == .answered {
                        // The answered cluster's pill: "✓ Answered · 14 jobs resumed".
                        HStack(spacing: Space.xs) {
                            Image(systemName: "checkmark")
                            Text("Answered · \(C3Format.plural(latest.jobCount, "job")) resumed")
                        }
                        .font(Typography.callout)
                        .foregroundStyle(Palette.applied)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 2)
                        .background(Palette.applied.opacity(0.12), in: Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(latest.clusterID)
                    }
                }
            }
            .padding(.horizontal, Space.m)
        }
    }
}

// MARK: - Composer

struct AnswerComposer: View {
    var model: InboxModel
    var cluster: QuestionCluster
    var undoManager: UndoManager?
    @Environment(AppStore.self) private var store
    @State private var showAllVariants = false
    @State private var previewJobID: Int?
    @FocusState private var editorFocused: Bool

    private var kind: AnswerKind { model.kind(for: cluster) }
    private var draft: AnswerDraft { model.draft(for: cluster) }
    private var isLocked: Bool { cluster.neverGuessKey != nil || cluster.reason == .neverGuess }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                questionHeader
                if draft.perJob {
                    perJobList
                } else {
                    editor
                    if kind.supportsTemplate { templateExtras }
                }
                if let message = model.validationMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.error)
                        .transition(.opacity)
                }
                options
                actions
            }
            .padding(Space.contentPadding)
            .frame(maxWidth: 720, alignment: .leading)
            .errorShake(trigger: model.shakeTrigger)
        }
        .onAppear {
            editorFocused = true
            if previewJobID == nil { previewJobID = cluster.jobIds.first }
        }
    }

    // Question + variants

    private var questionHeader: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(cluster.canonicalQuestion).eyebrowStyle()
                if isLocked {
                    Label("Never-guess", systemImage: "lock.fill")
                        .font(Typography.monoSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.sunken, in: Capsule())
                }
            }
            Text(cluster.canonicalQuestion).font(Typography.title2).textSelection(.enabled)
            let others = cluster.variants.filter { $0 != cluster.canonicalQuestion }
            if cluster.jobCount > 0 || !others.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Asked by \(C3Format.plural(cluster.jobCount, "job"))\(others.isEmpty ? "" : " · variants:")")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    if !others.isEmpty {
                        let shown = showAllVariants ? others : Array(others.prefix(2))
                        FlowLayout(spacing: Space.xs) {
                            ForEach(shown, id: \.self) { v in
                                Text("“\(v)”").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                            }
                            if others.count > 2 {
                                Button(showAllVariants ? "Show less" : "+\(others.count - 2)") { showAllVariants.toggle() }
                                    .buttonStyle(.link).font(Typography.callout)
                            }
                        }
                    }
                }
            }
            jobContext
            if let suggestion = cluster.suggestedAnswer, !suggestion.isEmpty {
                if let note = cluster.suggestedNote, !note.isEmpty {
                    Label(note, systemImage: "lightbulb")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("What the agent couldn't find in your profile. Add it to your answer, or to your profile so future drafts include it.")
                }
                // The agent's own draft: shown so the user can accept it in one click or edit it.
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text("Agent's draft").eyebrowStyle()
                        if let c = cluster.suggestedConfidence {
                            Text("\(Int((c * 100).rounded()))% sure").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                        }
                        Spacer()
                        Button("Use draft") { useSuggestion(suggestion) }
                            .buttonStyle(.glass)
                            .help("Put the agent's draft in the answer box; edit it before you answer if needed")
                    }
                    Text(suggestion)
                        .font(Typography.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sunkenWell()
            } else if cluster.reason == .lowConfidence {
                Text("The agent drafted something but wasn't confident enough to submit it.")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    // Which job(s) the question is for, with location: "this country" / sponsorship answers depend on it.

    private var contextJobs: [JobItem] { cluster.jobIds.compactMap { store.jobs.job(id: $0) } }

    private var asksAboutCountry: Bool {
        let q = ([cluster.canonicalQuestion] + cluster.variants).joined(separator: " ").lowercased()
        return ["this country", "country", "sponsor", "visa", "authoriz", "authoris", "right to work", "relocat", "located", "location", "reside"]
            .contains { q.contains($0) }
    }

    @ViewBuilder
    private var jobContext: some View {
        let jobs = contextJobs
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                if asksAboutCountry {
                    let places = Array(Set(jobs.map { InboxJobContext.country(of: $0) })).sorted()
                    let named = places.filter { $0 != InboxJobContext.unknown }
                    Label(named.isEmpty
                          ? "Job location not listed — check the posting before answering."
                          : "Answering for: \(named.joined(separator: ", "))\(places.count > 1 ? " (jobs differ — consider answering per job)" : "")",
                          systemImage: "mappin.and.ellipse")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(named.isEmpty ? Palette.textSecondary : Palette.textPrimary)
                }
                ForEach(jobs.prefix(4)) { job in
                    Button { store.router.openJob(id: job.id) } label: {
                        HStack(spacing: Space.xs) {
                            Text(job.displayName).lineLimit(1)
                            Text("· \(InboxJobContext.where_(job))").foregroundStyle(Palette.textTertiary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .help("Open this job")
                }
                if jobs.count > 4 {
                    Text("+\(jobs.count - 4) more").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private func useSuggestion(_ text: String) {
        model.updateDraft(for: cluster) { d in
            switch kind {
            case .yesNo:
                let t = text.trimmingCharacters(in: .whitespaces).lowercased()
                d.yesNo = t.hasPrefix("y") || t == "true" ? true : (t.hasPrefix("n") || t == "false" ? false : d.yesNo)
            case .choice:
                if let match = cluster.options.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                    d.choices = [match]
                } else {
                    d.text = text
                }
            default:
                d.text = text
            }
        }
    }

    // Adaptive editor

    @ViewBuilder
    private var editor: some View {
        switch kind {
        case .yesNo:
            Picker("Answer", selection: Binding(
                get: { draft.yesNo },
                set: { v in model.updateDraft(for: cluster) { $0.yesNo = v } })) {
                Text("Yes").tag(Bool?.some(true))
                Text("No").tag(Bool?.some(false))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
        case .choice(let multi):
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(multi ? "Pick all that apply (options from the actual forms)" : "Pick one (options from the actual forms)")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                ToggleChips(options: cluster.options, selection: Binding(
                    get: { Set(draft.choices) },
                    set: { new in
                        model.updateDraft(for: cluster) { d in
                            d.choices = multi ? cluster.options.filter(new.contains) : Array(new.subtracting(d.choices).prefix(1))
                            if !multi && d.choices.isEmpty, let only = new.first { d.choices = [only] }
                        }
                    }), label: { $0 }, singleSelection: !multi)
            }
        case .longText:
            VStack(alignment: .leading, spacing: Space.xs) {
                Label("Template answer, personalized per company", systemImage: "text.badge.star")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                TextEditor(text: textBinding)
                    .font(Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(Space.s)
                    .frame(minHeight: 140)
                    .sunkenWell()
                    .focused($editorFocused)
                HStack(spacing: Space.xs) {
                    tokenButton("{company}")
                    tokenButton("{role}")
                    Spacer()
                    Text("\(draft.text.count) characters").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                }
            }
        case .captcha:
            VStack(alignment: .leading, spacing: Space.s) {
                Text("A CAPTCHA blocked the form. A browser window opens automatically; solve it there and the job resumes once it's solved. If it doesn't resume on its own, confirm below.")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary)
                Button {
                    let url = cluster.jobIds.first.flatMap { store.jobs.job(id: $0)?.applyURL }
                    Task { await store.openAgentChrome(url: url) }
                } label: {
                    Label("Open agent Chrome", systemImage: "globe")
                }
                .buttonStyle(.glass)
            }
        default:
            TextField(placeholder, text: textBinding)
                .textFieldStyle(.roundedBorder)
                .font(Typography.body)
                .frame(maxWidth: kind == .number ? 200 : 460)
                .focused($editorFocused)
                .onSubmit { model.submitSelected(undoManager: undoManager) }
        }
        if let memory = model.memorySuggestion(for: cluster), draft.text.isEmpty, kind != .yesNo, kind != .captcha {
            Button {
                model.updateDraft(for: cluster) { $0.text = memory.answer }
            } label: {
                Label("Use your saved answer: “\(memory.answer.prefix(60))\(memory.answer.count > 60 ? "…" : "")”", systemImage: "brain")
                    .font(Typography.callout)
            }
            .buttonStyle(.link)
        }
    }

    private var placeholder: String {
        switch kind {
        case .number: "Number, e.g. 4"
        case .url: "https://…"
        case .email: "you@example.com"
        case .date: "e.g. 2 months from offer"
        default: "Your answer"
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { draft.text }, set: { v in model.updateDraft(for: cluster) { $0.text = v } })
    }

    private func tokenButton(_ token: String) -> some View {
        Button(token) { model.updateDraft(for: cluster) { $0.text += $0.text.hasSuffix(" ") || $0.text.isEmpty ? token : " \(token)" } }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(Typography.mono)
    }

    @ViewBuilder
    private var templateExtras: some View {
        let stories = model.suggestedStories(for: cluster)
        if !stories.isEmpty {
            HStack(spacing: Space.xs) {
                Text("Suggested from your stories:").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                ForEach(stories) { story in
                    Button {
                        model.updateDraft(for: cluster) { d in
                            let snippet = StorySuggester.snippet(story)
                            d.text = d.text.isEmpty ? snippet : d.text + "\n\n" + snippet
                        }
                    } label: {
                        Label(story.title, systemImage: "text.book.closed").font(Typography.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Insert this story's facts (the agent won't invent metrics)")
                }
            }
        }
        let jobs = model.jobs(for: cluster)
        if !jobs.isEmpty, AnswerComposerLogic.usesTokens(draft.text) {
            let current = jobs.first { $0.id == previewJobID } ?? jobs[0]
            VStack(alignment: .leading, spacing: Space.xs) {
                Menu {
                    ForEach(jobs) { job in Button(job.displayName) { previewJobID = job.id } }
                } label: {
                    Text("Preview for \(current.company)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text(AnswerComposerLogic.render(template: draft.text, company: current.company, role: current.title))
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .textSelection(.enabled)
            }
        }
    }

    // Per-job escape hatch

    private var perJobList: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("One answer per job").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            ForEach(cluster.jobIds, id: \.self) { jobID in
                let job = store.jobs.job(id: jobID)
                HStack(spacing: Space.s) {
                    Text(job?.displayName ?? "Job #\(jobID)").font(Typography.body).lineLimit(1).frame(width: 260, alignment: .leading)
                    TextField("Answer", text: Binding(
                        get: { draft.perJobAnswers[jobID] ?? "" },
                        set: { v in model.updateDraft(for: cluster) { $0.perJobAnswers[jobID] = v } }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // Memory / profile / per-job options

    private var options: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if isLocked && cluster.neverGuessKey != nil {
                Toggle(isOn: Binding(get: { draft.saveToProfile }, set: { v in model.updateDraft(for: cluster) { $0.saveToProfile = v } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Save to profile")
                        Text("Stored as a never-guess fact and used for all future forms.")
                            .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(draft.perJob)
            }
            if kind != .captcha {
                Toggle("Save to memory (reuse for future jobs)", isOn: Binding(
                    get: { draft.saveToMemory && !draft.saveToProfile },
                    set: { v in model.updateDraft(for: cluster) { $0.saveToMemory = v } }))
                    .toggleStyle(.checkbox)
                    .disabled(draft.saveToProfile || draft.perJob)
                if cluster.jobIds.count > 1 {
                    Toggle("Answer per job instead", isOn: Binding(
                        get: { draft.perJob },
                        set: { v in model.updateDraft(for: cluster) { $0.perJob = v } }))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .font(Typography.body)
    }

    private var actions: some View {
        HStack(spacing: Space.s) {
            Spacer()
            Button("Skip these jobs") { model.skipSelected(undoManager: undoManager) }
                .buttonStyle(.glass)
                .help("Skip every job that asks this")
            Button {
                model.submitSelected(undoManager: undoManager)
            } label: {
                HStack(spacing: Space.xs) {
                    Text(kind == .captcha ? "I've solved it" : "Answer")
                    KeyCap(.submit)
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.submit)
        }
    }
}

// MARK: - Inbox zero

private struct InboxZeroView: View {
    @Environment(AppStore.self) private var store
    var model: InboxModel

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()
            InboxZeroCelebration(resumedJobs: model.resumedToday, trigger: model.inboxZeroTrigger)
            if model.pendingCount > 0 {
                Button("Undo last answer") { model.undo() }.buttonStyle(.link)
            }
            Spacer()
            AnsweredTodaySection(model: model)
                .frame(maxWidth: 420)
                .padding(.bottom, Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Inbox") {
    let daemon = MockDaemon(scenario: .needsYouStorm)
    let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "needsYouStorm")
    store.start()
    return InboxView()
        .environment(store)
        .environment(store.router)
        .frame(width: 1100, height: 720)
}

/// Location helpers for the Needs-You job context line.
enum InboxJobContext {
    static let unknown = "location not listed"

    static func where_(_ job: JobItem) -> String {
        let loc = job.location?.trimmingCharacters(in: .whitespaces) ?? ""
        let remote = job.remote == .remote ? "Remote" : nil
        if loc.isEmpty { return remote ?? unknown }
        if let remote, !loc.lowercased().contains("remote") { return "\(loc) · \(remote)" }
        return loc
    }

    /// The country part of a job location ("Bengaluru, Karnataka, India" -> "India").
    static func country(of job: JobItem) -> String {
        guard let loc = job.location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty else { return unknown }
        let parts = loc.split(whereSeparator: { $0 == "," || $0 == "·" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "remote" && $0.lowercased() != "hybrid" && $0.lowercased() != "on-site" }
        let last = parts.last ?? loc
        let usStates: Set<String> = ["CA", "NY", "WA", "TX", "MA", "IL", "CO", "GA", "FL", "OR", "NJ", "PA", "VA", "NC", "UT", "AZ", "MN", "MI", "OH", "DC"]
        if usStates.contains(last) || last == "USA" || last == "US" { return "United States" }
        if last == "UK" { return "United Kingdom" }
        return last
    }
}
