// BoardModel.swift — Pipeline board logic (docs/UI_UX_PLAN.md §5.3): column/filter
// derivation, legal-drop rules (a card dropped on Queued is applied to by the agent; one the
// agent never submitted dropped on Applied or later = "I applied myself"; the user owns
// post-apply statuses), keyboard moves, undo, nudge and ghosting affordances. Pure rules live in
// `BoardRules` (unit-tested); `BoardModel` adds the stateful drag/undo/celebration bits.
import AppKit
import Foundation
import Observation

enum BoardRules {
    // MARK: Columns & filtering

    /// Columns to render for `filter` (Skipped is appended behind "Show skipped").
    static func visibleColumns(filter: PipelineFilter) -> [BoardColumn] {
        var columns = BoardColumn.defaultVisible
        if filter.showSkipped { columns = [.discovered, .skipped] + columns }
        if let only = filter.columns, !only.isEmpty {
            return BoardColumn.allCases.filter { only.contains($0) }
        }
        return columns
    }

    static func matches(_ job: JobItem, filter: PipelineFilter) -> Bool {
        if let source = filter.source, job.source != source { return false }
        if let min = filter.minScore, (job.score ?? -1) < min { return false }
        if let status = filter.status, !(job.state == .submitted && (job.status ?? .applied) == status) { return false }
        if let reason = filter.skipReason, skipReasonKey(job.skipReason ?? job.stateReason) != skipReasonKey(reason) { return false }
        let q = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            let haystack = "\(job.company) \(job.title) \(job.location ?? "") \(job.ats.label) \(job.source.label)".lowercased()
            if !q.split(separator: " ").allSatisfy({ haystack.contains($0) }) { return false }
        }
        return true
    }

    static func filtered(_ jobs: [JobItem], filter: PipelineFilter) -> [JobItem] {
        jobs.filter { matches($0, filter: filter) }
    }

    /// Jobs per column after filtering, in the store's column order (newest update first).
    static func columns(from store: [BoardColumn: [JobItem]], visible: [BoardColumn], filter: PipelineFilter) -> [BoardColumn: [JobItem]] {
        var out: [BoardColumn: [JobItem]] = [:]
        for column in visible { out[column] = filtered(store[column] ?? [], filter: filter) }
        return out
    }

    // MARK: Closed drawer (a kind no)

    /// Rejected and Ghosted fold into one quiet "Closed" drawer at the end of the board.
    static let closedColumns: [BoardColumn] = [.rejected, .ghosted]

    /// The columns that stay open on the board.
    static func openColumns(_ visible: [BoardColumn]) -> [BoardColumn] {
        visible.filter { !closedColumns.contains($0) }
    }

    /// The visible columns that live in the Closed drawer.
    static func drawerColumns(_ visible: [BoardColumn]) -> [BoardColumn] {
        visible.filter { closedColumns.contains($0) }
    }

    /// The drawer opens by itself when the filter asks for a closed column (e.g. a funnel click).
    static func drawerForcedOpen(filter: PipelineFilter) -> Bool {
        guard let only = filter.columns, !only.isEmpty else { return false }
        return only.contains { closedColumns.contains($0) }
    }

    /// Columns the arrow keys walk: closed ones only while the drawer is open.
    static func navigableColumns(_ visible: [BoardColumn], drawerOpen: Bool) -> [BoardColumn] {
        drawerOpen ? visible : openColumns(visible)
    }

    /// Plain, kind names inside the drawer.
    static func closedTitle(_ column: BoardColumn) -> String {
        switch column {
        case .rejected: "They went another way"
        case .ghosted: "No reply"
        default: column.title
        }
    }

    /// How a move to `status` is named in menus and toasts. A rejection is never "Rejected".
    static func moveLabel(_ status: BoardStatus) -> String {
        switch status {
        case .rejected: "Closed · they went another way"
        case .ghosted: "Closed · no reply"
        default: status.label
        }
    }

    /// Neutral symbol for a closed column (a soft fold, not an X).
    static func closedSymbol(_ column: BoardColumn) -> String {
        column == .ghosted ? "moon.zzz" : "archivebox"
    }

    // MARK: Drag & drop legality

    /// The agent can apply to it: not applied yet, not being worked on, and it has a company
    /// form (Easy Apply / LinkedIn-only jobs don't). Dropping it on Queued starts the agent.
    static func canQueue(_ job: JobItem) -> Bool {
        guard job.applicationID != nil, !job.easyApply, job.applyURL?.isEmpty == false else { return false }
        return [.discovered, .scored, .skipped, .failed].contains(job.state)
    }

    /// "I applied myself": a job the agent never submitted and isn't working on right now.
    static func canMarkApplied(_ job: JobItem) -> Bool {
        job.applicationID != nil && [.discovered, .scored, .skipped, .queued, .needsYou].contains(job.state)
    }

    /// Submitted cards move between post-apply statuses; earlier cards can go to Queued (agent)
    /// or to Applied and later columns (applied by you).
    static func isDraggable(_ job: JobItem) -> Bool {
        isSubmitted(job) || canQueue(job) || canMarkApplied(job)
    }

    private static func isSubmitted(_ job: JobItem) -> Bool {
        job.state == .submitted && job.applicationID != nil
    }

    /// What a drop of `job` on `column` means, or nil when it isn't allowed.
    enum DropAction: Equatable, Sendable {
        case setStatus(BoardStatus)
        case queue
        case markApplied(BoardStatus)
    }

    static func dropAction(_ job: JobItem, on column: BoardColumn) -> DropAction? {
        if column == .queued { return canQueue(job) ? .queue : nil }
        guard let target = column.boardStatus else { return nil }
        if isSubmitted(job) { return target != (job.status ?? .applied) ? .setStatus(target) : nil }
        return canMarkApplied(job) ? .markApplied(target) : nil
    }

    static func canDrop(_ job: JobItem, on column: BoardColumn) -> Bool {
        dropAction(job, on: column) != nil
    }

    /// Legal status moves for a submitted job (accessibility actions "Move to Interview", status menus).
    static func legalTargets(for job: JobItem) -> [BoardStatus] {
        guard isSubmitted(job) else { return [] }
        let current = job.status ?? .applied
        return BoardStatus.ordered.filter { $0 != current }
    }

    /// ⌘← / ⌘→: previous/next status in column order, nil at the ends or for agent-owned jobs.
    static func keyboardTarget(for job: JobItem, delta: Int) -> BoardStatus? {
        guard isSubmitted(job) else { return nil }
        let current = job.status ?? .applied
        return delta < 0 ? current.previous : current.next
    }

    // MARK: Card affordances

    enum Nudge: Equatable, Sendable {
        case heardBack(days: Int)
    }

    /// "Heard back?" on Applied cards from the first nudge day until they ghost.
    static func nudge(for job: JobItem, now: Date, nudgeDays: [Int], ghostAfterDays: Int, calendar: Calendar = .current) -> Nudge? {
        guard job.state == .submitted, (job.status ?? .applied) == .applied,
              let days = job.daysSinceSubmitted(now: now, calendar: calendar),
              let first = nudgeDays.min(), days >= first, days < ghostAfterDays else { return nil }
        return .heardBack(days: days)
    }

    /// Compact age: "5m", "3h", "3d", "6w".
    static func ageText(since date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 3_600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86_400 { return "\(Int(s / 3_600))h" }
        if s < 86_400 * 14 { return "\(Int(s / 86_400))d" }
        return "\(Int(s / (86_400 * 7)))w"
    }

    /// The date a card's age counts from.
    static func ageReference(_ job: JobItem) -> Date {
        job.submittedAt ?? job.stateUpdatedAt ?? job.discoveredAt
    }

    /// Applications that moved to Ghosted since `since` (the "Moved 2 to Ghosted" toast).
    static func newlyGhosted(_ jobs: [JobItem], since: Date) -> [JobItem] {
        jobs.filter { $0.state == .submitted && $0.status == .ghosted && ($0.statusUpdatedAt ?? .distantPast) > since }
    }

    /// Open inbox questions per job ("✋ 2 Qs" chip).
    static func questionCounts(_ clusters: [QuestionCluster]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for cluster in clusters { for id in Set(cluster.jobIds) { out[id, default: 0] += 1 } }
        return out
    }

    // MARK: Outreach

    /// The envelope on a card: emailed someone there, or they replied. Keyed by application id.
    @MainActor
    static func outreachMarks(_ outreach: OutreachStore) -> [Int: JobOutreachMark] {
        var marks: [Int: JobOutreachMark] = [:]
        for thread in outreach.data.threads where thread.applicationID != nil && thread.state != .cancelled {
            let name = outreach.contact(id: thread.contactID)?.fullName.split(separator: " ").first.map(String.init)
            let mark: JobOutreachMark?
            switch thread.state {
            case .replied: mark = .replied(name)
            case .active, .closed, .bounced, .optedOut:
                mark = outreach.lastSent(threadID: thread.id) != nil ? .emailed(name) : nil
            case .draft:
                mark = outreach.lastSent(threadID: thread.id) != nil ? .emailed(name) : nil
            case .cancelled: mark = nil
            }
            guard let mark, let app = thread.applicationID else { continue }
            if case .replied = marks[app] { continue }
            marks[app] = mark
        }
        return marks
    }

    // MARK: Skip reasons

    /// Normalized key: "excluded_keyword:crypto" → "excluded_keyword".
    static func skipReasonKey(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "other" }
        return String(raw.split(separator: ":").first ?? Substring(raw)).lowercased()
    }

    /// One short sentence for a skipped job ("Too senior (staff)", "Match 40 < 70", "Excluded: crypto").
    static func skipTag(_ raw: String?, score: Int?, threshold: Int) -> String {
        let key = skipReasonKey(raw)
        let detail = raw.flatMap { r in r.contains(":") ? String(r.split(separator: ":", maxSplits: 1).last ?? "") : nil } ?? ""
        switch key {
        case "below_threshold": return score.map { "Match \($0) < \(threshold)" } ?? "Below your match threshold"
        case "seniority_mismatch": return ["staff", "principal", "executive", "lead"].contains(detail) ? "Too senior (\(detail))" : "Seniority mismatch"
        case "excluded_keyword": return detail.isEmpty ? "Excluded keyword" : "Excluded: \(detail)"
        case "excluded_company": return "Excluded company"
        case "salary_below_floor", "salary_floor": return "Salary below your floor"
        case "missing_salary": return "No salary listed"
        case "location_mismatch": return "Location doesn't match"
        case "work_auth": return "Needs work authorization"
        case "remote_policy": return detail.isEmpty ? "Work-style mismatch" : "\(detail.capitalized) roles not wanted"
        case "company_cooldown": return "Applied here recently"
        case "daily_cap_reached": return "Daily cap reached"
        case "no_apply_url": return "No company apply link"
        case "posting_closed": return "Posting closed"
        case "asks_candidate_to_pay": return "Asks you to pay a fee"
        case "risk_review": return "Flagged: review before sending"
        default: return skipReasonLabel(raw)
        }
    }

    static func skipReasonLabel(_ raw: String?) -> String {
        switch skipReasonKey(raw) {
        case "below_threshold": "Below threshold"
        case "excluded_keyword": "Excluded keyword"
        case "excluded_company": "Excluded company"
        case "company_cooldown": "Company cooldown"
        case "salary_floor", "salary_below_floor": "Salary floor"
        case "missing_salary": "No salary listed"
        case "work_auth": "Work authorization"
        case "remote_policy": "Work-style mismatch"
        case "daily_cap_reached": "Daily cap"
        case "no_apply_url": "No apply link"
        case "location_mismatch": "Location mismatch"
        case "seniority_mismatch": "Seniority mismatch"
        case "duplicate": "Duplicate"
        case "user": "Skipped by you"
        case "posting_closed": "Posting closed"
        case "asks_candidate_to_pay": "Asks for a fee"
        case "risk_review": "Risk review"
        default: (raw ?? "Other").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "Below threshold · 27", "Excluded keyword · 4", … largest first.
    static func skipReasonGroups(_ jobs: [JobItem]) -> [(key: String, label: String, count: Int)] {
        var counts: [String: (label: String, count: Int)] = [:]
        for job in jobs where job.state == .skipped {
            let raw = job.skipReason ?? job.stateReason
            let key = skipReasonKey(raw)
            counts[key, default: (skipReasonLabel(raw), 0)].count += 1
        }
        return counts.map { (key: $0.key, label: $0.value.label, count: $0.value.count) }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
    }

    // MARK: Keyboard selection

    /// Move the selection within/between columns (↑↓ / ←→, J K / H L).
    static func moveSelection(from id: Int?, columns: [BoardColumn], jobs: [BoardColumn: [JobItem]], dx: Int, dy: Int) -> Int? {
        let nonEmpty = columns.filter { !(jobs[$0] ?? []).isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        guard let id, let col = nonEmpty.firstIndex(where: { (jobs[$0] ?? []).contains { $0.id == id } }),
              let row = jobs[nonEmpty[col]]?.firstIndex(where: { $0.id == id }) else {
            return jobs[nonEmpty[0]]?.first?.id
        }
        if dx != 0 {
            let newCol = min(nonEmpty.count - 1, max(0, col + dx))
            let list = jobs[nonEmpty[newCol]] ?? []
            return list[min(row, list.count - 1)].id
        }
        let list = jobs[nonEmpty[col]] ?? []
        return list[min(list.count - 1, max(0, row + dy))].id
    }
}

/// Board/Table toggle.
enum BoardViewMode: String, CaseIterable, Sendable {
    case board, table

    var title: String { self == .board ? "Board" : "Table" }
}

@MainActor
@Observable
final class BoardModel {
    let store: AppStore

    /// Job currently being dragged (illegal columns dim to 40%).
    var draggingJobID: Int?
    /// Column under the cursor while dragging.
    var targetColumn: BoardColumn?
    /// Last card that landed with a celebration (interview / offer).
    private(set) var celebratedJobID: Int?
    private(set) var celebrationSerial = 0
    /// Last card a drop landed in its new column (it settles into place once).
    private(set) var landedJobID: Int?
    private(set) var landingSerial = 0
    /// One-time "First interview. Nice." note.
    private(set) var firstInterviewNoteJobID: Int?
    /// The Closed drawer (Rejected + Ghosted) is folded until the user opens it.
    var closedExpanded = false

    func toggleClosed() { closedExpanded.toggle() }

    static let firstInterviewKey = "board.firstInterviewCelebrated"
    static let lastVisitKey = "board.lastVisit"
    @ObservationIgnored var defaults: UserDefaults = .standard

    init(store: AppStore) {
        self.store = store
    }

    var draggingJob: JobItem? { draggingJobID.flatMap { store.jobs.job(id: $0) } }

    /// Is `column` a legal target for the job being dragged?
    func isLegalTarget(_ column: BoardColumn) -> Bool {
        guard let job = draggingJob else { return false }
        return BoardRules.canDrop(job, on: column)
    }

    /// Move a submitted job to `status` with optimistic UI, undo (⌘Z + toast) and haptics.
    /// Returns true when the daemon acked.
    @discardableResult
    func move(jobID: Int, to status: BoardStatus, undoManager: UndoManager? = nil, isUndo: Bool = false) async -> Bool {
        guard let job = store.jobs.job(id: jobID), let appID = job.applicationID,
              isUndo ? job.state == .submitted : BoardRules.dropAction(job, on: BoardColumn(status: status)) == .setStatus(status)
        else { return false }
        let previous = job.status ?? .applied
        guard previous != status else { return false }
        let ok = await store.setStatus(applicationID: appID, status: status, offerUndo: false)
        guard ok else { return false }
        Haptics.levelChange()
        // A closed card goes quietly: no sound.
        if !isUndo, !BoardRules.closedColumns.contains(BoardColumn(status: status)) {
            Sounds.play(status == .interview || status == .offer ? .celebrate : .pop)
        }
        if !isUndo {
            celebrateIfNeeded(jobID: jobID, status: status)
            // The undo target and toast action must outlive this model: Job detail and the
            // inspector call `move` on short-lived models, and UndoManager does not retain its
            // target. Register against the (window-lifetime) store and capture it strongly.
            let store = self.store
            undoManager?.registerUndo(withTarget: store) { store in
                MainActor.assumeIsolated {
                    _ = Task { await BoardModel.revert(store: store, jobID: jobID, to: previous) }
                }
            }
            undoManager?.setActionName("Move to \(BoardRules.moveLabel(status))")
            let closed = BoardRules.closedColumns.contains(BoardColumn(status: status))
            store.toasts.show(closed ? BoardRules.moveLabel(status) : "Moved to \(status.label)",
                              symbol: closed ? BoardRules.closedSymbol(BoardColumn(status: status)) : StatusKind(status: status).symbol,
                              style: closed ? .info : .success, duration: .seconds(4), actionTitle: "Undo") {
                Task { await BoardModel.revert(store: store, jobID: jobID, to: previous) }
            }
        }
        return true
    }

    /// Undo of a move: restores `previous` without registering a new undo. Static so it does not
    /// depend on the lifetime of the model that performed the move.
    @discardableResult
    static func revert(store: AppStore, jobID: Int, to previous: BoardStatus) async -> Bool {
        await BoardModel(store: store).move(jobID: jobID, to: previous, undoManager: nil, isUndo: true)
    }

    /// ⌘← / ⌘→ on the focused job.
    @discardableResult
    func moveFocused(by delta: Int, undoManager: UndoManager? = nil) async -> Bool {
        guard let id = store.router.focusedJobID, let job = store.jobs.job(id: id),
              let target = BoardRules.keyboardTarget(for: job, delta: delta) else { return false }
        return await move(jobID: id, to: target, undoManager: undoManager)
    }

    /// Handle a drop payload ("job:<id>") on `column`. Returns whether it was accepted.
    func performDrop(payload: String, on column: BoardColumn, undoManager: UndoManager?) -> Bool {
        defer { endDrag() }
        guard let id = Self.jobID(fromPayload: payload), let job = store.jobs.job(id: id),
              let action = BoardRules.dropAction(job, on: column) else { return false }
        switch action {
        case .setStatus(let status):
            Task { if await move(jobID: id, to: status, undoManager: undoManager) { land(id) } }
        case .queue:
            Task { if await queue(jobID: id) { land(id) } }
        case .markApplied(let status):
            // Can't be undone (it records a real application): ask first.
            pendingManualApply = ManualApply(jobID: id, status: status)
        }
        return true
    }

    /// "I applied myself" waiting for the user's OK (the board shows a confirmation).
    struct ManualApply: Equatable, Identifiable {
        var jobID: Int
        var status: BoardStatus
        var id: Int { jobID }
    }

    var pendingManualApply: ManualApply?

    /// Hand a job to the agent (Queued); it starts right away unless paused.
    @discardableResult
    func queue(jobID: Int) async -> Bool {
        guard let job = store.jobs.job(id: jobID), BoardRules.canQueue(job), let appID = job.applicationID else { return false }
        let ok = await store.queueApplication(applicationID: appID)
        if ok {
            Haptics.levelChange()
            Sounds.play(.send)
        }
        return ok
    }

    @discardableResult
    func confirmManualApply() async -> Bool {
        guard let pending = pendingManualApply else { return false }
        pendingManualApply = nil
        guard let job = store.jobs.job(id: pending.jobID), BoardRules.canMarkApplied(job), let appID = job.applicationID else { return false }
        let ok = await store.markApplied(applicationID: appID, status: pending.status)
        if ok {
            Haptics.levelChange()
            Sounds.play(pending.status == .interview || pending.status == .offer ? .celebrate : .pop)
            celebrateIfNeeded(jobID: pending.jobID, status: pending.status)
        }
        return ok
    }

    /// The dropped card is in its new column: let it settle (KanbanColumn's drop settle).
    private func land(_ jobID: Int) {
        landedJobID = jobID
        landingSerial += 1
    }

    func beginDrag(jobID: Int) {
        draggingJobID = jobID
        store.router.focusedJobID = jobID
    }

    func endDrag() {
        draggingJobID = nil
        targetColumn = nil
    }

    nonisolated static func payload(for jobID: Int) -> String { "autoapply-job:\(jobID)" }

    nonisolated static func jobID(fromPayload payload: String) -> Int? {
        let prefix = "autoapply-job:"
        guard payload.hasPrefix(prefix) else { return nil }
        return Int(payload.dropFirst(prefix.count))
    }

    // MARK: Celebrations

    private func celebrateIfNeeded(jobID: Int, status: BoardStatus) {
        guard status == .interview || status == .offer else { return }
        celebratedJobID = jobID
        celebrationSerial += 1
        if status == .interview && !defaults.bool(forKey: Self.firstInterviewKey) {
            defaults.set(true, forKey: Self.firstInterviewKey)
            firstInterviewNoteJobID = jobID
            let serial = celebrationSerial
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if self?.celebrationSerial == serial { self?.firstInterviewNoteJobID = nil }
            }
        }
    }

    // MARK: Ghosting

    /// On board appear: toast "Moved 2 to Ghosted · 21 days without reply" for cards the daemon
    /// ghosted since the last visit, then stamp the visit.
    func announceGhostedSinceLastVisit(now: Date = Date()) {
        let last = defaults.object(forKey: Self.lastVisitKey) as? Date
        defaults.set(now, forKey: Self.lastVisitKey)
        guard let last, store.jobs.isLoaded else { return }
        let ghosted = BoardRules.newlyGhosted(store.jobs.all, since: last)
        guard !ghosted.isEmpty else { return }
        let days = store.preferences.ghostAfterDays
        store.toasts.show("Closed \(ghosted.count) · no reply in \(days) days", symbol: StatusKind.ghosted.symbol,
                          style: .info, duration: .seconds(4))
    }
}

extension BoardColumn {
    /// The column a board status lives in.
    init(status: BoardStatus) {
        switch status {
        case .applied: self = .applied
        case .assessment: self = .assessment
        case .interview: self = .interview
        case .offer: self = .offer
        case .rejected: self = .rejected
        case .ghosted: self = .ghosted
        }
    }
}

/// A pipeline card's outreach marker (the envelope).
enum JobOutreachMark: Equatable, Sendable {
    /// First name of the person emailed, when known.
    case emailed(String?)
    case replied(String?)

    var text: String {
        switch self {
        case .emailed(let name): name.map { "Emailed \($0)" } ?? "Emailed"
        case .replied(let name): name.map { "\($0) replied" } ?? "Replied"
        }
    }

    var symbol: String {
        switch self {
        case .emailed: "envelope"
        case .replied: "envelope.open.fill"
        }
    }
}
