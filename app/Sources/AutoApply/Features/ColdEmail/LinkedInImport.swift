// LinkedInImport.swift — Cold Email ▸ People ▸ "Import LinkedIn connections…" (contract
// §5.1.1): the user downloads their own data from LinkedIn and picks Connections.csv. The file is
// read on this Mac, contacts are never shared, and LinkedIn is never opened. Connections at
// companies you applied to, watch or saved as prospects become referral suggestions; you send
// every request yourself. The sheet's one primary action is "Choose Connections.csv…" (then
// "Show referrals" / "Done").
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LinkedInImportState: Equatable, Sendable {
    case idle
    case importing
    case done(LinkedInImportResult)
    case failed(String)
}

extension ColdEmailModel {
    func beginLinkedInImport() {
        linkedInImport = .idle
        showPeople(.everyone)
        isLinkedInImportPresented = true
    }

    /// Import the picked export. On failure the sheet says why (bad file, not found, agent away).
    func importLinkedIn(filePath: String) async {
        linkedInImport = .importing
        if let result = await store.importLinkedInConnections(filePath: filePath) {
            linkedInImport = .done(result)
        } else {
            linkedInImport = .failed(store.lastOutreachErrorMessage)
        }
    }

    /// Close the sheet and show the referral suggestions it created.
    func showReferralsAfterImport() {
        isLinkedInImportPresented = false
        showPeople(.couldRefer)
    }

    /// "312 new contacts · 4 updated · 2 skipped"
    static func linkedInSummary(_ r: LinkedInImportResult) -> String {
        var parts = [C3Format.plural(r.imported, "new contact")]
        if r.merged > 0 { parts.append("\(r.merged) updated") }
        if r.skipped > 0 { parts.append("\(r.skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    /// "5 people could refer you at 3 companies" / nothing new.
    static func linkedInReferralLine(_ r: LinkedInImportResult) -> String {
        guard r.referralSuggestions > 0 else {
            return r.matchedCompanies.isEmpty
                ? "None of your connections work at a company you applied to, watch or saved as a prospect yet."
                : "No new referral suggestions; the people at these companies are already in Referrals."
        }
        return "\(C3Format.plural(r.referralSuggestions, "new referral suggestion")) at \(C3Format.plural(r.matchedCompanies.count, "company", "companies"))."
    }
}

struct LinkedInImportSheet: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Import LinkedIn connections").font(Typography.title2)
            switch model.linkedInImport {
            case .idle, .importing, .failed:
                instructions
            case .done(let result):
                resultView(result)
            }
            privacy
            HStack(spacing: Space.l) {
                Spacer()
                actions
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Download your own connections from LinkedIn, then choose the file here.")
                .font(Typography.body)
            VStack(alignment: .leading, spacing: Space.xs) {
                step(1, "On linkedin.com, open Settings ▸ Data privacy ▸ Get a copy of your data.")
                step(2, "Pick Connections, request the archive, and download it when LinkedIn emails you.")
                step(3, "Unzip it and choose Connections.csv.")
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .well()
            if case .failed(let message) = model.linkedInImport {
                ErrorState(title: message, compact: true)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("\(n)").font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
            Text(text).font(Typography.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultView(_ r: LinkedInImportResult) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label(ColdEmailModel.linkedInSummary(r), systemImage: "checkmark.circle.fill")
                .font(Typography.bodyEmph)
                .foregroundStyle(Palette.textPrimary)
            Text(ColdEmailModel.linkedInReferralLine(r))
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !r.matchedCompanies.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(r.matchedCompanies.prefix(8)) { c in
                        HStack(spacing: Space.s) {
                            Text(c.name).font(Typography.body).lineLimit(1)
                            if !c.why.isEmpty { Badge(c.why) }
                            Spacer()
                            Text(C3Format.plural(c.connections, "connection")).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        }
                        .padding(.vertical, Space.xs)
                    }
                    if r.matchedCompanies.count > 8 {
                        Text("and \(r.matchedCompanies.count - 8) more").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    }
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.xs)
                .well()
            }
        }
    }

    private var privacy: some View {
        Label("The file is read on this Mac. Your contacts stay here and are never shared, and AutoApply never opens LinkedIn. You send every message yourself.",
              systemImage: "lock")
            .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        switch model.linkedInImport {
        case .done(let r):
            if r.referralSuggestions > 0 {
                Button("Done") { dismiss() }.buttonStyle(.secondaryLink).keyboardShortcut(.cancelAction)
                Button("Show referrals") { model.showReferralsAfterImport() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
        case .idle, .importing, .failed:
            Button("Cancel") { dismiss() }.buttonStyle(.secondaryLink).keyboardShortcut(.cancelAction)
            if model.linkedInImport == .importing { ProgressView().controlSize(.small) }
            Button(model.linkedInImport == .importing ? "Importing…" : "Choose Connections.csv…") { choose() }
                .buttonStyle(.primaryPill)
                .keyboardShortcut(.defaultAction)
                .disabled(model.linkedInImport == .importing || !store.isConnected)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose Connections.csv from your LinkedIn data export"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importLinkedIn(filePath: url.path) }
    }
}
