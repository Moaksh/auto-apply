// SettingsModel.swift — Settings scene state: which tab is shown,
// editable drafts of preferences and never-guess facts that auto-save (debounced) as partial
// patches containing only what changed, validation with inline errors, LaunchAgent control,
// and the tracker CSV export.
import AppKit
import Foundation
import Observation
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, preferences, guardrails, modes, sources, schedule, outreach, agent, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .preferences: "Preferences"
        case .guardrails: "Guardrails"
        case .modes: "Modes"
        case .sources: "Sources"
        case .schedule: "Schedule & Limits"
        case .outreach: "Outreach"
        case .agent: "Agent"
        case .data: "Data"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .preferences: "slider.horizontal.3"
        case .guardrails: "lock.shield"
        case .modes: "bolt.horizontal.circle"
        case .sources: "antenna.radiowaves.left.and.right"
        case .schedule: "calendar.badge.clock"
        case .outreach: "envelope"
        case .agent: "cpu"
        case .data: "externaldrive"
        }
    }
}

/// Lets other screens (⌘K "salary floor", Profile ▸ never-guess "Edit") open a specific tab.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab: SettingsTab = .general
    /// A setting key the palette jumped to (the tab can highlight it).
    var highlightedKey: String?

    func open(_ tab: SettingsTab, key: String? = nil, router: Router) {
        self.tab = tab
        highlightedKey = key
        router.requestSettings()
    }
}

/// Validation of preference drafts before anything is sent.
enum PreferencesValidator {
    struct Issue: Equatable, Sendable {
        var key: Preferences.CodingKeys
        var message: String
    }

    static func validate(_ p: Preferences) -> [Issue] {
        var issues: [Issue] = []
        if p.remotePolicy.isEmpty { issues.append(Issue(key: .remotePolicy, message: "Pick at least one of Remote, Hybrid or Onsite.")) }
        if let floor = p.salaryFloor, floor < 0 { issues.append(Issue(key: .salaryFloor, message: "Salary floor can't be negative.")) }
        if !(1...200).contains(p.dailyCap) { issues.append(Issue(key: .dailyCap, message: "Daily cap must be between 1 and 200.")) }
        if !(1...4).contains(p.parallelApplications) { issues.append(Issue(key: .parallelApplications, message: "Agents at once must be 1–4.")) }
        if !(0...100).contains(p.matchThreshold) { issues.append(Issue(key: .matchThreshold, message: "Match threshold is 0–100.")) }
        if !(0...365).contains(p.perCompanyCooldownDays) { issues.append(Issue(key: .perCompanyCooldownDays, message: "Cooldown must be 0–365 days.")) }
        if !(1...180).contains(p.ghostAfterDays) { issues.append(Issue(key: .ghostAfterDays, message: "Auto-ghost must be 1–180 days.")) }
        if p.nudgeDays.contains(where: { $0 < 1 }) || p.nudgeDays != p.nudgeDays.sorted() || Set(p.nudgeDays).count != p.nudgeDays.count {
            issues.append(Issue(key: .nudgeDays, message: "Nudge days must be positive, unique and ascending."))
        } else if let last = p.nudgeDays.last, last >= p.ghostAfterDays {
            issues.append(Issue(key: .nudgeDays, message: "Nudges must come before the auto-ghost day (\(p.ghostAfterDays))."))
        }
        if p.schedule.contains(where: { ScheduleTimes.parse($0) == nil }) {
            issues.append(Issue(key: .schedule, message: "Run times must look like 09:00."))
        }
        if !(0...10).contains(p.linkedinSessionsPerDay) { issues.append(Issue(key: .linkedinSessionsPerDay, message: "LinkedIn sessions: 0–10 per day.")) }
        if !(0...10).contains(p.glassdoorSessionsPerDay) { issues.append(Issue(key: .glassdoorSessionsPerDay, message: "Glassdoor sessions: 0–10 per day.")) }
        if !(0...40).contains(p.outreachDailyCap) { issues.append(Issue(key: .outreachDailyCap, message: "New emails a day: 0–40.")) }
        if !(0...2).contains(p.outreachMaxFollowups) { issues.append(Issue(key: .outreachMaxFollowups, message: "Follow-ups: 0–2 per conversation.")) }
        if !(1...30).contains(p.outreachFollowupDays) { issues.append(Issue(key: .outreachFollowupDays, message: "Follow-up after 1–30 business days.")) }
        if !(0...100).contains(p.outreachMinEmailConfidence) {
            issues.append(Issue(key: .outreachMinEmailConfidence, message: "Email confidence is 0–100."))
        }
        if !(0...30).contains(p.peopleFinderVisitsPerDay) { issues.append(Issue(key: .peopleFinderVisitsPerDay, message: "People finder: 0–30 pages a day.")) }
        let window = p.outreachSendWindow.compactMap(ScheduleTimes.parse)
        if window.count != 2 || window[0].hour * 60 + window[0].minute >= window[1].hour * 60 + window[1].minute {
            issues.append(Issue(key: .outreachSendWindow, message: "The send window must start before it ends."))
        }
        if let bad = p.careerPageUrls.first(where: { !CareerURL.isValid($0) }) {
            issues.append(Issue(key: .careerPageUrls, message: "“\(bad)” isn't a valid http(s) URL."))
        }
        return issues
    }
}

enum CareerURL {
    static func isValid(_ s: String) -> Bool {
        guard let url = URL(string: s.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, host.contains(".") else { return false }
        return true
    }

    /// Accept "acme.com/careers" by adding https://.
    static func normalize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.contains("://") ? t : "https://\(t)"
    }
}

/// Schedule run times ("09:00") ↔ hour-of-day cells.
enum ScheduleTimes {
    static func parse(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, parts[0].count <= 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    static func format(hour: Int, minute: Int = 0) -> String { String(format: "%02d:%02d", hour, minute) }

    /// Toggle a run at `hour`:00, keeping the list sorted and unique.
    static func toggle(hour: Int, in schedule: [String]) -> [String] {
        let hasHour = schedule.contains { parse($0)?.hour == hour }
        let next = hasHour ? schedule.filter { parse($0)?.hour != hour } : schedule + [format(hour: hour)]
        return sorted(next)
    }

    static func sorted(_ schedule: [String]) -> [String] {
        var seen = Set<String>()
        return schedule
            .compactMap { s -> (String, Int)? in parse(s).map { (format(hour: $0.hour, minute: $0.minute), $0.hour * 60 + $0.minute) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
            .filter { seen.insert($0).inserted }
    }

    static func hours(_ schedule: [String]) -> Set<Int> { Set(schedule.compactMap { parse($0)?.hour }) }
}

@MainActor
@Observable
final class SettingsModel {
    enum SaveState: Equatable, Sendable {
        case idle, saving, saved, failed(String)
    }

    let store: AppStore

    /// Editable copies. Bind controls to these; changes auto-save after `debounce`.
    var preferencesDraft: Preferences { didSet { if preferencesDraft != oldValue { preferencesChanged() } } }
    var neverGuessDraft: NeverGuess { didSet { if neverGuessDraft != oldValue { neverGuessChanged() } } }

    /// What the daemon last confirmed (diff base).
    private(set) var preferencesBaseline: Preferences
    private(set) var neverGuessBaseline: NeverGuess
    private(set) var preferencesSave: SaveState = .idle
    private(set) var neverGuessSave: SaveState = .idle
    private(set) var issues: [PreferencesValidator.Issue] = []
    /// Bumped to shake the field with the first issue.
    private(set) var shakeTrigger = 0

    @ObservationIgnored var debounce: Duration = .milliseconds(600)
    @ObservationIgnored private var prefsTask: Task<Void, Never>?
    @ObservationIgnored private var ngTask: Task<Void, Never>?
    @ObservationIgnored private var applyingRemote = false

    static func shared(for store: AppStore) -> SettingsModel {
        FeatureModels.model(SettingsModel.self, for: store) { SettingsModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
        preferencesDraft = store.preferences
        preferencesBaseline = store.preferences
        neverGuessDraft = store.library.neverGuess
        neverGuessBaseline = store.library.neverGuess
    }

    // MARK: Sync from the daemon / DB

    var hasUnsavedPreferences: Bool { preferencesDraft != preferencesBaseline }
    var hasUnsavedNeverGuess: Bool { neverGuessDraft != neverGuessBaseline }

    /// Adopt remote values (snapshot / DB) unless the user has unsaved edits.
    func syncFromStore() {
        let remotePrefs = store.preferences
        if remotePrefs != preferencesBaseline && !hasUnsavedPreferences {
            applyingRemote = true
            preferencesBaseline = remotePrefs
            preferencesDraft = remotePrefs
            applyingRemote = false
        }
        let remoteNG = store.library.neverGuess
        if remoteNG != neverGuessBaseline && !hasUnsavedNeverGuess {
            applyingRemote = true
            neverGuessBaseline = remoteNG
            neverGuessDraft = remoteNG
            applyingRemote = false
        }
    }

    func issue(for key: Preferences.CodingKeys) -> String? { issues.first { $0.key == key }?.message }

    // MARK: Preferences

    private func preferencesChanged() {
        guard !applyingRemote else { return }
        issues = PreferencesValidator.validate(preferencesDraft)
        prefsTask?.cancel()
        guard issues.isEmpty else {
            shakeTrigger += 1
            return
        }
        let delay = debounce
        prefsTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.savePreferences()
        }
    }

    /// The partial patch that would be sent now (only changed keys).
    var pendingPreferencesPatch: PreferencesPatch {
        JSONDiff.preferencesPatch(from: preferencesBaseline, to: preferencesDraft)
    }

    /// Send changed preference keys now. Returns true when the daemon acked (or nothing changed).
    @discardableResult
    func savePreferences() async -> Bool {
        prefsTask?.cancel()
        issues = PreferencesValidator.validate(preferencesDraft)
        guard issues.isEmpty else {
            shakeTrigger += 1
            // Say so in the save line too: the issue may sit on another tab.
            if let first = issues.first { preferencesSave = .failed("Not saved · \(first.message)") }
            return false
        }
        let patch = pendingPreferencesPatch
        guard !patch.isEmpty else { return true }
        let sent = preferencesDraft
        preferencesSave = .saving
        let ok = await store.updatePreferences(patch)
        if ok {
            preferencesBaseline = store.preferences
            // Adopt the daemon's normalized copy unless the user kept typing meanwhile.
            if preferencesDraft == sent {
                applyingRemote = true
                preferencesDraft = store.preferences
                applyingRemote = false
            }
            preferencesSave = .saved
        } else {
            preferencesSave = .failed(OnboardingModel.failureMessage(for: store.lastCommandError))
        }
        return ok
    }

    /// Global mode: sent immediately on its own (`mode` key only), independent of the rest of the
    /// draft, so an invalid field elsewhere can never leave the picker showing an unsent mode.
    @discardableResult
    func setGlobalMode(_ mode: Mode) async -> Bool {
        await saveField(\.mode, mode)
    }

    /// Per-ATS override (nil = inherit), sent immediately as its own `per_ats_mode` patch.
    @discardableResult
    func setAtsMode(_ ats: Ats, _ mode: Mode?) async -> Bool {
        var map = preferencesDraft.perAtsMode
        if let mode { map[ats.rawValue] = mode } else { map.removeValue(forKey: ats.rawValue) }
        return await saveField(\.perAtsMode, map)
    }

    /// Per-company override keyed by company id (nil = inherit), sent as its own patch.
    @discardableResult
    func setCompanyMode(companyID: Int, _ mode: Mode?) async -> Bool {
        let key = String(companyID)
        var map = preferencesDraft.perCompanyMode
        if let mode { map[key] = mode } else { map.removeValue(forKey: key) }
        return await saveField(\.perCompanyMode, map)
    }

    /// Set one preference and send just that key now, bypassing whole-draft validation (other
    /// unsaved edits stay pending in the draft). Rolled back in the draft on failure.
    private func saveField<T: Equatable>(_ keyPath: WritableKeyPath<Preferences, T>, _ value: T) async -> Bool {
        let old = preferencesBaseline[keyPath: keyPath]
        applyingRemote = true
        preferencesDraft[keyPath: keyPath] = value
        applyingRemote = false
        var target = preferencesBaseline
        target[keyPath: keyPath] = value
        let patch = JSONDiff.preferencesPatch(from: preferencesBaseline, to: target)
        guard !patch.isEmpty else { return true }
        preferencesSave = .saving
        let ok = await store.updatePreferences(patch, optimistic: { $0[keyPath: keyPath] = value },
                                               rollback: { $0[keyPath: keyPath] = old })
        if ok {
            let confirmed = store.preferences[keyPath: keyPath]
            preferencesBaseline[keyPath: keyPath] = confirmed
            if preferencesDraft[keyPath: keyPath] == value {
                applyingRemote = true
                preferencesDraft[keyPath: keyPath] = confirmed
                applyingRemote = false
            }
            preferencesSave = .saved
        } else {
            if preferencesDraft[keyPath: keyPath] == value {
                applyingRemote = true
                preferencesDraft[keyPath: keyPath] = old
                applyingRemote = false
            }
            preferencesSave = .failed(OnboardingModel.failureMessage(for: store.lastCommandError))
        }
        return ok
    }

    /// Companies we know about (from jobs), for the per-company override picker.
    var knownCompanies: [(id: Int, name: String)] {
        var seen = Set<Int>()
        return store.jobs.all.compactMap { j in seen.insert(j.companyID).inserted ? (j.companyID, j.company) : nil }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    func companyName(_ id: String) -> String {
        guard let n = Int(id) else { return id }
        return store.jobs.all.first { $0.companyID == n }?.company ?? "Company #\(id)"
    }

    var jobsWithModeOverride: [JobItem] { store.jobs.all.filter { $0.modeOverride != nil } }

    func toggleSource(_ source: SourceName, _ on: Bool) { preferencesDraft.sourcesEnabled[source.rawValue] = on }

    /// A source missing from saved preferences (added in a later version, e.g. Google Jobs) uses the daemon's default.
    func isSourceEnabled(_ source: SourceName) -> Bool { preferencesDraft.sourcesEnabled[source.rawValue] ?? (source == .google) }

    func addCareerURL(_ raw: String) -> Bool {
        let url = CareerURL.normalize(raw)
        guard CareerURL.isValid(url) else { shakeTrigger += 1; return false }
        if !preferencesDraft.careerPageUrls.contains(url) { preferencesDraft.careerPageUrls.append(url) }
        return true
    }

    func toggleScheduleHour(_ hour: Int) {
        preferencesDraft.schedule = ScheduleTimes.toggle(hour: hour, in: preferencesDraft.schedule)
    }

    // MARK: Never-guess

    private func neverGuessChanged() {
        guard !applyingRemote else { return }
        ngTask?.cancel()
        let delay = debounce
        ngTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.saveNeverGuess()
        }
    }

    var pendingNeverGuessPatch: NeverGuessPatch {
        var draft = neverGuessDraft
        // Blank strings mean "always ask me" → explicit null.
        draft.sponsorship = draft.sponsorship.c3Trimmed
        draft.salaryExpectation = draft.salaryExpectation.c3Trimmed
        draft.noticePeriod = draft.noticePeriod.c3Trimmed
        draft.startDate = draft.startDate.c3Trimmed
        draft.relocation = draft.relocation.c3Trimmed
        draft.eeoGender = draft.eeoGender.c3Trimmed
        draft.eeoRace = draft.eeoRace.c3Trimmed
        draft.eeoVeteran = draft.eeoVeteran.c3Trimmed
        draft.eeoDisability = draft.eeoDisability.c3Trimmed
        if draft.salaryExpectation == nil { draft.salaryNegotiable = nil }
        draft.workAuth = draft.workAuth.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.isEmpty }
        return JSONDiff.neverGuessPatch(from: neverGuessBaseline, to: draft)
    }

    @discardableResult
    func saveNeverGuess() async -> Bool {
        ngTask?.cancel()
        let patch = pendingNeverGuessPatch
        guard !patch.isEmpty else { return true }
        let sent = neverGuessDraft
        neverGuessSave = .saving
        if let saved = await store.updateNeverGuess(patch) {
            neverGuessBaseline = saved
            if neverGuessDraft == sent {
                applyingRemote = true
                neverGuessDraft = saved
                applyingRemote = false
            }
            neverGuessSave = .saved
            return true
        }
        neverGuessSave = .failed(OnboardingModel.failureMessage(for: store.lastCommandError))
        return false
    }

    /// Flush both drafts immediately (closing Settings).
    func flush() async {
        if hasUnsavedPreferences { await savePreferences() }
        if hasUnsavedNeverGuess { await saveNeverGuess() }
    }
}

// MARK: - General (app-local settings)

enum GeneralSettings {
    static let menuBarCounterKey = "menuBarCounter"
    static let soundsKey = "soundsEnabled"
    static let notifyPrefix = "notify."

    /// Notification categories (§3.6) with their defaults.
    static let notificationCategories: [(key: String, title: String, defaultOn: Bool)] = [
        ("NEEDS_YOU", "Questions need you", true),
        ("REVIEW_READY", "Applications ready to review", true),
        ("RUN_SUMMARY", "Run summary", true),
        ("SUBMITTED", "Each submission", false),
        ("NUDGE", "Did you hear back? nudges", true),
        ("REPLIES", "Replies to your emails and from employers", false),
        ("ERROR", "Errors (agent down, login expired)", true),
    ]

    static func isNotificationOn(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: notifyPrefix + key) as? Bool ?? notificationCategories.first { $0.key == key }?.defaultOn ?? true
    }

    @MainActor
    static func applyShowInDock(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: AppDelegate.showInDockKey)
        NSApp.setActivationPolicy(on ? .regular : .accessory)
        if on { NSApp.activate() }
    }

    /// Launch at login via SMAppService (works for a bundled .app; reports why otherwise).
    @MainActor
    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @MainActor
    static func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't change login item: \(error.localizedDescription)"
        }
    }
}

// MARK: - LaunchAgent control (Settings ▸ Agent)

/// Parsed `launchctl print gui/<uid>/com.autoapply.daemon` (mirrors engine/autoapply/launchd_install.py).
struct LaunchAgentStatus: Equatable, Sendable {
    var installed: Bool
    var loaded: Bool
    var running: Bool
    var pid: Int?
    var lastExitCode: Int?
    var state: String?

    static func parse(printOutput: String, exitCode: Int32, plistExists: Bool) -> LaunchAgentStatus {
        guard exitCode == 0 else { return LaunchAgentStatus(installed: plistExists, loaded: false, running: false) }
        var state: String?, pid: Int?, lastExit: Int?
        for raw in printOutput.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: " = ") else { continue }
            let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "state" where state == nil: state = value
            case "pid" where pid == nil: pid = Int(value)
            case "last exit code" where lastExit == nil:
                let digits = value.prefix { $0 == "-" || $0.isNumber }
                lastExit = Int(digits)
            default: break
            }
        }
        return LaunchAgentStatus(installed: plistExists, loaded: true, running: state == "running" || pid != nil,
                                 pid: pid, lastExitCode: lastExit, state: state)
    }

    var summary: String {
        if running { return "Running\(pid.map { " · pid \($0)" } ?? "")" }
        if loaded { return "Loaded, not running\(lastExitCode.map { " · last exit \($0)" } ?? "")" }
        return installed ? "Installed, not loaded" : "Not installed"
    }
}

@MainActor
@Observable
final class DaemonAgentModel {
    static let engineDirKey = "agent.engineDir"

    private(set) var status: LaunchAgentStatus?
    private(set) var busy = false
    private(set) var lastOutput: String?
    var engineDir: String {
        didSet { UserDefaults.standard.set(engineDir, forKey: Self.engineDirKey) }
    }

    init() {
        engineDir = UserDefaults.standard.string(forKey: Self.engineDirKey) ?? Self.detectEngineDir() ?? ""
    }

    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(DaemonControl.launchAgentLabel).plist")
    }

    var serviceTarget: String { "gui/\(getuid())/\(DaemonControl.launchAgentLabel)" }

    /// Find `engine/pyproject.toml` near the executable (dev builds run from the repo), or via
    /// `AUTOAPPLY_ENGINE_DIR`.
    static func detectEngineDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let env = environment["AUTOAPPLY_ENGINE_DIR"], !env.isEmpty { return env }
        var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("engine/pyproject.toml")
            if FileManager.default.fileExists(atPath: candidate.path) { return dir.appendingPathComponent("engine").path }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    func refresh() async {
        let result = await ProcessRunner.run("/bin/launchctl", ["print", serviceTarget], timeout: .seconds(5))
        status = LaunchAgentStatus.parse(printOutput: result.stdout, exitCode: result.status,
                                         plistExists: FileManager.default.fileExists(atPath: plistURL.path))
    }

    /// `uv run python -m autoapply.launchd_install install|uninstall` in the engine project.
    func runInstaller(_ action: String) async -> Bool {
        guard !engineDir.isEmpty else {
            lastOutput = "Set the engine folder (the directory containing pyproject.toml) first."
            return false
        }
        busy = true
        defer { busy = false }
        // PYTHONPATH makes `autoapply` importable even if the venv's editable-install .pth file
        // is skipped (macOS can flag it hidden, and Python 3.12 ignores hidden .pth files).
        let result = await ProcessRunner.run("/usr/bin/env", ["PYTHONPATH=\(engineDir)", "uv", "run", "--project", engineDir,
                                                              "python", "-m", "autoapply.launchd_install", action],
                                             timeout: .seconds(120))
        lastOutput = [result.stdout, result.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        await refresh()
        return result.status == 0
    }

    func restart() async -> Bool {
        busy = true
        defer { busy = false }
        let ok = await DaemonControl.restart()
        try? await Task.sleep(for: .milliseconds(600))
        await refresh()
        return ok
    }
}

// MARK: - Data export

enum TrackerCSV {
    static let header = ["company", "title", "location", "source", "ats", "state", "status", "score", "mode", "submitted_at", "status_updated_at", "apply_url"]

    /// One row per job that reached the tracker (submitted), newest first.
    static func make(jobs: [JobItem], includeAll: Bool = false) -> String {
        let rows = jobs
            .filter { includeAll || $0.state == .submitted }
            .sorted { ($0.submittedAt ?? $0.discoveredAt) > ($1.submittedAt ?? $1.discoveredAt) }
            .map { j in
                [j.company, j.title, j.location ?? "", j.source.rawValue, j.ats.rawValue, j.state.rawValue, j.status?.rawValue ?? "",
                 j.score.map(String.init) ?? "", j.mode?.rawValue ?? "",
                 j.submittedAt.map(ProtocolCoding.formatDate) ?? "", j.statusUpdatedAt.map(ProtocolCoding.formatDate) ?? "", j.applyURL ?? ""]
            }
        return ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
