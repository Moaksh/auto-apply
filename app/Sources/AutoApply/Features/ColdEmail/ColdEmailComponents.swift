// ColdEmailComponents.swift — small pieces shared by the Cold Email tabs, Needs You ▸ Replies and
// the job inspector: the email confidence badge, the follow-up status badge, the fact-check
// badge, unsupported-claim highlighting, the fixed footer preview, the provenance popover and
// the calm "sending is off" notice.
import SwiftUI

extension Badge {
    /// "Verified · 94" — the email confidence tier of a contact.
    init(contact: ContactItem) {
        let tier = contact.tier
        let tone: Tone = switch tier {
        case .verified: .status(.applied)
        case .likely: .accent
        case .guess: .warning
        case .unknown: .neutral
        }
        self.init(contact.hasEmail ? "\(tier.label) · \(contact.emailConfidence)" : "No email", symbol: tier.symbol, tone: tone,
                  accessibilityText: contact.hasEmail ? "Email \(tier.label.lowercased()), confidence \(contact.emailConfidence)" : "No email address")
    }

    /// Where an applied job stands on outreach.
    init(followUp status: FollowUpStatus) {
        let tone: Tone = switch status {
        case .replied: .status(.interview)
        case .draft: .accent
        case .emailed, .scheduled: .status(.applied)
        case .noContact, .closed: .neutral
        case .scouting, .contactsFound: .neutral
        }
        self.init(status.label, symbol: status.symbol, tone: tone)
    }

    /// The fact check's verdict on a draft.
    init(factCheck message: OutreachMessageItem) {
        if message.needsClaimsFix {
            let n = message.unsupportedClaims.count
            self.init(n == 1 ? "1 claim not found in your profile" : "\(max(n, 1)) claims not found in your profile",
                      symbol: "exclamationmark.triangle", tone: .warning)
        } else if message.claimsOverridden && !message.unsupportedClaims.isEmpty {
            self.init("You confirmed the claims", symbol: "checkmark.shield", tone: .accent)
        } else {
            self.init("Fact-checked", symbol: "checkmark.shield", tone: .status(.applied))
        }
    }
}

/// Highlights claims the fact check couldn't find in the user's profile and stories.
enum ClaimHighlighter {
    static func attributed(_ body: String, claims: [String]) -> AttributedString {
        var text = AttributedString(body)
        for claim in claims where !claim.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex, let range = text[searchStart...].range(of: claim, options: .caseInsensitive) {
                text[range].backgroundColor = Palette.needsYou.opacity(0.22)
                text[range].underlineStyle = .single
                searchStart = range.upperBound
            }
        }
        return text
    }

    /// Claims that no longer appear in the text (the user edited them away).
    static func remaining(_ body: String, claims: [String]) -> [String] {
        claims.filter { body.range(of: $0, options: .caseInsensitive) != nil }
    }
}

/// The footer every email carries. Stored apart from the body and never editable.
struct FooterPreview: View {
    var footer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(Palette.textSecondary)
                Text("Added to every email").eyebrowStyle()
            }
            Text(footer.c3Trimmed ?? "—\nI found your address on [where it was found]. If you'd rather not hear from me, reply \"no thanks\" and I won't email again.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("It says where the address came from and how to opt out. It can't be removed.")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
        .accessibilityElement(children: .combine)
    }
}

/// "Where did this address come from?" — the contact's evidence rows.
struct ProvenanceButton: View {
    var contact: ContactItem
    @Environment(AppStore.self) private var store
    @State private var shown = false
    @State private var rows: [ContactEvidenceItem]?

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.textSecondary)
            .help("Where this contact came from")
            .accessibilityLabel("Where \(contact.fullName)'s details came from")
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                ProvenanceList(contact: contact, rows: rows)
                    .task { rows = await store.repository.contactEvidence(contactID: contact.id) }
            }
    }
}

struct ProvenanceList: View {
    var contact: ContactItem
    var rows: [ContactEvidenceItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(contact.fullName).font(Typography.bodyEmph)
            HStack(spacing: Space.xs) {
                Badge(contact: contact)
                Badge(contact.origin.label)
            }
            Divider()
            if let rows {
                if rows.isEmpty {
                    Text("No sources recorded.").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.sentence).font(Typography.callout)
                        if let snippet = row.snippet.c3Trimmed {
                            Text("“\(snippet)”").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(3)
                        }
                        if let url = row.url.flatMap(URL.init(string:)) {
                            Link(row.url ?? "", destination: url).font(Typography.callout).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            } else {
                SkeletonBlock(lines: 2)
            }
        }
        .padding(Space.l)
        .frame(width: 320, alignment: .leading)
    }
}

/// The calm inline state while sending is off. Drafts still get written; nothing is sent.
struct SendingOffNotice: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        let account = store.outreach.mailAccount
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sending is off").font(Typography.bodyEmph)
                Text(account.isConnected
                     ? "Drafts are written for your review, but nothing goes out until you turn sending on. Turning it on sends one test email to \(account.email ?? "you") first."
                     : "Drafts are written for your review. To send from your own Gmail, connect your mailbox in Settings ▸ Sources, then turn sending on.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    // Wraps to the width it's given, but no `.fixedSize(vertical:)`: this notice sits
                    // above a ScrollView outside any scrolling container, and a fixed-height wrapped
                    // text reports a huge minimum height when the split view probes a near-zero
                    // width. That pushed the whole window's content off-screen (blank window).
                    .lineLimit(4)
            }
            Spacer(minLength: Space.s)
            if account.isConnected {
                Button("Enable sending…") {
                    model.resetEnableState()
                    model.isEnableSheetPresented = true
                }
                .buttonStyle(.secondaryLink)
            } else {
                Button("Open Settings") { SettingsNavigation.shared.open(.sources, router: store.router) }
                    .buttonStyle(.secondaryLink)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well(cornerRadius: Radius.card)
    }
}

/// Enable sending: a test email to yourself must go through before anything can be sent.
struct EnableSendingSheet: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let email = store.outreach.mailAccount.email
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Turn on sending").font(Typography.title2)
            Text("AutoApply sends emails from \(email ?? "your Gmail") only after you approve each batch. To check the connection, it first sends one test email to \(email ?? "you"). Sending turns on only if that goes through.")
                .font(Typography.body).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Label("Plain text, no tracking pixels, no link rewriting", systemImage: "eye.slash")
                Label("At most \(store.preferences.outreachDailyCap) new emails a day, spaced out, inside your send window", systemImage: "clock")
                Label("Replies land in your Gmail; you answer them there", systemImage: "tray")
            }
            .font(Typography.callout)
            .foregroundStyle(Palette.textSecondary)
            switch model.enableState {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Sending a test email…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
            case .enabled(let to):
                Label("Test email sent to \(to). Sending is on.", systemImage: "checkmark.circle.fill")
                    .font(Typography.callout).foregroundStyle(Palette.applied)
            case .failed(let message):
                Label(message, systemImage: StatusKind.error.symbol)
                    .font(Typography.callout).foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if case .enabled = model.enableState {
                    Button("Done") { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.buttonStyle(.secondaryLink).keyboardShortcut(.cancelAction)
                    Button("Send test email") { Task { await model.enableSending() } }
                        .buttonStyle(.primaryPill)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.enableState == .testing || email == nil)
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
    }
}

/// One fact: "Label    value".
struct ColdEmailFact: View {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(label).font(Typography.callout).foregroundStyle(Palette.textSecondary).frame(width: 96, alignment: .leading)
            Text(value).font(Typography.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension String {
    /// nil for a blank string, else the trimmed value.
    var nonEmptyTrimmed: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
