// DaemonControl.swift — LaunchAgent helpers ("Restart daemon" in the error panel / banner).
import AppKit
import Foundation

enum DaemonControl {
    static let launchAgentLabel = "com.autoapply.daemon"
    /// One-shot setup that works on a fresh Mac: installs uv if missing (it fetches Python itself),
    /// puts the engine in place (the copy shipped inside the app, or this repo checkout in development),
    /// installs its dependencies + the Playwright browser, then installs and starts the LaunchAgent.
    static var installHint: String {
        let pathLine = "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\""
        var lines = ["set -e", pathLine,
                     "command -v uv >/dev/null 2>&1 || { echo 'Installing uv…'; curl -LsSf https://astral.sh/uv/install.sh | sh; }",
                     pathLine]
        if let bundled = bundledEngine, devCheckout == nil {
            let rt = runtimeDirectory.path
            lines += [
                "mkdir -p \(shellQuote(rt))",
                "rsync -a --delete --exclude .venv \(shellQuote(bundled.path + "/")) \(shellQuote(rt + "/engine/"))",
                "rsync -a --delete \(shellQuote(bundled.deletingLastPathComponent().appendingPathComponent("contract").path + "/")) \(shellQuote(rt + "/contract/"))",
                "cd \(shellQuote(rt + "/engine"))",
            ]
        } else {
            lines.append("cd \(shellQuote(engineDirectory().path))")
        }
        lines += [
            "echo 'Installing the agent (first time takes a few minutes)…'",
            "uv sync --frozen --quiet",
            "uv run playwright install chromium",
            "uv run python -m autoapply.launchd_install install",
            "echo \(shellQuote(bundleStamp)) > \(shellQuote(runtimeDirectory.appendingPathComponent(".bundle-version").path)) 2>/dev/null || true",
        ]
        return lines.joined(separator: "\n")
    }

    /// Engine shipped inside AutoApply.app (Contents/Resources/engine), when this is a distributable build.
    static var bundledEngine: URL? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("engine"),
              FileManager.default.fileExists(atPath: res.appendingPathComponent("pyproject.toml").path) else { return nil }
        return res
    }

    /// Where a shared build installs the engine: ~/Library/Application Support/AutoApply/runtime.
    static var runtimeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AutoApply/runtime")
    }

    static var bundleStamp: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }

    /// A shared build whose engine copy is older than the app (or not installed yet) needs a (re)install.
    static var runtimeOutdated: Bool {
        guard bundledEngine != nil, devCheckout == nil else { return false }
        let stamp = try? String(contentsOf: runtimeDirectory.appendingPathComponent(".bundle-version"), encoding: .utf8)
        return stamp?.trimmingCharacters(in: .whitespacesAndNewlines) != bundleStamp
    }

    /// A source checkout next to the app (development): app/build/AutoApply.app -> repo/engine.
    static var devCheckout: URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["AUTOAPPLY_ENGINE_DIR"] { return URL(fileURLWithPath: env) }
        var dir = Bundle.main.bundleURL
        for _ in 0..<4 {
            dir = dir.deletingLastPathComponent()
            let e = dir.appendingPathComponent("engine")
            if fm.fileExists(atPath: e.appendingPathComponent("pyproject.toml").path),
               fm.fileExists(atPath: dir.appendingPathComponent("contract/schema.sql").path) { return e }
        }
        return nil
    }

    /// The engine folder in use: the dev checkout, else the installed runtime copy.
    static func engineDirectory() -> URL {
        devCheckout ?? runtimeDirectory.appendingPathComponent("engine")
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
        if FileManager.default.fileExists(atPath: plist) && !runtimeOutdated {
            // Not -k: a healthy daemon is left alone.
            started = await ProcessRunner.run("/bin/launchctl", ["kickstart", target], timeout: .seconds(10)).status == 0
        }
        if !started {
            // First install on a fresh Mac downloads Python, packages and a browser: allow several minutes.
            let r = await ProcessRunner.run("/bin/zsh", ["-lc", installHint], timeout: .seconds(900))
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
