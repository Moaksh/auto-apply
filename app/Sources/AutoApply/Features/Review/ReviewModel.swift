// ReviewModel.swift — Review queue logic (docs/UI_UX_PLAN.md §5.6): flagged (medium/low
// confidence) items sorted to the top, multi-selection, the floating bar's states (actions →
// "include the flagged one?" safeguard → skip reason picker), approve through the send hold
// (`SendHoldModel`: nothing is sent until its ≈5 s Undo window closes), reject with a reason,
// jump to the next flagged answer (F), and inline answer edits.
import Foundation
import Observation

/// Why the user skipped a reviewed application (feeds the skip log via `reject.reason`).
enum ReviewSkipReason: String, CaseIterable, Identifiable, Sendable {
    case notInterested = "not_interested"
    case wrongAnswers = "wrong_answers"
    case company = "company"
    case other = "other"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notInterested: "Not interested"
        case .wrongAnswers: "Wrong answers"
        case .company: "Company"
        case .other: "Other"
        }
    }
}

@MainActor
@Observable
final class ReviewModel {
    enum BarMode: Equatable, Sendable {
        case actions
        /// Selection mixes flagged + clean items: "Include the flagged one? Yes / Only the N clean".
        case confirmFlagged(targets: [Int])
        /// Every target is flagged: "Approve anyway?".
        case confirmAllFlagged(targets: [Int])
        case skipReason(targets: [Int])
    }

    let store: AppStore

    /// Focused row (job id) — drives the detail pane.
    var focusedJobID: Int?
    /// Multi-selection (job ids).
    var selection: Set<Int> = []
    var barMode: BarMode = .actions
    /// Q&A per application id (streamed from the DB).
    private(set) var answers: [Int: [ApplicationAnswerItem]] = [:]
    /// Application ids whose Q&A stream has emitted at least once. Until then an application's
    /// confidence is *unknown* and it is never treated as clean by the approve safeguard.
    private(set) var loadedApplicationIDs: Set<Int> = []
    /// Bumped by F / "N need a look": the Q&A panel spotlights the next flagged answer.
    private(set) var flaggedJumpSerial = 0

    @ObservationIgnored private var answerTasks: [Int: Task<Void, Never>] = [:]

    static func shared(for store: AppStore) -> ReviewModel {
        FeatureModels.model(ReviewModel.self, for: store) { ReviewModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

    /// Approvals wait here (≈5 s, Undo / ⌘Z) before the `approve` command goes out. Shared with
    /// Job detail, so a job held from either place shows its countdown in both.
    var sendHold: SendHoldModel { SendHoldModel.shared(for: store) }

    /// On hold (or sending): a second press is ignored instead of sending twice.
    func isHeld(_ jobID: Int) -> Bool { sendHold.isHeld(jobID) }

    // MARK: Queue

    /// Awaiting-review jobs: flagged first (low before medium), then by match score, then oldest.
    var queue: [JobItem] {
        store.jobs.awaitingReview.sorted { a, b in
            let fa = flagRank(a), fb = flagRank(b)
            if fa != fb { return fa > fb }
            if (a.score ?? 0) != (b.score ?? 0) { return (a.score ?? 0) > (b.score ?? 0) }
            return (a.stateUpdatedAt ?? a.discoveredAt) < (b.stateUpdatedAt ?? b.discoveredAt)
        }
    }

    var focusedJob: JobItem? {
        guard let id = focusedJobID else { return nil }
        return store.jobs.job(id: id).flatMap { $0.state == .awaitingReview ? $0 : nil }
    }

    func answers(for job: JobItem) -> [ApplicationAnswerItem] {
        job.applicationID.flatMap { answers[$0] } ?? []
    }

    /// Answers needing a look (medium or low confidence).
    func flaggedAnswers(for job: JobItem) -> [ApplicationAnswerItem] {
        ReviewSafeguard.flaggedAnswers(answers(for: job))
    }

    func isFlagged(_ job: JobItem) -> Bool { flagRank(job) > 0 }

    /// Whether this job's Q&A has loaded (jobs without an application have nothing to load).
    func answersLoaded(_ job: JobItem) -> Bool {
        guard let appID = job.applicationID else { return true }
        return loadedApplicationIDs.contains(appID)
    }

    /// Needs the inline confirmation before approval: flagged, or answers not loaded yet
    /// (fail closed — unknown confidence is never "clean").
    func needsLook(_ job: JobItem) -> Bool { isFlagged(job) || !answersLoaded(job) }

    private func needsLook(jobID: Int) -> Bool {
        store.jobs.job(id: jobID).map(needsLook) ?? false
    }

    /// Any of these targets still waiting for its Q&A (drives the "still loading" copy).
    func anyLoading(_ jobIDs: [Int]) -> Bool {
        jobIDs.contains { id in store.jobs.job(id: id).map { !answersLoaded($0) } ?? false }
    }

    /// 2 = has a low-confidence answer, 1 = medium, 0 = clean.
    private func flagRank(_ job: JobItem) -> Int {
        ReviewSafeguard.flagRank(answers(for: job))
    }

    /// "Mode: Review (Greenhouse override: Auto)".
    var modeSummary: String {
        let prefs = store.preferences
        let overrides = prefs.perAtsMode
            .filter { $0.value != prefs.mode }
            .sorted { $0.key < $1.key }
            .map { "\(Ats(rawValue: $0.key)?.label ?? $0.key.capitalized): \($0.value.rawValue.capitalized)" }
        let base = "Mode: \(prefs.mode.rawValue.capitalized)"
        return overrides.isEmpty ? base : "\(base) (\(overrides.joined(separator: ", ")))"
    }

    // MARK: Q&A subscriptions

    /// Subscribe to the Q&A of every queued application; drop subscriptions that left.
    func syncSubscriptions() {
        let ids = Set(store.jobs.awaitingReview.compactMap(\.applicationID))
        for (id, task) in answerTasks where !ids.contains(id) {
            task.cancel()
            answerTasks.removeValue(forKey: id)
            answers.removeValue(forKey: id)
            loadedApplicationIDs.remove(id)
        }
        let repo = store.repository
        for id in ids where answerTasks[id] == nil {
            let stream = repo.applicationAnswers(applicationID: id)
            answerTasks[id] = Task { [weak self] in
                for await list in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.answers[id] = list
                    self.loadedApplicationIDs.insert(id)
                }
            }
        }
        pruneSelection()
    }

    func pruneSelection() {
        let live = Set(store.jobs.awaitingReview.map(\.id))
        selection.formIntersection(live)
        if let f = focusedJobID, !live.contains(f) { focusedJobID = nil }
        if focusedJobID == nil { focusedJobID = (queue.first { !isHeld($0.id) } ?? queue.first)?.id }
    }

    // MARK: Selection & focus

    func toggleSelection(_ jobID: Int) {
        if selection.contains(jobID) { selection.remove(jobID) } else { selection.insert(jobID) }
        barMode = .actions
    }

    func toggleFocusedSelection() {
        if let id = focusedJobID { toggleSelection(id) }
    }

    func selectAll() {
        selection = Set(queue.map(\.id).filter { !isHeld($0) })
        barMode = .actions
    }

    func clearSelection() {
        selection.removeAll()
        barMode = .actions
    }

    func moveFocus(by delta: Int) {
        let list = queue
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == focusedJobID } ?? (delta > 0 ? -1 : list.count)
        focusedJobID = list[max(0, min(list.count - 1, current + delta))].id
    }

    /// F / the "N need a look" count: spotlight the focused job's next flagged answer.
    func jumpToNextFlagged() {
        guard let job = focusedJob, !flaggedAnswers(for: job).isEmpty else { return }
        flaggedJumpSerial += 1
    }

    /// After an Undo, focus the first job put back so it can be fixed or approved again.
    func didUndo(_ jobIDs: [Int]) {
        if let first = jobIDs.first(where: { id in queue.contains { $0.id == id } }) { focusedJobID = first }
    }

    /// Targets for an action: the selection when non-empty, else the focused row. Rows on hold
    /// (or sending) are excluded.
    var targets: [Int] {
        let order = queue.map(\.id).filter { !isHeld($0) }
        if !selection.isEmpty { return order.filter(selection.contains) }
        guard let f = focusedJobID, !isHeld(f) else { return [] }
        return [f]
    }

    /// "Approve & send" / "Approve 2 (1 needs a look)".
    var approveTitle: String {
        let t = targets
        let flagged = t.filter(needsLook(jobID:)).count
        if t.count <= 1 { return flagged > 0 ? "Approve (needs a look)" : "Approve & send" }
        return flagged > 0 ? "Approve \(t.count) (\(flagged) need\(flagged == 1 ? "s" : "") a look)" : "Approve \(t.count) & send"
    }

    // MARK: Approve (with the low-confidence safeguard and the send hold)

    /// A / the bar's Approve button (the selection, else the focused row), or the detail pane's
    /// button (`only` that job, whatever else is selected). Asks inline (no modal) when flagged
    /// items are included.
    func requestApprove(only: [Int]? = nil, undoManager: UndoManager? = nil) {
        let t = only.map { ids in ids.filter { !isHeld($0) } } ?? targets
        guard !t.isEmpty else { return }
        let flagged = t.filter(needsLook(jobID:))
        if flagged.isEmpty {
            approve(t, undoManager: undoManager)
        } else if flagged.count == t.count {
            barMode = .confirmAllFlagged(targets: t)
        } else {
            barMode = .confirmFlagged(targets: t)
        }
    }

    /// Answer the safeguard question.
    func confirmApprove(includeFlagged: Bool, undoManager: UndoManager? = nil) {
        let t: [Int]
        switch barMode {
        case .confirmFlagged(let targets), .confirmAllFlagged(let targets): t = targets
        default: return
        }
        let chosen = includeFlagged ? t : t.filter { !needsLook(jobID: $0) }
        barMode = .actions
        approve(chosen, undoManager: undoManager)
    }

    func cancelBar() { barMode = .actions }

    /// Put the jobs on the send hold: each row shows "Sending in 5…" with Undo (⌘Z) and focus
    /// moves on. The `approve` command goes out only when the window closes (`SendHoldModel`).
    func approve(_ requested: [Int], undoManager: UndoManager? = nil) {
        // In-flight guard: a double press must not hold (and later send) the same rows twice.
        var jobIDs = requested.filter { !isHeld($0) }
        // The daemon allows one application per company per cooldown window and refuses the whole
        // batch otherwise. Send the first job per company (counting jobs already on hold); the
        // rest stay here for later.
        var held: [String] = []
        if store.preferences.perCompanyCooldownDays > 0 {
            var seen = Set(sendHold.heldJobIDs.compactMap { store.jobs.job(id: $0)?.companyID })
            jobIDs = jobIDs.filter { id in
                guard let job = store.jobs.job(id: id) else { return true }
                if seen.insert(job.companyID).inserted { return true }
                held.append(job.company)
                return false
            }
        }
        if !held.isEmpty {
            let names = Array(Set(held)).sorted().joined(separator: ", ")
            store.toasts.show("Kept \(held.count) in Review: one application per company every \(store.preferences.perCompanyCooldownDays) days (\(names))",
                              symbol: "hand.raised", style: .info)
        }
        let nextFocus = queue.first { !jobIDs.contains($0.id) && !isHeld($0.id) }?.id
        let holding = sendHold.hold(jobIDs: jobIDs, undoManager: undoManager)
        guard !holding.isEmpty else { return }
        selection.subtract(holding)
        if let f = focusedJobID, holding.contains(f), let nextFocus { focusedJobID = nextFocus }
    }

    /// A row's Undo: the job stays in Review, focused, and nothing is sent.
    func undoHold(jobID: Int) {
        if sendHold.undo(jobID: jobID) { focusedJobID = jobID }
    }

    // MARK: Skip

    /// S / Skip: open the reason picker in the bar.
    func requestSkip(only: [Int]? = nil) {
        let t = only.map { ids in ids.filter { !isHeld($0) } } ?? targets
        guard !t.isEmpty else { return }
        barMode = .skipReason(targets: t)
    }

    func skip(reason: ReviewSkipReason) async {
        guard case .skipReason(let t) = barMode else { return }
        barMode = .actions
        let nextFocus = queue.first { !t.contains($0.id) }?.id
        var skipped = 0
        for id in t {
            guard let appID = store.jobs.job(id: id)?.applicationID else { continue }
            if await store.reject(applicationID: appID, reason: reason.rawValue) { skipped += 1 }
        }
        selection.subtract(t)
        focusedJobID = nextFocus
        if skipped > 0 {
            store.toasts.show(skipped == 1 ? "Skipped · \(reason.title)" : "Skipped \(skipped) · \(reason.title)",
                              symbol: "arrow.uturn.right", style: .info)
        }
        pruneSelection()
    }

    // MARK: Inline edits

    /// Edit one answer (it becomes "you" provenance once the daemon confirms).
    func editAnswer(_ answer: ApplicationAnswerItem, to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != answer.answer else { return }
        // Optimistic: show the edit (and "you" provenance) immediately; the DB stream reconciles.
        let appID = answer.applicationID
        let before = answers[appID]
        if let i = answers[appID]?.firstIndex(where: { $0.id == answer.id }) {
            answers[appID]?[i].answer = trimmed
            answers[appID]?[i].origin = .user
            answers[appID]?[i].confidence = 1
        }
        let result = await store.perform(.editApplicationAnswer(EditApplicationAnswerPayload(applicationAnswerId: answer.id, answer: trimmed)))
        if case .failure = result { answers[appID] = before }
    }

    /// Per-job mode override (Inherit / Auto / Review) for the focused job.
    func setMode(_ mode: Mode?, for job: JobItem) async {
        await store.setJobMode(jobID: job.id, mode: mode)
    }
}
