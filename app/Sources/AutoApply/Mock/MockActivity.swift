// MockActivity.swift — the mock daemon's outreach progress, written the way autoapplyd writes its
// `meta` rows (contract §5.1.3): a search queued → running by stage → done with its count, and a
// people search's Google half queued → running → finished (with a second `scout_finished`). Sample
// mode and mock runs show the Companies strip, the row tags and the sidebar indicator from this.
import Foundation

enum MockActivity {
    static func newSearchID(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())" }

    static func addSearch(_ data: inout RepositoryData, id: String, kind: OutreachWork.Search.Kind, query: String, location: String?,
                          status: OutreachWork.Search.Status, stage: String?, ycOnly: Bool = false) {
        data.outreach.work.searches.append(OutreachWork.Search(
            id: id, kind: kind, query: query, location: location, status: status, stage: stage, ycOnly: ycOnly, createdAt: Date()))
        data.outreach.work.searches = Array(data.outreach.work.searches.suffix(30))
    }

    static func updateSearch(_ world: MockWorld, id: String, _ body: (inout OutreachWork.Search) -> Void) {
        world.repository.update { data in
            guard let i = data.outreach.work.searches.firstIndex(where: { $0.id == id }) else { return }
            body(&data.outreach.work.searches[i])
        }
    }

    /// Why queued Google work waits in the mock: paused, else "the next time the browser is free".
    private static func waiting(_ world: MockWorld) -> OutreachWork.Wait {
        OutreachWork.Wait(reason: world.isPaused ? .paused : .nextTurn)
    }

    private static func setGoogle(_ world: MockWorld, _ status: OutreachWork.GoogleStatus) {
        world.repository.update { data in
            var s = status
            s.updatedAt = Date()
            data.outreach.work.google = s
        }
    }

    /// Back to idle unless other work is still queued (then it waits for its turn).
    private static func settleGoogle(_ world: MockWorld) {
        let pending = world.repository.read { d in
            (people: !d.outreach.work.googleQueue.isEmpty || !d.outreach.work.referrerQueue.isEmpty,
             searches: d.outreach.work.searches.contains { $0.status == .queued })
        }
        if !pending.people && !pending.searches {
            setGoogle(world, OutreachWork.GoogleStatus())
        } else {
            setGoogle(world, OutreachWork.GoogleStatus(state: .waiting, people: pending.people ? waiting(world) : nil,
                                                      searches: pending.searches ? waiting(world) : nil))
        }
    }

    /// The Google half of a search: waits a beat for the browser, reads `steps` result pages, saves.
    /// `save` adds the companies found and returns how many.
    static func runGoogleSearch(_ world: MockWorld, id: String, stage: String, steps: Int = 3,
                                save: @escaping @Sendable (inout RepositoryData) -> Int) async {
        settleGoogle(world)
        await world.sleepRespectingPause(1.5)
        setGoogle(world, OutreachWork.GoogleStatus(state: .running, active: .search(id: id)))
        for step in 1...steps {
            updateSearch(world, id: id) { $0.status = .running; $0.stage = stage; $0.step = step; $0.steps = steps }
            await world.sleepRespectingPause(1)
        }
        updateSearch(world, id: id) { $0.stage = "saving"; $0.step = nil; $0.steps = nil }
        await world.sleepRespectingPause(1)
        let added = world.repository.update(save)
        updateSearch(world, id: id) { s in
            s.status = .done
            s.found = (s.kind == .startups ? s.found : 0) + added
            s.stage = nil
            s.finishedAt = Date()
        }
        settleGoogle(world)
    }

    /// The Google half of "Find people" at a company: queued, then read, then a `scout_finished`.
    static func queueGooglePeople(_ world: MockWorld, companyID: Int) {
        world.repository.update { data in
            data.outreach.work.googleQueue.removeAll { $0 == companyID }
            data.outreach.work.googleQueue.append(companyID)
        }
        settleGoogle(world)
    }

    static func runGooglePeople(_ world: MockWorld, companyIDs: [Int], purpose: ScoutPurpose, applicationID: Int? = nil) async {
        await world.sleepRespectingPause(2)
        for companyID in companyIDs where world.repository.read({ $0.outreach.work.googleQueue.contains(companyID) }) {
            setGoogle(world, OutreachWork.GoogleStatus(state: .running, active: .people(companyID: companyID)))
            await world.sleepRespectingPause(2)
            let (found, withEmail, best): (Int, Int, Int?) = world.repository.update { data in
                data.outreach.work.googleQueue.removeAll { $0 == companyID }
                let people = data.outreach.contacts.filter { $0.companyID == companyID }
                let emails = people.filter(\.hasEmail)
                return (people.count, emails.count, emails.map(\.emailConfidence).max())
            }
            world.emit(.scoutFinished(ScoutFinishedPayload(companyId: companyID, purpose: purpose, applicationId: applicationID,
                                                           found: found, withEmail: withEmail, bestConfidence: best, queuedGoogle: false)))
        }
        settleGoogle(world)
    }
}
