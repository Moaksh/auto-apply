// EasyApplyModel.swift — the LinkedIn Easy Apply manual list. The
// app never automates LinkedIn: it shows pre-drafted answers to copy, opens the posting in the
// user's browser, offers the resume PDF to drag into the upload field, and records "Mark as
// applied" (mode `manual`, which doesn't count toward the daily cap).
import AppKit
import Foundation
import Observation

/// One Easy Apply job joined with its job row.
struct EasyApplyEntry: Identifiable, Hashable, Sendable {
    var item: EasyApplyItem
    var job: JobItem?

    var id: Int { item.jobID }
    var company: String { job?.company ?? "Job #\(item.jobID)" }
    var title: String { job?.title ?? "" }
    var score: Int? { job?.score }
}

@MainActor
@Observable
final class EasyApplyModel {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case unopened, all, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .unopened: "Unopened"
            case .all: "All"
            case .done: "Done"
            }
        }
    }

    let store: AppStore
    @ObservationIgnored var clipboard: ClipboardWriting = SystemClipboard.shared
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    var filter: Filter = .unopened
    var selectedJobID: Int?
    /// Focused drafted-answer row (↑↓ moves, C copies).
    var focusedRow: Int = 0
    /// Row whose copy icon is showing the checkmark (resets after 1.2 s).
    private(set) var copiedRowID: String?
    private(set) var copyFlashSerial = 0

    static func shared(for store: AppStore) -> EasyApplyModel {
        FeatureModels.model(EasyApplyModel.self, for: store) { EasyApplyModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

    // MARK: Lists

    private var allEntries: [EasyApplyEntry] {
        store.library.easyApply.map { EasyApplyEntry(item: $0, job: store.jobs.job(id: $0.jobID)) }
    }

    func entries(for filter: Filter) -> [EasyApplyEntry] {
        let list: [EasyApplyEntry]
        switch filter {
        case .unopened: list = allEntries.filter { $0.item.isOpen && !$0.item.opened }
        case .all: list = allEntries.filter { !$0.item.dismissed }
        case .done: list = allEntries.filter { $0.item.done }
        }
        return list.sorted { a, b in
            // To-do before done, then best match first, newest first.
            if a.item.done != b.item.done { return !a.item.done }
            if (a.score ?? 0) != (b.score ?? 0) { return (a.score ?? 0) > (b.score ?? 0) }
            return a.item.createdAt > b.item.createdAt
        }
    }

    var visible: [EasyApplyEntry] { entries(for: filter) }

    var toDoCount: Int { store.library.easyApplyToDoCount }

    var selected: EasyApplyEntry? {
        guard let id = selectedJobID else { return nil }
        return allEntries.first { $0.id == id }
    }

    func ensureSelection() {
        if let id = selectedJobID, visible.contains(where: { $0.id == id }) { return }
        selectedJobID = visible.first?.id
        focusedRow = 0
    }

    func select(_ jobID: Int?) {
        selectedJobID = jobID
        focusedRow = 0
    }

    func moveSelection(by delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedJobID } ?? (delta > 0 ? -1 : list.count)
        select(list[max(0, min(list.count - 1, current + delta))].id)
    }

    // MARK: Rows

    /// Answers that can be copied (not "Ask me" placeholders).
    func copyableAnswers(_ entry: EasyApplyEntry) -> [DraftedAnswer] {
        entry.item.draftedAnswers.filter { !$0.askMe && !$0.answer.isEmpty }
    }

    func askMeAnswers(_ entry: EasyApplyEntry) -> [DraftedAnswer] {
        entry.item.draftedAnswers.filter { $0.askMe || $0.answer.isEmpty }
    }

    func moveFocusedRow(by delta: Int) {
        guard let entry = selected else { return }
        let count = copyableAnswers(entry).count
        guard count > 0 else { return }
        focusedRow = max(0, min(count - 1, focusedRow + delta))
    }

    /// Resume to upload: the variant drafted for this job, else the default.
    func resume(for entry: EasyApplyEntry) -> ResumeVariantItem? {
        store.library.resume(id: entry.item.resumeVariantID ?? entry.job?.resumeVariantID) ?? store.library.defaultResume
    }

    func resumeURL(for entry: EasyApplyEntry) -> URL? {
        resume(for: entry).flatMap { LocalFiles.existing($0.filePath) }
    }

    // MARK: Copy

    func copy(_ answer: DraftedAnswer) {
        clipboard.write(answer.answer)
        copiedRowID = answer.id
        copyFlashSerial += 1
        let serial = copyFlashSerial
        store.toasts.show("Copied · \(answer.question)", symbol: "checkmark", style: .success)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, self.copyFlashSerial == serial else { return }
            self.copiedRowID = nil
        }
    }

    /// C on the focused row.
    func copyFocused() {
        guard let entry = selected else { return }
        let rows = copyableAnswers(entry)
        guard rows.indices.contains(focusedRow) else { return }
        copy(rows[focusedRow])
    }

    /// ⌘⇧C: every answer as "Question: Answer" lines, plus the job header.
    func copyAll() {
        guard let entry = selected else { return }
        clipboard.write(Self.formatted(entry))
        store.toasts.show("Copied all answers · \(entry.company)", symbol: "doc.on.doc", style: .success)
    }

    nonisolated static func formatted(_ entry: EasyApplyEntry) -> String {
        var lines = ["\(entry.company)\(entry.title.isEmpty ? "" : " · \(entry.title)")", ""]
        for a in entry.item.draftedAnswers where !a.askMe && !a.answer.isEmpty {
            lines.append("\(a.question): \(a.answer)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    /// O: open the posting in the user's own browser (never automated) and mark it opened.
    func openPosting() {
        guard let entry = selected, let url = URL(string: entry.item.url) else { return }
        openURL(url)
        if !entry.item.opened {
            Task { await store.markEasyApplyOpened(jobID: entry.id) }
        }
    }

    func markApplied() async {
        guard let entry = selected else { return }
        let next = visible.first { $0.id != entry.id && !$0.item.done }?.id
        let result = await store.perform(.markEasyApplyDone(MarkEasyApplyDonePayload(jobId: entry.id)))
        if case .success = result {
            store.toasts.show("Marked as applied · \(entry.company)", symbol: "checkmark.circle.fill", style: .success)
            select(next)
        }
    }

    func dismiss() async {
        guard let entry = selected else { return }
        let next = visible.first { $0.id != entry.id }?.id
        let result = await store.perform(.dismissEasyApply(DismissEasyApplyPayload(jobId: entry.id)))
        if case .success = result { select(next) }
    }
}
