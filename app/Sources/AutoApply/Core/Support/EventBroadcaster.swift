// EventBroadcaster.swift — fan-out of values to any number of AsyncStream consumers.
import Foundation
import Synchronization

/// Thread-safe multicast: every `stream()` call returns a new independent stream that
/// receives every value yielded after it was created, in order.
final class EventBroadcaster<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])
    private let finished = Mutex(false)

    init() {}

    func stream(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        if finished.withLock({ $0 }) {
            continuation.finish()
            return stream
        }
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ value: Element) {
        let targets = continuations.withLock { Array($0.values) }
        for c in targets { c.yield(value) }
    }

    var subscriberCount: Int { continuations.withLock { $0.count } }

    func finish() {
        finished.withLock { $0 = true }
        let targets = continuations.withLock { dict -> [AsyncStream<Element>.Continuation] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        for c in targets { c.finish() }
    }
}
