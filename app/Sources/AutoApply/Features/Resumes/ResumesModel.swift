// ResumesModel.swift — resume variants: the grid selection shared
// with the inspector, per-variant send/response stats, the jobs each variant was used for,
// adding PDFs, and tag / default / enabled edits. Files are read-only in-app.
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ResumesModel {
    let store: AppStore
    var selectedID: Int?
    private(set) var adding: [String] = []   // file names being added
    /// Tag editing buffer for the inspector (committed on change).
    @ObservationIgnored var tagCommitDebounce: Duration = .milliseconds(500)
    @ObservationIgnored private var tagTasks: [Int: Task<Void, Never>] = [:]
    /// Optimistic tag edits until the DB reflects them.
    private(set) var pendingTags: [Int: [String]] = [:]

    static func shared(for store: AppStore) -> ResumesModel {
        FeatureModels.model(ResumesModel.self, for: store) { ResumesModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

    var variants: [ResumeVariantItem] {
        store.library.resumeVariants.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.enabled != b.enabled { return a.enabled }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    var selected: ResumeVariantItem? { selectedID.flatMap { id in variants.first { $0.id == id } } }

    func tags(for variant: ResumeVariantItem) -> [String] { pendingTags[variant.id] ?? variant.tags }

    /// "64 sent · 22%" — applications submitted with this variant and their response rate.
    func stat(for variant: ResumeVariantItem) -> VariantStat {
        if let s = store.stats.byVariant.first(where: { $0.variantID == variant.id }) { return s }
        let used = jobs(usedBy: variant).filter { $0.state == .submitted }
        let responses = used.filter { $0.status?.isResponse == true }.count
        let interviews = used.filter { $0.status == .interview || $0.status == .offer }.count
        return VariantStat(variantID: variant.id, label: variant.label, applications: used.count, responses: responses, interviews: interviews)
    }

    func statLine(for variant: ResumeVariantItem) -> String {
        let s = stat(for: variant)
        guard s.applications > 0 else { return "not sent yet" }
        return "\(s.applications) sent · \(C3Format.percent(s.responseRate))"
    }

    /// Jobs this variant was picked for, newest first.
    func jobs(usedBy variant: ResumeVariantItem) -> [JobItem] {
        store.jobs.all.filter { $0.resumeVariantID == variant.id }
            .sorted { ($0.submittedAt ?? $0.stateUpdatedAt ?? $0.discoveredAt) > ($1.submittedAt ?? $1.stateUpdatedAt ?? $1.discoveredAt) }
    }

    func ensureSelection() {
        if selected == nil { selectedID = variants.first?.id }
    }

    // MARK: Add

    /// Label from a file name: "Backend_Resume-2026.pdf" → "Backend Resume 2026".
    nonisolated static func label(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").joined(separator: " ")
    }

    func chooseAndAdd() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose approved resume PDFs. They're copied into AutoApply and never modified."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await add(urls) }
    }

    func add(_ urls: [URL]) async {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            let name = url.lastPathComponent
            adding.append(name)
            let id = await store.addResumeVariant(filePath: url.path, label: Self.label(for: url), tags: [], isDefault: store.library.resumeVariants.isEmpty)
            adding.removeAll { $0 == name }
            if let id {
                selectedID = id
                store.toasts.show("Added \(name)", symbol: "doc.badge.plus", style: .success)
            }
        }
    }

    // MARK: Edits

    func setTags(_ tags: [String], for variant: ResumeVariantItem) {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        pendingTags[variant.id] = cleaned
        tagTasks[variant.id]?.cancel()
        let delay = tagCommitDebounce
        let id = variant.id
        tagTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Success: keep showing the edit until the DB stream carries it (reconcilePending).
            // Failure: the store toasted; fall back to the DB value.
            let ok = await self.store.updateResumeVariant(UpdateResumeVariantPayload(id: id, tags: cleaned))
            guard !Task.isCancelled else { return }
            if ok { self.reconcilePending() } else { self.pendingTags.removeValue(forKey: id) }
        }
    }

    /// Drop optimistic tag edits the DB now reflects.
    func reconcilePending() {
        for (id, tags) in pendingTags where store.library.resume(id: id)?.tags == tags {
            pendingTags.removeValue(forKey: id)
        }
    }

    func rename(_ variant: ResumeVariantItem, to label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != variant.label else { return }
        await store.updateResumeVariant(UpdateResumeVariantPayload(id: variant.id, label: trimmed))
    }

    func makeDefault(_ variant: ResumeVariantItem) async {
        guard !variant.isDefault else { return }
        if await store.updateResumeVariant(UpdateResumeVariantPayload(id: variant.id, isDefault: true)) {
            store.toasts.show("\(variant.label) is now the default", symbol: "star.fill", style: .success)
        }
    }

    func setEnabled(_ enabled: Bool, _ variant: ResumeVariantItem) async {
        if !enabled && variant.isDefault {
            store.toasts.error("Pick another default before disabling this one.")
            return
        }
        await store.updateResumeVariant(UpdateResumeVariantPayload(id: variant.id, enabled: enabled))
    }
}
