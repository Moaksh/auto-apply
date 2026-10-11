// ActivityLogTests.swift — scope/search/day/run filtering, tags and formatting, incremental
// sync == full recompute, trimming, follow-mode freezing, and 100k-row performance.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("C2 · Activity log", .serialized)
struct ActivityLogTests {
    let labels: (Int) -> String? = { id in id == 1 ? "stripe/backend-engineer" : (id == 2 ? "ramp/platform" : nil) }

    var sample: [ActivityEvent] {
        [
            C2.event(id: 1, kind: "discover", jobID: 1, message: "found Backend Engineer via Greenhouse"),
            C2.event(id: 2, kind: "fill", jobID: 1, runID: 7, message: "answered \"Years with Go\" = 4"),
            C2.event(id: 3, kind: "status", actor: .user, jobID: 2, message: "moved to Interview"),
            C2.event(id: 4, kind: "error", level: .error, jobID: 2, runID: 7, message: "selector timeout on step 5"),
            C2.event(id: 5, ts: Samples.now.addingTimeInterval(-3 * 86_400), kind: "skip", jobID: nil, message: "64 below threshold"),
        ]
    }

    func ids(_ filter: ActivityFilter, runID: Int? = nil) -> [Int] {
        sample.filter { ActivityRules.matches($0, filter: filter, runID: runID, jobLabel: labels, calendar: C2.utc) }.map(\.id)
    }

    @Test func scopesSearchDayJobAndRun() {
        #expect(ids(ActivityFilter()) == [1, 2, 3, 4, 5])
        #expect(ids(ActivityFilter(scope: .agent)) == [1, 2, 4, 5])
        #expect(ids(ActivityFilter(scope: .you)) == [3])
        #expect(ids(ActivityFilter(scope: .errors)) == [4])
        #expect(ids(ActivityFilter(searchText: "years go")) == [2], "all terms must match")
        #expect(ids(ActivityFilter(searchText: "ramp")) == [3, 4], "matches the job slug")
        #expect(ids(ActivityFilter(searchText: "FILL")) == [2], "matches the kind, case-insensitive")
        #expect(ids(ActivityFilter(day: Samples.now)) == [1, 2, 3, 4])
        #expect(ids(ActivityFilter(jobID: 2)) == [3, 4])
        #expect(ids(ActivityFilter(), runID: 7) == [2, 4])
    }

    @Test func tagsTimestampsAndSlugs() {
        let fill = ActivityRules.tag(for: C2.event(id: 1, kind: "fill"))
        #expect(fill.text == "FILL   ")
        #expect(fill.kind == .filling)
        #expect(ActivityRules.tag(for: C2.event(id: 1, kind: "submit")).kind == .applied)
        #expect(ActivityRules.tag(for: C2.event(id: 1, kind: "fill", level: .error)).kind == .error)
        #expect(ActivityRules.tag(for: C2.event(id: 1, kind: "cover_letter")).text == "COVER L")
        #expect(ActivityRules.tag(for: C2.event(id: 1, kind: "log")).kind == nil)
        let t = C2.utc.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 14, minute: 2, second: 40, nanosecond: 118_000_000))!
        #expect(ActivityRules.timestamp(t, calendar: C2.utc) == "14:02:40.118")
        #expect(ActivityRules.slug(company: "Grafana Labs", title: "Backend Engineer, Payments") == "grafanalabs/backend-engineer-p")
        #expect(ActivityRules.slug(company: "Stripe", title: "SRE") == "stripe/sre")
    }

    @Test func diagnosticIncludesPayload() {
        var e = C2.event(id: 4, kind: "error", level: .error, jobID: 2, runID: 7, message: "selector timeout")
        e.payload = .object(["step": .int(5), "selector": .string("#submit")])
        let text = ActivityRules.diagnostic(for: e, jobLabel: "Ramp · Platform")
        #expect(text.contains("message: selector timeout"))
        #expect(text.contains("job: Ramp · Platform (#2)"))
        #expect(text.contains("\"selector\" : \"#submit\""))
    }

    @Test func binarySearchFirstIndexAfter() {
        let rows = [1, 3, 5, 9].map { C2.event(id: $0) }
        #expect(ActivityRules.firstIndex(after: 0, in: rows) == 0)
        #expect(ActivityRules.firstIndex(after: 3, in: rows) == 2)
        #expect(ActivityRules.firstIndex(after: 4, in: rows) == 2)
        #expect(ActivityRules.firstIndex(after: 9, in: rows) == 4)
        #expect(ActivityRules.firstIndex(after: 5, in: []) == 0)
    }

    @Test func incrementalSyncMatchesFullRecompute() {
        let model = ActivityLogModel()
        var events = Array(sample.sorted { $0.id < $1.id })
        let filter = ActivityFilter(scope: .agent)
        model.sync(events: events, filter: filter, jobLabel: labels, forceSynchronous: true)
        #expect(model.rows.map(\.id) == [1, 2, 4, 5])
        events.append(C2.event(id: 6, kind: "score", jobID: 1))
        events.append(C2.event(id: 7, kind: "status", actor: .user, jobID: 1))
        model.sync(events: events, filter: filter, jobLabel: labels)
        #expect(model.rows.map(\.id) == [1, 2, 4, 5, 6])
        let full = ActivityLogModel()
        full.sync(events: events, filter: filter, jobLabel: labels, forceSynchronous: true)
        #expect(full.rows == model.rows)
        // Store trimmed its oldest rows.
        model.sync(events: Array(events.dropFirst(2)), filter: filter, jobLabel: labels)
        #expect(model.rows.map(\.id) == [4, 5, 6])
        // Filter change recomputes.
        model.sync(events: events, filter: ActivityFilter(scope: .you), jobLabel: labels)
        #expect(model.rows.map(\.id) == [3, 7])
        #expect(model.displayed.map(\.id) == [7, 3], "newest first")
    }

    @Test func followModeFreezesVisibleRowsAndCountsNewOnes() {
        let model = ActivityLogModel()
        var events = (1...5).map { C2.event(id: $0) }
        model.sync(events: events, filter: ActivityFilter(), jobLabel: labels)
        #expect(model.isFollowing && model.newEventCount == 0)
        model.pauseFollow()
        events += (6...17).map { C2.event(id: $0) }
        model.sync(events: events, filter: ActivityFilter(), jobLabel: labels)
        #expect(model.rows.count == 17)
        #expect(model.visibleCount == 5)
        #expect(model.newEventCount == 12)
        #expect(model.displayed.first?.id == 5, "the table doesn't shift while reading")
        let request = model.scrollToTopRequest
        model.resumeFollow()
        #expect(model.newEventCount == 0 && model.displayed.first?.id == 17)
        #expect(model.scrollToTopRequest == request + 1)
    }

    @Test func selectionLookupAndClearing() {
        let model = ActivityLogModel()
        model.sync(events: sample.sorted { $0.id < $1.id }, filter: ActivityFilter(), jobLabel: labels, forceSynchronous: true)
        model.selection = 4
        #expect(model.selectedEvent?.message == "selector timeout on step 5")
        model.sync(events: sample.sorted { $0.id < $1.id }, filter: ActivityFilter(scope: .you), jobLabel: labels, forceSynchronous: true)
        #expect(model.selection == nil, "selection cleared when filtered out")
    }

    @Test func hundredThousandRowsStayFast() async {
        let base = Samples.now
        let events = (1...100_000).map { i in
            ActivityEvent(id: i, ts: base.addingTimeInterval(Double(i) * 0.5), kind: i % 97 == 0 ? "error" : "fill",
                          level: i % 97 == 0 ? .error : .info, jobID: i % 50, message: "FILL answered question \(i)")
        }
        let model = ActivityLogModel()
        let clock = ContinuousClock()
        let full = clock.measure {
            model.sync(events: events, filter: ActivityFilter(scope: .errors), jobLabel: { _ in nil }, forceSynchronous: true)
        }
        #expect(model.rows.count == 100_000 / 97)
        #expect(full < .seconds(2), "full 100k filter took \(full)")

        // Appending to a 100k log only tests the new rows.
        var more = events
        more.append(ActivityEvent(id: 100_001, ts: base, kind: "error", level: .error, message: "new"))
        let incremental = clock.measure {
            model.sync(events: more, filter: ActivityFilter(scope: .errors), jobLabel: { _ in nil })
        }
        #expect(model.rows.last?.id == 100_001)
        #expect(incremental < .milliseconds(50), "incremental append took \(incremental)")

        // The displayed collection is a lazy reversed slice: indexing is O(1).
        let display = clock.measure { _ = model.displayed.first; _ = model.displayed.count }
        #expect(display < .milliseconds(5))

        // Background path for large logs publishes when done.
        let bg = ActivityLogModel()
        bg.backgroundThreshold = 10_000
        bg.sync(events: events, filter: ActivityFilter(searchText: "question 100000"), jobLabel: { _ in nil })
        #expect(await waitUntil(timeout: .seconds(10)) { bg.rows.map(\.id) == [100_000] })
    }

    @Test func eventsArrivingDuringBackgroundRecomputeAreKept() async {
        let base = Samples.now
        func ev(_ i: Int) -> ActivityEvent {
            ActivityEvent(id: i, ts: base.addingTimeInterval(Double(i)), kind: "fill", level: .info, jobID: 1, message: "row \(i)")
        }
        var events = (1...5_000).map(ev)
        let model = ActivityLogModel()
        model.backgroundThreshold = 10
        model.sync(events: events, filter: ActivityFilter(), jobLabel: { _ in nil }, forceSynchronous: true)
        // Filter change → off-main recompute; rows arrive before it publishes.
        model.sync(events: events, filter: ActivityFilter(searchText: "row"), jobLabel: { _ in nil })
        events.append(ev(5_001)); events.append(ev(5_002))
        model.sync(events: events, filter: ActivityFilter(searchText: "row"), jobLabel: { _ in nil })
        #expect(await waitUntil(timeout: .seconds(10)) { model.rows.last?.id == 5_002 })
        #expect(model.rows.count == 5_002)
        // And the incremental path keeps working afterwards.
        events.append(ev(5_003))
        model.sync(events: events, filter: ActivityFilter(searchText: "row"), jobLabel: { _ in nil })
        #expect(model.rows.last?.id == 5_003)
        #expect(model.rows.count == 5_003)
    }
}
