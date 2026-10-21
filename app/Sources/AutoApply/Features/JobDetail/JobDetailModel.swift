// JobDetailModel.swift — data + rules for Job Detail (docs/UI_UX_PLAN.md §5.4): match factor
// ordering, the event timeline, "Copy all" text, the status menu's legal actions, and the
// loader that streams the Q&A audit and JD from the read-only repository.
import AppKit
import Foundation
import Observation

enum JobDetailRules {
    struct Factor: Hashable, Sendable {
        var name: String
        var value: Int
    }

    /// Factors in the spec's order (Skills, Seniority, Location, Salary, Domain), unknown ones
    /// after, alphabetically. Names are title-cased for display.
    static func orderedFactors(_ factors: [String: Int]) -> [Factor] {
        let order = ["skills", "seniority", "location", "salary", "domain"]
        return factors.map { Factor(name: $0.key, value: min(100, max(0, $0.value))) }
            .sorted { a, b in
                let ia = order.firstIndex(of: a.name.lowercased()) ?? Int.max
                let ib = order.firstIndex(of: b.name.lowercased()) ?? Int.max
                return ia != ib ? ia < ib : a.name < b.name
            }
            .map { Factor(name: $0.name.replacingOccurrences(of: "_", with: " ").capitalized, value: $0.value) }
    }

    /// Muted banner for skipped jobs: "Skipped · below threshold (64) · salary floor not met".
    static func skippedBanner(_ job: JobItem, threshold: Int) -> String? {
        guard job.state == .skipped else { return nil }
        var parts = ["Skipped"]
        let reason = job.skipReason ?? job.stateReason
        if BoardRules.skipReasonKey(reason) == "below_threshold", let score = job.score {
            parts.append("below threshold (\(score) < \(threshold))")
        } else {
            parts.append(BoardRules.skipReasonLabel(reason).lowercased())
            if let detail = reason?.split(separator: ":").dropFirst().first { parts.append(String(detail)) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Status menu

    enum StatusAction: Hashable, Sendable {
        case setStatus(BoardStatus)
        case retry
        case resolveSubmitted
        case resolveFailed
        case approve
        case reject
        case applyAnyway

        var title: String {
            switch self {
            case .setStatus(let s): s.label
            case .retry: "Try again"
            case .resolveSubmitted: "It was sent"
            case .resolveFailed: "It wasn't sent"
            case .approve: "Approve & submit"
            case .reject: "Skip"
            case .applyAnyway: "Queue for next run"
            }
        }
    }

    /// Legal manual actions for the header status menu — the same rules as the board, plus the
    /// user-only edges the protocol exposes (retry, resolve unknown, approve/reject, apply anyway).
    static func statusActions(for job: JobItem) -> [StatusAction] {
        switch job.state {
        case .submitted: BoardRules.legalTargets(for: job).map { .setStatus($0) }
        case .failed: job.applicationID == nil ? [] : [.retry]
        case .unknownVerify: [.resolveSubmitted, .resolveFailed]
        case .awaitingReview: [.approve, .reject]
        case .skipped: job.applicationID == nil ? [] : [.applyAnyway]
        default: []
        }
    }

    // MARK: Header actions

    /// State-aware buttons in the header (what the user can do about this job right now).
    enum HeaderAction: Hashable, Sendable {
        case approve
        case skip
        case retry
        case applyAnyway
        case resolveSent
        case resolveNotSent

        var title: String {
            switch self {
            case .approve: "Approve & submit"
            case .skip: "Skip"
            case .retry: "Try again"
            case .applyAnyway: "Queue for next run"
            case .resolveSent: "It was sent"
            case .resolveNotSent: "It wasn't sent"
            }
        }

        var symbol: String? {
            switch self {
            case .approve: "paperplane.fill"
            case .retry: "arrow.clockwise"
            case .applyAnyway: "arrow.uturn.forward"
            case .skip, .resolveSent, .resolveNotSent: nil
            }
        }

        /// At most one accent-filled button per state; "was it sent?" has no default answer.
        var isPrimary: Bool {
            switch self {
            case .approve, .retry, .applyAnyway: true
            case .skip, .resolveSent, .resolveNotSent: false
            }
        }

        var shortcut: AppShortcut? { self == .approve ? .submit : nil }

        /// Sends a daemon command (disabled while disconnected).
        var needsDaemon: Bool { true }

        var help: String {
            switch self {
            case .approve: "Send this application as filled (\(AppShortcut.submit.displayString))"
            case .skip: "Don't send it; pick a reason"
            case .retry: "Queue this application to be filled again on the next run"
            case .applyAnyway: "Undo the skip: the agent applies on its next run"
            case .resolveSent: "The form was sent; mark it as applied"
            case .resolveNotSent: "The form wasn't sent; mark it as failed"
            }
        }
    }

    /// awaiting_review → Approve & submit + Skip; failed → Retry; skipped → Apply anyway;
    /// unknown_verify → It was sent / It wasn't sent. Actions that need an application row are
    /// omitted when there is none. needs_you has none: its questions are answered in the
    /// Questions tab.
    static func headerActions(for job: JobItem) -> [HeaderAction] {
        let hasApp = job.applicationID != nil
        switch job.state {
        case .awaitingReview: return hasApp ? [.approve, .skip] : []
        case .failed: return hasApp ? [.retry] : []
        case .skipped: return hasApp ? [.applyAnyway] : []
        case .unknownVerify: return hasApp ? [.resolveSent, .resolveNotSent] : []
        default: return []
        }
    }

    /// Quiet status text shown where a button would be ("Queued · next run").
    static func headerNote(for job: JobItem) -> String? {
        job.state == .queued ? "Queued · next run" : nil
    }

    /// Open Needs You clusters that block this job, in inbox (impact) order.
    static func openClusters(forJob jobID: Int, in clusters: [QuestionCluster]) -> [QuestionCluster] {
        clusters.filter { $0.jobIds.contains(jobID) }
    }

    /// The status menu only offers board moves; state actions are header buttons.
    static func menuActions(for job: JobItem) -> [StatusAction] {
        statusActions(for: job).filter { if case .setStatus = $0 { true } else { false } }
    }

    // MARK: Copy all

    /// ⌘⇧C: all answers as formatted text.
    static func copyAllText(job: JobItem, answers: [ApplicationAnswerItem]) -> String {
        var lines = ["\(job.company) · \(job.title)", ""]
        for a in answers {
            lines.append("\(a.question)")
            lines.append(a.answer.isEmpty ? "—" : a.answer)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Timeline

    struct TimelineItem: Identifiable, Hashable, Sendable {
        var id: String
        var at: Date
        var title: String
        var detail: String?
        var actor: Actor
        var isError: Bool = false
    }

    /// Discovered (source) → Scored 91 → Queued → Filling (duration) → Submitted → Nudge day 7 →
    /// Moved to Interview (by you). Logged events win; milestones fill gaps when the log is
    /// missing them (e.g. trimmed history).
    static func timeline(job: JobItem, events: [ActivityEvent], now: Date = Date()) -> [TimelineItem] {
        var items: [TimelineItem] = []
        let kinds = Set(events.map { $0.kind.lowercased() })

        for e in events {
            items.append(TimelineItem(id: "e\(e.id)", at: e.ts, title: title(for: e), detail: e.message,
                                      actor: e.actor, isError: e.level == .error || e.kind.lowercased() == "error"))
        }
        if !kinds.contains("discover") {
            items.append(TimelineItem(id: "m-discovered", at: job.discoveredAt, title: "Discovered",
                                      detail: "via \(job.source.label)", actor: .agent))
        }
        if let score = job.score, !kinds.contains("score") {
            items.append(TimelineItem(id: "m-scored", at: job.scoredAt ?? job.discoveredAt, title: "Scored \(score)",
                                      detail: job.scoreSummary, actor: .agent))
        }
        if job.state == .skipped, !kinds.contains("skip") {
            items.append(TimelineItem(id: "m-skipped", at: job.stateUpdatedAt ?? job.discoveredAt, title: "Skipped",
                                      detail: BoardRules.skipReasonLabel(job.skipReason ?? job.stateReason), actor: .agent))
        }
        if let submitted = job.submittedAt, !kinds.contains("submit") {
            items.append(TimelineItem(id: "m-submitted", at: submitted, title: "Applied",
                                      detail: job.mode == .manual ? "manually (Easy Apply)" : nil,
                                      actor: job.mode == .manual ? .user : .agent))
        }
        if let submitted = job.submittedAt {
            for (i, day) in [7, 14].enumerated() where job.nudgesSent > i {
                let at = submitted.addingTimeInterval(Double(day) * 86_400)
                if at <= now {
                    items.append(TimelineItem(id: "m-nudge\(day)", at: at, title: "Nudge · day \(day)", detail: "“Heard back?”", actor: .system))
                }
            }
        }
        if let status = job.status, status != .applied, let at = job.statusUpdatedAt, !kinds.contains("status") {
            items.append(TimelineItem(id: "m-status", at: at, title: "Moved to \(status.label)",
                                      detail: status == .ghosted ? "\(Int((at.timeIntervalSince(job.submittedAt ?? at)) / 86_400)) days without reply" : "by you",
                                      actor: status == .ghosted ? .system : .user))
        }
        return items.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    static func title(for event: ActivityEvent) -> String {
        switch event.kind.lowercased() {
        case "discover": "Discovered"
        case "score": "Scored"
        case "skip": "Skipped"
        case "queue", "queued": "Queued"
        case "fill": "Filling"
        case "resume": "Resume picked"
        case "cover_letter": "Cover letter"
        case "ask": "Asked you"
        case "answer": "Answered"
        case "review": "Ready for review"
        case "approve": "Approved"
        case "submit": "Applied"
        case "status": event.actor == .user ? "Status changed (by you)" : "Status changed"
        case "nudge": "Nudge"
        case "error": "Error"
        default: event.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Screenshots

    struct Shot: Identifiable, Hashable, Sendable {
        var id: String { path }
        var label: String
        var path: String
    }

    /// Pre-submit page first, then the post-submit confirmation (filmstrip order).
    static func screenshots(for job: JobItem) -> [Shot] {
        var out: [Shot] = []
        if let p = job.screenshotPath, !p.isEmpty { out.append(Shot(label: "Before sending", path: p)) }
        if let p = job.confirmationScreenshotPath, !p.isEmpty { out.append(Shot(label: "Confirmation", path: p)) }
        return out
    }
}

/// Streams the Q&A audit and loads the JD for one job (repository is read-only).
@MainActor
@Observable
final class JobDetailLoader {
    private(set) var answers: [ApplicationAnswerItem] = []
    private(set) var answersLoaded = false
    private(set) var jobDescription: String?
    private(set) var descriptionLoaded = false

    init() {}

    func loadDescription(jobID: Int, fallback: String?, repository: any AppRepository) async {
        descriptionLoaded = false
        let text = await repository.jobDescription(jobID: jobID)
        jobDescription = text ?? fallback
        descriptionLoaded = true
    }

    /// Runs until cancelled (bind to `.task(id:)`).
    func streamAnswers(applicationID: Int?, repository: any AppRepository) async {
        answers = []
        answersLoaded = false
        guard let applicationID else {
            answersLoaded = true
            return
        }
        for await rows in repository.applicationAnswers(applicationID: applicationID) {
            answers = rows
            answersLoaded = true
        }
    }

    /// Inline ✎ edit (awaiting review). Optimistic, like the Review queue: the edit shows with
    /// "you" provenance at once; the DB stream reconciles, and a failure rolls back.
    func editAnswer(_ answer: ApplicationAnswerItem, to text: String, store: AppStore) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != answer.answer else { return }
        let before = answers
        if let i = answers.firstIndex(where: { $0.id == answer.id }) {
            answers[i].answer = trimmed
            answers[i].origin = .user
            answers[i].confidence = 1
        }
        let result = await store.perform(.editApplicationAnswer(EditApplicationAnswerPayload(applicationAnswerId: answer.id, answer: trimmed)))
        if case .failure = result { answers = before }
    }

    func copyAll(job: JobItem) {
        let text = JobDetailRules.copyAllText(job: job, answers: answers)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Runs the header's state actions for one job and owns their inline prompts (the Review
/// queue's low-confidence safeguard and skip-reason picker). The user stays on the page: the
/// state chip updates and a toast confirms.
@MainActor
@Observable
final class JobDetailActions {
    enum Prompt: Equatable, Sendable {
        case none
        /// "This one has 2 answers that need a look. Approve anyway?" (`loading`: Q&A not in yet).
        case confirmFlagged(flagged: Int, loading: Bool)
        case skipReason
    }

    var prompt: Prompt = .none
    /// An action is waiting on the daemon (buttons disable; a second ⌘↵ is ignored).
    private(set) var inFlight = false
    /// Inline editors open on the page (answer ✎, notes). ⌘↵ approve is held while typing.
    private(set) var openEditors = 0

    var isEditing: Bool { openEditors > 0 }

    init() {}

    func editingChanged(_ editing: Bool) {
        openEditors = max(0, openEditors + (editing ? 1 : -1))
    }

    /// The job left the state the prompt was about (approved elsewhere, re-filled, …).
    func reset() { prompt = .none }

    func cancelPrompt() { prompt = .none }

    // MARK: Approve (with the safeguard)

    /// Button / ⌘↵ / palette. Asks inline when an answer needs a look or the Q&A hasn't loaded.
    func requestApprove(job: JobItem, answers: [ApplicationAnswerItem], answersLoaded: Bool, store: AppStore) async {
        guard !inFlight, !isEditing, job.state == .awaitingReview, job.applicationID != nil else { return }
        if ReviewSafeguard.needsLook(answers: answers, loaded: answersLoaded) {
            prompt = .confirmFlagged(flagged: ReviewSafeguard.flaggedAnswers(answers).count, loading: !answersLoaded)
        } else {
            await approve(job: job, store: store)
        }
    }

    /// "Approve anyway" in the safeguard prompt.
    func confirmApprove(job: JobItem, store: AppStore) async {
        guard case .confirmFlagged = prompt else { return }
        prompt = .none
        await approve(job: job, store: store)
    }

    private func approve(job: JobItem, store: AppStore) async {
        // Re-read: another window (or the Review queue) may have approved it meanwhile.
        guard !inFlight, let current = store.jobs.job(id: job.id), current.state == .awaitingReview,
              let appID = current.applicationID else { return }
        inFlight = true
        defer { inFlight = false }
        if await store.approve(applicationIDs: [appID]) {
            store.toasts.show("Approved · sending now", symbol: "paperplane.fill", style: .success)
        }
    }

    // MARK: Skip

    func requestSkip(job: JobItem) {
        guard !inFlight, job.state == .awaitingReview, job.applicationID != nil else { return }
        prompt = .skipReason
    }

    func skip(job: JobItem, reason: ReviewSkipReason, store: AppStore) async {
        guard case .skipReason = prompt, let appID = job.applicationID else { return }
        prompt = .none
        inFlight = true
        defer { inFlight = false }
        if await store.reject(applicationID: appID, reason: reason.rawValue) {
            store.toasts.show("Skipped · \(reason.title)", symbol: "arrow.uturn.right", style: .info)
        }
    }

    // MARK: Other states

    func retry(job: JobItem, store: AppStore) async {
        guard !inFlight, let appID = job.applicationID else { return }
        inFlight = true
        defer { inFlight = false }
        if await store.retryApplication(applicationID: appID) {
            store.toasts.show("Queued for the next run", symbol: "arrow.clockwise", style: .success)
        }
    }

    func applyAnyway(job: JobItem, store: AppStore) async {
        guard !inFlight, let appID = job.applicationID else { return }
        inFlight = true
        defer { inFlight = false }
        await store.applyAnyway(applicationID: appID) // shows its own toast
    }

    func resolve(job: JobItem, sent: Bool, store: AppStore) async {
        guard !inFlight, let appID = job.applicationID else { return }
        inFlight = true
        defer { inFlight = false }
        if await store.resolveUnknown(applicationID: appID, submitted: sent) {
            store.toasts.show(sent ? "Marked as sent" : "Marked as not sent", symbol: "checkmark", style: .success)
        }
    }
}
