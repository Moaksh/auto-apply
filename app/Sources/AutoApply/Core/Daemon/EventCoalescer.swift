// EventCoalescer.swift — turns the daemon's event stream into at most one main-actor batch
// per display frame (docs/UI_UX_PLAN.md §8.4): one batch = one Observation transaction =
// one render pass, however many events/second the daemon emits.
import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// A decoded live-browser frame (from `agent_step.screenshot_thumb`).
struct DecodedFrame: @unchecked Sendable, Equatable {
    let applicationID: Int
    let jobID: Int
    let image: CGImage
    let receivedAt: Date

    static func == (a: DecodedFrame, b: DecodedFrame) -> Bool {
        a.applicationID == b.applicationID && a.receivedAt == b.receivedAt && a.image === b.image
    }
}

enum FrameDecoder {
    /// Decode a base64 JPEG thumbnail into a CGImage (≤ 720 px wide). Runs off-main.
    static func decode(base64: String, maxPixelSize: Int = 720) -> CGImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return decode(data: data, maxPixelSize: maxPixelSize)
    }

    static func decode(data: Data, maxPixelSize: Int = 720) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// One coalesced delivery to the main actor.
struct EventBatch: Sendable {
    var envelopes: [EventEnvelope]
    /// The newest decoded frame in this batch (intermediate frames are dropped).
    var frame: DecodedFrame?
}

/// Consumes an event stream off-main and delivers `EventBatch`es to a main-actor handler,
/// at most once per `interval` (default one 60 Hz frame).
final class EventCoalescer: Sendable {
    private struct Buffer {
        var envelopes: [EventEnvelope] = []
        var frame: DecodedFrame?
        var flushScheduled = false
    }

    let interval: Duration
    private let buffer = Mutex(Buffer())
    private let consumer = Mutex<Task<Void, Never>?>(nil)
    private let handler: @MainActor @Sendable (EventBatch) -> Void

    init(interval: Duration = .milliseconds(16), handler: @escaping @MainActor @Sendable (EventBatch) -> Void) {
        self.interval = interval
        self.handler = handler
    }

    deinit { consumer.withLock { $0?.cancel() } }

    /// Start consuming `stream`. Replaces any previous stream.
    func start(_ stream: AsyncStream<EventEnvelope>) {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            for await envelope in stream {
                guard let self else { return }
                self.ingest(envelope)
            }
        }
        let old = consumer.withLock { c -> Task<Void, Never>? in
            let o = c
            c = task
            return o
        }
        old?.cancel()
    }

    func stop() {
        let old = consumer.withLock { c -> Task<Void, Never>? in
            let o = c
            c = nil
            return o
        }
        old?.cancel()
    }

    /// Off-main: buffer one envelope (pre-decoding its thumbnail) and schedule a flush.
    func ingest(_ envelope: EventEnvelope) {
        var frame: DecodedFrame?
        if case .agentStep(let step) = envelope.event, let b64 = step.screenshotThumb, !b64.isEmpty,
           let image = FrameDecoder.decode(base64: b64) {
            frame = DecodedFrame(applicationID: step.applicationId, jobID: step.jobId, image: image, receivedAt: Date())
        }
        let needsSchedule = buffer.withLock { b -> Bool in
            b.envelopes.append(envelope)
            if let frame { b.frame = frame }
            if b.flushScheduled { return false }
            b.flushScheduled = true
            return true
        }
        if needsSchedule {
            let interval = self.interval
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: interval)
                self?.flush()
            }
        }
    }

    @MainActor
    private func flush() {
        let batch = buffer.withLock { b -> EventBatch in
            let batch = EventBatch(envelopes: b.envelopes, frame: b.frame)
            b.envelopes.removeAll(keepingCapacity: true)
            b.frame = nil
            b.flushScheduled = false
            return batch
        }
        guard !batch.envelopes.isEmpty else { return }
        handler(batch)
    }
}
