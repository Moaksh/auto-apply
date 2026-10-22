// DayLineTests.swift — the Dashboard's day line: which of today's events become chips and in what
// order, which wait for you, the window and where now sits on it, lane packing, the empty day,
// and Job detail's ticket fields (missing data is left out).
import Foundation
import Testing
@testable import AutoApply

@Suite("C2 · Day line")
struct DayLineTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-10-10 at hh:mm UTC.
    static func at(_ h: Int, _ m: Int = 0, day: Int = 10) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    static let now = at(14, 30)

    func items(jobs: [JobItem] = [], replies: [ApplicationReplyItem] = [], messages: [OutreachMessageItem] = [],
               threads: [OutreachThreadItem] = [], clusters: [QuestionCluster] = []) -> [DayLineItem] {
        DayLine.items(jobs: jobs, replies: replies, messages: messages, threads: threads, clusters: clusters, now: Self.now, calendar: Self.utc)
    }

    func sent(_ id: Int, _ company: String, at: Date, review: Bool = false) -> JobItem {
        var j = C2.job(id: id, company: company, state: .submitted, status: .applied, submittedAt: at)
        j.mode = review ? .review : .auto
        return j
    }

    // MARK: Derivation

    @Test func todaysEventsInTimeOrder() {
        var waiting = C2.job(id: 3, company: "Notion", state: .awaitingReview)
        waiting.stateUpdatedAt = Self.at(13, 50)
        let jobs = [sent(1, "Razorpay", at: Self.at(9, 12)), sent(2, "Stripe", at: Self.at(11, 40), review: true), waiting,
                    sent(4, "Old", at: Self.at(17, 0, day: 9))]
        let reply = ApplicationReplyItem(id: 7, applicationID: 1, messageID: "<m>", fromEmail: "t@razorpay.com", subject: "Next steps",
                                         snippet: "", receivedAt: Self.at(12, 5), label: .interviewInvite, suggestedStatus: .interview,
                                         suggestionState: .pending)
        let thread = OutreachThreadItem(id: 9, kind: .application, companyID: 5, company: "Ramp", jobID: 5, applicationID: 5,
                                        state: .active, createdAt: Self.at(8), updatedAt: Self.at(10))
        let followUp = OutreachMessageItem(id: 11, threadID: 9, seq: 1, state: .sent, body: "", sentAt: Self.at(10, 2),
                                           createdAt: Self.at(10), updatedAt: Self.at(10, 2))
        var cluster = Samples.cluster("c1", jobs: [6], question: "Notice period?")
        cluster.companies = ["Zepto"]
        cluster.createdAt = Self.at(14, 1)
        let list = items(jobs: jobs, replies: [reply], messages: [followUp], threads: [thread], clusters: [cluster])
        #expect(list.map(\.title) == ["Razorpay", "Ramp", "Stripe", "Razorpay", "Notion", "Zepto"])
        #expect(list.map(\.label) == ["Sent", "Follow-up", "Approved", "Reply", "Review", "Question"])
        #expect(!list.contains { $0.title == "Old" }, "yesterday is not on today's line")
        // What waits for you, and where clicking it goes.
        #expect(list.filter(\.needsYou).map(\.title) == ["Razorpay", "Notion", "Zepto"])
        #expect(list[3].target == .reply(.employer(7)))
        #expect(list[4].target == .review(jobID: 3))
        #expect(list[5].target == .question(clusterID: "c1"))
        #expect(list[0].target == .job(1) && !list[0].needsYou)
        #expect(DayLine.summary(list) == "2 sent · 1 reply · 3 for you")
    }

    @Test func readRepliesAndOutreachRepliesMarkOnlyWhatsUnread() {
        let read = ApplicationReplyItem(id: 1, applicationID: 1, messageID: "<a>", fromEmail: "x@y.com", fromName: "Acme Talent", subject: "",
                                        snippet: "", receivedAt: Self.at(9), label: .receivedAck, readAt: Self.at(9, 5))
        let thread = OutreachThreadItem(id: 2, kind: .application, companyID: 1, company: "Linear", jobID: 4, state: .replied,
                                        unreadReply: true, createdAt: Self.at(8), updatedAt: Self.at(11))
        let inbound = OutreachMessageItem(id: 3, threadID: 2, seq: 1, isInbound: true, state: .received, body: "", classification: "positive",
                                          createdAt: Self.at(11), updatedAt: Self.at(11))
        let bounce = OutreachMessageItem(id: 4, threadID: 2, seq: 2, isInbound: true, state: .received, body: "", classification: "bounce",
                                         createdAt: Self.at(12), updatedAt: Self.at(12))
        let list = items(replies: [read], messages: [inbound, bounce], threads: [thread])
        #expect(list.count == 2, "bounces aren't replies")
        #expect(list[0].title == "Acme Talent" && !list[0].needsYou, "no job for the reply: the sender's name")
        #expect(list[0].target == nil)
        #expect(list[1].title == "Linear" && list[1].needsYou && list[1].target == .reply(.outreach(2)))
    }

    @Test func questionsOpenedInOneBurstShareAChip() {
        func cluster(_ id: String, _ company: String, _ h: Int, _ m: Int, action: Bool = false) -> QuestionCluster {
            var c = Samples.cluster(id, jobs: [1])
            c.companies = [company]
            c.createdAt = Self.at(h, m)
            if action { c.kind = "action"; c.actionType = "account" }
            return c
        }
        let list = items(clusters: [cluster("a", "Stripe", 9, 0), cluster("b", "Ramp", 9, 10), cluster("c", "Stripe", 9, 20),
                                    cluster("d", "Notion", 13, 0, action: true)])
        #expect(list.count == 2)
        #expect(list[0].label == "3 questions" && list[0].title == "Stripe +1")
        #expect(list[0].at == Self.at(9, 0))
        #expect(list[1].label == "Task" && list[1].needsYou)
    }

    @Test func emptyDayHasOnlyTheNowMarker() {
        let list = items(jobs: [C2.job(id: 1, state: .queued)])
        #expect(list.isEmpty)
        #expect(DayLine.summary(list).isEmpty)
        let window = DayLine.window(items: list, now: Self.now, calendar: Self.utc)
        #expect(window.start == Self.at(8) && window.end == Self.at(20))
        #expect(!DayLine.emptyNote.contains("!"))
    }

    // MARK: Window and now

    @Test func nowSitsWhereTheClockIs() {
        let window = DayLine.window(items: [], now: Self.now, calendar: Self.utc)
        // 14:30 on an 08:00–20:00 line: 6.5 of 12 hours.
        #expect(abs(window.fraction(Self.now) - 6.5 / 12) < 0.0001)
        #expect(window.fraction(Self.at(6)) == 0 && window.fraction(Self.at(23)) == 1, "clamped")
        #expect(window.hourMarks(calendar: Self.utc).map { DayLine.time($0, calendar: Self.utc) }
                == ["08:00", "10:00", "12:00", "14:00", "16:00", "18:00", "20:00"])
    }

    @Test func windowStretchesForEarlyEventsAndLateNights() {
        let early = [sent(1, "Stripe", at: Self.at(6, 40))]
        let w1 = DayLine.window(items: items(jobs: early), now: Self.now, calendar: Self.utc)
        #expect(w1.start == Self.at(6))
        // Late at night, now keeps room on the right but the line never runs past midnight.
        let late = Self.at(23, 50)
        let w2 = DayLine.window(items: [], now: late, calendar: Self.utc)
        #expect(w2.end == Self.at(0, day: 11))
        #expect(w2.fraction(late) < 1)
        let evening = DayLine.window(items: [], now: Self.at(19, 45), calendar: Self.utc)
        #expect(evening.end == Self.at(21), "half an hour of room after now")
        #expect(DayLine.time(Self.at(9, 5), calendar: Self.utc) == "09:05")
    }

    // MARK: Lanes

    @Test func chipsTakeTheNextLaneWhenTheyWouldOverlap() {
        let packed = DayLineLayout.pack(widths: [100, 100, 100, 100, 100], preferred: [0, 40, 80, 90, 300], width: 600, maxLanes: 3, gap: 6)
        #expect(packed.map(\.lane) == [0, 1, 2, 0, 0])
        // All lanes taken: the fourth waits its turn to the right in the lane that frees first.
        #expect(packed[3].x == 106)
        #expect(packed[4].x == 300)
        // Chips never run off the trailing edge.
        let edge = DayLineLayout.pack(widths: [120], preferred: [580], width: 600, maxLanes: 3, gap: 6)
        #expect(edge[0].x == 480)
    }

    // MARK: Job detail ticket fields

    @Test func ticketFactsPrintRealFieldsOnly() {
        let en = Locale(identifier: "en_US")
        var job = C2.job(id: 1, state: .submitted, status: .applied, score: 92, source: .linkedin, ats: .greenhouse)
        job.location = "Bengaluru, India"
        job.postedAt = Self.at(9, day: 8)
        job.resumeVariantID = 1
        job.coverLetterPath = "/tmp/letter.md"
        job.salaryMin = 3_000_000
        job.salaryMax = 4_200_000
        job.salaryCurrency = "INR"
        let facts = JobDetailRules.ticketFacts(for: job, answerCount: 9, threshold: 70, locale: en)
        #expect(facts.map(\.label) == ["Match", "Posted", "Found", "Site", "Location", "Salary", "Enclosed"])
        #expect(facts[0].value == "92" && facts[0].tone == .accent)
        #expect(facts[3].value == "Greenhouse")
        #expect(facts[5].value == "INR 3M–4.2M")
        #expect(facts[6].value == "Resume + Letter + 9 answers")
        #expect(!facts.contains { $0.label == "Status" }, "the badge already says it")

        // A bare discovered job: no score, no posting date, no location, no salary, nothing enclosed.
        let bare = C2.job(id: 2, state: .discovered)
        let few = JobDetailRules.ticketFacts(for: bare, answerCount: nil, threshold: 70, locale: en)
        #expect(few.map(\.label) == ["Found", "Site"])
        #expect(few.allSatisfy { !$0.value.isEmpty && $0.value != "—" })

        // Below the bar the match reads in the needs-you ink; a queued job encloses nothing yet.
        var low = C2.job(id: 3, state: .queued, score: 61)
        low.resumeVariantID = 1
        low.remote = .remote
        let lowFacts = JobDetailRules.ticketFacts(for: low, answerCount: 4, threshold: 70, locale: en)
        #expect(lowFacts.first?.tone == .needsYou)
        #expect(lowFacts.first { $0.label == "Location" }?.value == "Remote")
        #expect(!lowFacts.contains { $0.label == "Enclosed" })
        // Answers not loaded yet: the enclosure lists what is known.
        #expect(JobDetailRules.enclosed(job, answerCount: nil) == "Resume + Letter")
        #expect(JobDetailRules.enclosed(job, answerCount: 1) == "Resume + Letter + 1 answer")
    }
}
