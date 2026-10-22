// DayLineModel.swift — pure rules for the Dashboard's day line: today's events (applications sent
// or approved, replies, follow-ups sent, things held for you) derived from what the store already
// holds, the time window the line spans, and where "now" sits on it. Unit-tested
// (Tests/AutoApplyTests/C2/DayLineTests.swift); the view only draws.
import Foundation

/// One chip on the day line.
struct DayLineItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        /// An application the agent sent on its own (Auto).
        case sent
        /// An application you approved, then the agent sent (Review).
        case approved
        /// An employer reply, or a reply to one of your emails.
        case reply
        /// An email that went out after you applied.
        case followUp
        /// A filled application held for your review.
        case review
        /// Questions or tasks the agent parked for you.
        case question
    }

    /// Where clicking the chip goes.
    enum Target: Hashable, Sendable {
        case review(jobID: Int)
        case question(clusterID: String)
        case reply(NeedsYouReply.Key)
        case job(Int)
    }

    var id: String
    var at: Date
    var kind: Kind
    /// The printed label beside the time ("Sent", "Reply", "3 questions").
    var label: String
    /// Short title: the company.
    var title: String
    /// Marked with the coral dot: something here waits for you.
    var needsYou: Bool
    var target: Target?
}

/// The stretch of today the line spans, and where a moment falls on it.
struct DayLineWindow: Equatable, Sendable {
    var start: Date
    var end: Date

    /// 0 at `start`, 1 at `end`, clamped.
    func fraction(_ date: Date) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / span))
    }

    /// Hour marks under the line: every 2 hours (3 on long days), aligned to the hour.
    func hourMarks(calendar: Calendar = .current) -> [Date] {
        let hours = end.timeIntervalSince(start) / 3_600
        let step = hours > 14 ? 3 : 2
        var marks: [Date] = []
        var t = start
        while t <= end {
            marks.append(t)
            guard let next = calendar.date(byAdding: .hour, value: step, to: t) else { break }
            t = next
        }
        return marks
    }
}

enum DayLine {
    /// The working day the line shows at least, so a quiet morning still reads as a day.
    static let dayStartHour = 8
    static let dayEndHour = 20
    /// Questions parked within this many minutes of each other share one chip.
    static let questionGroupMinutes: Double = 30

    /// The calm line under an empty day.
    static let emptyNote = "Nothing yet today. I'll put each application, reply and question here as it happens."

    /// Today's events, oldest first. Only what the store already has: submitted jobs (approved when
    /// sent in Review mode), employer replies, outreach replies and sends, applications waiting
    /// for review and Needs You clusters opened today.
    static func items(jobs: [JobItem], replies: [ApplicationReplyItem], messages: [OutreachMessageItem],
                      threads: [OutreachThreadItem], clusters: [QuestionCluster], now: Date,
                      calendar: Calendar = .current) -> [DayLineItem] {
        func today(_ date: Date?) -> Date? {
            guard let date, calendar.isDate(date, inSameDayAs: now), date <= now.addingTimeInterval(60) else { return nil }
            return date
        }
        var out: [DayLineItem] = []

        for job in jobs {
            if job.state == .submitted, let at = today(job.submittedAt) {
                let approved = job.mode == .review
                out.append(DayLineItem(id: "sent-\(job.id)", at: at, kind: approved ? .approved : .sent,
                                       label: approved ? "Approved" : "Sent", title: job.company, needsYou: false, target: .job(job.id)))
            } else if job.state == .awaitingReview, let at = today(job.stateUpdatedAt) {
                out.append(DayLineItem(id: "review-\(job.id)", at: at, kind: .review, label: "Review", title: job.company,
                                       needsYou: true, target: .review(jobID: job.id)))
            }
        }

        let jobsByApplication = Dictionary(jobs.compactMap { j in j.applicationID.map { ($0, j) } }, uniquingKeysWith: { a, _ in a })
        for reply in replies {
            guard let at = today(reply.receivedAt) else { continue }
            let job = jobsByApplication[reply.applicationID]
            let waiting = reply.isPendingSuggestion || reply.readAt == nil
            out.append(DayLineItem(id: "reply-\(reply.id)", at: at, kind: .reply, label: "Reply", title: job?.company ?? reply.sender,
                                   needsYou: waiting, target: waiting ? .reply(.employer(reply.id)) : job.map { .job($0.id) }))
        }

        let threadsByID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for message in messages {
            guard let thread = threadsByID[message.threadID], thread.state != .cancelled else { continue }
            if message.isInbound {
                guard message.classification != "bounce", let at = today(message.createdAt) else { continue }
                let waiting = thread.unreadReply
                out.append(DayLineItem(id: "in-\(message.id)", at: at, kind: .reply, label: "Reply", title: thread.company,
                                       needsYou: waiting, target: waiting ? .reply(.outreach(thread.id)) : thread.jobID.map { .job($0) }))
            } else if message.state == .sent, let at = today(message.sentAt) {
                let followUp = thread.kind == .application || message.isFollowup
                out.append(DayLineItem(id: "out-\(message.id)", at: at, kind: .followUp, label: followUp ? "Follow-up" : "Email",
                                       title: thread.company, needsYou: false, target: thread.jobID.map { .job($0) }))
            }
        }

        out.append(contentsOf: questionItems(clusters: clusters, today: today))
        return out.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// Clusters opened today, one chip per burst (a run parks several questions within minutes).
    private static func questionItems(clusters: [QuestionCluster], today: (Date?) -> Date?) -> [DayLineItem] {
        let opened = clusters.compactMap { c in today(c.createdAt).map { (c, $0) } }.sorted { $0.1 < $1.1 }
        var groups: [[(QuestionCluster, Date)]] = []
        for entry in opened {
            if let first = groups.last?.first, entry.1.timeIntervalSince(first.1) <= questionGroupMinutes * 60 {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups.map { group in
            let clusters = group.map(\.0)
            let n = clusters.count
            let tasks = clusters.filter(\.isAction).count
            let label = switch (n, tasks) {
            case (1, 1): "Task"
            case (1, _): "Question"
            case (_, n): "\(n) tasks"
            case (_, 0): "\(n) questions"
            default: "\(n) for you"
            }
            var companies: [String] = []
            for c in clusters { for name in c.companies where !companies.contains(name) { companies.append(name) } }
            let title = companies.first.map { companies.count > 1 ? "\($0) +\(companies.count - 1)" : $0 }
                ?? C3Format.plural(clusters.reduce(0) { $0 + $1.jobCount }, "job")
            return DayLineItem(id: "ask-\(clusters[0].clusterId)", at: group[0].1, kind: .question, label: label, title: title,
                               needsYou: true, target: .question(clusterID: InboxStore.sorted(clusters)[0].clusterId))
        }
    }

    /// The window the line spans: at least 08:00–20:00 today, stretched to the hour around the
    /// earliest and latest event and now, never past today. Now keeps half an hour of room on
    /// the right so its marker never sits on the edge.
    static func window(items: [DayLineItem], now: Date, calendar: Calendar = .current) -> DayLineWindow {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now.addingTimeInterval(86_400)
        let workStart = calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: now) ?? dayStart
        let workEnd = calendar.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: now) ?? dayEnd
        let earliest = [workStart, now, items.first?.at].compactMap { $0 }.min()!
        let latest = [workEnd, now.addingTimeInterval(30 * 60), items.last?.at].compactMap { $0 }.max()!
        let start = max(dayStart, floorHour(earliest, calendar: calendar))
        let end = min(dayEnd, ceilHour(latest, calendar: calendar))
        return DayLineWindow(start: start, end: max(end, start.addingTimeInterval(3_600)))
    }

    /// "14:12": 24-hour, like the agent's ticker.
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "4 sent · 2 replies · 3 for you" (empty when nothing happened).
    static func summary(_ items: [DayLineItem]) -> String {
        let sent = items.filter { $0.kind == .sent || $0.kind == .approved }.count
        let replies = items.filter { $0.kind == .reply }.count
        let waiting = items.filter(\.needsYou).count
        var parts: [String] = []
        if sent > 0 { parts.append("\(sent) sent") }
        if replies > 0 { parts.append(replies == 1 ? "1 reply" : "\(replies) replies") }
        if waiting > 0 { parts.append("\(waiting) for you") }
        return parts.joined(separator: " · ")
    }

    /// VoiceOver: "Sent, Stripe, 14:12" (+ ", waiting for you").
    static func accessibilityLabel(_ item: DayLineItem, calendar: Calendar = .current) -> String {
        "\(item.label), \(item.title), \(time(item.at, calendar: calendar))\(item.needsYou ? ", waiting for you" : "")"
    }

    private static func floorHour(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    private static func ceilHour(_ date: Date, calendar: Calendar) -> Date {
        let floor = floorHour(date, calendar: calendar)
        return floor == date ? date : floor.addingTimeInterval(3_600)
    }
}
