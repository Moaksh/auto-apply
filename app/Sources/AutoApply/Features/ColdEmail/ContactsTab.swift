// ContactsTab.swift — Cold Email ▸ Contacts (plan §A.4, §B.5): everyone found or added, with the
// email's confidence tier, where it came from (provenance popover), and when you last wrote.
// Add contact is the tab's one primary action; Import LinkedIn connections, Import CSV, Suppress
// and Delete are secondary.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContactsTab: View {
    @Bindable var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                TextField("Search name, company, email", text: $model.contactSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                if importing { ProgressView().controlSize(.small) }
                Button("Import LinkedIn connections…") { model.beginLinkedInImport() }
                    .buttonStyle(.secondaryLink)
                    .disabled(!store.isConnected)
                    .help("From the Connections.csv you download from LinkedIn yourself. Stays on this Mac.")
                Button("Import CSV…") { importCSV() }
                    .buttonStyle(.secondaryLink)
                    .disabled(importing || !store.isConnected)
                    .help("Columns: name, email, company, title, linkedin_url, notes. Duplicates are merged by email.")
                Button("Add contact") { model.isAddContactPresented = true }
                    .buttonStyle(.primaryPill)
                    .disabled(!store.isConnected)
            }
            .padding(.horizontal, Space.contentPadding)
            .padding(.vertical, Space.m)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let contacts = model.filteredContacts
        if store.outreach.data.contacts.isEmpty {
            EmptyState(symbol: "person.2", title: "No contacts yet",
                       message: "People the agent finds after you apply show up here, with where each address came from. You can add people you know, too.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if contacts.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nobody matches “\(model.contactSearch)”.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxs, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(contacts) { ContactRow(contact: $0, model: model) }
                    } header: {
                        ContactColumns()
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.l)
            }
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CSV with columns name, email, company, title, linkedin_url, notes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task {
            _ = await store.importContacts(filePath: url.path)
            importing = false
        }
    }
}

/// Column widths shared by the header and rows.
private enum ContactColumn {
    static let name: CGFloat = 220
    static let company: CGFloat = 140
    static let email: CGFloat = 300
    static let origin: CGFloat = 130
    static let last: CGFloat = 110
}

private struct ContactColumns: View {
    var body: some View {
        HStack(spacing: Space.m) {
            Text("Name").frame(width: ContactColumn.name, alignment: .leading)
            Text("Company").frame(width: ContactColumn.company, alignment: .leading)
            Text("Email").frame(width: ContactColumn.email, alignment: .leading)
            Text("Origin").frame(width: ContactColumn.origin, alignment: .leading)
            Text("Last contacted").frame(width: ContactColumn.last, alignment: .leading)
            Spacer()
        }
        .eyebrowStyle()
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Palette.windowBackground)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ContactRow: View {
    var contact: ContactItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.fullName).font(Typography.bodyEmph).lineLimit(1)
                Text(contact.title ?? contact.roleCategory.label).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            .frame(width: ContactColumn.name, alignment: .leading)
            Text(contact.company ?? "—").font(Typography.callout).lineLimit(1).frame(width: ContactColumn.company, alignment: .leading)
            HStack(spacing: Space.xs) {
                Text(contact.email ?? "No email").font(Typography.mono).foregroundStyle(contact.hasEmail ? Palette.textPrimary : Palette.textTertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if contact.hasEmail { Badge(EmailTier(confidence: contact.emailConfidence).label, symbol: contact.tier.symbol, tone: tone) }
                ProvenanceButton(contact: contact)
            }
            .frame(width: ContactColumn.email, alignment: .leading)
            Text(contact.origin.label).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                .frame(width: ContactColumn.origin, alignment: .leading)
            Text(contact.lastContactedAt.map { C3Format.relative($0) } ?? "Never").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .frame(width: ContactColumn.last, alignment: .leading)
            Spacer(minLength: 0)
            menu
        }
        .selectableRow(isSelected: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(contact.fullName), \(contact.company ?? ""), \(contact.hasEmail ? contact.tier.label : "no email")")
        .confirmationDialog("Delete \(contact.fullName)?", isPresented: $confirmDelete) {
            Button("Delete and never email", role: .destructive) { Task { await store.deleteContact(id: contact.id, suppress: true) } }
            Button("Delete only") { Task { await store.deleteContact(id: contact.id, suppress: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their drafts are cancelled. “Never email” keeps the address on your do-not-contact list.")
        }
    }

    private var tone: Badge.Tone {
        switch contact.tier {
        case .verified: .status(.applied)
        case .likely: .accent
        case .guess: .warning
        case .unknown: .neutral
        }
    }

    private var menu: some View {
        Menu {
            if contact.hasEmail, let companyID = contact.companyID {
                let application = store.jobs.all.first { $0.companyID == companyID && $0.state == .submitted }
                Button(application != nil ? "Draft email about your application" : "Draft introduction") {
                    Task {
                        if let check = await store.draftOutreach(contactID: contact.id, kind: application != nil ? .application : .prospect,
                                                                 applicationID: application?.applicationID),
                           let tid = check.threadId {
                            model.open(threadID: tid)
                        }
                    }
                }
            }
            if contact.companyID != nil {
                Button("Could refer me") {
                    Task { _ = await store.addReferral(AddReferralPayload(companyId: contact.companyID, contactId: contact.id, basis: .user)) }
                }
            }
            if let email = contact.email {
                Divider()
                Button("Never email \(email)") { Task { await store.suppress(email: email) } }
            }
            Button("Delete…", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!store.isConnected)
        .accessibilityLabel("Actions for \(contact.fullName)")
    }
}

// MARK: - Add contact

/// Someone you know: a typed email is trusted (confidence 100). Sharing is off by default.
struct AddContactSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var company = ""
    @State private var title = ""
    @State private var linkedin = ""
    @State private var relationship: Relationship? = nil
    @State private var notes = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Add contact").font(Typography.title2)
            Form {
                TextField("Name", text: $name)
                TextField("Email", text: $email)
                TextField("Company", text: $company)
                TextField("Title", text: $title)
                TextField("LinkedIn profile (optional)", text: $linkedin)
                Picker("How you know them", selection: $relationship) {
                    Text("—").tag(Relationship?.none)
                    Text("Friend").tag(Relationship?.some(.friend))
                    Text("Ex-colleague").tag(Relationship?.some(.exColleague))
                    Text("Alumni").tag(Relationship?.some(.alumni))
                    Text("Met them").tag(Relationship?.some(.met))
                    Text("Other").tag(Relationship?.some(.other))
                }
                TextField("Notes", text: $notes)
            }
            .formStyle(.grouped)
            Text("Kept on this Mac. An address you type is treated as correct.")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            if let error { Text(error).font(Typography.callout).foregroundStyle(Palette.error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.secondaryLink).keyboardShortcut(.cancelAction)
                Button(saving ? "Adding…" : "Add contact") { save() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || (!email.isEmpty && !email.contains("@")))
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
    }

    private func save() {
        saving = true
        error = nil
        let companyID = store.jobs.all.first { $0.company.caseInsensitiveCompare(company.trimmingCharacters(in: .whitespaces)) == .orderedSame }?.companyID
        let payload = AddContactPayload(companyId: companyID, companyName: companyID == nil ? company.nonEmptyTrimmed : nil,
                                        fullName: name.trimmingCharacters(in: .whitespaces), email: email.nonEmptyTrimmed, title: title.nonEmptyTrimmed,
                                        linkedinUrl: linkedin.nonEmptyTrimmed, relationship: relationship, notes: notes.nonEmptyTrimmed, shareOk: false)
        Task {
            if await store.addContact(payload) != nil { dismiss() } else { error = store.lastOutreachErrorMessage }
            saving = false
        }
    }
}
