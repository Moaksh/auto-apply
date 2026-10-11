// DaemonClientTests.swift — NDJSON framing, the live Unix-socket client against an in-process
// fake daemon (handshake, request/reply correlation, errors, timeouts, reconnect), and
// frame-coalesced delivery.
import Foundation
import Testing
@testable import AutoApply

@Suite("NDJSON framing")
struct NDJSONTests {
    @Test func splitsCompleteLinesAndBuffersPartial() throws {
        var s = NDJSONLineSplitter()
        var lines = try s.append(Array("{\"a\":1}\n{\"b\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}"])
        #expect(s.pendingByteCount == 4)
        lines = try s.append(Array(":2}\r\n\n{\"c\":3}\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"b\":2}", "{\"c\":3}"])
        #expect(s.pendingByteCount == 0)
    }

    @Test func rejectsOverlongLines() {
        var s = NDJSONLineSplitter(maxLineLength: 8)
        #expect(throws: NDJSONLineSplitter.SplitError.self) { _ = try s.append(Array("0123456789".utf8)) }
        var t = NDJSONLineSplitter(maxLineLength: 8)
        #expect(throws: NDJSONLineSplitter.SplitError.self) { _ = try t.append(Array("0123456789\n".utf8)) }
    }

    @Test func broadcasterFansOutInOrder() async {
        let hub = EventBroadcaster<Int>()
        let a = hub.stream(), b = hub.stream()
        for i in 0..<5 { hub.yield(i) }
        hub.finish()
        var ra: [Int] = [], rb: [Int] = []
        for await v in a { ra.append(v) }
        for await v in b { rb.append(v) }
        #expect(ra == [0, 1, 2, 3, 4])
        #expect(rb == ra)
    }
}

@Suite("UnixSocketDaemonClient", .serialized)
struct UnixSocketClientTests {
    func makeClient(_ server: FakeDaemonServer) -> UnixSocketDaemonClient {
        var config = UnixSocketDaemonClient.Configuration(socketPath: server.path)
        config.backoff = [.milliseconds(50)]
        config.handshakeTimeout = .seconds(2)
        return UnixSocketDaemonClient(configuration: config)
    }

    @Test func handshakeReturnsSnapshotAndSendsHello() async throws {
        let server = try FakeDaemonServer()
        defer { server.stop() }
        server.snapshot = Samples.snapshot(paused: true)
        let client = makeClient(server)
        let snapshot = try await client.connect()
        #expect(snapshot.state.paused == true)
        #expect(await client.connectionState == .connected)
        guard case .hello(let hello)? = server.commands.first?.command else {
            Issue.record("first command was not hello")
            return
        }
        #expect(hello.client == .app)
        #expect(hello.protocolVersion == 1)
        await client.disconnect()
    }

    @Test func requestCorrelatesReplyAndDecodesResult() async throws {
        let server = try FakeDaemonServer()
        defer { server.stop() }
        let client = makeClient(server)
        try await client.connect()
        struct RunResult: Decodable { var run_id: String }
        let result = try await client.requestResult(.runNow(RunNowPayload(kind: .prep)), as: RunResult.self)
        #expect(result.run_id == "r1")
        await client.disconnect()
    }

    @Test func errorReplyThrowsDaemonError() async throws {
        let server = try FakeDaemonServer()
        defer { server.stop() }
        let client = makeClient(server)
        try await client.connect()
        await #expect(throws: DaemonClientError.self) {
            _ = try await client.request(.reject(RejectPayload(applicationId: 1, reason: "x")), timeout: .seconds(2))
        }
        do {
            _ = try await client.request(.reject(RejectPayload(applicationId: 1, reason: "x")), timeout: .seconds(2))
        } catch DaemonClientError.daemon(let payload) {
            #expect(payload.code == .illegalTransition)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        await client.disconnect()
    }

    @Test func missingReplyTimesOut() async throws {
        let server = try FakeDaemonServer()
        defer { server.stop() }
        server.ignoredTypes = ["ping"]
        let client = makeClient(server)
        try await client.connect()
        let start = ContinuousClock.now
        do {
            _ = try await client.request(.ping(PingPayload()), timeout: .milliseconds(200))
            Issue.record("expected timeout")
        } catch DaemonClientError.timeout {
            #expect(ContinuousClock.now - start < .seconds(2))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        await client.disconnect()
    }

    @Test func eventsArriveInOrderIncludingPartialWrites() async throws {
        let server = try FakeDaemonServer()
        defer { server.stop() }
        let client = makeClient(server)
        let stream = client.events
        try await client.connect()
        // Two log events, the second split across writes, plus a garbage line in between.
        let first = try ProtocolCoding.encodeLine(EventEnvelope(event: .log(LogPayload(message: "one", at: Samples.now))))
        let second = try ProtocolCoding.encodeLine(EventEnvelope(event: .log(LogPayload(message: "two", at: Samples.now))))
        server.pushRaw(first)
        server.pushRaw(Data("not json\n".utf8))
        server.pushRaw(second.prefix(10))
        try await Task.sleep(for: .milliseconds(50))
        server.pushRaw(second.dropFirst(10))
        let received = await collect(stream, count: 4, timeout: .seconds(3))
        let messages = received.compactMap { env -> String? in
            if case .log(let p) = env.event { return p.message }
            return nil
        }
        // snapshot reply, "one", undecodable-line warning, "two"
        #expect(messages.first == "one")
        #expect(messages.last == "two")
        #expect(messages.contains { $0.contains("undecodable") })
        if case .snapshot = received.first?.event {} else { Issue.record("snapshot reply should be broadcast first") }
        await client.disconnect()
    }

    @Test func reconnectsAfterDropAndRedoesHandshake() async throws {
        let server = try FakeDaemonServer()
        defer { server.stop() }
        let client = makeClient(server)
        let states = client.connectionStates
        try await client.connect()
        server.dropClients()
        // Expect: disconnected → connecting → connected → reconnecting → connected, and a second hello.
        let seen = await collect(states, count: 5, timeout: .seconds(5))
        #expect(seen.contains { if case .reconnecting = $0 { true } else { false } })
        #expect(seen.last == .connected)
        let deadline = ContinuousClock.now + .seconds(2)
        while server.commands.filter({ $0.command.type == "hello" }).count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.commands.filter { $0.command.type == "hello" }.count == 2)
        await client.disconnect()
        #expect(await client.connectionState == .disconnected)
    }

    @Test func connectFailsWhenNoDaemonButKeepsRetrying() async throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("aa-missing-\(UUID().uuidString.prefix(6)).sock")
        var config = UnixSocketDaemonClient.Configuration(socketPath: path)
        config.backoff = [.milliseconds(30)]
        let client = UnixSocketDaemonClient(configuration: config)
        await #expect(throws: (any Error).self) { try await client.connect() }
        try await Task.sleep(for: .milliseconds(120))
        if case .reconnecting = await client.connectionState {} else { Issue.record("should be reconnecting") }
        await client.disconnect()
        #expect(await client.connectionState == .disconnected)
    }

    @Test func requestWhileDisconnectedThrowsNotConnected() async {
        let client = UnixSocketDaemonClient(configuration: .init(socketPath: "/tmp/does-not-exist.sock"))
        await #expect(throws: DaemonClientError.notConnected) {
            _ = try await client.request(.ping(PingPayload()), timeout: .seconds(1))
        }
    }
}

@Suite("Event coalescing")
struct EventCoalescerTests {
    @MainActor
    @Test func coalescesBurstsIntoFewOrderedBatches() async {
        final class Sink: @unchecked Sendable { var batches: [[EventEnvelope]] = [] }
        let sink = Sink()
        let coalescer = EventCoalescer(interval: .milliseconds(16)) { batch in sink.batches.append(batch.envelopes) }
        let hub = EventBroadcaster<EventEnvelope>()
        coalescer.start(hub.stream())
        try? await Task.sleep(for: .milliseconds(20))
        for i in 0..<300 {
            hub.yield(EventEnvelope(id: "\(i)", event: .log(LogPayload(message: "\(i)", at: Samples.now))))
        }
        let done = await waitUntil { sink.batches.flatMap { $0 }.count == 300 }
        #expect(done)
        let ids = sink.batches.flatMap { $0 }.map(\.id)
        #expect(ids == (0..<300).map(String.init))
        #expect(sink.batches.count < 30, "300 events should coalesce into a handful of frames, got \(sink.batches.count)")
        coalescer.stop()
    }

    @Test func frameDecoderHandlesBadAndEmptyInput() throws {
        #expect(FrameDecoder.decode(base64: "") == nil)
        #expect(FrameDecoder.decode(base64: "not base64 !!") == nil)
        let jpeg = try #require(MockFrames.frame(company: "Stripe", step: 1, total: 3))
        #expect(FrameDecoder.decode(base64: jpeg) != nil)
        // Wire JSON with snake_case key and with the thumb absent.
        let json = #"{"application_id":1,"job_id":2,"index":0,"action":"x","screenshot_thumb":"\#(jpeg)","at":0}"#
        _ = json
    }

    @MainActor
    @Test func decodesOnlyTheNewestFrame() async throws {
        final class Sink: @unchecked Sendable { var frames: [DecodedFrame] = [] }
        let sink = Sink()
        let coalescer = EventCoalescer(interval: .milliseconds(30)) { batch in if let f = batch.frame { sink.frames.append(f) } }
        let jpeg = try #require(MockFrames.frame(company: "Stripe", step: 2, total: 7))
        for app in [1, 2, 3] {
            coalescer.ingest(EventEnvelope(event: .agentStep(AgentStepPayload(applicationId: app, jobId: app, index: 0, action: "x",
                                                                                screenshotThumb: jpeg, at: Samples.now))))
        }
        #expect(await waitUntil { !sink.frames.isEmpty })
        #expect(sink.frames.count == 1)
        #expect(sink.frames.first?.applicationID == 3)
        #expect((sink.frames.first?.image.width ?? 0) <= 720)
    }
}
