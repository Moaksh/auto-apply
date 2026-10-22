// OutboxTab.swift — Cold Email ▸ Up next (app/COLD_EMAIL_UX.md): the queue on the left, ordered
// by what needs you — drafts waiting for your OK, replies, applications nobody has been written
// to yet, emails that need a check, scheduled, and (folded) sent — and the focused item on the
// right. A draft shows as the email will look: From / To / Subject, the text with any claim the
// fact check couldn't find underlined inline, and the locked footer. The floating bar at the
// bottom holds the screen's one primary action: "Send N…" (the only path to sending), or, while
// sending is off, the one-time "Turn on sending…" setup. Its sheet surfaces every
// approve_outreach conflict before anything is scheduled.
import SwiftUI

struct OutboxTab: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        if model.isFirstRun {
            ScrollView {
                ColdEmailFirstRun(model: model)
                    .padding(Space.xxl)
                    .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                UpNextQueue(model: model)
                    .frame(width: 360)
                Divider()
                UpNextDetail(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .overlay(alignment: .bottom) {
                SendBar(model: model)
                    .padding(.bottom, Space.l)
            }
            .onAppear { model.ensureFocus() }
        }
    }
}

// MARK: - First run

/// Nothing to show yet: what happens on its own, and what waits for you.
struct ColdEmailFirstRun: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.s) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 30, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.accent)
                Text("Reach the people behind your applications").font(Typography.title2)
                Text("After you apply, the agent can find a recruiter or the hiring manager and write them a short note. You read every word and decide what goes out.")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.l) {
                FirstRunStep(n: 1, title: "You apply", detail: "Through the agent, or on your own and mark it applied.")
                FirstRunStep(n: 2, title: "The agent finds someone and drafts a note",
                             detail: "Drafted from your profile and stories, with where it found the address. It shows up here.")
                FirstRunStep(n: 3, title: "You read it and press Send",
                             detail: "Nothing is sent without your OK. At most one gentle follow-up, and only if you approve it.")
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()
            HStack(spacing: Space.l) {
                Button("Add someone you know") { model.isAddContactPresented = true }
                    .buttonStyle(.secondaryLink)
                    .disabled(!store.isConnected)
                Button("Find companies you'd like to work at") { model.tab = .prospects }
                    .buttonStyle(.secondaryLink)
            }
            if !store.outreach.sendEnabled {
                Label("Sending is off for now. When your first draft is ready, you'll turn it on once with a test email to yourself.",
                      systemImage: "lock")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

private struct FirstRunStep: View {
    var n: Int
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text("\(n)")
                .font(Typography.metricSmall)
                .foregroundStyle(Palette.accent)
                .frame(width: 22, height: 22)
                .background(Palette.accent.opacity(0.12), in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.bodyEmph)
                Text(detail).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Queue

private struct UpNextQueue: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @Namespace private var selectionNS

    /// What the queue's rows are: when it changes, rows rise in / collapse out and the rest close up.
    private struct Signature: Equatable {
        var drafts: [Int], replies: [Int], jobs: [Int], checks: [Int], scheduled: [Int], sent: Int, showSent: Bool, showAll: Bool
    }

    var body: some View {
        let o = store.outreach
        let jobs = model.jobsAwaitingNote
        let signature = Signature(drafts: o.drafts.map(\.id), replies: o.replyThreads.map(\.id), jobs: jobs.prefix(model.showAllApplied ? 200 : 5).map(\.id),
                                  checks: (o.unknownSends + o.failedSends).map(\.id), scheduled: o.scheduled.map(\.id),
                                  sent: model.showSent ? min(200, o.sent.count) : 0, showSent: model.showSent, showAll: model.showAllApplied)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xxs) {
                if !o.drafts.isEmpty {
                    section("Waiting for your OK", count: o.drafts.count, first: true) {
                        let all = model.selection.count == o.drafts.count
                        Button(all ? "Clear" : "Select all") { if all { model.clearSelection() } else { model.selectAllDrafts() } }
                            .buttonStyle(.secondaryLink)
                            .font(Typography.callout)
                    }
                    ForEach(o.drafts) { draftRow($0) }
                }
                if !o.replyThreads.isEmpty {
                    section("Replies", count: o.replyThreads.count, first: o.drafts.isEmpty)
                    ForEach(o.replyThreads) { replyRow($0) }
                }
                if !jobs.isEmpty {
                    section("Applied, no note yet", count: jobs.count, first: o.drafts.isEmpty && o.replyThreads.isEmpty)
                    // The newest few; the rest one click away.
                    let shown = model.showAllApplied ? 200 : 5
                    ForEach(jobs.prefix(shown)) { jobRow($0) }
                    if jobs.count > 5 {
                        Button(model.showAllApplied ? "Show fewer" : "Show all \(jobs.count)") { model.showAllApplied.toggle() }
                            .buttonStyle(.secondaryLink)
                            .font(Typography.callout)
                            .padding(.horizontal, Space.m)
                            .padding(.top, Space.xxs)
                    }
                }
                if !o.unknownSends.isEmpty || !o.failedSends.isEmpty {
                    section("Needs a check", count: o.unknownSends.count + o.failedSends.count)
                    ForEach(o.unknownSends) { messageRow($0, detail: "May have gone out · check your Sent Mail", warning: true) }
                    ForEach(o.failedSends) { messageRow($0, detail: "Not sent · \($0.error ?? "refused before sending")", warning: true) }
                }
                if !o.scheduled.isEmpty {
                    section("Scheduled", count: o.scheduled.count)
                    ForEach(o.scheduled) { m in
                        messageRow(m, detail: m.state == .sending ? "Sending now" : m.sendAt.map { "Goes out \(OutboxFormat.when($0))" } ?? "Waiting for the send window") {
                            if m.state != .sending {
                                Button("Cancel") { Task { await store.cancelOutreach(messageIDs: [m.id]) } }
                                    .buttonStyle(.secondaryLink)
                                    .font(Typography.callout)
                                    .disabled(!store.isConnected)
                                    .help("Back to drafts; nothing is sent")
                            }
                        }
                    }
                }
                if !o.sent.isEmpty {
                    Button {
                        model.showSent.toggle()
                    } label: {
                        HStack(spacing: Space.xs) {
                            Image(systemName: "chevron.right").imageScale(.small)
                                .rotationEffect(.degrees(model.showSent ? 90 : 0))
                                .motion(Motion.snappy, value: model.showSent)
                            Text("Sent").eyebrowStyle()
                            Text("\(o.sent.count)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                                .numericRoll(Double(o.sent.count))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.m)
                    .padding(.top, Space.l)
                    .padding(.bottom, Space.xxs)
                    .accessibilityLabel(model.showSent ? "Hide sent emails" : "Show \(o.sent.count) sent emails")
                    if model.showSent {
                        ForEach(o.sent.prefix(200)) { m in messageRow(m, detail: m.sentAt.map { "Sent \(C3Format.relative($0))" } ?? "Sent") }
                    }
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.top, Space.xs)
            // Room for the floating send bar.
            .padding(.bottom, 80)
            // The focus highlight travels between rows; rows arrive and leave with `.row`.
            .selectionHighlightGroup(selectionNS, selection: "\(model.focusedMessageID ?? -1)|\(model.focusedJobID ?? -1)")
            .motion(Motion.move, value: signature)
        }
    }

    private func section(_ title: String, count: Int, first: Bool = false) -> some View {
        section(title, count: count, first: first) { EmptyView() }
    }

    private func section<Trailing: View>(_ title: String, count: Int, first: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Space.s) {
            Text(title).eyebrowStyle()
            Text("\(count)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary).numericRoll(Double(count))
            Spacer()
            trailing()
        }
        .padding(.horizontal, Space.m)
        .padding(.top, first ? Space.m : Space.xl)
        .padding(.bottom, Space.xxs)
        .accessibilityAddTraits(.isHeader)
    }

    private func jobTitle(_ thread: OutreachThreadItem?) -> String? {
        thread?.jobID.flatMap { store.jobs.job(id: $0)?.title }
    }

    private func draftRow(_ m: OutreachMessageItem) -> some View {
        let thread = store.outreach.thread(id: m.threadID)
        let contact = store.outreach.contact(id: thread?.contactID)
        let lowConfidence = contact.map { $0.emailConfidence < store.preferences.outreachMinEmailConfidence } ?? false
        let ticked = model.selectedDraftIDs.contains(m.id)
        return HStack(alignment: .top, spacing: Space.s) {
            Toggle("", isOn: Binding(get: { ticked }, set: { _ in model.toggle(m.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 1)
                .accessibilityLabel("Include in the batch")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(contact?.fullName ?? m.toEmail ?? "No recipient").font(Typography.bodyEmph).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Text(C3Format.relative(m.createdAt)).font(Typography.callout).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
                Text([thread?.company, jobTitle(thread)].compactMap { $0 }.joined(separator: " · "))
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                if m.needsClaimsFix || lowConfidence || m.isFollowup {
                    HStack(spacing: Space.xs) {
                        if m.needsClaimsFix { Badge("Check a claim", symbol: "exclamationmark.triangle", tone: .warning) }
                        if lowConfidence, let contact { Badge(contact: contact) }
                        if m.isFollowup { Badge("Follow-up", symbol: "arrow.turn.down.right") }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .selectableRow(isSelected: model.focusedMessageID == m.id)
        .onTapGesture { model.focus(m.id) }
        .motionTransition(.row)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(model.focusedMessageID == m.id ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel("Draft to \(contact?.fullName ?? "unknown") at \(thread?.company ?? "")\(m.needsClaimsFix ? ", a claim to check" : "")\(ticked ? ", in the batch" : "")")
    }

    private func messageRow(_ m: OutreachMessageItem, detail: String, warning: Bool = false) -> some View {
        messageRow(m, detail: detail, warning: warning) { EmptyView() }
    }

    private func messageRow<Trailing: View>(_ m: OutreachMessageItem, detail: String, warning: Bool = false,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        let thread = store.outreach.thread(id: m.threadID)
        let contact = store.outreach.contact(id: thread?.contactID)
        return HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(contact?.fullName ?? m.toEmail ?? "—").font(Typography.bodyEmph).lineLimit(1)
                    Text("· \(thread?.company ?? "")").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Label {
                    Text(detail)
                } icon: {
                    if warning { Image(systemName: "questionmark.circle").foregroundStyle(Palette.needsYou) }
                }
                .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .selectableRow(isSelected: model.focusedMessageID == m.id)
        .onTapGesture { model.focus(m.id) }
        .motionTransition(.row)
        .accessibilityElement(children: .contain)
    }

    private func replyRow(_ t: OutreachThreadItem) -> some View {
        let reply = store.outreach.latestReply(threadID: t.id)
        let contact = store.outreach.contact(id: t.contactID)
        return HStack(alignment: .top, spacing: Space.s) {
            Circle().fill(t.unreadReply ? Palette.needsYou : Color.clear).frame(width: 7, height: 7).padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(contact?.fullName ?? "Someone").font(t.unreadReply ? Typography.bodyEmph : Typography.body).lineLimit(1)
                    Text("· \(t.company)").font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Text(reply.map { OutboxFormat.snippet($0.body) } ?? t.state.label)
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .selectableRow(isSelected: reply.map { model.focusedMessageID == $0.id } ?? false)
        .onTapGesture { if let reply { model.focus(reply.id) } }
        .motionTransition(.row)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(t.unreadReply ? "Unread reply" : "Reply") from \(contact?.fullName ?? "someone") at \(t.company)")
    }

    private func jobRow(_ job: JobItem) -> some View {
        let status = store.outreach.followUpStatus(for: job)
        return HStack(alignment: .center, spacing: Space.s) {
            CompanyMonogram(name: job.company, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.company).font(Typography.bodyEmph).lineLimit(1)
                Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            Text(status.shortLabel).font(Typography.callout).foregroundStyle(Palette.textTertiary).lineLimit(1)
        }
        .selectableRow(isSelected: model.focusedJobID == job.id)
        .onTapGesture { model.focusJob(job.id) }
        .motionTransition(.row)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(job.company), \(job.title), \(status.label)")
    }
}

extension FollowUpStatus {
    /// The queue's quiet trailing word.
    var shortLabel: String {
        switch self {
        case .noContact: "No one yet"
        case .scouting: "Looking…"
        case .contactsFound(let n): n == 1 ? "1 person" : "\(n) people"
        default: label
        }
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

    static func firstName(_ name: String?) -> String {
        name?.split(separator: " ").first.map(String.init) ?? "them"
    }
}

// MARK: - Send bar (the screen's one primary action)

/// Floats over the queue while drafts wait. Sending on: "N ticked · Send N…". Sending off: the
/// one-time setup (a test email to yourself). No mailbox: where to connect one. No drafts: hidden.
struct SendBar: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        let o = store.outreach
        if o.draftCount > 0 {
            Group {
                if !o.mailAccount.isConnected {
                    GlassBar {
                        Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(Palette.textSecondary)
                        Text("Connect your Gmail to send. Drafts are still written for you.").font(Typography.body).lineLimit(1)
                        Button("Open Settings") { SettingsNavigation.shared.open(.sources, router: store.router) }
                            .buttonStyle(.secondaryLink)
                    }
                } else if !o.sendEnabled {
                    GlassBar {
                        Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(Palette.textSecondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("One-time setup: turn on sending").font(Typography.bodyEmph)
                            Text("A test email goes to \(o.mailAccount.email ?? "you") first.").font(Typography.callout)
                                .foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                        Button("Turn on sending…") {
                            model.resetEnableState()
                            model.isEnableSheetPresented = true
                        }
                        .buttonStyle(.primaryPill)
                    }
                } else {
                    let n = model.selection.count
                    GlassBar {
                        Text(n == 0 ? "Tick the drafts you're happy with" : "\(n) of \(C3Format.plural(o.draftCount, "draft")) ticked")
                            .font(Typography.body).foregroundStyle(n == 0 ? Palette.textSecondary : Palette.textPrimary)
                            .lineLimit(1)
                        if n < o.draftCount {
                            Button("Select all") { model.selectAllDrafts() }.buttonStyle(.secondaryLink)
                        }
                        Button(n > 0 ? "Send \(n)…" : "Send…") { model.beginSend() }
                            .buttonStyle(.primaryPill)
                            .disabled(!model.canSend)
                            .help(model.sendBlocker ?? "Review the batch and approve it. Nothing is sent before you confirm.")
                    }
                }
            }
            .fixedSize()
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Detail

private struct UpNextDetail: View {
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
                .padding(.bottom, 64)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .id(m.id)
        } else if let job = model.focusedJob {
            ScrollView {
                AppliedJobPanel(job: job, model: model)
                    .padding(Space.contentPadding)
                    .frame(maxWidth: 760, alignment: .leading)
            }
            .id("job-\(job.id)")
        } else {
            EmptyState(symbol: "checkmark.circle", title: "You're all caught up",
                       message: "New drafts land here after you apply. Pick anything on the left to see it.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// An application nobody has been written to yet: who's been found there and a draft link for
/// each, or Find people. Every draft waits here for your OK.
struct AppliedJobPanel: View {
    var job: JobItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        let contacts = store.outreach.contacts(companyID: job.companyID)
        let scouting = store.outreach.scouting.contains(job.companyID)
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Applied, no note yet").eyebrowStyle()
                Text("Reach someone at \(job.company) about \(job.title)")
                    .font(Typography.title2).fixedSize(horizontal: false, vertical: true)
                Text("\(job.submittedAt.map { "You applied \(C3Format.relative($0))." } ?? "You applied.") A short note to the recruiter or the hiring manager helps your application get read.")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("People at \(job.company)").eyebrowStyle()
                    Spacer()
                    if scouting || busy { ProgressView().controlSize(.small) }
                    Button(contacts.isEmpty ? "Find people" : "Find more people") {
                        run { _ = await store.scoutContacts(companyID: job.companyID, applicationID: job.applicationID) }
                    }
                    .buttonStyle(.secondaryLink)
                    .disabled(busy || scouting || !store.isConnected)
                    .help("Looks on \(job.company)'s site, GitHub and Google results at a human pace")
                }
                .padding(.bottom, Space.s)
                if contacts.isEmpty {
                    Text(scouting ? "Looking on \(job.company)'s site, GitHub and Google results…"
                         : "No one found yet. The agent looks for a recruiter named in the posting, then the hiring manager.")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Space.s)
                } else {
                    ForEach(Array(contacts.prefix(6).enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider() }
                        HStack(spacing: Space.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.fullName).font(Typography.bodyEmph).lineLimit(1)
                                Text(c.title ?? c.roleCategory.label).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                            }
                            Spacer(minLength: Space.s)
                            Badge(contact: c)
                            ProvenanceButton(contact: c)
                            if c.hasEmail {
                                Button("Draft a note") {
                                    run {
                                        if let check = await store.draftOutreach(contactID: c.id, kind: .application, applicationID: job.applicationID),
                                           let tid = check.threadId {
                                            model.open(threadID: tid)
                                        }
                                    }
                                }
                                .buttonStyle(.secondaryLink)
                                .disabled(busy || !store.isConnected)
                                .help("Draft a short note to \(c.fullName) for your review. Nothing is sent.")
                            }
                        }
                        .padding(.vertical, Space.s)
                    }
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .surface()
            Label("Drafts wait here for your OK. Nothing is sent without it.", systemImage: "hand.raised")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
        }
    }

    private func run(_ op: @escaping () async -> Void) {
        busy = true
        Task {
            await op()
            busy = false
        }
    }
}

/// The draft as the email will look: who it's to and why, then From / To / Subject, the text
/// (any claim the fact check couldn't find underlined in place, with Edit / It's true right
/// there), the locked footer, and the few actions: tick for the batch, Edit, Discard, Next.
struct DraftEditor: View {
    var message: OutreachMessageItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var editing: Bool
    @State private var subject: String
    @State private var text: String
    @State private var saving = false

    /// `startEditing`: open with the text editor showing (tests, "Edit").
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
            intro(thread: thread, contact: contact)
            emailCard(thread: thread, contact: contact)
            if let contact, contact.emailConfidence < store.preferences.outreachMinEmailConfidence {
                Label("This address is a \(contact.tier.label.lowercased()) (\(contact.emailConfidence), below your bar of \(store.preferences.outreachMinEmailConfidence)). You'll be asked to confirm before it's sent.",
                      systemImage: "questionmark.circle")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
    }

    // MARK: Intro

    private func intro(thread: OutreachThreadItem?, contact: ContactItem?) -> some View {
        let first = OutboxFormat.firstName(contact?.fullName)
        let company = thread?.company ?? "the company"
        let job = thread?.jobID.flatMap { store.jobs.job(id: $0) }
        let headline: String = if message.isFollowup {
            "Follow up with \(first) at \(company)"
        } else {
            switch thread?.kind ?? .application {
            case .application: job.map { "Email \(first) at \(company) about \($0.title)" } ?? "Email \(first) at \(company) about your application"
            case .prospect: "Introduce yourself to \(first) at \(company)"
            case .referralEmail: "Ask \(first) at \(company) for a referral"
            }
        }
        var context: [String] = []
        if let name = contact?.fullName, let title = contact?.title { context.append("\(name), \(title)") }
        if let applied = job?.submittedAt { context.append("Applied \(C3Format.relative(applied))") }
        if thread?.kind == .prospect { context.append("No application, so it never says you applied") }
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(model.draftPosition.map { "Next up · \($0.index) of \($0.count)" } ?? "Draft").eyebrowStyle()
                Spacer()
                if model.isRedrafting(message.id) {
                    ProgressView().controlSize(.small)
                    Text("Re-drafting…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                if model.nextDraftID != nil {
                    Button { model.focusNextDraft() } label: {
                        HStack(spacing: Space.xxs) { Text("Next draft"); Image(systemName: "chevron.right").imageScale(.small) }
                    }
                    .buttonStyle(.secondaryLink)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("The next draft waiting for your OK (⌘])")
                }
            }
            Text(headline).font(Typography.title2).fixedSize(horizontal: false, vertical: true)
            if !context.isEmpty {
                Text(context.joined(separator: " · "))
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: The email

    private func emailCard(thread: OutreachThreadItem?, contact: ContactItem?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow("From") {
                Text(message.fromEmail ?? store.outreach.mailAccount.email ?? "your Gmail")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Divider().padding(.leading, Space.l)
            headerRow("To") {
                HStack(spacing: Space.xs) {
                    Text(contact?.fullName ?? "No recipient").font(Typography.bodyEmph).lineLimit(1)
                    if let email = message.toEmail ?? contact?.email {
                        Text(email).font(Typography.mono).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let contact {
                        Badge(contact: contact)
                        ProvenanceButton(contact: contact)
                    }
                    Spacer(minLength: Space.xs)
                    if let thread { contactSwitcher(thread: thread, current: contact) }
                }
            }
            Divider().padding(.leading, Space.l)
            headerRow("Subject") {
                if editing {
                    TextField("Subject", text: $subject).textFieldStyle(.plain).font(Typography.bodyEmph)
                } else {
                    Text(message.subject ?? "(no subject)").font(Typography.bodyEmph).textSelection(.enabled)
                }
            }
            Divider()
            bodyText
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.l)
            if message.needsClaimsFix && !editing { claims.padding(.horizontal, Space.xl).padding(.bottom, Space.l) }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Email preview")
    }

    private func headerRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(label).font(Typography.callout).foregroundStyle(Palette.textTertiary).frame(width: 56, alignment: .leading)
            content()
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
    }

    @ViewBuilder
    private func contactSwitcher(thread: OutreachThreadItem, current: ContactItem?) -> some View {
        let others = store.outreach.contacts(companyID: thread.companyID).filter { $0.id != current?.id && $0.hasEmail }
        if !others.isEmpty {
            Menu("Someone else") {
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

    @ViewBuilder
    private var bodyText: some View {
        if editing {
            VStack(alignment: .leading, spacing: Space.xs) {
                TextEditor(text: $text)
                    .font(Typography.body)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 240)
                    .padding(Space.s)
                    .well()
                    .accessibilityLabel("Email text")
                Text("\(text.split(whereSeparator: \.isWhitespace).count) words · the fact check runs again when you save")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        } else {
            Text(ClaimHighlighter.attributed(message.body, claims: message.needsClaimsFix ? message.unsupportedClaims : []))
                .font(Typography.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Inline under the text: what the fact check couldn't find, and the two ways forward.
    private var claims: some View {
        let n = message.unsupportedClaims.count
        return VStack(alignment: .leading, spacing: Space.xs) {
            Label(n == 1 ? "The underlined claim isn't in your profile or stories" : "\(n) underlined claims aren't in your profile or stories",
                  systemImage: "exclamationmark.triangle")
                .font(Typography.callout.weight(.medium)).foregroundStyle(Palette.needsYou)
            Text("Edit the text, or confirm it's true. It can't be sent until you do one or the other.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.l) {
                Button("Edit") { beginEditing() }.buttonStyle(.secondaryLink)
                Button("It's true") {
                    Task {
                        saving = true
                        _ = await store.editOutreachDraft(messageID: message.id, subject: nil, body: message.body, confirmClaims: true)
                        saving = false
                    }
                }
                .buttonStyle(.secondaryLink)
                .disabled(saving || !store.isConnected)
                .help("You confirm the underlined claims are accurate. This is recorded on the email.")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.needsYou.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(message.footer.c3Trimmed ?? FooterPreview.placeholder)
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Label("Added to every email: where the address came from and how to opt out. It can't be removed.", systemImage: "lock.fill")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sunken.opacity(0.6))
        .accessibilityElement(children: .combine)
    }

    private func beginEditing() {
        text = message.body
        subject = message.subject ?? ""
        editing = true
    }

    // MARK: Actions

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
                Toggle("Include in this batch", isOn: Binding(get: { model.selectedDraftIDs.contains(message.id) },
                                                             set: { _ in model.toggle(message.id) }))
                    .toggleStyle(.checkbox)
                // A claim to check is explained inline in the email; the badge is for the other verdicts.
                if !message.needsClaimsFix { Badge(factCheck: message) }
                Spacer()
                Button("Edit") { beginEditing() }.buttonStyle(.secondaryLink)
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
            ScheduleRibbon(count: ids.count, window: prefs.outreachSendWindow, weekdaysOnly: prefs.outreachWeekdaysOnly)
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
            Text("Emails wait under Scheduled in Up next until their time; you can cancel any of them until then.")
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
