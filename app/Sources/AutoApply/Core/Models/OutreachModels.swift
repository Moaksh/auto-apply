// OutreachModels.swift — DB-shaped cold-outreach and employer-reply rows (schema v10 / v11,
// contract/protocol.md §6.2.2–6.2.3), read through GRDBRepository or fixtures. Protocol enums
// (OutreachKind, ReferralState, ProspectStatus, …) come from Messages.swift.
import Foundation

// MARK: - Contacts

/// Email confidence tiers (protocol §6.2.2): Verified ≥ 90, Likely 70–89, Guess 40–69, Unknown < 40.
enum EmailTier: String, Sendable, CaseIterable, Hashable {
    case verified, likely, guess, unknown

    init(confidence: Int) {
        switch confidence {
        case 90...: self = .verified
        case 70..<90: self = .likely
        case 40..<70: self = .guess
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .verified: "Verified"
        case .likely: "Likely"
        case .guess: "Guess"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .verified: "checkmark.seal"
        case .likely: "checkmark.circle"
        case .guess: "questionmark.circle"
        case .unknown: "circle.dashed"
        }
    }
}

enum ContactOrigin: String, Sendable, CaseIterable, Hashable {
    case scout, user, `import`, shared

    var label: String {
        switch self {
        case .scout: "Found by the agent"
        case .user: "Added by you"
        case .import: "Imported"
        case .shared: "Shared library"
        }
    }
}

enum ContactRoleCategory: String, Sendable, CaseIterable, Hashable {
    case recruiter, talentLead = "talent_lead", hiringManager = "hiring_manager", engLeader = "eng_leader", engineer, founder,
         roleMailbox = "role_mailbox", other

    var label: String {
        switch self {
        case .recruiter: "Recruiter"
        case .talentLead: "Talent lead"
        case .hiringManager: "Hiring manager"
        case .engLeader: "Engineering leader"
        case .engineer: "Engineer"
        case .founder: "Founder"
        case .roleMailbox: "Team mailbox"
        case .other: "Other"
        }
    }
}

/// One person at a company (`contacts`).
struct ContactItem: Identifiable, Sendable, Hashable {
    var id: Int
    var companyID: Int?
    var company: String?
    var fullName: String
    var title: String?
    var roleCategory: ContactRoleCategory = .other
    var email: String?
    /// none | pattern | published | provider_verified | user | delivered | replied | bounced.
    var emailStatus: String = "none"
    var emailConfidence: Int = 0
    var origin: ContactOrigin = .scout
    var relationship: Relationship?
    var linkedinURL: String?
    var notes: String?
    var shareOk = false
    var lastContactedAt: Date?
    var createdAt: Date

    var tier: EmailTier { EmailTier(confidence: email == nil ? 0 : emailConfidence) }
    var hasEmail: Bool { !(email ?? "").isEmpty }

    /// "Jane Rao · Recruiter"
    var nameAndTitle: String { [fullName, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// One observation behind a contact (`contact_evidence`): the provenance popover.
struct ContactEvidenceItem: Identifiable, Sendable, Hashable {
    var id: Int
    var contactID: Int
    /// user | job_posting | company_page | github | google_serp | pattern | provider | shared_library | reply | bounce
    var kind: String
    /// name | title | email
    var field: String
    var url: String?
    var snippet: String?
    var provider: String?
    var observedAt: Date

    var kindLabel: String {
        switch kind {
        case "user": "You added it"
        case "job_posting": "The job posting"
        case "company_page": "The company's website"
        case "github": "GitHub"
        case "google_serp": "A Google result"
        case "pattern": "The company's email pattern"
        case "provider": provider.map { "\($0.capitalized) (lookup service)" } ?? "A lookup service"
        case "shared_library": "Shared library"
        case "reply": "They replied from it"
        case "bounce": "An email to it bounced"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "found on acme.com/team, 12 Oct"
    var sentence: String {
        let place = url.flatMap(URL.init(string:)).map { u in
            ((u.host() ?? "") + u.path()).replacingOccurrences(of: "www.", with: "")
        }
        let when = observedAt.formatted(.dateTime.day().month(.abbreviated))
        return "\(field.capitalized): \(place.map { "found on \($0)" } ?? kindLabel.lowercased()), \(when)"
    }
}

// MARK: - Threads and messages

enum OutreachThreadState: String, Sendable, CaseIterable, Hashable {
    case draft, active, replied, bounced, optedOut = "opted_out", closed, cancelled

    var label: String {
        switch self {
        case .draft: "Draft"
        case .active: "Emailed"
        case .replied: "Replied"
        case .bounced: "Bounced"
        case .optedOut: "Asked not to be emailed"
        case .closed: "Closed"
        case .cancelled: "Discarded"
        }
    }
}

enum OutreachMessageState: String, Sendable, CaseIterable, Hashable {
    case draft, approved, scheduled, sending, sent, failed, unknown, cancelled, received
}

/// One conversation with one contact (`outreach_threads` + company name).
struct OutreachThreadItem: Identifiable, Sendable, Hashable {
    var id: Int
    var kind: OutreachKind
    var contactID: Int?
    var companyID: Int
    var company: String
    var jobID: Int?
    var applicationID: Int?
    var state: OutreachThreadState = .draft
    var outcome: ThreadOutcome?
    var subject: String?
    var unreadReply = false
    var followupApproved = false
    /// A reply suggested moving the application here (schema v12); Accept / Dismiss in Needs You.
    var suggestedStatus: BoardStatus?
    var suggestionPending = false
    var nextActionAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

/// A draft, a sent email, or an inbound reply / bounce (`outreach_messages`).
struct OutreachMessageItem: Identifiable, Sendable, Hashable {
    var id: Int
    var threadID: Int
    var seq = 0
    var isInbound = false
    /// application_followup | prospect | followup | referral_email
    var kind: String?
    var state: OutreachMessageState
    var toEmail: String?
    var fromEmail: String?
    var subject: String?
    var body: String
    /// Always appended when sending; never editable.
    var footer: String?
    var origin = "generated"
    var grounded = true
    var unsupportedClaims: [String] = []
    var claimsOverridden = false
    var messageIDHeader: String?
    var sendAt: Date?
    var sentAt: Date?
    /// Inbound: positive | referred | not_interested | opt_out | question | other | ooo | bounce.
    var classification: String?
    var error: String?
    var createdAt: Date
    var updatedAt: Date

    /// Approval is blocked until the text is fixed or the user confirms the claims are true.
    var needsClaimsFix: Bool { !grounded && !claimsOverridden }
    var isFollowup: Bool { seq > 0 || kind == "followup" }
    var gmailURL: URL? { messageIDHeader.flatMap(GmailLink.url(messageID:)) }
}

/// "Open in Gmail" (protocol §6.2.2): a search for the RFC 822 Message-ID.
enum GmailLink {
    static func url(messageID raw: String) -> URL? {
        let id = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \n"))
        guard !id.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return URL(string: "https://mail.google.com/mail/u/0/#search/rfc822msgid%3A\(encoded)")
    }
}

// MARK: - Do-not-contact, referrals, prospects

/// One do-not-contact entry (`suppression`): an address or a whole domain.
struct SuppressionItem: Identifiable, Sendable, Hashable {
    var id: Int
    var emailNorm: String?
    var domain: String?
    var reason: SuppressionReason
    var source: String?
    var createdAt: Date

    var value: String { emailNorm ?? domain.map { "@\($0)" } ?? "" }
    /// Opt-outs are permanent in the app (only "delete record" in the data tools).
    var isRemovable: Bool { reason != .optOut }

    var reasonLabel: String {
        switch reason {
        case .optOut: "Asked not to be emailed"
        case .hardBounce: "Address bounced"
        case .user: "Added by you"
        case .sharedRemoval: "Removal request"
        case .complaint: "Complaint"
        }
    }
}

/// The LinkedIn referral copilot (`referrals`). The user does every LinkedIn step themselves.
struct ReferralItem: Identifiable, Sendable, Hashable {
    var id: Int
    var companyID: Int
    var company: String
    var jobID: Int?
    var jobTitle: String?
    var contactID: Int?
    var personName: String
    var title: String?
    var linkedinURL: String?
    var basis: ReferralBasis
    var basisDetail: String?
    var evidenceURL: String?
    var evidenceSnippet: String?
    var state: ReferralState = .suggested
    var connectNote: String?
    var referralDM: String?
    var grounded = true
    var unsupportedClaims: [String] = []
    var stateUpdatedAt: Date
    var createdAt: Date

    var basisLabel: String {
        let detail = basisDetail.c3Trimmed
        switch basis {
        case .alumni: return detail.map { "Alumni · \($0)" } ?? "Alumni"
        case .exColleague: return detail.map { "Ex-colleague · \($0)" } ?? "Ex-colleague"
        case .sameFunction: return detail.map { "Same team · \($0)" } ?? "Same kind of role"
        case .user: return "You know them"
        case .other: return detail ?? "Other"
        }
    }
}

extension ReferralState {
    var label: String {
        switch self {
        case .suggested: "Suggested"
        case .toConnect: "To connect"
        case .requested: "Request sent"
        case .connected: "Connected"
        case .asked: "Asked"
        case .referred: "Referred"
        case .declined: "Declined"
        case .noResponse: "No response"
        case .dismissed: "Dismissed"
        }
    }

    /// Mirror of `models.REFERRAL_TRANSITIONS` (protocol §7.2).
    var nextStates: [ReferralState] {
        switch self {
        case .suggested: [.toConnect, .requested, .connected, .dismissed]
        case .toConnect: [.requested, .connected, .suggested, .dismissed]
        case .requested: [.connected, .noResponse, .dismissed]
        case .connected: [.asked, .dismissed]
        case .asked: [.referred, .declined, .noResponse]
        case .noResponse: [.toConnect, .requested, .connected, .asked, .dismissed]
        case .referred: []
        case .declined: [.dismissed]
        case .dismissed: [.suggested]
        }
    }

    /// Display order of the Referrals groups.
    static let displayOrder: [ReferralState] = [.connected, .toConnect, .suggested, .requested, .asked, .noResponse, .referred, .declined]
}

extension ProspectStatus {
    var label: String {
        switch self {
        case .suggested: "Suggested"
        case .shortlisted: "Shortlisted"
        case .contacted: "Contacted"
        case .dismissed: "Dismissed"
        }
    }
}

/// A company to reach out to without an application (`prospects` + company).
struct ProspectItem: Identifiable, Sendable, Hashable {
    var id: Int
    var companyID: Int
    var company: String
    var domain: String?
    var status: ProspectStatus = .suggested
    var fitScore: Int?
    /// `fit_reasons.summary`: one sentence on why.
    var fitSummary: String?
    /// `fit_reasons.factors`: domain / stack / stage, 0–100.
    var fitFactors: [String: Int] = [:]
    /// The homepage description drafts may cite.
    var summary: String?
    var summaryURL: String?
    var matchingRoles: Int?
    /// search | watchlist | user
    var foundVia: String?
    var searchQuery: String?
    var cooldownUntil: Date?
    var watched = false
    var createdAt: Date

    var foundViaLabel: String {
        switch foundVia {
        case "search": searchQuery.map { "Company search: “\($0)”" } ?? "Company search"
        case "watchlist": "Your watched companies"
        case "user": "Added by you"
        default: foundVia?.capitalized ?? "—"
        }
    }
}

/// `meta.mail_account`: the connected mailbox and whether sending is on.
struct MailAccountInfo: Sendable, Hashable {
    var email: String?
    var sendEnabled = false

    var isConnected: Bool { !(email ?? "").isEmpty }
}

/// Everything the Cold Email screen reads, as one consistent snapshot.
struct OutreachData: Sendable, Hashable {
    var contacts: [ContactItem] = []
    var threads: [OutreachThreadItem] = []
    var messages: [OutreachMessageItem] = []
    var suppression: [SuppressionItem] = []
    var referrals: [ReferralItem] = []
    var prospects: [ProspectItem] = []
    var mailAccount = MailAccountInfo()
}

// MARK: - Employer replies

/// An employer / ATS email about a submitted application (`application_replies`, schema v11).
struct ApplicationReplyItem: Identifiable, Sendable, Hashable {
    enum SuggestionState: String, Sendable, Hashable { case none, pending, accepted, dismissed }

    var id: Int
    var applicationID: Int
    var messageID: String
    var fromEmail: String
    var fromName: String?
    var subject: String
    var snippet: String
    var receivedAt: Date
    var label: ApplicationReplyLabel
    var suggestedStatus: BoardStatus?
    var suggestionState: SuggestionState = .none
    var ambiguous = false
    /// When the user read it (schema v12); nil = unread.
    var readAt: Date?

    var isPendingSuggestion: Bool { suggestionState == .pending && suggestedStatus != nil }
    /// Unread and with nothing to decide (an acknowledgement, a reply with no suggested move).
    var isUnreadNote: Bool { readAt == nil && !isPendingSuggestion }
    var sender: String { fromName.c3Trimmed ?? fromEmail }
    var gmailURL: URL? { GmailLink.url(messageID: messageID) }
}

extension ApplicationReplyLabel {
    var label: String {
        switch self {
        case .interviewInvite: "Interview invite"
        case .assessment: "Assessment"
        case .rejection: "Rejection"
        case .offer: "Offer"
        case .receivedAck: "Application received"
        case .other: "Other"
        }
    }
}

extension ReplyLabel {
    var label: String {
        switch self {
        case .positive: "Interested"
        case .referred: "Referred you"
        case .notInterested: "Not interested"
        case .optOut: "Asked not to be emailed"
        case .question: "Asked a question"
        case .other: "Replied"
        case .ooo: "Out of office"
        case .bounce: "Bounced"
        }
    }
}
