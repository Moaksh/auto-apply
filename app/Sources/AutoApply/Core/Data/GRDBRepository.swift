// GRDBRepository.swift — read-only SQLite access to autoapply.db (the daemon is the only writer).
//
// GRDB's ValueObservation only sees writes made through the same GRDB connection, and every
// write here comes from another process (autoapplyd). So change detection polls
// `PRAGMA data_version` (which changes whenever *another* connection commits) and re-runs
// the observed queries, emitting only when a result actually changed. Default poll: 0.5 s,
// which meets the "DB reconciles within a second" rule (docs/UI_UX_PLAN.md §8.4).
import Foundation
import GRDB
import Synchronization

final class GRDBRepository: AppRepository {
    let path: String
    let pollInterval: Duration

    private struct State {
        var queue: DatabaseQueue?
        var dataVersion: Int?
        var lastOpenError: String?
    }

    private let state = Mutex(State())
    private let changes = EventBroadcaster<Void>()
    private let poller = Mutex<Task<Void, Never>?>(nil)

    init(path: String, pollInterval: Duration = .milliseconds(500)) {
        self.path = path
        self.pollInterval = pollInterval
        startPolling()
    }

    convenience init(paths: AppPaths = .resolve()) {
        self.init(path: paths.database.path)
    }

    deinit {
        poller.withLock { $0?.cancel() }
        changes.finish()
    }

    var isAvailable: Bool { state.withLock { $0.queue != nil } }
    var lastOpenError: String? { state.withLock { $0.lastOpenError } }

    // MARK: - Change detection

    private func startPolling() {
        let interval = pollInterval
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
        poller.withLock { $0 = task }
    }

    /// One poll: open the DB if needed, compare data_version, broadcast on change.
    func pollOnce() async {
        guard let queue = openIfNeeded() else { return }
        do {
            let version = try await queue.read { db in try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0 }
            let changed = state.withLock { st -> Bool in
                defer { st.dataVersion = version }
                return st.dataVersion != version
            }
            if changed { changes.yield(()) }
        } catch {
            // The file may have been replaced (reset); reopen next tick.
            state.withLock { st in
                st.queue = nil
                st.dataVersion = nil
                st.lastOpenError = String(describing: error)
            }
        }
    }

    private func openIfNeeded() -> DatabaseQueue? {
        if let q = state.withLock({ $0.queue }) { return q }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            var config = Configuration()
            config.readonly = true
            config.label = "AutoApply.readonly"
            config.busyMode = .timeout(5)
            let queue = try DatabaseQueue(path: path, configuration: config)
            state.withLock { st in
                st.queue = queue
                st.lastOpenError = nil
            }
            return queue
        } catch {
            state.withLock { $0.lastOpenError = String(describing: error) }
            return nil
        }
    }

    private func read<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) async -> T? {
        guard let queue = state.withLock({ $0.queue }) ?? openIfNeeded() else { return nil }
        return try? await queue.read(fetch)
    }

    /// Emit `fetch` now and after every DB change, skipping unchanged results.
    private func observe<T: Sendable & Equatable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncStream<T> {
        let ticks = changes.stream(bufferingPolicy: .bufferingNewest(1))
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                var last: T?
                if let value = await self?.read(fetch) {
                    last = value
                    continuation.yield(value)
                }
                for await _ in ticks {
                    guard let self else { break }
                    if let value = await self.read(fetch), value != last {
                        last = value
                        continuation.yield(value)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - AppRepository

    func jobs() -> AsyncStream<[JobItem]> {
        observe { db in try Row.fetchAll(db, sql: Self.jobsSQL).map(Self.jobItem) }
    }

    /// Full JD text for one job (excluded from `jobs()` to keep list refreshes cheap).
    func jobDescription(jobID: Int) async -> String? {
        await read { db in try String.fetchOne(db, sql: "SELECT description FROM jobs WHERE id = ?", arguments: [jobID]) } ?? nil
    }

    func applicationAnswers(applicationID: Int) -> AsyncStream<[ApplicationAnswerItem]> {
        observe { db in
            try Row.fetchAll(db, sql: """
                SELECT id, application_id, field_key, question, answer, field_type, confidence, origin, origin_ref, bbox
                FROM application_answers WHERE application_id = ? ORDER BY id
                """, arguments: [applicationID]).map(Self.answerItem)
        }
    }

    func activity(initialLimit: Int) -> AsyncStream<ActivityDelta> {
        let ticks = changes.stream(bufferingPolicy: .bufferingNewest(1))
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                var lastID: Int?
                func fetch(_ repo: GRDBRepository) async -> ActivityDelta? {
                    if let after = lastID {
                        guard let rows = await repo.read({ db in
                            try Row.fetchAll(db, sql: "SELECT * FROM events WHERE id > ? ORDER BY id", arguments: [after]).map(Self.activityEvent)
                        }) else { return nil }
                        return ActivityDelta(appended: rows, isInitial: false)
                    }
                    guard let rows = await repo.read({ db in
                        try Row.fetchAll(db, sql: "SELECT * FROM events ORDER BY id DESC LIMIT ?", arguments: [initialLimit]).map(Self.activityEvent)
                    }) else { return nil }
                    return ActivityDelta(appended: rows.reversed(), isInitial: true)
                }
                if let repo = self, let delta = await fetch(repo) {
                    lastID = delta.appended.last?.id ?? 0
                    continuation.yield(delta)
                }
                for await _ in ticks {
                    guard let repo = self else { break }
                    guard let delta = await fetch(repo) else { continue }
                    if delta.isInitial {
                        lastID = delta.appended.last?.id ?? 0
                        continuation.yield(delta)
                    } else if !delta.appended.isEmpty {
                        lastID = delta.appended.last?.id ?? lastID
                        continuation.yield(delta)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func resumeVariants() -> AsyncStream<[ResumeVariantItem]> {
        observe { db in
            try Row.fetchAll(db, sql: "SELECT * FROM resume_variants WHERE replaced_by IS NULL ORDER BY is_default DESC, id").map { row in
                ResumeVariantItem(
                    id: row["id"], label: row["label"], filePath: row["file_path"],
                    tags: DBJSON.decode([String].self, from: row["tags"], default: []),
                    isDefault: (row["is_default"] as Int?) == 1, enabled: (row["enabled"] as Int?) != 0,
                    version: row["version"] ?? 1, replacedBy: row["replaced_by"],
                    createdAt: DBJSON.date(row["created_at"]) ?? .distantPast,
                    updatedAt: DBJSON.date(row["updated_at"]) ?? .distantPast)
            }
        }
    }

    func stories() -> AsyncStream<[StoryItem]> {
        observe { db in
            try Row.fetchAll(db, sql: "SELECT * FROM stories ORDER BY updated_at DESC, id DESC").map { row in
                StoryItem(id: row["id"], title: row["title"], situation: row["situation"] ?? "", task: row["task"] ?? "",
                          action: row["action"] ?? "", result: row["result"] ?? "",
                          tags: DBJSON.decode([String].self, from: row["tags"], default: []),
                          uses: row["uses"] ?? 0, updatedAt: DBJSON.date(row["updated_at"]) ?? .distantPast)
            }
        }
    }

    func memoryAnswers() -> AsyncStream<[MemoryAnswerItem]> {
        observe { db in
            try Row.fetchAll(db, sql: "SELECT * FROM answers ORDER BY uses DESC, updated_at DESC").map { row in
                MemoryAnswerItem(id: row["id"], canonicalQuestion: row["canonical_question"], answer: row["answer"],
                                 fieldType: FieldType(rawValue: row["field_type"] ?? "text") ?? .text,
                                 isTemplate: (row["is_template"] as Int?) == 1, source: row["source"] ?? "user",
                                 uses: row["uses"] ?? 0, lastUsedAt: DBJSON.date(row["last_used_at"]),
                                 updatedAt: DBJSON.date(row["updated_at"]) ?? .distantPast)
            }
        }
    }

    func easyApply() -> AsyncStream<[EasyApplyItem]> {
        observe { db in
            try Row.fetchAll(db, sql: "SELECT * FROM easy_apply ORDER BY done, created_at DESC").map { row in
                EasyApplyItem(id: row["id"], jobID: row["job_id"], url: row["url"],
                              draftedAnswers: DBJSON.decode([DraftedAnswer].self, from: row["drafted_answers"], default: []),
                              resumeVariantID: row["resume_variant_id"], opened: (row["opened"] as Int?) == 1,
                              done: (row["done"] as Int?) == 1, dismissed: (row["dismissed"] as Int?) == 1,
                              doneAt: DBJSON.date(row["done_at"]), createdAt: DBJSON.date(row["created_at"]) ?? .distantPast)
            }
        }
    }

    func companySuggestions() -> AsyncStream<[CompanySuggestionItem]> {
        observe { db in
            // The table arrives with schema v6; an older daemon's DB simply has no suggestions.
            guard try db.tableExists("company_suggestions") else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM company_suggestions WHERE status IN ('pending', 'auto')
                ORDER BY status = 'pending' DESC, matching_roles DESC, suggested_at DESC LIMIT 200
                """).map { row in
                CompanySuggestionItem(
                    id: row["id"], companyName: row["company_name"] ?? "", url: row["url"] ?? "",
                    ats: (row["ats"] as String?).flatMap(Ats.init(rawValue:)), boardToken: row["board_token"],
                    source: row["source"] ?? "", foundVia: row["found_via"], sampleTitle: row["sample_title"],
                    matchingRoles: row["matching_roles"] ?? 0, openRoles: row["open_roles"],
                    verified: (row["verified"] as Int?) == 1,
                    status: (row["status"] as String?).flatMap(CompanySuggestionItem.Status.init(rawValue:)) ?? .pending,
                    suggestedAt: DBJSON.date(row["suggested_at"]) ?? .distantPast)
            }
        }
    }

    func profile() -> AsyncStream<Profile> {
        observe { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM profile WHERE id = 1") else { return Profile() }
            var p = Profile()
            p.fullName = row["full_name"]
            p.firstName = row["first_name"]
            p.lastName = row["last_name"]
            p.email = row["email"]
            p.phone = row["phone"]
            p.location = row["location"]
            p.headline = row["headline"]
            p.summary = row["summary"]
            p.links = DBJSON.decode([String: String].self, from: row["links"], default: [:])
            p.workHistory = DBJSON.decode([WorkHistoryItem].self, from: row["work_history"], default: [])
            p.education = DBJSON.decode([EducationItem].self, from: row["education"], default: [])
            p.skills = DBJSON.decode([String].self, from: row["skills"], default: [])
            p.yearsExperience = row["years_experience"]
            p.extra = DBJSON.decode([String: JSONValue].self, from: row["extra"], default: [:])
            p.rawText = row["raw_text"]
            p.updatedAt = DBJSON.date(row["updated_at"])
            return p
        }
    }

    func neverGuess() -> AsyncStream<NeverGuess> {
        observe { db in
            var values: [String: JSONValue] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM never_guess") {
                let key: String = row["key"]
                let value = DBJSON.decode(JSONValue.self, from: row["value"], default: .null)
                if value != .null { values[key] = value }
            }
            return (try? JSONValue.object(values).decode(NeverGuess.self)) ?? NeverGuess()
        }
    }

    func runs(limit: Int) -> AsyncStream<[RunItem]> {
        observe { db in
            try Row.fetchAll(db, sql: "SELECT * FROM runs ORDER BY started_at DESC LIMIT ?", arguments: [limit]).map { row in
                RunItem(id: row["id"], runUID: row["run_uid"],
                        kind: RunKind(rawValue: row["kind"] ?? "full") ?? .full,
                        trigger: RunTrigger(rawValue: row["trigger"] ?? "manual") ?? .manual,
                        startedAt: DBJSON.date(row["started_at"]) ?? .distantPast,
                        finishedAt: DBJSON.date(row["finished_at"]),
                        outcome: (row["outcome"] as String?).flatMap(RunOutcome.init(rawValue:)),
                        stats: DBJSON.decode(RunStats.self, from: row["stats"], default: RunStats()),
                        tokensIn: row["tokens_in"] ?? 0, tokensOut: row["tokens_out"] ?? 0)
            }
        }
    }

    // MARK: - Row mapping

    static let jobsSQL = """
        SELECT j.id, j.source, j.source_url, j.apply_url, j.ats, j.company_id, j.title, j.location, j.remote,
               j.salary_min, j.salary_max, j.salary_currency, j.posted_at, j.discovered_at, j.easy_apply,
               j.mode_override, j.notes,
               c.name AS company_name, c.domain AS company_domain,
               a.id AS app_id, a.state, a.state_reason, a.state_updated_at, a.mode AS app_mode,
               a.resume_variant_id, a.resume_pick_score, a.cover_letter_path, a.screenshot_path,
               a.confirmation_screenshot_path, a.submitted_at, a.status, a.status_updated_at,
               a.nudges_sent, a.tokens_in, a.tokens_out,
               s.score, s.reasons, s.skip_reason, s.scored_at
        FROM jobs j
        JOIN companies c ON c.id = j.company_id
        LEFT JOIN applications a ON a.job_id = j.id
        LEFT JOIN scores s ON s.job_id = j.id
        ORDER BY j.discovered_at DESC, j.id DESC
        """

    static func jobItem(_ row: Row) -> JobItem {
        var job = JobItem(
            id: row["id"],
            applicationID: row["app_id"],
            companyID: row["company_id"],
            company: row["company_name"] ?? "Unknown",
            companyDomain: row["company_domain"],
            title: row["title"] ?? "",
            location: row["location"],
            remote: (row["remote"] as String?).flatMap(RemotePolicy.init(rawValue:)),
            source: JobSource(rawValue: row["source"] ?? "") ?? .manual,
            ats: Ats(rawValue: row["ats"] ?? "") ?? .other,
            applyURL: row["apply_url"],
            sourceURL: row["source_url"],
            easyApply: (row["easy_apply"] as Int?) == 1,
            discoveredAt: DBJSON.date(row["discovered_at"]) ?? .distantPast)
        job.salaryMin = row["salary_min"]
        job.salaryMax = row["salary_max"]
        job.salaryCurrency = row["salary_currency"]
        job.postedAt = DBJSON.date(row["posted_at"])
        job.modeOverride = (row["mode_override"] as String?).flatMap(Mode.init(rawValue:))
        job.notes = row["notes"]
        job.state = (row["state"] as String?).flatMap(AppState.init(rawValue:)) ?? .discovered
        job.stateReason = row["state_reason"]
        job.stateUpdatedAt = DBJSON.date(row["state_updated_at"])
        job.mode = (row["app_mode"] as String?).flatMap(ApplicationMode.init(rawValue:))
        job.resumeVariantID = row["resume_variant_id"]
        job.resumePickScore = row["resume_pick_score"]
        job.coverLetterPath = row["cover_letter_path"]
        job.screenshotPath = row["screenshot_path"]
        job.confirmationScreenshotPath = row["confirmation_screenshot_path"]
        job.submittedAt = DBJSON.date(row["submitted_at"])
        job.status = (row["status"] as String?).flatMap(BoardStatus.init(rawValue:))
        job.statusUpdatedAt = DBJSON.date(row["status_updated_at"])
        job.nudgesSent = row["nudges_sent"] ?? 0
        job.tokensIn = row["tokens_in"] ?? 0
        job.tokensOut = row["tokens_out"] ?? 0
        job.score = row["score"]
        job.skipReason = row["skip_reason"]
        job.scoredAt = DBJSON.date(row["scored_at"])
        let reasons = DBJSON.decode(JSONValue.self, from: row["reasons"], default: .object([:]))
        if case .string(let summary)? = reasons["summary"] { job.scoreSummary = summary }
        if case .object(let factors)? = reasons["factors"] {
            for (k, v) in factors {
                switch v {
                case .int(let i): job.scoreFactors[k] = i
                case .double(let d): job.scoreFactors[k] = Int(d.rounded())
                default: break
                }
            }
        }
        return job
    }

    static func answerItem(_ row: Row) -> ApplicationAnswerItem {
        var bbox: CGRect?
        if case .object(let o) = DBJSON.decode(JSONValue.self, from: row["bbox"], default: .null) {
            func num(_ k: String) -> Double? {
                switch o[k] {
                case .int(let i)?: Double(i)
                case .double(let d)?: d
                default: nil
                }
            }
            if let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") {
                bbox = CGRect(x: x, y: y, width: w, height: h)
            }
        }
        return ApplicationAnswerItem(
            id: row["id"], applicationID: row["application_id"], fieldKey: row["field_key"],
            question: row["question"] ?? "", answer: row["answer"] ?? "",
            fieldType: FieldType(rawValue: row["field_type"] ?? "text") ?? .text,
            confidence: row["confidence"],
            origin: AnswerOrigin(rawValue: row["origin"] ?? "generated") ?? .generated,
            originRef: row["origin_ref"], bbox: bbox)
    }

    static func activityEvent(_ row: Row) -> ActivityEvent {
        ActivityEvent(
            id: row["id"], ts: DBJSON.date(row["ts"]) ?? .distantPast, kind: row["kind"] ?? "log",
            actor: Actor(rawValue: row["actor"] ?? "agent") ?? .agent,
            level: LogLevel(rawValue: row["level"] ?? "info") ?? .info,
            runID: row["run_id"], jobID: row["job_id"], applicationID: row["application_id"],
            message: row["message"] ?? "",
            payload: DBJSON.decode(JSONValue.self, from: row["payload"], default: .object([:])))
    }
}
