// RootView.swift — the main window: NavigationSplitView with the sidebar, a detail stack
// rendering registry screens, the system glass toolbar (the only place Run lives besides ⌘K and
// the Agent menu), the floating details panel, the ⌘K palette and HUD toasts.
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(ScreenRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: LayoutMetrics.sidebarWidth, max: 280)
        } detail: {
            NavigationStack(path: $router.path) {
                registry.view(for: router.selection.screen)
                    .detailColumnSized()
                    .navigationDestination(for: Destination.self) { destination in
                        switch destination {
                        case .job(let id): registry.jobDetail(id: id).detailColumnSized()
                        case .insights: InsightsView().detailColumnSized()
                        }
                    }
            }
            .overlay(alignment: .top) { PausedHairline() }
            .overlay(alignment: .bottom) { SessionHost() }
            // Details float over the screen instead of being a split-view column: as a column it made
            // the window's content wider than the window (cut off at the edge, toolbar collapsed into
            // ">>", and an AppKit constraint loop that crashed the app).
            .overlay(alignment: .trailing) {
                if router.isInspectorPresented {
                    InspectorPanel { router.isInspectorPresented = false }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduced ? nil : Motion.flow, value: router.isInspectorPresented)
            // On the detail column so the controls stay over the screen they act on.
            .toolbar { MainToolbar() }
        }
        .navigationTitle(store.isPaused ? "Paused" : router.selection.title)
        .overlay { CommandPaletteHost() }
        .sheet(isPresented: Binding(get: { router.isAddJobPresented }, set: { router.isAddJobPresented = $0 })) {
            AddJobSheet(seed: router.addJobSeed)
        }
        .overlay { ConfettiOverlay() }
        .onAppear { EasterEggs.installKonami() }
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

extension View {
    /// Screens fill the detail column but never size it: whatever a screen's content measures at
    /// the split view's probe sizes (e.g. wrapped text proposed a near-zero width reports a very
    /// tall minimum), the column's minimum stays zero. Without this one screen could push the
    /// split view's minimum height past the window, and AppKit then laid the whole split view
    /// (sidebar included) out off-screen: a blank window, restored on every launch.
    func detailColumnSized() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
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

/// Toolbar: Add job, Run (menu), Pause/Resume, Auto|Review, Search (⌘K), More, Details. Every
/// control is icon-sized so the bar fits a narrow window. Run controls live only here, in ⌘K and
/// in the Agent menu.
struct MainToolbar: ToolbarContent {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow
    @State private var showModeConfirm = false

    var body: some ToolbarContent {
        SampleDataToolbarItem()  // "Sample data" chip + Set up for real (Features/Onboarding/SampleMode)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                router.requestAddJob()
            } label: {
                Label("Add job by link", systemImage: "link.badge.plus")
            }
            .labelStyle(.iconOnly)
            .help("Add a job by pasting its link (\(AppShortcut.addJobByLink.displayString))")

            Menu {
                Button("Run now: find, score and apply") { Task { await store.runNow() } }
                Button("Apply queued jobs only (\(store.queuedCount))") { Task { await store.applyQueued() } }
                    .disabled(store.queuedCount == 0)
                Button("Collect questions only") { Task { await store.runPrepPass() } }
            } label: {
                Label("Run", systemImage: "play.fill")
            } primaryAction: {
                Task { await store.runNow() }
            }
            .labelStyle(.iconOnly)
            .disabled(store.isPaused || !store.isConnected)
            .help(store.isPaused ? "Resume the agent to run" : "Run now: find, score and apply (\(AppShortcut.runNow.displayString)). Hold for more.")

            Button {
                Haptics.levelChange()
                Task { await store.togglePause() }
            } label: {
                Label(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.iconOnly)
            .help("\(store.isPaused ? "Resume" : "Pause") agent (\(AppShortcut.togglePause.displayString))")
        }
        ToolbarItem(placement: .primaryAction) {
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
            .controlSize(.small)
            .fixedSize()
            .help("Auto sends applications on its own; Review waits for your approval")
            .popover(isPresented: $showModeConfirm, arrowEdge: .bottom) {
                ModeSwitchConfirm(pending: store.counts.awaitingReview) { switchMode in
                    showModeConfirm = false
                    if switchMode { Task { await store.setMode(.auto) } }
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                router.togglePalette()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .help("Search and commands (\(AppShortcut.commandPalette.displayString))")

            Menu {
                Button("Open the agent's Chrome") { Task { await store.openAgentChrome() } }
                Button("Open data folder") { Task { await store.perform(.openDataFolder) } }
                Divider()
                Button("Report a Bug…") { FeedbackRequest.kind = .bug; openWindow(id: WindowID.feedback) }
                Button("Request a Feature…") { FeedbackRequest.kind = .feature; openWindow(id: WindowID.feedback) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More actions")

            Button {
                router.toggleInspector()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .labelStyle(.iconOnly)
            .help("Show or hide details (\(AppShortcut.toggleInspector.displayString))")
        }
    }
}

/// Switching to Auto only switches the mode. It never approves anything: applications already
/// waiting in Review stay there until you approve them on the Review screen.
struct ModeSwitchConfirm: View {
    var pending: Int
    /// true = switch to Auto, false = cancel.
    var onChoose: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Switch to Auto?").font(Typography.title2)
            Text(ModeSwitchConfirm.message(pending: pending))
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer()
                Button("Cancel") { onChoose(false) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Switch to Auto") { onChoose(true) }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.l)
        .frame(width: 320)
    }

    static func message(pending: Int) -> String {
        "New applications will be sent without asking you. The \(pending) already waiting stay in Review until you approve them there."
    }
}

/// The details panel: a floating Liquid Glass pane on the trailing edge (like the system
/// inspector), over the screen's content. No custom material, radius or shadow.
private struct InspectorPanel: View {
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").eyebrowStyle()
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close details (Esc)")
                .accessibilityLabel("Close details")
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.m)
            InspectorContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: LayoutMetrics.inspectorWidth)
        .frame(maxHeight: .infinity)
        .glassChrome(in: RoundedRectangle(cornerRadius: Radius.palette, style: .continuous))
        .padding(Space.s)
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
            EmptyState(symbol: "sidebar.right", title: "No details", message: "Select an item to see its details here.")
        }
    }
}
