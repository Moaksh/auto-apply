// AIDraftControls.swift — "Draft with AI" and conversational refinement under the answer editor
// (protocol.md §5.5). The agent writes from the user's profile, resume, stories, saved answers
// and the job; every result is fact-checked and anything it couldn't back is named. Over an
// empty editor the draft is ghost text (GhostDraftView.swift: Tab takes it); over the user's text
// it replaces it, with Undo. Nothing is answered until the user presses Answer. Typed answers only;
// never-guess facts, choices and agent tasks don't show it.
import SwiftUI

struct AIDraftControls: View {
    var model: InboxModel
    var cluster: QuestionCluster
    @Environment(\.motionReduced) private var reduced

    private var ai: AIDraftState { model.aiDraft(for: cluster) }
    private var text: String { model.draft(for: cluster).text }

    var body: some View {
        let ai = self.ai
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Button {
                    Task { await model.draftWithAI(for: cluster) }
                } label: {
                    Label("Draft with AI", systemImage: "pencil.line")
                }
                .buttonStyle(.secondaryLink)
                .disabled(ai.isDrafting)
                .help(text.isEmpty ? "Write a draft from your profile, resume and stories. It shows in the box as a draft: Tab uses it. "
                                     + "Nothing is answered until you press Answer."
                                   : "Replace the text above with a fresh draft (Undo brings yours back). Nothing is answered until you press Answer.")
                if ai.canUndo {
                    Button("Undo") { model.undoAIDraft(for: cluster) }
                        .buttonStyle(.secondaryLink)
                        .disabled(ai.isDrafting)
                        .help("Back to the text before the agent's last change")
                }
                Spacer(minLength: 0)
                status(ai)
            }
            TextField("Tell the agent what to change…", text: Binding(
                get: { model.aiDraft(for: cluster).instruction },
                set: { v in model.updateAIDraft(for: cluster) { $0.instruction = v } }))
                .textFieldStyle(.roundedBorder)
                .font(Typography.callout)
                .frame(maxWidth: 460)
                .disabled(ai.isDrafting)
                .onSubmit { Task { await model.reviseWithAI(for: cluster) } }
                .help("Press Return. The agent rewrites the text above as you ask (\"make it shorter\", \"mention my Kafka project\"). "
                      + "Facts you state here count as yours.")
                .accessibilityLabel("Tell the agent what to change")
            if !ai.history.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("You asked:").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    FlowLayout(spacing: Space.xs) {
                        ForEach(ai.history.suffix(4).reversed(), id: \.self) { past in
                            Button(past) { model.updateAIDraft(for: cluster) { $0.instruction = past } }
                                .buttonStyle(.secondaryLink)
                                .font(Typography.callout)
                                .lineLimit(1)
                                .help("Ask this again")
                        }
                    }
                }
            }
            outcome(ai)
        }
    }

    @ViewBuilder
    private func status(_ ai: AIDraftState) -> some View {
        if case .drafting(let revising) = ai.phase {
            HStack(spacing: Space.xs) {
                if reduced {
                    Image(systemName: "hourglass").foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(revising ? "Rewriting…" : "Writing from your profile, resume and stories…")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func outcome(_ ai: AIDraftState) -> some View {
        if let message = ai.errorMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(Typography.callout)
                .foregroundStyle(Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        } else if let result = ai.result, !ai.isDrafting, !ai.resultIsGhost {
            // A ghost that hasn't been taken says where it came from in its own chip.
            let claims = ai.unsupportedClaims(in: text)
            VStack(alignment: .leading, spacing: Space.xs) {
                if !claims.isEmpty {
                    Label("Unsupported: \(claims.joined(separator: ", ")). Not in your profile, resume, stories or instructions. "
                          + "Remove it, or tell the agent where it comes from.", systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.needsYou)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Written from your profile, resume and stories. Check it before answering.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                if !result.sources.isEmpty {
                    Text("Used: " + result.sources.joined(separator: " · "))
                        .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                        .help(result.sources.joined(separator: "\n"))
                }
            }
        }
    }
}
