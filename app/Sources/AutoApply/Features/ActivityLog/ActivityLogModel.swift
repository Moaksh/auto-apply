// ActivityLogModel.swift — the Activity log's filtering and follow mode (docs/UI_UX_PLAN.md
// §5.11). Built for 100k rows: filtering is incremental (only newly appended rows are tested
// when the filter is unchanged), the displayed collection is a reversed slice (no copies),
// and pausing follow freezes the visible rows so the table never shifts under the reader.
import AppKit
import Foundation
import Observation

enum ActivityRules {
    // MARK: Filtering

    static func matches(_ e: ActivityEvent, filter: ActivityFilter, runID: Int?, jobLabel: (Int) -> String?,
                        calendar: Calendar = .current) -> Bool {
        switch filter.scope {
        case .all: break
        case .agent: if e.actor == .user { return false }
        case .you: if e.actor != .user { return false }
        case .errors: if !isError(e) { return false }
        }
        if let jobID = filter.jobID, e.jobID != jobID { return false }
        if let runID, e.runID != runID { return false }
        if let day = filter.day, !calendar.isDate(e.ts, inSameDayAs: day) { return false }
        let q = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let label = e.jobID.flatMap(jobLabel) ?? ""
            for term in q.split(separator: " ") {
                if e.message.range(of: term, options: .caseInsensitive) == nil
                    && e.kind.range(of: term, options: .caseInsensitive) == nil
                    && label.range(of: term, options: .caseInsensitive) == nil {
                    return false
                }
            }
        }
        return true
    }

    static func isError(_ e: ActivityEvent) -> Bool {
        e.level == .error || e.kind.lowercased() == "error"
    }

    // MARK: Presentation

    /// Fixed-width uppercase tag ("FILL   ") and its status tint.
    static func tag(for e: ActivityEvent) -> (text: String, kind: StatusKind?) {
        let label = e.kind.uppercased().replacingOccurrences(of: "_", with: " ")
        let padded = label.count >= 7 ? String(label.prefix(7)) : label.padding(toLength: 7, withPad: " ", startingAt: 0)
        if isError(e) { return (padded, .error) }
        let kind: StatusKind? = switch e.kind.lowercased() {
        case "discover": .discovered
        case "score", "queue", "queued": .queued
        case "skip": .skipped
        case "fill", "resume", "cover_letter", "prep": .filling
        case "ask", "question": .needsYou
        case "submit", "approve": .applied
        case "status": .interview
        case "nudge", "ghost": .ghosted
        default: e.level == .warning ? .needsYou : nil
        }
        return (padded, kind)
    }

    /// "14:02:40.118" in the user's time zone.
    static func timestamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }

    /// "stripe/backend-engineer".
    static func slug(company: String, title: String) -> String {
        func clean(_ s: String) -> String {
            let allowed = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            return String(allowed).split(separator: "-").joined(separator: "-")
        }
        let t = clean(title)
        return "\(clean(company).replacingOccurrences(of: "-", with: ""))/\(t.count > 18 ? String(t.prefix(18)) : t)"
    }

    /// Pretty, key-sorted JSON for the inspector.
    static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// "Copy diagnostic" text for an error row.
    static func diagnostic(for e: ActivityEvent, jobLabel: String?) -> String {
        var lines = [
            "AutoApply diagnostic",
            "time: \(ProtocolCoding.formatDate(e.ts))",
            "kind: \(e.kind)  level: \(e.level.rawValue)  actor: \(e.actor.rawValue)",
        ]
        if let jobLabel { lines.append("job: \(jobLabel) (#\(e.jobID ?? 0))") }
        if let app = e.applicationID { lines.append("application: #\(app)") }
        if let run = e.runID { lines.append("run: #\(run)") }
        lines.append("message: \(e.message)")
        lines.append("payload:")
        lines.append(prettyJSON(e.payload))
        return lines.joined(separator: "\n")
    }

    /// Index of the first element with id > `id` in an ascending-by-id array.
    static func firstIndex(after id: Int, in rows: [ActivityEvent]) -> Int {
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].id <= id { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

@MainActor
@Observable
final class ActivityLogModel {
    /// Shared by the screen and its inspector (one main window).
    static let shared = ActivityLogModel()

    /// Filtered rows, ascending id (oldest first).
    private(set) var rows: [ActivityEvent] = []
    /// Follow mode: new rows appear at the top. Off = the view is frozen at `frozenUpToID`.
    private(set) var isFollowing = true
    private(set) var frozenUpToID: Int?
    var selection: ActivityEvent.ID?
    var runID: Int?
    /// Bumped when the view should scroll back to the newest row.
    private(set) var scrollToTopRequest = 0

    @ObservationIgnored private var lastKey: Key?
    @ObservationIgnored private var lastSourceFirstID: Int?
    @ObservationIgnored private var lastSourceLastID: Int?
    @ObservationIgnored private var generation = 0
    /// True while an off-main recompute for `lastKey` has not yet published.
    @ObservationIgnored private var recomputeInFlight = false
    /// Latest events seen while a recompute was in flight; replayed incrementally on publish so
    /// rows that arrive mid-recompute are not lost.
    @ObservationIgnored private var deferredSync: (events: [ActivityEvent], jobLabel: (Int) -> String?)?
    /// Above this many source rows a full recompute runs off the main actor.
    @ObservationIgnored var backgroundThreshold = 20_000

    struct Key: Equatable, Sendable {
        var filter: ActivityFilter
        var runID: Int?
    }

    init() {}

    // MARK: Displayed rows

    /// Count of rows visible in the table (all rows when following).
    var visibleCount: Int {
        guard let frozen = frozenUpToID else { return rows.count }
        return ActivityRules.firstIndex(after: frozen, in: rows)
    }

    /// Newest first, without copying.
    var displayed: ReversedCollection<ArraySlice<ActivityEvent>> { rows[..<visibleCount].reversed() }

    /// "12 new events ↑" while follow is paused.
    var newEventCount: Int { rows.count - visibleCount }

    var selectedEvent: ActivityEvent? {
        guard let selection else { return nil }
        let i = ActivityRules.firstIndex(after: selection - 1, in: rows)
        return i < rows.count && rows[i].id == selection ? rows[i] : nil
    }

    // MARK: Follow

    func pauseFollow() {
        guard isFollowing else { return }
        isFollowing = false
        frozenUpToID = rows.last?.id ?? 0
    }

    func resumeFollow() {
        isFollowing = true
        frozenUpToID = nil
        scrollToTopRequest += 1
    }

    func toggleFollow() { isFollowing ? pauseFollow() : resumeFollow() }

    // MARK: Sync

    /// Bring `rows` up to date with the store's events (ascending id) under `filter`.
    /// Appends incrementally when only new rows arrived; otherwise recomputes.
    func sync(events: [ActivityEvent], filter: ActivityFilter, jobLabel: @escaping (Int) -> String?, forceSynchronous: Bool = false) {
        let key = Key(filter: filter, runID: runID)
        let first = events.first?.id
        let last = events.last?.id
        if key == lastKey, recomputeInFlight, !forceSynchronous {
            // `rows` still reflects the previous filter; appending to it would be clobbered by the
            // pending publish. Remember the newest events and catch up once it lands.
            deferredSync = (events, jobLabel)
            return
        }
        if key == lastKey, let lastFirst = lastSourceFirstID, let lastLast = lastSourceLastID, let first, let last,
           first >= lastFirst, last >= lastLast {
            if first > lastFirst, let cut = rows.firstIndex(where: { $0.id >= first }) {
                rows.removeFirst(cut)   // the store trimmed its oldest rows (maxRows)
            } else if first > lastFirst {
                rows.removeAll()
            }
            if last > lastLast {
                let start = ActivityRules.firstIndex(after: lastLast, in: events)
                let fresh = events[start...].filter { ActivityRules.matches($0, filter: filter, runID: key.runID, jobLabel: jobLabel) }
                if !fresh.isEmpty { rows.append(contentsOf: fresh) }
            }
            lastSourceFirstID = first
            lastSourceLastID = last
            return
        }
        lastKey = key
        lastSourceFirstID = first
        lastSourceLastID = last
        generation += 1
        let gen = generation
        deferredSync = nil
        if forceSynchronous || events.count <= backgroundThreshold {
            recomputeInFlight = false
            rows = events.filter { ActivityRules.matches($0, filter: filter, runID: key.runID, jobLabel: jobLabel) }
            afterRecompute()
            return
        }
        // Large logs: filter off-main with a snapshot of job labels, then publish if current.
        let ids = Set(events.compactMap(\.jobID))
        var labels: [Int: String] = [:]
        if !filter.searchText.isEmpty { for id in ids { labels[id] = jobLabel(id) } }
        let snapshot = events
        let frozenLabels = labels
        recomputeInFlight = true
        Task.detached(priority: .userInitiated) {
            let filtered = snapshot.filter { ActivityRules.matches($0, filter: filter, runID: key.runID, jobLabel: { frozenLabels[$0] }) }
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.rows = filtered
                self.recomputeInFlight = false
                self.afterRecompute()
                // lastSourceFirstID/LastID already describe `snapshot`, so this takes the
                // incremental path and appends only what arrived during the recompute.
                if let deferred = self.deferredSync {
                    self.deferredSync = nil
                    self.sync(events: deferred.events, filter: filter, jobLabel: deferred.jobLabel)
                }
            }
        }
    }

    /// Test hook: forget the incremental state.
    func invalidate() {
        recomputeInFlight = false
        deferredSync = nil
        lastKey = nil
        lastSourceFirstID = nil
        lastSourceLastID = nil
    }

    private func afterRecompute() {
        if let frozen = frozenUpToID, let last = rows.last?.id, frozen > last { frozenUpToID = last }
        if let selection, selectedEvent == nil { self.selection = nil }
    }

    // MARK: Actions

    func copyDiagnostic(_ e: ActivityEvent, jobLabel: String?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ActivityRules.diagnostic(for: e, jobLabel: jobLabel), forType: .string)
    }
}
