// AppNotifier.swift — macOS notifications posted BY the app (not the daemon's osascript, which
// macOS attributes to Script Editor). Clicking one brings AutoApply forward on the exact item:
// the Needs-You question (cluster), the Review queue, or the job.
//
// Notifications you can act on (DESIGN_AWARD_VISION 1H): a short text question takes its answer
// inline (a text-input action → `answer_question` for the cluster); a yes/no or a choice of at
// most four options offers them as buttons; "Ready for review" offers Approve and Open. Approve
// takes the same path as the Review screen: the ≈5 s send hold (`SendHoldModel`), so it can
// still be undone in the app before anything is sent, and never a raw command.
//
// A kind no (1F): rejections never notify: not an employer's "not moving forward", not a
// contact's "not interested". They wait quietly in Needs You ▸ Replies.
import AppKit
import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` the notifier uses, so tests can inject a fake.
@MainActor
protocol NotificationCentering: AnyObject {
    func requestAuthorization()
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate)
    func setCategories(_ categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest)
}

/// The real centre. Touched lazily: `UNUserNotificationCenter.current()` traps outside an app bundle.
@MainActor
final class SystemNotificationCenter: NotificationCentering {
    private var center: UNUserNotificationCenter { .current() }
    func requestAuthorization() { center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) { center.delegate = delegate }
    func setCategories(_ categories: Set<UNNotificationCategory>) { center.setNotificationCategories(categories) }
    func add(_ request: UNNotificationRequest) { center.add(request) }
}

@MainActor
final class AppNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifier()

    // Category and action identifiers.
    static let textCategory = "AA_QUESTION_TEXT"
    static let reviewCategory = "AA_REVIEW"
    static let choiceCategoryPrefix = "AA_CHOICE_"
    static let answerAction = "AA_ANSWER"
    static let approveAction = "AA_APPROVE"
    static let openAction = "AA_OPEN"
    static let optionActionPrefix = "AA_OPT_"
    /// Options offered as buttons only up to this many; more open the app instead.
    static let maxInlineOptions = 4
    /// Per-question choice categories kept registered (oldest dropped first).
    static let maxChoiceCategories = 24

    private weak var store: AppStore?
    private var started = false
    private var recent: [String: Date] = [:]
    private let center: NotificationCentering
    /// Settings ▸ General ▸ Notifications live here.
    var defaults: UserDefaults = .standard
    /// Tests drive a mock-scenario store through the notifier; the real app never notifies for one.
    var allowsMockStore = false
    /// Choice categories by cluster, in registration order.
    private var choiceCategories: [(id: String, category: UNNotificationCategory)] = []

    init(center: NotificationCentering = SystemNotificationCenter()) {
        self.center = center
        super.init()
    }

    /// Call once at launch. No-op outside a real app bundle (tests, `swift run`).
    func start(store: AppStore) {
        self.store = store
        guard !started, Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        activate()
    }

    /// Start without the bundle check (tests with a fake centre).
    func startForTesting(store: AppStore) {
        self.store = store
        activate()
    }

    private func activate() {
        started = true
        center.setDelegate(self)
        center.requestAuthorization()
        registerCategories()
    }

    /// Map a daemon event to a notification. Quiet by design: only things that need the user.
    func handle(_ event: DaemonEvent, store: AppStore) {
        guard started, allowsMockStore || store.mockScenarioName == nil else { return }
        switch event {
        case .questionOpened(let p):
            guard isOn("NEEDS_YOU") else { return }
            postQuestion(p.cluster)
        case .applicationState(let p):
            if p.toState == .awaitingReview, isOn("REVIEW_READY") {
                post(id: "review-\(p.applicationId)", title: "Ready for review", body: jobLabel(p.jobId, store) ?? "A filled application is waiting for you.",
                     route: ["route": "review", "application": String(p.applicationId), "job": String(p.jobId)],
                     category: Self.reviewCategory)
            } else if p.toState == .submitted, isOn("SUBMITTED") {
                post(id: "sub-\(p.applicationId)", title: "Applied", body: jobLabel(p.jobId, store) ?? "Application submitted.",
                     route: ["route": "job", "job": String(p.jobId)])
            } else if p.toState == .failed, isOn("ERROR") {
                post(id: "fail-\(p.applicationId)", title: "Application failed", body: [jobLabel(p.jobId, store), p.reason].compactMap { $0 }.joined(separator: " · "),
                     route: ["route": "job", "job": String(p.jobId)])
            }
        case .outreachReply(let p):
            // Off by default (Settings ▸ General ▸ Notifications). Auto-replies, bounces and a
            // polite no never notify.
            guard isOn("REPLIES"), !Self.isQuiet(p) else { return }
            post(id: "reply-\(p.threadId)", title: "\(p.contactName) at \(p.company) replied", body: p.snippet,
                 route: ["route": "replies"])
        case .applicationReply(let p):
            guard isOn("REPLIES"), !Self.isRejection(p), let move = p.suggestedStatus, !p.ambiguous else { return }
            post(id: "areply-\(p.replyId)", title: "\(p.company) replied", body: "\(p.subject) · suggests \(move.label)",
                 route: ["route": "replies"])
        default:
            break
        }
    }

    /// A kind no: an employer reply that is, or suggests, a rejection.
    nonisolated static func isRejection(_ p: ApplicationReplyPayload) -> Bool {
        p.label == .rejection || p.suggestedStatus == .rejected
    }

    /// Cold-email replies that never notify.
    nonisolated static func isQuiet(_ p: OutreachReplyPayload) -> Bool {
        [.ooo, .bounce, .notInterested].contains(p.label) || p.suggestedStatus == .rejected
    }

    /// Update available / ready (from Updater); clicking restarts into it or opens the prompt.
    func postUpdate(title: String, body: String) {
        guard started else { return }
        post(id: "update-\(title)", title: title, body: body, route: ["route": "update"])
    }

    private func isOn(_ key: String) -> Bool { GeneralSettings.isNotificationOn(key, defaults: defaults) }

    private func jobLabel(_ jobID: Int, _ store: AppStore) -> String? {
        store.jobs.job(id: jobID).map { "\($0.company) · \($0.title)" }
    }

    // MARK: Questions

    /// How a question can be answered from the notification.
    enum InlineAnswer: Equatable, Sendable {
        /// Not inline: the notification opens Needs You.
        case none
        /// A text field in the notification.
        case text
        /// One button per option (yes/no, or a single choice of at most four).
        case options([String])
    }

    /// Keep it to simple questions: short text, yes/no, and single choices of ≤4 options. Essays,
    /// numbers, dates, links, multi-selects, tasks, CAPTCHAs and facts only you set open the app.
    static func inlineAnswer(for cluster: QuestionCluster) -> InlineAnswer {
        guard !cluster.isAction, cluster.reason != .neverGuess, cluster.neverGuessKey == nil else { return .none }
        switch AnswerKind(cluster: cluster) {
        case .shortText: return .text
        case .yesNo: return .options(["Yes", "No"])
        case .choice(let multi):
            guard !multi, (1...maxInlineOptions).contains(cluster.options.count) else { return .none }
            return .options(cluster.options)
        default: return .none
        }
    }

    private func postQuestion(_ c: QuestionCluster) {
        let title = c.canonicalQuestion.hasPrefix("Security code") ? "Security code needed" : "Needs your input"
        let where_ = c.companies.prefix(2).joined(separator: ", ")
        var route = ["route": "inbox", "cluster": c.clusterId]
        var category: String?
        switch Self.inlineAnswer(for: c) {
        case .none:
            break
        case .text:
            category = Self.textCategory
        case .options(let options):
            category = registerChoiceCategory(clusterID: c.clusterId, options: options)
            for (i, option) in options.enumerated() { route["opt\(i)"] = option }
        }
        post(id: "q-\(c.clusterId)", title: title, body: where_.isEmpty ? c.canonicalQuestion : "\(where_): \(c.canonicalQuestion)",
             route: route, category: category)
    }

    // MARK: Categories

    private var staticCategories: [UNNotificationCategory] {
        let answer = UNTextInputNotificationAction(identifier: Self.answerAction, title: "Answer", options: [],
                                                   textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "Approve", options: [])
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open", options: [.foreground])
        return [
            UNNotificationCategory(identifier: Self.textCategory, actions: [answer], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.reviewCategory, actions: [approve, open], intentIdentifiers: []),
        ]
    }

    private func registerCategories() {
        center.setCategories(Set(staticCategories + choiceCategories.map(\.category)))
    }

    /// One category per choice question (its options are its buttons). Returns its identifier.
    private func registerChoiceCategory(clusterID: String, options: [String]) -> String {
        let id = Self.choiceCategoryPrefix + clusterID
        let actions = options.prefix(Self.maxInlineOptions).enumerated().map { i, option in
            UNNotificationAction(identifier: Self.optionActionPrefix + String(i), title: option, options: [])
        }
        choiceCategories.removeAll { $0.id == id }
        choiceCategories.append((id, UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])))
        if choiceCategories.count > Self.maxChoiceCategories { choiceCategories.removeFirst(choiceCategories.count - Self.maxChoiceCategories) }
        registerCategories()
        return id
    }

    // MARK: Posting

    private func post(id: String, title: String, body: String, route: [String: String], category: String? = nil) {
        if let last = recent[id], Date().timeIntervalSince(last) < 60 { return }
        recent[id] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = route
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        completionHandler()
        Task { @MainActor in await self.respond(action: action, text: text, info: info) }
    }

    /// Handle a click or an action button. Returns once any command it sends has finished.
    func respond(action: String, text: String?, info: [String: String]) async {
        guard let store else { return }
        switch action {
        case Self.answerAction:
            guard let cluster = info["cluster"], let reply = text?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
                open(info)
                return
            }
            await answer(cluster: cluster, with: reply, store: store, info: info)
        case let a where a.hasPrefix(Self.optionActionPrefix):
            let index = a.dropFirst(Self.optionActionPrefix.count)
            guard let cluster = info["cluster"], let option = info["opt\(index)"] else {
                open(info)
                return
            }
            await answer(cluster: cluster, with: option, store: store, info: info)
        case Self.approveAction:
            await approveFromNotification(info: info, store: store)
        default:
            // Open, a click on the notification, or anything unknown: bring the app forward.
            open(info)
        }
    }

    private func answer(cluster: String, with answer: String, store: AppStore, info: [String: String]) async {
        // The question may already be answered in the app; don't send a stale answer.
        guard store.inbox.clusters.contains(where: { $0.clusterId == cluster }) else { return }
        let ok = await store.answerQuestion(clusterID: cluster, answer: answer)
        if !ok {
            post(id: "q-fail-\(cluster)", title: "Your answer didn't go through", body: "Open Needs You to answer it again.", route: info)
        }
    }

    /// Approve through the same path Review uses: the send hold (`SendHoldModel`), which sends
    /// the `approve` command only after its Undo window closes. A job with an answer that needs a
    /// look, or one no longer waiting (or already on hold), opens in Review instead.
    private func approveFromNotification(info: [String: String], store: AppStore) async {
        guard let appID = info["application"].flatMap(Int.init), let job = store.jobs.job(applicationID: appID),
              job.state == .awaitingReview else {
            open(info)
            return
        }
        guard await isClean(applicationID: appID, store: store) else {
            post(id: "review-look-\(appID)", title: "Have a look first", body: "\(job.company) · \(job.title) has an answer worth checking.",
                 route: info)
            open(info)
            return
        }
        let label = "\(job.company) · \(job.title)"
        let hold = SendHoldModel.shared(for: store)
        let held = hold.hold(jobIDs: [job.id]) { [weak self] sent in
            // The hold's own toast and send sound cover success; only a failure needs a notification.
            guard !sent else { return }
            self?.post(id: "review-fail-\(appID)", title: "Not approved yet", body: "\(label) is still in Review.", route: info)
        }
        guard !held.isEmpty else { open(info); return }
        // In the app the hold reads like Review's: a draining Undo toast for the same window.
        let jobID = job.id
        store.toasts.show("Approved · sending in \(Int(SendHoldTiming.seconds(hold.window).rounded())) s", symbol: "paperplane",
                          duration: hold.window, actionTitle: "Undo", countdown: true) { hold.undo(jobID: jobID) }
    }

    /// The application's Q&A has loaded and no answer is medium or low confidence.
    private func isClean(applicationID: Int, store: AppStore) async -> Bool {
        let stream = store.repository.applicationAnswers(applicationID: applicationID)
        let reader = Task { @MainActor () -> [ApplicationAnswerItem]? in
            for await list in stream { return list }
            return nil
        }
        // A repository that never answers counts as "not loaded": open Review instead.
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            reader.cancel()
        }
        let answers = await reader.value
        timer.cancel()
        guard let answers else { return false }
        return ReviewSafeguard.flagRank(answers) == 0
    }

    /// Bring the main window forward on the item the notification was about.
    func open(_ info: [String: String]) {
        guard let store else { return }
        NSApp?.activate()
        store.router.requestMainWindow()
        switch info["route"] {
        case "inbox":
            store.router.go(.needsYou)
            if let cluster = info["cluster"] { InboxModel.shared(for: store).select(cluster) }
        case "review":
            store.router.go(.review)
            if let job = info["job"].flatMap(Int.init) { ReviewModel.shared(for: store).focusedJobID = job }
        case "replies":
            store.router.go(.needsYou)
            InboxModel.shared(for: store).ensureSelection()
        case "update":
            Updater.shared.restartPrompt()
        case "job":
            if let id = info["job"].flatMap(Int.init) { store.router.openJob(id: id) }
        default:
            break
        }
    }
}
