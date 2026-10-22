// NotificationActionsTests.swift — notifications you can act on (1H) and a kind no (1F), driven
// through a fake notification centre: no rejection ever notifies, an inline answer sends
// `answer_question` for the cluster, choice questions offer ≤4 options as buttons, and Approve
// from "Ready for review" goes through the store's approve path (with the flagged-answer guard).
import Foundation
import Testing
import UserNotifications
@testable import AutoApply

@MainActor
final class FakeNotificationCenter: NotificationCentering {
    var posted: [UNNotificationRequest] = []
    var categories: Set<UNNotificationCategory> = []
    var authorized = false

    func requestAuthorization() { authorized = true }
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {}
    func setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
    func add(_ request: UNNotificationRequest) { posted.append(request) }

    var titles: [String] { posted.map(\.content.title) }
    func category(_ id: String) -> UNNotificationCategory? { categories.first { $0.identifier == id } }
}

@MainActor
@Suite("1F/1H · Actionable notifications and a kind no", .serialized)
struct NotificationActionsTests {
    private func notifier(_ store: AppStore, replies: Bool = true) -> (AppNotifier, FakeNotificationCenter) {
        let center = FakeNotificationCenter()
        let n = AppNotifier(center: center)
        let defaults = UserDefaults(suiteName: "aa.notifier.tests.\(UUID().uuidString)")!
        defaults.set(replies, forKey: GeneralSettings.notifyPrefix + "REPLIES")
        n.defaults = defaults
        n.allowsMockStore = true
        n.startForTesting(store: store)
        return (n, center)
    }

    private func reply(_ label: ApplicationReplyLabel, suggests: BoardStatus?, id: Int = 1) -> ApplicationReplyPayload {
        ApplicationReplyPayload(replyId: id, applicationId: 1, jobId: 1, company: "Acme", label: label, suggestedStatus: suggests,
                                fromEmail: "people@acme.com", subject: "Your application", receivedAt: C3Fixtures.now, messageId: "<m\(id)@acme>")
    }

    // MARK: A kind no

    @Test func rejectionsNeverNotify() async {
        let (store, _, _) = await makeC3Store()
        let (n, center) = notifier(store)
        #expect(center.authorized)
        n.handle(.applicationReply(reply(.rejection, suggests: .rejected, id: 1)), store: store)
        n.handle(.applicationReply(reply(.other, suggests: .rejected, id: 2)), store: store)
        n.handle(.outreachReply(OutreachReplyPayload(threadId: 3, contactName: "Priya Shah", company: "Acme", label: .notInterested)), store: store)
        n.handle(.outreachReply(OutreachReplyPayload(threadId: 4, contactName: "Priya Shah", company: "Acme", label: .other,
                                                     suggestedStatus: .rejected)), store: store)
        #expect(center.posted.isEmpty, "\(center.titles)")
        // Good news still gets through when replies are on.
        n.handle(.applicationReply(reply(.interviewInvite, suggests: .interview, id: 5)), store: store)
        #expect(center.titles == ["Acme replied"])
        #expect(AppNotifier.isRejection(reply(.rejection, suggests: nil)))
        await store.stop()
    }

    // MARK: Questions

    @Test func shortTextQuestionTakesAnInlineAnswer() async {
        let cluster = C3Fixtures.cluster("c-city", jobs: [1, 2], question: "Which city are you based in?")
        let (store, daemon, _) = await makeC3Store(clusters: [cluster])
        let (n, center) = notifier(store)
        n.handle(.questionOpened(QuestionOpenedPayload(cluster: cluster)), store: store)
        let request = try! #require(center.posted.first)
        #expect(request.content.categoryIdentifier == AppNotifier.textCategory)
        let actions = center.category(AppNotifier.textCategory)?.actions ?? []
        #expect(actions.first is UNTextInputNotificationAction)
        #expect(actions.first?.identifier == AppNotifier.answerAction)

        let info = request.content.userInfo as! [String: String]
        await n.respond(action: AppNotifier.answerAction, text: "  Bengaluru \n", info: info)
        let sent = daemon.sent("answer_question").compactMap(\.answerPayload)
        #expect(sent.count == 1)
        #expect(sent.first?.clusterId == "c-city")
        #expect(sent.first?.answer == "Bengaluru")
        #expect(!store.inbox.clusters.contains { $0.clusterId == "c-city" }, "answered clusters leave Needs You")
        await store.stop()
    }

    @Test func emptyInlineAnswerSendsNothing() async {
        let cluster = C3Fixtures.cluster("c1", jobs: [1], question: "Which city are you based in?")
        let (store, daemon, _) = await makeC3Store(clusters: [cluster])
        let (n, _) = notifier(store)
        await n.respond(action: AppNotifier.answerAction, text: "   ", info: ["route": "inbox", "cluster": "c1"])
        #expect(daemon.sent("answer_question").isEmpty)
        await store.stop()
    }

    @Test func choiceQuestionsOfferUpToFourOptions() async {
        let small = C3Fixtures.cluster("c-auth", jobs: [1], question: "Work authorization?", fieldType: .select,
                                       options: ["Citizen", "Visa", "Need sponsorship"])
        let big = C3Fixtures.cluster("c-big", jobs: [1], question: "Pick a team", fieldType: .select, options: ["A", "B", "C", "D", "E"])
        let yesNo = C3Fixtures.cluster("c-yn", jobs: [1], question: "Are you over 18?", fieldType: .boolean)
        let essay = C3Fixtures.cluster("c-why", jobs: [1], question: "Why do you want to work here?")
        let fact = C3Fixtures.cluster("c-fact", jobs: [1], question: "Notice period", neverGuessKey: "notice_period")
        #expect(AppNotifier.inlineAnswer(for: small) == .options(["Citizen", "Visa", "Need sponsorship"]))
        #expect(AppNotifier.inlineAnswer(for: big) == .none, "more than four options open the app")
        #expect(AppNotifier.inlineAnswer(for: yesNo) == .options(["Yes", "No"]))
        #expect(AppNotifier.inlineAnswer(for: essay) == .none, "essays are not answered from a banner")
        #expect(AppNotifier.inlineAnswer(for: fact) == .none, "facts only you set open the app")

        let (store, daemon, _) = await makeC3Store(clusters: [small, big])
        let (n, center) = notifier(store)
        n.handle(.questionOpened(QuestionOpenedPayload(cluster: small)), store: store)
        n.handle(.questionOpened(QuestionOpenedPayload(cluster: big)), store: store)
        #expect(center.posted.count == 2)
        let request = center.posted[0]
        let category = try! #require(center.category(request.content.categoryIdentifier))
        #expect(category.actions.map(\.title) == ["Citizen", "Visa", "Need sponsorship"])
        #expect(center.posted[1].content.categoryIdentifier.isEmpty)

        let info = request.content.userInfo as! [String: String]
        await n.respond(action: category.actions[1].identifier, text: nil, info: info)
        #expect(daemon.sent("answer_question").compactMap(\.answerPayload).map(\.answer) == ["Visa"])
        await store.stop()
    }

    @Test func questionsRespectTheirSetting() async {
        let cluster = C3Fixtures.cluster("c1", jobs: [1], question: "Which city are you based in?")
        let (store, _, _) = await makeC3Store(clusters: [cluster])
        let (n, center) = notifier(store)
        n.defaults.set(false, forKey: GeneralSettings.notifyPrefix + "NEEDS_YOU")
        n.handle(.questionOpened(QuestionOpenedPayload(cluster: cluster)), store: store)
        #expect(center.posted.isEmpty)
        await store.stop()
    }

    // MARK: Ready for review

    private func reviewEvent(_ id: Int) -> DaemonEvent {
        .applicationState(ApplicationStatePayload(applicationId: id, jobId: id, fromState: .filling, toState: .awaitingReview, at: C3Fixtures.now))
    }

    @Test func approveFromNotificationGoesThroughTheStore() async {
        let job = C3Fixtures.job(id: 7, company: "Ramp", state: .awaitingReview)
        let data = RepositoryData(jobs: [job], applicationAnswers: [7: [C3Fixtures.answer(id: 1, app: 7, question: "Name", confidence: 0.99)]])
        let (store, daemon, _) = await makeC3Store(data: data)
        let (n, center) = notifier(store)
        n.handle(reviewEvent(7), store: store)
        let request = try! #require(center.posted.first)
        #expect(request.content.categoryIdentifier == AppNotifier.reviewCategory)
        #expect(center.category(AppNotifier.reviewCategory)?.actions.map(\.title) == ["Approve", "Open"])

        let hold = SendHoldModel.shared(for: store)
        hold.window = .milliseconds(40)
        await n.respond(action: AppNotifier.approveAction, text: nil, info: request.content.userInfo as! [String: String])
        // The same send hold as Review: held first, nothing sent inside the window.
        #expect(hold.isHeld(7))
        #expect(daemon.sent("approve").isEmpty)
        #expect(store.toasts.current?.actionTitle == "Undo")
        _ = await c3WaitUntil { !daemon.sent("approve").isEmpty }
        let approvals = daemon.sent("approve")
        #expect(approvals.count == 1)
        if case .approve(let p)? = approvals.first { #expect(p.applicationIds == [7]) }
        // The store's path ran: its optimistic state, not a bare command.
        #expect(store.jobs.job(id: 7)?.state == .submitting)
        await store.stop()
    }

    @Test func approveFromNotificationCanBeUndoneInsideTheHold() async {
        let job = C3Fixtures.job(id: 9, company: "Linear", state: .awaitingReview)
        let data = RepositoryData(jobs: [job], applicationAnswers: [9: [C3Fixtures.answer(id: 1, app: 9, question: "Name", confidence: 0.99)]])
        let (store, daemon, _) = await makeC3Store(data: data)
        let (n, _) = notifier(store)
        let hold = SendHoldModel.shared(for: store)
        hold.window = .milliseconds(150)
        await n.respond(action: AppNotifier.approveAction, text: nil, info: ["route": "review", "application": "9", "job": "9"])
        #expect(hold.isHeld(9))
        store.toasts.performAction()  // the toast's Undo
        #expect(!hold.isHeld(9))
        try? await Task.sleep(for: .milliseconds(250))
        #expect(daemon.sent("approve").isEmpty)
        #expect(store.jobs.job(id: 9)?.state == .awaitingReview)
        await store.stop()
    }

    @Test func approveWithAnAnswerToCheckOpensReviewInstead() async {
        let job = C3Fixtures.job(id: 8, state: .awaitingReview)
        let data = RepositoryData(jobs: [job], applicationAnswers: [8: [C3Fixtures.answer(id: 1, app: 8, question: "Salary", confidence: 0.4)]])
        let (store, daemon, _) = await makeC3Store(data: data)
        let (n, center) = notifier(store)
        await n.respond(action: AppNotifier.approveAction, text: nil, info: ["route": "review", "application": "8", "job": "8"])
        #expect(daemon.sent("approve").isEmpty)
        #expect(center.titles == ["Have a look first"])
        #expect(store.router.selection == .review)
        await store.stop()
    }
}
