// OutreachStore.swift — cold outreach and employer replies, read from the DB (OutreachData,
// application_replies) with lookups the screens need, plus the live event reducer
// (outreach_state / outreach_reply / scout_finished / application_reply). The DB always wins:
// every repository emission replaces optimistic edits.
import Foundation
import Observation

/// Where an applied job stands on outreach (Cold Email ▸ Follow-ups, the job card envelope).
enum FollowUpStatus: Equatable, Sendable {
    case noContact
    case scouting
    case contactsFound(Int)
    case draft
    case scheduled
    case emailed
    case replied
    case closed

    var label: String {
        switch self {
        case .noContact: "No contact yet"
        case .scouting: "Finding people…"
        case .contactsFound(let n): n == 1 ? "1 person found" : "\(n) people found"
        case .draft: "Draft ready for review"
        case .scheduled: "Scheduled"
        case .emailed: "Emailed"
        case .replied: "Replied"
        case .closed: "Closed"
        }
    }

    var symbol: String {
        switch self {
        case .noContact: "person.crop.circle.badge.questionmark"
        case .scouting: "magnifyingglass"
        case .contactsFound: "person.2"
        case .draft: "square.and.pencil"
        case .scheduled: "clock"
        case .emailed: "envelope"
        case .replied: "envelope.open.fill"
        case .closed: "envelope.badge"
        }
    }
}

@MainActor
@Observable
final class OutreachStore {
    private(set) var data = OutreachData()
    private(set) var replies: [ApplicationReplyItem] = []
    /// False until the first DB emission (screens show their loading state).
    private(set) var isLoaded = false
    private(set) var repliesLoaded = false
    /// Companies with a scout running that the user started (cleared by `scout_finished`).
    private(set) var scouting: Set<Int> = []
    /// The last scout result per company (this session).
    private(set) var lastScout: [Int: ScoutFinishedPayload] = [:]
    /// Board moves suggested by `outreach_reply` events, per thread, until the DB row (v12
    /// `outreach_threads.suggested_status`) arrives. Only ever a suggestion.
    private(set) var replyMoves: [Int: BoardStatus] = [:]

    // Indexes, rebuilt on every change.
    @ObservationIgnored private var contactIndex: [Int: ContactItem] = [:]
    @ObservationIgnored private var threadIndex: [Int: OutreachThreadItem] = [:]
    @ObservationIgnored private var messageIndex: [Int: OutreachMessageItem] = [:]
    @ObservationIgnored private var messagesByThread: [Int: [OutreachMessageItem]] = [:]
    @ObservationIgnored private var threadsByApplication: [Int: [OutreachThreadItem]] = [:]
    @ObservationIgnored private var contactsByCompany: [Int: [ContactItem]] = [:]

    init() {}

    // MARK: Loading

    func replace(_ new: OutreachData) {
        data = new
        isLoaded = true
        reindex()
    }

    func replaceReplies(_ new: [ApplicationReplyItem]) {
        replies = new
        repliesLoaded = true
    }

    private func reindex() {
        contactIndex = Dictionary(data.contacts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        threadIndex = Dictionary(data.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        messageIndex = Dictionary(data.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        messagesByThread = Dictionary(grouping: data.messages, by: \.threadID).mapValues { $0.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) } }
        threadsByApplication = Dictionary(grouping: data.threads.filter { $0.applicationID != nil }, by: { $0.applicationID! })
            .mapValues { $0.sorted { $0.updatedAt > $1.updatedAt } }
        contactsByCompany = Dictionary(grouping: data.contacts.filter { $0.companyID != nil }, by: { $0.companyID! })
            .mapValues { $0.sorted { ($0.hasEmail ? $0.emailConfidence : -1, $0.id) > ($1.hasEmail ? $1.emailConfidence : -1, $1.id) } }
    }

    // MARK: Lookups

    var mailAccount: MailAccountInfo { data.mailAccount }
    var sendEnabled: Bool { data.mailAccount.sendEnabled }

    func contact(id: Int?) -> ContactItem? { id.flatMap { contactIndex[$0] } }
    func thread(id: Int?) -> OutreachThreadItem? { id.flatMap { threadIndex[$0] } }
    func message(id: Int?) -> OutreachMessageItem? { id.flatMap { messageIndex[$0] } }
    func messages(threadID: Int) -> [OutreachMessageItem] { messagesByThread[threadID] ?? [] }

    /// Contacts at a company, best email first (no email last).
    func contacts(companyID: Int) -> [ContactItem] { contactsByCompany[companyID] ?? [] }
    func bestContact(companyID: Int) -> ContactItem? { contacts(companyID: companyID).first }

    /// The application's conversations, newest first (discarded ones excluded).
    func threads(applicationID: Int?) -> [OutreachThreadItem] {
        guard let applicationID else { return [] }
        return (threadsByApplication[applicationID] ?? []).filter { $0.state != .cancelled }
    }

    func primaryThread(applicationID: Int?) -> OutreachThreadItem? { threads(applicationID: applicationID).first }

    /// The newest inbound message in a thread (the reply to show).
    func latestReply(threadID: Int) -> OutreachMessageItem? {
        messages(threadID: threadID).last { $0.isInbound && $0.classification != "bounce" } ?? messages(threadID: threadID).last(where: \.isInbound)
    }

    /// The open draft of a thread, if any.
    func openDraft(threadID: Int) -> OutreachMessageItem? {
        messages(threadID: threadID).last { !$0.isInbound && $0.state == .draft }
    }

    /// The last email that went out in a thread (for Gmail links).
    func lastSent(threadID: Int) -> OutreachMessageItem? {
        messages(threadID: threadID).last { !$0.isInbound && $0.state == .sent }
    }

    // MARK: Outbox sections

    private func isLive(_ m: OutreachMessageItem) -> Bool {
        guard let t = thread(id: m.threadID) else { return true }
        return t.state != .cancelled
    }

    /// Drafts waiting for the user's review, newest first.
    var drafts: [OutreachMessageItem] {
        data.messages.filter { !$0.isInbound && $0.state == .draft && isLive($0) }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    /// Approved and waiting for their send time (or being sent right now), soonest first.
    var scheduled: [OutreachMessageItem] {
        data.messages.filter { !$0.isInbound && [.approved, .scheduled, .sending].contains($0.state) }
            .sorted { ($0.sendAt ?? .distantFuture, $0.id) < ($1.sendAt ?? .distantFuture, $1.id) }
    }

    /// Sent emails, newest first.
    var sent: [OutreachMessageItem] {
        data.messages.filter { !$0.isInbound && $0.state == .sent }.sorted { ($0.sentAt ?? $0.updatedAt) > ($1.sentAt ?? $1.updatedAt) }
    }

    /// Emails that may or may not have gone out (crash during sending). Never resent automatically.
    var unknownSends: [OutreachMessageItem] { data.messages.filter { !$0.isInbound && $0.state == .unknown } }

    /// Emails that failed before sending (definitely not sent).
    var failedSends: [OutreachMessageItem] { data.messages.filter { !$0.isInbound && $0.state == .failed } }

    /// Conversations with an inbound message (replies, auto-replies, bounces), unread first.
    var replyThreads: [OutreachThreadItem] {
        let withInbound = Set(data.messages.filter(\.isInbound).map(\.threadID))
        return data.threads.filter { withInbound.contains($0.id) || $0.unreadReply }
            .sorted { ($0.unreadReply ? 1 : 0, $0.updatedAt) > ($1.unreadReply ? 1 : 0, $1.updatedAt) }
    }

    var unreadReplyThreads: [OutreachThreadItem] {
        data.threads.filter(\.unreadReply).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Employer replies whose suggested board move waits for Accept / Dismiss.
    var pendingSuggestions: [ApplicationReplyItem] { replies.filter(\.isPendingSuggestion) }

    /// Employer emails not read yet that need no decision (e.g. "we received your application").
    var unreadEmployerNotes: [ApplicationReplyItem] { replies.filter(\.isUnreadNote) }

    func pendingSuggestion(applicationID: Int?) -> ApplicationReplyItem? {
        guard let applicationID else { return nil }
        return replies.first { $0.applicationID == applicationID && $0.isPendingSuggestion }
    }

    /// The newest employer reply on an application (evidence it heard back).
    func latestReply(applicationID: Int?) -> ApplicationReplyItem? {
        guard let applicationID else { return nil }
        return replies.filter { $0.applicationID == applicationID }.max { $0.receivedAt < $1.receivedAt }
    }

    var draftCount: Int { drafts.count }
    var unreadReplyCount: Int { data.threads.reduce(0) { $0 + ($1.unreadReply ? 1 : 0) } }
    var unknownCount: Int { unknownSends.count }
    var pendingSuggestionCount: Int { replies.reduce(0) { $0 + ($1.isPendingSuggestion ? 1 : 0) } }
    /// Matches the engine's Counts.application_replies_unread: unread or a pending suggestion.
    var employerRepliesNeedingYou: Int { replies.reduce(0) { $0 + ($1.isPendingSuggestion || $1.readAt == nil ? 1 : 0) } }

    /// Outreach status of an applied job.
    func followUpStatus(for job: JobItem) -> FollowUpStatus {
        if let thread = primaryThread(applicationID: job.applicationID) {
            switch thread.state {
            case .replied: return .replied
            case .bounced, .optedOut, .closed: return .closed
            case .active:
                return messages(threadID: thread.id).contains { !$0.isInbound && [.approved, .scheduled, .sending].contains($0.state) }
                    ? .scheduled : .emailed
            case .draft:
                let ms = messages(threadID: thread.id)
                if ms.contains(where: { !$0.isInbound && [.approved, .scheduled, .sending].contains($0.state) }) { return .scheduled }
                if ms.contains(where: { !$0.isInbound && $0.state == .draft }) { return .draft }
            case .cancelled: break
            }
        }
        if scouting.contains(job.companyID) { return .scouting }
        let n = contacts(companyID: job.companyID).count
        return n > 0 ? .contactsFound(n) : .noContact
    }

    /// Prospects not dismissed, best fit first.
    var activeProspects: [ProspectItem] { data.prospects.filter { $0.status != .dismissed } }

    /// Referrals grouped by state in display order (dismissed hidden), each group newest first.
    var referralGroups: [(state: ReferralState, items: [ReferralItem])] {
        let groups = Dictionary(grouping: data.referrals, by: \.state)
        return ReferralState.displayOrder.compactMap { state in
            guard let items = groups[state], !items.isEmpty else { return nil }
            return (state, items.sorted { $0.stateUpdatedAt > $1.stateUpdatedAt })
        }
    }

    func referral(id: Int) -> ReferralItem? { data.referrals.first { $0.id == id } }
    func prospect(id: Int?) -> ProspectItem? { id.flatMap { pid in data.prospects.first { $0.id == pid } } }

    // MARK: Event reducer

    func apply(_ event: DaemonEvent) {
        switch event {
        case .outreachState(let p):
            if p.entity == .message, let mid = p.messageId, let state = OutreachMessageState(rawValue: p.toState) {
                mutateMessage(mid) { $0.state = state }
            } else if p.entity == .thread, let state = OutreachThreadState(rawValue: p.toState) {
                mutateThread(p.threadId) { $0.state = state }
            }
        case .outreachReply(let p):
            guard p.label != .ooo else { return }
            mutateThread(p.threadId) { t in
                switch p.label {
                case .bounce: t.state = .bounced
                case .optOut: t.state = .optedOut
                default: t.state = .replied
                }
                t.unreadReply = true
                t.updatedAt = Date()
            }
            if let status = p.suggestedStatus, p.applicationId != nil { replyMoves[p.threadId] = status }
        case .scoutFinished(let p):
            scouting.remove(p.companyId)
            lastScout[p.companyId] = p
        case .applicationReply(let p):
            guard !replies.contains(where: { $0.id == p.replyId }) else { return }
            let state: ApplicationReplyItem.SuggestionState = (p.suggestedStatus != nil && !p.ambiguous) ? .pending : .none
            replies.insert(ApplicationReplyItem(id: p.replyId, applicationID: p.applicationId, messageID: p.messageId,
                                                fromEmail: p.fromEmail, fromName: p.fromName, subject: p.subject, snippet: p.snippet,
                                                receivedAt: p.receivedAt, label: p.label, suggestedStatus: p.suggestedStatus,
                                                suggestionState: state, ambiguous: p.ambiguous), at: 0)
        default:
            break
        }
    }

    // MARK: Optimistic edits (overwritten by the next DB emission)

    func mutateMessage(_ id: Int, _ body: (inout OutreachMessageItem) -> Void) {
        guard let i = data.messages.firstIndex(where: { $0.id == id }) else { return }
        body(&data.messages[i])
        reindex()
    }

    func mutateThread(_ id: Int, _ body: (inout OutreachThreadItem) -> Void) {
        guard let i = data.threads.firstIndex(where: { $0.id == id }) else { return }
        body(&data.threads[i])
        reindex()
    }

    func mutateReferral(_ id: Int, _ body: (inout ReferralItem) -> Void) {
        guard let i = data.referrals.firstIndex(where: { $0.id == id }) else { return }
        body(&data.referrals[i])
    }

    func mutateProspect(_ id: Int, _ body: (inout ProspectItem) -> Void) {
        guard let i = data.prospects.firstIndex(where: { $0.id == id }) else { return }
        body(&data.prospects[i])
    }

    func mutateReply(_ id: Int, _ body: (inout ApplicationReplyItem) -> Void) {
        guard let i = replies.firstIndex(where: { $0.id == id }) else { return }
        body(&replies[i])
    }

    /// The board move a reply suggested for this thread's application, if any (this session).
    func suggestedMove(threadID: Int) -> BoardStatus? {
        guard let thread = thread(id: threadID), thread.applicationID != nil else { return nil }
        if thread.suggestionPending, let stored = thread.suggestedStatus { return stored }
        return replyMoves[threadID]
    }

    func clearSuggestedMove(threadID: Int) { replyMoves.removeValue(forKey: threadID) }

    func setSendEnabled(_ on: Bool) { data.mailAccount.sendEnabled = on }

    func removeContact(_ id: Int) -> ContactItem? {
        guard let i = data.contacts.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = data.contacts.remove(at: i)
        reindex()
        return removed
    }

    func restoreContact(_ contact: ContactItem) {
        guard !data.contacts.contains(where: { $0.id == contact.id }) else { return }
        data.contacts.append(contact)
        reindex()
    }

    func removeSuppression(_ id: Int) -> SuppressionItem? {
        guard let i = data.suppression.firstIndex(where: { $0.id == id }) else { return nil }
        return data.suppression.remove(at: i)
    }

    func restoreSuppression(_ item: SuppressionItem) {
        guard !data.suppression.contains(where: { $0.id == item.id }) else { return }
        data.suppression.insert(item, at: 0)
    }

    func beginScouting(companyID: Int) { scouting.insert(companyID) }
    func endScouting(companyID: Int) { scouting.remove(companyID) }
}
