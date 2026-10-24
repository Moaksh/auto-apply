// OutreachActivityTests.swift — "what is outreach doing": the engine's meta rows decoded (and read
// through GRDB from the contract schema), the pure derivation into lines / row phases / sidebar
// state and its copy, the finished-scout toast, the mock daemon's staged progress, and the strip,
// rows and sidebar rendering (light / dark) with one primary action.
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AutoApply

private let schemaURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("contract/schema.sql")

@MainActor
@Suite("Outreach activity", .serialized)
struct OutreachActivityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private func search(_ id: String = "s1", kind: OutreachWork.Search.Kind = .startups, status: OutreachWork.Search.Status,
                        stage: String? = nil, step: Int? = nil, steps: Int? = nil, found: Int = 0, ycDone: Bool = false,
                        created: TimeInterval = -60, finished: TimeInterval? = nil) -> OutreachWork.Search {
        OutreachWork.Search(id: id, kind: kind, query: kind == .startups ? "Startups in India" : "devtools", location: kind == .startups ? "India" : nil,
                            status: status, stage: stage, step: step, steps: steps, found: found, ycDone: ycDone,
                            createdAt: now.addingTimeInterval(created), finishedAt: finished.map { now.addingTimeInterval($0) })
    }

    private func derive(_ work: OutreachWork, scouting: Set<Int> = [], recentlyQueued: [Int: Date] = [:]) -> OutreachActivity {
        OutreachActivity.derive(work: work, scouting: scouting, recentlyQueued: recentlyQueued,
                                companyName: { [7: "Patang AI", 8: "Lab0", 9: "Waybill"][$0] }, now: now)
    }

    // MARK: Decoding

    @Test func metaRowsDecode() {
        let searches = """
            [{"id":"a","kind":"startups","query":"Startups in India","location":"India","status":"queued","found":12,"yc_done":true,
              "created_at":"\(iso(now))"},
             {"id":"b","query":"devtools","status":"running","stage":"search","step":2,"steps":4,"found":0,"created_at":"\(iso(now))"},
             {"id":"bad"}]
            """
        let status = """
            {"state":"waiting","active":null,"people":{"reason":"daily_limit","resumes_at":"\(iso(now))"},
             "searches":{"reason":"browser_busy","resumes_at":null},"updated_at":"\(iso(now))"}
            """
        let w = OutreachWork.decode(searches: searches, googleQueue: #"[{"company_id":7,"purpose":"prospect"},{"company_id":7}]"#,
                                    referrerQueue: #"[{"company_id":9}]"#, status: status)
        #expect(w.searches.map(\.id) == ["a", "b"], "an odd item is skipped")
        #expect(w.searches[0].kind == .startups && w.searches[0].ycDone && w.searches[0].found == 12)
        #expect(w.searches[1].kind == .companies && w.searches[1].stage == "search" && w.searches[1].step == 2 && w.searches[1].steps == 4)
        #expect(w.googleQueue == [7] && w.referrerQueue == [9] && w.queuedCompanyIDs == [7, 9])
        #expect(w.google.state == .waiting && w.google.people?.reason == .dailyLimit && w.google.people?.resumesAt != nil)
        #expect(w.google.searches?.reason == .browserBusy)
        let running = OutreachWork.decode(searches: nil, googleQueue: nil, referrerQueue: nil,
                                          status: #"{"state":"running","active":{"kind":"people","company_id":8}}"#)
        #expect(running.google.active == .people(companyID: 8) && running.isEmpty == false)
        #expect(OutreachWork.decode(searches: "garbage", googleQueue: nil, referrerQueue: nil, status: nil).isEmpty)
    }

    @Test func grdbReadsTheMetaRowsWithCompanyNames() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aa-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("autoapply.db").path
        let writer = try DatabaseQueue(path: path)
        let sql = try String(contentsOf: schemaURL, encoding: .utf8)
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: sql)
        }
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO companies (id, name, normalized_name) VALUES (7, 'Patang AI', 'patang ai')")
            try db.execute(sql: """
                INSERT INTO meta (key, value, updated_at) VALUES
                ('outreach_google_queue', '[{"company_id":7,"purpose":"prospect"}]', '2026-10-24T00:00:00Z'),
                ('outreach_google_status', '{"state":"running","active":{"kind":"people","company_id":7}}', '2026-10-24T00:00:00Z'),
                ('outreach_prospect_searches', '[{"id":"x","kind":"startups","query":"Startups in India","location":"India","status":"running","stage":"yc","found":3,"created_at":"2026-10-24T00:00:00Z"}]', '2026-10-24T00:00:00Z')
                """)
        }
        let repo = GRDBRepository(path: path, pollInterval: .milliseconds(50))
        let data = try #require(await collect(repo.outreach(), count: 1).first)
        #expect(data.work.googleQueue == [7] && data.work.companyNames[7] == "Patang AI")
        #expect(data.work.google.active == .people(companyID: 7))
        #expect(data.work.searches.first?.found == 3 && data.work.searches.first?.stage == "yc")
    }

    // MARK: Derivation and copy

    @Test func startupSearchStages() {
        var w = OutreachWork()
        w.searches = [search(status: .running, stage: "yc", found: 12)]
        var a = derive(w)
        #expect(a.lines.map(\.text) == ["Looking for startups in India · YC's directory: 12 found so far"])
        #expect(a.lines[0].phase == .working && a.isWorking && a.isActive)

        w.searches = [search(status: .queued, found: 12, ycDone: true)]
        w.google = .init(state: .waiting, searches: .init(reason: .browserBusy))
        a = derive(w)
        #expect(a.lines[0].text == "Looking for startups in India · YC's directory: 12 found · funding news: waiting while I use the browser to apply, then I'll start")
        #expect(a.lines[0].phase == .waiting && !a.isWorking && a.isActive)

        w.google = .init(state: .waiting, searches: .init(reason: .dailyLimit, resumesAt: now.addingTimeInterval(3600)))
        #expect(derive(w).lines[0].text.hasSuffix("funding news: today's Google limit is used, I'll continue tomorrow"))

        w.searches = [search(status: .running, stage: "news", step: 2, steps: 3, found: 12, ycDone: true)]
        w.google = .init(state: .running, active: .search(id: "s1"), updatedAt: now)
        a = derive(w)
        #expect(a.lines[0].text == "Looking for startups in India · YC's directory: 12 found · reading funding news (2 of 3)")
        #expect(a.lines[0].phase == .working)

        w.searches = [search(status: .running, stage: "saving", found: 12, ycDone: true)]
        #expect(derive(w).lines[0].text.hasSuffix("checking the companies in the news"))

        w.searches = [search(status: .done, found: 14, ycDone: true, finished: -120)]
        w.google = .init()
        a = derive(w)
        #expect(a.lines.map(\.text) == ["Found 14 startups in India"] && a.lines[0].phase == .done)
        #expect(!a.isActive && !a.isWorking && a.summary == nil, "a result is not work in progress")

        w.searches = [search(status: .done, found: 14, finished: -(OutreachActivity.recentWindow + 5))]
        #expect(derive(w).isEmpty, "then it goes quiet")
        w.searches = [search(status: .done, found: 0, finished: -5)]
        #expect(derive(w).lines[0].text.hasPrefix("No new startups in India this time"))
    }

    @Test func companySearchAndQueueOrder() {
        var w = OutreachWork()
        w.searches = [search("q", kind: .companies, status: .queued)]
        #expect(derive(w).lines[0].text == "Searching for “devtools”: waiting for the browser, I'll start when it's free")
        // Behind other Google work right now: it's simply next.
        w.google = .init(state: .running, active: .people(companyID: 7), updatedAt: now)
        #expect(derive(w).lines.first { $0.id == "q" }?.text == "Searching for “devtools”: next, after the Google results I'm reading now")
        w.searches = [search("q", kind: .companies, status: .running, stage: "search", step: 1, steps: 4)]
        w.google = .init(state: .running, active: .search(id: "q"), updatedAt: now)
        #expect(derive(w).lines[0].text == "Searching for “devtools” · reading Google results (1 of 4)")
        w.searches = [search("q", kind: .companies, status: .done, found: 5, finished: -1)]
        w.google = .init()
        #expect(derive(w).lines[0].text == "Found 5 companies for “devtools”")
    }

    @Test func peoplePhases() {
        var w = OutreachWork()
        w.googleQueue = [7, 9]
        w.google = .init(state: .running, active: .people(companyID: 7), updatedAt: now)
        var a = derive(w, scouting: [8])
        #expect(a.scouts == [7: .googleRunning, 8: .site, 9: .googleQueued(nil)])
        #expect(a.lines.first { $0.id == "people-working" }?.text == "Finding people at Lab0 and Patang AI")
        #expect(a.lines.first { $0.id == "people-queued" }?.text
                == "Google results for people at Waybill: next, after the Google results I'm reading now")
        #expect(a.lines.first?.phase == .working, "work in progress is listed first")

        w.google = .init(state: .waiting, people: .init(reason: .paused))
        a = derive(w)
        #expect(a.scouts[7] == .googleQueued(.init(reason: .paused)) && !a.isWorking && a.isActive)
        #expect(a.lines.first { $0.id == "people-queued" }?.text.hasSuffix("paused. Resume me to continue") == true)

        // The moment after a site scout ends, before the DB shows the queue.
        a = derive(OutreachWork(), recentlyQueued: [9: now.addingTimeInterval(-1)])
        #expect(a.scouts[9] == .googleQueued(.init(reason: .nextTurn)))
        #expect(derive(OutreachWork(), recentlyQueued: [9: now.addingTimeInterval(-60)]).isEmpty)

        var r = OutreachWork()
        r.referrerQueue = [9]
        #expect(derive(r).lines.map(\.text) == ["People who could refer you at Waybill: waiting for the browser, I'll start when it's free"])
    }

    @Test func staleStatesAreNotShownAsRunning() {
        var w = OutreachWork()
        w.searches = [search(status: .running, stage: "yc", created: -(OutreachActivity.staleYC + 60))]
        #expect(derive(w).isEmpty, "a YC stage cut short by a stopped agent")
        w.searches = []
        w.googleQueue = [7]
        w.google = .init(state: .running, active: .people(companyID: 7), updatedAt: now.addingTimeInterval(-(OutreachActivity.staleRunning + 60)))
        #expect(derive(w).scouts[7] == .googleQueued(.init(reason: .nextTurn)))
    }

    @Test func waitAndResultCopy() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let later = OutreachActivity.waitText(.init(reason: .resting, resumesAt: now.addingTimeInterval(600)), now: now, calendar: cal)
        #expect(later.hasPrefix("Google asked me to slow down, I'll try again "))
        #expect(OutreachActivity.waitText(.init(reason: .off), now: now).contains("Settings"))
        #expect(OutreachActivity.list(["A", "B", "C", "D", "E"]) == "A, B and 3 more")
        let p = { (found: Int, email: Int, q: Bool) in ScoutFinishedPayload(companyId: 1, found: found, withEmail: email, queuedGoogle: q) }
        #expect(OutreachActivity.scoutResult(p(3, 3, false), company: "Patang AI") == "Found 3 people at Patang AI")
        #expect(OutreachActivity.scoutResult(p(3, 2, false), company: "X") == "Found 3 people at X, 2 with an email")
        #expect(OutreachActivity.scoutResult(p(1, 0, false), company: "X") == "Found 1 person at X, no email yet")
        #expect(OutreachActivity.scoutResult(p(0, 0, false), company: "X") == "No one with an email at X yet")
        #expect(OutreachActivity.scoutResult(p(0, 0, true), company: "X") == "No one on X's site yet · I'll check Google results next")
    }

    // MARK: Store

    @Test func aFinishedScoutTheAppFollowsGetsAToast() {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository)
        store.apply(EventEnvelope(replyTo: nil, event: .scoutFinished(ScoutFinishedPayload(companyId: 42, found: 1, withEmail: 1))))
        #expect(store.toasts.current == nil, "a scout nobody is watching stays quiet")
        store.outreach.beginScouting(companyID: 42)
        #expect(store.outreach.activity().scouts[42] == .site)
        store.apply(EventEnvelope(replyTo: nil, event: .scoutFinished(ScoutFinishedPayload(companyId: 42, found: 3, withEmail: 3, queuedGoogle: true))))
        let messages = ([store.toasts.current] + store.toasts.queue).compactMap { $0?.message }
        #expect(messages.contains("Found 3 people at the company · I'll check Google results next"))
        #expect(!store.outreach.scouting.contains(42))
        #expect(store.outreach.activity().scouts[42] == .googleQueued(.init(reason: .nextTurn)), "Google half queued, not forgotten")
    }

    func mockStore(speed: Double = 50) async -> AppStore {
        let daemon = MockDaemon(scenario: .idle, speed: speed)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await waitUntil(timeout: .seconds(20)) { store.hasSnapshot && store.outreach.isLoaded && store.isConnected }
        return store
    }

    @Test func mockSimulatesSearchStagesAndPeople() async {
        let store = await mockStore(speed: 5)
        #expect(await store.discoverStartups(location: "Bangalore, India", ycOnly: false, hiringOnly: false, stages: []))
        #expect(await waitUntil(timeout: .seconds(20)) {
            store.outreach.activity().lines.contains { $0.phase != .done && $0.text.hasPrefix("Looking for startups in Bangalore, India") }
        })
        #expect(await waitUntil(timeout: .seconds(30)) {
            store.outreach.activity().lines.contains { $0.phase == .done && $0.text.hasPrefix("Found ") && $0.text.hasSuffix("in Bangalore, India") }
        })
        #expect(await store.scoutTopProspects(limit: 2) == 2)
        #expect(await waitUntil(timeout: .seconds(20)) { !store.outreach.activity().scouts.isEmpty })
        #expect(await waitUntil(timeout: .seconds(40)) {
            store.outreach.data.work.googleQueue.isEmpty && store.outreach.activity().scouts.isEmpty
                && store.outreach.data.work.google.state == .idle
        })
        await store.stop()
    }

    // MARK: Render

    private func render<V: View>(store: AppStore, scheme: ColorScheme, @ViewBuilder _ view: () -> V) -> (CGImage?, Int) {
        let audit = ProminenceAudit()
        let content = view()
            .appEnvironment(store, simulateReduceMotion: true)
            .environment(\.prominenceAudit, audit)
            .environment(\.colorScheme, scheme)
            .frame(width: 1200, height: 900)
            .background(Palette.windowBackground)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return (renderer.cgImage, audit.count)
    }

    @Test func stripRowsAndSidebarRenderWithOnePrimary() async {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await waitUntil(timeout: .seconds(20)) { store.outreach.isLoaded && !store.outreach.activeProspects.isEmpty }
        let ids = store.outreach.activeProspects.prefix(2).map(\.companyID)
        daemon.repository.update { data in
            data.outreach.work.searches = [OutreachWork.Search(id: "r", kind: .startups, query: "Startups in India", location: "India",
                                                               status: .running, stage: "news", step: 2, steps: 3, found: 12, ycDone: true,
                                                               createdAt: Date())]
            data.outreach.work.googleQueue = ids
            data.outreach.work.google = .init(state: .running, active: .search(id: "r"), updatedAt: Date())
        }
        _ = await waitUntil(timeout: .seconds(20)) { store.outreach.data.work.googleQueue == ids }
        #expect(store.outreach.activity().isWorking)
        for scheme in [ColorScheme.light, .dark] {
            let model = ColdEmailModel(store: store)
            model.tab = .prospects
            model.selectedProspectID = store.outreach.activeProspects.first?.id
            let (image, primaries) = render(store: store, scheme: scheme) { ColdEmailView(modelOverride: model) }
            #expect(image != nil)
            #expect(primaries == 1, "Companies with activity shows \(primaries) primary actions")
            #expect(render(store: store, scheme: scheme) { SidebarView().environment(store.router) }.0 != nil)
            #expect(render(store: store, scheme: scheme) {
                VStack {
                    OutreachActivityLines(activity: store.outreach.activity())
                    ScoutPhaseTag(phase: .googleQueued(.init(reason: .dailyLimit)))
                    ScoutPhaseNote(phase: .site, company: "Patang AI")
                }
            }.0 != nil)
        }
        await store.stop()
    }
}
