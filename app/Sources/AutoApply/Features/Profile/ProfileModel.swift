// ProfileModel.swift — Profile document editing: an editable draft of
// the profile saved as a partial `update_profile` patch, answer-memory edits/deletes, and the
// Story bank (STAR) with "Import from text".
import Foundation
import Observation

@MainActor
@Observable
final class ProfileModel {
    let store: AppStore

    /// Non-nil while editing; saved as a diff against the profile it started from.
    var draft: Profile?
    private(set) var editBase: Profile?
    private(set) var isSaving = false
    var linkDraftKey = ""
    var linkDraftValue = ""
    /// Memory row being edited inline (id → text).
    var editingMemoryID: Int?
    var memoryDraft = ""
    /// Memory row asking "Delete?" inline (no modal).
    var confirmingDeleteMemoryID: Int?
    var memoryFilter = ""

    static func shared(for store: AppStore) -> ProfileModel {
        FeatureModels.model(ProfileModel.self, for: store) { ProfileModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

    var profile: Profile { store.library.profile }
    var isEditing: Bool { draft != nil }

    func beginEditing() {
        editBase = profile
        draft = profile
    }

    func cancelEditing() {
        draft = nil
        editBase = nil
    }

    /// The patch that Save would send.
    var pendingPatch: ProfilePatch {
        guard let draft, let base = editBase else { return ProfilePatch() }
        return JSONDiff.profilePatch(from: base, to: Self.normalized(draft))
    }

    /// Trim strings, drop empty list entries, recompute full name from first/last if needed.
    static func normalized(_ p: Profile) -> Profile {
        var n = p
        func clean(_ s: String?) -> String? { s.c3Trimmed }
        n.firstName = clean(p.firstName)
        n.lastName = clean(p.lastName)
        n.fullName = clean(p.fullName) ?? [n.firstName, n.lastName].compactMap { $0 }.joined(separator: " ").c3NilIfEmpty
        n.email = clean(p.email)
        n.phone = clean(p.phone)
        n.location = clean(p.location)
        n.headline = clean(p.headline)
        n.summary = clean(p.summary)
        n.links = p.links.reduce(into: [:]) { acc, kv in
            let k = kv.key.trimmingCharacters(in: .whitespaces), v = kv.value.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty && !v.isEmpty { acc[k] = v }
        }
        n.skills = p.skills.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        n.workHistory = p.workHistory.filter { !$0.company.trimmingCharacters(in: .whitespaces).isEmpty }.map { w in
            var w = w
            w.highlights = w.highlights.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return w
        }
        n.education = p.education.filter { !$0.school.trimmingCharacters(in: .whitespaces).isEmpty }
        return n
    }

    /// Validate obvious mistakes before sending.
    static func validate(_ p: Profile) -> String? {
        if let email = p.email.c3Trimmed, !(email.contains("@") && email.split(separator: "@").last?.contains(".") == true) {
            return "That email doesn't look right."
        }
        if let years = p.yearsExperience, years < 0 || years > 60 { return "Years of experience should be 0–60." }
        for (name, url) in p.links where !url.isEmpty && URL(string: url)?.scheme == nil {
            return "The \(name) link needs to start with https://."
        }
        return nil
    }

    @discardableResult
    func save() async -> Bool {
        guard let draft else { return true }
        if let problem = Self.validate(Self.normalized(draft)) {
            store.toasts.error(problem)
            return false
        }
        let patch = pendingPatch
        guard !patch.isEmpty else { cancelEditing(); return true }
        isSaving = true
        defer { isSaving = false }
        if await store.updateProfile(patch) != nil {
            cancelEditing()
            store.toasts.show("Profile saved", symbol: "checkmark", style: .success)
            return true
        }
        return false
    }

    func addLink() {
        let key = linkDraftKey.trimmingCharacters(in: .whitespaces).lowercased()
        var value = linkDraftValue.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return }
        if !value.contains("://") { value = "https://\(value)" }
        draft?.links[key] = value
        linkDraftKey = ""
        linkDraftValue = ""
    }

    // MARK: Memory

    var memory: [MemoryAnswerItem] {
        let q = memoryFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.library.memoryAnswers }
        return store.library.memoryAnswers.filter { $0.canonicalQuestion.lowercased().contains(q) || $0.answer.lowercased().contains(q) }
    }

    func beginEditingMemory(_ item: MemoryAnswerItem) {
        editingMemoryID = item.id
        memoryDraft = item.answer
        confirmingDeleteMemoryID = nil
    }

    func saveMemory(_ item: MemoryAnswerItem) async {
        let text = memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingMemoryID = nil
        guard !text.isEmpty, text != item.answer else { return }
        let result = await store.perform(.updateAnswer(UpdateAnswerPayload(answerId: item.id, answer: text)))
        if case .success = result {
            store.toasts.show("Memory updated", symbol: "brain", style: .success)
        }
    }

    func deleteMemory(_ item: MemoryAnswerItem) async {
        confirmingDeleteMemoryID = nil
        let result = await store.perform(.deleteAnswer(DeleteAnswerPayload(answerId: item.id)))
        if case .success = result {
            store.toasts.show("Removed from memory", symbol: "trash", style: .info)
        }
    }
}

// MARK: - Story bank

/// Editable STAR story.
struct StoryDraftValue: Equatable, Sendable {
    var id: Int?
    var title = ""
    var situation = ""
    var task = ""
    var action = ""
    var result = ""
    var tags: [String] = []

    init() {}

    init(_ story: StoryItem) {
        id = story.id
        title = story.title
        situation = story.situation
        task = story.task
        action = story.action
        result = story.result
        tags = story.tags
    }

    var payload: UpsertStoryPayload {
        UpsertStoryPayload(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                           situation: situation.trimmingCharacters(in: .whitespacesAndNewlines),
                           task: task.trimmingCharacters(in: .whitespacesAndNewlines),
                           action: action.trimmingCharacters(in: .whitespacesAndNewlines),
                           result: result.trimmingCharacters(in: .whitespacesAndNewlines),
                           tags: tags)
    }

    var isValid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum StoryImporter {
    /// Split pasted text into STAR parts. Recognizes "Situation:", "Task:", "Action:", "Result:"
    /// (also "S:", "T:", "A:", "R:" and markdown headings); otherwise paragraphs map in order.
    /// The first line becomes the title when it isn't a STAR label.
    static func parse(_ text: String) -> StoryDraftValue {
        var draft = StoryDraftValue()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var current: WritableKeyPath<StoryDraftValue, String>?
        var sawLabel = false
        var leftovers: [String] = []

        func label(_ line: String) -> (WritableKeyPath<StoryDraftValue, String>, String)? {
            let stripped = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*- ")).trimmingCharacters(in: .whitespaces)
            let lower = stripped.lowercased()
            let map: [(String, WritableKeyPath<StoryDraftValue, String>)] = [
                ("situation", \.situation), ("task", \.task), ("action", \.action), ("actions", \.action), ("result", \.result), ("results", \.result),
                ("s", \.situation), ("t", \.task), ("a", \.action), ("r", \.result),
            ]
            for (name, key) in map {
                if lower == name { return (key, "") }
                for sep in [":", " -", " –", "."] where lower.hasPrefix(name + sep) {
                    let rest = stripped.dropFirst(name.count + sep.count).trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t"))
                    return (key, rest)
                }
            }
            return nil
        }

        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let (key, rest) = label(line) {
                sawLabel = true
                current = key
                if !rest.isEmpty { append(&draft[keyPath: key], rest) }
                continue
            }
            if line.isEmpty { continue }
            if let current {
                append(&draft[keyPath: current], line)
            } else if i == lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) && draft.title.isEmpty {
                draft.title = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*- ")).trimmingCharacters(in: .whitespaces)
            } else {
                leftovers.append(line)
            }
        }
        if !sawLabel {
            // No labels: paragraphs fill S, T, A, R in order; extras go to Action.
            let paras = paragraphs(text)
            draft = StoryDraftValue()
            // A short first paragraph without a full stop reads as a title.
            let titled = paras.count > 1 && paras[0].count <= 80 && !paras[0].hasSuffix(".")
            if titled { draft.title = paras[0].trimmingCharacters(in: CharacterSet(charactersIn: "#*- ")) }
            let body = titled ? Array(paras.dropFirst()) : paras
            let keys: [WritableKeyPath<StoryDraftValue, String>] = [\.situation, \.task, \.action, \.result]
            for (i, p) in body.enumerated() {
                let key = i < keys.count ? keys[i] : \StoryDraftValue.action
                append(&draft[keyPath: key], p)
            }
        } else if !leftovers.isEmpty {
            append(&draft.situation, leftovers.joined(separator: " "))
        }
        if draft.title.isEmpty {
            draft.title = String((draft.situation.isEmpty ? "Imported story" : draft.situation).prefix(60))
        }
        return draft
    }

    private static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    private static func append(_ target: inout String, _ text: String) {
        target = target.isEmpty ? text : target + " " + text
    }
}

@MainActor
@Observable
final class StoryBankModel {
    let store: AppStore
    var selectedStoryID: Int?
    /// The story being edited (a new story has `id == nil`).
    var draft: StoryDraftValue?
    private(set) var isSaving = false
    var confirmingDelete = false
    var importText = ""
    var isImporting = false

    static func shared(for store: AppStore) -> StoryBankModel {
        FeatureModels.model(StoryBankModel.self, for: store) { StoryBankModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

    var stories: [StoryItem] { store.library.stories }

    var selectedStory: StoryItem? { selectedStoryID.flatMap { id in stories.first { $0.id == id } } }

    var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        guard let id = draft.id, let story = stories.first(where: { $0.id == id }) else { return draft.isValid }
        return draft != StoryDraftValue(story)
    }

    func select(_ id: Int?) {
        selectedStoryID = id
        confirmingDelete = false
        draft = id.flatMap { id in stories.first { $0.id == id } }.map(StoryDraftValue.init)
    }

    func ensureSelection() {
        if draft == nil || (draft?.id != nil && selectedStory == nil) { select(stories.first?.id) }
    }

    func newStory() {
        selectedStoryID = nil
        confirmingDelete = false
        draft = StoryDraftValue()
    }

    func applyImport() {
        guard !importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectedStoryID = nil
        draft = StoryImporter.parse(importText)
        importText = ""
        isImporting = false
    }

    @discardableResult
    func save() async -> Bool {
        guard let draft, draft.isValid else {
            store.toasts.error("Give the story a title first.")
            return false
        }
        isSaving = true
        defer { isSaving = false }
        if let id = await store.upsertStory(draft.payload) {
            selectedStoryID = id
            self.draft?.id = id
            store.toasts.show("Story saved", symbol: "text.book.closed", style: .success)
            return true
        }
        return false
    }

    func delete() async {
        guard let id = draft?.id else { draft = nil; return }
        confirmingDelete = false
        let next = stories.first { $0.id != id }?.id
        let result = await store.perform(.deleteStory(DeleteStoryPayload(id: id)))
        if case .success = result {
            store.toasts.show("Story deleted", symbol: "trash", style: .info)
            select(next)
        }
    }

    /// "used in 7 applications"
    func usageLine(_ story: StoryItem) -> String {
        story.uses == 0 ? "not used yet" : "used in \(C3Format.plural(story.uses, "application"))"
    }
}

extension String {
    var c3NilIfEmpty: String? { isEmpty ? nil : self }
}
