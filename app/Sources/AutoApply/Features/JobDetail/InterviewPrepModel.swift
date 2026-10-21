// InterviewPrepModel.swift — Job detail ▸ Interview prep state (contract/protocol.md §5.4): the
// stored pack per application (read without a model call), Generate / Regenerate, and the
// debrief notes → structured debrief + a thank-you draft that is never sent. One model per store,
// keyed by application, so a pack and an unsent note survive switching tabs or jobs.
import Foundation
import Observation

@MainActor
@Observable
final class InterviewPrepModel {
    enum PackState: Equatable, Sendable {
        /// Not asked yet.
        case unknown
        case loading
        /// No pack stored for this application.
        case empty
        case ready
        case failed(String)
    }

    let store: AppStore
    private(set) var packs: [Int: InterviewPrepPack] = [:]
    private(set) var states: [Int: PackState] = [:]
    private(set) var generating: Set<Int> = []
    private(set) var generateErrors: [Int: String] = [:]
    /// Debriefs for an application, newest last (stored ones plus those written this session).
    private(set) var debriefs: [Int: [InterviewDebrief]] = [:]
    private(set) var debriefing: Set<Int> = []
    private(set) var debriefErrors: [Int: String] = [:]
    /// Unsent debrief notes per application.
    var notes: [Int: String] = [:]

    /// Reads `<home>/interview_prep/<id>.debriefs.json` (the protocol has no command for past
    /// debriefs). Only for the real database; mock mode and tests start empty.
    @ObservationIgnored var storedDebriefs: @MainActor (Int) -> [InterviewDebrief]

    static let maxNotes = 20_000

    static func shared(for store: AppStore) -> InterviewPrepModel {
        FeatureModels.model(InterviewPrepModel.self, for: store) { InterviewPrepModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
        let readsFiles = store.repository is GRDBRepository
        storedDebriefs = { id in readsFiles ? Self.readDebriefs(applicationID: id, home: AppPaths.resolve().home) : [] }
    }

    // MARK: Queries

    func state(_ applicationID: Int?) -> PackState {
        guard let applicationID else { return .empty }
        return states[applicationID] ?? .unknown
    }

    func pack(_ applicationID: Int?) -> InterviewPrepPack? { applicationID.flatMap { packs[$0] } }

    /// The tab shows for jobs at Assessment / Interview / Offer, or whenever a pack exists.
    static func isStage(_ job: JobItem) -> Bool {
        guard job.state == .submitted, job.applicationID != nil else { return false }
        return [.assessment, .interview, .offer].contains(job.status ?? .applied)
    }

    func showsTab(for job: JobItem) -> Bool {
        Self.isStage(job) || pack(job.applicationID) != nil
    }

    /// Questions grouped by kind, in a fixed order (behavioural, technical, about the role).
    static func grouped(_ questions: [InterviewQuestion]) -> [(kind: InterviewQuestion.Kind, questions: [InterviewQuestion])] {
        InterviewQuestion.Kind.allCases.compactMap { kind in
            let qs = questions.filter { $0.kind == kind }
            return qs.isEmpty ? nil : (kind, qs)
        }
    }

    // MARK: Commands

    /// Read the stored pack once per application (no model call). `force` re-reads.
    func load(applicationID: Int?, force: Bool = false) async {
        guard let applicationID else { return }
        if !force, let s = states[applicationID], s != .unknown, !isFailed(s) { return }
        if debriefs[applicationID] == nil {
            let stored = storedDebriefs(applicationID)
            if !stored.isEmpty { debriefs[applicationID] = stored }
        }
        // A re-check keeps a pack on screen instead of flashing "Looking…".
        if packs[applicationID] == nil { states[applicationID] = .loading }
        switch await store.interviewPrep(applicationID: applicationID) {
        case .success(let pack?):
            packs[applicationID] = pack
            states[applicationID] = .ready
        case .success(nil):
            packs[applicationID] = nil
            states[applicationID] = .empty
        case .failure:
            if packs[applicationID] == nil { states[applicationID] = .failed(store.lastOutreachErrorMessage) }
        }
    }

    /// Write the pack (`force` rewrites an existing one). A failure keeps any pack already shown.
    func generate(applicationID: Int?, force: Bool) async {
        guard let applicationID, !generating.contains(applicationID) else { return }
        generating.insert(applicationID)
        generateErrors[applicationID] = nil
        defer { generating.remove(applicationID) }
        if let pack = await store.generateInterviewPrep(applicationID: applicationID, force: force) {
            packs[applicationID] = pack
            states[applicationID] = .ready
        } else {
            generateErrors[applicationID] = store.lastOutreachErrorMessage
            if packs[applicationID] == nil { states[applicationID] = .empty }
        }
    }

    enum NotesIssue: Equatable { case empty, tooLong }

    static func notesIssue(_ text: String) -> NotesIssue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > maxNotes { return .tooLong }
        return nil
    }

    /// Notes → debrief. The notes stay in the editor until a debrief comes back.
    func debrief(applicationID: Int?) async {
        guard let applicationID, !debriefing.contains(applicationID) else { return }
        let text = (notes[applicationID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.notesIssue(text) {
        case .empty?:
            debriefErrors[applicationID] = "Write a few lines about how it went first."
            return
        case .tooLong?:
            debriefErrors[applicationID] = "Keep the notes under \(Self.maxNotes.formatted()) characters."
            return
        case nil:
            break
        }
        debriefing.insert(applicationID)
        debriefErrors[applicationID] = nil
        defer { debriefing.remove(applicationID) }
        if let result = await store.interviewDebrief(applicationID: applicationID, notes: text) {
            debriefs[applicationID, default: []].append(result)
            notes[applicationID] = ""
        } else {
            debriefErrors[applicationID] = store.lastOutreachErrorMessage
        }
    }

    func latestDebrief(_ applicationID: Int?) -> InterviewDebrief? { applicationID.flatMap { debriefs[$0]?.last } }

    /// "Subject: …\n\nbody" for the clipboard.
    static func clipboardText(_ draft: ThankYouDraft) -> String {
        draft.subject.isEmpty ? draft.body : "Subject: \(draft.subject)\n\n\(draft.body)"
    }

    private func isFailed(_ s: PackState) -> Bool { if case .failed = s { true } else { false } }

    nonisolated static func readDebriefs(applicationID: Int, home: URL) -> [InterviewDebrief] {
        let url = home.appendingPathComponent("interview_prep/\(applicationID).debriefs.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? ProtocolCoding.makeDecoder().decode([InterviewDebrief].self, from: data)) ?? []
    }
}

extension InterviewQuestion.Kind {
    var title: String {
        switch self {
        case .behavioural: "Behavioural"
        case .technical: "Technical"
        case .role: "About the role"
        }
    }
}

extension ChecklistItem.Source {
    var label: String {
        switch self {
        case .employerReply: "From their email"
        case .job: "From the posting"
        case .general: "General"
        }
    }
}
