// IssueReporterTests.swift — pre-filled GitHub issue URLs and log redaction.
import Foundation
import Testing
@testable import AutoApply

@Suite("IssueReporter")
struct IssueReporterTests {
    let env = IssueReporter.Environment(appVersion: "0.1.1", build: "42", macOS: "Version 26.0", arch: "arm64",
                                        daemonConnected: true, mode: "review")

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func bugURLHasLabelTitleBodyAndLogs() {
        let url = IssueReporter.makeURL(kind: .bug, title: "Glassdoor & LinkedIn: 100% stuck?", description: "It hung.",
                                        env: env, logs: "line 1\nline 2", bundleName: "AutoApply-logs-x.txt", repo: "o/r")
        #expect(url.absoluteString.hasPrefix("https://github.com/o/r/issues/new?"))
        let q = query(url)
        #expect(q["labels"] == "bug")
        #expect(q["title"] == "Glassdoor & LinkedIn: 100% stuck?")   // & and % survive the round trip
        let body = q["body"] ?? ""
        #expect(body.contains("It hung."))
        #expect(body.contains("0.1.1 (build 42)"))
        #expect(body.contains("line 2"))
        #expect(body.contains("AutoApply-logs-x.txt"))
    }

    @Test func featureURLUsesEnhancementLabelAndNoLogs() {
        let url = IssueReporter.makeURL(kind: .feature, title: "Dark mode", description: "Please", env: env,
                                        logs: nil, bundleName: nil, repo: "o/r")
        let q = query(url)
        #expect(q["labels"] == "enhancement")
        #expect(!(q["body"] ?? "").contains("Recent logs"))
    }

    @Test func longLogsAreTrimmedToFit() {
        let logs = (1...3000).map { "2026-10-16 13:00:\($0 % 60) INFO something happened number \($0)" }.joined(separator: "\n")
        let url = IssueReporter.makeURL(kind: .bug, title: "t", description: "d", env: env, logs: logs, bundleName: nil, repo: "o/r")
        #expect(url.absoluteString.count <= IssueReporter.maxURLLength)
        let body = query(url)["body"] ?? ""
        #expect(body.contains("number 3000"))          // newest lines kept
        #expect(!body.contains("number 1\n"))          // oldest dropped
        let huge = String(repeating: "word ", count: 5000)
        #expect(IssueReporter.makeURL(kind: .bug, title: "t", description: huge, env: env, logs: nil, bundleName: nil, repo: "o/r")
            .absoluteString.count <= IssueReporter.maxURLLength)
    }

    @Test func encodingIsStrict() {
        #expect(IssueReporter.encode("a b&c=d#e?f/g+h") == "a%20b%26c%3Dd%23e%3Ff%2Fg%2Bh")
    }

    @Test func redactsPersonalDataButKeepsLogsReadable() {
        let raw = """
        2026-10-16 13:00:15,702 INFO autoapply.discovery.linkedin: launch_persistent_context ok
        user moaksh@example.com logged in, phone +91 98765 43210 or 9876543210
        key sk-ant-api03-abcdefghijklmnop token=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZg
        app password abcd efgh ijkl mnop
        file /Users/tester/Library/Application Support/AutoApply/autoapply.db
        cookie 7f9a3b2c1d0e4f5a6b7c8d9e0f1a2b3c4d5e
        """
        let s = IssueReporter.redact(raw, home: "/Users/tester")
        #expect(s.contains("2026-10-16 13:00:15,702"))          // timestamps intact
        #expect(s.contains("launch_persistent_context"))       // identifiers intact
        #expect(s.contains("~/Library/Application Support/AutoApply/autoapply.db"))
        #expect(!s.contains("moaksh@example.com") && s.contains("<email>"))
        #expect(!s.contains("98765 43210") && !s.contains("9876543210"))
        #expect(!s.contains("sk-ant-api03"))
        #expect(!s.contains("Zm9vYmFy"))
        #expect(!s.contains("abcd efgh ijkl mnop"))
        #expect(!s.contains("7f9a3b2c1d0e4f5a"))
        #expect(!s.contains("/Users/tester"))
    }

    @Test func excerptAndBundleReadLogFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = (1...100).map { "line \($0) for a@b.co" }.joined(separator: "\n")
        try lines.write(to: dir.appendingPathComponent("autoapplyd.log"), atomically: true, encoding: .utf8)
        let excerpt = IssueReporter.recentLogExcerpt(lines: 5, directory: dir)
        #expect(excerpt.hasPrefix("line 96"))
        #expect(excerpt.contains("<email>") && !excerpt.contains("a@b.co"))
        let out = dir.appendingPathComponent("reports")
        let bundle = try IssueReporter.writeLogBundle(env: env, directory: dir, to: out)
        let text = try String(contentsOf: bundle, encoding: .utf8)
        #expect(bundle.lastPathComponent.hasPrefix("AutoApply-logs-"))
        #expect(text.contains("===== autoapplyd.log (last 100 lines) ====="))
        #expect(!text.contains("a@b.co"))
    }
}
