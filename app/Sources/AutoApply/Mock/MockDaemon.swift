// MockDaemon.swift — a DaemonConnecting implementation that replays MockScenario scripts and
// answers every command like autoapplyd would (ack/error replies with `reply_to`, then
// side-effect events). Select with AUTOAPPLY_MOCK=<scenario> (env or `-AUTOAPPLY_MOCK x`).
import Foundation
import Synchronization

final class MockDaemon: DaemonConnecting, DaemonConnectionObserving {
    let scenario: MockScenario
    let speed: Double
    let repository: InMemoryRepository
    let world: MockWorld

    private struct Inner {
        var state: DaemonConnectionState = .disconnected
        var scriptTask: Task<Void, Never>?
        var downTask: Task<Void, Never>?
        var followUps: [Task<Void, Never>] = []
        var scriptStarted = false
    }

    private let inner = Mutex(Inner())
    private let hub = EventBroadcaster<EventEnvelope>()
    private let stateHub = EventBroadcaster<DaemonConnectionState>()

    init(scenario: MockScenario, speed: Double = 1, now: Date = Date()) {
        self.scenario = scenario
        self.speed = speed
        let setup = scenario.makeSetup(now: now)
        self.repository = InMemoryRepository(setup.data)
        self.world = MockWorld(repository: repository, state: setup.state, speed: speed, emitter: hub)
    }

    deinit {
        inner.withLock { st in
            st.scriptTask?.cancel()
            st.downTask?.cancel()
            st.followUps.forEach { $0.cancel() }
        }
    }

    /// Resolve the scenario requested by `AUTOAPPLY_MOCK` (env var or `-AUTOAPPLY_MOCK name`
    /// launch argument). Returns nil when mock mode is off.
    static func requestedScenario(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  defaults: UserDefaults = .standard) -> MockScenario? {
        let raw = defaults.string(forKey: "AUTOAPPLY_MOCK") ?? environment["AUTOAPPLY_MOCK"]
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "0", raw.lowercased() != "false" else { return nil }
        if raw == "1" || raw.lowercased() == "true" { return .happyRun }
        return MockScenario(name: raw) ?? .happyRun
    }

    static func requestedSpeed(environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard) -> Double {
        let raw = defaults.string(forKey: "AUTOAPPLY_MOCK_SPEED") ?? environment["AUTOAPPLY_MOCK_SPEED"]
        return raw.flatMap(Double.init).map { max(0.1, $0) } ?? 1
    }

    // MARK: DaemonConnecting

    var connectionState: DaemonConnectionState { get async { inner.withLock { $0.state } } }

    var events: AsyncStream<EventEnvelope> { hub.stream() }

    var connectionStates: AsyncStream<DaemonConnectionState> {
        let stream = stateHub.stream()
        let current = inner.withLock { $0.state }
        return AsyncStream { continuation in
            continuation.yield(current)
            let task = Task {
                for await s in stream { continuation.yield(s) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func connect() async throws -> SnapshotPayload {
        setState(.connecting)
        if scenario.daemonIsDown {
            startDownLoop()
            throw DaemonClientError.notConnected
        }
        setState(.connected)
        let snapshot = world.snapshot()
        hub.yield(EventEnvelope(replyTo: ProtocolCoding.newID(), event: .snapshot(snapshot)))
        startScriptIfNeeded()
        return snapshot
    }

    func disconnect() async {
        inner.withLock { st in
            st.scriptTask?.cancel()
            st.scriptTask = nil
            st.downTask?.cancel()
            st.downTask = nil
            st.followUps.forEach { $0.cancel() }
            st.followUps.removeAll()
        }
        setState(.disconnected)
    }

    @discardableResult
    func send(_ command: Command) async throws -> String {
        let envelope = CommandEnvelope(command: command)
        Task { _ = try? await self.dispatch(envelope) }
        return envelope.id
    }

    func request(_ command: Command, timeout: Duration) async throws -> EventEnvelope {
        let envelope = CommandEnvelope(command: command)
        let reply = try await dispatch(envelope)
        if case .error(let payload) = reply.event { throw DaemonClientError.daemon(payload) }
        return reply
    }

    // MARK: Internals

    private func dispatch(_ envelope: CommandEnvelope) async throws -> EventEnvelope {
        guard inner.withLock({ $0.state.isConnected }) else { throw DaemonClientError.notConnected }
        let handled = await MockCommandHandler.handle(envelope.command, world: world)
        let reply = EventEnvelope(replyTo: envelope.id, event: handled.reply)
        hub.yield(reply)
        if let followUp = handled.followUp {
            let world = self.world
            let task = Task { await followUp(world) }
            inner.withLock { $0.followUps.append(task) }
        }
        return reply
    }

    private func startScriptIfNeeded() {
        let script = scenario.script
        let world = self.world
        inner.withLock { st in
            guard !st.scriptStarted else { return }
            st.scriptStarted = true
            st.scriptTask = Task {
                var virtualTime = 0.0
                for step in script {
                    if step.at > virtualTime {
                        await world.sleepRespectingPause(step.at - virtualTime)
                        virtualTime = step.at
                    }
                    if Task.isCancelled { return }
                    await step.action(world)
                }
            }
        }
    }

    /// daemonDown: connecting → reconnecting(n) forever with the real backoff schedule.
    private func startDownLoop() {
        let task = Task { [weak self] in
            let backoff: [Double] = [0.5, 1, 2, 5]
            var attempt = 1
            while !Task.isCancelled {
                self?.setState(.reconnecting(attempt: attempt))
                try? await Task.sleep(for: .seconds(backoff[min(attempt - 1, backoff.count - 1)] / max(1, (self?.speed ?? 1))))
                attempt += 1
            }
        }
        inner.withLock { st in
            st.downTask?.cancel()
            st.downTask = task
        }
    }

    private func setState(_ state: DaemonConnectionState) {
        let changed = inner.withLock { st -> Bool in
            guard st.state != state else { return false }
            st.state = state
            return true
        }
        if changed { stateHub.yield(state) }
    }
}
