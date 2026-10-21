// IssueReporter.swift — "Report a Bug" / "Request a Feature" without any agent: builds a
// pre-filled GitHub "new issue" URL (title, body, label) and opens it in the browser. Bugs carry
// an environment block and a redacted excerpt of the daemon logs; the fuller redacted log bundle
// is written to <home>/reports/ and revealed in Finder for the user to drag into the issue.
// Nothing leaves the Mac until the user presses Submit on GitHub.
import AppKit
import Foundation

enum IssueReporter {
    enum Kind: String, CaseIterable, Identifiable {
        case bug, feature
        var id: String { rawValue }
        var label: String { self == .bug ? "bug" : "enhancement" }
        var title: String { self == .bug ? "Bug" : "Feature request" }
    }

    struct Environment {
        var appVersion: String
        var build: String
        var macOS: String
        var arch: String
        var daemonConnected: Bool
        var mode: String

        static func current(connected: Bool, mode: String) -> Environment {
            let info = Bundle.main.infoDictionary ?? [:]
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            return Environment(
                appVersion: info["CFBundleShortVersionString"] as? String ?? "dev",
                build: info["CFBundleVersion"] as? String ?? "dev",
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                arch: arch, daemonConnected: connected, mode: mode)
        }
    }

    /// GitHub accepts long URLs, but browsers and the issue form get unreliable past ~8k.
    static let maxURLLength = 7500
    static let excerptLines = 60
    static let bundleLines = 2000

    // MARK: Logs

    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoApply/logs", isDirectory: true)
    }

    static var reportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoApply/reports", isDirectory: true)
    }

    /// The daemon's own log plus launchd's stdout/stderr captures (see engine paths / launchd_install).
    static let logFiles = ["autoapplyd.log", "autoapplyd.stderr.log", "autoapplyd.stdout.log"]

    static func tail(_ url: URL, lines n: Int) -> [String] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        // Only the end matters; avoid decoding a huge file.
        let slice = data.count > 4_000_000 ? data.suffix(4_000_000) : data
        let text = String(decoding: slice, as: UTF8.self)
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(n).map(String.init))
    }

    /// Last lines of the main daemon log (falls back to stderr), redacted.
    static func recentLogExcerpt(lines n: Int = excerptLines, directory: URL = logsDirectory) -> String {
        for name in logFiles.prefix(2) {
            let lines = tail(directory.appendingPathComponent(name), lines: n)
            if !lines.isEmpty { return redact(lines.joined(separator: "\n")) }
        }
        return "(no agent log found)"
    }

    /// Writes the redacted bundle; returns its URL.
    static func writeLogBundle(env: Environment, directory: URL = logsDirectory, to out: URL = reportsDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let file = out.appendingPathComponent("AutoApply-logs-\(stamp).txt")
        var text = "AutoApply log bundle (redacted)\n\(environmentBlock(env))\n"
        for name in logFiles {
            let lines = tail(directory.appendingPathComponent(name), lines: bundleLines)
            text += "\n===== \(name) (last \(lines.count) lines) =====\n" + redact(lines.joined(separator: "\n")) + "\n"
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: Redaction

    private static let patterns: [(String, String)] = [
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"\bsk-[A-Za-z0-9_\-]{8,}"#, "<key>"),
        (#"(?i)\b(bearer|token|password|passwd|secret|api[_-]?key|authorization)\b(["']?\s*[:=]\s*["']?)[^\s"',}]+"#, "$1$2<redacted>"),
        (#"\b[a-z]{4} [a-z]{4} [a-z]{4} [a-z]{4}\b"#, "<app-password>"),
        (#"\b[A-Fa-f0-9]{25,}\b"#, "<hex>"),
        // Long mixed letter+digit runs (tokens, cookies); plain identifiers and paths stay readable.
        (#"\b(?=[A-Za-z0-9+_\-]*\d)(?=[A-Za-z0-9+_\-]*[A-Za-z])[A-Za-z0-9+_\-]{32,}={0,2}"#, "<token>"),
        // Phones: international (+91 98765 43210) or a bare 10-digit run; timestamps don't match.
        (#"\+\d{1,3}[\s\-]?\(?\d{2,5}\)?[\s\-]?\d{3,5}[\s\-]?\d{3,5}\b"#, "<phone>"),
        (#"(?<![\d\-:.])\b\d{10}\b(?![\-:.]\d)"#, "<phone>"),
    ]

    static func redact(_ text: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var s = text
        if !home.isEmpty, home != "/" { s = s.replacingOccurrences(of: home, with: "~") }
        for (pattern, template) in patterns {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    // MARK: Body + URL

    static func environmentBlock(_ env: Environment) -> String {
        """
        - App: \(env.appVersion) (build \(env.build))
        - macOS: \(env.macOS) · \(env.arch)
        - Agent: \(env.daemonConnected ? "connected" : "not connected") · mode \(env.mode)
        """
    }

    static func body(kind: Kind, description: String, env: Environment, logs: String?, bundleName: String?) -> String {
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .feature:
            return """
            ### What would you like?
            \(desc.isEmpty ? "_Describe the feature._" : desc)

            ### Why would it help?


            ---
            \(environmentBlock(env))
            """
        case .bug:
            var b = """
            ### What happened
            \(desc.isEmpty ? "_Describe the bug._" : desc)

            ### Steps to reproduce
            1.

            ### Expected


            ### Environment
            \(environmentBlock(env))
            """
            if let bundleName {
                b += "\n\n**Full logs attached:** drag `\(bundleName)` (just revealed in Finder) into this issue."
            }
            if let logs {
                b += "\n\n<details><summary>Recent logs (redacted)</summary>\n\n```\n\(logs)\n```\n</details>"
            }
            return b
        }
    }

    /// Strict query encoding: only unreserved characters pass through.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func issueURL(kind: Kind, title: String, body: String, repo: String = Updater.repo) -> URL {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTitle = t.isEmpty ? (kind == .bug ? "Bug: " : "Feature: ") : t
        let s = "https://github.com/\(repo)/issues/new?labels=\(encode(kind.label))&title=\(encode(fullTitle))&body=\(encode(body))"
        return URL(string: s)!
    }

    /// Builds the URL, trimming the log excerpt (oldest lines first) until it fits.
    static func makeURL(kind: Kind, title: String, description: String, env: Environment,
                        logs: String?, bundleName: String?, repo: String = Updater.repo) -> URL {
        var lines = logs.map { $0.components(separatedBy: "\n") }
        while true {
            let excerpt = lines.map { $0.joined(separator: "\n") }
            let url = issueURL(kind: kind, title: title,
                               body: body(kind: kind, description: description, env: env,
                                          logs: (excerpt?.isEmpty ?? true) ? nil : excerpt, bundleName: bundleName),
                               repo: repo)
            if url.absoluteString.count <= maxURLLength { return url }
            if var l = lines, !l.isEmpty {
                l.removeFirst(max(1, l.count / 5))
                lines = l
                continue
            }
            // Still too long (huge description): trim the description itself.
            var d = description
            while d.count > 200 {
                d = String(d.prefix(d.count * 3 / 4)) + "…"
                let u = issueURL(kind: kind, title: title, body: body(kind: kind, description: d, env: env, logs: nil, bundleName: bundleName), repo: repo)
                if u.absoluteString.count <= maxURLLength { return u }
            }
            return issueURL(kind: kind, title: title, body: body(kind: kind, description: d, env: env, logs: nil, bundleName: bundleName), repo: repo)
        }
    }

    // MARK: Submit

    /// Writes the log bundle (bugs with logs), reveals it, opens the pre-filled issue.
    @MainActor
    static func open(kind: Kind, title: String, description: String, includeLogs: Bool, env: Environment) {
        var bundle: URL?
        if kind == .bug, includeLogs {
            bundle = try? writeLogBundle(env: env)
            if let bundle { NSWorkspace.shared.activateFileViewerSelecting([bundle]) }
        }
        let url = makeURL(kind: kind, title: title, description: description, env: env,
                          logs: kind == .bug && includeLogs ? recentLogExcerpt() : nil,
                          bundleName: bundle?.lastPathComponent)
        NSWorkspace.shared.open(url)
    }
}
