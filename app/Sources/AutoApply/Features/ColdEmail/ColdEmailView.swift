// ColdEmailView.swift — Cold Email (docs/COLD_EMAIL_PLAN.md §G.6): Follow-ups | Prospects |
// Contacts | Outbox | Referrals. After each application the agent can find people and draft a
// short note; every email waits in the Outbox until you approve it, and at most one gentle
// follow-up goes out, only if you approve that too. LinkedIn is never automated.
import SwiftUI

@objc(ColdEmailFeature)
final class ColdEmailFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.coldEmail) { ColdEmailView() }
    }
}

struct ColdEmailView: View {
    @Environment(AppStore.self) private var store
    /// Tests: render a given model (tab / phase) instead of the shared one.
    var modelOverride: ColdEmailModel?

    private var model: ColdEmailModel { modelOverride ?? ColdEmailModel.shared(for: store) }

    var body: some View {
        @Bindable var model = self.model
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader("Cold Email", summary: model.summary)
            Picker("Section", selection: $model.tab) {
                ForEach(ColdEmailTab.allCases) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .padding(.horizontal, Space.contentPadding)
            .padding(.bottom, Space.m)
            if model.phase == .ready, !store.outreach.sendEnabled, model.tab == .outbox || model.tab == .followUps {
                SendingOffNotice(model: model)
                    .padding(.horizontal, Space.contentPadding)
                    .padding(.bottom, Space.m)
            }
            Divider()
            Group {
                switch model.phase {
                case .loading:
                    LoadingState(message: "Loading your outreach…")
                case .error(let message):
                    ErrorState(title: "Can't show Cold Email", message: message)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    switch model.tab {
                    case .followUps: FollowUpsTab(model: model)
                    case .prospects: ProspectsTab(model: model)
                    case .contacts: ContactsTab(model: model)
                    case .outbox: OutboxTab(model: model)
                    case .referrals: ReferralsTab(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.windowBackground)
        .sheet(isPresented: $model.isSendSheetPresented) { SendConfirmSheet(model: model).environment(store) }
        .sheet(isPresented: $model.isEnableSheetPresented) { EnableSendingSheet(model: model).environment(store) }
        .sheet(isPresented: $model.isAddContactPresented) { AddContactSheet().environment(store) }
        .sheet(isPresented: $model.isAddReferralPresented) { AddReferralSheet().environment(store) }
    }
}

// MARK: - Follow-ups

/// Applied jobs with their outreach status, best contact and the next step.
struct FollowUpsTab: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    private var jobs: [JobItem] {
        store.jobs.all.filter { $0.state == .submitted && $0.applicationID != nil }
            .sorted { ($0.submittedAt ?? $0.discoveredAt) > ($1.submittedAt ?? $1.discoveredAt) }
    }

    var body: some View {
        let jobs = self.jobs
        if jobs.isEmpty {
            EmptyState(symbol: "envelope", title: "No applications yet",
                       message: "After you apply, the agent looks for a recruiter or the hiring manager and drafts a short note for your review.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxs) {
                    Text(explainer)
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.m)
                        .padding(.bottom, Space.s)
                    ForEach(jobs.prefix(400)) { job in
                        FollowUpRow(job: job, model: model)
                    }
                }
                .padding(Space.l)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
    }

    private var explainer: String {
        let p = store.preferences
        let auto = p.outreachAutoScout && p.outreachAutoDraft
            ? "After each application the agent finds people at the company and drafts a note for your review."
            : "Find people and draft a note for any application."
        let followUp = p.outreachMaxFollowups > 0
            ? " At most one gentle follow-up after \(p.outreachFollowupDays) business days, and only if you approve it."
            : ""
        return auto + " Nothing is sent without your approval." + followUp
    }
}

private struct FollowUpRow: View {
    var job: JobItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        let status = store.outreach.followUpStatus(for: job)
        let thread = store.outreach.primaryThread(applicationID: job.applicationID)
        let contact = store.outreach.contact(id: thread?.contactID) ?? store.outreach.bestContact(companyID: job.companyID)
        HStack(alignment: .center, spacing: Space.m) {
            CompanyMonogram(name: job.company, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.company).font(Typography.bodyEmph).lineLimit(1)
                Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            .frame(width: 220, alignment: .leading)
            Badge(followUp: status)
                .frame(width: 190, alignment: .leading)
            if let contact {
                HStack(spacing: Space.xs) {
                    Text(contact.nameAndTitle).font(Typography.callout).lineLimit(1)
                    Badge(contact: contact)
                }
            } else {
                Text(job.submittedAt.map { "Applied \(C3Format.relative($0))" } ?? "Applied")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: Space.s)
            actions(status: status, thread: thread, contact: contact)
        }
        .selectableRow(isSelected: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.company), \(job.title), \(status.label)")
    }

    @ViewBuilder
    private func actions(status: FollowUpStatus, thread: OutreachThreadItem?, contact: ContactItem?) -> some View {
        HStack(spacing: Space.m) {
            if busy { ProgressView().controlSize(.small) }
            switch status {
            case .noContact:
                Button("Find people") { run { _ = await store.scoutContacts(companyID: job.companyID, applicationID: job.applicationID) } }
                    .buttonStyle(.secondaryLink)
            case .scouting:
                EmptyView()
            case .contactsFound:
                if let contact, contact.hasEmail {
                    Button("Draft") {
                        run {
                            if let check = await store.draftOutreach(contactID: contact.id, kind: .application, applicationID: job.applicationID),
                               let tid = check.threadId {
                                model.open(threadID: tid)
                            }
                        }
                    }
                    .buttonStyle(.secondaryLink)
                    .help("Draft a short note to \(contact.fullName) for your review. Nothing is sent.")
                }
                Button("Find people") { run { _ = await store.scoutContacts(companyID: job.companyID, applicationID: job.applicationID) } }
                    .buttonStyle(.secondaryLink)
            case .draft, .scheduled, .emailed, .replied, .closed:
                if let thread {
                    Button("Open thread") { model.open(threadID: thread.id) }.buttonStyle(.secondaryLink)
                }
            }
        }
        .disabled(busy || !store.isConnected)
    }

    private func run(_ op: @escaping () async -> Void) {
        busy = true
        Task {
            await op()
            busy = false
        }
    }
}
