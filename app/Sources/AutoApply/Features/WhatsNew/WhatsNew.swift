// WhatsNew.swift — the "what's new" popover a release can ship with. It points at the sidebar
// row where the new feature lives, shows once per version after an update (never on a fresh
// install: onboarding covers that), and Help ▸ What's New in AutoApply opens it again. "Try it"
// goes to the screen; "Later" just closes it.
import Foundation
import Observation
import SwiftUI

/// One release's highlights. Add a new `current` for a release that ships one; a release without
/// a popover leaves the previous one in place (it was already seen).
struct WhatsNewRelease: Sendable {
    struct Item: Sendable, Hashable {
        var symbol: String
        var title: String
        var detail: String
    }

    var version: String
    var title: String
    var subtitle: String
    /// The sidebar row the popover points at, and where "Try it" goes.
    var anchor: SidebarItem
    var items: [Item]

    static let current = WhatsNewRelease(
        version: "0.1.6",
        title: "Edit your resume with Claude",
        subtitle: "Attach the .docx, .tex or .html your resume PDF was made from, and Claude edits it with you.",
        anchor: .resumes,
        items: [
            Item(symbol: "doc.richtext", title: "A live PDF beside the editor",
                 detail: "Change a line yourself or ask Claude. The PDF updates a moment later, with Claude's suggestions in it before you accept them."),
            Item(symbol: "checkmark.shield", title: "Only what's true",
                 detail: "Every change is checked against your profile, stories and resume. Anything Claude can't back is flagged, and the job post never counts as proof."),
            Item(symbol: "scope", title: "Tailored for each job",
                 detail: "Before applying, I reword a copy of your resume for the job. Your PDF stays as it is, and you can turn this off per resume."),
            Item(symbol: "checkmark.circle", title: "\u{201C}Looks right\u{201D} in Review",
                 detail: "Clear a \u{201C}Check this\u{201D} flag without retyping the answer."),
        ])
}

@MainActor
@Observable
final class WhatsNewCenter {
    static let shared = WhatsNewCenter()
    static let seenKey = "whatsNew.lastSeenVersion"

    var isPresented = false
    let release = WhatsNewRelease.current
    @ObservationIgnored var defaults: UserDefaults = .standard

    var lastSeen: String? { defaults.string(forKey: Self.seenKey) }

    /// After the first snapshot: show once for this release when updating from an older version.
    /// A fresh install (still onboarding, or nothing seen yet) just records it as seen.
    func appear(needsOnboarding: Bool) {
        guard let seen = lastSeen else {
            markSeen()
            return
        }
        guard !needsOnboarding, Updater.isNewer(release.version, than: seen) else { return }
        isPresented = true
    }

    func show() { isPresented = true }

    func dismiss() {
        isPresented = false
        markSeen()
    }

    func markSeen() { defaults.set(release.version, forKey: Self.seenKey) }
}

struct WhatsNewPopover: View {
    var center: WhatsNewCenter
    var onTry: () -> Void

    var body: some View {
        let release = center.release
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("New in \(release.version)").eyebrowStyle()
                Text(release.title).font(Typography.title2)
                Text(release.subtitle)
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.m) {
                ForEach(release.items, id: \.self) { item in
                    HStack(alignment: .top, spacing: Space.s) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(Typography.bodyEmph)
                            Text(item.detail)
                                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack {
                Spacer()
                Button("Later") { center.dismiss() }.buttonStyle(.secondaryLink)
                Button("Try it") {
                    center.dismiss()
                    onTry()
                }
                .buttonStyle(.primaryPill)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.l)
        .frame(width: 380)
    }
}
