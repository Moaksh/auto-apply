// AppBootstrap.swift — chooses the backend: MockDaemon when AUTOAPPLY_MOCK=<scenario> (env var
// or `-AUTOAPPLY_MOCK <scenario>` launch argument), otherwise the live socket + read-only DB.
import Foundation

@MainActor
enum AppBootstrap {
    static func makeStore(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppStore {
        if let scenario = MockDaemon.requestedScenario(environment: environment) {
            let daemon = MockDaemon(scenario: scenario, speed: MockDaemon.requestedSpeed(environment: environment))
            return AppStore(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
        }
        let paths = AppPaths.resolve(environment: environment)
        return AppStore(client: UnixSocketDaemonClient(paths: paths), repository: GRDBRepository(paths: paths))
    }

    /// Swap to a mock scenario at runtime (Debug menu).
    static func switchToMock(_ scenario: MockScenario, speed: Double, store: AppStore) async {
        let daemon = MockDaemon(scenario: scenario, speed: speed)
        await store.replaceBackend(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
    }

    /// Swap back to the live daemon.
    static func switchToLive(store: AppStore) async {
        let paths = AppPaths.resolve()
        await store.replaceBackend(client: UnixSocketDaemonClient(paths: paths), repository: GRDBRepository(paths: paths), mockScenarioName: nil)
    }
}
