// SessionModel.swift — "Today's ten minutes" (docs/DESIGN_AWARD_VISION.md §3.3): what is waiting
// for the user, each piece with a rough time estimate, and the guided session that walks through
// it in order. Pure logic and state only; the live sources are read in SessionSources.swift, the
// floating bar is SessionBar.swift and the Dashboard card is Dashboard/Briefing/.
//
// Estimates are estimates: they come from the kind of work (a yes/no question ≈ 10 s, a short
// answer ≈ 30 s, an essay ≈ 90 s, a flagged application ≈ 40 s, a clean one ≈ 15 s…), are rounded
// up to whole minutes and always shown as "about".
import Foundation
import Observation

/// The kinds of work in a session, in session order.
enum SessionKind: Int, CaseIterable, Comparable, Sendable {
    /// Needs You tasks the agent can't do itself (sign in, CAPTCHA, verification).
    case blocker
    /// Needs You questions (one item per cluster: answer once, many jobs).
    case question
    /// Applications waiting in Review.
    case review
    /// Replies to read: people who answered your emails, employer emails.
    case reply
    /// Interview prep for jobs at Assessment or Interview without a prep pack yet.
    case prep
    /// Cold-email drafts waiting in the Outbox.
    case draft

    static func < (a: SessionKind, b: SessionKind) -> Bool { a.rawValue < b.rawValue }

    /// The session bar's step name: "Answer a question".
    var stepTitle: String {
        switch self {
        case .blocker: "Help the agent past a sign-in or check"
        case .question: "Answer a question"
        case .review: "Look over an application"
        case .reply: "Read a reply"
        case .prep: "Prepare for an interview"
        case .draft: "Check a cold-email draft"
        }
    }

    /// The briefing's row: "2 questions to answer".
    func groupLabel(count: Int) -> String {
        let one = count == 1
        switch self {
        case .blocker: return one ? "1 sign-in or check the agent can't do" : "\(count) sign-ins or checks the agent can't do"
        case .question: return one ? "1 question to answer" : "\(count) questions to answer"
        case .review: return one ? "1 application to look over" : "\(count) applications to look over"
        case .reply: return one ? "1 reply to read" : "\(count) replies to read"
        case .prep: return one ? "1 interview to prepare for" : "\(count) interviews to prepare for"
        case .draft: return one ? "1 cold-email draft to check" : "\(count) cold-email drafts to check"
        }
    }

    var symbol: String {
        switch self {
        case .blocker: "person.badge.key"
        case .question: "hand.raised"
        case .review: "checkmark.rectangle.stack"
        case .reply: "envelope.badge"
        case .prep: "person.2.wave.2"
        case .draft: "envelope.open"
        }
    }
}

/// One thing to do in the session.
struct SessionItem: Identifiable, Hashable, Sendable {
    enum Key: Hashable, Sendable {
        case cluster(String)
        case review(jobID: Int)
        case reply(NeedsYouReply.Key)
        case prep(jobID: Int)
        case draft(messageID: Int)
    }

    var key: Key
    var kind: SessionKind
    /// What it's about ("Stripe · Backend Engineer", the question text…), for help and VoiceOver.
    var subject: String
    /// Rough time it takes, in seconds (an estimate).
    var seconds: Int

    var id: Key { key }
}

/// The per-kind time estimates (seconds) and how they're written.
enum SessionEstimate {
    /// Needs You question by answer kind: yes/no ≈ 10 s, a pick ≈ 15 s, short text ≈ 30 s,
    /// long text ≈ 90 s; a task in the agent's Chrome ≈ 2 min.
    static func seconds(for kind: AnswerKind) -> Int {
        switch kind {
        case .yesNo: 10
        case .choice: 15
        case .shortText, .number, .url, .email, .date: 30
        case .longText: 90
        case .action: 120
        }
    }

    /// Review: an application with flagged answers ≈ 40 s, a clean one ≈ 15 s.
    static func review(flagged: Bool) -> Int { flagged ? 40 : 15 }

    /// A reply to read ≈ 30 s; one that may not have been sent (yes / no) ≈ 15 s.
    static func reply(_ item: NeedsYouReply) -> Int {
        if case .possiblySent = item { return 15 }
        return 30
    }

    /// Interview prep: generate or open the pack and skim it ≈ 3 min.
    static let prep = 180
    /// A cold-email draft to check ≈ 30 s.
    static let draft = 30

    /// "about 4 min", "under a minute". Rounded up to whole minutes; always "about".
    static func label(seconds: Int) -> String {
        guard seconds > 0 else { return "no time" }
        if seconds < 60 { return "under a minute" }
        return "about \(minutes(seconds)) min"
    }

    /// Whole minutes, rounded up.
    static func minutes(_ seconds: Int) -> Int { max(0, (seconds + 59) / 60) }
}

/// The work from each source, already in that source's own order (Needs You's list order,
/// Review's queue order, newest replies first…). `items` puts it in session order.
struct SessionSources: Equatable, Sendable {
    var blockers: [SessionItem] = []
    var questions: [SessionItem] = []
    var reviews: [SessionItem] = []
    var replies: [SessionItem] = []
    var preps: [SessionItem] = []
    var drafts: [SessionItem] = []

    /// Session order: unblock the agent, answer questions, look over applications, read replies,
    /// prepare for interviews, then check cold-email drafts. Duplicate keys are dropped.
    var items: [SessionItem] {
        var seen = Set<SessionItem.Key>()
        return (blockers + questions + reviews + replies + preps + drafts).filter { seen.insert($0.key).inserted }
    }

    var isEmpty: Bool { items.isEmpty }
}

/// What the Dashboard's briefing shows: one row per kind with its count and estimate, the total.
struct BriefingSummary: Equatable, Sendable {
    struct Group: Equatable, Identifiable, Sendable {
        var kind: SessionKind
        var count: Int
        var seconds: Int
        var id: SessionKind { kind }
        var label: String { kind.groupLabel(count: count) }
        var estimate: String { SessionEstimate.label(seconds: seconds) }
    }

    var groups: [Group]

    init(items: [SessionItem]) {
        let byKind = Dictionary(grouping: items, by: \.kind)
        groups = SessionKind.allCases.compactMap { kind in
            guard let list = byKind[kind], !list.isEmpty else { return nil }
            return Group(kind: kind, count: list.count, seconds: list.reduce(0) { $0 + $1.seconds })
        }
    }

    var isDone: Bool { groups.isEmpty }
    var itemCount: Int { groups.reduce(0) { $0 + $1.count } }
    var totalSeconds: Int { groups.reduce(0) { $0 + $1.seconds } }
    var totalLabel: String { SessionEstimate.label(seconds: totalSeconds) }

    /// "5 things are waiting for you, about 4 min in all."
    var headline: String {
        let n = itemCount
        guard n > 0 else { return "Nothing is waiting for you." }
        let things = n == 1 ? "1 thing is waiting for you" : "\(n) things are waiting for you"
        return "\(things), \(totalLabel) in all."
    }

    /// The Start button: "Start · about 4 min".
    var startTitle: String {
        totalSeconds < 60 ? "Start · under a minute" : "Start · \(SessionEstimate.minutes(totalSeconds)) min"
    }
}

/// The guided session: a fixed list taken when Start is pressed, walked in order. Items finish
/// when the work is actually done (`reconcile`), or when the user moves on with Next (⌘→); Skip
/// leaves an item for later. When nothing is left it ends on "Done for today".
@MainActor
@Observable
final class SessionModel {
    enum Phase: Equatable, Sendable { case idle, active, done }

    private(set) var phase: Phase = .idle
    private(set) var items: [SessionItem] = []
    private(set) var index = 0
    /// Items whose work is done (seen gone from its source, or moved past with Next).
    private(set) var finished: Set<SessionItem.Key> = []
    /// Items left for later with Skip.
    private(set) var skipped: Set<SessionItem.Key> = []
    /// Bumped whenever the current item changes or should be shown again: the host navigates to it.
    private(set) var navigationSerial = 0
    /// Bumped once per finished session (the "Done for today" moment).
    private(set) var doneSerial = 0

    static func shared(for store: AppStore) -> SessionModel {
        FeatureModels.model(SessionModel.self, for: store) { SessionModel() }
    }

    init() {}

    var isActive: Bool { phase == .active }

    var current: SessionItem? {
        guard phase == .active, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// 1-based position of the current item ("2 of 7").
    var position: Int { min(index + 1, items.count) }
    var total: Int { items.count }

    /// "2 of 7".
    var progressLabel: String { "\(position) of \(total)" }

    /// Estimated time left: the current item and everything after it that isn't done or skipped.
    var remainingSeconds: Int {
        guard phase == .active, items.indices.contains(index) else { return 0 }
        return items[index...].filter { !finished.contains($0.key) && !skipped.contains($0.key) }.reduce(0) { $0 + $1.seconds }
    }

    /// "about 3 min left", "under a minute left".
    var remainingLabel: String { "\(SessionEstimate.label(seconds: remainingSeconds)) left" }

    /// Items done in this session.
    var finishedCount: Int { items.filter { finished.contains($0.key) }.count }
    /// Items left for later.
    var skippedCount: Int { items.filter { skipped.contains($0.key) && !finished.contains($0.key) }.count }

    /// The closing line under "Done for today."
    var doneMessage: String {
        let left = skippedCount
        if left == 0 { return "The agent takes it from here." }
        return left == 1 ? "1 item left for later. The agent takes it from here." : "\(left) items left for later. The agent takes it from here."
    }

    // MARK: Commands

    /// Begin with `items` (in order). Returns false (and stays idle) when there is nothing to do.
    @discardableResult
    func start(_ items: [SessionItem]) -> Bool {
        guard !items.isEmpty else { return false }
        self.items = items
        index = 0
        finished = []
        skipped = []
        phase = .active
        navigationSerial += 1
        return true
    }

    /// Next (⌘→): the user is done with this one; go to the next.
    func next() {
        guard let current else { return }
        finished.insert(current.key)
        advance()
    }

    /// Skip: leave this one for later; go to the next.
    func skip() {
        guard let current else { return }
        skipped.insert(current.key)
        advance()
    }

    /// End the session early (Esc). Nothing is lost: undone items stay where they are.
    func end() {
        phase = .idle
        items = []
        index = 0
        finished = []
        skipped = []
    }

    /// Close the "Done for today" moment.
    func dismissDone() {
        guard phase == .done else { return }
        end()
    }

    /// Show the current item again (e.g. after wandering to another screen).
    func showCurrent() {
        guard current != nil else { return }
        navigationSerial += 1
    }

    /// Mark items whose work is no longer waiting as done (`open` = the keys still waiting in
    /// their sources). If the current one is done, move on.
    func reconcile(open: Set<SessionItem.Key>) {
        guard phase == .active else { return }
        for item in items where !open.contains(item.key) {
            finished.insert(item.key)
        }
        if let current, finished.contains(current.key) { advance() }
    }

    /// The next item after the current one that isn't done; "Done for today" when there is none.
    private func advance() {
        var i = index + 1
        while items.indices.contains(i), finished.contains(items[i].key) { i += 1 }
        if items.indices.contains(i) {
            index = i
            navigationSerial += 1
        } else {
            index = items.count
            phase = .done
            doneSerial += 1
        }
    }
}
