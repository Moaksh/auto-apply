// ReferralsTab.swift — Cold Email ▸ People ▸ Could refer you: the LinkedIn referral copilot (plan
// §F.1) as a three-step checklist per person — 1 connect, 2 ask for a referral, 3 hear back.
// AutoApply never opens or drives LinkedIn: "Copy note & open profile" puts the note on your
// clipboard and opens the profile in your own browser; you send it yourself, then say whether
// you did. The People toolbar holds Add referral (the one primary) and Suggest referrers.
import SwiftUI

struct ReferralsList: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    /// Companies you applied to (or are about to), newest first: where to suggest referrers.
    static func companies(_ store: AppStore) -> [(id: Int, name: String, jobID: Int?)] {
        var seen = Set<Int>()
        return store.jobs.all.filter { $0.state == .submitted || $0.state == .queued || $0.state == .awaitingReview }
            .sorted { ($0.submittedAt ?? $0.discoveredAt) > ($1.submittedAt ?? $1.discoveredAt) }
            .compactMap { j in seen.insert(j.companyID).inserted ? (j.companyID, j.company, j.id) : nil }
            .prefix(30).map { $0 }
    }

    var body: some View {
        let all = store.outreach.data.referrals.filter { $0.state != .dismissed }
        let open = all.filter(\.state.isOpen)
            .sorted { ($0.state.checklistStep, $0.stateUpdatedAt) > ($1.state.checklistStep, $1.stateUpdatedAt) }
        let settled = all.filter { !$0.state.isOpen }.sorted { $0.stateUpdatedAt > $1.stateUpdatedAt }
        if all.isEmpty {
            EmptyState(symbol: "person.2.wave.2", title: "No one who could refer you yet",
                       message: "Suggest referrers finds alumni and ex-colleagues at a company from Google results, or mark someone you know as “could refer me”. You send every LinkedIn message yourself.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.m) {
                    Label("You send every LinkedIn message yourself; AutoApply only copies the text and opens the profile in your browser. About 5 invitations a day is plenty. \(C3Format.plural(model.requestsThisWeek, "request")) marked sent this week.",
                          systemImage: "hand.raised")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Space.xs)
                    if !open.isEmpty {
                        Text("In progress").eyebrowStyle().accessibilityAddTraits(.isHeader)
                        ForEach(open) { ReferralCard(referral: $0, model: model).motionTransition(.row) }
                    }
                    if !settled.isEmpty {
                        Text("Done").eyebrowStyle().padding(.top, Space.m).accessibilityAddTraits(.isHeader)
                        ForEach(settled) { ReferralCard(referral: $0, model: model).motionTransition(.row) }
                    }
                }
                // A referral moving to Done travels down with `move`.
                .motion(Motion.move, value: open.map(\.id) + [-1] + settled.map(\.id))
                .padding(.horizontal, Space.contentPadding)
                .padding(.vertical, Space.l)
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }
}

/// One person: who they are and why, then the three steps with the one thing to do now.
struct ReferralCard: View {
    var referral: ReferralItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var drafting = false
    @State private var showTexts = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                PersonInitials(name: referral.personName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text(referral.personName).font(Typography.bodyEmph).lineLimit(1)
                        Text("· \([referral.title, "at \(referral.company)"].compactMap { $0 }.joined(separator: " "))")
                            .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: Space.xs) {
                        Badge(referral.basisLabel, symbol: "link")
                        if let job = referral.jobTitle { Text("For \(job)").font(Typography.callout).foregroundStyle(Palette.textTertiary).lineLimit(1) }
                        if !referral.grounded { Badge("Check the note", symbol: "exclamationmark.triangle", tone: .warning) }
                    }
                }
                Spacer(minLength: Space.s)
                if drafting { ProgressView().controlSize(.small) }
                moreMenu
            }
            if referral.state.isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    step(1, title: "Connect on LinkedIn")
                    step(2, title: "Ask for a referral")
                    step(3, title: "Hear back")
                }
                .padding(.vertical, Space.xs)
                .padding(.horizontal, Space.m)
                .well()
            } else {
                Label(referral.state == .referred ? "\(OutboxFormat.firstName(referral.personName)) referred you" : "\(OutboxFormat.firstName(referral.personName)) declined",
                      systemImage: referral.state == .referred ? "checkmark.circle.fill" : "minus.circle")
                    .font(Typography.callout)
                    .foregroundStyle(referral.state == .referred ? Palette.accent : Palette.textSecondary)
            }
            if let check = model.sentCheck, check.referralID == referral.id {
                sentPrompt(check)
            }
            if showTexts { texts }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(referral.personName) at \(referral.company), step \(min(referral.state.checklistStep, 3)) of 3: \(referral.state.label)")
    }

    // MARK: Steps

    private enum StepState { case done, current, later }

    private func stepState(_ n: Int) -> StepState {
        let at = referral.state.checklistStep
        return n < at ? .done : (n == at ? .current : .later)
    }

    private func step(_ n: Int, title: String) -> some View {
        let state = stepState(n)
        return HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(Palette.accent)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.onAccent)
                case .current:
                    Circle().strokeBorder(Palette.accent, lineWidth: 1.5)
                    Text("\(n)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.accent)
                case .later:
                    Circle().strokeBorder(Palette.strokeStrong, lineWidth: 1)
                    Text("\(n)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Palette.textTertiary)
                }
            }
            .frame(width: 18, height: 18)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(state == .current ? Typography.bodyEmph : Typography.body)
                    .foregroundStyle(state == .later ? Palette.textTertiary : (state == .done ? Palette.textSecondary : Palette.textPrimary))
                if state == .current, let detail = detail(n) {
                    Text(detail).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s)
            if state == .current { stepActions(n) }
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(n), \(title), \(state == .done ? "done" : state == .current ? "now" : "later")")
    }

    private func detail(_ n: Int) -> String? {
        switch n {
        case 1:
            switch referral.state {
            case .requested: "Request sent \(C3Format.relative(referral.stateUpdatedAt)). Waiting for them to accept; LinkedIn's email tells the agent when they do."
            case .noResponse: "No answer yet. You can try once more, or ask someone else."
            default: referral.connectNote.c3Trimmed == nil
                ? "Draft a short note, or just connect: sending without a note is fine."
                : "The note is ready (\(referral.connectNote?.count ?? 0)/300). Sending without a note is fine too."
            }
        case 2: referral.referralDM.c3Trimmed == nil ? "You're connected. Draft a short message with the job link." : "You're connected. The message is ready."
        case 3: "You asked \(C3Format.relative(referral.stateUpdatedAt)). Mark how it went."
        default: nil
        }
    }

    @ViewBuilder
    private func stepActions(_ n: Int) -> some View {
        HStack(spacing: Space.m) {
            switch n {
            case 1 where referral.state == .requested:
                Button("They accepted") { Task { await store.updateReferral(id: referral.id, state: .connected) } }
                    .buttonStyle(.secondaryLink)
                    .disabled(!store.isConnected)
            case 1:
                if referral.connectNote.c3Trimmed != nil {
                    Button("Copy note & open profile") { model.copyNoteAndOpenProfile(referral) }
                        .buttonStyle(.secondaryLink)
                        .help("Copies the note and opens their profile in your browser. You send the invitation yourself.")
                } else {
                    Button("Draft note") { draft() }.buttonStyle(.secondaryLink).disabled(drafting || !store.isConnected)
                    Button("Open profile") { model.copyNoteAndOpenProfile(referral) }
                        .buttonStyle(.secondaryLink)
                        .help("Opens their profile in your browser. You send the invitation yourself.")
                }
            case 2:
                if referral.referralDM.c3Trimmed != nil {
                    Button("Copy message & open") { model.copyMessageAndOpen(referral) }
                        .buttonStyle(.secondaryLink)
                        .help("Copies the referral request and opens their profile in your browser. You send it yourself.")
                } else {
                    Button("Draft message") { draft() }.buttonStyle(.secondaryLink).disabled(drafting || !store.isConnected)
                }
            case 3:
                Button("They referred me") { Task { await store.updateReferral(id: referral.id, state: .referred) } }
                    .buttonStyle(.secondaryLink)
                    .disabled(!store.isConnected)
                Button("They declined") { Task { await store.updateReferral(id: referral.id, state: .declined) } }
                    .buttonStyle(.secondaryLink)
                    .disabled(!store.isConnected)
            default:
                EmptyView()
            }
        }
        .font(Typography.callout)
    }

    // MARK: More

    private var moreMenu: some View {
        Menu {
            if referral.connectNote.c3Trimmed != nil || referral.referralDM.c3Trimmed != nil || referral.evidenceSnippet.c3Trimmed != nil {
                Button(showTexts ? "Hide note and message" : "Show note and message") { showTexts.toggle() }
            }
            Button(referral.connectNote == nil && referral.referralDM == nil ? "Draft note and message" : "Draft again") { draft() }
                .disabled(drafting || !store.isConnected)
            Divider()
            ForEach(referral.state.nextStates, id: \.self) { next in
                Button(menuTitle(next)) { Task { await store.updateReferral(id: referral.id, state: next) } }
                    .disabled(!store.isConnected)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More for \(referral.personName). Status: \(referral.state.label)")
    }

    private func menuTitle(_ s: ReferralState) -> String {
        switch s {
        case .requested: "I sent a connection request"
        case .connected: "We're connected"
        case .asked: "I asked for a referral"
        case .referred: "They referred me"
        case .declined: "They declined"
        case .noResponse: "No response"
        case .dismissed: "Not this person"
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
        .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
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
            showTexts = true
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
