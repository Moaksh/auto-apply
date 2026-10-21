// OutboxTab.swift — Cold Email ▸ Outbox: Drafts (multi-select → "Send N…"), Scheduled (Cancel),
// Sent and Replies, with the draft editor on the right. The editor highlights claims the fact
// check couldn't find, shows the fact-check status, lets you switch to another contact (re-draft)
// and previews the fixed footer. "Send N…" is the screen's one primary action and the only path
// to sending; its sheet surfaces every approve_outreach conflict before anything is scheduled.
import SwiftUI

struct OutboxTab: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        let o = store.outreach
        let isEmpty = o.drafts.isEmpty && o.scheduled.isEmpty && o.sent.isEmpty && o.replyThreads.isEmpty && o.unknownSends.isEmpty
            && o.failedSends.isEmpty
        if isEmpty {
            EmptyState(symbol: "tray", title: "Nothing in the Outbox",
                       message: "Drafts appear here for your review. Start one from Follow-ups, Prospects or Contacts.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                OutboxList(model: model)
                    .frame(width: 380)
                Divider()
                OutboxDetail(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onAppear { model.ensureFocus() }
        }
    }
}

// MARK: - List

private struct OutboxList: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        let o = store.outreach
        VStack(alignment: .leading, spacing: 0) {
            // Pinned: the batch's "Send N…" stays in view while the list scrolls.
            draftsHeader
                .padding(.horizontal, Space.s)
                .padding(.top, Space.s)
            Divider()
            list(o)
        }
    }

    private func list(_ o: OutreachStore) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xxs) {
                if o.drafts.isEmpty {
                    Text("No drafts waiting.").font(Typography.callout).foregroundStyle(Palette.textTertiary).padding(.horizontal, Space.m)
                }
                ForEach(o.drafts) { draftRow($0) }
                if !o.unknownSends.isEmpty {
                    section("Not sure these went out", count: o.unknownSends.count)
                    ForEach(o.unknownSends) { messageRow($0, detail: "Check your Sent Mail") }
                }
                if !o.scheduled.isEmpty {
                    section("Scheduled", count: o.scheduled.count)
                    ForEach(o.scheduled) { m in
                        messageRow(m, detail: m.state == .sending ? "Sending now" : m.sendAt.map { "Goes out \(OutboxFormat.when($0))" } ?? "Waiting for the send window") {
                            if m.state != .sending {
                                Button("Cancel") { Task { await store.cancelOutreach(messageIDs: [m.id]) } }
                                    .buttonStyle(.secondaryLink)
                                    .font(Typography.callout)
                                    .help("Back to Drafts; nothing is sent")
                            }
                        }
                    }
                }
                if !o.failedSends.isEmpty {
                    section("Not sent", count: o.failedSends.count)
                    ForEach(o.failedSends) { messageRow($0, detail: $0.error ?? "Refused before sending") }
                }
                if !o.replyThreads.isEmpty {
                    section("Replies", count: o.replyThreads.count)
                    ForEach(o.replyThreads) { replyRow($0) }
                }
                if !o.sent.isEmpty {
                    section("Sent", count: o.sent.count)
                    ForEach(o.sent.prefix(200)) { m in messageRow(m, detail: m.sentAt.map { "Sent \(C3Format.relative($0))" } ?? "Sent") }
                }
            }
            .padding(Space.s)
        }
    }

    private var draftsHeader: some View {
        let count = model.selection.count
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text("Drafts").eyebrowStyle()
                Text("\(store.outreach.draftCount)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                Spacer()
                if store.outreach.draftCount > 0 {
                    Button(count == store.outreach.draftCount ? "Clear" : "Select all") {
                        if count == store.outreach.draftCount { model.clearSelection() } else { model.selectAllDrafts() }
                    }
                    .buttonStyle(.secondaryLink)
                    .font(Typography.callout)
                }
                Button(count > 0 ? "Send \(count)…" : "Send…") { model.beginSend() }
                    .buttonStyle(.primaryPill)
                    .controlSize(.small)
                    .disabled(!model.canSend)
                    .help(model.sendBlocker ?? "Review the batch and approve it. Nothing is sent before you confirm.")
            }
            if let blocker = model.sendBlocker, store.outreach.draftCount > 0 {
                Text(blocker).font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: Space.s) {
            Text(title).eyebrowStyle()
            Text("\(count)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.l)
        .padding(.bottom, Space.xxs)
        .accessibilityAddTraits(.isHeader)
    }

    private func draftRow(_ m: OutreachMessageItem) -> some View {
        let thread = store.outreach.thread(id: m.threadID)
        let contact = store.outreach.contact(id: thread?.contactID)
        let lowConfidence = contact.map { $0.emailConfidence < store.preferences.outreachMinEmailConfidence } ?? false
        return HStack(alignment: .top, spacing: Space.s) {
            Toggle("", isOn: Binding(get: { model.selectedDraftIDs.contains(m.id) }, set: { _ in model.toggle(m.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Include in the batch")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(contact?.fullName ?? m.toEmail ?? "No recipient").font(Typography.bodyEmph).lineLimit(1)
                    Text("· \(thread?.company ?? "")").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Text(m.subject ?? "(no subject)").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                HStack(spacing: Space.xs) {
                    if m.needsClaimsFix { Badge("Check claims", symbol: "exclamationmark.triangle", tone: .warning) }
                    if lowConfidence, let contact { Badge(contact: contact) }
                    if m.isFollowup { Badge("Follow-up", symbol: "arrow.turn.down.right") }
                }
            }
            Spacer(minLength: 0)
        }
        .selectableRow(isSelected: model.focusedMessageID == m.id)
        .onTapGesture { model.focus(m.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Draft to \(contact?.fullName ?? "unknown") at \(thread?.company ?? "")\(m.needsClaimsFix ? ", claims to check" : "")")
    }

    private func messageRow(_ m: OutreachMessageItem, detail: String) -> some View {
        messageRow(m, detail: detail) { EmptyView() }
    }

    private func messageRow<Trailing: View>(_ m: OutreachMessageItem, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        let thread = store.outreach.thread(id: m.threadID)
        let contact = store.outreach.contact(id: thread?.contactID)
        return HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(contact?.fullName ?? m.toEmail ?? "—").font(Typography.bodyEmph).lineLimit(1)
                    Text("· \(thread?.company ?? "")").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Text(detail).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .selectableRow(isSelected: model.focusedMessageID == m.id)
        .onTapGesture { model.focus(m.id) }
    }

    private func replyRow(_ t: OutreachThreadItem) -> some View {
        let reply = store.outreach.latestReply(threadID: t.id)
        let contact = store.outreach.contact(id: t.contactID)
        return HStack(alignment: .top, spacing: Space.s) {
            Circle().fill(t.unreadReply ? Palette.needsYou : Color.clear).frame(width: 7, height: 7).padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(contact?.fullName ?? "Someone").font(Typography.bodyEmph).lineLimit(1)
                    Text("· \(t.company)").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Text(reply.map { OutboxFormat.snippet($0.body) } ?? t.state.label)
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .selectableRow(isSelected: reply.map { model.focusedMessageID == $0.id } ?? false)
        .onTapGesture { if let reply { model.focus(reply.id) } }
        .accessibilityLabel("\(t.unreadReply ? "Unread reply" : "Reply") from \(contact?.fullName ?? "someone") at \(t.company)")
    }
}

enum OutboxFormat {
    /// "today 10:42", "Tue 10:42".
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    static func snippet(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Detail

private struct OutboxDetail: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        if let m = model.focusedMessage {
            ScrollView {
                Group {
                    if m.isInbound {
                        ReplyDetail(message: m, model: model)
                    } else if m.state == .draft {
                        DraftEditor(message: m, model: model)
                    } else {
                        SentDetail(message: m)
                    }
                }
                .padding(Space.contentPadding)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .id(m.id)
        } else {
            EmptyState(symbol: "square.and.pencil", title: "Pick a draft", message: "Read and edit it before you approve it.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The draft editor: recipient (with a contact switcher), subject, the body with unsupported
/// claims highlighted, the fact-check status and the fixed footer.
struct DraftEditor: View {
    var message: OutreachMessageItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var editing: Bool
    @State private var subject: String
    @State private var text: String
    @State private var saving = false

    /// `startEditing`: open with the text editor showing (tests, "Edit text").
    init(message: OutreachMessageItem, model: ColdEmailModel, startEditing: Bool = false) {
        self.message = message
        self.model = model
        _editing = State(initialValue: startEditing)
        _subject = State(initialValue: message.subject ?? "")
        _text = State(initialValue: message.body)
    }

    var body: some View {
        let thread = store.outreach.thread(id: message.threadID)
        let contact = store.outreach.contact(id: thread?.contactID)
        VStack(alignment: .leading, spacing: Space.l) {
            recipient(thread: thread, contact: contact)
            if let thread { context(thread) }
            HStack(spacing: Space.s) {
                Badge(factCheck: message)
                if message.isFollowup { Badge("Follow-up", symbol: "arrow.turn.down.right") }
                if model.isRedrafting(message.id) {
                    ProgressView().controlSize(.small)
                    Text("Re-drafting…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
            }
            if let contact, contact.emailConfidence < store.preferences.outreachMinEmailConfidence {
                Label("This address is a \(contact.tier.label.lowercased()) (\(contact.emailConfidence), below your bar of \(store.preferences.outreachMinEmailConfidence)). You'll be asked to confirm before it's sent.",
                      systemImage: "questionmark.circle")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.needsClaimsFix { claims }
            subjectField
            bodyField
            FooterPreview(footer: message.footer)
            actions
        }
    }

    private func recipient(thread: OutreachThreadItem?, contact: ContactItem?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text("To").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary).frame(width: 56, alignment: .leading)
                Text(contact?.fullName ?? "No recipient").font(Typography.bodyEmph)
                if let email = message.toEmail ?? contact?.email {
                    Text(email).font(Typography.mono).foregroundStyle(Palette.textSecondary).lineLimit(1).textSelection(.enabled)
                }
                if let contact {
                    Badge(contact: contact)
                    ProvenanceButton(contact: contact)
                }
                Spacer()
                if let thread { contactSwitcher(thread: thread, current: contact) }
            }
            if let title = contact?.title {
                Text(title).font(Typography.callout).foregroundStyle(Palette.textSecondary).padding(.leading, 56 + Space.s)
            }
        }
    }

    @ViewBuilder
    private func contactSwitcher(thread: OutreachThreadItem, current: ContactItem?) -> some View {
        let others = store.outreach.contacts(companyID: thread.companyID).filter { $0.id != current?.id && $0.hasEmail }
        if !others.isEmpty {
            Menu("Switch contact") {
                ForEach(others) { c in
                    Button("\(c.fullName)\(c.title.map { " · \($0)" } ?? "") · \(c.tier.label) \(c.emailConfidence)") {
                        Task { await model.switchContact(message: message, to: c.id) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isRedrafting(message.id) || !store.isConnected)
            .help("Re-draft this email for someone else at \(thread.company)")
        }
    }

    private func context(_ thread: OutreachThreadItem) -> some View {
        let job = thread.jobID.flatMap { store.jobs.job(id: $0) }
        let line: String = switch thread.kind {
        case .application: job.map { "About your application: \($0.title)\($0.submittedAt.map { ", applied \(C3Format.relative($0))" } ?? "")" } ?? "About your application"
        case .prospect: "Introduction to \(thread.company) (no application)"
        case .referralEmail: "Asking for a referral at \(thread.company)"
        }
        return Text(line).font(Typography.callout).foregroundStyle(Palette.textSecondary)
    }

    private var claims: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Not found in your profile or stories").eyebrowStyle()
            ForEach(message.unsupportedClaims, id: \.self) { claim in
                Label("“\(claim)”", systemImage: "exclamationmark.triangle")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textPrimary)
            }
            Text("Edit the text, or confirm these are true. It can't be sent until you do one or the other.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.l) {
                Button("Edit text") { beginEditing() }.buttonStyle(.secondaryLink)
                Button("These are true") {
                    Task {
                        saving = true
                        _ = await store.editOutreachDraft(messageID: message.id, subject: nil, body: message.body, confirmClaims: true)
                        saving = false
                    }
                }
                .buttonStyle(.secondaryLink)
                .disabled(saving || !store.isConnected)
                .help("You confirm the highlighted claims are accurate. This is recorded on the email.")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.needsYou.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }

    @ViewBuilder
    private var subjectField: some View {
        HStack(spacing: Space.s) {
            Text("Subject").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary).frame(width: 56, alignment: .leading)
            if editing {
                TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
            } else {
                Text(message.subject ?? "(no subject)").font(Typography.body).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var bodyField: some View {
        if editing {
            TextEditor(text: $text)
                .font(Typography.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
                .padding(Space.s)
                .well()
                .accessibilityLabel("Email text")
            Text("\(text.split(whereSeparator: \.isWhitespace).count) words · the fact check runs again when you save")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
        } else {
            Text(ClaimHighlighter.attributed(message.body, claims: message.needsClaimsFix ? message.unsupportedClaims : []))
                .font(Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .well()
        }
    }

    private func beginEditing() {
        text = message.body
        subject = message.subject ?? ""
        editing = true
    }

    private var actions: some View {
        HStack(spacing: Space.l) {
            if editing {
                Spacer()
                Button("Cancel") {
                    text = message.body
                    subject = message.subject ?? ""
                    editing = false
                }
                .buttonStyle(.secondaryLink)
                .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    Task {
                        saving = true
                        if await store.editOutreachDraft(messageID: message.id, subject: subject.nonEmptyTrimmed, body: text) != nil { editing = false }
                        saving = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.isConnected)
            } else {
                Toggle("Include in the next batch", isOn: Binding(get: { model.selectedDraftIDs.contains(message.id) },
                                                                set: { _ in model.toggle(message.id) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Edit text") { beginEditing() }.buttonStyle(.secondaryLink)
                Button("Discard") { Task { await store.discardOutreach(threadID: message.threadID) } }
                    .buttonStyle(.secondaryLink)
                    .foregroundStyle(Palette.error)
                    .disabled(!store.isConnected)
                    .help("Throw this draft away. Nothing was sent.")
            }
        }
    }
}

/// A scheduled, sent, failed or "possibly sent" email (read-only).
private struct SentDetail: View {
    var message: OutreachMessageItem
    @Environment(AppStore.self) private var store

    var body: some View {
        let thread = store.outreach.thread(id: message.threadID)
        let contact = store.outreach.contact(id: thread?.contactID)
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Text(contact?.fullName ?? message.toEmail ?? "—").font(Typography.title2)
                if let contact { Badge(contact: contact) }
            }
            status
            Text(message.subject ?? "").font(Typography.bodyEmph)
            Text(message.body)
                .font(Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .well()
            FooterPreview(footer: message.footer)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch message.state {
        case .approved, .scheduled:
            HStack(spacing: Space.l) {
                Label(message.sendAt.map { "Goes out \(OutboxFormat.when($0))" } ?? "Waiting for the send window", systemImage: "clock")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Button("Cancel") { Task { await store.cancelOutreach(messageIDs: [message.id]) } }
                    .buttonStyle(.secondaryLink)
                    .disabled(!store.isConnected)
                    .help("Back to Drafts; nothing is sent")
            }
        case .sending:
            Label("Sending now", systemImage: "paperplane").font(Typography.callout).foregroundStyle(Palette.textSecondary)
        case .sent:
            HStack(spacing: Space.l) {
                Label(message.sentAt.map { "Sent \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Sent", systemImage: "checkmark.circle")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                if let url = message.gmailURL {
                    Button("Open in Gmail") { NSWorkspace.shared.open(url) }.buttonStyle(.secondaryLink)
                }
            }
        case .failed:
            Label("Not sent: \(message.error ?? "refused before sending")", systemImage: StatusKind.error.symbol)
                .font(Typography.callout).foregroundStyle(Palette.error)
        case .unknown:
            PossiblySentControls(message: message)
        default:
            EmptyView()
        }
    }
}

/// "We may not have sent this email." Never resent automatically: the user checks Sent Mail.
struct PossiblySentControls: View {
    var message: OutreachMessageItem
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label("The agent stopped while sending this, so it may or may not have gone out. It won't be sent again on its own.",
                  systemImage: "questionmark.circle")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Button("It was sent") { resolve(true) }.buttonStyle(.bordered)
                Button("It wasn't sent") { resolve(false) }.buttonStyle(.bordered)
                if let url = message.gmailURL {
                    Button("Check Sent Mail") { NSWorkspace.shared.open(url) }.buttonStyle(.secondaryLink)
                }
            }
            .disabled(busy || !store.isConnected)
        }
    }

    private func resolve(_ sent: Bool) {
        busy = true
        Task {
            _ = await store.resolveOutreachUnknown(messageID: message.id, sent: sent)
            busy = false
        }
    }
}

/// An inbound reply: the text, Open in Gmail, outcome and close.
private struct ReplyDetail: View {
    var message: OutreachMessageItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        let thread = store.outreach.thread(id: message.threadID)
        let contact = store.outreach.contact(id: thread?.contactID)
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Text("\(contact?.fullName ?? "Someone") replied").font(Typography.title2)
                if let c = message.classification.flatMap(ReplyLabel.init(rawValue:)) { Badge(c.label) }
            }
            Text("\(thread?.company ?? "") · \(message.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            Text(message.body)
                .font(Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .well()
            Text("Answer them in Gmail; AutoApply never replies for you.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            HStack(spacing: Space.l) {
                if let url = message.gmailURL {
                    Button("Open in Gmail") { NSWorkspace.shared.open(url) }.buttonStyle(.secondaryLink)
                }
                if let thread {
                    Menu("Outcome") {
                        ForEach(ThreadOutcome.allCases, id: \.self) { outcome in
                            Button(OutboxFormat.outcomeLabel(outcome)) { Task { await store.setThreadOutcome(threadID: thread.id, outcome: outcome, close: false) } }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    if thread.state != .closed {
                        Button("Close conversation") { Task { await store.setThreadOutcome(threadID: thread.id, outcome: thread.outcome, close: true) } }
                            .buttonStyle(.secondaryLink)
                            .help("Stops any follow-up for this conversation")
                    }
                }
            }
            .disabled(!store.isConnected)
        }
    }
}

extension OutboxFormat {
    static func outcomeLabel(_ o: ThreadOutcome) -> String {
        switch o {
        case .positive: "Positive"
        case .referred: "Referred me"
        case .notInterested: "Not interested"
        case .question: "Asked a question"
        case .other: "Other"
        }
    }
}

// MARK: - Send N… sheet

/// The one approval click. Says exactly what will happen, and lists anything the agent refused
/// (unsupported claims, an address below your bar, do-not-contact, a closed conversation).
struct SendConfirmSheet: View {
    @Bindable var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        let ids = model.selection
        let prefs = store.preferences
        VStack(alignment: .leading, spacing: Space.l) {
            Text(ids.count == 1 ? "Send 1 email?" : "Send \(ids.count) emails?").font(Typography.title2)
            Text(model.sendSentence(count: ids.count, preferences: prefs))
                .font(Typography.body).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            recipients(ids)
            if prefs.outreachMaxFollowups > 0 {
                Toggle("Also send one gentle follow-up after \(prefs.outreachFollowupDays) business days if nobody replies",
                       isOn: $model.includeFollowups)
                    .toggleStyle(.checkbox)
                Text(model.includeFollowups
                     ? "It's stopped if they reply, bounce or ask not to be emailed, or if the application closes."
                     : "If nobody replies, a follow-up draft comes back here for your review instead.")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            problems
            Text("Emails wait in Scheduled until their time; you can cancel any of them until then.")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelSendSheet() }
                    .buttonStyle(.secondaryLink)
                    .keyboardShortcut(.cancelAction)
                Button(model.approveState == .sending ? "Scheduling…" : (ids.count == 1 ? "Send 1 email" : "Send \(ids.count) emails")) {
                    Task { await model.approveSelected() }
                }
                .buttonStyle(.primaryPill)
                .keyboardShortcut(.defaultAction)
                .disabled(ids.isEmpty || model.approveState == .sending || !store.isConnected)
            }
        }
        .padding(Space.xl)
        .frame(width: 560)
    }

    private func recipients(_ ids: [Int]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(ids.prefix(8), id: \.self) { id in
                let m = store.outreach.message(id: id)
                let t = store.outreach.thread(id: m?.threadID)
                let c = store.outreach.contact(id: t?.contactID)
                HStack(spacing: Space.s) {
                    Text(c?.fullName ?? m?.toEmail ?? "—").font(Typography.callout)
                    Text("· \(t?.company ?? "")").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    if let c { Badge(contact: c) }
                    if model.sendAnyway.contains(id) { Badge("Send anyway", symbol: "checkmark", tone: .accent) }
                }
            }
            if ids.count > 8 {
                Text("+\(ids.count - 8) more").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }

    @ViewBuilder
    private var problems: some View {
        switch model.approveState {
        case .conflicts(let c, _):
            VStack(alignment: .leading, spacing: Space.m) {
                Label("Nothing was scheduled. Fix or leave out these first:", systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.bodyEmph).foregroundStyle(Palette.needsYou)
                if !c.ungrounded.isEmpty {
                    problem(ids: c.ungrounded, text: "has a claim the fact check couldn't find in your profile. Edit it, or confirm it's true.") { id in
                        Button("Review") { model.review(id) }.buttonStyle(.secondaryLink)
                    }
                }
                if !c.lowConfidence.isEmpty {
                    problem(ids: c.lowConfidence, text: "goes to an address below your confidence bar of \(store.preferences.outreachMinEmailConfidence).") { id in
                        Button("Send anyway") { Task { await model.sendAnywayAndRetry([id]) } }.buttonStyle(.secondaryLink)
                    }
                }
                if !c.doNotContact.isEmpty {
                    problem(ids: c.doNotContact, text: "is on your do-not-contact list (or has no address). It can't be sent.") { _ in EmptyView() }
                }
                if !c.threadClosed.isEmpty {
                    problem(ids: c.threadClosed, text: "belongs to a conversation that's already closed.") { _ in EmptyView() }
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.needsYou.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        case .failed(let message):
            Label(message, systemImage: StatusKind.error.symbol)
                .font(Typography.callout).foregroundStyle(Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .sending:
            EmptyView()
        }
    }

    private func problem<Fix: View>(ids: [Int], text: String, @ViewBuilder fix: @escaping (Int) -> Fix) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(ids, id: \.self) { id in
                let m = store.outreach.message(id: id)
                let t = store.outreach.thread(id: m?.threadID)
                let name = store.outreach.contact(id: t?.contactID)?.fullName ?? m?.toEmail ?? "This email"
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text("\(name) (\(t?.company ?? "")) \(text)")
                        .font(Typography.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.s)
                    fix(id)
                    Button("Leave out") { model.leaveOut([id]) }.buttonStyle(.secondaryLink)
                }
            }
        }
    }
}
