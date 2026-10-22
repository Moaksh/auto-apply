// SampleMode.swift — "Explore with sample data" (DESIGN_AWARD_VISION 1I): a zero-install path
// through the whole app. Choosing it on the welcome screen swaps the backend for the in-memory
// MockDaemon running `MockScenario.sample`, wrapped in `SampleModeClient`, which refuses the few
// commands that would reach the real world (the agent's Chrome, the Keychain, mail accounts) with
// a plain message. Nothing in sample mode opens the real database, the socket or the network.
// The choice persists (UserDefaults) until "Set up for real", which returns to onboarding on the
// live agent with every sample value cleared out of the store.
import SwiftUI

@MainActor
enum SampleMode {
    /// UserDefaults flag: relaunch resumes sample mode while it's set.
    nonisolated static let defaultsKey = "sampleMode.active"
    nonisolated static let scenario = MockScenario.sample

    nonisolated static func isPersisted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func isActive(_ store: AppStore) -> Bool { store.mockScenarioName == scenario.rawValue }

    /// Switch to the sample backend and remember the choice.
    static func enter(store: AppStore, defaults: UserDefaults = .standard, speed: Double = 1) async {
        defaults.set(true, forKey: defaultsKey)
        await AppBootstrap.switchToSample(store: store, speed: speed)
        store.router.go(.dashboard)
    }

    /// Leave sample mode: forget the choice, clear every sample value out of the store (so
    /// onboarding starts empty and nothing sample-made is ever sent to the real agent), then
    /// connect to the live agent. The caller opens the onboarding window.
    static func exit(store: AppStore, defaults: UserDefaults = .standard,
                     goLive: @MainActor (AppStore) async -> Void = { await AppBootstrap.switchToLive(store: $0) }) async {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: OnboardingModel.stepDefaultsKey)
        store.setPreferences(Preferences())
        store.setOnboarding(OnboardingState())
        let library = store.library
        library.profile = Profile()
        library.neverGuess = NeverGuess()
        library.resumeVariants = []
        library.stories = []
        library.memoryAnswers = []
        library.easyApply = []
        library.companySuggestions = []
        library.runs = []
        store.outreach.replace(OutreachData())
        store.outreach.replaceReplies([])
        await goLive(store)
    }

    // MARK: Live-only actions

    /// The message shown instead of running `command` in sample mode, or nil when the command is
    /// safe to simulate. Everything here would otherwise reach Chrome, the Keychain or a mailbox.
    nonisolated static func blockedMessage(for command: Command) -> String? {
        switch command {
        case .openAgentChrome:
            "This is sample data, so there's no agent Chrome to open. Set up for real to use it."
        case .onboardingConnectSource, .checkSourceLogin:
            "Signing in to job sites needs the real agent. Set up for real to connect LinkedIn or Glassdoor."
        case .revealSiteAccountPassword:
            "Sample accounts have no passwords. Real ones stay in your Mac's Keychain."
        case .setMailAccount, .clearMailAccount, .deleteSiteAccount, .setProviderKey:
            "Sample data never touches your Keychain or email. Set up for real to connect this."
        default:
            nil
        }
    }
}

/// The sample backend: the MockDaemon, minus anything live-only. Guarded commands get an
/// `unavailable` error with `SampleMode.blockedMessage`, which the store shows as a toast.
final class SampleModeClient: DaemonConnecting, DaemonConnectionObserving {
    let base: MockDaemon

    init(base: MockDaemon) { self.base = base }

    var repository: InMemoryRepository { base.repository }
    var connectionState: DaemonConnectionState { get async { await base.connectionState } }
    var events: AsyncStream<EventEnvelope> { base.events }
    var connectionStates: AsyncStream<DaemonConnectionState> { base.connectionStates }

    @discardableResult
    func connect() async throws -> SnapshotPayload { try await base.connect() }

    func disconnect() async { await base.disconnect() }

    @discardableResult
    func send(_ command: Command) async throws -> String {
        if SampleMode.blockedMessage(for: command) != nil { return ProtocolCoding.newID() }
        return try await base.send(command)
    }

    func request(_ command: Command, timeout: Duration) async throws -> EventEnvelope {
        if let message = SampleMode.blockedMessage(for: command) {
            throw DaemonClientError.daemon(ErrorPayload(code: .unavailable, message: message, details: ["sample": .bool(true)]))
        }
        return try await base.request(command, timeout: timeout)
    }
}

// MARK: Toolbar

/// The calm "Sample data" chip, shown only in sample mode (one line in `MainToolbar`).
struct SampleDataToolbarItem: ToolbarContent {
    @Environment(AppStore.self) private var store

    var body: some ToolbarContent {
        if SampleMode.isActive(store) {
            ToolbarItem(placement: .navigation) { SampleDataChip() }
        }
    }
}

/// A quiet capsule; clicking it explains sample mode and offers "Set up for real".
struct SampleDataChip: View {
    @State private var showDetails = false

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            Badge("Sample data", symbol: "testtube.2", tone: .accent)
        }
        .buttonStyle(.plain)
        .help("You're exploring sample data. Click to set up for real.")
        .accessibilityLabel("Sample data")
        .accessibilityHint("Explains sample mode and offers Set up for real")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            SampleDataCard { showDetails = false }
        }
    }
}

/// What sample mode is, and the way out.
struct SampleDataCard: View {
    var dismiss: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isLeaving = false

    static let message = "The person, jobs and replies here are made up. Nothing leaves this Mac, and the agent's Chrome, your Keychain and your email are never used."

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("You're exploring sample data").font(Typography.title2)
            Text(Self.message)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Button("Keep exploring", action: dismiss)
                    .buttonStyle(.secondaryLink)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    setUpForReal()
                } label: {
                    HStack(spacing: Space.xs) {
                        if isLeaving { ProgressView().controlSize(.small) }
                        Text("Set up for real")
                    }
                }
                .buttonStyle(.primaryPill)
                .keyboardShortcut(.defaultAction)
                .disabled(isLeaving)
            }
        }
        .padding(Space.l)
        .frame(width: 340)
    }

    private func setUpForReal() {
        isLeaving = true
        Task {
            await SampleMode.exit(store: store)
            dismiss()
            openWindow(id: WindowID.onboarding)
            dismissWindow(id: WindowID.main)
        }
    }
}
