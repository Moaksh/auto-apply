// GENERATED FILE - DO NOT EDIT.
// Source: contract/protocol.schema.json (itself generated from engine/autoapply/models.py).
// Regenerate: cd engine && uv run python -m autoapply.models && uv run python scripts/gen_swift_messages.py
//
// Swift mirror of the AutoApply socket protocol v1 (contract/protocol.md).
// Wire names are snake_case via explicit CodingKeys; Swift names are camelCase.

import Foundation

// MARK: - Runtime support

/// Arbitrary JSON (ack results, score reasons, error details, patches).
enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Encode any `Encodable` value into a `JSONValue` using the protocol encoder.
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try ProtocolCoding.makeEncoder().encode(value)
        return try ProtocolCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode this JSON into a typed value (e.g. an `ack.result` into `SystemCheckResult`).
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try ProtocolCoding.makeEncoder().encode(self)
        return try ProtocolCoding.makeDecoder().decode(T.self, from: data)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

/// Encoders/decoders configured for the wire format (ISO-8601 UTC timestamps with ms + `Z`).
enum ProtocolCoding {
    static let version = 1

    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func parseDate(_ string: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(string) { return d }
        // Offsets other than Z (e.g. +05:30), with or without fractional seconds.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    /// Parse a known-good timestamp literal (used for generated defaults).
    static func date(_ string: String) -> Date {
        parseDate(string) ?? Date(timeIntervalSince1970: 0)
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid timestamp \(s)")
            }
            return date
        }
        return d
    }

    /// One NDJSON line (JSON + `\n`).
    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func decodeEvent(_ line: Data) throws -> EventEnvelope {
        try makeDecoder().decode(EventEnvelope.self, from: line)
    }

    static func decodeCommand(_ line: Data) throws -> CommandEnvelope {
        try makeDecoder().decode(CommandEnvelope.self, from: line)
    }
}

// MARK: - Enumerations

enum Actor: String, Codable, Sendable, CaseIterable, Hashable {
    case agent
    case user
    case system
}

enum AppState: String, Codable, Sendable, CaseIterable, Hashable {
    case discovered
    case scored
    case skipped
    case queued
    case prepping
    case needsYou = "needs_you"
    case filling
    case awaitingReview = "awaiting_review"
    case submitting
    case submitted
    case failed
    case unknownVerify = "unknown_verify"
}

enum AskConfidence: String, Codable, Sendable, CaseIterable, Hashable {
    case strict
    case balanced
    case lenient
}

enum Ats: String, Codable, Sendable, CaseIterable, Hashable {
    case greenhouse
    case lever
    case ashby
    case workday
    case linkedinEasyApply = "linkedin_easy_apply"
    case other
}

enum BoardStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case applied
    case assessment
    case interview
    case offer
    case rejected
    case ghosted
}

enum CapKind: String, Codable, Sendable, CaseIterable, Hashable {
    case daily
    case companyCooldown = "company_cooldown"
    case linkedinBudget = "linkedin_budget"
    case glassdoorBudget = "glassdoor_budget"
}

enum DaemonActivity: String, Codable, Sendable, CaseIterable, Hashable {
    case idle
    case discovering
    case scoring
    case prepping
    case applying
}

enum ErrorCode: String, Codable, Sendable, CaseIterable, Hashable {
    case badRequest = "bad_request"
    case unsupportedVersion = "unsupported_version"
    case unknownType = "unknown_type"
    case invalidPayload = "invalid_payload"
    case notFound = "not_found"
    case illegalTransition = "illegal_transition"
    case conflict
    case paused
    case capReached = "cap_reached"
    case unavailable
    case `internal`
}

enum FieldType: String, Codable, Sendable, CaseIterable, Hashable {
    case text
    case textarea
    case number
    case boolean
    case select
    case multiselect
    case url
    case email
    case phone
    case date
    case file
}

enum JobSource: String, Codable, Sendable, CaseIterable, Hashable {
    case greenhouse
    case lever
    case ashby
    case careers
    case linkedin
    case glassdoor
    case manual
}

enum LogLevel: String, Codable, Sendable, CaseIterable, Hashable {
    case debug
    case info
    case warning
    case error
}

enum Mode: String, Codable, Sendable, CaseIterable, Hashable {
    case auto
    case review
}

enum QuestionReason: String, Codable, Sendable, CaseIterable, Hashable {
    case unknown
    case neverGuess = "never_guess"
    case lowConfidence = "low_confidence"
    case captcha
    case alwaysAsk = "always_ask"
}

enum RemotePolicy: String, Codable, Sendable, CaseIterable, Hashable {
    case remote
    case hybrid
    case onsite
}

enum RunKind: String, Codable, Sendable, CaseIterable, Hashable {
    case full
    case discover
    case prep
    case apply
}

enum RunOutcome: String, Codable, Sendable, CaseIterable, Hashable {
    case completed
    case paused
    case failed
    case capReached = "cap_reached"
}

enum RunTrigger: String, Codable, Sendable, CaseIterable, Hashable {
    case manual
    case scheduled
    case wake
    case cli
}

enum Seniority: String, Codable, Sendable, CaseIterable, Hashable {
    case junior
    case mid
    case senior
    case staff
    case principal
}

enum SourceName: String, Codable, Sendable, CaseIterable, Hashable {
    case linkedin
    case glassdoor
    case greenhouse
    case lever
    case ashby
    case careers
}

// MARK: - Payload and shared types

/// Success reply to a command (envelope carries ``reply_to``).
struct AckPayload: Codable, Sendable, Hashable {
    var ok: Bool = true
    var result: [String: JSONValue]? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case ok
        case result
    }
}

extension AckPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        result = try c.decodeIfPresent([String: JSONValue].self, forKey: .result)
    }
}

struct AddResumeVariantPayload: Codable, Sendable, Hashable {
    var filePath: String
    var label: String
    var tags: [String] = []
    var isDefault: Bool = false

    enum CodingKeys: String, CodingKey, CaseIterable {
        case filePath = "file_path"
        case label
        case tags
        case isDefault = "is_default"
    }
}

extension AddResumeVariantPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try c.decode(String.self, forKey: .filePath)
        label = try c.decode(String.self, forKey: .label)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

struct AgentStepPayload: Codable, Sendable, Hashable {
    var applicationId: Int
    var jobId: Int
    var runId: String? = nil
    var index: Int
    var total: Int? = nil
    var action: String
    var detail: String? = nil
    var confidence: Double? = nil
    var screenshotThumb: String? = nil
    var at: Date

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
        case jobId = "job_id"
        case runId = "run_id"
        case index
        case total
        case action
        case detail
        case confidence
        case screenshotThumb = "screenshot_thumb"
        case at
    }
}

extension AgentStepPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        jobId = try c.decode(Int.self, forKey: .jobId)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        index = try c.decode(Int.self, forKey: .index)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
        action = try c.decode(String.self, forKey: .action)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        screenshotThumb = try c.decodeIfPresent(String.self, forKey: .screenshotThumb)
        at = try c.decode(Date.self, forKey: .at)
    }
}

struct AnswerQuestionPayload: Codable, Sendable, Hashable {
    var clusterId: String
    var answer: String
    var saveToMemory: Bool = true
    var saveToProfile: Bool = false
    var perJobAnswers: [PerJobAnswer] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case clusterId = "cluster_id"
        case answer
        case saveToMemory = "save_to_memory"
        case saveToProfile = "save_to_profile"
        case perJobAnswers = "per_job_answers"
    }
}

extension AnswerQuestionPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clusterId = try c.decode(String.self, forKey: .clusterId)
        answer = try c.decode(String.self, forKey: .answer)
        saveToMemory = try c.decodeIfPresent(Bool.self, forKey: .saveToMemory) ?? true
        saveToProfile = try c.decodeIfPresent(Bool.self, forKey: .saveToProfile) ?? false
        perJobAnswers = try c.decodeIfPresent([PerJobAnswer].self, forKey: .perJobAnswers) ?? []
    }
}

struct ApplicationStatePayload: Codable, Sendable, Hashable {
    var applicationId: Int
    var jobId: Int
    var fromState: AppState? = nil
    var toState: AppState
    var reason: String? = nil
    var actor: Actor = .agent
    var at: Date

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
        case jobId = "job_id"
        case fromState = "from_state"
        case toState = "to_state"
        case reason
        case actor
        case at
    }
}

extension ApplicationStatePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        jobId = try c.decode(Int.self, forKey: .jobId)
        fromState = try c.decodeIfPresent(AppState.self, forKey: .fromState)
        toState = try c.decode(AppState.self, forKey: .toState)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        actor = try c.decodeIfPresent(Actor.self, forKey: .actor) ?? .agent
        at = try c.decode(Date.self, forKey: .at)
    }
}

/// Manual board status changed (user drag-drop, auto-ghost, notification action).
struct ApplicationStatusPayload: Codable, Sendable, Hashable {
    var applicationId: Int
    var jobId: Int
    var previousStatus: BoardStatus? = nil
    var status: BoardStatus
    var actor: Actor = .user
    var at: Date

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
        case jobId = "job_id"
        case previousStatus = "previous_status"
        case status
        case actor
        case at
    }
}

extension ApplicationStatusPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        jobId = try c.decode(Int.self, forKey: .jobId)
        previousStatus = try c.decodeIfPresent(BoardStatus.self, forKey: .previousStatus)
        status = try c.decode(BoardStatus.self, forKey: .status)
        actor = try c.decodeIfPresent(Actor.self, forKey: .actor) ?? .user
        at = try c.decode(Date.self, forKey: .at)
    }
}

/// User override of a hard-filter / below-threshold skip: skipped -> queued (actor user).
struct ApplyAnywayPayload: Codable, Sendable, Hashable {
    var applicationId: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
    }
}

extension ApplyAnywayPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
    }
}

struct ApprovePayload: Codable, Sendable, Hashable {
    var applicationIds: [Int]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationIds = "application_ids"
    }
}

extension ApprovePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationIds = try c.decode([Int].self, forKey: .applicationIds)
    }
}

struct CapReachedPayload: Codable, Sendable, Hashable {
    var cap: CapKind
    var used: Int
    var limit: Int
    var resetsAt: Date? = nil
    var companyId: Int? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case cap
        case used
        case limit
        case resetsAt = "resets_at"
        case companyId = "company_id"
    }
}

extension CapReachedPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cap = try c.decode(CapKind.self, forKey: .cap)
        used = try c.decode(Int.self, forKey: .used)
        limit = try c.decode(Int.self, forKey: .limit)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        companyId = try c.decodeIfPresent(Int.self, forKey: .companyId)
    }
}

struct CapsStatus: Codable, Sendable, Hashable {
    var dailyUsed: Int = 0
    var dailyLimit: Int = 0
    var companiesCoolingDown: Int = 0
    var linkedinSessionsUsed: Int = 0
    var linkedinSessionsLimit: Int = 0
    var glassdoorSessionsUsed: Int = 0
    var glassdoorSessionsLimit: Int = 0

    enum CodingKeys: String, CodingKey, CaseIterable {
        case dailyUsed = "daily_used"
        case dailyLimit = "daily_limit"
        case companiesCoolingDown = "companies_cooling_down"
        case linkedinSessionsUsed = "linkedin_sessions_used"
        case linkedinSessionsLimit = "linkedin_sessions_limit"
        case glassdoorSessionsUsed = "glassdoor_sessions_used"
        case glassdoorSessionsLimit = "glassdoor_sessions_limit"
    }
}

extension CapsStatus {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyUsed = try c.decodeIfPresent(Int.self, forKey: .dailyUsed) ?? 0
        dailyLimit = try c.decodeIfPresent(Int.self, forKey: .dailyLimit) ?? 0
        companiesCoolingDown = try c.decodeIfPresent(Int.self, forKey: .companiesCoolingDown) ?? 0
        linkedinSessionsUsed = try c.decodeIfPresent(Int.self, forKey: .linkedinSessionsUsed) ?? 0
        linkedinSessionsLimit = try c.decodeIfPresent(Int.self, forKey: .linkedinSessionsLimit) ?? 0
        glassdoorSessionsUsed = try c.decodeIfPresent(Int.self, forKey: .glassdoorSessionsUsed) ?? 0
        glassdoorSessionsLimit = try c.decodeIfPresent(Int.self, forKey: .glassdoorSessionsLimit) ?? 0
    }
}

struct CheckSourceLoginPayload: Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable, CaseIterable, Hashable {
        case linkedin
        case glassdoor
    }
    var source: Source

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source
    }
}

extension CheckSourceLoginPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(Source.self, forKey: .source)
    }
}

struct ClearMailAccountPayload: Codable, Sendable, Hashable {
}

extension ClearMailAccountPayload {
    init(from decoder: any Decoder) throws {
    }
}

/// Live counters for badges / hero. Derived from the DB at snapshot time.
struct Counts: Codable, Sendable, Hashable {
    var queued: Int = 0
    var needsYouClusters: Int = 0
    var needsYouJobs: Int = 0
    var awaitingReview: Int = 0
    var easyApplyOpen: Int = 0
    var unknownVerify: Int = 0
    var failed: Int = 0
    var submittedToday: Int = 0
    var discoveredToday: Int = 0
    var submittedTotal: Int = 0

    enum CodingKeys: String, CodingKey, CaseIterable {
        case queued
        case needsYouClusters = "needs_you_clusters"
        case needsYouJobs = "needs_you_jobs"
        case awaitingReview = "awaiting_review"
        case easyApplyOpen = "easy_apply_open"
        case unknownVerify = "unknown_verify"
        case failed
        case submittedToday = "submitted_today"
        case discoveredToday = "discovered_today"
        case submittedTotal = "submitted_total"
    }
}

extension Counts {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        needsYouClusters = try c.decodeIfPresent(Int.self, forKey: .needsYouClusters) ?? 0
        needsYouJobs = try c.decodeIfPresent(Int.self, forKey: .needsYouJobs) ?? 0
        awaitingReview = try c.decodeIfPresent(Int.self, forKey: .awaitingReview) ?? 0
        easyApplyOpen = try c.decodeIfPresent(Int.self, forKey: .easyApplyOpen) ?? 0
        unknownVerify = try c.decodeIfPresent(Int.self, forKey: .unknownVerify) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        submittedToday = try c.decodeIfPresent(Int.self, forKey: .submittedToday) ?? 0
        discoveredToday = try c.decodeIfPresent(Int.self, forKey: .discoveredToday) ?? 0
        submittedTotal = try c.decodeIfPresent(Int.self, forKey: .submittedTotal) ?? 0
    }
}

struct DeleteAnswerPayload: Codable, Sendable, Hashable {
    var answerId: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case answerId = "answer_id"
    }
}

extension DeleteAnswerPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answerId = try c.decode(Int.self, forKey: .answerId)
    }
}

struct DeleteStoryPayload: Codable, Sendable, Hashable {
    var id: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
    }
}

extension DeleteStoryPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
    }
}

struct DismissEasyApplyPayload: Codable, Sendable, Hashable {
    var jobId: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobId = "job_id"
    }
}

extension DismissEasyApplyPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(Int.self, forKey: .jobId)
    }
}

struct EditApplicationAnswerPayload: Codable, Sendable, Hashable {
    var applicationAnswerId: Int
    var answer: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationAnswerId = "application_answer_id"
        case answer
    }
}

extension EditApplicationAnswerPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationAnswerId = try c.decode(Int.self, forKey: .applicationAnswerId)
        answer = try c.decode(String.self, forKey: .answer)
    }
}

struct EducationItem: Codable, Sendable, Hashable {
    var school: String
    var degree: String? = nil
    var field: String? = nil
    var start: String? = nil
    var end: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case school
        case degree
        case field
        case start
        case end
    }
}

extension EducationItem {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        school = try c.decode(String.self, forKey: .school)
        degree = try c.decodeIfPresent(String.self, forKey: .degree)
        field = try c.decodeIfPresent(String.self, forKey: .field)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
    }
}

/// Failure reply to a command (with ``reply_to``) or an unsolicited daemon error.
struct ErrorPayload: Codable, Sendable, Hashable {
    var code: ErrorCode
    var message: String
    var details: [String: JSONValue]? = nil
    var jobId: Int? = nil
    var applicationId: Int? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case message
        case details
        case jobId = "job_id"
        case applicationId = "application_id"
    }
}

extension ErrorPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(ErrorCode.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        details = try c.decodeIfPresent([String: JSONValue].self, forKey: .details)
        jobId = try c.decodeIfPresent(Int.self, forKey: .jobId)
        applicationId = try c.decodeIfPresent(Int.self, forKey: .applicationId)
    }
}

/// A question harvested from an application form (ATS API or browser scan).
struct FormQuestion: Codable, Sendable, Hashable {
    var key: String
    var label: String
    var fieldType: FieldType = .text
    var required: Bool = false
    var options: [String] = []
    var description: String? = nil
    var maxLength: Int? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case key
        case label
        case fieldType = "field_type"
        case required
        case options
        case description
        case maxLength = "max_length"
    }
}

extension FormQuestion {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        fieldType = try c.decodeIfPresent(FieldType.self, forKey: .fieldType) ?? .text
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description)
        maxLength = try c.decodeIfPresent(Int.self, forKey: .maxLength)
    }
}

struct GetMailAccountPayload: Codable, Sendable, Hashable {
    var test: Bool = false

    enum CodingKeys: String, CodingKey, CaseIterable {
        case test
    }
}

extension GetMailAccountPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        test = try c.decodeIfPresent(Bool.self, forKey: .test) ?? false
    }
}

struct HelloPayload: Codable, Sendable, Hashable {
    enum Client: String, Codable, Sendable, CaseIterable, Hashable {
        case app
        case cli
        case test
    }
    var client: Client = .app
    var clientVersion: String? = nil
    var protocolVersion: Int = 1

    enum CodingKeys: String, CodingKey, CaseIterable {
        case client
        case clientVersion = "client_version"
        case protocolVersion = "protocol_version"
    }
}

extension HelloPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        client = try c.decodeIfPresent(Client.self, forKey: .client) ?? .app
        clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
    }
}

struct JobDiscoveredPayload: Codable, Sendable, Hashable {
    var job: JobSummary
    var runId: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case job
        case runId = "run_id"
    }
}

extension JobDiscoveredPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job = try c.decode(JobSummary.self, forKey: .job)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
    }
}

struct JobScoredPayload: Codable, Sendable, Hashable {
    var jobId: Int
    var applicationId: Int
    var score: Int? = nil
    var reasons: [String: JSONValue] = [:]
    var skipReason: String? = nil
    var queued: Bool = false
    var runId: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobId = "job_id"
        case applicationId = "application_id"
        case score
        case reasons
        case skipReason = "skip_reason"
        case queued
        case runId = "run_id"
    }
}

extension JobScoredPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(Int.self, forKey: .jobId)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        score = try c.decodeIfPresent(Int.self, forKey: .score)
        reasons = try c.decodeIfPresent([String: JSONValue].self, forKey: .reasons) ?? [:]
        skipReason = try c.decodeIfPresent(String.self, forKey: .skipReason)
        queued = try c.decodeIfPresent(Bool.self, forKey: .queued) ?? false
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
    }
}

struct JobSummary: Codable, Sendable, Hashable {
    var id: Int
    var applicationId: Int? = nil
    var companyId: Int
    var company: String
    var title: String
    var location: String? = nil
    var remote: RemotePolicy? = nil
    var source: JobSource
    var ats: Ats
    var applyUrl: String? = nil
    var sourceUrl: String? = nil
    var easyApply: Bool = false
    var salaryMin: Int? = nil
    var salaryMax: Int? = nil
    var salaryCurrency: String? = nil
    var discoveredAt: Date

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case applicationId = "application_id"
        case companyId = "company_id"
        case company
        case title
        case location
        case remote
        case source
        case ats
        case applyUrl = "apply_url"
        case sourceUrl = "source_url"
        case easyApply = "easy_apply"
        case salaryMin = "salary_min"
        case salaryMax = "salary_max"
        case salaryCurrency = "salary_currency"
        case discoveredAt = "discovered_at"
    }
}

extension JobSummary {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        applicationId = try c.decodeIfPresent(Int.self, forKey: .applicationId)
        companyId = try c.decode(Int.self, forKey: .companyId)
        company = try c.decode(String.self, forKey: .company)
        title = try c.decode(String.self, forKey: .title)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        remote = try c.decodeIfPresent(RemotePolicy.self, forKey: .remote)
        source = try c.decode(JobSource.self, forKey: .source)
        ats = try c.decode(Ats.self, forKey: .ats)
        applyUrl = try c.decodeIfPresent(String.self, forKey: .applyUrl)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        easyApply = try c.decodeIfPresent(Bool.self, forKey: .easyApply) ?? false
        salaryMin = try c.decodeIfPresent(Int.self, forKey: .salaryMin)
        salaryMax = try c.decodeIfPresent(Int.self, forKey: .salaryMax)
        salaryCurrency = try c.decodeIfPresent(String.self, forKey: .salaryCurrency)
        discoveredAt = try c.decode(Date.self, forKey: .discoveredAt)
    }
}

struct LogPayload: Codable, Sendable, Hashable {
    var level: LogLevel = .info
    var message: String
    var logger: String? = nil
    var jobId: Int? = nil
    var applicationId: Int? = nil
    var at: Date

    enum CodingKeys: String, CodingKey, CaseIterable {
        case level
        case message
        case logger
        case jobId = "job_id"
        case applicationId = "application_id"
        case at
    }
}

extension LogPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decodeIfPresent(LogLevel.self, forKey: .level) ?? .info
        message = try c.decode(String.self, forKey: .message)
        logger = try c.decodeIfPresent(String.self, forKey: .logger)
        jobId = try c.decodeIfPresent(Int.self, forKey: .jobId)
        applicationId = try c.decodeIfPresent(Int.self, forKey: .applicationId)
        at = try c.decode(Date.self, forKey: .at)
    }
}

struct MarkEasyApplyDonePayload: Codable, Sendable, Hashable {
    var jobId: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobId = "job_id"
    }
}

extension MarkEasyApplyDonePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(Int.self, forKey: .jobId)
    }
}

struct MarkEasyApplyOpenedPayload: Codable, Sendable, Hashable {
    var jobId: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobId = "job_id"
    }
}

extension MarkEasyApplyOpenedPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(Int.self, forKey: .jobId)
    }
}

/// Facts the agent never guesses. ``None`` means "always ask me".
///
/// Each field is one row in the ``never_guess`` table (key = field name, value = JSON).
struct NeverGuess: Codable, Sendable, Hashable {
    var workAuth: [String: String] = [:]
    var sponsorship: String? = nil
    var salaryExpectation: String? = nil
    var salaryNegotiable: Bool? = nil
    var noticePeriod: String? = nil
    var startDate: String? = nil
    var relocation: String? = nil
    var eeoPolicy: String = "decline"
    var eeoGender: String? = nil
    var eeoRace: String? = nil
    var eeoVeteran: String? = nil
    var eeoDisability: String? = nil
    var attestAccuracy: Bool = false
    var attestBackgroundCheck: Bool = false

    enum CodingKeys: String, CodingKey, CaseIterable {
        case workAuth = "work_auth"
        case sponsorship
        case salaryExpectation = "salary_expectation"
        case salaryNegotiable = "salary_negotiable"
        case noticePeriod = "notice_period"
        case startDate = "start_date"
        case relocation
        case eeoPolicy = "eeo_policy"
        case eeoGender = "eeo_gender"
        case eeoRace = "eeo_race"
        case eeoVeteran = "eeo_veteran"
        case eeoDisability = "eeo_disability"
        case attestAccuracy = "attest_accuracy"
        case attestBackgroundCheck = "attest_background_check"
    }
}

extension NeverGuess {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workAuth = try c.decodeIfPresent([String: String].self, forKey: .workAuth) ?? [:]
        sponsorship = try c.decodeIfPresent(String.self, forKey: .sponsorship)
        salaryExpectation = try c.decodeIfPresent(String.self, forKey: .salaryExpectation)
        salaryNegotiable = try c.decodeIfPresent(Bool.self, forKey: .salaryNegotiable)
        noticePeriod = try c.decodeIfPresent(String.self, forKey: .noticePeriod)
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate)
        relocation = try c.decodeIfPresent(String.self, forKey: .relocation)
        eeoPolicy = try c.decodeIfPresent(String.self, forKey: .eeoPolicy) ?? "decline"
        eeoGender = try c.decodeIfPresent(String.self, forKey: .eeoGender)
        eeoRace = try c.decodeIfPresent(String.self, forKey: .eeoRace)
        eeoVeteran = try c.decodeIfPresent(String.self, forKey: .eeoVeteran)
        eeoDisability = try c.decodeIfPresent(String.self, forKey: .eeoDisability)
        attestAccuracy = try c.decodeIfPresent(Bool.self, forKey: .attestAccuracy) ?? false
        attestBackgroundCheck = try c.decodeIfPresent(Bool.self, forKey: .attestBackgroundCheck) ?? false
    }
}

struct NudgeDuePayload: Codable, Sendable, Hashable {
    var applicationId: Int
    var jobId: Int
    var day: Int
    var company: String
    var title: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
        case jobId = "job_id"
        case day
        case company
        case title
    }
}

extension NudgeDuePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        jobId = try c.decode(Int.self, forKey: .jobId)
        day = try c.decode(Int.self, forKey: .day)
        company = try c.decode(String.self, forKey: .company)
        title = try c.decode(String.self, forKey: .title)
    }
}

struct OnboardingCompletePayload: Codable, Sendable, Hashable {
    var runPrep: Bool = false

    enum CodingKeys: String, CodingKey, CaseIterable {
        case runPrep = "run_prep"
    }
}

extension OnboardingCompletePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runPrep = try c.decodeIfPresent(Bool.self, forKey: .runPrep) ?? false
    }
}

struct OnboardingConnectSourcePayload: Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable, CaseIterable, Hashable {
        case linkedin
        case glassdoor
    }
    var source: Source

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source
    }
}

extension OnboardingConnectSourcePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(Source.self, forKey: .source)
    }
}

struct OnboardingParseResumePayload: Codable, Sendable, Hashable {
    var filePath: String
    var label: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case filePath = "file_path"
        case label
    }
}

extension OnboardingParseResumePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try c.decode(String.self, forKey: .filePath)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}

struct OnboardingSetStepPayload: Codable, Sendable, Hashable {
    var step: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case step
    }
}

extension OnboardingSetStepPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decode(Int.self, forKey: .step)
    }
}

struct OnboardingState: Codable, Sendable, Hashable {
    var completed: Bool = false
    var step: Int = 0

    enum CodingKeys: String, CodingKey, CaseIterable {
        case completed
        case step
    }
}

extension OnboardingState {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 0
    }
}

struct OnboardingSystemCheckPayload: Codable, Sendable, Hashable {
}

extension OnboardingSystemCheckPayload {
    init(from decoder: any Decoder) throws {
    }
}

struct OpenAgentChromePayload: Codable, Sendable, Hashable {
    var url: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case url
    }
}

extension OpenAgentChromePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }
}

/// ``ack.result`` for ``onboarding_parse_resume``.
struct ParseResumeResult: Codable, Sendable, Hashable {
    var resumeVariantId: Int
    var profile: Profile
    var uncertainFields: [String] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case resumeVariantId = "resume_variant_id"
        case profile
        case uncertainFields = "uncertain_fields"
    }
}

extension ParseResumeResult {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resumeVariantId = try c.decode(Int.self, forKey: .resumeVariantId)
        profile = try c.decode(Profile.self, forKey: .profile)
        uncertainFields = try c.decodeIfPresent([String].self, forKey: .uncertainFields) ?? []
    }
}

struct PauseAllPayload: Codable, Sendable, Hashable {
}

extension PauseAllPayload {
    init(from decoder: any Decoder) throws {
    }
}

struct PerJobAnswer: Codable, Sendable, Hashable {
    var jobId: Int
    var answer: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobId = "job_id"
        case answer
    }
}

extension PerJobAnswer {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(Int.self, forKey: .jobId)
        answer = try c.decode(String.self, forKey: .answer)
    }
}

struct PingPayload: Codable, Sendable, Hashable {
}

extension PingPayload {
    init(from decoder: any Decoder) throws {
    }
}

/// Job-search preferences. Field names == ``preferences`` table columns.
struct Preferences: Codable, Sendable, Hashable {
    var roles: [String] = []
    var seniority: [Seniority] = []
    var locations: [String] = []
    var remotePolicy: [RemotePolicy] = [.remote, .hybrid]
    var workAuthSummary: String? = nil
    var salaryFloor: Int? = nil
    var salaryCurrency: String = "USD"
    var hideWithoutSalary: Bool = false
    var excludeCompanies: [String] = []
    var excludeIndustries: [String] = []
    var excludeKeywords: [String] = []
    var dailyCap: Int = 15
    var perCompanyCooldownDays: Int = 30
    var matchThreshold: Int = 70
    var mode: Mode = .auto
    var perAtsMode: [String: Mode] = ["workday": .review]
    var perCompanyMode: [String: Mode] = [:]
    var schedule: [String] = ["09:00", "13:00", "18:00"]
    var askConfidence: AskConfidence = .balanced
    var ghostAfterDays: Int = 21
    var nudgeDays: [Int] = [7, 14]
    var linkedinSessionsPerDay: Int = 3
    var glassdoorSessionsPerDay: Int = 3
    var searchesPerSession: Int = 3
    var jobsPerSession: Int = 30
    var sourcesEnabled: [String: Bool] = ["greenhouse": true, "lever": true, "ashby": true, "careers": true, "linkedin": false, "glassdoor": false]
    var careerPageUrls: [String] = []
    var alwaysAskPatterns: [String] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case roles
        case seniority
        case locations
        case remotePolicy = "remote_policy"
        case workAuthSummary = "work_auth_summary"
        case salaryFloor = "salary_floor"
        case salaryCurrency = "salary_currency"
        case hideWithoutSalary = "hide_without_salary"
        case excludeCompanies = "exclude_companies"
        case excludeIndustries = "exclude_industries"
        case excludeKeywords = "exclude_keywords"
        case dailyCap = "daily_cap"
        case perCompanyCooldownDays = "per_company_cooldown_days"
        case matchThreshold = "match_threshold"
        case mode
        case perAtsMode = "per_ats_mode"
        case perCompanyMode = "per_company_mode"
        case schedule
        case askConfidence = "ask_confidence"
        case ghostAfterDays = "ghost_after_days"
        case nudgeDays = "nudge_days"
        case linkedinSessionsPerDay = "linkedin_sessions_per_day"
        case glassdoorSessionsPerDay = "glassdoor_sessions_per_day"
        case searchesPerSession = "searches_per_session"
        case jobsPerSession = "jobs_per_session"
        case sourcesEnabled = "sources_enabled"
        case careerPageUrls = "career_page_urls"
        case alwaysAskPatterns = "always_ask_patterns"
    }
}

extension Preferences {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        seniority = try c.decodeIfPresent([Seniority].self, forKey: .seniority) ?? []
        locations = try c.decodeIfPresent([String].self, forKey: .locations) ?? []
        remotePolicy = try c.decodeIfPresent([RemotePolicy].self, forKey: .remotePolicy) ?? [.remote, .hybrid]
        workAuthSummary = try c.decodeIfPresent(String.self, forKey: .workAuthSummary)
        salaryFloor = try c.decodeIfPresent(Int.self, forKey: .salaryFloor)
        salaryCurrency = try c.decodeIfPresent(String.self, forKey: .salaryCurrency) ?? "USD"
        hideWithoutSalary = try c.decodeIfPresent(Bool.self, forKey: .hideWithoutSalary) ?? false
        excludeCompanies = try c.decodeIfPresent([String].self, forKey: .excludeCompanies) ?? []
        excludeIndustries = try c.decodeIfPresent([String].self, forKey: .excludeIndustries) ?? []
        excludeKeywords = try c.decodeIfPresent([String].self, forKey: .excludeKeywords) ?? []
        dailyCap = try c.decodeIfPresent(Int.self, forKey: .dailyCap) ?? 15
        perCompanyCooldownDays = try c.decodeIfPresent(Int.self, forKey: .perCompanyCooldownDays) ?? 30
        matchThreshold = try c.decodeIfPresent(Int.self, forKey: .matchThreshold) ?? 70
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .auto
        perAtsMode = try c.decodeIfPresent([String: Mode].self, forKey: .perAtsMode) ?? ["workday": .review]
        perCompanyMode = try c.decodeIfPresent([String: Mode].self, forKey: .perCompanyMode) ?? [:]
        schedule = try c.decodeIfPresent([String].self, forKey: .schedule) ?? ["09:00", "13:00", "18:00"]
        askConfidence = try c.decodeIfPresent(AskConfidence.self, forKey: .askConfidence) ?? .balanced
        ghostAfterDays = try c.decodeIfPresent(Int.self, forKey: .ghostAfterDays) ?? 21
        nudgeDays = try c.decodeIfPresent([Int].self, forKey: .nudgeDays) ?? [7, 14]
        linkedinSessionsPerDay = try c.decodeIfPresent(Int.self, forKey: .linkedinSessionsPerDay) ?? 3
        glassdoorSessionsPerDay = try c.decodeIfPresent(Int.self, forKey: .glassdoorSessionsPerDay) ?? 3
        searchesPerSession = try c.decodeIfPresent(Int.self, forKey: .searchesPerSession) ?? 3
        jobsPerSession = try c.decodeIfPresent(Int.self, forKey: .jobsPerSession) ?? 30
        sourcesEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .sourcesEnabled) ?? ["greenhouse": true, "lever": true, "ashby": true, "careers": true, "linkedin": false, "glassdoor": false]
        careerPageUrls = try c.decodeIfPresent([String].self, forKey: .careerPageUrls) ?? []
        alwaysAskPatterns = try c.decodeIfPresent([String].self, forKey: .alwaysAskPatterns) ?? []
    }
}

struct Profile: Codable, Sendable, Hashable {
    var fullName: String? = nil
    var firstName: String? = nil
    var lastName: String? = nil
    var email: String? = nil
    var phone: String? = nil
    var location: String? = nil
    var headline: String? = nil
    var summary: String? = nil
    var links: [String: String] = [:]
    var workHistory: [WorkHistoryItem] = []
    var education: [EducationItem] = []
    var skills: [String] = []
    var yearsExperience: Double? = nil
    var extra: [String: JSONValue] = [:]
    var rawText: String? = nil
    var updatedAt: Date? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case fullName = "full_name"
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case phone
        case location
        case headline
        case summary
        case links
        case workHistory = "work_history"
        case education
        case skills
        case yearsExperience = "years_experience"
        case extra
        case rawText = "raw_text"
        case updatedAt = "updated_at"
    }
}

extension Profile {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName)
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        links = try c.decodeIfPresent([String: String].self, forKey: .links) ?? [:]
        workHistory = try c.decodeIfPresent([WorkHistoryItem].self, forKey: .workHistory) ?? []
        education = try c.decodeIfPresent([EducationItem].self, forKey: .education) ?? []
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        yearsExperience = try c.decodeIfPresent(Double.self, forKey: .yearsExperience)
        extra = try c.decodeIfPresent([String: JSONValue].self, forKey: .extra) ?? [:]
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct Progress: Codable, Sendable, Hashable {
    var done: Int
    var total: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case done
        case total
    }
}

extension Progress {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        done = try c.decode(Int.self, forKey: .done)
        total = try c.decode(Int.self, forKey: .total)
    }
}

/// A Needs-You inbox cluster: semantically equivalent questions answered once.
struct QuestionCluster: Codable, Sendable, Hashable {
    var clusterId: String
    var canonicalQuestion: String
    var fieldType: FieldType = .text
    var options: [String] = []
    var neverGuessKey: String? = nil
    var reason: QuestionReason = .unknown
    var questionIds: [Int] = []
    var variants: [String] = []
    var jobIds: [Int] = []
    var jobCount: Int = 0
    var companies: [String] = []
    var createdAt: Date
    var suggestedAnswer: String? = nil
    var suggestedConfidence: Double? = nil
    var suggestedNote: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case clusterId = "cluster_id"
        case canonicalQuestion = "canonical_question"
        case fieldType = "field_type"
        case options
        case neverGuessKey = "never_guess_key"
        case reason
        case questionIds = "question_ids"
        case variants
        case jobIds = "job_ids"
        case jobCount = "job_count"
        case companies
        case createdAt = "created_at"
        case suggestedAnswer = "suggested_answer"
        case suggestedConfidence = "suggested_confidence"
        case suggestedNote = "suggested_note"
    }
}

extension QuestionCluster {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clusterId = try c.decode(String.self, forKey: .clusterId)
        canonicalQuestion = try c.decode(String.self, forKey: .canonicalQuestion)
        fieldType = try c.decodeIfPresent(FieldType.self, forKey: .fieldType) ?? .text
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        neverGuessKey = try c.decodeIfPresent(String.self, forKey: .neverGuessKey)
        reason = try c.decodeIfPresent(QuestionReason.self, forKey: .reason) ?? .unknown
        questionIds = try c.decodeIfPresent([Int].self, forKey: .questionIds) ?? []
        variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
        jobIds = try c.decodeIfPresent([Int].self, forKey: .jobIds) ?? []
        jobCount = try c.decodeIfPresent(Int.self, forKey: .jobCount) ?? 0
        companies = try c.decodeIfPresent([String].self, forKey: .companies) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        suggestedAnswer = try c.decodeIfPresent(String.self, forKey: .suggestedAnswer)
        suggestedConfidence = try c.decodeIfPresent(Double.self, forKey: .suggestedConfidence)
        suggestedNote = try c.decodeIfPresent(String.self, forKey: .suggestedNote)
    }
}

struct QuestionOpenedPayload: Codable, Sendable, Hashable {
    var cluster: QuestionCluster

    enum CodingKeys: String, CodingKey, CaseIterable {
        case cluster
    }
}

extension QuestionOpenedPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cluster = try c.decode(QuestionCluster.self, forKey: .cluster)
    }
}

struct QuestionResolvedPayload: Codable, Sendable, Hashable {
    enum Status: String, Codable, Sendable, CaseIterable, Hashable {
        case answered
        case skipped
    }
    var clusterId: String
    var status: Status
    var answerId: Int? = nil
    var resumedApplicationIds: [Int] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case clusterId = "cluster_id"
        case status
        case answerId = "answer_id"
        case resumedApplicationIds = "resumed_application_ids"
    }
}

extension QuestionResolvedPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clusterId = try c.decode(String.self, forKey: .clusterId)
        status = try c.decode(Status.self, forKey: .status)
        answerId = try c.decodeIfPresent(Int.self, forKey: .answerId)
        resumedApplicationIds = try c.decodeIfPresent([Int].self, forKey: .resumedApplicationIds) ?? []
    }
}

struct RejectPayload: Codable, Sendable, Hashable {
    var applicationId: Int
    var reason: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
        case reason
    }
}

extension RejectPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        reason = try c.decode(String.self, forKey: .reason)
    }
}

struct ResetSourceCapPayload: Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable, CaseIterable, Hashable {
        case linkedin
        case glassdoor
    }
    var source: Source

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source
    }
}

extension ResetSourceCapPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(Source.self, forKey: .source)
    }
}

struct ResolveUnknownPayload: Codable, Sendable, Hashable {
    var applicationId: Int
    var submitted: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
        case submitted
    }
}

extension ResolveUnknownPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        submitted = try c.decode(Bool.self, forKey: .submitted)
    }
}

struct ResumePayload: Codable, Sendable, Hashable {
}

extension ResumePayload {
    init(from decoder: any Decoder) throws {
    }
}

struct RetryApplicationPayload: Codable, Sendable, Hashable {
    var applicationId: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
    }
}

extension RetryApplicationPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
    }
}

struct RunFinishedPayload: Codable, Sendable, Hashable {
    var run: RunInfo

    enum CodingKeys: String, CodingKey, CaseIterable {
        case run
    }
}

extension RunFinishedPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decode(RunInfo.self, forKey: .run)
    }
}

struct RunInfo: Codable, Sendable, Hashable {
    var runId: String
    var kind: RunKind
    var trigger: RunTrigger = .manual
    var startedAt: Date
    var finishedAt: Date? = nil
    var outcome: RunOutcome? = nil
    var stats: RunStats = RunStats()
    var tokensIn: Int = 0
    var tokensOut: Int = 0

    enum CodingKeys: String, CodingKey, CaseIterable {
        case runId = "run_id"
        case kind
        case trigger
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case outcome
        case stats
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
    }
}

extension RunInfo {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        kind = try c.decode(RunKind.self, forKey: .kind)
        trigger = try c.decodeIfPresent(RunTrigger.self, forKey: .trigger) ?? .manual
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        outcome = try c.decodeIfPresent(RunOutcome.self, forKey: .outcome)
        stats = try c.decodeIfPresent(RunStats.self, forKey: .stats) ?? RunStats()
        tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
        tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
    }
}

struct RunNowPayload: Codable, Sendable, Hashable {
    var kind: RunKind = .full

    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
    }
}

extension RunNowPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(RunKind.self, forKey: .kind) ?? .full
    }
}

struct RunStartedPayload: Codable, Sendable, Hashable {
    var run: RunInfo

    enum CodingKeys: String, CodingKey, CaseIterable {
        case run
    }
}

extension RunStartedPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decode(RunInfo.self, forKey: .run)
    }
}

struct RunStats: Codable, Sendable, Hashable {
    var discovered: Int = 0
    var scored: Int = 0
    var skipped: Int = 0
    var queued: Int = 0
    var needsYou: Int = 0
    var awaitingReview: Int = 0
    var submitted: Int = 0
    var failed: Int = 0

    enum CodingKeys: String, CodingKey, CaseIterable {
        case discovered
        case scored
        case skipped
        case queued
        case needsYou = "needs_you"
        case awaitingReview = "awaiting_review"
        case submitted
        case failed
    }
}

extension RunStats {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        discovered = try c.decodeIfPresent(Int.self, forKey: .discovered) ?? 0
        scored = try c.decodeIfPresent(Int.self, forKey: .scored) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        needsYou = try c.decodeIfPresent(Int.self, forKey: .needsYou) ?? 0
        awaitingReview = try c.decodeIfPresent(Int.self, forKey: .awaitingReview) ?? 0
        submitted = try c.decodeIfPresent(Int.self, forKey: .submitted) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }
}

/// Swap the resume an application will use (Review ↻). An application awaiting review is
/// sent back to ``queued`` so the form is re-filled with the new file.
struct SetApplicationResumePayload: Codable, Sendable, Hashable {
    var applicationId: Int
    var resumeVariantId: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
        case resumeVariantId = "resume_variant_id"
    }
}

extension SetApplicationResumePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        resumeVariantId = try c.decode(Int.self, forKey: .resumeVariantId)
    }
}

struct SetJobModePayload: Codable, Sendable, Hashable {
    var jobId: Int
    var mode: Mode? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobId = "job_id"
        case mode
    }
}

extension SetJobModePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(Int.self, forKey: .jobId)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode)
    }
}

struct SetMailAccountPayload: Codable, Sendable, Hashable {
    var email: String
    var appPassword: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case email
        case appPassword = "app_password"
    }
}

extension SetMailAccountPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        appPassword = try c.decode(String.self, forKey: .appPassword)
    }
}

struct SetStatusPayload: Codable, Sendable, Hashable {
    var applicationId: Int
    var status: BoardStatus

    enum CodingKeys: String, CodingKey, CaseIterable {
        case applicationId = "application_id"
        case status
    }
}

extension SetStatusPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicationId = try c.decode(Int.self, forKey: .applicationId)
        status = try c.decode(BoardStatus.self, forKey: .status)
    }
}

struct SkipQuestionPayload: Codable, Sendable, Hashable {
    var clusterId: String
    var reason: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case clusterId = "cluster_id"
        case reason
    }
}

extension SkipQuestionPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clusterId = try c.decode(String.self, forKey: .clusterId)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// Full live state. Sent as the reply to ``hello`` (and on demand).
struct SnapshotPayload: Codable, Sendable, Hashable {
    var protocolVersion: Int = 1
    var daemonVersion: String
    var state: StatePayload
    var mode: Mode
    var nextRunAt: Date? = nil
    var currentRun: RunInfo? = nil
    var lastRun: RunInfo? = nil
    var counts: Counts = Counts()
    var caps: CapsStatus = CapsStatus()
    var openClusters: [QuestionCluster] = []
    var sources: [SourceStatus] = []
    var onboarding: OnboardingState = OnboardingState()
    var preferences: Preferences

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol_version"
        case daemonVersion = "daemon_version"
        case state
        case mode
        case nextRunAt = "next_run_at"
        case currentRun = "current_run"
        case lastRun = "last_run"
        case counts
        case caps
        case openClusters = "open_clusters"
        case sources
        case onboarding
        case preferences
    }
}

extension SnapshotPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        daemonVersion = try c.decode(String.self, forKey: .daemonVersion)
        state = try c.decode(StatePayload.self, forKey: .state)
        mode = try c.decode(Mode.self, forKey: .mode)
        nextRunAt = try c.decodeIfPresent(Date.self, forKey: .nextRunAt)
        currentRun = try c.decodeIfPresent(RunInfo.self, forKey: .currentRun)
        lastRun = try c.decodeIfPresent(RunInfo.self, forKey: .lastRun)
        counts = try c.decodeIfPresent(Counts.self, forKey: .counts) ?? Counts()
        caps = try c.decodeIfPresent(CapsStatus.self, forKey: .caps) ?? CapsStatus()
        openClusters = try c.decodeIfPresent([QuestionCluster].self, forKey: .openClusters) ?? []
        sources = try c.decodeIfPresent([SourceStatus].self, forKey: .sources) ?? []
        onboarding = try c.decodeIfPresent(OnboardingState.self, forKey: .onboarding) ?? OnboardingState()
        preferences = try c.decode(Preferences.self, forKey: .preferences)
    }
}

struct SourceStatus: Codable, Sendable, Hashable {
    var source: SourceName
    var enabled: Bool = true
    var connected: Bool = false
    var checkedAt: Date? = nil
    var detail: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case enabled
        case connected
        case checkedAt = "checked_at"
        case detail
    }
}

extension SourceStatus {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(SourceName.self, forKey: .source)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

struct SourceStatusPayload: Codable, Sendable, Hashable {
    var source: SourceStatus

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source
    }
}

extension SourceStatusPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(SourceStatus.self, forKey: .source)
    }
}

struct StatePayload: Codable, Sendable, Hashable {
    var daemon: DaemonActivity
    var paused: Bool = false
    var runId: String? = nil
    var progress: Progress? = nil
    var message: String? = nil
    var activeApplicationId: Int? = nil
    var activeJobId: Int? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case daemon
        case paused
        case runId = "run_id"
        case progress
        case message
        case activeApplicationId = "active_application_id"
        case activeJobId = "active_job_id"
    }
}

extension StatePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemon = try c.decode(DaemonActivity.self, forKey: .daemon)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        progress = try c.decodeIfPresent(Progress.self, forKey: .progress)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        activeApplicationId = try c.decodeIfPresent(Int.self, forKey: .activeApplicationId)
        activeJobId = try c.decodeIfPresent(Int.self, forKey: .activeJobId)
    }
}

struct SystemCheckItem: Codable, Sendable, Hashable {
    enum Name: String, Codable, Sendable, CaseIterable, Hashable {
        case claudeCli = "claude_cli"
        case uv
        case node
        case autoapplyd
        case chrome
    }
    var name: Name
    var ok: Bool
    var required: Bool = true
    var version: String? = nil
    var detail: String? = nil
    var fixCommand: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case ok
        case required
        case version
        case detail
        case fixCommand = "fix_command"
    }
}

extension SystemCheckItem {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(Name.self, forKey: .name)
        ok = try c.decode(Bool.self, forKey: .ok)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        version = try c.decodeIfPresent(String.self, forKey: .version)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        fixCommand = try c.decodeIfPresent(String.self, forKey: .fixCommand)
    }
}

/// ``ack.result`` for ``onboarding_system_check``.
struct SystemCheckResult: Codable, Sendable, Hashable {
    var items: [SystemCheckItem]
    var allRequiredOk: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case items
        case allRequiredOk = "all_required_ok"
    }
}

extension SystemCheckResult {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([SystemCheckItem].self, forKey: .items)
        allRequiredOk = try c.decode(Bool.self, forKey: .allRequiredOk)
    }
}

struct UpdateAnswerPayload: Codable, Sendable, Hashable {
    var answerId: Int
    var answer: String
    var canonicalQuestion: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case answerId = "answer_id"
        case answer
        case canonicalQuestion = "canonical_question"
    }
}

extension UpdateAnswerPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answerId = try c.decode(Int.self, forKey: .answerId)
        answer = try c.decode(String.self, forKey: .answer)
        canonicalQuestion = try c.decodeIfPresent(String.self, forKey: .canonicalQuestion)
    }
}

struct UpdateJobNotesPayload: Codable, Sendable, Hashable {
    var jobId: Int
    var notes: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jobId = "job_id"
        case notes
    }
}

extension UpdateJobNotesPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(Int.self, forKey: .jobId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

struct UpdateNeverGuessPayload: Codable, Sendable, Hashable {
    var values: NeverGuessPatch

    enum CodingKeys: String, CodingKey, CaseIterable {
        case values
    }
}

extension UpdateNeverGuessPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decode(NeverGuessPatch.self, forKey: .values)
    }
}

struct UpdatePreferencesPayload: Codable, Sendable, Hashable {
    var preferences: PreferencesPatch

    enum CodingKeys: String, CodingKey, CaseIterable {
        case preferences
    }
}

extension UpdatePreferencesPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferences = try c.decode(PreferencesPatch.self, forKey: .preferences)
    }
}

struct UpdateProfilePayload: Codable, Sendable, Hashable {
    var profile: ProfilePatch

    enum CodingKeys: String, CodingKey, CaseIterable {
        case profile
    }
}

extension UpdateProfilePayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(ProfilePatch.self, forKey: .profile)
    }
}

struct UpdateResumeVariantPayload: Codable, Sendable, Hashable {
    var id: Int
    var label: String? = nil
    var tags: [String]? = nil
    var enabled: Bool? = nil
    var isDefault: Bool? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case label
        case tags
        case enabled
        case isDefault = "is_default"
    }
}

extension UpdateResumeVariantPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
    }
}

struct UpsertStoryPayload: Codable, Sendable, Hashable {
    var id: Int? = nil
    var title: String
    var situation: String = ""
    var task: String = ""
    var action: String = ""
    var result: String = ""
    var tags: [String] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case title
        case situation
        case task
        case action
        case result
        case tags
    }
}

extension UpsertStoryPayload {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        situation = try c.decodeIfPresent(String.self, forKey: .situation) ?? ""
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

struct WorkHistoryItem: Codable, Sendable, Hashable {
    var company: String
    var title: String
    var start: String? = nil
    var end: String? = nil
    var location: String? = nil
    var highlights: [String] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case company
        case title
        case start
        case end
        case location
        case highlights
    }
}

extension WorkHistoryItem {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        company = try c.decode(String.self, forKey: .company)
        title = try c.decode(String.self, forKey: .title)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        highlights = try c.decodeIfPresent([String].self, forKey: .highlights) ?? []
    }
}

// MARK: - Patches

/// Partial `NeverGuess` for update commands. Only keys present are applied by the daemon;
/// an explicit `.null` clears the value (e.g. never-guess "always ask me").
struct NeverGuessPatch: Codable, Sendable, Hashable {
    typealias Key = NeverGuess.CodingKeys
    var values: [String: JSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }

    /// Set `key` to `value` (`nil` encodes an explicit JSON null).
    mutating func set<T: Encodable>(_ key: Key, _ value: T?) throws {
        if let value {
            values[key.rawValue] = try JSONValue.encode(value)
        } else {
            values[key.rawValue] = .null
        }
    }

    /// Remove `key` from the patch (leave the stored value unchanged).
    mutating func unset(_ key: Key) {
        values.removeValue(forKey: key.rawValue)
    }

    var isEmpty: Bool { values.isEmpty }
}

/// Partial `Preferences` for update commands. Only keys present are applied by the daemon;
/// an explicit `.null` clears the value (e.g. never-guess "always ask me").
struct PreferencesPatch: Codable, Sendable, Hashable {
    typealias Key = Preferences.CodingKeys
    var values: [String: JSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }

    /// Set `key` to `value` (`nil` encodes an explicit JSON null).
    mutating func set<T: Encodable>(_ key: Key, _ value: T?) throws {
        if let value {
            values[key.rawValue] = try JSONValue.encode(value)
        } else {
            values[key.rawValue] = .null
        }
    }

    /// Remove `key` from the patch (leave the stored value unchanged).
    mutating func unset(_ key: Key) {
        values.removeValue(forKey: key.rawValue)
    }

    var isEmpty: Bool { values.isEmpty }
}

/// Partial `Profile` for update commands. Only keys present are applied by the daemon;
/// an explicit `.null` clears the value (e.g. never-guess "always ask me").
struct ProfilePatch: Codable, Sendable, Hashable {
    typealias Key = Profile.CodingKeys
    var values: [String: JSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }

    /// Set `key` to `value` (`nil` encodes an explicit JSON null).
    mutating func set<T: Encodable>(_ key: Key, _ value: T?) throws {
        if let value {
            values[key.rawValue] = try JSONValue.encode(value)
        } else {
            values[key.rawValue] = .null
        }
    }

    /// Remove `key` from the patch (leave the stored value unchanged).
    mutating func unset(_ key: Key) {
        values.removeValue(forKey: key.rawValue)
    }

    var isEmpty: Bool { values.isEmpty }
}

// MARK: - Messages

/// App -> daemon commands (contract/protocol.md §5).
enum Command: Sendable, Hashable {
    case hello(HelloPayload)
    case ping(PingPayload)
    case runNow(RunNowPayload)
    case pauseAll(PauseAllPayload)
    case resume(ResumePayload)
    case answerQuestion(AnswerQuestionPayload)
    case skipQuestion(SkipQuestionPayload)
    case approve(ApprovePayload)
    case reject(RejectPayload)
    case setStatus(SetStatusPayload)
    case updatePreferences(UpdatePreferencesPayload)
    case updateNeverGuess(UpdateNeverGuessPayload)
    case updateProfile(UpdateProfilePayload)
    case addResumeVariant(AddResumeVariantPayload)
    case updateResumeVariant(UpdateResumeVariantPayload)
    case upsertStory(UpsertStoryPayload)
    case deleteStory(DeleteStoryPayload)
    case updateAnswer(UpdateAnswerPayload)
    case deleteAnswer(DeleteAnswerPayload)
    case editApplicationAnswer(EditApplicationAnswerPayload)
    case setJobMode(SetJobModePayload)
    case retryApplication(RetryApplicationPayload)
    case resolveUnknown(ResolveUnknownPayload)
    case applyAnyway(ApplyAnywayPayload)
    case updateJobNotes(UpdateJobNotesPayload)
    case setApplicationResume(SetApplicationResumePayload)
    case markEasyApplyDone(MarkEasyApplyDonePayload)
    case markEasyApplyOpened(MarkEasyApplyOpenedPayload)
    case dismissEasyApply(DismissEasyApplyPayload)
    case openAgentChrome(OpenAgentChromePayload)
    case onboardingSystemCheck(OnboardingSystemCheckPayload)
    case onboardingParseResume(OnboardingParseResumePayload)
    case onboardingConnectSource(OnboardingConnectSourcePayload)
    case checkSourceLogin(CheckSourceLoginPayload)
    case resetSourceCap(ResetSourceCapPayload)
    case setMailAccount(SetMailAccountPayload)
    case getMailAccount(GetMailAccountPayload)
    case clearMailAccount(ClearMailAccountPayload)
    case onboardingSetStep(OnboardingSetStepPayload)
    case onboardingComplete(OnboardingCompletePayload)

    /// Wire `type` string.
    var type: String {
        switch self {
        case .hello: "hello"
        case .ping: "ping"
        case .runNow: "run_now"
        case .pauseAll: "pause_all"
        case .resume: "resume"
        case .answerQuestion: "answer_question"
        case .skipQuestion: "skip_question"
        case .approve: "approve"
        case .reject: "reject"
        case .setStatus: "set_status"
        case .updatePreferences: "update_preferences"
        case .updateNeverGuess: "update_never_guess"
        case .updateProfile: "update_profile"
        case .addResumeVariant: "add_resume_variant"
        case .updateResumeVariant: "update_resume_variant"
        case .upsertStory: "upsert_story"
        case .deleteStory: "delete_story"
        case .updateAnswer: "update_answer"
        case .deleteAnswer: "delete_answer"
        case .editApplicationAnswer: "edit_application_answer"
        case .setJobMode: "set_job_mode"
        case .retryApplication: "retry_application"
        case .resolveUnknown: "resolve_unknown"
        case .applyAnyway: "apply_anyway"
        case .updateJobNotes: "update_job_notes"
        case .setApplicationResume: "set_application_resume"
        case .markEasyApplyDone: "mark_easy_apply_done"
        case .markEasyApplyOpened: "mark_easy_apply_opened"
        case .dismissEasyApply: "dismiss_easy_apply"
        case .openAgentChrome: "open_agent_chrome"
        case .onboardingSystemCheck: "onboarding_system_check"
        case .onboardingParseResume: "onboarding_parse_resume"
        case .onboardingConnectSource: "onboarding_connect_source"
        case .checkSourceLogin: "check_source_login"
        case .resetSourceCap: "reset_source_cap"
        case .setMailAccount: "set_mail_account"
        case .getMailAccount: "get_mail_account"
        case .clearMailAccount: "clear_mail_account"
        case .onboardingSetStep: "onboarding_set_step"
        case .onboardingComplete: "onboarding_complete"
        }
    }

    static let allTypes: [String] = [
        "hello",
        "ping",
        "run_now",
        "pause_all",
        "resume",
        "answer_question",
        "skip_question",
        "approve",
        "reject",
        "set_status",
        "update_preferences",
        "update_never_guess",
        "update_profile",
        "add_resume_variant",
        "update_resume_variant",
        "upsert_story",
        "delete_story",
        "update_answer",
        "delete_answer",
        "edit_application_answer",
        "set_job_mode",
        "retry_application",
        "resolve_unknown",
        "apply_anyway",
        "update_job_notes",
        "set_application_resume",
        "mark_easy_apply_done",
        "mark_easy_apply_opened",
        "dismiss_easy_apply",
        "open_agent_chrome",
        "onboarding_system_check",
        "onboarding_parse_resume",
        "onboarding_connect_source",
        "check_source_login",
        "reset_source_cap",
        "set_mail_account",
        "get_mail_account",
        "clear_mail_account",
        "onboarding_set_step",
        "onboarding_complete",
    ]
}

/// Daemon -> app events (contract/protocol.md §6). Unknown types decode to `.unknown`.
enum DaemonEvent: Sendable, Hashable {
    case ack(AckPayload)
    case error(ErrorPayload)
    case snapshot(SnapshotPayload)
    case state(StatePayload)
    case runStarted(RunStartedPayload)
    case runFinished(RunFinishedPayload)
    case jobDiscovered(JobDiscoveredPayload)
    case jobScored(JobScoredPayload)
    case applicationState(ApplicationStatePayload)
    case applicationStatus(ApplicationStatusPayload)
    case questionOpened(QuestionOpenedPayload)
    case questionResolved(QuestionResolvedPayload)
    case agentStep(AgentStepPayload)
    case capReached(CapReachedPayload)
    case sourceStatus(SourceStatusPayload)
    case nudgeDue(NudgeDuePayload)
    case log(LogPayload)
    case unknown(type: String, payload: JSONValue)

    /// Wire `type` string.
    var type: String {
        switch self {
        case .ack: "ack"
        case .error: "error"
        case .snapshot: "snapshot"
        case .state: "state"
        case .runStarted: "run_started"
        case .runFinished: "run_finished"
        case .jobDiscovered: "job_discovered"
        case .jobScored: "job_scored"
        case .applicationState: "application_state"
        case .applicationStatus: "application_status"
        case .questionOpened: "question_opened"
        case .questionResolved: "question_resolved"
        case .agentStep: "agent_step"
        case .capReached: "cap_reached"
        case .sourceStatus: "source_status"
        case .nudgeDue: "nudge_due"
        case .log: "log"
        case .unknown(let type, _): type
        }
    }

    static let allTypes: [String] = [
        "ack",
        "error",
        "snapshot",
        "state",
        "run_started",
        "run_finished",
        "job_discovered",
        "job_scored",
        "application_state",
        "application_status",
        "question_opened",
        "question_resolved",
        "agent_step",
        "cap_reached",
        "source_status",
        "nudge_due",
        "log",
    ]

    /// Event types that always carry `reply_to`.
    static let replyTypes: Set<String> = [
        "ack",
    ]
}

/// `{"v":1,"id":…,"type":…,"payload":{…}}` carrying a command.
struct CommandEnvelope: Codable, Sendable, Hashable {
    var v: Int = ProtocolCoding.version
    var id: String = ProtocolCoding.newID()
    var command: Command

    init(id: String = ProtocolCoding.newID(), command: Command) {
        self.id = id
        self.command = command
    }

    enum CodingKeys: String, CodingKey {
        case v, id, type, payload
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello": command = .hello(try c.decode(HelloPayload.self, forKey: .payload))
        case "ping": command = .ping(try c.decode(PingPayload.self, forKey: .payload))
        case "run_now": command = .runNow(try c.decode(RunNowPayload.self, forKey: .payload))
        case "pause_all": command = .pauseAll(try c.decode(PauseAllPayload.self, forKey: .payload))
        case "resume": command = .resume(try c.decode(ResumePayload.self, forKey: .payload))
        case "answer_question": command = .answerQuestion(try c.decode(AnswerQuestionPayload.self, forKey: .payload))
        case "skip_question": command = .skipQuestion(try c.decode(SkipQuestionPayload.self, forKey: .payload))
        case "approve": command = .approve(try c.decode(ApprovePayload.self, forKey: .payload))
        case "reject": command = .reject(try c.decode(RejectPayload.self, forKey: .payload))
        case "set_status": command = .setStatus(try c.decode(SetStatusPayload.self, forKey: .payload))
        case "update_preferences": command = .updatePreferences(try c.decode(UpdatePreferencesPayload.self, forKey: .payload))
        case "update_never_guess": command = .updateNeverGuess(try c.decode(UpdateNeverGuessPayload.self, forKey: .payload))
        case "update_profile": command = .updateProfile(try c.decode(UpdateProfilePayload.self, forKey: .payload))
        case "add_resume_variant": command = .addResumeVariant(try c.decode(AddResumeVariantPayload.self, forKey: .payload))
        case "update_resume_variant": command = .updateResumeVariant(try c.decode(UpdateResumeVariantPayload.self, forKey: .payload))
        case "upsert_story": command = .upsertStory(try c.decode(UpsertStoryPayload.self, forKey: .payload))
        case "delete_story": command = .deleteStory(try c.decode(DeleteStoryPayload.self, forKey: .payload))
        case "update_answer": command = .updateAnswer(try c.decode(UpdateAnswerPayload.self, forKey: .payload))
        case "delete_answer": command = .deleteAnswer(try c.decode(DeleteAnswerPayload.self, forKey: .payload))
        case "edit_application_answer": command = .editApplicationAnswer(try c.decode(EditApplicationAnswerPayload.self, forKey: .payload))
        case "set_job_mode": command = .setJobMode(try c.decode(SetJobModePayload.self, forKey: .payload))
        case "retry_application": command = .retryApplication(try c.decode(RetryApplicationPayload.self, forKey: .payload))
        case "resolve_unknown": command = .resolveUnknown(try c.decode(ResolveUnknownPayload.self, forKey: .payload))
        case "apply_anyway": command = .applyAnyway(try c.decode(ApplyAnywayPayload.self, forKey: .payload))
        case "update_job_notes": command = .updateJobNotes(try c.decode(UpdateJobNotesPayload.self, forKey: .payload))
        case "set_application_resume": command = .setApplicationResume(try c.decode(SetApplicationResumePayload.self, forKey: .payload))
        case "mark_easy_apply_done": command = .markEasyApplyDone(try c.decode(MarkEasyApplyDonePayload.self, forKey: .payload))
        case "mark_easy_apply_opened": command = .markEasyApplyOpened(try c.decode(MarkEasyApplyOpenedPayload.self, forKey: .payload))
        case "dismiss_easy_apply": command = .dismissEasyApply(try c.decode(DismissEasyApplyPayload.self, forKey: .payload))
        case "open_agent_chrome": command = .openAgentChrome(try c.decode(OpenAgentChromePayload.self, forKey: .payload))
        case "onboarding_system_check": command = .onboardingSystemCheck(try c.decode(OnboardingSystemCheckPayload.self, forKey: .payload))
        case "onboarding_parse_resume": command = .onboardingParseResume(try c.decode(OnboardingParseResumePayload.self, forKey: .payload))
        case "onboarding_connect_source": command = .onboardingConnectSource(try c.decode(OnboardingConnectSourcePayload.self, forKey: .payload))
        case "check_source_login": command = .checkSourceLogin(try c.decode(CheckSourceLoginPayload.self, forKey: .payload))
        case "reset_source_cap": command = .resetSourceCap(try c.decode(ResetSourceCapPayload.self, forKey: .payload))
        case "set_mail_account": command = .setMailAccount(try c.decode(SetMailAccountPayload.self, forKey: .payload))
        case "get_mail_account": command = .getMailAccount(try c.decode(GetMailAccountPayload.self, forKey: .payload))
        case "clear_mail_account": command = .clearMailAccount(try c.decode(ClearMailAccountPayload.self, forKey: .payload))
        case "onboarding_set_step": command = .onboardingSetStep(try c.decode(OnboardingSetStepPayload.self, forKey: .payload))
        case "onboarding_complete": command = .onboardingComplete(try c.decode(OnboardingCompletePayload.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown command type \(type)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(command.type, forKey: .type)
        switch command {
        case .hello(let p): try c.encode(p, forKey: .payload)
        case .ping(let p): try c.encode(p, forKey: .payload)
        case .runNow(let p): try c.encode(p, forKey: .payload)
        case .pauseAll(let p): try c.encode(p, forKey: .payload)
        case .resume(let p): try c.encode(p, forKey: .payload)
        case .answerQuestion(let p): try c.encode(p, forKey: .payload)
        case .skipQuestion(let p): try c.encode(p, forKey: .payload)
        case .approve(let p): try c.encode(p, forKey: .payload)
        case .reject(let p): try c.encode(p, forKey: .payload)
        case .setStatus(let p): try c.encode(p, forKey: .payload)
        case .updatePreferences(let p): try c.encode(p, forKey: .payload)
        case .updateNeverGuess(let p): try c.encode(p, forKey: .payload)
        case .updateProfile(let p): try c.encode(p, forKey: .payload)
        case .addResumeVariant(let p): try c.encode(p, forKey: .payload)
        case .updateResumeVariant(let p): try c.encode(p, forKey: .payload)
        case .upsertStory(let p): try c.encode(p, forKey: .payload)
        case .deleteStory(let p): try c.encode(p, forKey: .payload)
        case .updateAnswer(let p): try c.encode(p, forKey: .payload)
        case .deleteAnswer(let p): try c.encode(p, forKey: .payload)
        case .editApplicationAnswer(let p): try c.encode(p, forKey: .payload)
        case .setJobMode(let p): try c.encode(p, forKey: .payload)
        case .retryApplication(let p): try c.encode(p, forKey: .payload)
        case .resolveUnknown(let p): try c.encode(p, forKey: .payload)
        case .applyAnyway(let p): try c.encode(p, forKey: .payload)
        case .updateJobNotes(let p): try c.encode(p, forKey: .payload)
        case .setApplicationResume(let p): try c.encode(p, forKey: .payload)
        case .markEasyApplyDone(let p): try c.encode(p, forKey: .payload)
        case .markEasyApplyOpened(let p): try c.encode(p, forKey: .payload)
        case .dismissEasyApply(let p): try c.encode(p, forKey: .payload)
        case .openAgentChrome(let p): try c.encode(p, forKey: .payload)
        case .onboardingSystemCheck(let p): try c.encode(p, forKey: .payload)
        case .onboardingParseResume(let p): try c.encode(p, forKey: .payload)
        case .onboardingConnectSource(let p): try c.encode(p, forKey: .payload)
        case .checkSourceLogin(let p): try c.encode(p, forKey: .payload)
        case .resetSourceCap(let p): try c.encode(p, forKey: .payload)
        case .setMailAccount(let p): try c.encode(p, forKey: .payload)
        case .getMailAccount(let p): try c.encode(p, forKey: .payload)
        case .clearMailAccount(let p): try c.encode(p, forKey: .payload)
        case .onboardingSetStep(let p): try c.encode(p, forKey: .payload)
        case .onboardingComplete(let p): try c.encode(p, forKey: .payload)
        }
    }
}

/// `{"v":1,"id":…,"type":…,"reply_to"?:…,"payload":{…}}` carrying an event.
struct EventEnvelope: Codable, Sendable, Hashable {
    var v: Int = ProtocolCoding.version
    var id: String = ProtocolCoding.newID()
    /// The command id this event answers (always set for `ack`; for `snapshot`/`error` when replying).
    var replyTo: String?
    var event: DaemonEvent

    init(id: String = ProtocolCoding.newID(), replyTo: String? = nil, event: DaemonEvent) {
        self.id = id
        self.replyTo = replyTo
        self.event = event
    }

    enum CodingKeys: String, CodingKey {
        case v, id, type, payload
        case replyTo = "reply_to"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ack": event = .ack(try c.decode(AckPayload.self, forKey: .payload))
        case "error": event = .error(try c.decode(ErrorPayload.self, forKey: .payload))
        case "snapshot": event = .snapshot(try c.decode(SnapshotPayload.self, forKey: .payload))
        case "state": event = .state(try c.decode(StatePayload.self, forKey: .payload))
        case "run_started": event = .runStarted(try c.decode(RunStartedPayload.self, forKey: .payload))
        case "run_finished": event = .runFinished(try c.decode(RunFinishedPayload.self, forKey: .payload))
        case "job_discovered": event = .jobDiscovered(try c.decode(JobDiscoveredPayload.self, forKey: .payload))
        case "job_scored": event = .jobScored(try c.decode(JobScoredPayload.self, forKey: .payload))
        case "application_state": event = .applicationState(try c.decode(ApplicationStatePayload.self, forKey: .payload))
        case "application_status": event = .applicationStatus(try c.decode(ApplicationStatusPayload.self, forKey: .payload))
        case "question_opened": event = .questionOpened(try c.decode(QuestionOpenedPayload.self, forKey: .payload))
        case "question_resolved": event = .questionResolved(try c.decode(QuestionResolvedPayload.self, forKey: .payload))
        case "agent_step": event = .agentStep(try c.decode(AgentStepPayload.self, forKey: .payload))
        case "cap_reached": event = .capReached(try c.decode(CapReachedPayload.self, forKey: .payload))
        case "source_status": event = .sourceStatus(try c.decode(SourceStatusPayload.self, forKey: .payload))
        case "nudge_due": event = .nudgeDue(try c.decode(NudgeDuePayload.self, forKey: .payload))
        case "log": event = .log(try c.decode(LogPayload.self, forKey: .payload))
        default:
            event = .unknown(type: type, payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:]))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(replyTo, forKey: .replyTo)
        try c.encode(event.type, forKey: .type)
        switch event {
        case .ack(let p): try c.encode(p, forKey: .payload)
        case .error(let p): try c.encode(p, forKey: .payload)
        case .snapshot(let p): try c.encode(p, forKey: .payload)
        case .state(let p): try c.encode(p, forKey: .payload)
        case .runStarted(let p): try c.encode(p, forKey: .payload)
        case .runFinished(let p): try c.encode(p, forKey: .payload)
        case .jobDiscovered(let p): try c.encode(p, forKey: .payload)
        case .jobScored(let p): try c.encode(p, forKey: .payload)
        case .applicationState(let p): try c.encode(p, forKey: .payload)
        case .applicationStatus(let p): try c.encode(p, forKey: .payload)
        case .questionOpened(let p): try c.encode(p, forKey: .payload)
        case .questionResolved(let p): try c.encode(p, forKey: .payload)
        case .agentStep(let p): try c.encode(p, forKey: .payload)
        case .capReached(let p): try c.encode(p, forKey: .payload)
        case .sourceStatus(let p): try c.encode(p, forKey: .payload)
        case .nudgeDue(let p): try c.encode(p, forKey: .payload)
        case .log(let p): try c.encode(p, forKey: .payload)
        case .unknown(_, let payload): try c.encode(payload, forKey: .payload)
        }
    }
}
