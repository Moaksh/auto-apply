// WritingVoiceSection.swift — Settings ▸ Outreach ▸ Writing voice (contract §5.1.2): sign-off,
// formality, a word limit, phrases to avoid and an optional writing sample. It shapes the style
// of cover letters, cold emails, LinkedIn notes and long answers; it never adds facts, and the
// sample is never used as a source of facts. Loads with `get_voice_profile`; edits auto-save
// (debounced) through `update_voice_profile`, and an invalid field holds the save ("Not saved").
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class VoiceProfileModel {
    enum Field: Hashable, Sendable { case signOff, maxWords, avoidPhrases, writingSample }

    enum Phase: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    static let signOffLimit = 40
    static let wordRange = 60...600
    static let phraseLimit = 20
    static let phraseLength = 80
    static let sampleLimit = 1500

    let store: AppStore
    /// Bind controls to this; changes auto-save after `debounce` when valid.
    var draft = VoiceProfile() { didSet { if draft != oldValue { changed() } } }
    /// What the agent last confirmed.
    private(set) var baseline: VoiceProfile?
    private(set) var phase: Phase = .idle
    private(set) var save: SettingsModel.SaveState = .idle
    private(set) var issues: [Field: String] = [:]

    @ObservationIgnored var debounce: Duration = .milliseconds(800)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var applyingRemote = false

    static func shared(for store: AppStore) -> VoiceProfileModel {
        FeatureModels.model(VoiceProfileModel.self, for: store) { VoiceProfileModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

    var hasUnsavedChanges: Bool { baseline.map { $0 != draft } ?? false }

    /// The same limits the agent enforces, said in plain words.
    static func validate(_ p: VoiceProfile) -> [Field: String] {
        var out: [Field: String] = [:]
        if p.signOff.trimmingCharacters(in: .whitespaces).count > signOffLimit {
            out[.signOff] = "Keep the sign-off under \(signOffLimit) characters."
        }
        if !wordRange.contains(p.maxWords) {
            out[.maxWords] = "Pick a limit between \(wordRange.lowerBound) and \(wordRange.upperBound) words."
        }
        let phrases = p.avoidPhrases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if phrases.count > phraseLimit {
            out[.avoidPhrases] = "Up to \(phraseLimit) phrases."
        } else if phrases.contains(where: { $0.count > phraseLength }) {
            out[.avoidPhrases] = "Each phrase can be up to \(phraseLength) characters."
        }
        if (p.writingSample ?? "").count > sampleLimit {
            out[.writingSample] = "Keep the sample under \(sampleLimit.formatted()) characters."
        }
        return out
    }

    /// Every field, so the agent stores exactly what is on screen. An empty sign-off or sample
    /// is sent as "" (the agent resets it to the default / no sample).
    static func payload(_ p: VoiceProfile) -> UpdateVoiceProfilePayload {
        UpdateVoiceProfilePayload(
            signOff: p.signOff.trimmingCharacters(in: .whitespaces),
            formality: p.formality,
            maxWords: p.maxWords,
            avoidPhrases: p.avoidPhrases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            writingSample: (p.writingSample ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func load() async {
        guard phase != .loading else { return }
        if baseline == nil { phase = .loading }
        if let profile = await store.voiceProfile() {
            adopt(profile, force: true)
            phase = .loaded
        } else if baseline == nil {
            phase = .failed(store.lastOutreachErrorMessage)
        }
    }

    /// Send now (also what the debounce calls). Returns true when the agent confirmed.
    @discardableResult
    func saveNow() async -> Bool {
        saveTask?.cancel()
        issues = Self.validate(draft)
        if let first = issues.values.sorted().first {
            save = .failed("Not saved · \(first)")
            return false
        }
        guard hasUnsavedChanges else { return true }
        let sent = draft
        save = .saving
        if let profile = await store.updateVoiceProfile(Self.payload(sent)) {
            baseline = profile
            // Adopt the agent's normalized copy unless the user kept typing.
            if draft == sent { adopt(profile, force: true) }
            save = .saved
            return true
        }
        save = .failed("Not saved · \(store.lastOutreachErrorMessage)")
        return false
    }

    private func adopt(_ profile: VoiceProfile, force: Bool) {
        guard force || !hasUnsavedChanges else { return }
        baseline = profile
        applyingRemote = true
        draft = profile
        applyingRemote = false
    }

    private func changed() {
        guard !applyingRemote, baseline != nil else { return }
        issues = Self.validate(draft)
        saveTask?.cancel()
        guard issues.isEmpty else {
            save = .failed("Not saved · \(issues.values.sorted().first ?? "")")
            return
        }
        let delay = debounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }
}

extension Formality {
    var label: String {
        switch self {
        case .casual: "Casual"
        case .neutral: "Neutral"
        case .formal: "Formal"
        }
    }
}

/// The rows, inside Settings ▸ Outreach.
struct WritingVoiceSection: View {
    var model: VoiceProfileModel
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Space.l) {
            SettingsRow("Writing voice",
                        help: "Shapes the style of cover letters, cold emails, LinkedIn notes and long answers. Style only: it never adds facts, and your sample is never used as a source of facts.") {
                switch model.phase {
                case .idle, .loading:
                    Text("Loading…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                case .failed(let message):
                    ErrorState(title: "Couldn't load your writing voice · \(message)", compact: true, actionTitle: "Try again") {
                        Task { await model.load() }
                    }
                case .loaded:
                    EmptyView()
                }
            }
            if model.phase == .loaded {
                fields(model)
            }
        }
        .disabled(!store.isConnected)
        .task { await model.load() }
    }

    @ViewBuilder
    private func fields(_ model: VoiceProfileModel) -> some View {
        @Bindable var model = model
        SettingsRow("Sign-off", help: "Ends emails and cover letters, e.g. “Best regards” or “Thanks”.", issue: model.issues[.signOff]) {
            TextField("Best regards", text: $model.draft.signOff)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
        SettingsRow("Formality") {
            Picker("Formality", selection: $model.draft.formality) {
                ForEach(Formality.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
        }
        SettingsRow("Length", help: "The longest a generated letter or email should be.", issue: model.issues[.maxWords]) {
            Stepper("Up to \(model.draft.maxWords) words", value: $model.draft.maxWords, in: VoiceProfileModel.wordRange, step: 10)
                .monospacedDigit()
        }
        SettingsRow("Phrases to avoid", help: "Never used in what's written for you, e.g. “I hope this finds you well”. Up to 20.",
                    issue: model.issues[.avoidPhrases]) {
            ChipField(values: $model.draft.avoidPhrases, placeholder: "Add a phrase")
                .frame(maxWidth: 420)
        }
        SettingsRow("Writing sample",
                    help: "Optional. A few paragraphs you wrote yourself, so drafts sound like you. Kept on this Mac; sent to Claude only as a style example.",
                    issue: model.issues[.writingSample]) {
            TextEditor(text: Binding(get: { model.draft.writingSample ?? "" },
                                     set: { model.draft.writingSample = $0.isEmpty ? nil : $0 }))
                .font(Typography.body)
                .frame(minHeight: 80, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(Space.xs)
                .well()
                .frame(maxWidth: 420)
                .accessibilityLabel("Writing sample")
            Text("\((model.draft.writingSample ?? "").count) / \(VoiceProfileModel.sampleLimit.formatted())")
                .font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
        }
        SettingsRow("") {
            SaveStatusLine(state: model.save)
        }
    }
}
