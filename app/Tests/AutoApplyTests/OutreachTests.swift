// OutreachTests.swift — cold outreach and employer replies in the store and the Cold Email /
// Needs You models: the approve flow (scheduled, every conflict kind, Send anyway, Leave out),
// cancel, accept / dismiss an employer reply suggestion, the referral copilot's copy-and-open
// through the clipboard seam, Enable sending, the event reducer, counts and badges, and the
// mock daemon's outreach semantics end to end.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("Outreach", .serialized)
struct OutreachTests {

    // MARK: Fixtures

    static let now = Samples.now

    static func data(sendEnabled: Bool = true, mailbox: String? = "asha@gmail.com") -> RepositoryData {
        var d = RepositoryData()
        var applied = Samples.job(id: 1, state: .submitted, status: .applied, submittedAt: now.addingTimeInterval(-86_400 * 3))
        applied.companyID = 7
        applied.company = "Acme"
        d.jobs = [applied, Samples.job(id: 2, state: .submitted, status: .applied, submittedAt: now)]
        var o = OutreachData()
        o.mailAccount = MailAccountInfo(email: mailbox, sendEnabled: sendEnabled)
        o.contacts = [
            ContactItem(id: 1, companyID: 7, company: "Acme", fullName: "Jane Rao", title: "Recruiter", roleCategory: .recruiter,
                        email: "jane@acme.com", emailStatus: "published", emailConfidence: 94, origin: .scout, createdAt: now),
            ContactItem(id: 2, companyID: 7, company: "Acme", fullName: "Sam Lee", title: "Engineering Manager", roleCategory: .hiringManager,
                        email: "sam@acme.com", emailStatus: "pattern", emailConfidence: 45, origin: .scout, createdAt: now),
        ]
        o.threads = [
            OutreachThreadItem(id: 10, kind: .application, contactID: 1, companyID: 7, company: "Acme", jobID: 1, applicationID: 1,
                               state: .draft, subject: "Backend Engineer application", createdAt: now, updatedAt: now),
            OutreachThreadItem(id: 11, kind: .application, contactID: 2, companyID: 7, company: "Acme", jobID: 2, applicationID: 2,
                               state: .draft, subject: "Hello", createdAt: now, updatedAt: now),
            OutreachThreadItem(id: 12, kind: .application, contactID: 1, companyID: 7, company: "Acme", jobID: 1, applicationID: 1,
                               state: .replied, unreadReply: true, createdAt: now, updatedAt: now),
        ]
        o.messages = [
            OutreachMessageItem(id: 100, threadID: 10, state: .draft, toEmail: "jane@acme.com", subject: "Backend Engineer application",
                                body: "Hi Jane, I applied this week.", footer: "—\nI found your address on acme.com/team.", createdAt: now, updatedAt: now),
            OutreachMessageItem(id: 101, threadID: 11, state: .draft, toEmail: "sam@acme.com", subject: "Hello",
                                body: "Hi Sam, I cut p99 latency by 60%.", grounded: false, unsupportedClaims: ["cut p99 latency by 60%"],
                                createdAt: now, updatedAt: now),
            OutreachMessageItem(id: 102, threadID: 12, state: .sent, toEmail: "jane@acme.com", body: "Earlier email", messageIDHeader: "<a1@mail>",
                                sentAt: now, createdAt: now, updatedAt: now),
            OutreachMessageItem(id: 103, threadID: 12, seq: 1, isInbound: true, state: .received, body: "Thanks! Passing this on.",
                                messageIDHeader: "<r1@acme.com>", classification: "positive", createdAt: now, updatedAt: now),
            OutreachMessageItem(id: 104, threadID: 10, seq: 1, state: .unknown, toEmail: "jane@acme.com", body: "Maybe sent",
                                messageIDHeader: "<u1@mail>", createdAt: now, updatedAt: now),
        ]
        o.referrals = [
            ReferralItem(id: 5, companyID: 7, company: "Acme", personName: "Karthik Raman", title: "Engineer",
                         linkedinURL: "https://www.linkedin.com/in/karthik", basis: .alumni, basisDetail: "IIT Madras", state: .toConnect,
                         connectNote: "Hi Karthik, fellow IIT Madras alum here.", referralDM: nil, stateUpdatedAt: now, createdAt: now),
            ReferralItem(id: 6, companyID: 7, company: "Acme", personName: "No Link", basis: .user, state: .connected,
                         referralDM: "Would you refer me?", stateUpdatedAt: now, createdAt: now),
        ]
        d.outreach = o
        d.applicationReplies = [
            ApplicationReplyItem(id: 1, applicationID: 1, messageID: "<e1@acme.com>", fromEmail: "talent@acme.com", fromName: "Acme Talent",
                                 subject: "Next steps", snippet: "We'd like to set up a call.", receivedAt: now, label: .interviewInvite,
                                 suggestedStatus: .interview, suggestionState: .pending),
            ApplicationReplyItem(id: 2, applicationID: 2, messageID: "<e2@acme.com>", fromEmail: "no-reply@acme.com", subject: "Received",
                                 snippet: "Thanks for applying", receivedAt: now, label: .receivedAck),
        ]
        return d
    }

    final class Box: @unchecked Sendable { var value: DaemonEvent? }

    func makeStore(_ data: RepositoryData = Self.data(), responder: @escaping @Sendable (Command) -> DaemonEvent? = { _ in .ack(AckPayload()) })
        async -> (AppStore, StubDaemon, InMemoryRepository) {
        let daemon = StubDaemon()
        daemon.responder = responder
        let repo = InMemoryRepository(data)
        let store = AppStore(client: daemon, repository: repo)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.outreach.isLoaded && store.outreach.repliesLoaded }
        return (store, daemon, repo)
    }

    private func approvals(_ daemon: StubDaemon) -> [ApproveOutreachPayload] {
        daemon.sent.compactMap { if case .approveOutreach(let p) = $0 { p } else { nil } }
    }

    // MARK: Store lookups and counts

    @Test func storeIndexesAndCounts() async {
        let (store, _, _) = await makeStore()
        let o = store.outreach
        #expect(o.drafts.map(\.id).sorted() == [100, 101])
        #expect(o.unknownSends.map(\.id) == [104])
        #expect(o.unreadReplyThreads.map(\.id) == [12])
        #expect(o.pendingSuggestions.map(\.id) == [1], "a plain acknowledgement isn't a suggestion")
        #expect(o.bestContact(companyID: 7)?.id == 1, "highest confidence first")
        #expect(o.latestReply(threadID: 12)?.id == 103)
        #expect(o.followUpStatus(for: store.jobs.job(id: 2)!) == .draft)
        #expect(store.coldEmailBadge == 3, "2 drafts + 1 unread reply")
        #expect(store.repliesNeedingYou == 3, "unread reply + pending suggestion + possibly sent")
        #expect(store.needsYouCount == store.inbox.openCount + 3)
        #expect(store.counts.outreachDrafts == 2 && store.counts.applicationRepliesUnread == 1)
        await store.stop()
    }

    @Test func emailTiersAndGmailLinks() {
        #expect(EmailTier(confidence: 95) == .verified)
        #expect(EmailTier(confidence: 70) == .likely)
        #expect(EmailTier(confidence: 40) == .guess)
        #expect(EmailTier(confidence: 39) == .unknown)
        #expect(GmailLink.url(messageID: "<abc.1+x@mail.gmail.com>")?.absoluteString
                == "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Aabc.1%2Bx%40mail.gmail.com")
        #expect(GmailLink.url(messageID: "<>") == nil)
    }

    @Test func claimHighlightingAndRemaining() {
        let body = "I cut p99 latency by 60% and CUT P99 LATENCY BY 60% again."
        let text = ClaimHighlighter.attributed(body, claims: ["cut p99 latency by 60%"])
        let highlighted = text.runs.filter { $0.backgroundColor != nil }.count
        #expect(highlighted == 2)
        #expect(ClaimHighlighter.remaining("I improved latency.", claims: ["cut p99 latency by 60%"]).isEmpty)
    }

    // MARK: Approve

    @Test func approveSchedulesAndClosesTheSheet() async {
        let (store, daemon, _) = await makeStore(responder: { cmd in
            guard case .approveOutreach(let p) = cmd else { return .ack(AckPayload()) }
            return .ack(AckPayload(ok: true, result: [
                "batch_uid": .string("b1"),
                "scheduled": .array(p.messageIds.map { .object(["message_id": .int($0), "send_at": .string("2026-10-10T10:00:00.000Z")]) }),
                "days": .array([.object(["date": .string("2026-10-10"), "count": .int(p.messageIds.count)])]),
            ]))
        })
        let model = ColdEmailModel(store: store)
        #expect(!model.canSend, "nothing selected yet")
        model.toggle(100)
        #expect(model.canSend && model.sendBlocker == nil)
        model.beginSend()
        #expect(model.isSendSheetPresented)
        #expect(approvals(daemon).isEmpty, "opening the sheet sends nothing")
        model.includeFollowups = true
        await model.approveSelected()
        #expect(approvals(daemon) == [ApproveOutreachPayload(messageIds: [100], includeFollowups: true, sendAnyway: [])])
        #expect(!model.isSendSheetPresented && model.selection.isEmpty)
        #expect(store.outreach.message(id: 100)?.state == .scheduled)
        #expect(store.outreach.message(id: 100)?.sendAt == ProtocolCoding.date("2026-10-10T10:00:00Z"))
        #expect(store.toasts.current?.message.hasPrefix("Scheduled") == true)
        await store.stop()
    }

    @Test func approveConflictsKeepTheSheetOpenWithEachProblem() async {
        let (store, daemon, _) = await makeStore(responder: { cmd in
            guard case .approveOutreach(let p) = cmd else { return .ack(AckPayload()) }
            if p.sendAnyway.contains(101) {
                return .ack(AckPayload(ok: true, result: ["batch_uid": .string("b2"), "scheduled": .array([]), "days": .array([])]))
            }
            return .error(ErrorPayload(code: .conflict, message: "some addresses are below your confidence bar",
                                       details: ["low_confidence": .array([.int(101)]), "ungrounded": .array([.int(100)]),
                                                 "do_not_contact": .array([]), "thread_closed": .array([])]))
        })
        let model = ColdEmailModel(store: store)
        model.selectAllDrafts()
        model.beginSend()
        await model.approveSelected()
        guard case .conflicts(let c, let message) = model.approveState else {
            Issue.record("expected conflicts, got \(model.approveState)")
            return
        }
        #expect(c.lowConfidence == [101] && c.ungrounded == [100] && c.doNotContact.isEmpty)
        #expect(message.contains("confidence"))
        #expect(model.isSendSheetPresented, "nothing scheduled: the sheet stays open")
        #expect(store.outreach.message(id: 100)?.state == .draft)

        model.leaveOut([100])
        #expect(model.selection == [101])
        if case .conflicts(let left, _) = model.approveState { #expect(left.ungrounded.isEmpty && left.lowConfidence == [101]) }

        await model.sendAnywayAndRetry([101])
        #expect(approvals(daemon).last?.sendAnyway == [101])
        #expect(approvals(daemon).last?.messageIds == [101])
        #expect(!model.isSendSheetPresented)
        await store.stop()
    }

    @Test func conflictDetailsParseEveryKind() {
        let c = OutreachConflicts(details: ["ungrounded": .array([.int(1)]), "low_confidence": .array([.int(2)]),
                                           "do_not_contact": .array([.int(3)]), "thread_closed": .array([.int(4)])])
        #expect(c.ungrounded == [1] && c.lowConfidence == [2] && c.doNotContact == [3] && c.threadClosed == [4])
        #expect(c.all == [1, 2, 3, 4] && !c.onlyLowConfidence)
        #expect(OutreachConflicts(details: ["low_confidence": .array([.int(9)])]).onlyLowConfidence)
        #expect(OutreachConflicts(details: nil).isEmpty)
    }

    @Test func sendingOffBlocksTheSendButtonAndSendsNothing() async {
        let (store, daemon, _) = await makeStore(Self.data(sendEnabled: false))
        let model = ColdEmailModel(store: store)
        model.selectAllDrafts()
        #expect(!model.canSend)
        #expect(model.sendBlocker == "Turn on sending first")
        model.beginSend()
        #expect(!model.isSendSheetPresented)
        #expect(approvals(daemon).isEmpty)
        let noMailbox = await makeStore(Self.data(sendEnabled: false, mailbox: nil))
        #expect(ColdEmailModel(store: noMailbox.0).sendBlocker == "Connect a mailbox first")
        await store.stop()
        await noMailbox.0.stop()
    }

    @Test func approveFailureIsShownNotScheduled() async {
        let (store, _, _) = await makeStore(responder: { cmd in
            if case .approveOutreach = cmd { return .error(ErrorPayload(code: .unavailable, message: "sending is off")) }
            return .ack(AckPayload())
        })
        let model = ColdEmailModel(store: store)
        model.toggle(100)
        model.beginSend()
        await model.approveSelected()
        #expect(model.approveState == .failed("Sending is off"))
        #expect(model.isSendSheetPresented)
        await store.stop()
    }

    // MARK: Cancel / unknown

    @Test func cancelMovesBackToDraftAndRollsBackOnError() async {
        var d = Self.data()
        d.outreach.messages[0].state = .scheduled
        d.outreach.messages[0].sendAt = Self.now
        let (store, daemon, _) = await makeStore(d)
        #expect(await store.cancelOutreach(messageIDs: [100]))
        #expect(daemon.sent.contains(.cancelOutreach(CancelOutreachPayload(messageIds: [100]))))
        #expect(store.outreach.message(id: 100)?.state == .draft)

        let failing = await makeStore(d, responder: { _ in .error(ErrorPayload(code: .illegalTransition, message: "not scheduled")) })
        #expect(await failing.0.cancelOutreach(messageIDs: [100]) == false)
        #expect(failing.0.outreach.message(id: 100)?.state == .scheduled, "rolled back")
        await store.stop()
        await failing.0.stop()
    }

    @Test func resolveUnknownSendsTheAnswer() async {
        let (store, daemon, _) = await makeStore()
        #expect(await store.resolveOutreachUnknown(messageID: 104, sent: false))
        #expect(daemon.sent.contains(.resolveOutreachUnknown(ResolveOutreachUnknownPayload(messageId: 104, sent: false))))
        #expect(store.outreach.message(id: 104)?.state == .failed)
        #expect(store.outreach.unknownSends.isEmpty)
        await store.stop()
    }

    // MARK: Employer reply suggestions

    @Test func acceptReplySuggestionMovesTheJob() async {
        let (store, daemon, _) = await makeStore()
        let reply = store.outreach.pendingSuggestions[0]
        #expect(await store.acceptReplySuggestion(reply))
        #expect(daemon.sent.contains(.acceptReplySuggestion(AcceptReplySuggestionPayload(replyId: 1))))
        #expect(store.jobs.job(applicationID: 1)?.status == .interview)
        #expect(store.outreach.pendingSuggestions.isEmpty)
        #expect(store.toasts.current?.message == "Moved to Interview")
        await store.stop()
    }

    @Test func acceptConflictRollsBack() async {
        let (store, _, _) = await makeStore(responder: { _ in .error(ErrorPayload(code: .conflict, message: "no pending suggestion")) })
        let reply = store.outreach.pendingSuggestions[0]
        #expect(await store.acceptReplySuggestion(reply) == false)
        #expect(store.jobs.job(applicationID: 1)?.status == .applied)
        #expect(store.outreach.pendingSuggestions.map(\.id) == [1])
        await store.stop()
    }

    @Test func dismissReplySuggestionKeepsTheBoard() async {
        let (store, daemon, _) = await makeStore()
        #expect(await store.dismissReplySuggestion(store.outreach.pendingSuggestions[0]))
        #expect(daemon.sent.contains(.dismissReplySuggestion(DismissReplySuggestionPayload(replyId: 1))))
        #expect(store.jobs.job(applicationID: 1)?.status == .applied)
        #expect(store.outreach.pendingSuggestions.isEmpty)
        await store.stop()
    }

    // MARK: Referral copilot

    @Test func copyNoteAndOpenUsesClipboardAndTheUsersBrowser() async {
        let (store, daemon, _) = await makeStore()
        let model = ColdEmailModel(store: store)
        let clipboard = RecordingClipboard()
        var opened: [URL] = []
        model.clipboard = clipboard
        model.openURL = { opened.append($0) }
        let referral = store.outreach.referral(id: 5)!
        #expect(model.copyNoteAndOpenProfile(referral))
        #expect(clipboard.last == "Hi Karthik, fellow IIT Madras alum here.")
        #expect(opened == [URL(string: "https://www.linkedin.com/in/karthik")!])
        #expect(model.sentCheck == .init(referralID: 5, kind: .note))
        #expect(daemon.sent.filter { $0.type == "update_referral" }.isEmpty, "nothing changes until the user says they sent it")

        await model.confirmSent(true)
        #expect(daemon.sent.contains(.updateReferral(UpdateReferralPayload(id: 5, state: .requested))))
        #expect(store.outreach.referral(id: 5)?.state == .requested)
        #expect(model.sentCheck == nil)
        await store.stop()
    }

    @Test func copyMessageWithoutAProfileLinkOpensNothing() async {
        let (store, daemon, _) = await makeStore()
        let model = ColdEmailModel(store: store)
        let clipboard = RecordingClipboard()
        var opened: [URL] = []
        model.clipboard = clipboard
        model.openURL = { opened.append($0) }
        #expect(model.copyMessageAndOpen(store.outreach.referral(id: 6)!) == false)
        #expect(opened.isEmpty && clipboard.writes.isEmpty && model.sentCheck == nil)
        #expect(ColdEmailModel.profileURL("javascript:alert(1)") == nil)
        #expect(ColdEmailModel.profileURL("https://www.linkedin.com/in/x") != nil)
        await model.confirmSent(true)
        #expect(daemon.sent.filter { $0.type == "update_referral" }.isEmpty)
        await store.stop()
    }

    @Test func answeringNotYetLeavesTheReferralAlone() async {
        let (store, daemon, _) = await makeStore()
        let model = ColdEmailModel(store: store)
        model.clipboard = RecordingClipboard()
        model.openURL = { _ in }
        model.copyNoteAndOpenProfile(store.outreach.referral(id: 5)!)
        await model.confirmSent(false)
        #expect(daemon.sent.filter { $0.type == "update_referral" }.isEmpty)
        #expect(store.outreach.referral(id: 5)?.state == .toConnect)
        await store.stop()
    }

    // MARK: Enable sending

    @Test func enableSendingRunsTheTestSend() async {
        let (store, daemon, _) = await makeStore(Self.data(sendEnabled: false), responder: { cmd in
            if case .enableSending(let p) = cmd {
                return .ack(AckPayload(ok: true, result: ["send_enabled": .bool(p.enabled), "test_sent_to": .string("asha@gmail.com")]))
            }
            return .ack(AckPayload())
        })
        let model = ColdEmailModel(store: store)
        await model.enableSending()
        #expect(daemon.sent.contains(.enableSending(EnableSendingPayload(enabled: true))))
        #expect(model.enableState == .enabled(sentTo: "asha@gmail.com"))
        #expect(store.outreach.sendEnabled)
        await store.stop()
    }

    @Test func failedTestSendKeepsSendingOff() async {
        let (store, _, _) = await makeStore(Self.data(sendEnabled: false), responder: { cmd in
            if case .enableSending = cmd { return .error(ErrorPayload(code: .unavailable, message: "the test email did not go through: 535 auth")) }
            return .ack(AckPayload())
        })
        let model = ColdEmailModel(store: store)
        await model.enableSending()
        #expect(model.enableState == .failed("The test email did not go through: 535 auth"))
        #expect(!store.outreach.sendEnabled)
        await store.stop()
    }

    @Test func enableSendingWithoutAMailboxSendsNothing() async {
        let (store, daemon, _) = await makeStore(Self.data(sendEnabled: false, mailbox: nil))
        let model = ColdEmailModel(store: store)
        await model.enableSending()
        #expect(daemon.sent.filter { $0.type == "enable_sending" }.isEmpty)
        if case .failed = model.enableState {} else { Issue.record("expected a failure, got \(model.enableState)") }
        await store.stop()
    }

    // MARK: Events

    @Test func eventsUpdateRepliesAndScouting() async {
        let (store, daemon, _) = await makeStore()
        store.outreach.beginScouting(companyID: 7)
        daemon.push(.scoutFinished(ScoutFinishedPayload(companyId: 7, found: 2, withEmail: 2, bestConfidence: 90)))
        daemon.push(.outreachReply(OutreachReplyPayload(threadId: 10, contactName: "Jane Rao", company: "Acme", label: .positive,
                                                        snippet: "Let's talk", applicationId: 1, suggestedStatus: .interview)))
        daemon.push(.applicationReply(ApplicationReplyPayload(replyId: 9, applicationId: 2, jobId: 2, company: "Acme", label: .rejection,
                                                              suggestedStatus: .rejected, fromEmail: "x@acme.com", subject: "Update",
                                                              snippet: "Sorry", receivedAt: Self.now, messageId: "<z>")))
        daemon.push(.outreachState(OutreachStatePayload(threadId: 11, messageId: 101, entity: .message, fromState: "draft",
                                                        toState: "scheduled", at: Self.now)))
        _ = await waitUntil { store.outreach.lastScout[7] != nil && store.outreach.pendingSuggestions.count == 2 }
        #expect(!store.outreach.scouting.contains(7))
        #expect(store.outreach.thread(id: 10)?.unreadReply == true)
        #expect(store.outreach.suggestedMove(threadID: 10) == .interview)
        #expect(store.outreach.message(id: 101)?.state == .scheduled)
        #expect(store.outreach.pendingSuggestion(applicationID: 2)?.suggestedStatus == .rejected)
        await store.stop()
    }

    @Test func outOfOfficeIsNotAReply() async {
        let (store, daemon, _) = await makeStore()
        daemon.push(.outreachReply(OutreachReplyPayload(threadId: 11, contactName: "Sam", company: "Acme", label: .ooo, snippet: "Away")))
        daemon.push(.scoutFinished(ScoutFinishedPayload(companyId: 99)))
        _ = await waitUntil { store.outreach.lastScout[99] != nil }
        #expect(store.outreach.thread(id: 11)?.unreadReply == false)
        await store.stop()
    }

    // MARK: Needs You ▸ Replies

    @Test func repliesSectionListsAndSelects() async {
        let (store, _, _) = await makeStore()
        let model = InboxModel(store: store)
        let keys = model.replyItems.map(\.key)
        #expect(keys == [.outreach(12), .employer(1), .possiblySent(104)])
        model.ensureSelection()
        #expect(model.selectedClusterID == nil && model.selectedReplyKey == .outreach(12), "no questions: the first reply is selected")
        model.selectReply(.employer(1))
        #expect(model.selectedReply == .employer(store.outreach.pendingSuggestions[0]))
        _ = await store.dismissReplySuggestion(store.outreach.pendingSuggestions[0])
        model.ensureSelection()
        #expect(model.selectedReplyKey == .outreach(12), "a handled reply drops out and selection moves on")
        await store.stop()
    }

    // MARK: Board labels and outreach marks

    @Test func newSkipReasonsHaveLabels() {
        #expect(BoardRules.skipTag("posting_closed", score: nil, threshold: 70) == "Posting closed")
        #expect(BoardRules.skipReasonLabel("posting_closed") == "Posting closed")
        #expect(BoardRules.skipTag("asks_candidate_to_pay", score: nil, threshold: 70) == "Asks you to pay a fee")
        #expect(BoardRules.skipReasonLabel("asks_candidate_to_pay") == "Asks for a fee")
        #expect(BoardRules.skipTag("risk_review:fee", score: nil, threshold: 70) == "Flagged: review before sending")
        #expect(BoardRules.skipReasonLabel("risk_review") == "Risk review")
    }

    @Test func outreachMarksForCards() async {
        let (store, _, _) = await makeStore()
        let marks = BoardRules.outreachMarks(store.outreach)
        #expect(marks[1] == .replied("Jane"), "a reply wins over a draft on the same application")
        #expect(marks[2] == nil, "a draft isn't an email yet")
        #expect(JobOutreachMark.emailed("Jane").text == "Emailed Jane")
        await store.stop()
    }

    // MARK: Settings

    @Test func outreachPreferencesValidate() {
        var p = Preferences()
        #expect(PreferencesValidator.validate(p).isEmpty)
        p.outreachDailyCap = 41
        p.outreachSendWindow = ["17:30", "09:30"]
        p.outreachMaxFollowups = 3
        let keys = Set(PreferencesValidator.validate(p).map(\.key))
        #expect(keys == [.outreachDailyCap, .outreachSendWindow, .outreachMaxFollowups])
        #expect(OutreachSettingsTab.times.first == "06:00" && OutreachSettingsTab.times.contains("09:30") && OutreachSettingsTab.times.last == "22:00")
        #expect(SettingsTab.allCases.contains(.outreach))
        #expect(PaletteSettingEntry.all.contains { $0.tab == .outreach && $0.key == "outreach_daily_cap" })
    }

    @Test func scheduleSummaryReadsPlainly() {
        let cal = Calendar.current
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: now)
        let tomorrow = f.string(from: cal.date(byAdding: .day, value: 1, to: now)!)
        let s = OutreachSchedule(batchUID: "b", sendAt: [:], days: [.init(date: today, count: 6), .init(date: tomorrow, count: 4)])
        #expect(s.summary(now: now) == "6 today, 4 tomorrow")
    }

    // MARK: Mock daemon end to end

    @Test func mockSeedsOutreachAndApprovesThroughTheSamePath() async {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.outreach.isLoaded && store.outreach.repliesLoaded }
        let o = store.outreach
        #expect(o.drafts.count == 3)
        #expect(o.unreadReplyThreads.count == 1 && o.unknownSends.count == 1 && o.pendingSuggestions.count == 2)
        #expect(!o.data.prospects.isEmpty && !o.data.referrals.isEmpty && !o.data.suppression.isEmpty)
        #expect(store.snapshotCounts.outreachDrafts == 3)

        let model = ColdEmailModel(store: store)
        model.selectAllDrafts()
        model.beginSend()
        await model.approveSelected()
        guard case .conflicts(let c, _) = model.approveState else {
            Issue.record("the mock refuses the ungrounded and low-confidence drafts, got \(model.approveState)")
            await store.stop()
            return
        }
        #expect(c.ungrounded.count == 1 && c.lowConfidence.count == 1)
        model.leaveOut(c.ungrounded)
        await model.sendAnywayAndRetry(c.lowConfidence)
        #expect(model.approveState == .idle && !model.isSendSheetPresented)
        _ = await waitUntil { store.outreach.scheduled.count == 3 }
        #expect(store.outreach.scheduled.count == 3, "1 seeded + 2 approved")
        #expect(store.outreach.drafts.count == 1, "the ungrounded draft stays in Drafts")

        // Opt-outs can't be removed; a user entry can.
        let optOut = o.data.suppression.first { $0.reason == .optOut }!
        #expect(await store.unsuppress(optOut) == false)
        let userEntry = o.data.suppression.first { $0.reason == .user }!
        #expect(await store.unsuppress(userEntry))
        _ = await waitUntil { !store.outreach.data.suppression.contains { $0.id == userEntry.id } }
        #expect(store.outreach.data.suppression.contains { $0.id == optOut.id })
        await store.stop()
    }

    @Test func mockAcceptsReplySuggestionAndMovesTheBoard() async {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded && store.outreach.repliesLoaded }
        let reply = store.outreach.pendingSuggestions.first { $0.suggestedStatus == .interview }!
        #expect(await store.acceptReplySuggestion(reply))
        _ = await waitUntil { store.jobs.job(applicationID: reply.applicationID)?.status == .interview && store.outreach.pendingSuggestions.count == 1 }
        #expect(store.jobs.job(applicationID: reply.applicationID)?.status == .interview)
        #expect(await store.acceptReplySuggestion(reply) == false, "a second accept is a conflict")
        await store.stop()
    }

    @Test func mockReferralTransitionsFollowTheContract() async {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.outreach.isLoaded }
        let referred = store.outreach.data.referrals.first { $0.state == .referred }!
        #expect(await store.updateReferral(id: referred.id, state: .asked) == false, "referred is terminal")
        let suggested = store.outreach.data.referrals.first { $0.state == .suggested }!
        #expect(await store.updateReferral(id: suggested.id, state: .toConnect))
        #expect(ReferralState.referred.nextStates.isEmpty && ReferralState.asked.nextStates.contains(.referred))
        await store.stop()
    }
}
