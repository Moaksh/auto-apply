// Updater.swift — check for updates and self-update from GitHub Releases (free: the public
// releases API, no server, no Sparkle keys). The newest non-draft release whose tag beats
// CFBundleShortVersionString wins; its .dmg is downloaded, the app inside is copied to a staging
// folder, and a tiny detached script swaps it in once this process exits (then relaunches).
// The engine follows on next launch: DaemonControl sees the new bundle stamp and reinstalls it.
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    nonisolated static let repo = "Moaksh/auto-apply"
    static let autoCheckKey = "updates.autoCheck"
    static let autoInstallKey = "updates.autoInstall"
    static let lastCheckKey = "updates.lastCheck"

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        case ready(String)          // staged; installs on quit or "Restart to Update"
        case failed(String)
    }

    struct Release: Decodable {
        struct Asset: Decodable { var name: String; var browserDownloadUrl: URL }
        var tagName: String
        var name: String?
        var body: String?
        var draft: Bool
        var htmlUrl: URL
        var assets: [Asset]
    }

    private(set) var phase: Phase = .idle
    private(set) var latest: Release?
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var store: AppStore?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var autoCheck: Bool { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
    static var autoInstall: Bool { UserDefaults.standard.object(forKey: autoInstallKey) as? Bool ?? true }

    /// Only a real, installed .app can replace itself (not tests / `swift run`).
    var canSelfUpdate: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var readyVersion: String? { if case .ready(let v) = phase { v } else { nil } }

    /// Launch: check now if it's been a day, then every 6 hours.
    func start(store: AppStore) {
        self.store = store
        guard canSelfUpdate, timer == nil else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if Self.autoCheck, Date().timeIntervalSince1970 - last > 6 * 3600 {
            Task { await check(userInitiated: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in
                if Updater.autoCheck { await Updater.shared.check(userInitiated: false) }
            }
        }
    }

    // MARK: Check

    func check(userInitiated: Bool) async {
        switch phase {
        case .checking, .downloading: return
        case .ready:
            if userInitiated { promptRestart() }
            return
        default: break
        }
        phase = .checking
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            latest = release
            guard let release, Self.isNewer(release.tagName, than: Self.currentVersion) else {
                phase = .upToDate
                if userInitiated { alert("You're up to date", "AutoApply \(Self.currentVersion) is the newest version.") }
                return
            }
            let version = Self.clean(release.tagName)
            if userInitiated {
                phase = .idle
                let notes = (release.body ?? "").prefix(600)
                let a = NSAlert()
                a.messageText = "AutoApply \(version) is available"
                a.informativeText = "You have \(Self.currentVersion).\n\n\(notes)"
                a.addButton(withTitle: canSelfUpdate ? "Download & Install" : "Open Release Page")
                a.addButton(withTitle: "Later")
                NSApp.activate()
                guard a.runModal() == .alertFirstButtonReturn else { return }
                if canSelfUpdate { await download(release) } else { NSWorkspace.shared.open(release.htmlUrl) }
            } else if Self.autoInstall {
                await download(release)
            } else {
                phase = .idle
                AppNotifier.shared.postUpdate(title: "AutoApply \(version) is available",
                                              body: "Choose AutoApply ▸ Check for Updates to install it.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=15")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AutoApply/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw UpdateError(code == 404 ? "The releases page isn't reachable (is the repository public?)."
                                          : code == 403 ? "GitHub is rate-limiting update checks; try again in an hour."
                                          : "GitHub answered \(code).")
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let releases = try dec.decode([Release].self, from: data)
        return releases
            .filter { !$0.draft && $0.assets.contains { $0.name.hasSuffix(".dmg") } }
            .max { Self.compare($0.tagName, $1.tagName) < 0 }
    }

    // MARK: Download + stage

    private func download(_ release: Release) async {
        let version = Self.clean(release.tagName)
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            phase = .failed("The release has no .dmg")
            return
        }
        phase = .downloading(version)
        do {
            let dir = Self.updatesDir
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: asset.browserDownloadUrl)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed.") }
            let dmg = dir.appendingPathComponent(asset.name)
            try FileManager.default.moveItem(at: tmp, to: dmg)
            let staged = try await Task.detached { try Self.extractApp(from: dmg, into: dir) }.value
            guard Self.bundleVersion(of: staged).map({ Self.compare($0, Self.currentVersion) > 0 }) ?? false else {
                throw UpdateError("The downloaded app isn't newer than this one.")
            }
            stagedApp = staged
            phase = .ready(version)
            if store?.live.isRunning == false && !NSApp.isActive {
                installAndRelaunch()   // nobody is looking and the agent is idle: update now
            } else {
                AppNotifier.shared.postUpdate(title: "AutoApply \(version) is ready",
                                              body: "It installs when you quit, or click to restart now.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated private static func extractApp(from dmg: URL, into dir: URL) throws -> URL {
        let mount = dir.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let name = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("No app inside the disk image.")
        }
        let staged = dir.appendingPathComponent(name)
        try run("/usr/bin/ditto", [mount.appendingPathComponent(name).path, staged.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    // MARK: Install

    /// "Restart to Update": swap the app and relaunch.
    func installAndRelaunch() { install(relaunch: true) }

    /// Called from applicationWillTerminate: a staged update installs silently on quit.
    func installOnQuitIfReady() { install(relaunch: false) }

    private func install(relaunch: Bool) {
        guard canSelfUpdate, let staged = stagedApp, FileManager.default.fileExists(atPath: staged.path) else { return }
        let dest = Bundle.main.bundleURL
        let script = """
        #!/bin/bash
        # AutoApply updater: wait for the app to quit, swap the bundle, relaunch.
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        DEST="\(dest.path)"; NEW="\(staged.path)"
        rm -rf "$DEST.previous"
        if mv "$DEST" "$DEST.previous" && /usr/bin/ditto "$NEW" "$DEST"; then
          rm -rf "$DEST.previous" "\(Self.updatesDir.path)"
        else
          rm -rf "$DEST"; mv "$DEST.previous" "$DEST"
        fi
        \(relaunch ? "/usr/bin/open \"$DEST\"" : "")
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autoapply-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()          // outlives us: it waits for this pid to exit
            stagedApp = nil
            if relaunch { NSApp.terminate(nil) }
        } catch {
            phase = .failed("Couldn't start the installer: \(error.localizedDescription)")
        }
    }

    private func promptRestart() {
        guard let v = readyVersion else { return }
        let a = NSAlert()
        a.messageText = "AutoApply \(v) is ready to install"
        a.informativeText = "AutoApply will restart. The agent picks up where it left off."
        a.addButton(withTitle: "Restart to Update")
        a.addButton(withTitle: "Install on Quit")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { installAndRelaunch() }
    }

    func restartPrompt() { promptRestart() }

    // MARK: Helpers

    static var updatesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoApply/updates", isDirectory: true)
    }

    static func clean(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    /// Numeric dotted compare ("v0.1.10" > "0.1.9"); a pre-release suffix sorts before its release.
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> ([Int], Bool) {
            let c = clean(s)
            let core = c.split(separator: "-", maxSplits: 1).first.map(String.init) ?? c
            return (core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }, c.contains("-"))
        }
        let (x, xPre) = parts(a), (y, yPre) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        if xPre != yPre { return xPre ? -1 : 1 }
        return 0
    }

    static func isNewer(_ tag: String, than current: String) -> Bool { compare(tag, current) > 0 }

    nonisolated private static func bundleVersion(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.prefix(200))") }
        return text
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}

struct UpdateError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
