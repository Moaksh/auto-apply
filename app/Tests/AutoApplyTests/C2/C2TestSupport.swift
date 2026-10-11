// C2TestSupport.swift — shared builders for the C2 (Dashboard / Board / Job detail / Activity)
// tests. Builds on C1's TestSupport (StubDaemon, Samples, waitUntil).
import Foundation
@testable import AutoApply

enum C2 {
    static let now = Samples.now
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    static func job(id: Int, company: String = "Stripe", title: String = "Backend Engineer", state: AppState = .queued,
                    status: BoardStatus? = nil, score: Int? = nil, source: JobSource = .greenhouse, ats: Ats = .greenhouse,
                    discoveredAt: Date = Samples.now, submittedAt: Date? = nil, skipReason: String? = nil) -> JobItem {
        var j = JobItem(id: id, applicationID: id, companyID: id, company: company, title: title,
                        source: source, ats: ats, discoveredAt: discoveredAt)
        j.state = state
        j.status = status
        j.score = score
        j.submittedAt = submittedAt
        j.skipReason = skipReason
        j.stateReason = skipReason
        return j
    }

    static func event(id: Int, ts: Date = Samples.now, kind: String = "fill", actor: Actor = .agent, level: LogLevel = .info,
                      jobID: Int? = nil, runID: Int? = nil, message: String = "filled 9 standard fields") -> ActivityEvent {
        ActivityEvent(id: id, ts: ts, kind: kind, actor: actor, level: level, runID: runID, jobID: jobID, applicationID: jobID, message: message)
    }

    @MainActor
    static func store(jobs: [JobItem], daemon: StubDaemon = StubDaemon()) -> (AppStore, StubDaemon) {
        var data = RepositoryData()
        data.jobs = jobs
        let store = AppStore(client: daemon, repository: InMemoryRepository(data))
        store.commandTimeout = .milliseconds(150)
        store.jobs.replaceAll(jobs)
        return (store, daemon)
    }

    /// Board statuses sent via set_status, in order.
    static func sentStatuses(_ daemon: StubDaemon) -> [BoardStatus] {
        daemon.sent.compactMap { if case .setStatus(let p) = $0 { p.status } else { nil } }
    }

    static func isolatedDefaults() -> UserDefaults {
        let name = "c2-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
}
