// NDJSONLineSplitter.swift — incremental newline framing for the daemon socket.
import Foundation

/// Accumulates raw socket bytes and yields complete NDJSON lines (without the `\n`).
/// Empty lines and a trailing `\r` are dropped. Lines longer than `maxLineLength`
/// (8 MiB per contract/protocol.md §1) are a protocol violation.
struct NDJSONLineSplitter: Sendable {
    enum SplitError: Error, Equatable { case lineTooLong(Int) }

    static let defaultMaxLineLength = 8 * 1024 * 1024

    let maxLineLength: Int
    private var buffer = Data()

    init(maxLineLength: Int = NDJSONLineSplitter.defaultMaxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Bytes currently buffered (an incomplete trailing line).
    var pendingByteCount: Int { buffer.count }

    mutating func append<Bytes: Sequence>(_ bytes: Bytes) throws -> [Data] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            var line = buffer[start..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            if line.count > maxLineLength { throw SplitError.lineTooLong(line.count) }
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: nl)
        }
        if start != buffer.startIndex {
            buffer = Data(buffer[start...])
        }
        if buffer.count > maxLineLength { throw SplitError.lineTooLong(buffer.count) }
        return lines
    }

    mutating func reset() { buffer = Data() }
}
