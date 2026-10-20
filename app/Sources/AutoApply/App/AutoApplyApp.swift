// AutoApplyApp.swift — app entry point and scenes (docs/UI_UX_PLAN.md §3.1).
import AppKit
import SwiftUI

@main
struct AutoApplyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @AppStorage(DebugSettings.simulateReduceMotionKey) private var simulateReduceMotion = false

    init() {
        let store = AppBootstrap.makeStore()
        ScreenRegistry.shared.discoverFeatures()
        store.start()
        AppNotifier.shared.start(store: store)
        Updater.shared.start(store: store)
        // An updated app moves the daemon onto its own build (re-install, or restart in a dev checkout).
        Task { await DaemonControl.refreshAfterUpdate() }
        _store = State(initialValue: store)
    }

    var body: some Scene {
        Window("AutoApply", id: WindowID.main) {
            RootView()
                .appEnvironment(store, simulateReduceMotion: simulateReduceMotion)
                .frame(minWidth: LayoutMetrics.minWindow.width, minHeight: LayoutMetrics.minWindow.height)
        }
        .defaultSize(width: LayoutMetrics.defaultWindow.width, height: LayoutMetrics.defaultWindow.height)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(store: store) }

        Window("Onboarding", id: WindowID.onboarding) {
            OnboardingView()
                .appEnvironment(store, simulateReduceMotion: simulateReduceMotion)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        WindowGroup("Job", id: WindowID.job, for: Int.self) { $jobID in
            Group {
                if let jobID {
                    ScreenRegistry.shared.jobDetail(id: jobID)
                } else {
                    EmptyState(symbol: "questionmark.folder", title: "No job selected")
                }
            }
            .appEnvironment(store, simulateReduceMotion: simulateReduceMotion)
            .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 980, height: 760)

        Window("Send Feedback", id: WindowID.feedback) {
            FeedbackView()
                .appEnvironment(store, simulateReduceMotion: simulateReduceMotion)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            ScreenRegistry.shared.view(for: .settings)
                .appEnvironment(store, simulateReduceMotion: simulateReduceMotion)
                .frame(minWidth: 640, minHeight: 420)
        }

        MenuBarExtra {
            MenuBarPanel()
                .appEnvironment(store, simulateReduceMotion: simulateReduceMotion)
        } label: {
            MenuBarGlyph(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Scene identifiers.
enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
    static let job = "job"
    static let feedback = "feedback"
}

enum DebugSettings {
    static let simulateReduceMotionKey = "debug.simulateReduceMotion"
}

extension View {
    /// Inject the shared store, router, registry and motion environment into a scene root.
    func appEnvironment(_ store: AppStore, simulateReduceMotion: Bool) -> some View {
        self
            .environment(store)
            .environment(store.router)
            .environment(ScreenRegistry.shared)
            .motionEnvironment(simulateReduceMotion: simulateReduceMotion)
            .tint(Palette.accent)
    }
}

/// Keeps the app alive in the menu bar when the main window closes; "Show in Dock" defaults on.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showInDockKey = "showInDock"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showInDock = UserDefaults.standard.object(forKey: Self.showInDockKey) as? Bool ?? true
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.installOnQuitIfReady() }
    }
}
