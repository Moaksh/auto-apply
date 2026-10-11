// ActivityStore.swift — the activity log (append-only `events` table), incrementally loaded.
import Foundation
import Observation

@MainActor
@Observable
final class ActivityStore {
    /// Upper bound kept in memory (the Table virtualizes rendering).
    var maxRows = 100_000
    /// Rows in ascending id order (views typically show them reversed).
    private(set) var events: [ActivityEvent] = []
    private(set) var isLoaded = false
    /// Count of rows appended since load (follow-mode "12 new events ↑" pill).
    private(set) var appendedCount = 0

    init() {}

    var newestFirst: ReversedCollection<[ActivityEvent]> { events.reversed() }

    func apply(_ delta: ActivityDelta) {
        if delta.isInitial {
            events = delta.appended
            isLoaded = true
            return
        }
        guard !delta.appended.isEmpty else { return }
        events.append(contentsOf: delta.appended)
        appendedCount += delta.appended.count
        if events.count > maxRows { events.removeFirst(events.count - maxRows) }
    }

    func events(forJob jobID: Int) -> [ActivityEvent] { events.filter { $0.jobID == jobID } }
}
