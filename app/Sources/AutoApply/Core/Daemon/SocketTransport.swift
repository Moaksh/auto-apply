// SocketTransport.swift — a non-blocking Unix-domain stream socket with NDJSON framing.
//
// Reads happen on a private serial queue (a DispatchSource), so line splitting and JSON
// decoding never touch the main thread. Writes are serialized by a lock and use poll(2)
// to wait out EAGAIN.
import Darwin
import Foundation
import Synchronization

enum SocketTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case socket(errno: Int32, op: String)
    case closed
    case writeTimeout

    var description: String {
        switch self {
        case .pathTooLong(let p): "socket path too long: \(p)"
        case .socket(let e, let op): "\(op) failed: \(String(cString: strerror(e)))"
        case .closed: "connection closed"
        case .writeTimeout: "write timed out"
        }
    }
}

final class SocketTransport: Sendable {
    /// Called on the transport's queue for each complete line.
    typealias LineHandler = @Sendable (Data) -> Void
    /// Called once, on the transport's queue, when the connection ends (nil = clean EOF / local close).
    typealias CloseHandler = @Sendable ((any Error)?) -> Void

    private struct ReadState {
        var splitter = NDJSONLineSplitter()
        var source: (any DispatchSourceRead)?
        var closed = false
    }

    let fd: Int32
    private let queue: DispatchQueue
    private let readState = Mutex(ReadState())
    private let writeLock = Mutex(())
    private let onLine: LineHandler
    private let onClose: CloseHandler

    /// Connect to the socket at `path`. Throws if nothing is listening.
    init(path: String, label: String = "autoapply.socket", onLine: @escaping LineHandler, onClose: @escaping CloseHandler) throws {
        self.fd = try Self.openAndConnect(path: path)
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.onLine = onLine
        self.onClose = onClose
    }

    /// Wrap an already-connected descriptor (used by tests' in-process servers).
    init(connectedFD: Int32, label: String = "autoapply.socket", onLine: @escaping LineHandler, onClose: @escaping CloseHandler) {
        self.fd = connectedFD
        Self.configure(fd: connectedFD)
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.onLine = onLine
        self.onClose = onClose
    }

    deinit {
        readState.withLock { st in
            if !st.closed {
                st.closed = true
                st.source?.cancel()
                if st.source == nil { Darwin.close(fd) }
            }
        }
    }

    /// Begin delivering lines. Call exactly once.
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        readState.withLock { $0.source = source }
        source.resume()
    }

    /// Write one complete line (caller supplies the trailing `\n`).
    func write(_ data: Data, timeout: Duration = .seconds(5)) throws {
        if readState.withLock({ $0.closed }) { throw SocketTransportError.closed }
        try writeLock.withLock { _ in
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard var ptr = raw.baseAddress else { return }
                var remaining = raw.count
                let deadline = ContinuousClock.now + timeout
                while remaining > 0 {
                    let n = Darwin.write(fd, ptr, remaining)
                    if n > 0 {
                        ptr = ptr.advanced(by: n)
                        remaining -= n
                        continue
                    }
                    let err = errno
                    if n < 0 && err == EINTR { continue }
                    if n < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
                        if ContinuousClock.now >= deadline { throw SocketTransportError.writeTimeout }
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pfd, 1, 200)
                        continue
                    }
                    throw SocketTransportError.socket(errno: err, op: "write")
                }
            }
        }
    }

    /// Close locally. The close handler fires with `nil`.
    func close() {
        queue.async { [self] in finish(error: nil) }
    }

    var isClosed: Bool { readState.withLock { $0.closed } }

    // MARK: - Private

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let lines: [Data]
                do {
                    lines = try readState.withLock { try $0.splitter.append(buffer[0..<n]) }
                } catch {
                    finish(error: error)
                    return
                }
                for line in lines { onLine(line) }
                if n < buffer.count { return }
                continue
            }
            if n == 0 {
                finish(error: nil)
                return
            }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK { return }
            finish(error: SocketTransportError.socket(errno: err, op: "read"))
            return
        }
    }

    private func finish(error: (any Error)?) {
        let shouldNotify = readState.withLock { st -> Bool in
            guard !st.closed else { return false }
            st.closed = true
            if let source = st.source {
                source.cancel()   // cancel handler closes the fd
            } else {
                Darwin.close(fd)
            }
            return true
        }
        if shouldNotify { onClose(error) }
    }

    private static func configure(fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func makeAddress(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketTransportError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func openAndConnect(path: String) throws -> Int32 {
        var addr = try makeAddress(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketTransportError.socket(errno: errno, op: "socket") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let err = errno
            Darwin.close(fd)
            throw SocketTransportError.socket(errno: err, op: "connect")
        }
        configure(fd: fd)
        return fd
    }
}
