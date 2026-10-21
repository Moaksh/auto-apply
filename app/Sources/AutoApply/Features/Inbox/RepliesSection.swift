// RepliesSection.swift — Needs You ▸ Replies: people who answered your emails (Open in Gmail,
// mark read, a suggested board move), employer emails with a suggested board move (Accept /
// Keep as is), and "possibly sent" emails the agent couldn't confirm (It was sent / It wasn't
// sent; never resent automatically). The board never moves by itself.
import AppKit
import SwiftUI

/// One item in Needs You ▸ Replies.
enum NeedsYouReply: Identifiable, Hashable {
    case outreach(OutreachThreadItem)
    case employer(ApplicationReplyItem)
    case possiblySent(OutreachMessageItem)

    enum Key: Hashable, Sendable {
        case outreach(Int)
        case employer(Int)
        case possiblySent(Int)
    }

    var key: Key {
        switch self {
        case .outreach(let t): .outreach(t.id)
        case .employer(let r): .employer(r.id)
        case .possiblySent(let m): .possiblySent(m.id)
        }
    }

    var id: Key { key }
}

extension InboxModel {
    /// Replies that need you: unread replies to your emails, employer replies with a suggested
    /// move, and emails that may not have gone out. Newest first within each kind.
    var replyItems: [NeedsYouReply] {
        let o = store.outreach
        return o.unreadReplyThreads.map(NeedsYouReply.outreach)
            + o.pendingSuggestions.sorted { $0.receivedAt > $1.receivedAt }.map(NeedsYouReply.employer)
            + o.unknownSends.map(NeedsYouReply.possiblySent)
    }

    var selectedReply: NeedsYouReply? {
        guard let key = selectedReplyKey else { return nil }
        return replyItems.first { $0.key == key }
    }

    func selectReply(_ key: NeedsYouReply.Key) {
        selectedClusterID = nil
        selectedReplyKey = key
        validationMessage = nil
    }

    /// "Stripe · Backend Engineer" for an application id.
    func jobName(applicationID: Int?) -> String? {
        applicationID.flatMap { store.jobs.job(applicationID: $0) }.map(\.displayName)
    }
}

// MARK: - List rows

struct RepliesListSection: View {
    var model: InboxModel

    var body: some View {
        let items = model.replyItems
        if !items.isEmpty {
            HStack(spacing: Space.xs) {
                Image(systemName: "envelope.open").imageScale(.small).foregroundStyle(Palette.textTertiary)
                Text("Replies").eyebrowStyle()
                Spacer()
                Text("\(items.count)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary).monospacedDigit()
            }
            .padding(.horizontal, Space.m)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                ReplyRow(model: model, item: item, isSelected: model.selectedReplyKey == item.key)
                    .onTapGesture { model.selectReply(item.key) }
            }
        }
    }
}

private struct ReplyRow: View {
    var model: InboxModel
    var item: NeedsYouReply
    var isSelected: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Circle().fill(Palette.needsYou).frame(width: 7, height: 7).padding(.top, 5).accessibilityHidden(true)
            Image(systemName: symbol).foregroundStyle(Palette.textSecondary).frame(width: 18).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.bodyEmph).lineLimit(2)
                Text(subtitle).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .selectableRow(isSelected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var symbol: String {
        switch item {
        case .outreach: "envelope.open"
        case .employer: "building.2"
        case .possiblySent: "questionmark.circle"
        }
    }

    private var title: String {
        switch item {
        case .outreach(let t):
            "\(store.outreach.contact(id: t.contactID)?.fullName ?? "Someone") at \(t.company) replied"
        case .employer(let r):
            "\(store.jobs.job(applicationID: r.applicationID)?.company ?? r.sender) wrote: \(r.label.label.lowercased())"
        case .possiblySent(let m):
            "Did this email go out? \(store.outreach.thread(id: m.threadID)?.company ?? "")"
        }
    }

    private var subtitle: String {
        switch item {
        case .outreach(let t):
            store.outreach.latestReply(threadID: t.id).map { "“\(OutboxFormat.snippet($0.body))”" } ?? t.state.label
        case .employer(let r):
            r.suggestedStatus.map { "Suggests moving it to \($0.label) · \(r.subject)" } ?? r.subject
        case .possiblySent(let m):
            "To \(store.outreach.contact(id: store.outreach.thread(id: m.threadID)?.contactID)?.fullName ?? m.toEmail ?? "—") · \(m.subject ?? "")"
        }
    }
}

// MARK: - Panes

struct ReplyPane: View {
    var model: InboxModel
    var item: NeedsYouReply

    var body: some View {
        switch item {
        case .outreach(let t): OutreachReplyPane(thread: t)
        case .employer(let r): EmployerReplyPane(reply: r)
        case .possiblySent(let m): PossiblySentPane(message: m)
        }
    }
}

/// The reply text scrolls; its actions stay pinned under it.
private struct ReplyPaneLayout<Content: View, Actions: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                content()
                    .padding(Space.contentPadding)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: Space.l) { actions() }
                .padding(.horizontal, Space.contentPadding)
                .padding(.vertical, Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Someone answered your email. You reply in Gmail; a board move is only suggested.
private struct OutreachReplyPane: View {
    var thread: OutreachThreadItem
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        let reply = store.outreach.latestReply(threadID: thread.id)
        let contact = store.outreach.contact(id: thread.contactID)
        let gmail = reply?.gmailURL ?? store.outreach.lastSent(threadID: thread.id)?.gmailURL
        ReplyPaneLayout {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Text("\(contact?.fullName ?? "Someone") replied").font(Typography.title2)
                        if let label = reply?.classification.flatMap(ReplyLabel.init(rawValue:)) { Badge(label.label) }
                    }
                    Text([contact?.title, thread.company, reply.map { $0.createdAt.formatted(date: .abbreviated, time: .shortened) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    if let job = model(thread) {
                        Text("About your application: \(job)").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                }
                if let reply {
                    Text(reply.body)
                        .font(Typography.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .well()
                }
                if let move = store.outreach.suggestedMove(threadID: thread.id), let app = thread.applicationID {
                    HStack(spacing: Space.m) {
                        Image(systemName: StatusKind(status: move).symbol).foregroundStyle(StatusKind(status: move).color)
                        Text("This reply suggests moving the application to \(move.label).").font(Typography.body)
                        Spacer()
                        Button("Move to \(move.label)") {
                            run {
                                if await store.setStatus(applicationID: app, status: move) { store.outreach.clearSuggestedMove(threadID: thread.id) }
                            }
                        }
                        .buttonStyle(.secondaryLink)
                        Button("Keep as is") { store.outreach.clearSuggestedMove(threadID: thread.id) }.buttonStyle(.secondaryLink)
                    }
                    .padding(Space.m)
                    .well()
                }
                Text("Answer them in Gmail; AutoApply never replies for you. Any follow-up to them has been stopped.")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Group {
                if let gmail {
                    Button("Open in Gmail") {
                        NSWorkspace.shared.open(gmail)
                        run { _ = await store.markReplyRead(threadID: thread.id) }
                    }
                    .buttonStyle(.primaryPill)
                }
                Button("Mark as read") { run { _ = await store.markReplyRead(threadID: thread.id) } }
                    .buttonStyle(.secondaryLink)
                Button("Open in Cold Email") {
                    store.router.go(.coldEmail)
                    ColdEmailModel.shared(for: store).open(threadID: thread.id)
                }
                .buttonStyle(.secondaryLink)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy || !store.isConnected)
        }
    }

    private func model(_ thread: OutreachThreadItem) -> String? {
        thread.applicationID.flatMap { store.jobs.job(applicationID: $0) }.map(\.displayName)
    }

    private func run(_ op: @escaping () async -> Void) {
        busy = true
        Task {
            await op()
            busy = false
        }
    }
}

/// An employer or its application site wrote about an application; the agent suggests a move.
private struct EmployerReplyPane: View {
    var reply: ApplicationReplyItem
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        let job = store.jobs.job(applicationID: reply.applicationID)
        ReplyPaneLayout {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Text("\(job?.company ?? reply.sender) wrote about your application").font(Typography.title2)
                        Badge(reply.label.label)
                    }
                    if let job { Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary) }
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    ColdEmailFact("From", reply.fromName.map { "\($0) <\(reply.fromEmail)>" } ?? reply.fromEmail)
                    ColdEmailFact("Subject", reply.subject)
                    ColdEmailFact("Received", reply.receivedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Text(reply.snippet)
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .well()
                if let move = reply.suggestedStatus {
                    HStack(spacing: Space.s) {
                        Image(systemName: StatusKind(status: move).symbol).foregroundStyle(StatusKind(status: move).color)
                        Text("Suggested: move it from \((job?.status ?? .applied).label) to \(move.label). Nothing changes unless you accept.")
                            .font(Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } actions: {
            Group {
                if let move = reply.suggestedStatus {
                    Button("Move to \(move.label)") { run { _ = await store.acceptReplySuggestion(reply) } }
                        .buttonStyle(.primaryPill)
                }
                Button("Keep as is") { run { _ = await store.dismissReplySuggestion(reply) } }
                    .buttonStyle(.secondaryLink)
                    .help("Leave it where it is in Pipeline. The email still counts as hearing back.")
                if let url = reply.gmailURL {
                    Button("Open in Gmail") { NSWorkspace.shared.open(url) }.buttonStyle(.secondaryLink)
                }
                if let job {
                    Button("Open job") { store.router.go(.pipeline); store.router.openJob(id: job.id) }.buttonStyle(.secondaryLink)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy || !store.isConnected)
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

/// An email the agent may or may not have sent (it stopped mid-send).
private struct PossiblySentPane: View {
    var message: OutreachMessageItem
    @Environment(AppStore.self) private var store

    var body: some View {
        let thread = store.outreach.thread(id: message.threadID)
        let contact = store.outreach.contact(id: thread?.contactID)
        ReplyPaneLayout {
            VStack(alignment: .leading, spacing: Space.l) {
                Text("We may not have sent this email").font(Typography.title2)
                VStack(alignment: .leading, spacing: Space.xs) {
                    ColdEmailFact("To", [contact?.fullName, message.toEmail].compactMap { $0 }.joined(separator: " · "))
                    ColdEmailFact("Company", thread?.company ?? "—")
                    ColdEmailFact("Subject", message.subject ?? "—")
                }
                Text(message.body)
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(8)
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .well()
            }
        } actions: {
            PossiblySentControls(message: message)
        }
    }
}
