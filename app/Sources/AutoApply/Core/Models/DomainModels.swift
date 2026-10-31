// DomainModels.swift — durable, DB-shaped models the UI renders (read from SQLite via
// GRDBRepository, or from fixtures via InMemoryRepository). Protocol payload types live in
// Messages.swift; these are the joined/enriched rows views actually need.
import CoreGraphics
import Foundation

/// Provenance of a recorded answer (`application_answers.origin`).
enum AnswerOrigin: String, Codable, Sendable, CaseIterable, Hashable {
    case profile
    case neverGuess = "never_guess"
    case cv
    case memory
    case story
    case generated
    case user

    var label: String {
        switch self {
        case .profile: "profile"
        case .neverGuess: "fact you set"
        case .cv: "CV"
        case .memory: "memory"
        case .story: "story"
        case .generated: "drafted"
        case .user: "you"
        }
    }
}

/// Application mode as stored on `applications.mode` (adds `manual` for Easy Apply).
enum ApplicationMode: String, Codable, Sendable, CaseIterable, Hashable {
    case auto, review, manual
}

/// One job joined with its company, application and score. `id` is the job id.
struct JobItem: Identifiable, Sendable, Hashable {
    var id: Int
    var applicationID: Int?
    var companyID: Int
    var company: String
    var companyDomain: String?
    /// `companies.last_applied_at`: when we last applied to this company (the per-company
    /// cooldown, `ReviewSendability`).
    var companyLastAppliedAt: Date?
    var title: String
    var location: String?
    var remote: RemotePolicy?
    var source: JobSource
    var ats: Ats
    var applyURL: String?
    var sourceURL: String?
    var easyApply: Bool = false
    var salaryMin: Int?
    var salaryMax: Int?
    var salaryCurrency: String?
    var description: String?
    var postedAt: Date?
    var discoveredAt: Date
    var modeOverride: Mode?
    var notes: String?

    // Application
    var state: AppState = .discovered
    var stateReason: String?
    var stateUpdatedAt: Date?
    var mode: ApplicationMode?
    var status: BoardStatus?
    var statusUpdatedAt: Date?
    var submittedAt: Date?
    var resumeVariantID: Int?
    var resumePickScore: Double?
    var coverLetterPath: String?
    var screenshotPath: String?
    var confirmationScreenshotPath: String?
    var nudgesSent: Int = 0
    var tokensIn: Int = 0
    var tokensOut: Int = 0

    // Score
    var score: Int?
    var scoreSummary: String?
    /// Factor name -> 0…100 (`scores.reasons.factors`).
    var scoreFactors: [String: Int] = [:]
    /// Requirement-level evidence (`scores.reasons.requirements`); nil for older scores.
    var scoreRequirements: [RequirementEvidence]?
    /// What the scorer's grounding guard dropped (`scores.reasons.grounding`).
    var scoreGrounding: ScoreGrounding?
    var skipReason: String?
    var scoredAt: Date?

    init(id: Int, applicationID: Int? = nil, companyID: Int, company: String, companyDomain: String? = nil,
         title: String, location: String? = nil, remote: RemotePolicy? = nil, source: JobSource, ats: Ats,
         applyURL: String? = nil, sourceURL: String? = nil, easyApply: Bool = false, discoveredAt: Date) {
        self.id = id
        self.applicationID = applicationID
        self.companyID = companyID
        self.company = company
        self.companyDomain = companyDomain
        self.title = title
        self.location = location
        self.remote = remote
        self.source = source
        self.ats = ats
        self.applyURL = applyURL
        self.sourceURL = sourceURL
        self.easyApply = easyApply
        self.discoveredAt = discoveredAt
    }

    /// Build from a `job_discovered` payload (optimistic, before the DB catches up).
    init(summary s: JobSummary) {
        self.init(id: s.id, applicationID: s.applicationId, companyID: s.companyId, company: s.company,
                  title: s.title, location: s.location, remote: s.remote, source: s.source, ats: s.ats,
                  applyURL: s.applyUrl, sourceURL: s.sourceUrl, easyApply: s.easyApply, discoveredAt: s.discoveredAt)
        salaryMin = s.salaryMin
        salaryMax = s.salaryMax
        salaryCurrency = s.salaryCurrency
    }

    /// Kanban column for this job, or nil when it isn't on the default board.
    var boardColumn: BoardColumn? { BoardColumn(job: self) }

    /// "Stripe · Backend Engineer"
    var displayName: String { "\(company) · \(title)" }

    /// Days since submission (for nudges / ghosting), nil if not submitted.
    func daysSinceSubmitted(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let submittedAt else { return nil }
        return calendar.dateComponents([.day], from: submittedAt, to: now).day
    }
}

/// Columns of the Pipeline board, in display order.
enum BoardColumn: String, CaseIterable, Identifiable, Sendable, Hashable {
    case discovered, skipped, queued, needsYou, applied, assessment, interview, offer, rejected, ghosted

    var id: String { rawValue }

    /// Columns shown by default (discovered/skipped live behind "Show skipped" / Table).
    static let defaultVisible: [BoardColumn] = [.queued, .needsYou, .applied, .assessment, .interview, .offer, .rejected, .ghosted]

    init?(job: JobItem) {
        switch job.state {
        case .submitted:
            switch job.status ?? .applied {
            case .applied: self = .applied
            case .assessment: self = .assessment
            case .interview: self = .interview
            case .offer: self = .offer
            case .rejected: self = .rejected
            case .ghosted: self = .ghosted
            }
        case .discovered, .scored: self = .discovered
        case .skipped: self = .skipped
        case .queued, .prepping, .filling, .awaitingReview, .submitting: self = .queued
        case .needsYou: self = .needsYou
        case .failed, .unknownVerify: self = .queued
        }
    }

    /// The board status a card dropped here gets, if the column is user-owned.
    var boardStatus: BoardStatus? {
        switch self {
        case .applied: .applied
        case .assessment: .assessment
        case .interview: .interview
        case .offer: .offer
        case .rejected: .rejected
        case .ghosted: .ghosted
        default: nil
        }
    }

    var title: String {
        switch self {
        case .discovered: "Discovered"
        case .skipped: "Skipped"
        case .queued: "Queued"
        case .needsYou: "Needs you"
        case .applied: "Applied"
        case .assessment: "Assessment"
        case .interview: "Interview"
        case .offer: "Offer"
        case .rejected: "Rejected"
        case .ghosted: "Ghosted"
        }
    }
}

/// One Q&A audit row (`application_answers`).
struct ApplicationAnswerItem: Identifiable, Sendable, Hashable {
    var id: Int
    var applicationID: Int
    var fieldKey: String?
    var question: String
    var answer: String
    var fieldType: FieldType = .text
    var confidence: Double?
    var origin: AnswerOrigin
    var originRef: String?
    /// Field location in the pre-submit screenshot (pixels), when the daemon recorded it.
    var bbox: CGRect?

    var isLocked: Bool { origin == .neverGuess }

    enum ConfidenceLevel: Sendable { case high, medium, low, notApplicable }
    var confidenceLevel: ConfidenceLevel {
        guard let c = confidence else { return .notApplicable }
        if c >= 0.85 { return .high }
        if c >= 0.6 { return .medium }
        return .low
    }
}

struct ResumeVariantItem: Identifiable, Sendable, Hashable {
    var id: Int
    var label: String
    var filePath: String
    var tags: [String] = []
    var isDefault: Bool = false
    var enabled: Bool = true
    var version: Int = 1
    var replacedBy: Int?
    var createdAt: Date
    var updatedAt: Date
}

struct StoryItem: Identifiable, Sendable, Hashable {
    var id: Int
    var title: String
    var situation: String = ""
    var task: String = ""
    var action: String = ""
    var result: String = ""
    var tags: [String] = []
    var uses: Int = 0
    var updatedAt: Date
}

/// Answer memory row (`answers`), shown in Profile ▸ Memory.
struct MemoryAnswerItem: Identifiable, Sendable, Hashable {
    var id: Int
    var canonicalQuestion: String
    var answer: String
    var fieldType: FieldType = .text
    var isTemplate: Bool = false
    var source: String = "user"
    var uses: Int = 0
    var lastUsedAt: Date?
    var updatedAt: Date
}

/// One pre-drafted Easy Apply answer (`easy_apply.drafted_answers[]`).
struct DraftedAnswer: Codable, Sendable, Hashable, Identifiable {
    var question: String
    var answer: String
    var origin: String?
    var locked: Bool = false
    var askMe: Bool = false

    var id: String { question }

    enum CodingKeys: String, CodingKey {
        case question, answer, origin, locked
        case askMe = "ask_me"
    }

    init(question: String, answer: String, origin: String? = nil, locked: Bool = false, askMe: Bool = false) {
        self.question = question
        self.answer = answer
        self.origin = origin
        self.locked = locked
        self.askMe = askMe
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        askMe = try c.decodeIfPresent(Bool.self, forKey: .askMe) ?? false
    }
}

/// LinkedIn Easy Apply manual-list row (`easy_apply` joined with its job).
struct EasyApplyItem: Identifiable, Sendable, Hashable {
    var id: Int
    var jobID: Int
    var url: String
    var draftedAnswers: [DraftedAnswer] = []
    var resumeVariantID: Int?
    var opened: Bool = false
    var done: Bool = false
    var dismissed: Bool = false
    var doneAt: Date?
    var createdAt: Date

    var isOpen: Bool { !done && !dismissed }
}

/// A company the agent found while browsing that is not on the watchlist (`company_suggestions`).
struct CompanySuggestionItem: Identifiable, Sendable, Hashable {
    enum Status: String, Sendable, Hashable {
        /// Waiting for Add / Dismiss.
        case pending
        /// The user added it.
        case accepted
        /// Never suggest again.
        case dismissed
        /// A verified ATS board the agent watched by itself (Dismiss unwatches it).
        case auto
    }

    var id: Int
    var companyName: String
    var url: String
    var ats: Ats?
    var boardToken: String?
    /// Where it was found: google | linkedin | glassdoor | company_finder | careers.
    var source: String
    var foundVia: String?
    var sampleTitle: String?
    var matchingRoles: Int = 0
    var openRoles: Int?
    var verified: Bool = false
    var status: Status = .pending
    var suggestedAt: Date

    /// "Google Jobs", "LinkedIn", "Company finder"…
    var sourceLabel: String {
        switch source {
        case "google": "Google Jobs"
        case "linkedin": "LinkedIn"
        case "glassdoor": "Glassdoor"
        case "company_finder": "Company finder (Google)"
        case "careers": "a career page"
        default: source.capitalized
        }
    }

    /// "Greenhouse board" / "Career page".
    var kindLabel: String {
        switch ats {
        case .greenhouse: "Greenhouse board"
        case .lever: "Lever board"
        case .ashby: "Ashby board"
        case .workday: "Workday site"
        default: "Career page"
        }
    }
}

/// One row of the append-only activity log (`events`).
struct ActivityEvent: Identifiable, Sendable, Hashable {
    var id: Int
    var ts: Date
    var kind: String
    var actor: Actor = .agent
    var level: LogLevel = .info
    var runID: Int?
    var jobID: Int?
    var applicationID: Int?
    var message: String
    var payload: JSONValue = .object([:])
}

/// A pipeline run (`runs`).
struct RunItem: Identifiable, Sendable, Hashable {
    var id: Int
    var runUID: String
    var kind: RunKind
    var trigger: RunTrigger
    var startedAt: Date
    var finishedAt: Date?
    var outcome: RunOutcome?
    var stats: RunStats
    var tokensIn: Int = 0
    var tokensOut: Int = 0
}
