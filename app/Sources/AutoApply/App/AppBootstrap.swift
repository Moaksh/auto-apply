// AppBootstrap.swift — chooses the backend: MockDaemon when AUTOAPPLY_MOCK=<scenario> (env var
// or `-AUTOAPPLY_MOCK <scenario>` launch argument); the sample backend while "Explore with sample
// data" is on (SampleMode, persisted); otherwise the live socket + read-only DB.
import Foundation

@MainActor
enum AppBootstrap {
    static func makeStore(environment: [String: String] = ProcessInfo.processInfo.environment,
                          defaults: UserDefaults = .standard) -> AppStore {
        if let scenario = MockDaemon.requestedScenario(environment: environment, defaults: defaults) {
            let (client, repository) = makeMockBackend(scenario, speed: MockDaemon.requestedSpeed(environment: environment, defaults: defaults))
            return AppStore(client: client, repository: repository, mockScenarioName: scenario.rawValue)
        }
        // Sample mode resumes on relaunch: never the real DB, the socket or the Keychain.
        if SampleMode.isPersisted(defaults) {
            let (client, repository) = makeMockBackend(SampleMode.scenario, speed: 1)
            return AppStore(client: client, repository: repository, mockScenarioName: SampleMode.scenario.rawValue)
        }
        let paths = AppPaths.resolve(environment: environment)
        return AppStore(client: UnixSocketDaemonClient(paths: paths), repository: GRDBRepository(paths: paths))
    }

    /// A mock backend for `scenario`. The sample scenario is wrapped so live-only commands are refused.
    static func makeMockBackend(_ scenario: MockScenario, speed: Double) -> (any DaemonConnecting, InMemoryRepository) {
        let daemon = MockDaemon(scenario: scenario, speed: speed)
        if scenario == SampleMode.scenario { return (SampleModeClient(base: daemon), daemon.repository) }
        return (daemon, daemon.repository)
    }

    /// Swap to a mock scenario at runtime (Debug menu).
    static func switchToMock(_ scenario: MockScenario, speed: Double, store: AppStore, defaults: UserDefaults = .standard) async {
        if scenario != SampleMode.scenario { defaults.removeObject(forKey: SampleMode.defaultsKey) }
        let (client, repository) = makeMockBackend(scenario, speed: speed)
        await store.replaceBackend(client: client, repository: repository, mockScenarioName: scenario.rawValue)
    }

    /// Swap to the sample backend ("Explore with sample data").
    static func switchToSample(store: AppStore, speed: Double = 1) async {
        let (client, repository) = makeMockBackend(SampleMode.scenario, speed: speed)
        await store.replaceBackend(client: client, repository: repository, mockScenarioName: SampleMode.scenario.rawValue)
    }

    /// Swap back to the live daemon (also ends sample mode for the next launch).
    static func switchToLive(store: AppStore, defaults: UserDefaults = .standard) async {
        defaults.removeObject(forKey: SampleMode.defaultsKey)
        let paths = AppPaths.resolve()
        await store.replaceBackend(client: UnixSocketDaemonClient(paths: paths), repository: GRDBRepository(paths: paths), mockScenarioName: nil)
    }
}
