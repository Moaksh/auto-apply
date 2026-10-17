// InMemoryRepository.swift — fixture-backed AppRepository for MockDaemon, previews and tests.
// Mutations (`update`) notify every open stream, mirroring how the daemon's DB writes reach
// GRDBRepository.
import Foundation
import Synchronization

/// The full durable dataset (what autoapply.db would contain).
struct RepositoryData: Sendable {
    var jobs: [JobItem] = []
    var jobDescriptions: [Int: String] = [:]
    var applicationAnswers: [Int: [ApplicationAnswerItem]] = [:]
    var activity: [ActivityEvent] = []
    var resumeVariants: [ResumeVariantItem] = []
    var stories: [StoryItem] = []
    var memoryAnswers: [MemoryAnswerItem] = []
    var easyApply: [EasyApplyItem] = []
    var companySuggestions: [CompanySuggestionItem] = []
    var profile = Profile()
    var neverGuess = NeverGuess()
    var runs: [RunItem] = []

    // MARK: Mutation helpers (used by MockDaemon to mirror daemon writes)

    func jobIndex(applicationID: Int) -> Int? { jobs.firstIndex { $0.applicationID == applicationID } }
    func jobIndex(jobID: Int) -> Int? { jobs.firstIndex { $0.id == jobID } }

    var nextActivityID: Int { (activity.last?.id ?? 0) + 1 }

    mutating func log(_ kind: String, _ message: String, actor: Actor = .agent, level: LogLevel = .info,
                      jobID: Int? = nil, applicationID: Int? = nil, payload: JSONValue = .object([:]), at: Date = Date()) {
        activity.append(ActivityEvent(id: nextActivityID, ts: at, kind: kind, actor: actor, level: level,
                                      jobID: jobID, applicationID: applicationID, message: message, payload: payload))
    }
}

final class InMemoryRepository: AppRepository {
    private let data: Mutex<RepositoryData>
    private let changes = EventBroadcaster<Void>()

    init(_ data: RepositoryData = RepositoryData()) {
        self.data = Mutex(data)
    }

    var isAvailable: Bool { true }

    /// Current dataset copy.
    var snapshot: RepositoryData { data.withLock { $0 } }

    /// Read without copying the whole dataset.
    func read<T>(_ body: (RepositoryData) -> T) -> T {
        data.withLock { body($0) }
    }

    /// Mutate the dataset and notify observers.
    @discardableResult
    func update<T>(_ body: (inout RepositoryData) -> T) -> T {
        let result = data.withLock { body(&$0) }
        changes.yield(())
        return result
    }

    func replaceAll(_ newData: RepositoryData) {
        data.withLock { $0 = newData }
        changes.yield(())
    }

    private func observe<T: Sendable & Equatable>(_ map: @escaping @Sendable (RepositoryData) -> T) -> AsyncStream<T> {
        let ticks = changes.stream(bufferingPolicy: .bufferingNewest(1))
        let first = data.withLock { map($0) }
        return AsyncStream { continuation in
            continuation.yield(first)
            let task = Task { [weak self] in
                var last = first
                for await _ in ticks {
                    guard let self else { break }
                    let value = self.data.withLock { map($0) }
                    if value != last {
                        last = value
                        continuation.yield(value)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func jobs() -> AsyncStream<[JobItem]> {
        observe { $0.jobs.sorted { ($0.discoveredAt, $0.id) > ($1.discoveredAt, $1.id) } }
    }

    func jobDescription(jobID: Int) async -> String? { data.withLock { $0.jobDescriptions[jobID] } }

    func applicationAnswers(applicationID: Int) -> AsyncStream<[ApplicationAnswerItem]> {
        observe { $0.applicationAnswers[applicationID] ?? [] }
    }

    func activity(initialLimit: Int) -> AsyncStream<ActivityDelta> {
        let ticks = changes.stream(bufferingPolicy: .bufferingNewest(1))
        let initial = data.withLock { Array($0.activity.suffix(initialLimit)) }
        return AsyncStream { continuation in
            continuation.yield(ActivityDelta(appended: initial, isInitial: true))
            let task = Task { [weak self] in
                var lastID = initial.last?.id ?? 0
                for await _ in ticks {
                    guard let self else { break }
                    let new = self.data.withLock { d in d.activity.filter { $0.id > lastID } }
                    if let last = new.last {
                        lastID = last.id
                        continuation.yield(ActivityDelta(appended: new, isInitial: false))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func resumeVariants() -> AsyncStream<[ResumeVariantItem]> { observe { $0.resumeVariants.filter { $0.replacedBy == nil } } }
    func stories() -> AsyncStream<[StoryItem]> { observe { $0.stories.sorted { $0.updatedAt > $1.updatedAt } } }
    func memoryAnswers() -> AsyncStream<[MemoryAnswerItem]> { observe { $0.memoryAnswers.sorted { $0.uses > $1.uses } } }
    func easyApply() -> AsyncStream<[EasyApplyItem]> { observe { $0.easyApply } }
    func companySuggestions() -> AsyncStream<[CompanySuggestionItem]> {
        observe { $0.companySuggestions.filter { $0.status == .pending || $0.status == .auto } }
    }
    func profile() -> AsyncStream<Profile> { observe { $0.profile } }
    func neverGuess() -> AsyncStream<NeverGuess> { observe { $0.neverGuess } }
    func runs(limit: Int) -> AsyncStream<[RunItem]> {
        observe { Array($0.runs.sorted { $0.startedAt > $1.startedAt }.prefix(limit)) }
    }
}
