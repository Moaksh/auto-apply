// SendBlock.swift — can an application awaiting review be sent now? The agent sends one
// application per company every `per_company_cooldown_days` (Settings ▸ Guardrails), and an
// application whose outcome it isn't sure of (mid-submit, or "unknown_verify") holds the company
// too. This mirrors the engine's `db.review_sendability` from the same columns the app already
// reads (`companies.last_applied_at`, the other applications' state and when it changed), so
// Review can say why and until when *before* the send hold starts, instead of letting a doomed
// Approve run its five seconds and fail (issue #4). The agent still has the final word: its
// `approve` refusal carries the same details (`CompanyHold`, protocol.md §5).
import Foundation

struct SendBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// We applied to this company `since`; this one can go at `resetsAt`.
        case cooldown
        /// Another application here may or may not have gone through (`unknown_verify`): the
        /// user settles it. `inFlight`: it's being sent right now (or on its send hold).
        case unconfirmedAttempt(inFlight: Bool)
        /// Another job at this company is waiting in Review too. Not a block: either can go, but
        /// sending one holds the other until `resetsAt`.
        case sameCompanyInReview
    }

    var kind: Kind
    var companyID: Int
    var company: String
    /// The other job / application involved (the one sent, unsure, or also waiting).
    var otherJobID: Int?
    var otherApplicationID: Int?
    /// When that other attempt happened (nil for a peer still waiting).
    var since: Date?
    /// When this job can be sent (for a peer: if the other one is sent now).
    var resetsAt: Date?

    /// The agent would refuse it now (a waiting peer is only a heads-up).
    var blocksSend: Bool { kind != .sameCompanyInReview }

    /// Needs the user to say whether the other application went through.
    var needsResolution: Bool { kind == .unconfirmedAttempt(inFlight: false) && otherApplicationID != nil }
}

/// A company hold as the agent reports it: an `approve` reply's `held[]`, or the details of its
/// `cap_reached` refusal (protocol.md §5, "company hold").
struct CompanyHoldInfo: Decodable, Sendable, Equatable {
    var applicationId: Int?
    var jobId: Int?
    var kind: String?
    var reason: String?
    var companyId: Int?
    var company: String?
    var since: String?
    var resetsAt: String?
    var otherApplicationId: Int?
    var otherJobId: Int?
    var otherState: String?

    enum CodingKeys: String, CodingKey {
        case applicationId = "application_id", jobId = "job_id", kind, reason, companyId = "company_id", company, since
        case resetsAt = "resets_at", otherApplicationId = "other_application_id", otherJobId = "other_job_id"
        case otherState = "other_state"
    }

    /// The same hold in the app's terms; nil for a refusal that isn't about a company.
    func sendBlock(fallbackCompany: String) -> SendBlock? {
        let k: SendBlock.Kind
        switch kind ?? reason {
        case "cooldown", "company_cooldown": k = .cooldown
        case "unconfirmed_attempt", "company_attempt_unconfirmed": k = .unconfirmedAttempt(inFlight: otherState == "submitting")
        case "same_batch", "company_same_batch": k = .unconfirmedAttempt(inFlight: true)
        default: return nil
        }
        return SendBlock(kind: k, companyID: companyId ?? 0, company: company ?? fallbackCompany, otherJobID: otherJobId,
                         otherApplicationID: otherApplicationId, since: since.flatMap(ProtocolCoding.parseDate),
                         resetsAt: resetsAt.flatMap(ProtocolCoding.parseDate))
    }
}

enum ReviewSendability {
    /// Why `job` (awaiting review) can't be sent now, or a heads-up about a peer, else nil.
    /// `all` is every job the app knows; `heldJobIDs` the approvals on the send hold (they're as
    /// good as sent); `cooldownDays` 0 turns the rule off.
    static func block(for job: JobItem, in all: [JobItem], cooldownDays: Int, heldJobIDs: Set<Int> = [],
                      now: Date = Date()) -> SendBlock? {
        guard cooldownDays > 0 else { return nil }
        let window = TimeInterval(cooldownDays) * 86_400
        let others = all.filter { $0.companyID == job.companyID && $0.id != job.id }
        func block(_ kind: SendBlock.Kind, _ other: JobItem?, since: Date?, resets: Date?) -> SendBlock {
            SendBlock(kind: kind, companyID: job.companyID, company: job.company, otherJobID: other?.id,
                      otherApplicationID: other?.applicationID, since: since, resetsAt: resets)
        }
        // 1. We applied here within the window: the company's own record, exactly what the
        //    agent checks (`companies.last_applied_at`). The other job is the latest one sent.
        if let last = job.companyLastAppliedAt, now.timeIntervalSince(last) < window {
            let lastSent = others.filter { $0.submittedAt != nil }.max { $0.submittedAt! < $1.submittedAt! }
            return block(.cooldown, lastSent, since: last, resets: last.addingTimeInterval(window))
        }
        // 2. Another application here is being sent now (or on its send hold), or may have gone.
        if let sending = others.first(where: { $0.state == .submitting || heldJobIDs.contains($0.id) }) {
            let at = min(sending.stateUpdatedAt ?? now, now)
            return block(.unconfirmedAttempt(inFlight: true), sending, since: at, resets: now.addingTimeInterval(window))
        }
        let unsure = others
            .filter { $0.state == .unknownVerify && now.timeIntervalSince($0.stateUpdatedAt ?? now) < window }
            .max { ($0.stateUpdatedAt ?? .distantPast) < ($1.stateUpdatedAt ?? .distantPast) }
        if let unsure {
            let at = min(unsure.stateUpdatedAt ?? now, now)
            return block(.unconfirmedAttempt(inFlight: false), unsure, since: at, resets: at.addingTimeInterval(window))
        }
        // 3. Heads-up: another job here waits in Review too.
        if let peer = others.first(where: { $0.state == .awaitingReview }) {
            return block(.sameCompanyInReview, peer, since: nil, resets: now.addingTimeInterval(window))
        }
        return nil
    }

    // MARK: Copy (first person: the agent speaking; says what happens next)

    static func day(_ date: Date?) -> String {
        guard let date else { return "later" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The other job's title, when we know it ("your Data Scientist application").
    private static func other(_ block: SendBlock, in all: [JobItem]) -> String {
        guard let id = block.otherJobID, let job = all.first(where: { $0.id == id }), !job.title.isEmpty else {
            return "your \(block.company) application"
        }
        return "your \(block.company) \(job.title) application"
    }

    /// The headline on the ticket / detail: why it can't go and when it can.
    static func message(_ block: SendBlock, in all: [JobItem] = []) -> String {
        switch block.kind {
        case .cooldown:
            return "You applied to \(block.company) on \(day(block.since)). I can send this from \(day(block.resetsAt))."
        case .unconfirmedAttempt(inFlight: true):
            return "I'm sending \(other(block, in: all)) now. If it goes through, this one waits until \(day(block.resetsAt))."
        case .unconfirmedAttempt(inFlight: false):
            return "I'm not sure \(other(block, in: all)) on \(day(block.since)) went through. Tell me, and I'll know whether this one can go."
        case .sameCompanyInReview:
            return "One \(block.company) job at a time: approving this holds the other until \(day(block.resetsAt))."
        }
    }

    /// Short, for a row: "From Nov 11", "Check first", "After the other".
    static func rowLabel(_ block: SendBlock) -> String {
        switch block.kind {
        case .cooldown: "From \(day(block.resetsAt))"
        case .unconfirmedAttempt(inFlight: true): "After the other"
        case .unconfirmedAttempt(inFlight: false): "Check first"
        case .sameCompanyInReview: "1 of 2 here"
        }
    }

    static func rowSymbol(_ block: SendBlock) -> String {
        switch block.kind {
        case .cooldown: "calendar.badge.clock"
        case .unconfirmedAttempt(inFlight: true): "paperplane"
        case .unconfirmedAttempt(inFlight: false): "questionmark.circle"
        case .sameCompanyInReview: "square.on.square"
        }
    }

    /// A toast for jobs the send hold turned away: "I kept Prodigal · ML Engineer in Review: …".
    static func keptToast(_ kept: [(job: JobItem, block: SendBlock)], all: [JobItem]) -> String {
        guard let first = kept.first else { return "" }
        let reason: String
        switch first.block.kind {
        case .cooldown:
            reason = "you applied to \(first.block.company) on \(day(first.block.since)), so I can send it from \(day(first.block.resetsAt))"
        case .unconfirmedAttempt(inFlight: true), .sameCompanyInReview:
            reason = "one \(first.block.company) job at a time, so it waits until \(day(first.block.resetsAt)) if the other goes through"
        case .unconfirmedAttempt(inFlight: false):
            reason = "I'm not sure \(other(first.block, in: all)) went through. Tell me in Review"
        }
        let more = kept.count > 1 ? " (and \(kept.count - 1) more held the same way)" : ""
        return "I kept \(first.job.displayName) in Review: \(reason).\(more)"
    }
}
