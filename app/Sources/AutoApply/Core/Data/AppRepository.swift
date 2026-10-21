// AppRepository.swift — read-only access to durable state (SQLite via GRDB in production,
// fixtures in mock mode). Every method returns a stream that emits the current value
// immediately and again whenever the underlying data changes.
import Foundation

/// New rows appended to the (append-only) activity log.
struct ActivityDelta: Sendable {
    /// Rows in ascending id order.
    var appended: [ActivityEvent]
    /// True for the first emission (the initial page) — consumers replace instead of append.
    var isInitial: Bool
}

protocol AppRepository: AnyObject, Sendable {
    /// All jobs joined with company/application/score, newest discovered first.
    func jobs() -> AsyncStream<[JobItem]>
    /// Full JD text for one job (not included in `jobs()` to keep refreshes cheap).
    func jobDescription(jobID: Int) async -> String?
    /// The Q&A audit for one application, in form order.
    func applicationAnswers(applicationID: Int) -> AsyncStream<[ApplicationAnswerItem]>
    /// The activity log: the newest `initialLimit` rows first, then appended rows as they land.
    func activity(initialLimit: Int) -> AsyncStream<ActivityDelta>
    func resumeVariants() -> AsyncStream<[ResumeVariantItem]>
    func stories() -> AsyncStream<[StoryItem]>
    func memoryAnswers() -> AsyncStream<[MemoryAnswerItem]>
    func easyApply() -> AsyncStream<[EasyApplyItem]>
    /// Companies found while browsing (pending first, most matching roles first); empty on DBs older than v6.
    func companySuggestions() -> AsyncStream<[CompanySuggestionItem]>
    func profile() -> AsyncStream<Profile>
    func neverGuess() -> AsyncStream<NeverGuess>
    func runs(limit: Int) -> AsyncStream<[RunItem]>
    /// Cold outreach (schema v10): contacts, threads, messages, do-not-contact list, referrals,
    /// prospects and the mailbox's sending switch. Empty on older DBs.
    func outreach() -> AsyncStream<OutreachData>
    /// The provenance of one contact (`contact_evidence`), newest first.
    func contactEvidence(contactID: Int) async -> [ContactEvidenceItem]
    /// Employer replies (schema v11), newest first: every pending suggestion plus recent rows.
    func applicationReplies() -> AsyncStream<[ApplicationReplyItem]>
    /// Whether the backing store is currently readable (false e.g. before the daemon created the DB).
    var isAvailable: Bool { get }
}

/// JSON helpers for decoding DB TEXT columns.
enum DBJSON {
    static func decode<T: Decodable>(_ type: T.Type, from text: String?, default fallback: T) -> T {
        guard let text, let data = text.data(using: .utf8) else { return fallback }
        return (try? ProtocolCoding.makeDecoder().decode(T.self, from: data)) ?? fallback
    }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let d = ProtocolCoding.parseDate(text) { return d }
        // SQLite's default CURRENT_TIMESTAMP style ("2026-10-10 09:00:00").
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: text)
    }
}
