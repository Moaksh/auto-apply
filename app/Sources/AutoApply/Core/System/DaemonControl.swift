// DaemonControl.swift — LaunchAgent helpers ("Restart daemon" in the error panel / banner).
import AppKit
import Foundation

enum DaemonControl {
    static let launchAgentLabel = "com.autoapply.daemon"
    /// A working one-shot install: writes the plist and bootstraps it via the engine's own installer.
    static var installHint: String {
        "cd \(shellQuote(engineDirectory().path)) && uv run python -m autoapply.launchd_install install"
    }

    /// The `engine/` folder of this checkout: `$AUTOAPPLY_ENGINE_DIR`, else found by walking up from the
    /// app bundle / executable (app/build/AutoApply.app -> repo root), else `~/github/auto_apply/engine`.
    static func engineDirectory() -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["AUTOAPPLY_ENGINE_DIR"] { candidates.append(URL(fileURLWithPath: env)) }
        for start in [Bundle.main.bundleURL, Bundle.main.executableURL].compactMap({ $0 }) {
            var dir = start
            for _ in 0..<8 {
                dir = dir.deletingLastPathComponent()
                candidates.append(dir.appendingPathComponent("engine"))
            }
        }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("github/auto_apply/engine"))
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("pyproject.toml").path) } ?? candidates.last!
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `launchctl kickstart -k gui/<uid>/com.autoapply.daemon`. Returns true on success.
    @discardableResult
    static func restart() async -> Bool {
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        let result = await ProcessRunner.run("/bin/launchctl", ["kickstart", "-k", target], timeout: .seconds(10))
        return result.status == 0
    }

    /// Self-heal: make sure the LaunchAgent is installed, loaded and running, then wait for its socket.
    /// Installs it when missing (or when `kickstart` can't find it), otherwise just starts it.
    /// Returns true once the daemon's socket is accepting connections.
    @discardableResult
    static func ensureRunning(timeout: Duration = .seconds(20)) async -> Bool {
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist").path
        var started = false
        if FileManager.default.fileExists(atPath: plist) {
            // Not -k: a healthy daemon is left alone.
            started = await ProcessRunner.run("/bin/launchctl", ["kickstart", target], timeout: .seconds(10)).status == 0
        }
        if !started {
            let r = await ProcessRunner.run("/bin/zsh", ["-lc", installHint], timeout: .seconds(120))
            started = r.status == 0
        }
        guard started else { return false }
        return await waitForSocket(timeout: timeout)
    }

    static func waitForSocket(timeout: Duration) async -> Bool {
        let path = AppPaths.resolve().socket.path
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if socketAccepts(path) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static func socketAccepts(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
    }

    /// Reveal the daemon logs folder.
    @MainActor
    static func openLogs() {
        let logs = AppPaths.resolve().logs
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }

    /// Open Terminal with `command` typed in (for interactive commands like `claude login`).
    static func openInTerminal(_ command: String) async {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = await ProcessRunner.run("/usr/bin/osascript", [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"\(escaped)\"",
        ])
    }
}

extension AppStore {
    /// Execute a banner/issue fix.
    func fix(_ issue: AppIssue) async {
        switch issue.fix {
        case .restartDaemon?:
            let ok = await DaemonControl.ensureRunning()
            toasts.show(ok ? "autoapplyd is running again." : "Couldn't start autoapplyd. Check the logs (Settings ▸ Data).",
                        symbol: ok ? "arrow.clockwise" : "exclamationmark.triangle.fill", style: ok ? .info : .error,
                        duration: .seconds(3))
        case .reconnectSource(let source)?:
            let target: OnboardingConnectSourcePayload.Source = source == .linkedin ? .linkedin : .glassdoor
            _ = await onboardingConnectSource(target)
        case .openActivity?:
            router.showActivity(filter: ActivityFilter(scope: .errors))
            dismissIssue(issue.id)
        case .dismissError?:
            dismissIssue(issue.id)
        case nil:
            break
        }
    }
}
