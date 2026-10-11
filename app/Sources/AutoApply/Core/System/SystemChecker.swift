// SystemChecker.swift — local prerequisite checks for onboarding step 1: `which claude/uv/node`
// plus `--version` for each, run off-main via Process with a PATH that includes Homebrew and
// user-local bins (GUI apps don't inherit the shell PATH).
import Foundation

/// One check outcome, mapped onto the protocol's SystemCheckItem so local and daemon results merge.
protocol SystemChecking: Sendable {
    func checkLocalTools() async -> [SystemCheckItem]
}

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum ProcessRunner {
    /// PATH used for every check/fix command.
    static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.volta/bin", "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (extra + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Run `executable args` with a timeout; never throws (failures come back as status != 0).
    ///
    /// stdout and stderr are drained concurrently on their own threads, so a child that writes
    /// more than a pipe buffer (64 KiB) to either stream can't deadlock against the other read.
    /// `onOutput` (optional) receives each chunk as it arrives, from a background thread.
    static func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(10),
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPath
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ProcessResult(status: -1, stdout: "", stderr: String(describing: error)))
                    return
                }
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: killer)

                let stdoutBuffer = PipeBuffer(), stderrBuffer = PipeBuffer()
                let drains = DispatchGroup()
                for (pipe, buffer) in [(out, stdoutBuffer), (err, stderrBuffer)] {
                    let handle = pipe.fileHandleForReading
                    DispatchQueue.global(qos: .userInitiated).async(group: drains) {
                        while true {
                            let chunk = handle.availableData   // blocks until data or EOF
                            if chunk.isEmpty { break }
                            buffer.append(chunk)
                            onOutput?(String(decoding: chunk, as: UTF8.self))
                        }
                    }
                }
                drains.wait()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: stdoutBuffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: String(decoding: stderrBuffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    /// Thread-safe accumulator for one pipe's bytes.
    private final class PipeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
        var data: Data { lock.withLock { storage } }
    }

    /// `which <tool>` → absolute path, or nil.
    static func which(_ tool: String) async -> String? {
        let r = await run("/usr/bin/which", [tool], timeout: .seconds(5))
        return r.status == 0 && !r.stdout.isEmpty ? r.stdout.components(separatedBy: .newlines).first : nil
    }
}

struct LocalSystemChecker: SystemChecking {
    func checkLocalTools() async -> [SystemCheckItem] {
        async let claude = check(.claudeCli, tool: "claude", fix: "npm install -g @anthropic-ai/claude-code")
        async let uv = check(.uv, tool: "uv", fix: "brew install uv")
        async let node = check(.node, tool: "node", fix: "brew install node", minimumMajor: 20)
        return await [claude, uv, node]
    }

    func check(_ name: SystemCheckItem.Name, tool: String, fix: String, minimumMajor: Int? = nil) async -> SystemCheckItem {
        guard let path = await ProcessRunner.which(tool) else {
            return SystemCheckItem(name: name, ok: false, required: true, version: nil, detail: "not found", fixCommand: fix)
        }
        let result = await ProcessRunner.run(path, ["--version"])
        let version = Self.parseVersion(result.stdout.isEmpty ? result.stderr : result.stdout)
        guard result.status == 0 else {
            return SystemCheckItem(name: name, ok: false, required: true, version: version,
                                   detail: "found at \(path) but `\(tool) --version` failed", fixCommand: fix)
        }
        if let minimumMajor, let major = version.flatMap(Self.majorVersion), major < minimumMajor {
            return SystemCheckItem(name: name, ok: false, required: true, version: version,
                                   detail: "version \(version ?? "?") is older than \(minimumMajor)", fixCommand: "brew upgrade node")
        }
        return SystemCheckItem(name: name, ok: true, required: true, version: version, detail: "found at \(path)")
    }

    /// "2.4.1 (Claude Code)" → "2.4.1"; "uv 0.6.2 (abc 2025-01-01)" → "0.6.2"; "v22.11.0" → "v22.11.0".
    static func parseVersion(_ output: String) -> String? {
        let firstLine = output.components(separatedBy: .newlines).first ?? ""
        for token in firstLine.split(separator: " ") {
            let t = String(token)
            let digits = t.hasPrefix("v") ? String(t.dropFirst()) : t
            if digits.first?.isNumber == true && digits.contains(".") { return t }
        }
        return firstLine.isEmpty ? nil : firstLine
    }

    static func majorVersion(_ version: String) -> Int? {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return v.split(separator: ".").first.flatMap { Int($0) }
    }
}

/// Merge local tool checks with the daemon's (which also knows autoapplyd/Chrome and whether
/// the claude CLI is logged in). A daemon "not ok" for claude_cli (e.g. not logged in) wins.
enum SystemCheckMerger {
    static let order: [SystemCheckItem.Name] = [.claudeCli, .uv, .node, .autoapplyd, .chrome]

    static func merge(local: [SystemCheckItem], daemon: SystemCheckResult?, daemonReachable: Bool) -> [SystemCheckItem] {
        var byName: [SystemCheckItem.Name: SystemCheckItem] = [:]
        for item in daemon?.items ?? [] { byName[item.name] = item }
        for item in local {
            if let d = byName[item.name], item.name == .claudeCli, item.ok, !d.ok {
                byName[item.name] = d
            } else {
                byName[item.name] = item
            }
        }
        if byName[.autoapplyd] == nil {
            byName[.autoapplyd] = SystemCheckItem(
                name: .autoapplyd, ok: daemonReachable, required: true, version: nil,
                detail: daemonReachable ? "running" : "not running — install the LaunchAgent",
                fixCommand: daemonReachable ? nil : DaemonControl.installHint)
        }
        if byName[.chrome] == nil {
            let chrome = FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app")
            byName[.chrome] = SystemCheckItem(name: .chrome, ok: chrome, required: false, version: nil,
                                              detail: chrome ? "Google Chrome" : "waiting", fixCommand: chrome ? nil : "brew install --cask google-chrome")
        }
        return order.compactMap { byName[$0] }
    }

    static func allRequiredOK(_ items: [SystemCheckItem]) -> Bool {
        items.filter(\.required).allSatisfy(\.ok)
    }
}

extension SystemCheckItem.Name {
    var title: String {
        switch self {
        case .claudeCli: "Claude CLI"
        case .uv: "uv"
        case .node: "Node.js ≥ 20"
        case .autoapplyd: "autoapplyd"
        case .chrome: "Chrome"
        }
    }

    var whyItMatters: String {
        switch self {
        case .claudeCli: "AutoApply uses your existing Claude login to read job descriptions and draft answers. No API key needed."
        case .uv: "The background agent (autoapplyd) is a Python program managed by uv."
        case .node: "Browser automation runs through Playwright MCP, which needs Node.js 20 or newer."
        case .autoapplyd: "The agent runs in the background as a LaunchAgent so it works while the app is closed."
        case .chrome: "A dedicated Chrome profile is used for browsing job boards. You log in once; no passwords are stored."
        }
    }
}
