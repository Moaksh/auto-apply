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
    @Environment(\.motionReduced) private var reduced

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

/// Toolbar: Run now, Pause/Resume, Auto|Review, search (⌘K), More. Every control is one click
/// and icon-sized, so the bar fits even a narrow window (no ">>" overflow menu hiding them).
struct MainToolbar: ToolbarContent {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow
    @State private var showModeConfirm = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                router.requestAddJob()
            } label: {
                Label("Add job by link", systemImage: "link.badge.plus")
            }
            .labelStyle(.iconOnly)
            .help("Add a job by pasting its link (\(AppShortcut.addJobByLink.displayString))")

            Button {
                Task { await store.runNow() }
            } label: {
                Label("Run now", systemImage: "bolt.fill")
            }
            .labelStyle(.iconOnly)
            .disabled(store.isPaused)
            .help(store.isPaused ? "Resume the agent to run" : "Run now: search, score and apply (\(AppShortcut.runNow.displayString))")

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
            .help("Auto applies on its own; Review waits for your approval")
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                router.togglePalette()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .help("Search and commands (\(AppShortcut.commandPalette.displayString))")

            Menu {
                Button("Run Prep pass") { Task { await store.runPrepPass() } }.keyboardShortcut(.runPrep)
                Divider()
                Button("Open agent Chrome") { Task { await store.openAgentChrome() } }
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

/// The details panel: a floating glass sheet on the trailing edge, over the screen's content.
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
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.35), radius: 18, x: -4, y: 0)
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
            EmptyState(symbol: "sidebar.right", title: "Nothing to inspect", message: "Select an item to see its details here.")
        }
    }
}
