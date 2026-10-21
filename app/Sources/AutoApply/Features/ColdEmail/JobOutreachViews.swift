// JobOutreachViews.swift — outreach on one job, shared by the Pipeline inspector and Job detail:
// the conversation's status with a "Reach out" action, and an employer reply's suggested board
// move with Accept / Keep as is. All actions are text links (a job page's one primary action
// stays its state action).
import SwiftUI

/// "Outreach": who you emailed (or could), where it stands, and Reach out.
struct JobOutreachSection: View {
    var job: JobItem
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        let o = store.outreach
        let status = o.followUpStatus(for: job)
        let thread = o.primaryThread(applicationID: job.applicationID)
        let contact = o.contact(id: thread?.contactID) ?? o.bestContact(companyID: job.companyID)
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeader("Outreach")
            HStack(spacing: Space.s) {
                Badge(followUp: status)
                if busy { ProgressView().controlSize(.small) }
            }
            if let contact {
                HStack(spacing: Space.xs) {
                    Text(contact.nameAndTitle).font(Typography.callout).lineLimit(1)
                    Badge(contact: contact)
                }
            }
            if let thread, let sent = o.lastSent(threadID: thread.id)?.sentAt {
                Text("Last email \(C3Format.relative(sent))").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            if job.state == .submitted, job.applicationID != nil {
                Button(thread == nil ? "Reach out" : "Open in Cold Email") { reachOut(thread: thread, contact: contact) }
                    .buttonStyle(.secondaryLink)
                    .disabled(busy || (!store.isConnected && thread == nil))
                    .help(thread == nil ? "Find someone at \(job.company) and draft a short note for your review. Nothing is sent without your approval."
                          : "See the conversation in Cold Email")
            }
        }
    }

    private func reachOut(thread: OutreachThreadItem?, contact: ContactItem?) {
        let model = ColdEmailModel.shared(for: store)
        if let thread {
            store.router.go(.coldEmail)
            model.open(threadID: thread.id)
            return
        }
        busy = true
        Task {
            defer { busy = false }
            if let contact, contact.hasEmail {
                if let check = await store.draftOutreach(contactID: contact.id, kind: .application, applicationID: job.applicationID),
                   let tid = check.threadId {
                    store.router.go(.coldEmail)
                    model.open(threadID: tid)
                }
            } else {
                _ = await store.scoutContacts(companyID: job.companyID, applicationID: job.applicationID)
            }
        }
    }
}

/// An employer email about this application with a suggested board move.
struct ReplySuggestionCard: View {
    var reply: ApplicationReplyItem
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Image(systemName: "envelope.badge").foregroundStyle(Palette.needsYou)
                Text("\(reply.sender) wrote").font(Typography.bodyEmph).lineLimit(1)
                Badge(reply.label.label)
            }
            Text(reply.subject).font(Typography.callout).lineLimit(2)
            Text(reply.snippet).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let move = reply.suggestedStatus {
                Text("Suggests moving it to \(move.label). Nothing changes unless you accept.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                FlowLayout(spacing: Space.m) {
                    Button("Move to \(move.label)") { run { _ = await store.acceptReplySuggestion(reply) } }
                        .buttonStyle(.secondaryLink)
                    Button("Keep as is") { run { _ = await store.dismissReplySuggestion(reply) } }
                        .buttonStyle(.secondaryLink)
                    if let url = reply.gmailURL {
                        Button("Open in Gmail") { NSWorkspace.shared.open(url) }.buttonStyle(.secondaryLink)
                    }
                }
                .disabled(busy || !store.isConnected)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.needsYou.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func run(_ op: @escaping () async -> Void) {
        busy = true
        Task {
            await op()
            busy = false
        }
    }
}
