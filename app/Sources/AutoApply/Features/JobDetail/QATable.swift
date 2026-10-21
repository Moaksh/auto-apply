// QATable.swift — the Q&A audit (§5.4): every field with its answer, a provenance tag
// (profile / CV / memory / story / generated / you) whose popover reveals the source, a
// confidence dot, the lock on never-guess fields, copy-on-hover, and hover-linking to the
// screenshot region.
import AppKit
import SwiftUI

struct QATable: View {
    var answers: [ApplicationAnswerItem]
    var isLoaded: Bool
    var library: LibraryStore
    @Binding var highlighted: ApplicationAnswerItem?
    var onCopied: (String) -> Void = { _ in }

    var body: some View {
        if !isLoaded {
            SkeletonBlock(lines: 6).padding(Space.m)
        } else if answers.isEmpty {
            Text("No answers recorded for this application yet.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(answers.enumerated()), id: \.element.id) { index, answer in
                    QARow(answer: answer, library: library, isHighlighted: highlighted?.id == answer.id, onCopied: onCopied)
                        .onHover { inside in
                            if inside { highlighted = answer } else if highlighted?.id == answer.id { highlighted = nil }
                        }
                    if index < answers.count - 1 { Divider().overlay(Palette.hairline) }
                }
            }
            .surface(cornerRadius: Radius.inner)
        }
    }
}

private struct QARow: View {
    var answer: ApplicationAnswerItem
    var library: LibraryStore
    var isHighlighted: Bool
    var onCopied: (String) -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var showSource = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            HStack(spacing: Space.xs) {
                if answer.isLocked { Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(Palette.textSecondary) }
                Text(answer.question).font(Typography.body).lineLimit(2)
            }
            .frame(width: 220, alignment: .leading)

            Text(answer.answer.isEmpty ? "—" : answer.answer)
                .font(answer.isLocked ? Typography.bodyEmph : Typography.body)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, answer.isLocked ? Space.s : 0)
                .padding(.vertical, answer.isLocked ? 2 : 0)
                .background(answer.isLocked ? Palette.sunken : .clear, in: RoundedRectangle(cornerRadius: 4))

            Button { copy() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || copied ? 1 : 0)
            .help("Copy answer")
            .accessibilityLabel("Copy answer")

            HStack(spacing: Space.xs) {
                ConfidenceDot(level: answer.confidenceLevel)
                if let c = answer.confidence {
                    Text(confidenceWord(answer.confidenceLevel)).font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                        .help("Confidence \(c.formatted(.number.precision(.fractionLength(2))))")
                }
                Button { showSource = true } label: { Badge(origin: answer.origin, reference: referenceLabel) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSource, arrowEdge: .trailing) { sourcePopover }
                    .help("Show where this answer came from")
            }
            .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(rowTint)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(answer.question): \(answer.answer.isEmpty ? "no answer" : answer.answer)")
        .accessibilityValue("Source \(answer.origin.label)\(answer.isLocked ? ", a fact only you set" : ""), \(confidenceWord(answer.confidenceLevel)) confidence")
        .accessibilityAction(named: "Copy answer") { copy() }
        .accessibilityAction(named: "Show source") { showSource = true }
    }

    private var rowTint: Color {
        if copied { return Palette.applied.opacity(0.10) }
        if isHighlighted { return Palette.accent.opacity(0.08) }
        if answer.confidenceLevel == .low { return Palette.needsYou.opacity(0.08) }
        return .clear
    }

    /// "story #3", "resume Backend".
    private var referenceLabel: String? {
        guard let ref = answer.originRef else { return nil }
        let parts = ref.split(separator: ":")
        guard parts.count == 2, let id = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "stories": return "#\(id)"
        case "resume_variants": return library.resume(id: id)?.label
        default: return nil
        }
    }

    @ViewBuilder
    private var sourcePopover: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Badge(origin: answer.origin, reference: referenceLabel)
                Spacer()
                ConfidenceDot(level: answer.confidenceLevel)
            }
            Text(QASource.snippet(for: answer, library: library))
                .font(Typography.callout)
                .textSelection(.enabled)
                .frame(maxWidth: 320, alignment: .leading)
            if let key = answer.fieldKey {
                Text(key).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(Space.m)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer.answer, forType: .string)
        copied = true
        onCopied(answer.question)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func confidenceWord(_ level: ApplicationAnswerItem.ConfidenceLevel) -> String {
        switch level {
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        case .notApplicable: "n/a"
        }
    }
}

/// Source snippets for the provenance popover.
enum QASource {
    @MainActor
    static func snippet(for answer: ApplicationAnswerItem, library: LibraryStore) -> String {
        let ref = answer.originRef?.split(separator: ":")
        let id = ref.flatMap { $0.count == 2 ? Int($0[1]) : nil }
        switch answer.origin {
        case .story:
            if let id, let story = library.stories.first(where: { $0.id == id }) {
                return "Story “\(story.title)”: \(story.situation) \(story.action) \(story.result)"
            }
            return "From your story bank."
        case .memory:
            if let id, let memory = library.memoryAnswers.first(where: { $0.id == id }) {
                return "Saved answer to “\(memory.canonicalQuestion)” (used \(memory.uses)×)."
            }
            return "From your answer memory."
        case .cv:
            if let id, let resume = library.resume(id: id) { return "Extracted from \(resume.label) (\((resume.filePath as NSString).lastPathComponent))." }
            return "Extracted from your resume."
        case .profile: return "From your profile."
        case .neverGuess: return "A fact only you set. The agent never guesses it."
        case .generated: return "Drafted by the agent from your profile, stories and the job description. Check it before you rely on it."
        case .user: return "You answered this directly."
        }
    }
}
