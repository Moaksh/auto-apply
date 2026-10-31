// SettingsView.swift — the Settings scene (⌘,): a tabbed toolbar
// whose height animates per tab. Preference and never-guess edits auto-save as partial
// `update_preferences` / `update_never_guess` patches; app-local toggles live in UserDefaults.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@objc(SettingsFeature)
final class SettingsFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.settings) { SettingsView() }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @Bindable private var navigation = SettingsNavigation.shared

    private var model: SettingsModel { SettingsModel.shared(for: store) }

    var body: some View {
        let model = self.model
        TabView(selection: $navigation.tab) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabContent(tab: tab, model: model)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .badge(tab == .sources ? store.library.pendingSuggestionCount : 0)  // suggested companies
                    .tag(tab)
            }
        }
        .frame(width: 680)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: navigation.tab)
        .onAppear { model.syncFromStore() }
        .onChange(of: store.preferences) { model.syncFromStore() }
        .onChange(of: store.library.neverGuess) { model.syncFromStore() }
        .onDisappear { Task { await model.flush() } }
        .overlay { ConfettiOverlay() }
        .toastHost(store.toasts)
    }
}

private struct SettingsTabContent: View {
    var tab: SettingsTab
    var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                switch tab {
                case .general: GeneralSettingsTab()
                case .preferences: PreferencesSettingsTab(model: model)
                case .guardrails: GuardrailsSettingsTab(model: model)
                case .modes: ModesSettingsTab(model: model)
                case .sources: SourcesSettingsTab(model: model)
                case .schedule: ScheduleSettingsTab(model: model)
                case .outreach: OutreachSettingsTab(model: model)
                case .agent: AgentSettingsTab()
                case .data: DataSettingsTab()
                }
                if tab != .general && tab != .agent && tab != .data {
                    SaveStatusLine(state: tab == .guardrails ? model.neverGuessSave : model.preferencesSave,
                                   secondary: tab == .guardrails ? model.preferencesSave : nil,
                                   blockedBy: model.issues.first?.message)
                }
                MadeWithLoveFooter()
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 360, idealHeight: 540, maxHeight: 720)
    }
}

/// "Saved" / "Saving…" / inline error under each tab. While a field is invalid it says nothing
/// is being saved, instead of promising that changes save automatically.
struct SaveStatusLine: View {
    var state: SettingsModel.SaveState
    var secondary: SettingsModel.SaveState?
    /// The first validation problem: while set, edits are held, not saved.
    var blockedBy: String? = nil

    var body: some View {
        HStack(spacing: Space.xs) {
            if let blockedBy, effective != .saving {
                Image(systemName: StatusKind.error.symbol).foregroundStyle(Palette.error)
                Text("Not saved · \(blockedBy)").foregroundStyle(Palette.error)
            } else {
                content
            }
        }
        .font(Typography.callout)
    }

    @ViewBuilder
    private var content: some View {
            switch effective {
            case .idle: Text("Changes save automatically.").foregroundStyle(Palette.textTertiary)
            case .saving: ProgressView().controlSize(.small); Text("Saving…").foregroundStyle(Palette.textSecondary)
            case .saved: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.applied); Text("Saved").foregroundStyle(Palette.textSecondary)
            case .failed(let message): Image(systemName: StatusKind.error.symbol).foregroundStyle(Palette.error); Text(message).foregroundStyle(Palette.error)
            }
    }

    private var effective: SettingsModel.SaveState {
        if case .failed = state { return state }
        if let secondary, case .failed = secondary { return secondary }
        if state == .saving || secondary == .saving { return .saving }
        return state
    }
}

/// Label column + content, used by every tab.
struct SettingsRow<Content: View>: View {
    var title: String
    var help: String?
    var issue: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, help: String? = nil, issue: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.help = help
        self.issue = issue
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            Text(title).font(Typography.bodyEmph).frame(width: 150, alignment: .trailing)
            VStack(alignment: .leading, spacing: Space.xs) {
                content()
                if let issue {
                    Text(issue).font(Typography.callout).foregroundStyle(Palette.error)
                } else if let help {
                    Text(help).font(Typography.callout).foregroundStyle(Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage(AppDelegate.showInDockKey) private var showInDock = true
    @AppStorage(GeneralSettings.menuBarCounterKey) private var menuBarCounter = true
    @AppStorage(Sounds.levelKey) private var soundLevel = Sounds.level()
    @AppStorage(Haptics.settingsKey) private var haptics = true
    @AppStorage(ApproveStyle.storageKey) private var approveStyle = ApproveStyle.ticket
    @State private var launchAtLogin = GeneralSettings.launchAtLogin
    @State private var loginError: String?

    var body: some View {
        SettingsRow("App") {
            Toggle("Show in Dock", isOn: Binding(get: { showInDock }, set: { showInDock = $0; GeneralSettings.applyShowInDock($0) }))
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                loginError = GeneralSettings.setLaunchAtLogin(on)
                launchAtLogin = GeneralSettings.launchAtLogin
            }))
            if let loginError { Text(loginError).font(Typography.callout).foregroundStyle(Palette.error) }
            Toggle("Show applied count next to the menu bar icon", isOn: $menuBarCounter)
        }
        SettingsRow("Notifications", help: "Quiet by default: no notification per submission unless you turn it on.") {
            ForEach(GeneralSettings.notificationCategories, id: \.key) { category in
                NotificationToggle(key: category.key, title: category.title, defaultOn: category.defaultOn)
            }
        }
        SettingsRow("Feedback") {
            Picker("Sounds", selection: $soundLevel) {
                ForEach(Sounds.Level.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Moments only: an interview or offer, inbox zero and easter eggs. All: also every answer, move and approval.")
            Toggle("Trackpad haptics", isOn: $haptics)
        }
        SettingsRow("Review", help: "Ticket: tear the stub off to approve. Classic: the Approve & send button. Either way it waits \(Int(SendHoldTiming.seconds(SendHoldTiming.window))) seconds with Undo before anything is sent.") {
            Picker("Approve style", selection: $approveStyle) {
                ForEach(ApproveStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        UpdatesSettingsRow()
        FeedbackSettingsRow()
    }
}

/// Settings → General → Feedback: opens the pre-filled GitHub issue window.
private struct FeedbackSettingsRow: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsRow("Feedback", help: "Opens a GitHub issue in your browser, filled in for you. Bug reports can include redacted logs.") {
            HStack(spacing: Space.s) {
                Button("Report a Bug…") {
                    FeedbackRequest.kind = .bug
                    openWindow(id: WindowID.feedback)
                }
                Button("Request a Feature…") {
                    FeedbackRequest.kind = .feature
                    openWindow(id: WindowID.feedback)
                }
            }
        }
    }
}

/// Settings → General → Updates (GitHub Releases).
private struct UpdatesSettingsRow: View {
    @AppStorage(Updater.autoCheckKey) private var autoCheck = true
    @AppStorage(Updater.autoInstallKey) private var autoInstall = true
    private var updater: Updater { Updater.shared }

    var body: some View {
        SettingsRow("Updates", help: "Updates come from the project's GitHub Releases: checking asks GitHub for the latest version, and downloading fetches it. Both are on unless you turn them off here.") {
            Toggle("Check for updates automatically", isOn: $autoCheck)
            Toggle("Download updates and install them when I quit", isOn: $autoInstall).disabled(!autoCheck)
            HStack(spacing: Space.s) {
                Text("Version \(Updater.currentVersion)").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Text(status).font(Typography.callout).foregroundStyle(Palette.textTertiary)
                Spacer()
                if let v = updater.readyVersion {
                    Button("Restart to Update to \(v)") { updater.installAndRelaunch() }.buttonStyle(.secondaryLink)
                } else {
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.phase == .checking)
                }
            }
        }
    }

    private var status: String {
        switch updater.phase {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "· Up to date"
        case .downloading(let v): "· Downloading \(v)…"
        case .ready(let v): "· \(v) ready"
        case .failed(let m): "· \(m)"
        }
    }
}

private struct NotificationToggle: View {
    var key: String
    var title: String
    var defaultOn: Bool
    @AppStorage private var on: Bool

    init(key: String, title: String, defaultOn: Bool) {
        self.key = key
        self.title = title
        self.defaultOn = defaultOn
        _on = AppStorage(wrappedValue: defaultOn, GeneralSettings.notifyPrefix + key)
    }

    var body: some View { Toggle(title, isOn: $on) }
}

// MARK: - Agent

private struct AgentSettingsTab: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var agent = DaemonAgentModel()

    var body: some View {
        SettingsRow("Connection") {
            HStack(spacing: Space.s) {
                StatusDot(kind: store.isConnected ? .applied : .error)
                Text(store.isConnected ? "Connected to the agent" : "Not connected").font(Typography.body)
                if let version = store.daemonVersion {
                    Text("v\(version)").font(Typography.mono).foregroundStyle(Palette.textSecondary)
                }
            }
            if let mock = store.mockScenarioName {
                Text("Mock agent · scenario \(mock)").font(Typography.callout).foregroundStyle(Palette.needsYou)
            }
        }
        SettingsRow("Background agent", help: "The agent runs in the background on this Mac, even when this window is closed.") {
            HStack(spacing: Space.s) {
                if let status = agent.status {
                    StatusDot(kind: status.running ? .applied : (status.loaded ? .needsYou : .skipped))
                    Text(status.summary).font(Typography.body)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(Typography.body).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button("Refresh") { Task { await agent.refresh() } }.buttonStyle(.borderless)
            }
            HStack(spacing: Space.s) {
                Button("Restart agent") {
                    Task {
                        if SampleMode.isActive(store) {
                            store.toasts.show("Sample data is made up and lives only in memory. Set up for real to use this.", symbol: "info.circle", style: .info)
                            return
                        }
                        let ok = await agent.restart()
                        store.toasts.show(ok ? "Restarting the agent…" : "Couldn't restart the agent. Is it installed?",
                                          symbol: ok ? "arrow.clockwise" : StatusKind.error.symbol, style: ok ? .info : .error)
                    }
                }
                .disabled(agent.busy || agent.status?.loaded != true)
                if agent.status?.installed == true || agent.status?.loaded == true {
                    Button("Uninstall") { Task { _ = await agent.runInstaller("uninstall") } }.disabled(agent.busy)
                } else {
                    Button("Install") { Task { _ = await agent.runInstaller("install") } }
                        .buttonStyle(.bordered)
                        .disabled(agent.busy || agent.engineDir.isEmpty)
                }
                if agent.busy { ProgressView().controlSize(.small) }
            }
            if let output = agent.lastOutput, !output.isEmpty {
                Text(output).font(Typography.mono).foregroundStyle(Palette.textSecondary).textSelection(.enabled)
                    .padding(Space.s).frame(maxWidth: .infinity, alignment: .leading).well()
            }
        }
        SettingsRow("Agent folder", help: "Where the agent's code lives on this Mac. Used to install it.") {
            HStack {
                TextField("…/auto_apply/engine", text: $agent.engineDir).textFieldStyle(.roundedBorder).font(Typography.mono)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { agent.engineDir = url.path }
                }
            }
        }
        SettingsRow("Files") {
            PathRow(title: "Data folder", url: AppPaths.resolve().home)
            PathRow(title: "Logs", url: AppPaths.resolve().logs)
            PathRow(title: "Agent Chrome profile", url: AppPaths.resolve().chromeProfile)
        }
        SettingsRow("Onboarding") {
            Button("Re-run onboarding") { openWindow(id: WindowID.onboarding) }
        }
        .task { await agent.refresh() }
    }
}

/// "Data folder  ~/Library/…/AutoApply  [Reveal]"
struct PathRow: View {
    var title: String
    var url: URL

    var body: some View {
        HStack(spacing: Space.s) {
            Text(title).font(Typography.body).frame(width: 150, alignment: .leading)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(Typography.mono)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Open") {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.secondaryLink)
        }
    }
}

// MARK: - Data

private struct DataSettingsTab: View {
    @Environment(AppStore.self) private var store
    @State private var includeAll = false

    var body: some View {
        SettingsRow("Database", help: "The app only reads it; the agent writes it.") {
            PathRow(title: "autoapply.db", url: AppPaths.resolve().database)
        }
        SettingsRow("Application files") {
            PathRow(title: "Screenshots", url: AppPaths.resolve().screenshots)
            PathRow(title: "Cover letters", url: AppPaths.resolve().coverLetters)
            PathRow(title: "Resumes", url: AppPaths.resolve().resumes)
        }
        SettingsRow("Export", help: "A CSV of the Pipeline: company, role, status, score, dates and links.") {
            Toggle("Include jobs that were never applied to", isOn: $includeAll)
            Button("Export Pipeline as CSV…") { export() }
                .disabled(!store.jobs.isLoaded)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "autoapply-tracker-\(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = TrackerCSV.make(jobs: store.jobs.all, includeAll: includeAll)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            store.toasts.show("Exported \(url.lastPathComponent)", symbol: "square.and.arrow.up", style: .success)
        } catch {
            store.toasts.error("Couldn't write the CSV: \(error.localizedDescription)")
        }
    }
}
