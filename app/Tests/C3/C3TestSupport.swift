// C3TestSupport.swift — helpers for the C3 feature tests (Inbox, Review, Easy Apply, Profile,
// Resumes, Settings, Command palette). Self-contained: does not depend on AutoApplyTests.
import Foundation
import Synchronization
@testable import AutoApply

/// Poll `condition` on the main actor until true or timeout.
@MainActor
func c3WaitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A DaemonConnecting double: records every command and replies via `responder`
/// (return nil to simulate a timeout).
final class C3StubDaemon: DaemonConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let hub = EventBroadcaster<EventEnvelope>()
    private var _sent: [Command] = []
    private var _responder: @Sendable (Command) -> DaemonEvent? = { _ in .ack(AckPayload()) }
    var snapshot: SnapshotPayload

    init(snapshot: SnapshotPayload = C3Fixtures.snapshot()) {
        self.snapshot = snapshot
    }

    var responder: @Sendable (Command) -> DaemonEvent? {
        get { lock.withLock { _responder } }
        set { lock.withLock { _responder = newValue } }
    }

    var sent: [Command] { lock.withLock { _sent } }

    /// Commands of one wire type (e.g. "answer_question").
    func sent(_ type: String) -> [Command] { sent.filter { $0.type == type } }

    var connectionState: DaemonConnectionState { get async { .connected } }
    var events: AsyncStream<EventEnvelope> { hub.stream() }

    func push(_ event: DaemonEvent) { hub.yield(EventEnvelope(replyTo: nil, event: event)) }

    func connect() async throws -> SnapshotPayload { snapshot }
    func disconnect() async {}

    func send(_ command: Command) async throws -> String {
        lock.withLock { _sent.append(command) }
        return ProtocolCoding.newID()
    }

    func request(_ command: Command, timeout: Duration) async throws -> EventEnvelope {
        lock.withLock { _sent.append(command) }
        guard let reply = responder(command) else {
            try? await Task.sleep(for: timeout)
            throw DaemonClientError.timeout(commandID: "stub")
        }
        if case .error(let p) = reply { throw DaemonClientError.daemon(p) }
        return EventEnvelope(replyTo: "stub", event: reply)
    }
}

enum C3Fixtures {
    static let now = ProtocolCoding.date("2026-10-10T09:00:00Z")

    static func snapshot(clusters: [QuestionCluster] = [], preferences: Preferences = Preferences()) -> SnapshotPayload {
        SnapshotPayload(daemonVersion: "0.1.0-test", state: StatePayload(daemon: .idle, paused: false), mode: preferences.mode,
                        openClusters: clusters, onboarding: OnboardingState(completed: true, step: 7), preferences: preferences)
    }

    static func cluster(_ id: String, jobs: [Int], question: String = "Why do you want to work here?", fieldType: FieldType = .text,
                        options: [String] = [], neverGuessKey: String? = nil, companies: [String] = ["Stripe"],
                        createdAt: Date = now) -> QuestionCluster {
        QuestionCluster(clusterId: id, canonicalQuestion: question, fieldType: fieldType, options: options, neverGuessKey: neverGuessKey,
                        reason: neverGuessKey == nil ? .unknown : .neverGuess, jobIds: jobs, jobCount: jobs.count, companies: companies,
                        createdAt: createdAt)
    }

    static func job(id: Int, company: String = "Stripe", title: String = "Backend Engineer", state: AppState = .queued,
                    score: Int? = 80, ats: Ats = .greenhouse, companyID: Int? = nil) -> JobItem {
        // One id per company name (stable across runs), unless a test pins it.
        let companyID = companyID ?? company.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        var j = JobItem(id: id, applicationID: id, companyID: companyID, company: company, title: title, location: "Remote",
                        source: .greenhouse, ats: ats, applyURL: "https://jobs.example.com/\(id)", discoveredAt: now.addingTimeInterval(Double(id)))
        j.state = state
        j.score = score
        return j
    }

    static func answer(id: Int, app: Int, question: String, answer: String = "x", confidence: Double? = nil,
                       origin: AnswerOrigin = .profile) -> ApplicationAnswerItem {
        ApplicationAnswerItem(id: id, applicationID: app, question: question, answer: answer, confidence: confidence, origin: origin)
    }
}

/// Build a started store over a stub daemon and an in-memory dataset; waits for the first
/// repository emission so `store.jobs` / `store.library` are populated.
@MainActor
func makeC3Store(data: RepositoryData = RepositoryData(), clusters: [QuestionCluster] = [],
                 preferences: Preferences = Preferences()) async -> (AppStore, C3StubDaemon, InMemoryRepository) {
    let daemon = C3StubDaemon(snapshot: C3Fixtures.snapshot(clusters: clusters, preferences: preferences))
    let repo = InMemoryRepository(data)
    let store = AppStore(client: daemon, repository: repo)
    store.commandTimeout = .milliseconds(300)
    store.approvalTimeout = .milliseconds(300)
    store.start()
    _ = await c3WaitUntil { store.hasSnapshot && store.jobs.isLoaded }
    _ = await c3WaitUntil { store.library.stories.count == data.stories.count && store.library.easyApply.count == data.easyApply.count
        && store.library.resumeVariants.count == data.resumeVariants.filter { $0.replacedBy == nil }.count }
    return (store, daemon, repo)
}

extension Command {
    var answerPayload: AnswerQuestionPayload? { if case .answerQuestion(let p) = self { p } else { nil } }
    var preferencesValues: [String: JSONValue]? { if case .updatePreferences(let p) = self { p.preferences.values } else { nil } }
    var neverGuessValues: [String: JSONValue]? { if case .updateNeverGuess(let p) = self { p.values.values } else { nil } }
    var profileValues: [String: JSONValue]? { if case .updateProfile(let p) = self { p.profile.values } else { nil } }
}
