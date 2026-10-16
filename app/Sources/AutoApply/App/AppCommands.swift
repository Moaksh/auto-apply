// AppCommands.swift — every menu-scoped shortcut from ShortcutRegistry lives in the menu bar so
// it's discoverable and VoiceOver-accessible (§3.4): Agent, Go, Job menus (+ Debug in DEBUG).
import SwiftUI

struct AppCommands: Commands {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            let updater = Updater.shared
            Button(updater.readyVersion.map { "Restart to Update to \($0)…" } ?? "Check for Updates…") {
                Task { await updater.check(userInitiated: true) }
            }
        }
        CommandGroup(after: .help) {
            Button("Report a Bug…") {
                FeedbackRequest.kind = .bug
                openWindow(id: WindowID.feedback)
            }
            Button("Request a Feature…") {
                FeedbackRequest.kind = .feature
                openWindow(id: WindowID.feedback)
            }
        }
        CommandGroup(after: .sidebar) {
            Button(AppShortcut.toggleInspector.title) { store.router.toggleInspector() }.keyboardShortcut(.toggleInspector)
            Button(AppShortcut.toggleSidebar.title) { store.router.toggleSidebar() }.keyboardShortcut(.toggleSidebar)
            Button(AppShortcut.commandPalette.title) { store.router.togglePalette() }.keyboardShortcut(.commandPalette)
        }

        CommandMenu("Agent") {
            Button(store.isPaused ? "Resume Agent" : "Pause Agent") {
                Haptics.levelChange()
                Task { await store.togglePause() }
            }
            .keyboardShortcut(.togglePause)
            Button(AppShortcut.runNow.title) { Task { await store.runNow() } }.keyboardShortcut(.runNow)
            Button(AppShortcut.runPrep.title) { Task { await store.runPrepPass() } }.keyboardShortcut(.runPrep)
            Button(AppShortcut.nextQuestion.title) { Task { await store.perform(.nextQuestion) } }.keyboardShortcut(.nextQuestion)
            Divider()
            Picker("Mode", selection: Binding(get: { store.mode }, set: { m in Task { await store.setMode(m) } })) {
                Text("Auto").tag(Mode.auto)
                Text("Review").tag(Mode.review)
            }
            Divider()
            Button("Open Agent Chrome") { Task { await store.openAgentChrome() } }
            Button("Open Data Folder") { Task { await store.perform(.openDataFolder) } }
            Button("Restart Daemon") { Task { _ = await DaemonControl.restart() } }
        }

        CommandMenu("Go") {
            ForEach(SidebarItem.allCases) { item in
                Button(item.title) {
                    openWindow(id: WindowID.main)
                    store.router.go(item)
                }
                .keyboardShortcut(AppShortcut.go(item))
            }
            Divider()
            Button(AppShortcut.openMainWindow.title) {
                openWindow(id: WindowID.main)
                NSApp.activate()
            }
            .keyboardShortcut(.openMainWindow)
        }

        CommandMenu("Job") {
            let focused = store.router.isJobContextActive ? store.router.focusedJobID.flatMap { store.jobs.job(id: $0) } : nil
            Button(AppShortcut.moveStatusPrevious.title) { moveFocused(by: -1) }
                .keyboardShortcut(.moveStatusPrevious)
                .disabled(focused?.status?.previous == nil)
            Button(AppShortcut.moveStatusNext.title) { moveFocused(by: 1) }
                .keyboardShortcut(.moveStatusNext)
                .disabled(focused?.state != .submitted || focused?.status?.next == nil)
            Button(AppShortcut.openJobWindow.title) {
                if let id = store.router.focusedJobID { openWindow(id: WindowID.job, value: id) }
            }
            .keyboardShortcut(.openJobWindow)
            .disabled(focused == nil)
            Button("Open Posting") {
                if let url = (focused?.applyURL ?? focused?.sourceURL).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
            }
            .disabled(focused?.applyURL == nil && focused?.sourceURL == nil)
        }

        #if DEBUG
        CommandMenu("Debug") {
            Menu("Mock Scenario") {
                ForEach(MockScenario.allCases) { scenario in
                    Button(scenario.title) { Task { await AppBootstrap.switchToMock(scenario, speed: 1, store: store) } }
                }
                Divider()
                ForEach(MockScenario.allCases) { scenario in
                    Button("\(scenario.title) at 4×") { Task { await AppBootstrap.switchToMock(scenario, speed: 4, store: store) } }
                }
            }
            Button("Use Live Daemon") { Task { await AppBootstrap.switchToLive(store: store) } }
            Divider()
            Toggle("Simulate Reduce Motion", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: DebugSettings.simulateReduceMotionKey) },
                set: { UserDefaults.standard.set($0, forKey: DebugSettings.simulateReduceMotionKey) }))
            Button("Show Onboarding") { openWindow(id: WindowID.onboarding) }
            Button("Test Toast") { store.toasts.show("Copied · Years of experience", symbol: "checkmark", style: .success) }
            Button("Recompute Stats") { store.recomputeStats() }
        }
        #endif
    }

    private func moveFocused(by delta: Int) {
        // Menu key equivalents win over the first responder. If the user is typing, give ⌘← / ⌘→
        // back to the text view as "move to line start/end" instead of moving a job's status.
        if NSApp.keyWindow?.firstResponder is NSTextView {
            let action = delta < 0 ? #selector(NSResponder.moveToLeftEndOfLine(_:)) : #selector(NSResponder.moveToRightEndOfLine(_:))
            NSApp.sendAction(action, to: nil, from: nil)
            return
        }
        guard store.router.isJobContextActive, let id = store.router.focusedJobID, let job = store.jobs.job(id: id), job.state == .submitted,
              let appID = job.applicationID else { return }
        let current = job.status ?? .applied
        guard let target = delta < 0 ? current.previous : current.next else { return }
        Task { await store.setStatus(applicationID: appID, status: target) }
    }
}
