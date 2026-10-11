// UnixSocketDaemonClient.swift — the live DaemonConnecting implementation (NDJSON over
// `<home>/autoapplyd.sock`, contract/protocol.md).
//
// * Lines are split and decoded off the main thread (on the transport's queue).
// * Every decoded event is broadcast on `events` (replies included), in arrival order.
// * Replies are correlated to `request` calls by `reply_to`; an `error` reply throws.
// * Lost connections reconnect with backoff 0.5, 1, 2, 5, 5… s and redo the `hello`
//   handshake; the fresh `snapshot` is broadcast like any other event.
import Foundation
import Synchronization

final class UnixSocketDaemonClient: DaemonConnecting, DaemonConnectionObserving {
    struct Configuration: Sendable {
        var socketPath: String
        var clientVersion: String? = AppInfo.version
        var backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)]
        var handshakeTimeout: Duration = .seconds(5)

        init(socketPath: String) { self.socketPath = socketPath }
        init(paths: AppPaths = .resolve()) { self.socketPath = paths.socket.path }
    }

    private struct Inner {
        var state: DaemonConnectionState = .disconnected
        var transport: SocketTransport?
        var generation = 0
        var pending: [String: CheckedContinuation<EventEnvelope, any Error>] = [:]
        var wantsConnection = false
        var reconnectTask: Task<Void, Never>?
    }

    let configuration: Configuration
    private let inner = Mutex(Inner())
    private let eventHub = EventBroadcaster<EventEnvelope>()
    private let stateHub = EventBroadcaster<DaemonConnectionState>()

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    convenience init(paths: AppPaths = .resolve()) {
        self.init(configuration: Configuration(paths: paths))
    }

    deinit {
        let (task, transport) = inner.withLock { ($0.reconnectTask, $0.transport) }
        task?.cancel()
        transport?.close()
    }

    // MARK: DaemonConnecting

    var connectionState: DaemonConnectionState {
        get async { inner.withLock { $0.state } }
    }

    var events: AsyncStream<EventEnvelope> { eventHub.stream() }

    var connectionStates: AsyncStream<DaemonConnectionState> {
        let stream = stateHub.stream()
        // Seed with the current state so subscribers never miss it.
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
        let existing = inner.withLock { st -> Task<Void, Never>? in
            st.wantsConnection = true
            let t = st.reconnectTask
            st.reconnectTask = nil
            return t
        }
        existing?.cancel()
        setState(.connecting)
        do {
            return try await openAndHandshake()
        } catch {
            // Keep trying in the background; the store learns about success via events.
            scheduleReconnect(after: error)
            throw error
        }
    }

    func disconnect() async {
        let (task, transport) = inner.withLock { st -> (Task<Void, Never>?, SocketTransport?) in
            st.wantsConnection = false
            let t = (st.reconnectTask, st.transport)
            st.reconnectTask = nil
            st.transport = nil
            st.generation += 1
            return t
        }
        task?.cancel()
        transport?.close()
        failAllPending(with: DaemonClientError.notConnected)
        setState(.disconnected)
    }

    @discardableResult
    func send(_ command: Command) async throws -> String {
        let envelope = CommandEnvelope(command: command)
        try write(envelope)
        return envelope.id
    }

    func request(_ command: Command, timeout: Duration) async throws -> EventEnvelope {
        let envelope = CommandEnvelope(command: command)
        return try await awaitReply(to: envelope, timeout: timeout)
    }

    // MARK: Internals

    private func awaitReply(to envelope: CommandEnvelope, timeout: Duration) async throws -> EventEnvelope {
        let id = envelope.id
        let reply: EventEnvelope = try await withCheckedThrowingContinuation { continuation in
            inner.withLock { $0.pending[id] = continuation }
            do {
                try write(envelope)
            } catch {
                if let c = inner.withLock({ $0.pending.removeValue(forKey: id) }) {
                    c.resume(throwing: error)
                }
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                if let c = self.inner.withLock({ $0.pending.removeValue(forKey: id) }) {
                    c.resume(throwing: DaemonClientError.timeout(commandID: id))
                }
            }
        }
        if case .error(let payload) = reply.event {
            throw DaemonClientError.daemon(payload)
        }
        return reply
    }

    private func write(_ envelope: CommandEnvelope) throws {
        guard let transport = inner.withLock({ $0.transport }) else {
            throw DaemonClientError.notConnected
        }
        let data: Data
        do {
            data = try ProtocolCoding.encodeLine(envelope)
        } catch {
            throw DaemonClientError.encoding(String(describing: error))
        }
        do {
            try transport.write(data)
        } catch {
            throw DaemonClientError.notConnected
        }
    }

    private func openAndHandshake() async throws -> SnapshotPayload {
        let generation = inner.withLock { st -> Int in
            st.generation += 1
            return st.generation
        }
        let transport = try SocketTransport(
            path: configuration.socketPath,
            onLine: { [weak self] line in self?.handleLine(line) },
            onClose: { [weak self] error in self?.handleClose(generation: generation, error: error) }
        )
        let stillWanted = inner.withLock { st -> Bool in
            guard st.wantsConnection, st.generation == generation else { return false }
            st.transport = transport
            return true
        }
        guard stillWanted else {
            transport.close()
            throw DaemonClientError.notConnected
        }
        transport.start()

        let hello = CommandEnvelope(command: .hello(HelloPayload(
            client: .app, clientVersion: configuration.clientVersion, protocolVersion: ProtocolCoding.version)))
        let reply: EventEnvelope
        do {
            reply = try await awaitReply(to: hello, timeout: configuration.handshakeTimeout)
        } catch {
            transport.close()
            throw error
        }
        guard case .snapshot(let snapshot) = reply.event else {
            transport.close()
            throw DaemonClientError.decoding("expected snapshot reply to hello, got \(reply.event.type)")
        }
        setState(.connected)
        return snapshot
    }

    /// Runs on the transport queue (off-main): decode, resolve pending request, broadcast.
    private func handleLine(_ line: Data) {
        let envelope: EventEnvelope
        do {
            envelope = try ProtocolCoding.decodeEvent(line)
        } catch {
            let message = "undecodable daemon line (\(line.count) bytes): \(error)"
            eventHub.yield(EventEnvelope(event: .log(LogPayload(level: .warning, message: message, logger: "app.socket", at: Date()))))
            return
        }
        if let replyTo = envelope.replyTo,
           let continuation = inner.withLock({ $0.pending.removeValue(forKey: replyTo) }) {
            continuation.resume(returning: envelope)
        }
        eventHub.yield(envelope)
    }

    private func handleClose(generation: Int, error: (any Error)?) {
        let isCurrent = inner.withLock { st -> Bool in
            guard st.generation == generation else { return false }
            st.transport = nil
            return true
        }
        guard isCurrent else { return }
        failAllPending(with: DaemonClientError.notConnected)
        scheduleReconnect(after: error)
    }

    private func scheduleReconnect(after error: (any Error)?) {
        let backoff = configuration.backoff
        let task: Task<Void, Never>? = inner.withLock { st in
            guard st.wantsConnection, st.reconnectTask == nil else { return nil }
            let t = Task { [weak self] in
                var attempt = 1
                while !Task.isCancelled {
                    guard let self else { return }
                    self.setState(.reconnecting(attempt: attempt))
                    let delay = backoff.isEmpty ? .seconds(1) : backoff[min(attempt - 1, backoff.count - 1)]
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { return }
                    guard self.inner.withLock({ $0.wantsConnection }) else { return }
                    do {
                        _ = try await self.openAndHandshake()
                        self.inner.withLock { $0.reconnectTask = nil }
                        return
                    } catch {
                        attempt += 1
                    }
                }
            }
            st.reconnectTask = t
            return t
        }
        if task == nil, !inner.withLock({ $0.wantsConnection }) {
            setState(.disconnected)
        }
        _ = error
    }

    private func failAllPending(with error: any Error) {
        let pending = inner.withLock { st -> [CheckedContinuation<EventEnvelope, any Error>] in
            let values = Array(st.pending.values)
            st.pending.removeAll()
            return values
        }
        for c in pending { c.resume(throwing: error) }
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

/// Static app metadata.
enum AppInfo {
    static let version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
}
