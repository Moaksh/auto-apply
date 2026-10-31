// DaemonClient.swift — the seam between the UI and autoapplyd (contract/protocol.md).
//
// READ-ONLY for feature workstreams (Foundation owns this protocol). Implementations
// (`LiveDaemonClient` over the Unix socket, `MockDaemon` replaying fixtures) belong to the
// C1 Swift-foundation workstream and live in their own files.

import Foundation

/// Connection status surfaced to the UI (sidebar pill, menu bar glyph, error panel).
enum DaemonConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    /// Connected and the `hello` -> `snapshot` handshake completed.
    case connected
    /// Lost the connection; reconnect scheduled with backoff (0.5, 1, 2, 5 s).
    case reconnecting(attempt: Int)
    case failed(message: String)
}

/// Errors a client reports to callers of `send` / `request`.
enum DaemonClientError: Error, Sendable, Hashable {
    case notConnected
    /// No reply (`ack` / `error` / `snapshot` with matching `reply_to`) within the timeout.
    case timeout(commandID: String)
    /// The daemon replied with an `error` event.
    case daemon(ErrorPayload)
    case encoding(String)
    case decoding(String)
}

/// A connection to autoapplyd. All methods are safe to call from any isolation domain.
///
/// Usage:
/// ```swift
/// try await client.connect()                       // hello -> snapshot handshake
/// Task { for await env in client.events { store.apply(env) } }
/// let reply = try await client.request(.approve(ApprovePayload(applicationIds: [11])))
/// ```
protocol DaemonConnecting: AnyObject, Sendable {
    /// Current connection state (also mirrored as events by implementations if useful).
    var connectionState: DaemonConnectionState { get async }

    /// Every event from the daemon, in arrival order, including replies.
    /// Each call returns a new stream; multiple consumers are allowed.
    var events: AsyncStream<EventEnvelope> { get }

    /// Connect to `<home>/autoapplyd.sock` and perform the `hello` handshake.
    /// Returns the initial snapshot.
    @discardableResult
    func connect() async throws -> SnapshotPayload

    /// Close the connection and stop reconnecting.
    func disconnect() async

    /// Fire-and-forget: send a command, return its envelope id (for correlating replies).
    @discardableResult
    func send(_ command: Command) async throws -> String

    /// Send a command and await its reply (the event whose `reply_to` == command id).
    /// Throws `DaemonClientError.daemon` when the reply is an `error` event, and
    /// `.timeout` after `timeout` (default 2 s).
    func request(_ command: Command, timeout: Duration) async throws -> EventEnvelope
}
