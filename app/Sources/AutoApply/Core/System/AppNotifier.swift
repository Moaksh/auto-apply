// AppNotifier.swift — macOS notifications posted BY the app (not the daemon's osascript, which
// macOS attributes to Script Editor). Clicking one brings AutoApply forward on the exact item:
// the Needs-You question (cluster), the Review queue, or the job.
import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifier()

    private weak var store: AppStore?
    private var started = false
    private var recent: [String: Date] = [:]

    /// Call once at launch. No-op outside a real app bundle (tests, `swift run`).
    func start(store: AppStore) {
        self.store = store
        guard !started, Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Map a daemon event to a notification. Quiet by design: only things that need the user.
    func handle(_ event: DaemonEvent, store: AppStore) {
        guard started, store.mockScenarioName == nil else { return }
        switch event {
        case .questionOpened(let p):
            guard GeneralSettings.isNotificationOn("NEEDS_YOU") else { return }
            let c = p.cluster
            let title = c.canonicalQuestion.hasPrefix("Security code") ? "Security code needed" : "Needs your input"
            let where_ = c.companies.prefix(2).joined(separator: ", ")
            post(id: "q-\(c.clusterId)", title: title, body: where_.isEmpty ? c.canonicalQuestion : "\(where_): \(c.canonicalQuestion)",
                 route: ["route": "inbox", "cluster": c.clusterId])
        case .applicationState(let p):
            if p.toState == .awaitingReview, GeneralSettings.isNotificationOn("REVIEW_READY") {
                post(id: "review-\(p.applicationId)", title: "Ready for review", body: jobLabel(p.jobId, store) ?? "A filled application is waiting for you.",
                     route: ["route": "review", "application": String(p.applicationId)])
            } else if p.toState == .submitted, GeneralSettings.isNotificationOn("SUBMITTED") {
                post(id: "sub-\(p.applicationId)", title: "Applied", body: jobLabel(p.jobId, store) ?? "Application submitted.",
                     route: ["route": "job", "job": String(p.jobId)])
            } else if p.toState == .failed, GeneralSettings.isNotificationOn("ERROR") {
                post(id: "fail-\(p.applicationId)", title: "Application failed", body: [jobLabel(p.jobId, store), p.reason].compactMap { $0 }.joined(separator: " · "),
                     route: ["route": "job", "job": String(p.jobId)])
            }
        default:
            break
        }
    }

    /// Update available / ready (from Updater); clicking restarts into it or opens the prompt.
    func postUpdate(title: String, body: String) {
        guard started else { return }
        post(id: "update-\(title)", title: title, body: body, route: ["route": "update"])
    }

    private func jobLabel(_ jobID: Int, _ store: AppStore) -> String? {
        store.jobs.job(id: jobID).map { "\($0.company) · \($0.title)" }
    }

    private func post(id: String, title: String, body: String, route: [String: String]) {
        if let last = recent[id], Date().timeIntervalSince(last) < 60 { return }
        recent[id] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = route
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        completionHandler()
        Task { @MainActor in self.open(info) }
    }

    /// Bring the main window forward on the item the notification was about.
    func open(_ info: [String: String]) {
        guard let store else { return }
        NSApp.activate()
        store.router.requestMainWindow()
        switch info["route"] {
        case "inbox":
            store.router.go(.needsYou)
            if let cluster = info["cluster"] { InboxModel.shared(for: store).select(cluster) }
        case "review":
            store.router.go(.review)
        case "update":
            Updater.shared.restartPrompt()
        case "job":
            if let id = info["job"].flatMap(Int.init) { store.router.openJob(id: id) }
        default:
            break
        }
    }
}
