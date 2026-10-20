// ReviewModel.swift — Review queue logic (docs/UI_UX_PLAN.md §5.6): flagged (medium/low
// confidence) items sorted to the top, multi-selection, the floating bar's states (actions →
// "include the flagged one?" safeguard → skip reason picker), staggered approve, reject with a
// reason, and inline answer edits.
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
    /// Rows animating out after approval (job ids → order index for the 40 ms stagger).
    private(set) var departing: [Int: Int] = [:]
    /// Q&A per application id (streamed from the DB).
    private(set) var answers: [Int: [ApplicationAnswerItem]] = [:]
    /// Application ids whose Q&A stream has emitted at least once. Until then an application's
    /// confidence is *unknown* and it is never treated as clean by the approve safeguard.
    private(set) var loadedApplicationIDs: Set<Int> = []
    /// Job ids with an approve in flight (stagger + hold + daemon round trip); a second press
    /// on the same rows is ignored instead of sending a duplicate `approve`.
    private(set) var approving: Set<Int> = []

    /// True while any approve is running (disables the bar's Approve button).
    var isApproving: Bool { !approving.isEmpty }

    @ObservationIgnored private var answerTasks: [Int: Task<Void, Never>] = [:]
    /// Delay between rows sliding out, and the pause before the command is sent.
    @ObservationIgnored var staggerStep: Duration = .milliseconds(40)
    @ObservationIgnored var departHold: Duration = .milliseconds(260)

    static func shared(for store: AppStore) -> ReviewModel {
        FeatureModels.model(ReviewModel.self, for: store) { ReviewModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

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
        return store.jobs.job(id: id).flatMap { $0.state == .awaitingReview || departing[$0.id] != nil ? $0 : nil }
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
            .map { "\(Ats(rawValue: $0.key)?.label ?? $0.key.capitalized) override: \($0.value.rawValue.capitalized)" }
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
        if let f = focusedJobID, !live.contains(f), departing[f] == nil { focusedJobID = nil }
        if focusedJobID == nil { focusedJobID = queue.first?.id }
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
        selection = Set(queue.map(\.id))
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

    /// Targets for an action: the selection when non-empty, else the focused row. Rows already
    /// departing / being approved are excluded.
    var targets: [Int] {
        let order = queue.map(\.id).filter { departing[$0] == nil && !approving.contains($0) }
        if !selection.isEmpty { return order.filter(selection.contains) }
        guard let f = focusedJobID, departing[f] == nil, !approving.contains(f) else { return [] }
        return [f]
    }

    /// "Approve & submit" / "Approve 2 (1 needs a look)".
    var approveTitle: String {
        let t = targets
        let flagged = t.filter(needsLook(jobID:)).count
        if t.count <= 1 { return flagged > 0 ? "Approve (needs a look)" : "Approve & submit" }
        return flagged > 0 ? "Approve \(t.count) (\(flagged) need\(flagged == 1 ? "s" : "") a look)" : "Approve \(t.count) & submit"
    }

    // MARK: Approve (with the low-confidence safeguard)

    /// A / the bar's Approve button (the selection, else the focused row), or the detail pane's
    /// button (`only` that job, whatever else is selected). Asks inline (no modal) when flagged
    /// items are included.
    func requestApprove(only: [Int]? = nil) async {
        let t = only.map { ids in ids.filter { departing[$0] == nil && !approving.contains($0) } } ?? targets
        guard !t.isEmpty else { return }
        let flagged = t.filter(needsLook(jobID:))
        if flagged.isEmpty {
            await approve(t)
        } else if flagged.count == t.count {
            barMode = .confirmAllFlagged(targets: t)
        } else {
            barMode = .confirmFlagged(targets: t)
        }
    }

    /// Answer the safeguard question.
    func confirmApprove(includeFlagged: Bool) async {
        let t: [Int]
        switch barMode {
        case .confirmFlagged(let targets), .confirmAllFlagged(let targets): t = targets
        default: return
        }
        let chosen = includeFlagged ? t : t.filter { !needsLook(jobID: $0) }
        barMode = .actions
        await approve(chosen)
    }

    func cancelBar() { barMode = .actions }

    /// Rows slide out in sequence (40 ms stagger, each with a ✓ draw-on), then the daemon is
    /// asked to submit them; progress shows in the hero / menu bar, not here.
    func approve(_ requested: [Int]) async {
        // In-flight guard: a double press (or a bar button during the departure animation)
        // must not send a second `approve` for rows already on their way.
        var jobIDs = requested.filter { !approving.contains($0) && departing[$0] == nil }
        // The daemon allows one application per company per cooldown window and refuses the whole
        // batch otherwise. Send the first job per company; the rest stay here for later.
        var held: [String] = []
        if store.preferences.perCompanyCooldownDays > 0 {
            var seen: Set<Int> = []
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
        let appIDs = jobIDs.compactMap { store.jobs.job(id: $0)?.applicationID }
        guard !appIDs.isEmpty else { return }
        approving.formUnion(jobIDs)
        defer { approving.subtract(jobIDs) }
        let nextFocus = queue.first { !jobIDs.contains($0.id) }?.id
        for (i, id) in jobIDs.enumerated() {
            departing[id] = i
            if i < jobIDs.count - 1 { try? await Task.sleep(for: staggerStep) }
        }
        try? await Task.sleep(for: departHold)
        selection.subtract(jobIDs)
        focusedJobID = nextFocus
        let ok = await store.approve(applicationIDs: appIDs)
        for id in jobIDs { departing.removeValue(forKey: id) }
        if ok {
            store.toasts.show(appIDs.count == 1 ? "Approved · submitting" : "Approved \(appIDs.count) · submitting",
                              symbol: "paperplane.fill", style: .success)
        }
        pruneSelection()
    }

    // MARK: Skip

    /// S / Skip: open the reason picker in the bar.
    func requestSkip(only: [Int]? = nil) {
        let t = only.map { ids in ids.filter { departing[$0] == nil && !approving.contains($0) } } ?? targets
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
