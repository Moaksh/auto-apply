// DashboardModel.swift — pure presentation logic for the Dashboard (docs/UI_UX_PLAN.md §4):
// greeting, next-run label, hero state/verb, KPI captions, count-up policy. Views stay thin
// and every rule here is unit-tested (Tests/AutoApplyTests/C2).
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

    static func appliedTodayDelta(_ delta: Double) -> KPICard.Delta? {
        let rounded = Int(delta.rounded())
        guard rounded != 0 else { return nil }
        return KPICard.Delta(text: "\(abs(rounded))", isPositive: rounded > 0)
    }

    /// W5: delta between two rates in percentage points ("3pt"), nil when either is missing.
    static func responseRateDelta(current: Double?, previous: Double?) -> KPICard.Delta? {
        guard let current, let previous else { return nil }
        let points = Int(((current - previous) * 100).rounded())
        guard points != 0 else { return nil }
        return KPICard.Delta(text: "\(abs(points))pt", isPositive: points > 0)
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
    case prepping = "Prepping"
    case filling = "Filling"
    case waitingOnPage = "Waiting on page"
    case submitting = "Submitting"
    case paused = "Paused"
    case needsYou = "Needs you"
    case error = "Error"
    case doneForToday = "Done for today"
    case connecting = "Connecting"
    case unreachable = "Can't reach autoapplyd"

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

/// "Count up from 0 only on the first launch of the day" (§2.5).
enum CountUpPolicy {
    static let storageKey = "dashboard.lastCountUpDay"

    static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// True when today hasn't counted up yet.
    static func shouldCountUp(lastStamp: String?, now: Date, reduceMotion: Bool, calendar: Calendar = .current) -> Bool {
        guard !reduceMotion else { return false }
        return lastStamp != dayStamp(now, calendar: calendar)
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

/// Adaptive dashboard grid (§4.2): under 1100pt content width the KPI row goes 2×2 and charts
/// stack into a single column.
enum DashboardLayout: Equatable {
    case wide, narrow

    static let breakpoint: CGFloat = 1100

    init(contentWidth: CGFloat) {
        self = contentWidth < Self.breakpoint ? .narrow : .wide
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
