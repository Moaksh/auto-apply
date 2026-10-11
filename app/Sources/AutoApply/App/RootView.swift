// RootView.swift — the main window: NavigationSplitView with the sidebar spine, a detail stack
// rendering registry screens, the unified glass toolbar, contextual inspector, ⌘K palette
// overlay and HUD toasts (§3.2).
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(ScreenRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: LayoutMetrics.sidebarWidth, max: 280)
        } detail: {
            NavigationStack(path: $router.path) {
                registry.view(for: router.selection.screen)
                    .navigationDestination(for: Destination.self) { destination in
                        switch destination {
                        case .job(let id): registry.jobDetail(id: id)
                        }
                    }
            }
            .overlay(alignment: .top) { PausedHairline() }
        }
        .navigationTitle(store.isPaused ? "Paused" : router.selection.title)
        .toolbar { MainToolbar() }
        .inspector(isPresented: $router.isInspectorPresented) {
            InspectorContent()
                .inspectorColumnWidth(min: LayoutMetrics.inspectorMin, ideal: 360, max: LayoutMetrics.inspectorMax)
        }
        .overlay { CommandPaletteHost() }
        .toastHost(store.toasts)
        .onChange(of: router.settingsRequest) { openSettings() }
        .onChange(of: router.jobWindowRequest) { _, request in
            if let request { openWindow(id: WindowID.job, value: request.id) }
        }
        .task(id: OnboardingGate.shouldPresent(store: store)) {
            guard OnboardingGate.shouldPresent(store: store) else { return }
            openWindow(id: WindowID.onboarding)
            dismissWindow(id: WindowID.main)
        }
        .onKeyPress(.escape) {
            guard router.isPalettePresented || router.isInspectorPresented else { return .ignored }
            router.escape()
            return .handled
        }
    }
}

/// When to show onboarding instead of the main window.
@MainActor
enum OnboardingGate {
    static let completedLocallyKey = "onboarding.completedLocally"

    static func shouldPresent(store: AppStore) -> Bool {
        if store.needsOnboarding { return true }
        // Fresh machine: no daemon yet (it's installed during onboarding's system check).
        let completedLocally = UserDefaults.standard.bool(forKey: completedLocallyKey)
        return !store.hasSnapshot && store.isDaemonUnreachable && !completedLocally && store.mockScenarioName == nil
    }

    static func markCompleted() { UserDefaults.standard.set(true, forKey: completedLocallyKey) }
}

/// While paused, the whole window gets a 1pt amber hairline under the toolbar.
private struct PausedHairline: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.isPaused {
            Rectangle().fill(Palette.needsYou).frame(height: 1).transition(.opacity)
        }
    }
}

/// Toolbar: Pause/Resume, Auto|Review, search (⌘K), More.
struct MainToolbar: ToolbarContent {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var showModeConfirm = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Haptics.levelChange()
                Task { await store.togglePause() }
            } label: {
                Label(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help("\(store.isPaused ? "Resume" : "Pause") agent (\(AppShortcut.togglePause.displayString))")

            Picker("Mode", selection: Binding(get: { store.mode }, set: { newMode in
                if newMode == .auto && store.counts.awaitingReview > 0 {
                    showModeConfirm = true
                } else {
                    Task { await store.setMode(newMode) }
                }
            })) {
                Text("Auto").tag(Mode.auto)
                Text("Review").tag(Mode.review)
            }
            .pickerStyle(.segmented)
            .help("Autonomy mode")
            .popover(isPresented: $showModeConfirm, arrowEdge: .bottom) {
                ModeSwitchConfirm(pending: store.counts.awaitingReview) { approveAll in
                    showModeConfirm = false
                    Task {
                        if approveAll {
                            await store.approve(applicationIDs: store.jobs.awaitingReview.compactMap(\.applicationID))
                        }
                        await store.setMode(.auto)
                    }
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                router.togglePalette()
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "magnifyingglass")
                    Text("Search…").foregroundStyle(Palette.textSecondary)
                    KeyCap(.commandPalette)
                }
            }
            .help("Command palette (\(AppShortcut.commandPalette.displayString))")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Run now") { Task { await store.runNow() } }.keyboardShortcut(.runNow)
                Button("Run Prep pass") { Task { await store.runPrepPass() } }.keyboardShortcut(.runPrep)
                Divider()
                Button("Open agent Chrome") { Task { await store.openAgentChrome() } }
                Button("Open data folder") { Task { await store.perform(.openDataFolder) } }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// "Approve 3 pending, or keep them in Review?" — inline decision, not a default (§3.2).
private struct ModeSwitchConfirm: View {
    var pending: Int
    var onChoose: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Switch to Auto").font(Typography.title2)
            Text("\(pending) application\(pending == 1 ? " is" : "s are") waiting for review.")
                .font(Typography.body).foregroundStyle(Palette.textSecondary)
            HStack {
                Button("Keep in Review") { onChoose(false) }.buttonStyle(.glass)
                Button("Approve \(pending)") { onChoose(true) }.buttonStyle(.glassProminent)
            }
        }
        .padding(Space.l)
        .frame(width: 300)
    }
}

/// Inspector content for the current screen (registered by features); job summary for Pipeline.
private struct InspectorContent: View {
    @Environment(Router.self) private var router
    @Environment(ScreenRegistry.self) private var registry

    var body: some View {
        if router.selection == .pipeline, let id = router.focusedJobID, let view = registry.jobInspector(id: id) {
            view
        } else if let view = registry.inspector(for: router.selection.screen) {
            view
        } else {
            EmptyState(symbol: "sidebar.right", title: "Nothing to inspect", message: "Select an item to see its details here.")
        }
    }
}
