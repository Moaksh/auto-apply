// InboxModel.swift — Needs-You inbox logic (docs/UI_UX_PLAN.md §5.5): impact-first clusters,
// an adaptive composer per cluster, answer-once with a 10 s Undo window (the command is held
// until the window closes, so Undo is a true undo), auto-advance, and the inbox-zero moment.
import AppKit
import Foundation
import Observation

/// How the composer adapts to a cluster's question.
enum AnswerKind: Equatable, Sendable {
    case shortText
    case longText          // template with {company} / {role} tokens + per-company preview
    case number
    case yesNo
    case choice(multi: Bool)
    case url
    case email
    case date
    case action            // agent blocker: no answer box — "do it in the agent's Chrome, then retry"

    init(cluster: QuestionCluster) {
        if cluster.isAction { self = .action; return }
        // Options decide, not field_type: forms often report dropdowns / scales ("Strong No" …
        // "Strong Yes") as text fields that carry options.
        if !cluster.options.isEmpty {
            self = .choice(multi: cluster.fieldType == .multiselect)
            return
        }
        switch cluster.fieldType {
        case .textarea: self = .longText
        case .number: self = .number
        case .boolean: self = .yesNo
        case .select: self = cluster.options.isEmpty ? .shortText : .choice(multi: false)
        case .multiselect: self = cluster.options.isEmpty ? .shortText : .choice(multi: true)
        case .url: self = .url
        case .email: self = .email
        case .date: self = .date
        case .text, .phone, .file:
            // "Why…", "Describe…", "Tell us…" read as essays even when the form used a text input.
            let q = cluster.canonicalQuestion.lowercased()
            let essay = ["why ", "describe", "tell us", "what draws", "what excites", "explain", "how would you"].contains { q.hasPrefix($0) || q.contains(" \($0)") }
            self = essay ? .longText : .shortText
        }
    }

    var supportsTemplate: Bool { self == .longText }
}

/// Per-cluster composer state. Drafts survive switching between clusters.
struct AnswerDraft: Equatable, Sendable {
    var text = ""
    var yesNo: Bool?
    var choices: [String] = []
    var saveToMemory = true
    /// Never-guess clusters: write the value into the profile's facts instead of memory.
    var saveToProfile = false
    /// Choice questions: "Other…" free text instead of a listed option (non-strict fields only).
    var useOther = false
    /// Choice questions with many options: the search filter.
    var choiceQuery = ""
    /// "Answer per job instead" escape hatch.
    var perJob = false
    var perJobAnswers: [Int: String] = [:]

    init() {}

    init(cluster: QuestionCluster) {
        let isNeverGuess = cluster.neverGuessKey != nil || cluster.reason == .neverGuess
        saveToProfile = isNeverGuess && cluster.neverGuessKey != nil
        saveToMemory = !saveToProfile && !cluster.isAction
        // The editor starts empty: the agent's stored draft shows as ghost text over it (Tab takes
        // it, see `InboxModel.ghost(for:)`), never as if the user had typed it. Choice and yes/no
        // questions keep it one click away instead: a pre-picked guess is too easy to send unread.
    }

    /// The agent's stored draft when it belongs in a text editor (shown as ghost text), else nil.
    static func prefill(for cluster: QuestionCluster) -> String? {
        guard let s = cluster.suggestedAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        switch AnswerKind(cluster: cluster) {
        case .shortText, .longText, .number, .url, .email, .date: return s
        case .yesNo, .choice, .action: return nil
        }
    }
}

/// "Draft with AI" for one cluster (protocol.md §5.5): what the agent last wrote, the
/// instructions asked this session, and the editor's earlier versions for Undo. Lives only in
/// this session, like the drafts themselves.
struct AIDraftState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case drafting(revising: Bool)
        case failed(String)
    }

    var phase: Phase = .idle
    /// The "Tell the agent what to change…" field.
    var instruction = ""
    /// Instructions sent this session, oldest first.
    var history: [String] = []
    /// Editor texts replaced by the agent, oldest first ("Undo" pops the last).
    var versions: [String] = []
    /// The last result (grounding, sources); nil after Undo.
    var result: DraftAnswerResult?
    /// The last result is ghost text over an empty editor, not yet taken (Tab takes it).
    var resultIsGhost = false
    /// Esc cleared the ghost (the agent's stored draft or an AI draft); a new draft brings it back.
    var ghostDismissed = false
    /// Tab was pressed once on a ghost that isn't grounded: its warning shows, and only a second
    /// Tab (or ⌥Tab / "Use anyway") takes it.
    var confirmingUngrounded = false
    /// Earlier ghost drafts replaced by a rewrite, oldest first ("Undo" pops the last).
    var ghostVersions: [DraftAnswerResult] = []

    static let historyLimit = 8
    static let versionLimit = 20

    var isDrafting: Bool { if case .drafting = phase { true } else { false } }

    var errorMessage: String? { if case .failed(let m) = phase { m } else { nil } }

    /// Undo has something to go back to: an editor text the agent replaced, or an earlier ghost.
    var canUndo: Bool { !versions.isEmpty || (resultIsGhost && !ghostVersions.isEmpty) }

    /// Unsupported claims still present in `text` (a claim the user already removed stops warning).
    /// A ghost that hasn't been taken warns through `GhostDraft` instead.
    func unsupportedClaims(in text: String) -> [String] {
        guard let result, !result.grounded, !resultIsGhost else { return [] }
        return result.unsupportedClaims.filter { text.range(of: $0, options: .caseInsensitive) != nil }
    }
}

/// A draft shown as ghost text over an empty editor (docs/DESIGN_AWARD_VISION.md 1D): tinted,
/// labelled with where it came from, taken with Tab. One that isn't grounded in the user's facts
/// says so and needs a second Tab (or ⌥Tab) to take.
struct GhostDraft: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The agent's stored draft from the form pass (`suggested_answer`).
        case stored(confidence: Double?)
        /// "Draft with AI" / a rewrite, with what it used.
        case drafted(sources: [String])
    }

    var text: String
    var source: Source
    var grounded: Bool
    var unsupportedClaims: [String]

    /// The provenance chip under the ghost.
    var chip: String {
        switch source {
        case .stored(let c):
            return c.map { "Agent's draft · \(Int(($0 * 100).rounded()))% sure" } ?? "Agent's draft"
        case .drafted(let sources):
            guard grounded else { return "Draft · not from your facts" }
            let named = sources.map(Self.plain).filter { !$0.isEmpty }
            return named.isEmpty ? "Draft · from your facts" : "Draft · from " + Self.list(Array(named.prefix(3)))
        }
    }

    /// "Profile" → "your profile"; anything else as the agent named it.
    static func plain(_ source: String) -> String {
        let s = source.trimmingCharacters(in: .whitespaces)
        switch s.lowercased() {
        case "profile", "resume", "stories", "story bank", "saved answers", "instructions": return "your " + s.lowercased()
        default: return s
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

/// What Tab did to a ghost draft.
enum GhostAcceptance: Equatable, Sendable {
    /// The ghost is now the editor's text.
    case accepted
    /// Not grounded: the warning shows; Tab again (or ⌥Tab) takes it.
    case needsConfirmation
    /// No ghost showing.
    case nothing
}

enum AnswerValidationError: Error, Equatable, Sendable {
    case empty
    case notANumber
    case invalidURL
    case invalidEmail
    case missingPerJob(count: Int)

    var message: String {
        switch self {
        case .empty: "Type an answer first."
        case .notANumber: "This one needs a number."
        case .invalidURL: "That doesn't look like a link (https://…)."
        case .invalidEmail: "That doesn't look like an email address."
        case .missingPerJob(let n): n == 1 ? "One job still needs an answer." : "\(n) jobs still need an answer."
        }
    }
}

/// The validated, wire-ready answer for `answer_question`.
struct ResolvedAnswer: Equatable, Sendable {
    var answer: String
    var saveToMemory: Bool
    var saveToProfile: Bool
    var perJobAnswers: [PerJobAnswer]
}

enum AnswerComposerLogic {
    /// Validate a draft into the payload fields, or say what's wrong.
    static func resolve(_ draft: AnswerDraft, kind: AnswerKind, jobIDs: [Int]) -> Result<ResolvedAnswer, AnswerValidationError> {
        if draft.perJob {
            let missing = jobIDs.filter { (draft.perJobAnswers[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !missing.isEmpty { return .failure(.missingPerJob(count: missing.count)) }
            let answers = jobIDs.map { PerJobAnswer(jobId: $0, answer: draft.perJobAnswers[$0]!.trimmingCharacters(in: .whitespacesAndNewlines)) }
            for a in answers {
                if case .failure(let e) = validateValue(a.answer, kind: kind) { return .failure(e) }
            }
            // `answer` is required on the wire: use the most common per-job value.
            let counts = Dictionary(grouping: answers.map(\.answer), by: { $0 }).mapValues(\.count)
            let representative = counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? answers[0].answer
            return .success(ResolvedAnswer(answer: representative, saveToMemory: false, saveToProfile: false, perJobAnswers: answers))
        }
        let value: String
        switch kind {
        case .yesNo:
            guard let yes = draft.yesNo else { return .failure(.empty) }
            value = yes ? "Yes" : "No"
        case .choice:
            if draft.useOther {
                value = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                guard !draft.choices.isEmpty else { return .failure(.empty) }
                value = draft.choices.joined(separator: ", ")
            }
        case .action:
            // "Done, retry": the daemon ignores the text and never stores it.
            return .success(ResolvedAnswer(answer: "done", saveToMemory: false, saveToProfile: false, perJobAnswers: []))
        default:
            value = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if case .failure(let e) = validateValue(value, kind: kind) { return .failure(e) }
        return .success(ResolvedAnswer(answer: value, saveToMemory: draft.saveToMemory && !draft.saveToProfile,
                                       saveToProfile: draft.saveToProfile, perJobAnswers: []))
    }

    static func validateValue(_ value: String, kind: AnswerKind) -> Result<Void, AnswerValidationError> {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return .failure(.empty) }
        switch kind {
        case .number:
            // Allow "4", "4.5", "4 years", "₹45L"-style values only when they start numeric.
            let numeric = v.replacingOccurrences(of: ",", with: "")
            guard let first = numeric.split(separator: " ").first, Double(first) != nil else { return .failure(.notANumber) }
        case .url:
            guard let url = URL(string: v.contains("://") ? v : "https://\(v)"), let host = url.host, host.contains(".") else {
                return .failure(.invalidURL)
            }
        case .email:
            let parts = v.split(separator: "@")
            guard parts.count == 2, parts[1].contains("."), !v.contains(" ") else { return .failure(.invalidEmail) }
        default:
            break
        }
        return .success(())
    }

    /// `{company}` / `{role}` substitution for the per-company preview.
    static func render(template: String, company: String, role: String) -> String {
        template
            .replacingOccurrences(of: "{company}", with: company)
            .replacingOccurrences(of: "{role}", with: role)
    }

    static func usesTokens(_ text: String) -> Bool { text.contains("{company}") || text.contains("{role}") }
}

/// Choice questions (any question that lists options): chips with 1–9 shortcuts for a few short
/// options, a searchable list for more; "Other…" free text only when the field isn't a strict select.
enum ChoiceLogic {
    enum Style: Equatable, Sendable { case chips, searchable }

    /// Up to this many short options render as chips.
    static let chipLimit = 5
    static let shortOption = 28

    static func style(for options: [String]) -> Style {
        options.count <= chipLimit && options.allSatisfy { $0.count <= shortOption } ? .chips : .searchable
    }

    /// Free text is allowed unless the form said the field is a select / multiselect / boolean.
    static func allowsOther(_ cluster: QuestionCluster) -> Bool {
        ![.select, .multiselect, .boolean].contains(cluster.fieldType)
    }

    /// Options matching a search query (case- and diacritic-insensitive substring), in form order.
    static func filter(_ options: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return options }
        return options.filter { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The option bound to number key "1"…"9" among the visible options.
    static func option(forKey key: Character, in options: [String]) -> String? {
        guard let n = key.wholeNumberValue, (1...9).contains(n), n <= options.count else { return nil }
        return options[n - 1]
    }

    /// New selection after picking `option`: single select replaces, multi toggles (kept in form order).
    static func pick(_ option: String, in current: [String], multi: Bool, order: [String]) -> [String] {
        guard multi else { return [option] }
        var set = Set(current)
        if set.contains(option) { set.remove(option) } else { set.insert(option) }
        return order.filter(set.contains) + current.filter { !order.contains($0) && set.contains($0) }
    }

    /// An agent draft / restored answer mapped back onto the options (exact, case-insensitive).
    static func match(_ answer: String, options: [String], multi: Bool) -> [String]? {
        let parts = multi ? answer.components(separatedBy: ", ") : [answer]
        let hits = parts.compactMap { part in
            options.first { $0.caseInsensitiveCompare(part.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        }
        return hits.count == parts.count && !hits.isEmpty ? hits : nil
    }
}

/// Plain-English copy for agent blockers (kind "action"): the task title, why the agent
/// stopped, and what to do. Never asks for a password.
enum InboxActionCopy {
    /// "Create an account at JPMC" — the task, not the form label.
    static func title(_ cluster: QuestionCluster) -> String {
        let at = companies(cluster)
        switch cluster.action {
        case .account: return at.isEmpty ? "Create an account or sign in" : "Create an account or sign in at \(at)"
        case .captcha: return at.isEmpty ? "Solve the CAPTCHA" : "Solve the CAPTCHA at \(at)"
        case .verification: return at.isEmpty ? "Finish the email or phone verification" : "Finish verifying at \(at)"
        case .other, nil: return cluster.canonicalQuestion
        }
    }

    /// Why the agent stopped, in one or two sentences.
    static func explanation(_ cluster: QuestionCluster) -> String {
        switch cluster.action {
        case .account:
            return "This application site wants an account before it shows the form, and I couldn't get one by "
                + "myself (account creation is off, no email is connected, or the site blocked it). Its saved password, "
                + "if any, is in Settings ▸ Guardrails ▸ Job-site accounts."
        case .captcha:
            return "A CAPTCHA or bot check appeared on the form. Only a person can get past it, so I stopped."
        case .verification:
            return "The site sent a verification code or link. I can't open your messages, so I stopped here."
        case .other, nil:
            return "I can't continue on my own. Do this step yourself, then retry, or skip these jobs."
        }
    }

    /// Numbered steps shown under the explanation.
    static func steps(_ cluster: QuestionCluster, jobs: Int) -> [String] {
        let retry = jobs == 1 ? "Click Done, try again. The job goes back in the queue." : "Click Done, try again. The \(jobs) jobs go back in the queue."
        switch cluster.action {
        case .account:
            return ["Open the agent's Chrome. The application page loads there.",
                    "Create the account or sign in yourself, and choose your own password there. Don't type it into AutoApply.",
                    retry + " It reuses the signed-in session."]
        case .captcha:
            return ["Open the agent's Chrome and solve the check.", retry]
        case .verification:
            return ["Open the agent's Chrome and finish verifying, using the code or link from your email or phone.", retry]
        case .other, nil:
            return ["Do the step above, in the agent's Chrome if it needs the site.", retry]
        }
    }

    /// SF Symbol per action type.
    static func symbol(_ cluster: QuestionCluster) -> String {
        switch cluster.action {
        case .account: "person.badge.key"
        case .captcha: "puzzlepiece.extension"
        case .verification: "envelope.badge"
        case .other, nil: "hand.raised"
        }
    }

    /// Field labels the agent hit ("Choose Password", "Retype Password"), excluding the title wording.
    static func evidence(_ cluster: QuestionCluster) -> [String] {
        var seen = Set<String>()
        return ([cluster.canonicalQuestion] + cluster.variants).filter { seen.insert($0.lowercased()).inserted }
    }

    private static func companies(_ cluster: QuestionCluster) -> String {
        var seen = Set<String>()
        let names = cluster.companies.filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return "" }
        return names.count > 2 ? "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)" : names.joined(separator: " and ")
    }
}

/// Ranks stories against a question by tag / keyword overlap ("Suggested from your stories").
enum StorySuggester {
    private static let stopwords: Set<String> = ["the", "a", "an", "you", "your", "to", "of", "and", "in", "on", "at", "for", "with",
                                                 "do", "did", "how", "what", "why", "when", "tell", "us", "about", "time", "describe", "is", "are", "we", "our"]

    static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stopwords.contains($0) })
    }

    static func rank(question: String, stories: [StoryItem], limit: Int = 3) -> [StoryItem] {
        let q = keywords(question)
        guard !q.isEmpty else { return [] }
        let scored: [(StoryItem, Int)] = stories.map { story in
            let tags = Set(story.tags.map { $0.lowercased() })
            let body = keywords([story.title, story.situation, story.task, story.action, story.result].joined(separator: " "))
            let score = q.intersection(tags).count * 3 + q.intersection(body).count
            return (story, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.uses > $1.0.uses }.prefix(limit).map(\.0)
    }

    /// Compact first-person paragraph to drop into a draft.
    static func snippet(_ story: StoryItem) -> String {
        [story.situation, story.action, story.result].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// One answered/skipped cluster for the collapsed "Answered today" section.
struct InboxAnsweredRecord: Identifiable, Equatable, Sendable {
    var id: String { clusterID }
    var clusterID: String
    var question: String
    var jobCount: Int
    var status: QuestionResolvedPayload.Status
    var at: Date
    /// Still inside the Undo window (command not sent yet).
    var isPending: Bool
}

@MainActor
@Observable
final class InboxModel {
    let store: AppStore
    @ObservationIgnored var clipboard: ClipboardWriting = SystemClipboard.shared

    /// Undo window before the answer is actually sent (§5.5: "Undo (⌘Z) is available for 10s").
    @ObservationIgnored var undoWindow: Duration = .seconds(10)

    var selectedClusterID: String?
    /// The selected item in the Replies section (mutually exclusive with a selected cluster).
    var selectedReplyKey: NeedsYouReply.Key?
    private(set) var drafts: [String: AnswerDraft] = [:]
    /// "Draft with AI" state per cluster (this session only).
    private(set) var aiDrafts: [String: AIDraftState] = [:]
    private(set) var answered: [InboxAnsweredRecord] = []
    private(set) var seenClusterIDs: Set<String> = []
    /// Bumps on the transition to zero open clusters (drives the celebration once per transition).
    private(set) var inboxZeroTrigger = 0
    /// Inline validation message for the selected cluster (cleared on edit).
    var validationMessage: String?
    /// Bumped to shake the composer on invalid input.
    private(set) var shakeTrigger = 0
    /// "One answer, many doors": the jobs an answer just sent back to the queue, flying to the
    /// sidebar's Pipeline row during the Undo window. Nil when nothing is in flight or held.
    private(set) var cascade: AnswerCascade?
    /// Bumps once when a cascade's last job lands on the Pipeline row (its badge pulses once).
    private(set) var cascadePulse = 0
    @ObservationIgnored private var cascadeSequence = 0
    /// Starts the flight for a new cascade (the overlay window in the app; tests swap it). It must
    /// land the cascade with `landCascade`, at once when there's nothing to fly.
    @ObservationIgnored var cascadeLauncher: @MainActor (AnswerCascade, InboxModel) -> Void = { cascade, model in
        CascadeFlight.launch(cascade, model: model)
    }

    private struct Pending {
        var cluster: QuestionCluster
        var answer: ResolvedAnswer?   // nil = skip
        var skipReason: String?
        var task: Task<Void, Never>
        /// When the Undo window opened, and the cluster's `resolvedToday` timestamp at that moment
        /// (if it had one) — used to tell whether the daemon resolved it while we held the answer.
        var enqueuedAt: Date
        var priorResolvedAt: Date?
    }
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    static func shared(for store: AppStore) -> InboxModel {
        FeatureModels.model(InboxModel.self, for: store) { InboxModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSynchronouslyOnQuit() }
        }
    }

    // MARK: Derived

    /// Open clusters in list order: agent blockers first, then questions; impact first within
    /// each (the store already sorts this way). Keyboard navigation follows this order.
    var clusters: [QuestionCluster] {
        let open = store.inbox.clusters.filter { pending[$0.clusterId] == nil }
        return open.filter(\.isAction) + open.filter { !$0.isAction }
    }

    /// "Agent is blocked · needs you to act" section.
    var actionClusters: [QuestionCluster] { clusters.filter(\.isAction) }

    /// "Questions to answer" section.
    var questionClusters: [QuestionCluster] { clusters.filter { !$0.isAction } }

    var actionCount: Int { actionClusters.count }

    var questionCount: Int { questionClusters.count }

    /// Header line: "3 to do · 34 questions".
    var summary: String { InboxStore.summary(actions: actionCount, questions: questionCount) }

    /// List / palette title: the task for an action, the question otherwise.
    func title(for cluster: QuestionCluster) -> String {
        cluster.isAction ? InboxActionCopy.title(cluster) : cluster.canonicalQuestion
    }

    var selectedCluster: QuestionCluster? {
        guard let id = selectedClusterID else { return nil }
        return clusters.first { $0.clusterId == id }
    }

    var openCount: Int { clusters.count }

    var jobsWaiting: Int { Set(clusters.flatMap(\.jobIds)).count }

    var pendingCount: Int { pending.count }

    /// Total jobs resumed by answers today (inbox-zero subline).
    var resumedToday: Int { answered.filter { $0.status == .answered }.reduce(0) { $0 + $1.jobCount } }

    var isInboxZero: Bool { clusters.isEmpty }

    func isUnread(_ cluster: QuestionCluster) -> Bool { !seenClusterIDs.contains(cluster.clusterId) }

    func kind(for cluster: QuestionCluster) -> AnswerKind { AnswerKind(cluster: cluster) }

    func draft(for cluster: QuestionCluster) -> AnswerDraft { drafts[cluster.clusterId] ?? AnswerDraft(cluster: cluster) }

    func updateDraft(for cluster: QuestionCluster, _ body: (inout AnswerDraft) -> Void) {
        var d = draft(for: cluster)
        let before = d.text
        body(&d)
        drafts[cluster.clusterId] = d
        validationMessage = nil
        // Typing replaces a ghost: a pending "Tab again to use it anyway" no longer applies.
        if d.text != before, aiDrafts[cluster.clusterId]?.confirmingUngrounded == true {
            aiDrafts[cluster.clusterId]?.confirmingUngrounded = false
        }
    }

    /// Jobs (company + role) blocked by a cluster, for previews and the per-job list.
    func jobs(for cluster: QuestionCluster) -> [JobItem] {
        cluster.jobIds.compactMap { store.jobs.job(id: $0) }
    }

    /// "Stripe, Ramp, +12"
    func companiesLine(_ cluster: QuestionCluster, max: Int = 2) -> String {
        var names = cluster.companies
        if names.isEmpty { names = jobs(for: cluster).map(\.company) }
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(max).joined(separator: ", ")
        return names.count > max ? "\(shown), +\(names.count - max)" : shown
    }

    func suggestedStories(for cluster: QuestionCluster) -> [StoryItem] {
        guard kind(for: cluster) == .longText else { return [] }
        return StorySuggester.rank(question: cluster.canonicalQuestion + " " + cluster.variants.joined(separator: " "),
                                   stories: store.library.stories)
    }

    /// An existing memory answer for a near-identical question (offered as a starting point).
    func memorySuggestion(for cluster: QuestionCluster) -> MemoryAnswerItem? {
        let q = StorySuggester.keywords(cluster.canonicalQuestion)
        guard !q.isEmpty else { return nil }
        var best: MemoryAnswerItem?
        var bestScore = 0.6
        for answer in store.library.memoryAnswers {
            let k = StorySuggester.keywords(answer.canonicalQuestion)
            guard !k.isEmpty else { continue }
            let jaccard = Double(q.intersection(k).count) / Double(q.union(k).count)
            if jaccard >= bestScore {
                bestScore = jaccard
                best = answer
            }
        }
        return best
    }

    // MARK: Ghost drafts

    /// The draft shown as ghost text over the editor: an AI draft not yet taken, else the
    /// agent's stored draft. Only while the editor is empty (typing replaces it) and not cleared
    /// with Esc; never for per-job answers, choices or yes/no.
    func ghost(for cluster: QuestionCluster) -> GhostDraft? {
        let d = draft(for: cluster)
        guard !d.perJob, d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let ai = aiDraft(for: cluster)
        guard !ai.ghostDismissed else { return nil }
        if ai.resultIsGhost, let r = ai.result, !r.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return GhostDraft(text: r.answer, source: .drafted(sources: r.sources), grounded: r.grounded,
                              unsupportedClaims: r.grounded ? [] : r.unsupportedClaims)
        }
        guard let stored = AnswerDraft.prefill(for: cluster) else { return nil }
        return GhostDraft(text: stored, source: .stored(confidence: cluster.suggestedConfidence), grounded: true, unsupportedClaims: [])
    }

    /// Tab: take the ghost into the editor. A ghost that isn't grounded needs a second Tab (or
    /// `force`: ⌥Tab / "Use anyway"); the first one only shows what it couldn't back.
    @discardableResult
    func acceptGhost(for cluster: QuestionCluster, force: Bool = false) -> GhostAcceptance {
        guard let ghost = ghost(for: cluster) else { return .nothing }
        if !ghost.grounded && !force && !aiDraft(for: cluster).confirmingUngrounded {
            updateAIDraft(for: cluster) { $0.confirmingUngrounded = true }
            return .needsConfirmation
        }
        updateAIDraft(for: cluster) { s in
            s.confirmingUngrounded = false
            // The taken draft keeps its result, so its unsupported claims keep warning in the text.
            if case .drafted = ghost.source { s.resultIsGhost = false }
        }
        updateDraft(for: cluster) { $0.text = ghost.text }
        return .accepted
    }

    /// Esc: clear the ghost. A new draft (or "Restore draft") brings it back.
    func dismissGhost(for cluster: QuestionCluster) {
        guard ghost(for: cluster) != nil else { return }
        updateAIDraft(for: cluster) { s in
            s.ghostDismissed = true
            s.confirmingUngrounded = false
        }
    }

    /// Show a cleared ghost again.
    func restoreGhost(for cluster: QuestionCluster) {
        updateAIDraft(for: cluster) { $0.ghostDismissed = false }
    }

    // MARK: Draft with AI

    /// Typed answers only. Never-guess / always-ask facts, choice and yes/no questions and agent
    /// tasks don't offer it (the agent refuses those anyway).
    func supportsAIDraft(_ cluster: QuestionCluster) -> Bool {
        guard !cluster.isAction, cluster.neverGuessKey == nil, cluster.reason != .neverGuess, cluster.reason != .alwaysAsk else { return false }
        switch kind(for: cluster) {
        case .shortText, .longText: return true
        default: return false
        }
    }

    func aiDraft(for cluster: QuestionCluster) -> AIDraftState { aiDrafts[cluster.clusterId] ?? AIDraftState() }

    func updateAIDraft(for cluster: QuestionCluster, _ body: (inout AIDraftState) -> Void) {
        var s = aiDraft(for: cluster)
        body(&s)
        aiDrafts[cluster.clusterId] = s
    }

    /// "Draft with AI": a fresh draft from the profile, resume, stories and the job. Over an empty
    /// editor it shows as ghost text (Tab takes it); over the user's text it replaces it (the old
    /// text is kept for Undo). Never answers.
    func draftWithAI(for cluster: QuestionCluster) async {
        await requestAIDraft(for: cluster, instructions: nil)
    }

    /// Return in "Tell the agent what to change…": revise the editor's text as asked (a first
    /// draft, guided by the instruction, when the editor is empty).
    func reviseWithAI(for cluster: QuestionCluster) async {
        let instruction = aiDraft(for: cluster).instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        await requestAIDraft(for: cluster, instructions: instruction)
    }

    /// Put the editor back to the text before the agent's last change (or the ghost back to the
    /// draft before the last rewrite).
    @discardableResult
    func undoAIDraft(for cluster: QuestionCluster) -> Bool {
        var s = aiDraft(for: cluster)
        if s.resultIsGhost, let earlier = s.ghostVersions.popLast() {
            s.result = earlier
            s.confirmingUngrounded = false
            s.ghostDismissed = false
            if case .failed = s.phase { s.phase = .idle }
            aiDrafts[cluster.clusterId] = s
            return true
        }
        guard let previous = s.versions.popLast() else { return false }
        s.result = nil
        if case .failed = s.phase { s.phase = .idle }
        aiDrafts[cluster.clusterId] = s
        updateDraft(for: cluster) { $0.text = previous }
        return true
    }

    private func requestAIDraft(for cluster: QuestionCluster, instructions: String?) async {
        let id = cluster.clusterId
        guard supportsAIDraft(cluster), !aiDraft(for: cluster).isDrafting,
              store.inbox.clusters.contains(where: { $0.clusterId == id }) else { return }
        let typed = draft(for: cluster).text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A rewrite of a ghost rewrites the ghost: it's what the user is looking at.
        let current = typed.isEmpty ? (ghost(for: cluster)?.text ?? "") : typed
        let revising = instructions != nil && !current.isEmpty
        updateAIDraft(for: cluster) { $0.phase = .drafting(revising: revising) }
        let result = await store.draftAnswer(clusterID: id, instructions: instructions, currentAnswer: revising ? current : nil)
        // Answered, skipped or resolved elsewhere while the agent was writing: drop the reply.
        guard store.inbox.clusters.contains(where: { $0.clusterId == id }) else {
            aiDrafts.removeValue(forKey: id)
            return
        }
        switch result {
        case .success(let reply):
            let before = draft(for: cluster).text
            // Over an empty editor the draft is a ghost (Tab takes it); over the user's text it
            // replaces it, with their text kept for Undo.
            let asGhost = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            updateAIDraft(for: cluster) { s in
                s.phase = .idle
                if asGhost, s.resultIsGhost, let earlier = s.result, earlier.answer != reply.answer {
                    s.ghostVersions.append(earlier)
                    if s.ghostVersions.count > AIDraftState.versionLimit { s.ghostVersions.removeFirst() }
                }
                s.result = reply
                s.resultIsGhost = asGhost
                s.ghostDismissed = false
                s.confirmingUngrounded = false
                if !asGhost, before != reply.answer {
                    s.versions.append(before)
                    if s.versions.count > AIDraftState.versionLimit { s.versions.removeFirst() }
                }
                if let instructions {
                    s.history.removeAll { $0 == instructions }
                    s.history.append(instructions)
                    if s.history.count > AIDraftState.historyLimit { s.history.removeFirst() }
                    s.instruction = ""
                }
            }
            if !asGhost { updateDraft(for: cluster) { $0.text = reply.answer } }
        case .failure(let error):
            updateAIDraft(for: cluster) { $0.phase = .failed(Self.aiDraftErrorMessage(error)) }
        }
    }

    static func aiDraftErrorMessage(_ error: DaemonClientError) -> String {
        switch error {
        case .daemon(let p): p.message
        case .timeout: "I took too long to write a draft. Try again."
        case .notConnected: "Can't reach the agent. Drafts need it running."
        case .encoding, .decoding: "The agent's draft couldn't be read. Try again."
        }
    }

    // MARK: Selection

    /// Keep a valid selection: the first (highest impact) cluster when nothing valid is selected.
    func ensureSelection() {
        if let key = selectedReplyKey, replyItems.contains(where: { $0.key == key }) { return }
        selectedReplyKey = nil
        if selectedCluster == nil {
            if let first = clusters.first {
                select(first.clusterId)
            } else {
                selectedClusterID = nil
                selectedReplyKey = replyItems.first?.key
            }
        }
    }

    func select(_ clusterID: String?) {
        selectedReplyKey = nil
        selectedClusterID = clusterID
        validationMessage = nil
        if let clusterID { seenClusterIDs.insert(clusterID) }
    }

    func moveSelection(by delta: Int) {
        let list = clusters
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.clusterId == selectedClusterID } ?? (delta > 0 ? -1 : list.count)
        let next = max(0, min(list.count - 1, current + delta))
        select(list[next].clusterId)
    }

    // MARK: The cascade

    /// The jobs a cluster's monogram row shows, highest impact first (list order), and how many
    /// more there are. The cascade flies exactly these.
    func waitingFlyers(for cluster: QuestionCluster) -> (flyers: [AnswerCascade.Flyer], overflow: Int) {
        var flyers: [AnswerCascade.Flyer] = []
        if cluster.jobIds.isEmpty {
            flyers = cluster.companies.prefix(AnswerCascade.maxFlyers).enumerated().map { AnswerCascade.Flyer(id: -1 - $0.offset, company: $0.element) }
        } else {
            for (i, id) in cluster.jobIds.prefix(AnswerCascade.maxFlyers).enumerated() {
                let company = store.jobs.job(id: id)?.company ?? (i < cluster.companies.count ? cluster.companies[i] : "")
                flyers.append(AnswerCascade.Flyer(id: id, company: company.isEmpty ? "?" : company))
            }
        }
        return (flyers, max(0, cluster.jobCount - flyers.count))
    }

    /// One landing on the Pipeline row: `jobs` more are back in the queue. The last one pulses
    /// the badge and plays the one haptic (never one per monogram).
    func landCascade(id: Int, jobs: Int) {
        guard var c = cascade, c.id == id, !c.isLanded else { return }
        c.landedJobs = min(c.jobCount, c.landedJobs + max(0, jobs))
        cascade = c
        if c.isLanded {
            cascadePulse += 1
            if c.hapticOnLanding { Haptics.levelChange() }
        }
    }

    private func startCascade(cluster: QuestionCluster, inboxZero: Bool) {
        guard cluster.jobCount >= AnswerCascade.minimumJobs else {
            cascade = nil
            return
        }
        cascadeSequence += 1
        let (flyers, _) = waitingFlyers(for: cluster)
        let c = AnswerCascade(id: cascadeSequence, clusterID: cluster.clusterId, jobCount: cluster.jobCount, flyers: flyers,
                              hapticOnLanding: !inboxZero)
        cascade = c
        cascadeLauncher(c, self)
    }

    // MARK: Answer once

    /// Validate and answer the selected cluster. Returns false (and shakes) on invalid input.
    @discardableResult
    func submitSelected(undoManager: UndoManager? = nil) -> Bool {
        guard let cluster = selectedCluster else { return false }
        if cluster.isAction {
            completeSelectedAction(undoManager: undoManager)
            return true
        }
        let draft = draft(for: cluster)
        switch AnswerComposerLogic.resolve(draft, kind: kind(for: cluster), jobIDs: cluster.jobIds) {
        case .failure(let error):
            // An empty editor under a ghost: the ghost isn't an answer until it's taken.
            validationMessage = error == .empty && ghost(for: cluster) != nil
                ? "Press Tab to use the draft, or type your answer." : error.message
            shakeTrigger += 1
            return false
        case .success(let resolved):
            enqueue(cluster: cluster, answer: resolved, skipReason: nil, undoManager: undoManager)
            return true
        }
    }

    /// "Done, retry N jobs" on an agent blocker: resolves it (nothing saved to memory) and the
    /// daemon re-queues its jobs. Same Undo window as answers.
    func completeSelectedAction(undoManager: UndoManager? = nil) {
        guard let cluster = selectedCluster, cluster.isAction else { return }
        enqueue(cluster: cluster, answer: ResolvedAnswer(answer: "done", saveToMemory: false, saveToProfile: false, perJobAnswers: []),
                skipReason: nil, undoManager: undoManager)
    }

    /// Open the agent's Chrome on the blocked job's application page.
    func openAgentChrome(for cluster: QuestionCluster) async {
        let url = cluster.jobIds.lazy.compactMap { self.store.jobs.job(id: $0)?.applyURL }.first
        await store.openAgentChrome(url: url)
    }

    /// "Skip these jobs": parks every job in the cluster as skipped (same Undo window).
    func skipSelected(reason: String? = "user_skipped_question", undoManager: UndoManager? = nil) {
        guard let cluster = selectedCluster else { return }
        enqueue(cluster: cluster, answer: nil, skipReason: reason, undoManager: undoManager)
    }

    private func enqueue(cluster: QuestionCluster, answer: ResolvedAnswer?, skipReason: String?, undoManager: UndoManager?) {
        let id = cluster.clusterId
        let wasLast = clusters.count == 1
        // Leave the list now (the cluster compresses into "Answered today"), send after the window.
        store.inbox.removeOptimistically(clusterID: id)
        let window = undoWindow
        let task = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit(clusterID: id)
        }
        pending[id] = Pending(cluster: cluster, answer: answer, skipReason: skipReason, task: task, enqueuedAt: Date(),
                              priorResolvedAt: store.inbox.resolvedToday.first { $0.clusterID == id }?.at)
        answered.removeAll { $0.clusterID == id }
        answered.insert(InboxAnsweredRecord(clusterID: id, question: title(for: cluster), jobCount: cluster.jobCount,
                                            status: answer == nil ? .skipped : .answered, at: Date(), isPending: true), at: 0)
        drafts.removeValue(forKey: id)
        aiDrafts.removeValue(forKey: id)
        validationMessage = nil
        let inboxZero = wasLast || clusters.isEmpty
        // The waiting jobs fly to Pipeline (read from the composer before it's replaced below).
        if answer != nil {
            startCascade(cluster: cluster, inboxZero: inboxZero)
        } else {
            cascade = nil
        }
        // Auto-advance to the next highest-impact cluster.
        select(clusters.first?.clusterId)
        if inboxZero {
            inboxZeroTrigger += 1
            Haptics.levelChange()
            Sounds.play(.celebrate)
        } else {
            Sounds.play(.pop)
        }
        let jobsText = C3Format.plural(cluster.jobCount, "job")
        let message = answer == nil ? "Skipped · \(jobsText)" : "\(cluster.isAction ? "Done" : "Answered") · \(jobsText) back in the queue"
        // The ring on the toast drains over the same window the answer is held for.
        store.toasts.show(message, symbol: answer == nil ? "arrow.uturn.right" : "checkmark", style: .success,
                          duration: window, actionTitle: "Undo", countdown: true) { [weak self] in self?.undo(clusterID: id) }
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.undo(clusterID: id) }
            }
            undoManager.setActionName(answer == nil ? (cluster.isAction ? "Skip Jobs" : "Skip Question") : (cluster.isAction ? "Retry" : "Answer"))
        }
    }

    /// Cancel a pending answer inside its window and put the cluster back, selected.
    @discardableResult
    func undo(clusterID: String? = nil) -> Bool {
        guard let id = clusterID ?? answered.first(where: \.isPending)?.clusterID, let p = pending.removeValue(forKey: id) else { return false }
        p.task.cancel()
        answered.removeAll { $0.clusterID == id }
        if cascade?.clusterID == id { cascade = nil }
        if resolvedElsewhere(p) {
            // The daemon already resolved it (CLI / another window): nothing to put back.
            store.toasts.show("Already resolved elsewhere", symbol: "info.circle", style: .info)
            return false
        }
        store.inbox.restore(p.cluster)
        restoreDraft(from: p)
        select(id)
        return true
    }

    /// Put a held answer back in the composer (text, yes/no, choices, per-job, save toggles) so
    /// nothing typed is lost.
    private func restoreDraft(from p: Pending) {
        guard let a = p.answer, !p.cluster.isAction else { return }
        var d = AnswerDraft(cluster: p.cluster)
        d.text = a.perJobAnswers.isEmpty ? a.answer : ""
        d.saveToMemory = a.saveToMemory
        d.saveToProfile = a.saveToProfile
        if !a.perJobAnswers.isEmpty {
            d.perJob = true
            d.perJobAnswers = Dictionary(a.perJobAnswers.map { ($0.jobId, $0.answer) }, uniquingKeysWith: { a, _ in a })
        }
        if AnswerKind(cluster: p.cluster) == .yesNo { d.yesNo = a.answer == "Yes" }
        if case .choice(let multi) = AnswerKind(cluster: p.cluster), a.perJobAnswers.isEmpty {
            if let hits = ChoiceLogic.match(a.answer, options: p.cluster.options, multi: multi) {
                d.choices = hits
            } else {
                d.useOther = true
            }
        }
        drafts[p.cluster.clusterId] = d
    }

    /// Whether the daemon resolved this cluster (a `question_resolved` from elsewhere) while the
    /// answer was held in its Undo window.
    private func resolvedElsewhere(_ p: Pending) -> Bool {
        guard let entry = store.inbox.resolvedToday.first(where: { $0.clusterID == p.cluster.clusterId }) else { return false }
        if let prior = p.priorResolvedAt { return entry.at != prior }
        return true
    }

    /// Send everything still pending now (leaving the app, tests).
    func flushPending() async {
        for id in Array(pending.keys) {
            pending[id]?.task.cancel()
            await commit(clusterID: id)
        }
    }

    private func commit(clusterID id: String) async {
        guard let p = pending.removeValue(forKey: id) else { return }
        // The Undo window closed: the Pipeline badge has said its piece.
        if cascade?.clusterID == id { cascade = nil }
        if resolvedElsewhere(p) {
            // Resolved by the daemon / CLI / another window during the window: sending now would
            // only error. Drop ours and let the remote "Answered today" row stand.
            answered.removeAll { $0.clusterID == id }
            store.toasts.show("Already resolved elsewhere · your answer wasn't sent", symbol: "info.circle", style: .info)
            return
        }
        let ok: Bool
        if let a = p.answer {
            ok = await store.answerQuestion(clusterID: id, answer: a.answer, saveToMemory: a.saveToMemory,
                                            saveToProfile: a.saveToProfile, perJobAnswers: a.perJobAnswers)
        } else {
            ok = await store.skipQuestion(clusterID: id, reason: p.skipReason)
        }
        if ok {
            if let i = answered.firstIndex(where: { $0.clusterID == id }) { answered[i].isPending = false }
        } else {
            answered.removeAll { $0.clusterID == id }
            // Resolved elsewhere while the send was in flight: don't resurrect a phantom cluster.
            guard !resolvedElsewhere(p) else { return }
            // The store already toasted the failure; bring the cluster back so nothing is lost.
            store.inbox.restore(p.cluster)
            restoreDraft(from: p)
        }
    }

    /// App is quitting inside an Undo window: send the held commands (no reply wait), blocking
    /// termination for at most ~1 s so they reach the socket.
    private func flushSynchronouslyOnQuit() {
        guard !pending.isEmpty else { return }
        let client = store.client
        for p in pending.values { p.task.cancel() }
        let commands: [Command] = pending.filter { !resolvedElsewhere($0.value) }.map { id, p in
            p.answer.map {
                .answerQuestion(AnswerQuestionPayload(clusterId: id, answer: $0.answer, saveToMemory: $0.saveToMemory,
                                                      saveToProfile: $0.saveToProfile, perJobAnswers: $0.perJobAnswers))
            } ?? .skipQuestion(SkipQuestionPayload(clusterId: id, reason: p.skipReason))
        }
        pending.removeAll()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for command in commands { _ = try? await client.send(command) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    /// Clusters answered in this session that the daemon resolved but we never saw locally
    /// (answered from the CLI / another window) — shown in "Answered today" too.
    var answeredTodayRows: [InboxAnsweredRecord] {
        let local = Set(answered.map(\.clusterID))
        let remote = store.inbox.resolvedToday.filter { !local.contains($0.clusterID) }.map {
            InboxAnsweredRecord(clusterID: $0.clusterID, question: $0.question, jobCount: $0.jobCount, status: $0.status, at: $0.at, isPending: false)
        }
        return (answered + remote).sorted { $0.at > $1.at }
    }

    func copyQuestion(_ cluster: QuestionCluster) {
        clipboard.write(title(for: cluster))
        store.toasts.show("Copied · question", symbol: "doc.on.clipboard", style: .success)
    }
}
