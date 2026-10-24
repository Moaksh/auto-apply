// OutreachActivity.swift — what cold outreach is doing right now, in words. The engine keeps its
// work in `meta` (contract §5.1.3 "Progress the app reads"): company searches and startup searches
// with their stage, the companies waiting for Google results (people, referrers), and why that
// Google work waits. `OutreachWork` is that raw state (read live with the rest of OutreachData);
// `OutreachActivity.derive` turns it, plus the scouts this app started, into the lines the
// Companies tab, the prospect rows and the sidebar show. Pure, so it is unit tested.
import Foundation

/// The engine's outreach work, as stored in `meta`.
struct OutreachWork: Sendable, Hashable {
    struct Search: Identifiable, Sendable, Hashable {
        enum Kind: Sendable, Hashable { case startups, companies }
        enum Status: String, Sendable, Hashable { case queued, running, done }

        var id: String
        var kind: Kind
        var query: String
        var location: String?
        var status: Status
        /// "yc", then "news" / "search" (Google result page `step` of `steps`), then "saving".
        var stage: String?
        var step: Int?
        var steps: Int?
        var found = 0
        var ycOnly = false
        var ycDone = false
        var ycFallback = false
        var createdAt: Date
        var finishedAt: Date?
    }

    /// Why queued Google work waits (`outreach_google_status.people|searches.reason`).
    enum WaitReason: String, Sendable, Hashable {
        case paused
        case browserBusy = "browser_busy"
        case dailyLimit = "daily_limit"
        case resting
        case off
        case nextTurn = "next_turn"
    }

    struct Wait: Sendable, Hashable {
        var reason: WaitReason
        var resumesAt: Date?
    }

    struct GoogleStatus: Sendable, Hashable {
        enum State: String, Sendable, Hashable { case running, waiting, idle }
        enum Active: Sendable, Hashable {
            case people(companyID: Int)
            case referrers(companyID: Int)
            case search(id: String)
        }

        var state: State = .idle
        var active: Active?
        var people: Wait?
        var searches: Wait?
        var updatedAt: Date?
    }

    /// Newest last, as the engine appends them.
    var searches: [Search] = []
    /// Companies whose Google half of "Find people" is queued.
    var googleQueue: [Int] = []
    /// Companies with a "who could refer you" search queued.
    var referrerQueue: [Int] = []
    var google = GoogleStatus()
    /// Names of the companies in the queues (they may not be prospects).
    var companyNames: [Int: String] = [:]

    var isEmpty: Bool { searches.isEmpty && googleQueue.isEmpty && referrerQueue.isEmpty && google.state == .idle }

    /// Every company id the queues mention (the repository looks their names up).
    var queuedCompanyIDs: Set<Int> {
        var ids = Set(googleQueue).union(referrerQueue)
        switch google.active {
        case .people(let id)?, .referrers(let id)?: ids.insert(id)
        default: break
        }
        return ids
    }

    // MARK: Decoding the meta values (lenient: an odd item is skipped, never fatal)

    static func decode(searches: String?, googleQueue: String?, referrerQueue: String?, status: String?) -> OutreachWork {
        var out = OutreachWork()
        if case .array(let items) = DBJSON.decode(JSONValue.self, from: searches, default: .array([])) {
            out.searches = items.compactMap(search)
        }
        out.googleQueue = companyIDs(DBJSON.decode(JSONValue.self, from: googleQueue, default: .array([])))
        out.referrerQueue = companyIDs(DBJSON.decode(JSONValue.self, from: referrerQueue, default: .array([])))
        if case .object(let o) = DBJSON.decode(JSONValue.self, from: status, default: .null) {
            out.google = google(o)
        }
        return out
    }

    private static func companyIDs(_ v: JSONValue) -> [Int] {
        guard case .array(let items) = v else { return [] }
        var seen = Set<Int>()
        return items.compactMap { item in
            guard case .object(let o) = item, let id = o["company_id"]?.intValue, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    private static func search(_ v: JSONValue) -> Search? {
        guard case .object(let o) = v, let id = o["id"]?.stringValue,
              let status = o["status"]?.stringValue.flatMap(Search.Status.init(rawValue:)) else { return nil }
        return Search(id: id, kind: o["kind"]?.stringValue == "startups" ? .startups : .companies,
                      query: o["query"]?.stringValue ?? "", location: o["location"]?.stringValue, status: status,
                      stage: o["stage"]?.stringValue, step: o["step"]?.intValue, steps: o["steps"]?.intValue,
                      found: o["found"]?.intValue ?? 0, ycOnly: o["yc_only"]?.boolValue ?? false,
                      ycDone: o["yc_done"]?.boolValue ?? false, ycFallback: o["yc_fallback"]?.boolValue ?? false,
                      createdAt: DBJSON.date(o["created_at"]?.stringValue) ?? .distantPast,
                      finishedAt: DBJSON.date(o["finished_at"]?.stringValue))
    }

    private static func google(_ o: [String: JSONValue]) -> GoogleStatus {
        func wait(_ v: JSONValue?) -> Wait? {
            guard case .object(let w)? = v, let reason = w["reason"]?.stringValue.flatMap(WaitReason.init(rawValue:)) else { return nil }
            return Wait(reason: reason, resumesAt: DBJSON.date(w["resumes_at"]?.stringValue))
        }
        var g = GoogleStatus(state: o["state"]?.stringValue.flatMap(GoogleStatus.State.init(rawValue:)) ?? .idle,
                             people: wait(o["people"]), searches: wait(o["searches"]),
                             updatedAt: DBJSON.date(o["updated_at"]?.stringValue))
        if case .object(let a)? = o["active"] {
            switch a["kind"]?.stringValue {
            case "people": g.active = a["company_id"]?.intValue.map { .people(companyID: $0) }
            case "referrers": g.active = a["company_id"]?.intValue.map { .referrers(companyID: $0) }
            case "search": g.active = a["search_id"]?.stringValue.map { .search(id: $0) }
            default: break
            }
        }
        return g
    }
}

private extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d): Int(d)
        default: nil
        }
    }
}

/// What outreach is doing, ready to print.
struct OutreachActivity: Sendable, Hashable {
    /// Where "Find people" stands at one company.
    enum ScoutPhase: Sendable, Hashable {
        /// Reading their site, YC's page and GitHub (HTTP, right away).
        case site
        /// Reading Google results for people there right now.
        case googleRunning
        /// The Google half is queued; `wait` says why it hasn't started (nil: behind other Google work).
        case googleQueued(OutreachWork.Wait?)

        /// Short label for a prospect row.
        var rowLabel: String {
            switch self {
            case .site: "Finding people…"
            case .googleRunning: "Reading Google results…"
            case .googleQueued: "Google results queued"
            }
        }

        var working: Bool {
            switch self {
            case .site, .googleRunning: true
            case .googleQueued: false
            }
        }
    }

    struct Line: Identifiable, Sendable, Hashable {
        enum Phase: Sendable, Hashable { case working, waiting, done }
        var id: String
        var phase: Phase
        var text: String
    }

    /// Searches (working and waiting first, then results from the last `recentWindow`) and the
    /// people / referrer summary lines, in display order.
    var lines: [Line] = []
    var scouts: [Int: ScoutPhase] = [:]
    /// Companies with a "who could refer you" search queued or running.
    var referrers: [Int: Bool] = [:]

    /// Something is actually happening right now (a small spinner is honest).
    var isWorking: Bool { lines.contains { $0.phase == .working } || scouts.values.contains { $0.working } }
    /// Work is in progress or waiting (finished results don't count).
    var isActive: Bool { lines.contains { $0.phase != .done } || !scouts.isEmpty || !referrers.isEmpty }
    var isEmpty: Bool { lines.isEmpty && scouts.isEmpty && referrers.isEmpty }

    /// A finished search stays on screen this long, then it goes quiet.
    static let recentWindow: TimeInterval = 10 * 60
    /// A YC stage this old was cut short (the agent stopped); it isn't shown as running.
    static let staleYC: TimeInterval = 60 * 60
    /// A "running" Google status this old is stale (the agent stopped mid-way).
    static let staleRunning: TimeInterval = 30 * 60
    /// After a site scout ends with Google queued, assume it's queued until the DB shows the queue.
    static let queueGrace: TimeInterval = 3

    /// One sentence for the sidebar's tooltip and VoiceOver.
    var summary: String? {
        let open = lines.filter { $0.phase != .done }
        guard !open.isEmpty else { return nil }
        return open.map(\.text).joined(separator: "\n")
    }

    // MARK: Derivation

    static func derive(work: OutreachWork, scouting: Set<Int>, recentlyQueued: [Int: Date] = [:],
                       companyName: (Int) -> String?, now: Date, calendar: Calendar = .current) -> OutreachActivity {
        var out = OutreachActivity()
        var google = work.google
        if google.state == .running, let at = google.updatedAt, now.timeIntervalSince(at) > staleRunning {
            google.state = .waiting
            google.active = nil
        }
        let googleBusy = google.state == .running
        func name(_ id: Int) -> String { companyName(id) ?? work.companyNames[id] ?? "a company" }

        // Searches: newest first; finished ones only for a while.
        var open: [Line] = []
        var done: [Line] = []
        for s in work.searches.reversed() {
            switch s.status {
            case .done:
                guard let at = s.finishedAt, now.timeIntervalSince(at) <= recentWindow, now >= at.addingTimeInterval(-60) else { continue }
                done.append(Line(id: s.id, phase: .done, text: doneText(s)))
            case .running where s.stage == "yc" || s.stage == nil:
                guard now.timeIntervalSince(s.createdAt) <= staleYC else { continue }
                open.append(Line(id: s.id, phase: .working, text: startupsPrefix(s) + " · " + ycProgress(s, running: true)))
            case .running:
                open.append(Line(id: s.id, phase: .working, text: googleText(s, active: true, wait: nil, now: now, calendar: calendar)))
            case .queued:
                let active: Bool = {
                    if case .search(let id)? = google.active { return id == s.id && googleBusy }
                    return false
                }()
                // Behind other Google work right now: no reason applies yet, it's simply next.
                let wait: OutreachWork.Wait? = googleBusy ? nil : (google.searches ?? OutreachWork.Wait(reason: .nextTurn))
                open.append(Line(id: s.id, phase: active ? .working : .waiting,
                                 text: googleText(s, active: active, wait: wait, now: now, calendar: calendar)))
            }
        }

        // People: this app's site scouts, then the Google queue.
        for id in scouting { out.scouts[id] = .site }
        let peopleWait: OutreachWork.Wait? = googleBusy ? nil : (google.people ?? OutreachWork.Wait(reason: .nextTurn))
        for id in work.googleQueue where out.scouts[id] == nil {
            if googleBusy, case .people(let a)? = google.active, a == id {
                out.scouts[id] = .googleRunning
            } else {
                out.scouts[id] = .googleQueued(peopleWait)
            }
        }
        for (id, at) in recentlyQueued where out.scouts[id] == nil && now.timeIntervalSince(at) <= queueGrace {
            out.scouts[id] = .googleQueued(peopleWait)
        }
        for id in work.referrerQueue {
            if googleBusy, case .referrers(let a)? = google.active, a == id { out.referrers[id] = true } else { out.referrers[id] = false }
        }

        if !out.scouts.isEmpty {
            let ids = out.scouts.keys.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
            let working = ids.filter { out.scouts[$0]!.working }
            let queued = ids.filter { !out.scouts[$0]!.working }
            if !working.isEmpty {
                open.append(Line(id: "people-working", phase: .working, text: "Finding people at \(list(working.map(name)))"))
            }
            if !queued.isEmpty {
                let what = "Google results for people at \(list(queued.map(name)))"
                open.append(Line(id: "people-queued", phase: .waiting,
                                 text: what + ": " + waitText(peopleWait, now: now, calendar: calendar)))
            }
        }
        if !out.referrers.isEmpty {
            let ids = out.referrers.keys.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
            if ids.contains(where: { out.referrers[$0] == true }) {
                open.append(Line(id: "referrers", phase: .working, text: "Looking for people who could refer you at \(list(ids.map(name)))"))
            } else {
                open.append(Line(id: "referrers", phase: .waiting,
                                 text: "People who could refer you at \(list(ids.map(name))): " + waitText(peopleWait, now: now, calendar: calendar)))
            }
        }
        out.lines = open.sorted { ($0.phase == .working ? 0 : 1) < ($1.phase == .working ? 0 : 1) } + done
        return out
    }

    // MARK: Copy (the agent speaks as "I" and says what happens next)

    static func waitText(_ wait: OutreachWork.Wait?, now: Date, calendar: Calendar = .current) -> String {
        guard let wait else { return "queued, after what I'm doing now" }
        switch wait.reason {
        case .nextTurn: return "waiting for the browser, I'll start when it's free"
        case .browserBusy: return "waiting while I use the browser to apply, then I'll start"
        case .paused: return "paused. Resume me to continue"
        case .dailyLimit: return "today's Google limit is used, I'll continue tomorrow"
        case .off: return "the people finder is off. Turn it on in Settings ▸ Cold Email"
        case .resting:
            guard let at = wait.resumesAt, at > now else { return "Google asked me to slow down, I'll try again soon" }
            let time = at.formatted(date: .omitted, time: .shortened)
            return "Google asked me to slow down, I'll try again " + (calendar.isDate(at, inSameDayAs: now) ? "at \(time)" : "tomorrow at \(time)")
        }
    }

    private static func startupsPrefix(_ s: OutreachWork.Search) -> String {
        "Looking for startups in \(s.location ?? s.query)"
    }

    private static func ycProgress(_ s: OutreachWork.Search, running: Bool) -> String {
        if running { return s.found == 0 ? "reading YC's directory" : "YC's directory: \(s.found) found so far" }
        return "YC's directory: \(s.found) found"
    }

    private static func googleText(_ s: OutreachWork.Search, active: Bool, wait: OutreachWork.Wait?, now: Date, calendar: Calendar) -> String {
        let progress: String? = {
            guard active else { return nil }
            switch s.stage {
            case "saving": return s.kind == .startups ? "checking the companies in the news" : "reading the companies I found"
            default:
                let what = s.kind == .startups ? (s.ycFallback && !s.ycDone ? "reading YC's pages from Google results" : "reading funding news")
                                               : "reading Google results"
                guard let step = s.step, let steps = s.steps, steps > 1 else { return what }
                return "\(what) (\(step) of \(steps))"
            }
        }()
        switch s.kind {
        case .startups:
            let yc = s.ycDone ? ycProgress(s, running: false) : nil
            let tail = progress ?? ((s.ycFallback && !s.ycDone ? "YC's directory through Google results" : "funding news") + ": "
                                    + waitText(wait, now: now, calendar: calendar))
            return ([startupsPrefix(s)] + [yc, tail].compactMap { $0 }).joined(separator: " · ")
        case .companies:
            let head = "Searching for “\(s.query)”" + (s.location.map { " in \($0)" } ?? "")
            return head + (progress.map { " · \($0)" } ?? ": " + waitText(wait, now: now, calendar: calendar))
        }
    }

    private static func doneText(_ s: OutreachWork.Search) -> String {
        switch s.kind {
        case .startups:
            let place = s.location ?? s.query
            return s.found == 0 ? "No new startups in \(place) this time. Try a nearby city, or clear the filters."
                                : "Found \(C3Format.plural(s.found, "startup")) in \(place)"
        case .companies:
            return s.found == 0 ? "No new companies for “\(s.query)”. Try broader words."
                                : "Found \(C3Format.plural(s.found, "company", "companies")) for “\(s.query)”"
        }
    }

    /// "Patang AI", "Patang AI and Lab0", "Patang AI, Lab0 and 3 more".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        case 3: "\(names[0]), \(names[1]) and \(names[2])"
        default: "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// The toast when a people search ends: what was found, and what happens next.
    static func scoutResult(_ p: ScoutFinishedPayload, company: String) -> String {
        let next = p.queuedGoogle ? " · I'll check Google results next" : ""
        if p.withEmail > 0 {
            let people = C3Format.plural(p.found, "person", "people")
            return (p.found > p.withEmail ? "Found \(people) at \(company), \(p.withEmail) with an email" : "Found \(people) at \(company)") + next
        }
        if p.found > 0 { return "Found \(C3Format.plural(p.found, "person", "people")) at \(company), no email yet" + next }
        return (p.queuedGoogle ? "No one on \(company)'s site yet" : "No one with an email at \(company) yet") + next
    }
}
