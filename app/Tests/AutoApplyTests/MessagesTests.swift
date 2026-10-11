// Verifies Messages.swift agrees with the Python side by decoding every example in
// contract/protocol.examples.ndjson and re-encoding it losslessly.
import Foundation
import Testing
@testable import AutoApply

private let examplesURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AutoApplyTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // app
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("contract/protocol.examples.ndjson")

private func exampleLines() throws -> [Data] {
    let text = try String(contentsOf: examplesURL, encoding: .utf8)
    return text.split(separator: "\n").map { Data($0.utf8) }
}

/// Drop JSON nulls recursively (the daemon emits optional fields as null; Swift omits nil).
private func stripNulls(_ v: JSONValue) -> JSONValue {
    switch v {
    case .object(let o):
        return .object(o.compactMapValues { $0 == .null ? nil : stripNulls($0) })
    case .array(let a):
        return .array(a.map(stripNulls))
    default:
        return v
    }
}

/// Numbers may round-trip as int vs double (e.g. 0.93); normalise ints to doubles.
private func normalizeNumbers(_ v: JSONValue) -> JSONValue {
    switch v {
    case .int(let i): return .double(Double(i))
    case .object(let o): return .object(o.mapValues(normalizeNumbers))
    case .array(let a): return .array(a.map(normalizeNumbers))
    default: return v
    }
}

private func canonical(_ data: Data) throws -> JSONValue {
    normalizeNumbers(stripNulls(try ProtocolCoding.makeDecoder().decode(JSONValue.self, from: data)))
}

@Suite("Protocol messages mirror contract")
struct MessagesTests {
    @Test func examplesFileCoversEveryType() throws {
        var seen = Set<String>()
        for line in try exampleLines() {
            let raw = try ProtocolCoding.makeDecoder().decode(JSONValue.self, from: line)
            if case .string(let t)? = raw["type"] { seen.insert(t) }
        }
        #expect(seen == Set(Command.allTypes).union(DaemonEvent.allTypes))
    }

    @Test func everyExampleRoundTrips() throws {
        let decoder = ProtocolCoding.makeDecoder()
        let encoder = ProtocolCoding.makeEncoder()
        for line in try exampleLines() {
            let raw = try decoder.decode(JSONValue.self, from: line)
            guard case .string(let type)? = raw["type"] else {
                Issue.record("missing type")
                continue
            }
            let reencoded: Data
            if Command.allTypes.contains(type) {
                let env = try decoder.decode(CommandEnvelope.self, from: line)
                #expect(env.command.type == type)
                reencoded = try encoder.encode(env)
            } else {
                let env = try decoder.decode(EventEnvelope.self, from: line)
                #expect(env.event.type == type)
                if case .unknown = env.event { Issue.record("event \(type) decoded as unknown") }
                reencoded = try encoder.encode(env)
            }
            #expect(try canonical(reencoded) == canonical(line), "round-trip mismatch for \(type)")
        }
    }

    @Test func unknownEventTypesAreTolerated() throws {
        let line = Data(#"{"v":1,"id":"x","type":"future_event","payload":{"a":1}}"#.utf8)
        let env = try ProtocolCoding.decodeEvent(line)
        #expect(env.event == .unknown(type: "future_event", payload: .object(["a": .int(1)])))
    }

    @Test func commandEncodingUsesWireNames() throws {
        let env = CommandEnvelope(id: "abc", command: .answerQuestion(
            AnswerQuestionPayload(clusterId: "k", answer: "Because {company}", saveToMemory: true)))
        let json = try canonical(try ProtocolCoding.encodeLine(env).dropLast())
        #expect(json["type"] == .string("answer_question"))
        #expect(json["payload"]?["cluster_id"] == .string("k"))
        #expect(json["payload"]?["save_to_memory"] == .bool(true))
    }

    @Test func patchEncodesExplicitNull() throws {
        var patch = NeverGuessPatch()
        try patch.set(.sponsorship, Optional<String>.none)
        try patch.set(.noticePeriod, "60 days")
        let env = CommandEnvelope(id: "p", command: .updateNeverGuess(UpdateNeverGuessPayload(values: patch)))
        let raw = try ProtocolCoding.makeDecoder().decode(JSONValue.self, from: try ProtocolCoding.makeEncoder().encode(env))
        #expect(raw["payload"]?["values"]?["sponsorship"] == .null)
        #expect(raw["payload"]?["values"]?["notice_period"] == .string("60 days"))
    }

    @Test func defaultsMatchPythonDefaults() {
        let p = Preferences()
        #expect(p.matchThreshold == 70)
        #expect(p.perCompanyCooldownDays == 30)
        #expect(p.mode == .auto)
        #expect(p.schedule == ["09:00", "13:00", "18:00"])
        #expect(p.ghostAfterDays == 21)
        #expect(p.perAtsMode == ["workday": .review])
    }

    @Test func timestampsParseWithAndWithoutFraction() {
        #expect(ProtocolCoding.parseDate("2026-10-10T09:00:00.000Z") != nil)
        #expect(ProtocolCoding.parseDate("2026-10-10T09:00:00Z") != nil)
        #expect(ProtocolCoding.parseDate("2026-10-10T14:30:00.123+05:30") != nil)
        #expect(ProtocolCoding.formatDate(ProtocolCoding.date("2026-10-10T09:00:00Z")) == "2026-10-10T09:00:00.000Z")
    }
}
