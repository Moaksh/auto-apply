// DashboardModel.swift — pure presentation logic for the Dashboard (docs/UI_UX_PLAN.md §4):
// greeting, next-run label, hero state/verb, KPI captions, count-up policy. Views stay thin
// and every rule here is unit-tested (Tests/AutoApplyTests/C2).
import CryptoKit
import Foundation

enum DashboardFormat {
    /// "Good afternoon, Moaksh." — changes at most once per session (the view caches it).
    static func greeting(at date: Date, name: String?, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<17: part = "Good afternoon"
        case 17..<22: part = "Good evening"
        default: part = "Working late"
        }
        if let name, !name.isEmpty { return "\(part), \(name)." }
        return "\(part)."
    }

    /// "TODAY · Friday 10 Oct".
    static func dateEyebrow(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar)
        style = style.weekday(.wide).day(.defaultDigits).month(.abbreviated)
        return "Today · \(date.formatted(style))"
    }

    /// "Next run 14:00"; inside the last 10 minutes it counts down ("Next run in 4 min") so the
    /// header doesn't tick constantly the rest of the day.
    static func nextRunLabel(nextRun: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let nextRun else { return nil }
        let remaining = nextRun.timeIntervalSince(now)
        if remaining <= 30 { return "Next run starting" }
        if remaining <= 600 {
            let minutes = max(1, Int((remaining / 60).rounded(.up)))
            return "Next run in \(minutes) min"
        }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        let time = nextRun.formatted(style)
        if calendar.isDate(nextRun, inSameDayAs: now) { return "Next run \(time)" }
        return "Next run \(nextRun.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    /// Whether the header needs a 1 s / 30 s refresh (only while counting down).
    static func needsCountdownRefresh(nextRun: Date?, now: Date) -> Bool {
        guard let nextRun else { return false }
        let remaining = nextRun.timeIntervalSince(now)
        return remaining <= 660 && remaining > -60
    }

    /// W3 caption: "+4 vs avg", "−2 vs avg", "On your average".
    static func deltaVsAverage(_ delta: Double) -> String {
        let rounded = Int(delta.rounded())
        if rounded == 0 { return "On your average" }
        return rounded > 0 ? "+\(rounded) vs avg" : "−\(abs(rounded)) vs avg"
    }

    /// Delta between two rates in percentage points ("3pt"), nil when either is missing.
    static func responseRateDelta(current: Double?, previous: Double?) -> MetricDelta? {
        guard let current, let previous else { return nil }
        let points = Int(((current - previous) * 100).rounded())
        guard points != 0 else { return nil }
        return MetricDelta(text: "\(abs(points))pt", isPositive: points > 0)
    }

    /// Submitted node glyphs: up to 12 checks, then "✓ × 21".
    static func submittedGlyphs(_ count: Int) -> String {
        guard count > 0 else { return "" }
        if count <= 12 { return String(repeating: "✓", count: count) }
        return "✓ × \(count)"
    }

    /// "27 skipped (below 70)" branch label.
    static func skippedLabel(_ count: Int, threshold: Int) -> String {
        // Skips come from filters (location, seniority, excludes…) as well as the threshold, so the
        // label must not claim they were all "below" it. Reasons are on each card in Pipeline.
        "\(count) skipped"
    }

    static func needsYouLabel(_ count: Int) -> String {
        count == 1 ? "1 needs you" : "\(count) need you"
    }

    /// Elapsed timer "00:42" / "1:02:09".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    /// Ticker timestamp "14:02:11".
    static func tickerTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

/// What the Live Agent hero shows (§4.3 W2 "Hero states").
enum HeroState: Equatable, Sendable {
    case loading
    case unreachable(lastSeen: Date?)
    case firstRun
    case paused
    case capReached(used: Int, limit: Int)
    case idle
    case discovering
    case scoring
    case prepping
    case filling

    var isRunning: Bool {
        switch self {
        case .discovering, .scoring, .prepping, .filling: true
        default: false
        }
    }

    struct Inputs: Equatable, Sendable {
        var hasSnapshot: Bool
        var isConnected: Bool
        var isUnreachable: Bool
        var lastSeen: Date?
        var paused: Bool
        var activity: DaemonActivity
        var hasAnyJobs: Bool
        var hasLastRun: Bool
        var capReached: CapReachedPayload?
        /// Today's usage from the snapshot caps, so "Done for today" survives a relaunch/reconnect
        /// (the live `cap_reached` event is cleared on snapshot reset).
        var dailyUsed: Int = 0
        var dailyLimit: Int = 0
    }

    static func resolve(_ i: Inputs) -> HeroState {
        if i.isUnreachable && !i.isConnected { return .unreachable(lastSeen: i.lastSeen) }
        if !i.hasSnapshot { return .loading }
        if i.paused { return .paused }
        switch i.activity {
        case .discovering: return .discovering
        case .scoring: return .scoring
        case .prepping: return .prepping
        case .applying: return .filling
        case .idle:
            if let cap = i.capReached, cap.cap == .daily { return .capReached(used: cap.used, limit: cap.limit) }
            if i.dailyLimit > 0 && i.dailyUsed >= i.dailyLimit { return .capReached(used: i.dailyUsed, limit: i.dailyLimit) }
            if !i.hasAnyJobs && !i.hasLastRun { return .firstRun }
            return .idle
        }
    }
}

/// The hero status verb (§4.3 W2a): Idle · Discovering · Scoring · Filling · Waiting on page ·
/// Submitting · Paused · Needs you · Error.
enum HeroVerb: String, Sendable, Equatable {
    case idle = "Idle"
    case discovering = "Discovering"
    case scoring = "Scoring"
    case prepping = "Collecting questions"
    case filling = "Filling"
    case waitingOnPage = "Waiting on page"
    case submitting = "Sending"
    case paused = "Paused"
    case needsYou = "Needs you"
    case error = "Error"
    case doneForToday = "Done for today"
    case connecting = "Connecting"
    case unreachable = "Can't reach the agent"

    static func resolve(state: HeroState, activeJobState: AppState?, lastStepAction: String?, openClusters: Int, hasError: Bool) -> HeroVerb {
        switch state {
        case .loading: return .connecting
        case .unreachable: return .unreachable
        case .paused: return .paused
        case .capReached: return .doneForToday
        case .discovering: return .discovering
        case .scoring: return .scoring
        case .prepping: return .prepping
        case .filling:
            if activeJobState == .submitting { return .submitting }
            if let action = lastStepAction?.lowercased(), action.contains("wait") || action.contains("load") { return .waitingOnPage }
            return .filling
        case .idle, .firstRun:
            if hasError { return .error }
            if openClusters > 0 { return .needsYou }
            return .idle
        }
    }
}

/// Throttle for VoiceOver announcements of pipeline stage changes (one per 10 s, §7).
struct AnnouncementThrottle: Sendable {
    var interval: TimeInterval = 10
    private(set) var lastAnnouncedAt: Date?

    init(interval: TimeInterval = 10) { self.interval = interval }

    mutating func shouldAnnounce(at now: Date) -> Bool {
        if let last = lastAnnouncedAt, now.timeIntervalSince(last) < interval { return false }
        lastAnnouncedAt = now
        return true
    }
}

/// Upcoming step chips under the ticker ("▢ cover letter ▢ review ▢ submit").
enum TickerChips {
    static let upcoming = ["cover letter", "review", "submit"]

    /// Which chips are done given the steps seen so far for the active application.
    static func completed(steps: [TickerStep]) -> Set<String> {
        var done: Set<String> = []
        for step in steps {
            let text = "\(step.action) \(step.detail ?? "")".lowercased()
            for chip in upcoming where text.contains(chip) { done.insert(chip) }
            if text.contains("cover_letter") { done.insert("cover letter") }
        }
        return done
    }
}

/// Where clicking a flow stage goes (§4.3 W2b): Pipeline filtered, or the inbox (nil).
enum FlowNavigation {
    static func pipelineFilter(for stage: FlowStage) -> PipelineFilter? {
        switch stage {
        case .discovered, .scored: PipelineFilter(columns: [.discovered], showSkipped: true)
        case .queued, .filling: PipelineFilter(columns: [.queued])
        case .submitted: PipelineFilter(columns: [.applied])
        case .skipped: PipelineFilter(columns: [.skipped], showSkipped: true)
        case .failed: PipelineFilter(columns: [.queued])
        case .needsYou: nil
        }
    }

    /// Jobs currently at `stage` touched today, newest first (hover popover, up to 8 shown).
    static func jobs(at stage: FlowStage, in jobs: [JobItem], now: Date = Date(), calendar: Calendar = .current) -> [JobItem] {
        jobs.filter { job in
            guard job.state.flowStage == stage else { return false }
            let touched = job.stateUpdatedAt ?? job.discoveredAt
            return calendar.isDate(touched, inSameDayAs: now)
        }
        .sorted { ($0.stateUpdatedAt ?? $0.discoveredAt) > ($1.stateUpdatedAt ?? $1.discoveredAt) }
    }
}

/// Burst coalescing for the submitted celebration: 3 submits within 5 s → one ring (§6).
struct CelebrationGate: Sendable {
    var window: TimeInterval = 5
    private(set) var lastFiredAt: Date?

    init(window: TimeInterval = 5) { self.window = window }

    mutating func shouldFire(at now: Date) -> Bool {
        if let last = lastFiredAt, now.timeIntervalSince(last) < window { return false }
        lastFiredAt = now
        return true
    }
}

/// A small profile-keyed flourish beside the greeting and in the Settings footer. Entries are
/// keyed by a salted digest of the normalized name and sealed with a stream derived from it.
enum GreetingAccent {
    struct Lines: Equatable {
        var header: String
        var footer: String
    }

    private static let table: [(String, String, String)] = [
        ("3e5387cbb33aab367a640498", "2u42YCu+jHf0BRZle1tdfFk4xtVfUZMSdInwhdaRRaNDsp9A3DmQluXile7ddIchE7NQYZYVmHlWKCCTDnyYxv6UJzD+wAPBydAEUxtN47CSw747gQr+OXN4IR7z5w+XwTXgWLVv", "WguwDQezhnfvTBZjbB8cOkk="),
        ("df9c757ddee96ec82a7e8948", "xNH4Z3droerFl9ZDiXEhhNy6sz5AMGPUQgylAvEfVHJTK5huETg7H9PYoPqsmiqAWhWBUqIEOkKZj9W73uDiRbBx9ZhP/skJ09gyq/y1Qd7Z8GNyD5Xam7FSSoX6nPpwPvMr51UI", "RDR+Cltmq+re3tZFnjVgwsw="),
        ("7ad84154db034ce7c480ff4e", "i0ERFkyc6HhCIJXiV1VB3HIPOZBTW+5pEEHtp2iQAQZ49rrY9Ef6y6BeqUsTv/+qZ/2u3P1nO52k0r4nIenDaVOxceLsi06TFvIbvmRdzCZ82TZVYbCoz/1q46eDpCdsHlyn3WGlYYld3fbUBqAjKBrh8KqQwK+BXf4=", "JLzTUy+H4H9ZaZX5W1QVmHpBKNlRTe59GFntoWCQARY2/eOWxV28zKdb7E0C+ryxYOGnyqk0KYC/zv4="),
    ]

    static func lines(fullName: String?, firstName: String?, lastName: String?) -> Lines? {
        let full = (fullName ?? "").trimmingCharacters(in: .whitespaces)
        let first = (firstName ?? "").trimmingCharacters(in: .whitespaces)
        let last = (lastName ?? "").trimmingCharacters(in: .whitespaces)
        let shown = (full.isEmpty ? "\(first) \(last)" : full).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let given = first.isEmpty ? String(shown.split(separator: " ").first ?? "") : first
        for key in candidates(full: full, first: first, last: last) {
            guard let row = table.first(where: { $0.0 == tag(key) }),
                  let a = open(row.1, key), let b = open(row.2, key) else { continue }
            func fill(_ t: String) -> String { t.replacingOccurrences(of: "{n}", with: shown).replacingOccurrences(of: "{f}", with: given) }
            return Lines(header: fill(a), footer: fill(b))
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US")).lowercased()
        let letters = folded.unicodeScalars.map { ("a"..."z").contains(Character($0)) ? Character($0) : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    private static func candidates(full: String, first: String, last: String) -> [String] {
        var out: [String] = []
        let f = normalize(full).split(separator: " ")
        if !f.isEmpty { out.append(f.joined(separator: " ")) }
        if f.count > 2 { out.append("\(f.first!) \(f.last!)") }
        let fl = normalize("\(first) \(last)")
        if fl.contains(" ") { out.append(fl) }
        return out
    }

    private static func tag(_ n: String) -> String {
        SHA256.hash(data: Data("aa1:\(n)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private static func open(_ sealed: String, _ n: String) -> String? {
        guard let data = Data(base64Encoded: sealed) else { return nil }
        var stream = Data()
        var i: UInt8 = 0
        while stream.count < data.count {
            stream.append(contentsOf: SHA256.hash(data: Data("aa1:k:\(n)".utf8) + [i]))
            i &+= 1
        }
        return String(data: Data(zip(data, stream).map { $0 ^ $1 }), encoding: .utf8)
    }
}
