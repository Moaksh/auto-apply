// InboxView.swift — Needs You: questions and tasks only you can do. The list has two sections:
// "Tasks for you" (create an account, solve a CAPTCHA, verify; done in the agent's Chrome, then
// tried again) above "Questions" (form fields, sorted by jobs waiting). The right pane is a task
// checklist or the answer composer, whose one primary action is Answer (⌘↵). "Answered today"
// is collapsed at the bottom. Answered jobs go back in the queue for the agent's next run.
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
    @Namespace private var selectionNS

    private var model: InboxModel { InboxModel.shared(for: store) }

    var body: some View {
        let model = self.model
        VStack(spacing: 0) {
            InboxHeader(model: model)
            Divider()
            if !store.hasSnapshot && store.isDaemonUnreachable {
                ErrorState(title: "Can't reach the agent", message: "Questions and tasks show here once the agent is running.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.hasSnapshot {
                LoadingState(message: "Loading questions…")
            } else if model.isInboxZero && model.replyItems.isEmpty {
                InboxZeroView(model: model)
            } else {
                HStack(spacing: 0) {
                    clusterList(model)
                        .frame(width: 340)
                    Divider()
                    Group {
                        if let reply = model.selectedReply {
                            ReplyPane(model: model, item: reply)
                                .id(reply.key)
                                .transition(reduced ? AnyTransition.opacity : AnyTransition(.blurReplace))
                        } else if let cluster = model.selectedCluster {
                            Group {
                                if cluster.isAction {
                                    ActionPane(model: model, cluster: cluster, undoManager: undoManager)
                                } else {
                                    AnswerComposer(model: model, cluster: cluster, undoManager: undoManager)
                                }
                            }
                            .id(cluster.clusterId)
                            .transition(reduced ? AnyTransition.opacity : AnyTransition(.blurReplace))
                        } else {
                            EmptyState(symbol: "hand.raised", title: "Pick a question",
                                       message: "Answer once, and every job that asks it goes back in the queue.")
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
        .onChange(of: model.replyItems.map(\.key)) { model.ensureSelection() }
    }

    private func clusterList(_ model: InboxModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let actions = model.actionClusters
                    let questions = model.questionClusters
                    if !actions.isEmpty {
                        InboxSectionHeader(kind: .action, count: actions.count)
                        ForEach(actions, id: \.clusterId) { row($0, model) }
                    }
                    if !questions.isEmpty {
                        InboxSectionHeader(kind: .question, count: questions.count)
                            .padding(.top, actions.isEmpty ? 0 : Space.m)
                        ForEach(questions, id: \.clusterId) { row($0, model) }
                    }
                    RepliesListSection(model: model)
                        .padding(.top, actions.isEmpty && questions.isEmpty ? 0 : Space.m)
                    AnsweredTodaySection(model: model)
                        .padding(.top, Space.l)
                }
                .padding(Space.s)
                // The selected fill travels from row to row (questions, tasks and replies share it).
                .selectionHighlightGroup(selectionNS, selection: "\(model.selectedClusterID ?? "")|\(model.selectedReply.map { "\($0.key)" } ?? "")")
                .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: model.clusters.map(\.clusterId))
                .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: model.clusters.map(\.jobCount))
            }
            .focusable()
            // The selected row / card shows keyboard focus; the system ring would outline the whole pane.
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
            .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
            .onKeyPress("j") { model.moveSelection(by: 1); return .handled }
            .onKeyPress("k") { model.moveSelection(by: -1); return .handled }
            .onChange(of: model.selectedClusterID) { _, id in
                if let id { withMotion(Motion.snappy, reduceMotion: reduced) { proxy.scrollTo(id) } }
            }
        }
        .accessibilityLabel("Needs You: tasks first, then questions sorted by jobs waiting")
    }

    private func row(_ cluster: QuestionCluster, _ model: InboxModel) -> some View {
        ClusterRow(model: model, cluster: cluster, isSelected: cluster.clusterId == model.selectedClusterID)
            .id(cluster.clusterId)
            .onTapGesture {
                model.select(cluster.clusterId)
                listFocused = true
            }
            .transition(reduced ? .opacity : .asymmetric(insertion: .rowInsert, removal: .inboxCollapse))
    }
}

// MARK: - Section header

/// "TASKS FOR YOU" / "QUESTIONS". Coral marks the tasks (the agent is stuck until you act);
/// questions stay neutral.
private struct InboxSectionHeader: View {
    enum Kind { case action, question }
    var kind: Kind
    var count: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: kind == .action ? "hand.raised.fill" : "text.bubble")
                .imageScale(.small)
                .foregroundStyle(kind == .action ? Palette.needsYou : Palette.textTertiary)
            Text(kind == .action ? "Tasks for you" : "Questions").eyebrowStyle()
            Spacer()
            Text("\(count)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary).numericRoll(Double(count))
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.s)
        .padding(.bottom, Space.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Header

private struct InboxHeader: View {
    @Environment(AppStore.self) private var store
    var model: InboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader("Needs You", summary: InboxHeader.summary(tasks: model.actionCount, questions: model.questionCount,
                                                                     jobs: model.jobsWaiting, replies: model.replyItems.count)) {
                if store.queuedCount > 0 {
                    // Answered jobs go back to the queue: send them now instead of waiting for a full run.
                    Button("Apply \(store.queuedCount) queued now") { Task { await store.applyQueued() } }
                        .buttonStyle(.secondaryLink)
                        .disabled(store.isPaused || !store.isConnected || store.live.activity != .idle)
                        .help("Fill and submit the queued jobs, including ones you just answered, without a new search "
                              + "(\(AppShortcut.applyQueued.displayString))")
                }
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
                .padding(.horizontal, Space.contentPadding)
                .padding(.bottom, Space.m)
                .motionTransition(.rise)
            }
        }
    }

    /// "2 tasks · 5 questions · 14 jobs waiting".
    static func summary(tasks: Int, questions: Int, jobs: Int, replies: Int = 0) -> String {
        var parts: [String] = []
        if tasks > 0 { parts.append(C3Format.plural(tasks, "task")) }
        parts.append(C3Format.plural(questions, "question"))
        parts.append("\(C3Format.plural(jobs, "job")) waiting")
        if replies > 0 { parts.append(C3Format.plural(replies, "reply", "replies")) }
        return parts.joined(separator: " · ")
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
            if cluster.isAction {
                Image(systemName: InboxActionCopy.symbol(cluster))
                    .foregroundStyle(Palette.needsYou)
                    .frame(width: 18)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xs) {
                    Text(model.title(for: cluster))
                        .font(Typography.bodyEmph)
                        .lineLimit(2)
                    if isLocked {
                        Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(Palette.textSecondary)
                            .accessibilityLabel("A fact only you set")
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
                }
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .selectableRow(isSelected: isSelected)
        .contextMenu {
            Button(cluster.isAction ? "Copy task" : "Copy question") { model.copyQuestion(cluster) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cluster.isAction ? "Task: " : "")\(model.title(for: cluster)), \(C3Format.plural(cluster.jobCount, "job"))\(isLocked ? ", locked" : "")\(model.isUnread(cluster) ? ", unread" : "")")
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
                                    .buttonStyle(.secondaryLink)
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
                        Badge("Answered · \(C3Format.plural(latest.jobCount, "job")) back in the queue", symbol: "checkmark",
                              tone: .status(.applied))
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
    /// Inside an outer ScrollView (Job detail's Questions tab): doesn't scroll on its own.
    var embedded = false
    @Environment(AppStore.self) private var store
    @State private var showAllVariants = false
    @State private var previewJobID: Int?
    @FocusState private var editorFocused: Bool

    private var kind: AnswerKind { model.kind(for: cluster) }
    private var draft: AnswerDraft { model.draft(for: cluster) }
    private var isLocked: Bool { cluster.neverGuessKey != nil || cluster.reason == .neverGuess }

    var body: some View {
        InboxPaneScroll(embedded: embedded) {
            VStack(alignment: .leading, spacing: Space.l) {
                questionHeader
                // Who's waiting: these monograms fly to Pipeline when the answer goes out.
                WaitingMonogramRow(model: model, cluster: cluster)
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
            .padding(embedded ? 0 : Space.contentPadding)
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
            if isLocked {
                Badge("Fact only you set", symbol: "lock.fill")
                    .help("The agent never guesses this. Your answer can be saved to your profile.")
            }
            Text(cluster.canonicalQuestion).font(Typography.title2).textSelection(.enabled)
            let others = cluster.variants.filter { $0 != cluster.canonicalQuestion }
            if cluster.jobCount > 0 || !others.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Asked by \(C3Format.plural(cluster.jobCount, "job"))\(others.isEmpty ? "" : " · also asked as:")")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    if !others.isEmpty {
                        let shown = showAllVariants ? others : Array(others.prefix(2))
                        FlowLayout(spacing: Space.xs) {
                            ForEach(shown, id: \.self) { v in
                                Text("“\(v)”").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                            }
                            if others.count > 2 {
                                Button(showAllVariants ? "Show less" : "+\(others.count - 2)") { showAllVariants.toggle() }
                                    .buttonStyle(.secondaryLink).font(Typography.callout)
                            }
                        }
                    }
                }
            }
            jobContext
            if let suggestion = cluster.suggestedAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !suggestion.isEmpty {
                if let note = cluster.suggestedNote, !note.isEmpty {
                    Label(note, systemImage: "lightbulb")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("What the agent couldn't find in your profile. Add it to your answer, or to your profile so future drafts include it.")
                }
                if AnswerDraft.prefill(for: cluster) != nil {
                    // Typed answers: the draft is ghost text in the editor below (its chip says
                    // whose it is). Once it's taken, edited or cleared, this line says so.
                    if model.ghost(for: cluster) == nil { agentDraftLabel(suggestion) }
                } else {
                    // Choices and yes/no: shown here, one click to use.
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.s) {
                            Text("Agent's draft").eyebrowStyle()
                            confidenceText
                            Spacer()
                            Button("Use draft") { useSuggestion(suggestion) }
                                .buttonStyle(.secondaryLink)
                                .help("Put the agent's draft in the answer box; edit it before you answer if needed")
                        }
                        Text(suggestion)
                            .font(Typography.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .well()
                }
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

    @ViewBuilder
    private var confidenceText: some View {
        if let c = cluster.suggestedConfidence {
            Text("\(Int((c * 100).rounded()))% sure").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
        }
    }

    /// "Agent's draft · 62% sure" once its ghost is gone: taken, edited, or cleared with Esc.
    private func agentDraftLabel(_ suggestion: String) -> some View {
        let empty = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: Space.s) {
            Text("Agent's draft").eyebrowStyle()
            confidenceText
            Text(draft.text == suggestion ? "It wasn't sure enough to send this. Check it before answering."
                                          : empty ? "Cleared." : "You've edited the agent's draft.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            Spacer()
            if draft.text != suggestion {
                Button("Restore draft") {
                    if empty { model.restoreGhost(for: cluster) } else { useSuggestion(suggestion) }
                }
                .buttonStyle(.secondaryLink)
                .font(Typography.callout)
                .help(empty ? "Show the agent's draft again" : "Put the agent's draft back in the answer box")
            }
        }
    }

    private func useSuggestion(_ text: String) {
        model.updateDraft(for: cluster) { d in
            switch kind {
            case .yesNo:
                let t = text.trimmingCharacters(in: .whitespaces).lowercased()
                d.yesNo = t.hasPrefix("y") || t == "true" ? true : (t.hasPrefix("n") || t == "false" ? false : d.yesNo)
            case .choice(let multi):
                if let hits = ChoiceLogic.match(text, options: cluster.options, multi: multi) {
                    d.choices = hits
                    d.useOther = false
                } else if ChoiceLogic.allowsOther(cluster) {
                    d.useOther = true
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
            ChoicePicker(model: model, cluster: cluster, multi: multi, focus: $editorFocused, undoManager: undoManager)
        case .longText:
            VStack(alignment: .leading, spacing: Space.xs) {
                Label("Template answer, personalized per company", systemImage: "text.badge.star")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                TextEditor(text: textBinding)
                    .font(Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(Space.s)
                    .frame(minHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if let ghost = model.ghost(for: cluster) {
                            // The text view's own inset: 5pt line-fragment padding inside our padding.
                            GhostText(ghost: ghost)
                                .padding(.leading, Space.s + 5)
                                .padding(.trailing, Space.s)
                                .padding(.vertical, Space.s)
                        }
                    }
                    .well()
                    .focused($editorFocused)
                    .accessibilityHint(model.ghost(for: cluster).map { "Draft available. Press Tab to use it: \($0.text)" } ?? "")
                HStack(spacing: Space.xs) {
                    tokenButton("{company}")
                    tokenButton("{role}")
                    Spacer()
                    Text("\(draft.text.count) characters").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                }
            }
        case .action:
            EmptyView()  // agent blockers use ActionPane
        default:
            let ghost = model.ghost(for: cluster)
            TextField(ghost == nil ? placeholder : "", text: textBinding)
                .textFieldStyle(.roundedBorder)
                .font(Typography.body)
                .overlay(alignment: .leading) {
                    if let ghost {
                        GhostText(ghost: ghost, lineLimit: 1).padding(.horizontal, 5)
                    }
                }
                .frame(maxWidth: kind == .number ? 200 : 460)
                .focused($editorFocused)
                .onSubmit { model.submitSelected(undoManager: undoManager) }
                .accessibilityHint(ghost.map { "Draft available. Press Tab to use it: \($0.text)" } ?? "")
        }
        if let ghost = model.ghost(for: cluster), kind != .action {
            GhostDraftBar(model: model, cluster: cluster, ghost: ghost)
                .frame(maxWidth: kind == .longText ? .infinity : 460)
                .transition(.opacity)
        }
        if model.supportsAIDraft(cluster) && !draft.perJob {
            AIDraftControls(model: model, cluster: cluster)
        }
        if let memory = model.memorySuggestion(for: cluster), draft.text.isEmpty || draft.text == AnswerDraft.prefill(for: cluster),
           kind != .yesNo, kind != .action {
            Button {
                useSuggestion(memory.answer)
            } label: {
                Label("Use your saved answer: “\(memory.answer.prefix(60))\(memory.answer.count > 60 ? "…" : "")”", systemImage: "brain")
                    .font(Typography.callout)
            }
            .buttonStyle(.secondaryLink)
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
                    .help("Insert this story's facts into your answer")
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
                    .well()
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
                        Text("Saved as a fact only you set and used on every future form.")
                            .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(draft.perJob)
            }
            if kind != .action {
                Toggle("Remember this answer for future jobs", isOn: Binding(
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
                .buttonStyle(.secondaryLink)
                .help("Skip every job that asks this")
            Button {
                model.submitSelected(undoManager: undoManager)
            } label: {
                HStack(spacing: Space.xs) {
                    Text("Answer")
                    KeyCap(.submit)
                }
            }
            .buttonStyle(.primaryPill)
            .keyboardShortcut(.submit)
        }
    }
}

/// The answer panes scroll on their own in Needs You, but not when embedded in a scrolling page.
private struct InboxPaneScroll<Content: View>: View {
    var embedded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if embedded { content } else { ScrollView { content } }
    }
}

// MARK: - Choice picker

/// Options as choices: chips with 1–9 number keys for a few short options, a filterable list
/// for more, and "Other…" free text only when the field isn't a strict select.
private struct ChoicePicker: View {
    var model: InboxModel
    var cluster: QuestionCluster
    var multi: Bool
    var focus: FocusState<Bool>.Binding
    var undoManager: UndoManager?
    @FocusState private var otherFocused: Bool

    private var draft: AnswerDraft { model.draft(for: cluster) }
    private var style: ChoiceLogic.Style { ChoiceLogic.style(for: cluster.options) }
    private var visible: [String] {
        style == .chips ? cluster.options : ChoiceLogic.filter(cluster.options, query: draft.choiceQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(multi ? "Pick all that apply · options from the actual form" : "Pick one · options from the actual form")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            Group {
                if style == .chips { chips } else { searchable }
            }
            .focusable()
            .focused(focus)
            .onKeyPress(characters: .decimalDigits) { press in
                guard let key = press.characters.first, let option = ChoiceLogic.option(forKey: key, in: Array(visible.prefix(9))) else {
                    return .ignored
                }
                pick(option)
                return .handled
            }
            if ChoiceLogic.allowsOther(cluster) { other }
        }
    }

    private var chips: some View {
        FlowLayout(spacing: Space.xs) {
            ForEach(Array(cluster.options.enumerated()), id: \.element) { i, option in
                chip(option, number: i + 1)
            }
        }
    }

    private var searchable: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            TextField("Filter \(cluster.options.count) options", text: Binding(
                get: { draft.choiceQuery },
                set: { v in model.updateDraft(for: cluster) { $0.choiceQuery = v } }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit { if let first = visible.first { pick(first) } }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(visible.enumerated()), id: \.element) { i, option in
                        let on = !draft.useOther && draft.choices.contains(option)
                        Button { pick(option) } label: {
                            HStack(spacing: Space.s) {
                                Image(systemName: on ? (multi ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                     : (multi ? "square" : "circle"))
                                    .foregroundStyle(on ? Palette.accent : Palette.textTertiary)
                                Text(option).font(Typography.body).frame(maxWidth: .infinity, alignment: .leading)
                                if i < 9 {
                                    Text("\(i + 1)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                                }
                            }
                            .padding(.horizontal, Space.s).padding(.vertical, 4)
                            .background(on ? Palette.accent.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    if visible.isEmpty {
                        Text("No option matches.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .frame(maxWidth: 460, maxHeight: 220)
            .well()
        }
    }

    private func chip(_ option: String, number: Int) -> some View {
        let on = !draft.useOther && draft.choices.contains(option)
        return Button { pick(option) } label: {
            HStack(spacing: Space.xs) {
                Text("\(number)").font(Typography.monoSmall).foregroundStyle(on ? Palette.accent : Palette.textTertiary)
                Text(option).font(Typography.body)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, 5)
            .background(on ? Palette.accent.opacity(0.12) : Palette.sunken, in: Capsule())
            .overlay(Capsule().stroke(on ? Palette.accent.opacity(0.5) : Palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Press \(number)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private var other: some View {
        if draft.useOther {
            HStack(spacing: Space.s) {
                TextField("Other: type your answer", text: Binding(
                    get: { draft.text },
                    set: { v in model.updateDraft(for: cluster) { $0.text = v } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .focused($otherFocused)
                    .onSubmit { model.submitSelected(undoManager: undoManager) }
                Button("Use the options") { model.updateDraft(for: cluster) { $0.useOther = false } }
                    .buttonStyle(.secondaryLink).font(Typography.callout)
            }
        } else {
            Button("Other…") {
                model.updateDraft(for: cluster) { $0.useOther = true }
                otherFocused = true
            }
            .buttonStyle(.secondaryLink)
            .font(Typography.callout)
            .help("None of these fit: type your own answer")
        }
    }

    private func pick(_ option: String) {
        model.updateDraft(for: cluster) { d in
            d.useOther = false
            d.choices = ChoiceLogic.pick(option, in: d.choices, multi: multi, order: cluster.options)
        }
    }
}

// MARK: - Action pane

/// Detail pane for a task: what to do, why the agent stopped, the jobs waiting, and "Open in the
/// agent's Chrome" / "Done, try again" / "Skip these jobs". No answer box, nothing is saved, and
/// the user is never asked to type a password here.
struct ActionPane: View {
    var model: InboxModel
    var cluster: QuestionCluster
    var undoManager: UndoManager?
    /// Inside an outer ScrollView (Job detail's Questions tab): doesn't scroll on its own.
    var embedded = false
    @Environment(AppStore.self) private var store
    @State private var opening = false

    private var jobs: [JobItem] { model.jobs(for: cluster) }

    var body: some View {
        InboxPaneScroll(embedded: embedded) {
            VStack(alignment: .leading, spacing: Space.l) {
                header
                stepsList
                evidence
                affectedJobs
                actions
            }
            .padding(embedded ? 0 : Space.contentPadding)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Badge("The agent is stuck until you do this", symbol: "hand.raised.fill", tone: .warning)
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: InboxActionCopy.symbol(cluster)).foregroundStyle(Palette.needsYou)
                Text(InboxActionCopy.title(cluster)).font(Typography.title2).textSelection(.enabled)
            }
            Text(InboxActionCopy.explanation(cluster))
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(InboxActionCopy.steps(cluster, jobs: cluster.jobCount).enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text("\(i + 1)")
                        .font(Typography.monoSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(Palette.sunken, in: Circle())
                    Text(step).font(Typography.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }

    /// What the agent actually hit ("Choose Password", "Retype Password", the site).
    @ViewBuilder
    private var evidence: some View {
        let lines = InboxActionCopy.evidence(cluster).filter { $0 != InboxActionCopy.title(cluster) }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("What the agent saw").eyebrowStyle()
                FlowLayout(spacing: Space.xs) {
                    ForEach(lines, id: \.self) { line in
                        Badge(line)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var affectedJobs: some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                // Who's waiting: these monograms fly to Pipeline on "Done, try again".
                WaitingMonogramRow(model: model, cluster: cluster)
                    .padding(.bottom, Space.xxs)
                ForEach(jobs.prefix(6)) { job in
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
                if jobs.count > 6 {
                    Text("+\(jobs.count - 6) more").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Space.s) {
            Button {
                opening = true
                Task {
                    await model.openAgentChrome(for: cluster)
                    opening = false
                }
            } label: {
                Label("Open in the agent's Chrome", systemImage: "globe")
            }
            .buttonStyle(.secondaryLink)
            .disabled(opening)
            .help("Opens the application page in the Chrome profile the agent uses, so what you do there carries over")
            Spacer()
            Button(cluster.jobCount == 1 ? "Skip this job" : "Skip these jobs") { model.skipSelected(undoManager: undoManager) }
                .buttonStyle(.secondaryLink)
                .help("Skip every job waiting on this")
            Button {
                model.completeSelectedAction(undoManager: undoManager)
            } label: {
                HStack(spacing: Space.xs) {
                    Text("Done, try again")
                    KeyCap(.submit)
                }
            }
            .buttonStyle(.primaryPill)
            .keyboardShortcut(.submit)
            .help(cluster.jobCount == 1 ? "You did the step: the job goes back in the queue"
                  : "You did the step: the \(cluster.jobCount) jobs go back in the queue")
        }
    }
}

// MARK: - Inbox zero

private struct InboxZeroView: View {
    @Environment(AppStore.self) private var store
    var model: InboxModel

    var body: some View {
        VStack(spacing: Space.l) {
            Spacer()
            InboxZeroCelebration(resumedJobs: model.resumedToday, trigger: model.inboxZeroTrigger)
            if model.pendingCount > 0 {
                Button("Undo last answer") { model.undo() }.buttonStyle(.secondaryLink)
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
