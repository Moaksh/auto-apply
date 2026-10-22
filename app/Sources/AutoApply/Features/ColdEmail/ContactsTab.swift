// ContactsTab.swift — Cold Email ▸ People (plan §A.4, §B.5, §F.1; app/COLD_EMAIL_UX.md): one
// place for everyone found or added — with the email's confidence, where it came from
// (provenance popover) and when you last wrote — and a "Could refer you" filter that is the
// LinkedIn referral copilot (ReferralsTab.swift). Add contact (or Add referral on that filter) is
// the one primary action; Import LinkedIn connections / CSV, Never email and Delete are secondary.
// "Never email" puts the address on the do-not-contact list.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PeopleView: View {
    @Bindable var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, Space.contentPadding)
                .padding(.bottom, Space.m)
            Divider()
            switch model.peopleFilter {
            case .everyone: everyone
            case .couldRefer: ReferralsList(model: model)
            }
        }
    }

    private var toolbar: some View {
        let referrals = store.outreach.data.referrals.filter { $0.state != .dismissed }.count
        return HStack(spacing: Space.m) {
            Picker("Show", selection: $model.peopleFilter) {
                Text("Everyone \(store.outreach.data.contacts.count)").tag(PeopleFilter.everyone)
                Text("Could refer you \(referrals)").tag(PeopleFilter.couldRefer)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if model.peopleFilter == .everyone {
                TextField("Search name, company, email", text: $model.contactSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            Spacer(minLength: Space.s)
            if importing { ProgressView().controlSize(.small) }
            Menu("Import") {
                Button("LinkedIn connections…") { model.beginLinkedInImport() }
                    .help("From the Connections.csv you download from LinkedIn yourself. Stays on this Mac.")
                Button("CSV file…") { importCSV() }
                    .help("Columns: name, email, company, title, linkedin_url, notes. Duplicates are merged by email.")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(importing || !store.isConnected)
            if model.peopleFilter == .everyone {
                Button("Add contact") { model.isAddContactPresented = true }
                    .buttonStyle(.primaryPill)
                    .disabled(!store.isConnected)
            } else {
                Menu("Suggest referrers") {
                    ForEach(ReferralsList.companies(store), id: \.id) { c in
                        Button(c.name) { Task { await store.suggestReferrers(companyID: c.id, jobID: c.jobID) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(ReferralsList.companies(store).isEmpty || !store.isConnected)
                .help("Looks for alumni, ex-colleagues and people in your kind of role using Google results only")
                Button("Add referral") { model.isAddReferralPresented = true }
                    .buttonStyle(.primaryPill)
                    .disabled(!store.isConnected)
            }
        }
    }

    @ViewBuilder
    private var everyone: some View {
        let contacts = model.filteredContacts
        if store.outreach.data.contacts.isEmpty {
            EmptyState(symbol: "person.2", title: "No one here yet",
                       message: "People the agent finds after you apply show up here, with where each address came from. You can add people you know, or import your LinkedIn connections.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if contacts.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nobody matches “\(model.contactSearch)”.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(contacts) { ContactRow(contact: $0, model: model) }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
                .frame(maxWidth: 1100, alignment: .leading)
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

/// Initials on a quiet disc (people, not companies).
struct PersonInitials: View {
    var name: String
    var size: CGFloat = 28

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textSecondary)
            .frame(width: size, height: size)
            .background(Palette.sunken, in: Circle())
            .accessibilityHidden(true)
    }
}

private struct ContactRow: View {
    var contact: ContactItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: Space.m) {
            PersonInitials(name: contact.fullName)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(contact.fullName).font(Typography.bodyEmph).lineLimit(1)
                    Text("· \(contact.title ?? contact.roleCategory.label)").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                HStack(spacing: Space.xs) {
                    Text(contact.company ?? "No company").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    Text("·").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    Text(contact.email ?? "No email").font(Typography.mono).foregroundStyle(contact.hasEmail ? Palette.textSecondary : Palette.textTertiary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Space.s)
            if contact.hasEmail { Badge(contact: contact) }
            Text(contact.lastContactedAt.map { "Emailed \(C3Format.relative($0))" } ?? contact.origin.label)
                .font(Typography.callout).foregroundStyle(Palette.textTertiary).lineLimit(1)
                .frame(width: 140, alignment: .trailing)
            ProvenanceButton(contact: contact)
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
