// ResumeEditorModel.swift — one "Edit with Claude" session on a resume with an editable source
// (protocol.md §5.6). The resume is a list of segments; the user edits them by hand or asks
// Claude for changes (or to tailor it for a job), and each suggested change arrives as a before /
// after diff to accept or reject. Accepted text is the working copy Claude edits from next. A live
// PDF follows every change (debounced; optionally with Claude's pending suggestions in it).
// Nothing is saved until Save, which stores the next version (the uploaded PDF is kept).
import Foundation
import Observation

@MainActor
@Observable
final class ResumeEditorModel {
    struct Message: Identifiable, Hashable {
        enum Role: Hashable { case user, claude, note }
        let id = UUID()
        var role: Role
        var text: String
        var warning: String?
    }

    enum Phase: Equatable {
        case loading, idle, thinking, saving
        case failed(String)
    }

    let store: AppStore
    let variantID: Int
    private(set) var source: ResumeSource?
    private(set) var phase: Phase = .loading
    /// Segment text as it is now (the source plus accepted / typed changes).
    private(set) var working: [String: String] = [:]
    private(set) var original: [String: String] = [:]
    /// Claude's suggestions not yet accepted or rejected, in segment order.
    private(set) var pending: [ResumeEdit] = []
    private(set) var messages: [Message] = []
    private(set) var history: [String] = []
    var input = ""
    var tailorJobID: Int?
    private(set) var saved: SaveResumeEditResult?

    // Live PDF
    /// Show Claude's pending suggestions in the preview before they're accepted.
    var previewSuggestions = true { didSet { if previewSuggestions != oldValue { schedulePreview() } } }
    private(set) var previewPath: String?
    private(set) var previewPages: Int?
    private(set) var previewRendering = false
    private(set) var previewError: String?
    /// Bumped on every new preview so the PDF view reloads even when the path repeats.
    private(set) var previewRevision = 0
    @ObservationIgnored var previewDebounce: Duration = .milliseconds(900)
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewSequence = 0

    init(store: AppStore, variantID: Int) {
        self.store = store
        self.variantID = variantID
    }

    var variant: ResumeVariantItem? { store.library.resume(id: variantID) }
    var segments: [ResumeSegment] { source?.segments ?? [] }
    var changedIDs: [String] { segments.map(\.id).filter { working[$0] != original[$0] } }
    var isBusy: Bool { phase == .thinking || phase == .saving || phase == .loading }
    var canSave: Bool { !changedIDs.isEmpty && !isBusy && source?.renderer != nil }
    var errorMessage: String? { if case .failed(let m) = phase { m } else { nil } }

    func text(_ id: String) -> String { working[id] ?? "" }
    func pendingEdit(for id: String) -> ResumeEdit? { pending.first { $0.segmentId == id } }

    /// Jobs worth tailoring for: open applications first, newest first.
    var tailorCandidates: [JobItem] {
        let open: Set<AppState> = [.queued, .awaitingReview, .needsYou, .scored, .discovered]
        return store.jobs.all
            .sorted { (open.contains($0.state) ? 0 : 1, -$0.discoveredAt.timeIntervalSince1970) < (open.contains($1.state) ? 0 : 1, -$1.discoveredAt.timeIntervalSince1970) }
            .prefix(25).map { $0 }
    }

    func job(_ id: Int?) -> JobItem? { id.flatMap { id in store.jobs.all.first { $0.id == id } } }

    // MARK: Load

    func load() async {
        phase = .loading
        switch await store.resumeSource(variantID: variantID) {
        case .success(let s):
            source = s
            original = Dictionary(s.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
            working = original
            phase = .idle
            showPreview(path: variant?.filePath, pages: nil)
            if messages.isEmpty {
                messages.append(Message(role: .claude, text: "Tell me what to change, or pick a job and I'll tailor this resume for it. "
                                        + "I only use what's in your profile, stories and this resume."))
            }
            if s.renderer == nil, let hint = s.renderHint {
                messages.append(Message(role: .note, text: "I can't make the PDF on this Mac yet. \(hint)"))
            }
        case .failure(let e):
            phase = .failed(Self.message(e))
        }
    }

    // MARK: Ask Claude

    func send() async {
        let ask = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobID = tailorJobID
        guard !isBusy, !ask.isEmpty || jobID != nil else { return }
        let shown = ask.isEmpty ? "Tailor it for \(job(jobID)?.displayName ?? "this job")." : ask
        messages.append(Message(role: .user, text: shown))
        input = ""
        phase = .thinking
        // The working copy minus what Claude still has on the table: it edits from what the user kept.
        let changed = Dictionary(changedIDs.map { ($0, working[$0] ?? "") }, uniquingKeysWith: { a, _ in a })
        let result = await store.proposeResumeEdits(variantID: variantID, instructions: ask, jobID: jobID,
                                                    working: changed, history: history)
        switch result {
        case .success(let proposal):
            history.append(shown)
            tailorJobID = nil
            let order = Dictionary(segments.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            // A new suggestion for a segment replaces the older one still waiting.
            let fresh = Set(proposal.edits.map(\.segmentId))
            pending = (pending.filter { !fresh.contains($0.segmentId) } + proposal.edits)
                .sorted { (order[$0.segmentId] ?? 0) < (order[$1.segmentId] ?? 0) }
            if previewSuggestions && !proposal.edits.isEmpty { schedulePreview() }
            let flagged = proposal.edits.flatMap(\.unsupportedClaims)
            let reply = proposal.edits.isEmpty ? (proposal.summary.isEmpty ? "I didn't find anything to change for that." : proposal.summary)
                : proposal.summary + (proposal.summary.isEmpty ? "" : " ") + "\(proposal.edits.count) change\(proposal.edits.count == 1 ? "" : "s") to review on the left."
            messages.append(Message(role: .claude, text: reply,
                                    warning: flagged.isEmpty ? nil : "I couldn't find \(Self.list(flagged)) in your profile, stories or this resume. "
                                        + "Reject that change, or tell me where it comes from."))
            phase = .idle
        case .failure(let e):
            messages.append(Message(role: .note, text: Self.message(e)))
            phase = .idle
        }
    }

    func accept(_ edit: ResumeEdit) {
        working[edit.segmentId] = edit.after
        pending.removeAll { $0.segmentId == edit.segmentId }
        schedulePreview()
    }

    func reject(_ edit: ResumeEdit) {
        pending.removeAll { $0.segmentId == edit.segmentId }
        schedulePreview()
    }

    /// Accept every waiting change that the fact check found nothing wrong with.
    func acceptAllGrounded() {
        for e in pending where e.unsupportedClaims.isEmpty { working[e.segmentId] = e.after }
        pending.removeAll { $0.unsupportedClaims.isEmpty }
        schedulePreview()
    }

    func setText(_ text: String, for id: String) {
        guard working[id] != text else { return }
        working[id] = text
        schedulePreview()
    }

    func revert(_ id: String) {
        working[id] = original[id]
        schedulePreview()
    }

    // MARK: Live PDF

    /// What the preview shows: the working copy's changes, plus pending suggestions when asked.
    var previewEdits: [String: String] {
        var edits = Dictionary(changedIDs.map { ($0, working[$0] ?? "") }, uniquingKeysWith: { a, _ in a })
        if previewSuggestions { for e in pending { edits[e.segmentId] = e.after } }
        return edits
    }

    /// Re-render shortly after the last change (typing doesn't render on every key).
    func schedulePreview() {
        guard source?.renderer != nil else { return }
        previewTask?.cancel()
        let delay = previewDebounce
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.renderPreview()
        }
    }

    func renderPreview() async {
        let edits = previewEdits
        previewSequence += 1
        let seq = previewSequence
        previewRendering = true
        let result = await store.previewResumeEdit(variantID: variantID, edits: edits)
        guard seq == previewSequence else { return }  // a newer render was asked for meanwhile
        previewRendering = false
        switch result {
        case .success(let p):
            previewError = nil
            showPreview(path: p.filePath, pages: p.pages)
        case .failure(let e):
            previewError = Self.message(e)
        }
    }

    private func showPreview(path: String?, pages: Int?) {
        previewPath = path
        previewPages = pages
        previewRevision += 1
    }

    // MARK: Save

    @discardableResult
    func save(asNew: Bool = false, label: String? = nil) async -> Bool {
        guard canSave else { return false }
        phase = .saving
        let edits = Dictionary(changedIDs.map { ($0, working[$0] ?? "") }, uniquingKeysWith: { a, _ in a })
        switch await store.saveResumeEdit(variantID: variantID, edits: edits, asNew: asNew, label: label) {
        case .success(let r):
            saved = r
            phase = .idle
            store.toasts.show(asNew ? "Saved as a new resume" : "Saved as v\(r.version)", symbol: "doc.badge.plus", style: .success)
            ResumesModel.shared(for: store).selectedID = r.resumeVariantId
            return true
        case .failure(let e):
            phase = .failed(Self.message(e))
            return false
        }
    }

    func dismissError() {
        if case .failed = phase { phase = source == nil ? .loading : .idle }
    }

    static func message(_ error: DaemonClientError) -> String {
        switch error {
        case .daemon(let p): p.message
        case .timeout: "That took too long. Try again."
        case .notConnected: "Can't reach the agent. Editing needs it running."
        case .encoding, .decoding: "The agent's reply couldn't be read. Try again."
        }
    }

    static func list(_ items: [String]) -> String {
        let unique = Array(NSOrderedSet(array: items).compactMap { $0 as? String }.prefix(4))
        return unique.count <= 1 ? (unique.first ?? "") : unique.dropLast().joined(separator: ", ") + " or " + unique.last!
    }
}
