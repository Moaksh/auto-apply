// ReferralsTab.swift — Cold Email ▸ Referrals: the LinkedIn referral copilot (plan §F.1). People
// who could refer you, grouped by where things stand. AutoApply never opens or drives LinkedIn:
// "Copy note & open profile" puts the note on your clipboard and opens the profile in your own
// browser; you send it yourself, then say whether you did. No primary action on this tab.
import SwiftUI

struct ReferralsTab: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    private var companies: [(id: Int, name: String, jobID: Int?)] {
        var seen = Set<Int>()
        return store.jobs.all.filter { $0.state == .submitted || $0.state == .queued || $0.state == .awaitingReview }
            .sorted { ($0.submittedAt ?? $0.discoveredAt) > ($1.submittedAt ?? $1.discoveredAt) }
            .compactMap { j in seen.insert(j.companyID).inserted ? (j.companyID, j.company, j.id) : nil }
            .prefix(30).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            let groups = store.outreach.referralGroups
            if groups.isEmpty {
                EmptyState(symbol: "person.2.wave.2", title: "No referrals yet",
                           message: "Find alumni and ex-colleagues at a company from Google results, or mark someone you know as “could refer me”. You send every LinkedIn message yourself.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(groups, id: \.state) { group in
                            HStack(spacing: Space.s) {
                                Text(group.state.label).eyebrowStyle()
                                Text("\(group.items.count)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.horizontal, Space.m)
                            .padding(.top, Space.l)
                            .padding(.bottom, Space.xxs)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { ReferralRow(referral: $0, model: model) }
                        }
                    }
                    .padding(.horizontal, Space.l)
                    .padding(.bottom, Space.l)
                    .frame(maxWidth: 1000, alignment: .leading)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text("LinkedIn limits invitations: about 5 a day is plenty, and sending without a note is fine. \(C3Format.plural(model.requestsThisWeek, "request")) marked sent this week.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Menu("Suggest referrers") {
                ForEach(companies, id: \.id) { c in
                    Button(c.name) { Task { await store.suggestReferrers(companyID: c.id, jobID: c.jobID) } }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(companies.isEmpty || !store.isConnected)
            .help("Looks for alumni, ex-colleagues and people in your kind of role using Google results only")
            Button("Add referral") { model.isAddReferralPresented = true }
                .buttonStyle(.secondaryLink)
                .disabled(!store.isConnected)
        }
        .padding(.horizontal, Space.contentPadding)
        .padding(.vertical, Space.m)
    }
}

private struct ReferralRow: View {
    var referral: ReferralItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var drafting = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text(referral.personName).font(Typography.bodyEmph)
                        Text("· \(referral.title ?? "") at \(referral.company)").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: Space.xs) {
                        Badge(referral.basisLabel, symbol: "link")
                        if let job = referral.jobTitle { Text("For \(job)").font(Typography.callout).foregroundStyle(Palette.textTertiary).lineLimit(1) }
                        if !referral.grounded { Badge("Check the note", symbol: "exclamationmark.triangle", tone: .warning) }
                    }
                }
                Spacer(minLength: Space.s)
                primaryActions
                stateMenu
            }
            if let check = model.sentCheck, check.referralID == referral.id {
                sentPrompt(check)
            }
            if expanded || referral.state == .connected || referral.state == .toConnect {
                texts
            }
        }
        .selectableRow(isSelected: false)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var primaryActions: some View {
        HStack(spacing: Space.m) {
            if drafting { ProgressView().controlSize(.small) }
            switch referral.state {
            case .suggested, .toConnect, .noResponse:
                if referral.connectNote.c3Trimmed != nil {
                    Button("Copy note & open profile") { model.copyNoteAndOpenProfile(referral) }
                        .buttonStyle(.secondaryLink)
                        .help("Copies the note and opens their profile in your browser. You send the invitation yourself.")
                } else {
                    Button("Draft note") { draft() }.buttonStyle(.secondaryLink).disabled(drafting || !store.isConnected)
                    Button("Open profile") { model.copyNoteAndOpenProfile(referral) }.buttonStyle(.secondaryLink)
                }
            case .connected, .asked:
                if referral.referralDM.c3Trimmed != nil {
                    Button("Copy message & open") { model.copyMessageAndOpen(referral) }
                        .buttonStyle(.secondaryLink)
                        .help("Copies the referral request and opens their profile in your browser. You send it yourself.")
                } else {
                    Button("Draft message") { draft() }.buttonStyle(.secondaryLink).disabled(drafting || !store.isConnected)
                }
            case .requested, .referred, .declined, .dismissed:
                EmptyView()
            }
            Button(expanded ? "Hide" : "Notes") { expanded.toggle() }
                .buttonStyle(.secondaryLink)
        }
    }

    private var stateMenu: some View {
        Menu {
            ForEach(referral.state.nextStates, id: \.self) { next in
                Button(menuTitle(next)) { Task { await store.updateReferral(id: referral.id, state: next) } }
            }
        } label: {
            Badge(referral.state.label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(referral.state.nextStates.isEmpty || !store.isConnected)
        .accessibilityLabel("Status: \(referral.state.label). Change status")
    }

    private func menuTitle(_ s: ReferralState) -> String {
        switch s {
        case .requested: "I sent a connection request"
        case .connected: "We're connected"
        case .asked: "I asked for a referral"
        case .referred: "They referred me"
        case .declined: "They declined"
        case .noResponse: "No response"
        case .dismissed: "Dismiss"
        case .toConnect: "To connect"
        case .suggested: "Back to suggested"
        }
    }

    private func sentPrompt(_ check: ColdEmailModel.SentCheck) -> some View {
        HStack(spacing: Space.m) {
            Text(check.kind == .note ? "Did you send the invitation?" : "Did you send the message?").font(Typography.bodyEmph)
            Spacer()
            Button(check.kind == .note ? "Yes, mark as sent" : "Yes, mark as asked") { Task { await model.confirmSent(true) } }
                .buttonStyle(.secondaryLink)
            Button("Not yet") { model.dismissSentCheck() }.buttonStyle(.secondaryLink)
        }
        .padding(Space.s)
        .well()
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let note = referral.connectNote.c3Trimmed {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Connection note · \(note.count)/300").eyebrowStyle()
                    Text(ClaimHighlighter.attributed(note, claims: referral.unsupportedClaims)).font(Typography.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let dm = referral.referralDM.c3Trimmed {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Referral message").eyebrowStyle()
                    Text(ClaimHighlighter.attributed(dm, claims: referral.unsupportedClaims)).font(Typography.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let snippet = referral.evidenceSnippet.c3Trimmed {
                Text("Found from: “\(snippet)”").font(Typography.callout).foregroundStyle(Palette.textTertiary).lineLimit(2)
            }
            HStack(spacing: Space.l) {
                Button(referral.connectNote == nil && referral.referralDM == nil ? "Draft note and message" : "Draft again") { draft() }
                    .buttonStyle(.secondaryLink)
                    .disabled(drafting || !store.isConnected)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }

    private func draft() {
        drafting = true
        Task {
            _ = await store.draftReferral(id: referral.id)
            drafting = false
            expanded = true
        }
    }
}

// MARK: - Add referral

/// "Could refer me": a person at a company (by name and profile link).
struct AddReferralSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var companyID: Int?
    @State private var name = ""
    @State private var title = ""
    @State private var linkedin = ""
    @State private var basis: ReferralBasis = .user
    @State private var detail = ""
    @State private var saving = false
    @State private var error: String?

    private var companies: [(id: Int, name: String)] {
        var seen = Set<Int>()
        return store.jobs.all.filter { $0.state == .submitted || $0.state == .queued }
            .compactMap { seen.insert($0.companyID).inserted ? ($0.companyID, $0.company) : nil }
            .sorted { $0.1 < $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Add referral").font(Typography.title2)
            Form {
                Picker("Company", selection: $companyID) {
                    Text("Choose…").tag(Int?.none)
                    ForEach(companies, id: \.id) { Text($0.name).tag(Int?.some($0.id)) }
                }
                TextField("Name", text: $name)
                TextField("Title (optional)", text: $title)
                TextField("LinkedIn profile link", text: $linkedin)
                Picker("Connection", selection: $basis) {
                    Text("I know them").tag(ReferralBasis.user)
                    Text("Alumni").tag(ReferralBasis.alumni)
                    Text("Ex-colleague").tag(ReferralBasis.exColleague)
                    Text("Same kind of role").tag(ReferralBasis.sameFunction)
                    Text("Other").tag(ReferralBasis.other)
                }
                TextField("School, company or team you share (optional)", text: $detail)
            }
            .formStyle(.grouped)
            if let error { Text(error).font(Typography.callout).foregroundStyle(Palette.error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.secondaryLink).keyboardShortcut(.cancelAction)
                Button(saving ? "Adding…" : "Add referral") { save() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || companyID == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
    }

    private func save() {
        saving = true
        error = nil
        let job = store.jobs.all.first { $0.companyID == companyID && $0.state == .submitted }
        let payload = AddReferralPayload(companyId: companyID, jobId: job?.id, personName: name.trimmingCharacters(in: .whitespaces),
                                         title: title.nonEmptyTrimmed, linkedinUrl: linkedin.nonEmptyTrimmed, basis: basis, basisDetail: detail.nonEmptyTrimmed)
        Task {
            if await store.addReferral(payload) != nil { dismiss() } else { error = store.lastOutreachErrorMessage }
            saving = false
        }
    }
}
