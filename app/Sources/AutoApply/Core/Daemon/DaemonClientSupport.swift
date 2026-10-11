// DaemonClientSupport.swift — helpers shared by every DaemonConnecting implementation.
import Foundation

/// Implementations that can stream connection-state changes (both UnixSocketDaemonClient and
/// MockDaemon do). The store uses this to drive the sidebar pill / error panel.
protocol DaemonConnectionObserving: AnyObject, Sendable {
    /// Every connection-state change after subscription; the first element is the current state.
    var connectionStates: AsyncStream<DaemonConnectionState> { get }
}

extension DaemonConnecting {
    /// `request` with the protocol's default 2 s timeout.
    func request(_ command: Command) async throws -> EventEnvelope {
        try await request(command, timeout: .seconds(2))
    }

    /// Send a command and decode `ack.result` into `T` (e.g. `SystemCheckResult`).
    func requestResult<T: Decodable>(_ command: Command, as type: T.Type, timeout: Duration = .seconds(2)) async throws -> T {
        let reply = try await request(command, timeout: timeout)
        switch reply.event {
        case .ack(let ack):
            do {
                return try JSONValue.object(ack.result ?? [:]).decode(T.self)
            } catch {
                throw DaemonClientError.decoding("ack.result for \(command.type): \(error)")
            }
        case .error(let payload):
            throw DaemonClientError.daemon(payload)
        default:
            throw DaemonClientError.decoding("unexpected reply \(reply.event.type) to \(command.type)")
        }
    }
}

extension DaemonConnectionState {
    var isConnected: Bool { if case .connected = self { true } else { false } }

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))…"
        case .failed(let message): "Unavailable: \(message)"
        }
    }
}

extension DaemonClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to autoapplyd"
        case .timeout: "Daemon didn't respond"
        case .daemon(let payload): payload.message
        case .encoding(let m): "Couldn't encode command: \(m)"
        case .decoding(let m): "Couldn't decode reply: \(m)"
        }
    }
}
