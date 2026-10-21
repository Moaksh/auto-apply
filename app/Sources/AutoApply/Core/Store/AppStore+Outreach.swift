// AppStore+Outreach.swift — cold-outreach and employer-reply commands (contract/protocol.md
// §5.1–5.2) with the same optimistic / rollback / toast rules as AppStore+Commands.swift.
// Nothing is ever sent without `approve_outreach`, which only runs from an explicit click.
import Foundation

/// The per-problem message ids of an `approve_outreach` conflict (error `details`).
struct OutreachConflicts: Equatable, Sendable {
    var ungrounded: [Int] = []
    var lowConfidence: [Int] = []
    var doNotContact: [Int] = []
    var threadClosed: [Int] = []

    init(ungrounded: [Int] = [], lowConfidence: [Int] = [], doNotContact: [Int] = [], threadClosed: [Int] = []) {
        self.ungrounded = ungrounded
        self.lowConfidence = lowConfidence
        self.doNotContact = doNotContact
        self.threadClosed = threadClosed
    }

    init(details: [String: JSONValue]?) {
        func ids(_ key: String) -> [Int] {
            guard case .array(let items)? = details?[key] else { return [] }
            return items.compactMap { if case .int(let i) = $0 { i } else { nil } }
        }
        self.init(ungrounded: ids("ungrounded"), lowConfidence: ids("low_confidence"), doNotContact: ids("do_not_contact"),
                  threadClosed: ids("thread_closed"))
    }

    var isEmpty: Bool { ungrounded.isEmpty && lowConfidence.isEmpty && doNotContact.isEmpty && threadClosed.isEmpty }
    var all: Set<Int> { Set(ungrounded + lowConfidence + doNotContact + threadClosed) }
    /// Only low-confidence addresses can be sent anyway; every other problem needs a fix first.
    var onlyLowConfidence: Bool { !lowConfidence.isEmpty && ungrounded.isEmpty && doNotContact.isEmpty && threadClosed.isEmpty }
}

/// What `approve_outreach` scheduled: when each email goes out, and how many per day.
struct OutreachSchedule: Equatable, Sendable {
    struct Day: Equatable, Sendable { var date: String; var count: Int }
    var batchUID: String
    var sendAt: [Int: Date]
    var days: [Day]

    /// "6 today, 4 tomorrow" style summary.
    func summary(now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let parts = days.map { day -> String in
            guard let date = f.date(from: day.date) else { return "\(day.count) on \(day.date)" }
            if calendar.isDate(date, inSameDayAs: now) { return "\(day.count) today" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
                return "\(day.count) tomorrow"
            }
            return "\(day.count) on \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        }
        return parts.joined(separator: ", ")
    }
}

enum ApproveOutreachResult: Equatable, Sendable {
    case scheduled(OutreachSchedule)
    /// The daemon refused part of the batch; nothing was scheduled.
    case conflicts(OutreachConflicts, message: String)
    case failed(String)
}

/// `draft_outreach` / `edit_outreach_draft`: the fact-check verdict.
struct DraftCheck: Decodable, Equatable, Sendable {
    var threadId: Int?
    var messageId: Int?
    var grounded: Bool
    var unsupportedClaims: [String]

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id", messageId = "message_id", grounded, unsupportedClaims = "unsupported_claims"
    }

    init(threadId: Int? = nil, messageId: Int? = nil, grounded: Bool, unsupportedClaims: [String]) {
        self.threadId = threadId
        self.messageId = messageId
        self.grounded = grounded
        self.unsupportedClaims = unsupportedClaims
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try c.decodeIfPresent(Int.self, forKey: .threadId)
        messageId = try c.decodeIfPresent(Int.self, forKey: .messageId)
        grounded = try c.decodeIfPresent(Bool.self, forKey: .grounded) ?? true
        unsupportedClaims = try c.decodeIfPresent([String].self, forKey: .unsupportedClaims) ?? []
    }
}

struct EnableSendingResult: Decodable, Equatable, Sendable {
    var sendEnabled: Bool
    var testSentTo: String?
    enum CodingKeys: String, CodingKey { case sendEnabled = "send_enabled", testSentTo = "test_sent_to" }
}

struct ImportContactsResult: Decodable, Equatable, Sendable {
    var added: Int
    var merged: Int
    var skipped: Int
}

struct ReferralDraft: Decodable, Equatable, Sendable {
    var connectNote: String?
    var referralDm: String?
    var grounded: Bool
    var unsupportedClaims: [String]
    enum CodingKeys: String, CodingKey {
        case connectNote = "connect_note", referralDm = "referral_dm", grounded, unsupportedClaims = "unsupported_claims"
    }
}

extension AppStore {
    /// Model work (drafting, the test email) can take a while.
    static let outreachSlowTimeout: Duration = .seconds(90)

    /// The daemon's message for the most recent failed command, in plain words.
    var lastOutreachErrorMessage: String {
        switch lastCommandError {
        case .daemon(let p)?: p.message.prefix(1).uppercased() + p.message.dropFirst()
        case .timeout?: "The agent didn't answer in time. Try again."
        case .notConnected?: "Can't reach the agent."
        case let other?: other.errorDescription ?? "Something went wrong."
        case nil: "Something went wrong."
        }
    }

    // MARK: Sending

    /// The only path to sending: schedule the user's approved drafts. A conflict (ungrounded,
    /// below the confidence bar, do-not-contact, closed thread) schedules nothing and comes back
    /// per message, so the sheet can show what to fix.
    func approveOutreach(messageIDs: [Int], includeFollowups: Bool, sendAnyway: [Int] = []) async -> ApproveOutreachResult {
        guard !messageIDs.isEmpty else { return .failed("Pick at least one draft.") }
        let payload = ApproveOutreachPayload(messageIds: messageIDs, includeFollowups: includeFollowups, sendAnyway: sendAnyway)
        switch await perform(.approveOutreach(payload), timeout: .seconds(10), silent: true) {
        case .success(let reply):
            guard case .ack(let ack) = reply.event else { return .failed("Unexpected reply from the agent.") }
            let schedule = Self.decodeSchedule(ack.result ?? [:])
            outreach.performBatch {
                for id in messageIDs {
                    outreach.mutateMessage(id) { $0.state = .scheduled; $0.sendAt = schedule.sendAt[id] ?? $0.sendAt }
                }
            }
            let summary = schedule.summary()
            toasts.show(summary.isEmpty ? "Scheduled" : "Scheduled · \(summary)", symbol: "clock", style: .success, duration: .seconds(3))
            return .scheduled(schedule)
        case .failure(.daemon(let p)) where p.code == .conflict:
            let conflicts = OutreachConflicts(details: p.details)
            if conflicts.isEmpty { return .failed(lastOutreachErrorMessage) }
            return .conflicts(conflicts, message: lastOutreachErrorMessage)
        case .failure:
            return .failed(lastOutreachErrorMessage)
        }
    }

    static func decodeSchedule(_ result: [String: JSONValue]) -> OutreachSchedule {
        var sendAt: [Int: Date] = [:]
        if case .array(let items)? = result["scheduled"] {
            for case .object(let o) in items {
                if case .int(let id)? = o["message_id"], case .string(let at)? = o["send_at"], let date = ProtocolCoding.parseDate(at) {
                    sendAt[id] = date
                }
            }
        }
        var days: [OutreachSchedule.Day] = []
        if case .array(let items)? = result["days"] {
            for case .object(let o) in items {
                if case .string(let d)? = o["date"], case .int(let n)? = o["count"] { days.append(.init(date: d, count: n)) }
            }
        }
        var batch = ""
        if case .string(let b)? = result["batch_uid"] { batch = b }
        return OutreachSchedule(batchUID: batch, sendAt: sendAt, days: days)
    }

    /// Scheduled → back to draft (nothing is sent).
    @discardableResult
    func cancelOutreach(messageIDs: [Int]) async -> Bool {
        let previous = messageIDs.compactMap { id in outreach.message(id: id).map { (id, $0.state, $0.sendAt) } }
        let result = await perform(
            .cancelOutreach(CancelOutreachPayload(messageIds: messageIDs)),
            optimistic: { [outreach] in for id in messageIDs { outreach.mutateMessage(id) { $0.state = .draft; $0.sendAt = nil } } },
            rollback: { [outreach] in for (id, state, at) in previous { outreach.mutateMessage(id) { $0.state = state; $0.sendAt = at } } })
        guard case .success = result else { return false }
        toasts.show(messageIDs.count == 1 ? "Cancelled · back in Drafts" : "Cancelled \(messageIDs.count) · back in Drafts",
                    symbol: "arrow.uturn.backward", style: .info)
        return true
    }

    /// Discard a conversation before anything was sent.
    @discardableResult
    func discardOutreach(threadID: Int) async -> Bool {
        let previous = outreach.thread(id: threadID)?.state
        let result = await perform(
            .discardOutreach(DiscardOutreachPayload(threadId: threadID)),
            optimistic: { [outreach] in outreach.mutateThread(threadID) { $0.state = .cancelled } },
            rollback: { [outreach] in if let previous { outreach.mutateThread(threadID) { $0.state = previous } } })
        if case .success = result { return true }
        return false
    }

    /// "It was sent" / "It wasn't sent" for an email in the `unknown` state. Never resent automatically.
    @discardableResult
    func resolveOutreachUnknown(messageID: Int, sent: Bool) async -> Bool {
        let result = await perform(
            .resolveOutreachUnknown(ResolveOutreachUnknownPayload(messageId: messageID, sent: sent)),
            optimistic: { [outreach] in outreach.mutateMessage(messageID) { $0.state = sent ? .sent : .failed } },
            rollback: { [outreach] in outreach.mutateMessage(messageID) { $0.state = .unknown } })
        if case .success = result { return true }
        return false
    }

    /// Turn sending on (a test email to yourself must go through first) or off.
    func enableSending(_ on: Bool) async -> EnableSendingResult? {
        guard let result = await performResult(.enableSending(EnableSendingPayload(enabled: on)), as: EnableSendingResult.self,
                                               timeout: Self.outreachSlowTimeout, silent: true) else { return nil }
        outreach.setSendEnabled(result.sendEnabled)
        return result
    }

    // MARK: Drafts

    /// Ask the agent for a (re)draft to `contactID`. Switching contact re-drafts the thread.
    func draftOutreach(contactID: Int, kind: OutreachKind, applicationID: Int? = nil, instructions: String? = nil) async -> DraftCheck? {
        await performResult(.draftOutreach(DraftOutreachPayload(contactId: contactID, kind: kind, applicationId: applicationID,
                                                                instructions: instructions.c3Trimmed)),
                            as: DraftCheck.self, timeout: Self.outreachSlowTimeout)
    }

    /// Save edits; the daemon re-checks the claims. `confirmClaims` = "These are true".
    func editOutreachDraft(messageID: Int, subject: String?, body: String, confirmClaims: Bool = false) async -> DraftCheck? {
        let previous = outreach.message(id: messageID)
        outreach.mutateMessage(messageID) { m in
            m.body = body
            if let subject { m.subject = subject }
            m.origin = "user"
        }
        guard let check = await performResult(.editOutreachDraft(EditOutreachDraftPayload(messageId: messageID, subject: subject, body: body,
                                                                                          confirmClaims: confirmClaims)),
                                              as: DraftCheck.self, timeout: Self.outreachSlowTimeout) else {
            if let previous { outreach.mutateMessage(messageID) { $0 = previous } }
            return nil
        }
        outreach.mutateMessage(messageID) { m in
            m.grounded = check.grounded
            m.unsupportedClaims = check.unsupportedClaims
            if confirmClaims { m.claimsOverridden = true }
        }
        return check
    }

    // MARK: Contacts

    /// Find people at a company (HTTP sources now; Google results when the browser is free).
    @discardableResult
    func scoutContacts(companyID: Int?, applicationID: Int? = nil, purpose: ScoutPurpose = .application) async -> Bool {
        if let companyID { outreach.beginScouting(companyID: companyID) }
        let result = await perform(.scoutContacts(ScoutContactsPayload(companyId: companyID, applicationId: applicationID, purpose: purpose)),
                                   timeout: .seconds(15))
        guard case .success = result else {
            if let companyID { outreach.endScouting(companyID: companyID) }
            return false
        }
        toasts.show("Looking for people · results show up here as they're found", symbol: "magnifyingglass", style: .info, duration: .seconds(3))
        return true
    }

    func addContact(_ payload: AddContactPayload) async -> Int? {
        struct Reply: Decodable { var contactId: Int; var merged: Bool
            enum CodingKeys: String, CodingKey { case contactId = "contact_id", merged } }
        guard let reply = await performResult(.addContact(payload), as: Reply.self, timeout: .seconds(10)) else { return nil }
        toasts.show(reply.merged ? "Merged with an existing contact" : "Added \(payload.fullName)", symbol: "person.badge.plus", style: .success)
        return reply.contactId
    }

    @discardableResult
    func updateContact(_ payload: UpdateContactPayload) async -> Bool {
        if case .success = await perform(.updateContact(payload)) { return true }
        return false
    }

    /// Delete a contact; with `suppress` the address also goes on the do-not-contact list.
    @discardableResult
    func deleteContact(id: Int, suppress: Bool) async -> Bool {
        var removed: ContactItem?
        let result = await perform(
            .deleteContact(DeleteContactPayload(id: id, suppress: suppress)),
            optimistic: { [outreach] in removed = outreach.removeContact(id) },
            rollback: { [outreach] in if let removed { outreach.restoreContact(removed) } })
        if case .success = result { return true }
        return false
    }

    func importContacts(filePath: String) async -> ImportContactsResult? {
        guard let r = await performResult(.importContacts(ImportContactsPayload(filePath: filePath)), as: ImportContactsResult.self,
                                          timeout: .seconds(30)) else { return nil }
        toasts.show("Imported \(r.added) · merged \(r.merged) · skipped \(r.skipped)", symbol: "tray.and.arrow.down", style: .success,
                    duration: .seconds(3))
        return r
    }

    // MARK: Do-not-contact

    @discardableResult
    func suppress(email: String? = nil, domain: String? = nil, reason: SuppressionReason = .user) async -> Bool {
        let result = await perform(.suppress(SuppressPayload(email: email.c3Trimmed, domain: domain.c3Trimmed, reason: reason)))
        guard case .success = result else { return false }
        toasts.show("Won't email \(email ?? domain.map { "anyone at \($0)" } ?? "them")", symbol: "hand.raised", style: .info)
        return true
    }

    /// Remove an entry. Opt-outs can't be removed (the daemon refuses with `conflict`).
    @discardableResult
    func unsuppress(_ item: SuppressionItem) async -> Bool {
        guard item.isRemovable else {
            toasts.show("They asked not to be emailed, so this stays on the list.", symbol: "hand.raised", style: .info, duration: .seconds(3))
            return false
        }
        var removed: SuppressionItem?
        let result = await perform(
            .unsuppress(UnsuppressPayload(email: item.emailNorm, domain: item.emailNorm == nil ? item.domain : nil)),
            optimistic: { [outreach] in removed = outreach.removeSuppression(item.id) },
            rollback: { [outreach] in if let removed { outreach.restoreSuppression(removed) } })
        if case .success = result { return true }
        return false
    }

    // MARK: Replies

    @discardableResult
    func markReplyRead(threadID: Int) async -> Bool {
        let result = await perform(.markReplyRead(MarkReplyReadPayload(threadId: threadID)),
                                   optimistic: { [outreach] in outreach.mutateThread(threadID) { $0.unreadReply = false } },
                                   rollback: { [outreach] in outreach.mutateThread(threadID) { $0.unreadReply = true } })
        if case .success = result { return true }
        return false
    }

    @discardableResult
    func setThreadOutcome(threadID: Int, outcome: ThreadOutcome?, close: Bool) async -> Bool {
        let previous = outreach.thread(id: threadID)
        let result = await perform(
            .setThreadOutcome(SetThreadOutcomePayload(threadId: threadID, outcome: outcome, close: close)),
            optimistic: { [outreach] in outreach.mutateThread(threadID) { t in t.outcome = outcome; if close { t.state = .closed } } },
            rollback: { [outreach] in if let previous { outreach.mutateThread(threadID) { $0 = previous } } })
        if case .success = result { return true }
        return false
    }

    /// Apply an employer reply's suggested board move (the board never moves by itself).
    @discardableResult
    func acceptReplySuggestion(_ reply: ApplicationReplyItem) async -> Bool {
        let job = jobs.job(applicationID: reply.applicationID)
        let previousStatus = job?.status
        let previousState = outreach.replies.first { $0.id == reply.id }?.suggestionState ?? reply.suggestionState
        let target = reply.suggestedStatus
        let result = await perform(
            .acceptReplySuggestion(AcceptReplySuggestionPayload(replyId: reply.id)),
            optimistic: { [outreach, jobs] in
                outreach.mutateReply(reply.id) { $0.suggestionState = .accepted }
                if let target { jobs.mutate(applicationID: reply.applicationID) { $0.status = target; $0.statusUpdatedAt = Date() } }
            },
            rollback: { [outreach, jobs] in
                outreach.mutateReply(reply.id) { $0.suggestionState = previousState }
                if target != nil { jobs.mutate(applicationID: reply.applicationID) { $0.status = previousStatus } }
            })
        guard case .success = result else { return false }
        if let target { toasts.show("Moved to \(target.label)", symbol: StatusKind(status: target).symbol, style: .success) }
        return true
    }

    /// Keep the board as it is; the reply still counts as "heard back".
    @discardableResult
    func dismissReplySuggestion(_ reply: ApplicationReplyItem) async -> Bool {
        let previousState = outreach.replies.first { $0.id == reply.id }?.suggestionState ?? reply.suggestionState
        let result = await perform(
            .dismissReplySuggestion(DismissReplySuggestionPayload(replyId: reply.id)),
            optimistic: { [outreach] in outreach.mutateReply(reply.id) { $0.suggestionState = .dismissed } },
            rollback: { [outreach] in outreach.mutateReply(reply.id) { $0.suggestionState = previousState } })
        if case .success = result { return true }
        return false
    }

    // MARK: Prospects

    @discardableResult
    func searchProspects(query: String, location: String?) async -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let result = await perform(.searchProspects(SearchProspectsPayload(query: q, location: location.c3Trimmed)), timeout: .seconds(10))
        guard case .success = result else { return false }
        toasts.show("Searching when the browser is free · companies appear here", symbol: "magnifyingglass", style: .info, duration: .seconds(3))
        return true
    }

    @discardableResult
    func addProspect(name: String?, url: String?) async -> Bool {
        let result = await perform(.addProspect(AddProspectPayload(companyName: name.c3Trimmed, url: url.c3Trimmed)), timeout: .seconds(15))
        guard case .success = result else { return false }
        toasts.show("Added · reading their site in the background", symbol: "building.2", style: .success)
        return true
    }

    @discardableResult
    func updateProspect(id: Int, status: ProspectStatus?, watch: Bool = false) async -> Bool {
        let previous = outreach.prospect(id: id)
        let result = await perform(
            .updateProspect(UpdateProspectPayload(id: id, status: status, watch: watch)),
            optimistic: { [outreach] in outreach.mutateProspect(id) { p in if let status { p.status = status }; if watch { p.watched = true } } },
            rollback: { [outreach] in if let previous { outreach.mutateProspect(id) { $0 = previous } } })
        guard case .success = result else { return false }
        if status == .shortlisted, let companyID = previous?.companyID { outreach.beginScouting(companyID: companyID) }
        if watch, let name = previous?.company { toasts.show("Watching \(name) for new roles", symbol: "eye", style: .info) }
        return true
    }

    // MARK: Referrals

    @discardableResult
    func suggestReferrers(companyID: Int, jobID: Int? = nil) async -> Bool {
        let result = await perform(.suggestReferrers(SuggestReferrersPayload(companyId: companyID, jobId: jobID)), timeout: .seconds(10))
        guard case .success = result else { return false }
        toasts.show("Looking for people who could refer you (Google results only)", symbol: "person.2", style: .info, duration: .seconds(3))
        return true
    }

    func addReferral(_ payload: AddReferralPayload) async -> Int? {
        struct Reply: Decodable { var referralId: Int
            enum CodingKeys: String, CodingKey { case referralId = "referral_id" } }
        return await performResult(.addReferral(payload), as: Reply.self, timeout: .seconds(10))?.referralId
    }

    func draftReferral(id: Int, instructions: String? = nil) async -> ReferralDraft? {
        guard let draft = await performResult(.draftReferral(DraftReferralPayload(id: id, instructions: instructions.c3Trimmed)),
                                              as: ReferralDraft.self, timeout: Self.outreachSlowTimeout) else { return nil }
        outreach.mutateReferral(id) { r in
            r.connectNote = draft.connectNote ?? r.connectNote
            r.referralDM = draft.referralDm ?? r.referralDM
            r.grounded = draft.grounded
            r.unsupportedClaims = draft.unsupportedClaims
        }
        return draft
    }

    @discardableResult
    func updateReferral(id: Int, state: ReferralState? = nil, connectNote: String? = nil, referralDM: String? = nil) async -> Bool {
        let previous = outreach.referral(id: id)
        let result = await perform(
            .updateReferral(UpdateReferralPayload(id: id, state: state, connectNote: connectNote, referralDm: referralDM)),
            optimistic: { [outreach] in
                outreach.mutateReferral(id) { r in
                    if let state { r.state = state; r.stateUpdatedAt = Date() }
                    if let connectNote { r.connectNote = connectNote }
                    if let referralDM { r.referralDM = referralDM }
                }
            },
            rollback: { [outreach] in if let previous { outreach.mutateReferral(id) { $0 = previous } } })
        if case .success = result { return true }
        return false
    }

    // MARK: Providers

    /// Check a provider key and store it in the Keychain (nil removes it). Returns whether it works.
    func setProviderKey(_ provider: SetProviderKeyPayload.Provider, apiKey: String?) async -> Bool? {
        struct Reply: Decodable { var ok: Bool }
        return await performResult(.setProviderKey(SetProviderKeyPayload(provider: provider, apiKey: apiKey.c3Trimmed)), as: Reply.self,
                                   timeout: .seconds(30))?.ok
    }
}

extension OutreachStore {
    /// Group optimistic edits (each mutation reindexes; this keeps the call sites readable).
    func performBatch(_ body: () -> Void) { body() }
}
