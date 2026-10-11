// TestSupport.swift — shared helpers: an in-process fake autoapplyd over a real Unix socket,
// polling waits, and sample payloads.
import Darwin
import Foundation
import Synchronization
@testable import AutoApply

/// Poll `condition` on the main actor until true or timeout.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Collect the first `count` elements of a stream (or whatever arrived before timeout).
func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int, timeout: Duration = .seconds(5)) async -> [T] {
    let task = Task {
        var out: [T] = []
        for await v in stream {
            out.append(v)
            if out.count >= count { break }
        }
        return out
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        task.cancel()
    }
    let result = await task.value
    timer.cancel()
    return result
}

enum Samples {
    static let now = ProtocolCoding.date("2026-10-10T09:00:00Z")

    static func snapshot(paused: Bool = false, activity: DaemonActivity = .idle, clusters: [QuestionCluster] = [],
                         onboardingCompleted: Bool = true) -> SnapshotPayload {
        SnapshotPayload(daemonVersion: "0.1.0-test", state: StatePayload(daemon: activity, paused: paused), mode: .auto,
                        openClusters: clusters, onboarding: OnboardingState(completed: onboardingCompleted, step: onboardingCompleted ? 7 : 2),
                        preferences: Preferences())
    }

    static func cluster(_ id: String, jobs: [Int], question: String = "Why us?") -> QuestionCluster {
        QuestionCluster(clusterId: id, canonicalQuestion: question, jobIds: jobs, jobCount: jobs.count, companies: ["Stripe"], createdAt: now)
    }

    static func job(id: Int, state: AppState = .queued, status: BoardStatus? = nil, submittedAt: Date? = nil) -> JobItem {
        var j = JobItem(id: id, applicationID: id, companyID: 1, company: "Stripe", title: "Backend Engineer",
                        source: .greenhouse, ats: .greenhouse, discoveredAt: now)
        j.state = state
        j.status = status
        j.submittedAt = submittedAt
        return j
    }
}

/// A scriptable fake daemon listening on a real Unix-domain socket.
final class FakeDaemonServer: @unchecked Sendable {
    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var clientFDs: [Int32] = []
    private var stopped = false
    private(set) var receivedCommands: [CommandEnvelope] = []
    /// Command types the server ignores (to exercise timeouts).
    var ignoredTypes: Set<String> = []
    var snapshot = Samples.snapshot()

    init() throws {
        let dir = NSTemporaryDirectory()
        path = (dir as NSString).appendingPathComponent("aa-\(UUID().uuidString.prefix(8)).sock")
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try SocketTransport.makeAddress(path: path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(listenFD, 8) == 0 else { throw SocketTransportError.socket(errno: errno, op: "bind/listen") }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let fds = clientFDs
        clientFDs.removeAll()
        lock.unlock()
        guard !wasStopped else { return }
        for fd in fds { shutdown(fd, SHUT_RDWR); close(fd) }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(path)
    }

    /// Drop every connected client (simulates a daemon restart; the listener stays up).
    func dropClients() {
        lock.lock()
        let fds = clientFDs
        clientFDs.removeAll()
        lock.unlock()
        for fd in fds { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    var connectedClientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clientFDs.count
    }

    var commands: [CommandEnvelope] {
        lock.lock(); defer { lock.unlock() }
        return receivedCommands
    }

    /// Broadcast an event to every client.
    func push(_ event: DaemonEvent, replyTo: String? = nil) {
        guard let data = try? ProtocolCoding.encodeLine(EventEnvelope(replyTo: replyTo, event: event)) else { return }
        lock.lock()
        let fds = clientFDs
        lock.unlock()
        for fd in fds { write(fd: fd, data) }
    }

    /// Write raw bytes (for framing tests: partial lines, garbage).
    func pushRaw(_ data: Data) {
        lock.lock()
        let fds = clientFDs
        lock.unlock()
        for fd in fds { write(fd: fd, data) }
    }

    private func write(fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            if stopped { lock.unlock(); close(fd); return }
            clientFDs.append(fd)
            lock.unlock()
            let thread = Thread { [weak self] in self?.readLoop(fd: fd) }
            thread.start()
        }
    }

    private func readLoop(fd: Int32) {
        var splitter = NDJSONLineSplitter()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            guard let lines = try? splitter.append(buf[0..<n]) else { return }
            for line in lines {
                guard let env = try? ProtocolCoding.decodeCommand(line) else { continue }
                lock.lock()
                receivedCommands.append(env)
                let ignored = ignoredTypes.contains(env.command.type)
                let snap = snapshot
                lock.unlock()
                if ignored { continue }
                let reply: DaemonEvent
                switch env.command {
                case .hello: reply = .snapshot(snap)
                case .reject: reply = .error(ErrorPayload(code: .illegalTransition, message: "not awaiting review"))
                case .runNow: reply = .ack(AckPayload(ok: true, result: ["run_id": .string("r1")]))
                default: reply = .ack(AckPayload())
                }
                if let data = try? ProtocolCoding.encodeLine(EventEnvelope(replyTo: env.id, event: reply)) {
                    write(fd: fd, data)
                }
            }
        }
    }
}

/// A DaemonConnecting double for store tests: records commands, replies per a closure.
final class StubDaemon: DaemonConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let hub = EventBroadcaster<EventEnvelope>()
    private var _sent: [Command] = []
    /// Return nil to simulate no reply (timeout).
    var responder: @Sendable (Command) -> DaemonEvent? = { _ in .ack(AckPayload()) }
    var snapshot = Samples.snapshot()

    var sent: [Command] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    var connectionState: DaemonConnectionState { get async { .connected } }
    var events: AsyncStream<EventEnvelope> { hub.stream() }

    func push(_ event: DaemonEvent, replyTo: String? = nil) { hub.yield(EventEnvelope(replyTo: replyTo, event: event)) }

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
