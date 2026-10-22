// GhostDraftView.swift — inline drafts as ghost text (docs/DESIGN_AWARD_VISION.md 1D). When the
// agent has a draft (its stored one, or a "Draft with AI" result) and the editor is empty, the
// draft shows inside the editor in a tint, never as if the user had typed it. Under it, a dashed
// rule and a chip say where it came from. Tab takes it, typing replaces it, Esc clears it. A
// draft that isn't grounded in the user's facts says so in coral and needs a second Tab (or ⌥Tab,
// or "Use anyway") to take: the first Tab only shows what it couldn't back.
import SwiftUI

/// The ghost text itself, laid over the editor (it never takes clicks or focus).
struct GhostText: View {
    var ghost: GhostDraft
    var lineLimit: Int?

    var body: some View {
        Text(ghost.text)
            .font(Typography.body)
            .foregroundStyle(GhostDraftBar.tint(ghost).opacity(0.72))
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Under the editor while a ghost shows: the dashed rule, the provenance chip, Tab / Esc, and for
/// a draft that isn't grounded, what it couldn't back.
struct GhostDraftBar: View {
    var model: InboxModel
    var cluster: QuestionCluster
    var ghost: GhostDraft
    @Environment(AppStore.self) private var store

    static func tint(_ ghost: GhostDraft) -> Color { ghost.grounded ? Palette.accent : Palette.needsYou }

    private var confirming: Bool { model.aiDraft(for: cluster).confirmingUngrounded }
    /// ⌘K owns the keyboard while it's open (Tab and Esc go to it).
    private var paletteOpen: Bool { store.router.isPalettePresented }

    var body: some View {
        let confirming = self.confirming
        VStack(alignment: .leading, spacing: Space.xs) {
            Line()
                .stroke(Self.tint(ghost).opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
                .accessibilityHidden(true)
            HStack(spacing: Space.s) {
                Label(ghost.chip, systemImage: ghost.grounded ? "text.cursor" : "exclamationmark.triangle.fill")
                    .font(Typography.callout)
                    .foregroundStyle(ghost.grounded ? Palette.textSecondary : Palette.needsYou)
                    .lineLimit(1)
                Spacer(minLength: Space.s)
                Button {
                    model.acceptGhost(for: cluster)
                } label: {
                    HStack(spacing: Space.xs) {
                        Text(ghost.grounded || !confirming ? "Use draft" : "Use it anyway")
                        KeyCap("⇥")
                    }
                }
                .buttonStyle(.secondaryLink)
                .font(Typography.callout)
                .keyboardShortcut(paletteOpen ? nil : KeyboardShortcut(.tab, modifiers: []))
                .help(ghost.grounded ? "Put the draft in the answer box to edit or answer (Tab). Typing replaces it."
                                     : "This draft says things that aren't in your facts. Tab shows them; Tab again uses it anyway.")
                if !ghost.grounded && !confirming {
                    // ⌥Tab: take it in one deliberate step.
                    Button {
                        model.acceptGhost(for: cluster, force: true)
                    } label: {
                        HStack(spacing: Space.xs) {
                            Text("Use anyway")
                            KeyCap("⌥⇥")
                        }
                    }
                    .buttonStyle(.secondaryLink)
                    .font(Typography.callout)
                    .keyboardShortcut(paletteOpen ? nil : KeyboardShortcut(.tab, modifiers: .option))
                    .help("Use this draft even though parts aren't in your facts, then fix those parts")
                }
                Button {
                    model.dismissGhost(for: cluster)
                } label: {
                    HStack(spacing: Space.xs) {
                        Text("Clear")
                        KeyCap("esc")
                    }
                }
                .buttonStyle(.secondaryLink)
                .font(Typography.callout)
                .keyboardShortcut(paletteOpen ? nil : .cancelAction)
                .help("Hide the draft and start from an empty box (Esc)")
            }
            if !ghost.grounded && (confirming || !ghost.unsupportedClaims.isEmpty) {
                Label(Self.warning(ghost, confirming: confirming), systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.needsYou)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Draft available: \(ghost.text). \(ghost.chip).")
    }

    /// "Not in your facts: Google, 12. Press Tab again to use it anyway, then fix those parts."
    static func warning(_ ghost: GhostDraft, confirming: Bool) -> String {
        let claims = ghost.unsupportedClaims.isEmpty ? "Parts of this draft aren't in your profile, resume, stories or instructions."
            : "Not in your facts: \(ghost.unsupportedClaims.joined(separator: ", "))."
        return confirming ? claims + " Press Tab again to use it anyway, then fix those parts." : claims
    }
}

/// A horizontal line for the dashed rule.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
