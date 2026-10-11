// AppPaths.swift — the AutoApply data directory layout (mirrors engine/autoapply/paths.py).
import Foundation

/// Concrete paths for one AutoApply home. `AUTOAPPLY_HOME` relocates the whole tree.
struct AppPaths: Sendable, Hashable {
    static let environmentKey = "AUTOAPPLY_HOME"

    let home: URL

    init(home: URL) { self.home = home }

    /// Resolve the home directory, honouring `AUTOAPPLY_HOME`.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let override = environment[environmentKey], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return AppPaths(home: URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoApply", isDirectory: true)
        return AppPaths(home: base)
    }

    var database: URL { home.appendingPathComponent("autoapply.db") }
    var socket: URL { home.appendingPathComponent("autoapplyd.sock") }
    var resumes: URL { home.appendingPathComponent("resumes", isDirectory: true) }
    var screenshots: URL { home.appendingPathComponent("screenshots", isDirectory: true) }
    var coverLetters: URL { home.appendingPathComponent("cover_letters", isDirectory: true) }
    var chromeProfile: URL { home.appendingPathComponent("chrome-profile", isDirectory: true) }
    var logs: URL { home.appendingPathComponent("logs", isDirectory: true) }
}
