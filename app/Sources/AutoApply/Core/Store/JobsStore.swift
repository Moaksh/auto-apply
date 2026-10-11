// JobsStore.swift — durable job/application rows (GRDB) with optimistic event updates.
// The DB always wins: `replaceAll` (from the repository) overwrites optimistic edits.
import Foundation
import Observation

@MainActor
@Observable
final class JobsStore {
    /// All jobs, newest discovered first.
    private(set) var all: [JobItem] = []
    /// Jobs grouped by board column (each newest first by state update).
    private(set) var columns: [BoardColumn: [JobItem]] = [:]
    private(set) var stateCounts: [AppState: Int] = [:]
    /// True once the repository delivered its first value.
    private(set) var isLoaded = false
    /// Bumped on every change (cheap `onChange` trigger for derived views).
    private(set) var revision = 0

    @ObservationIgnored private var indexByJobID: [Int: Int] = [:]
    @ObservationIgnored private var indexByApplicationID: [Int: Int] = [:]
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var dirty = false

    init() {}

    // MARK: Queries

    func job(id: Int) -> JobItem? { indexByJobID[id].map { all[$0] } }
    func job(applicationID: Int) -> JobItem? { indexByApplicationID[applicationID].map { all[$0] } }
    func jobs(in column: BoardColumn) -> [JobItem] { columns[column] ?? [] }
    func count(_ state: AppState) -> Int { stateCounts[state, default: 0] }

    /// Applications waiting in the Review queue, low-confidence handled by the Review screen.
    var awaitingReview: [JobItem] { all.filter { $0.state == .awaitingReview } }
    var submitted: [JobItem] { all.filter { $0.state == .submitted } }

    func submittedCount(on day: Date, calendar: Calendar = .current) -> Int {
        all.reduce(0) { n, j in
            guard let s = j.submittedAt, calendar.isDate(s, inSameDayAs: day) else { return n }
            return n + 1
        }
    }

    func discoveredCount(on day: Date, calendar: Calendar = .current) -> Int {
        all.reduce(0) { $0 + (calendar.isDate($1.discoveredAt, inSameDayAs: day) ? 1 : 0) }
    }

    // MARK: Mutation

    /// Group several mutations into one recompute.
    func performBatch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        if batchDepth == 0 && dirty { recompute() }
    }

    func replaceAll(_ jobs: [JobItem]) {
        all = jobs
        isLoaded = true
        markDirty()
    }

    func mutate(jobID: Int, _ body: (inout JobItem) -> Void) {
        guard let i = indexByJobID[jobID] else { return }
        body(&all[i])
        markDirty()
    }

    func mutate(applicationID: Int, _ body: (inout JobItem) -> Void) {
        guard let i = indexByApplicationID[applicationID] else { return }
        body(&all[i])
        markDirty()
    }

    func applyState(_ p: ApplicationStatePayload) {
        let update: (inout JobItem) -> Void = { job in
            job.applicationID = p.applicationId
            job.state = p.toState
            job.stateReason = p.reason
            job.stateUpdatedAt = p.at
            if p.toState == .submitted {
                if job.submittedAt == nil { job.submittedAt = p.at }
                if job.status == nil { job.status = .applied; job.statusUpdatedAt = p.at }
            }
        }
        if indexByApplicationID[p.applicationId] != nil {
            mutate(applicationID: p.applicationId, update)
        } else {
            mutate(jobID: p.jobId, update)
        }
    }

    func applyStatus(_ p: ApplicationStatusPayload) {
        mutate(applicationID: p.applicationId) { job in
            job.status = p.status
            job.statusUpdatedAt = p.at
        }
    }

    func applyDiscovered(_ summary: JobSummary) {
        guard indexByJobID[summary.id] == nil else { return }
        all.insert(JobItem(summary: summary), at: 0)
        markDirty()
    }

    func applyScored(_ p: JobScoredPayload) {
        mutate(jobID: p.jobId) { job in
            job.applicationID = p.applicationId
            job.score = p.score
            job.skipReason = p.skipReason
            if case .string(let summary)? = p.reasons["summary"] { job.scoreSummary = summary }
            if case .object(let factors)? = p.reasons["factors"] {
                for (k, v) in factors {
                    if case .int(let i) = v { job.scoreFactors[k] = i }
                    if case .double(let d) = v { job.scoreFactors[k] = Int(d.rounded()) }
                }
            }
        }
    }

    private func markDirty() {
        dirty = true
        if batchDepth == 0 { recompute() }
    }

    private func recompute() {
        dirty = false
        var byJob: [Int: Int] = [:]
        var byApp: [Int: Int] = [:]
        var counts: [AppState: Int] = [:]
        var cols: [BoardColumn: [JobItem]] = [:]
        byJob.reserveCapacity(all.count)
        for (i, job) in all.enumerated() {
            byJob[job.id] = i
            if let a = job.applicationID { byApp[a] = i }
            counts[job.state, default: 0] += 1
            if let c = job.boardColumn { cols[c, default: []].append(job) }
        }
        for key in cols.keys {
            cols[key]?.sort { ($0.statusUpdatedAt ?? $0.stateUpdatedAt ?? $0.discoveredAt) > ($1.statusUpdatedAt ?? $1.stateUpdatedAt ?? $1.discoveredAt) }
        }
        indexByJobID = byJob
        indexByApplicationID = byApp
        stateCounts = counts
        columns = cols
        revision &+= 1
    }
}
