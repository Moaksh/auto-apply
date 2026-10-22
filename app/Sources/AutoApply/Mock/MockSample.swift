// MockSample.swift — the "Explore with sample data" dataset (DESIGN_AWARD_VISION 1I): one
// believable job seeker in India (Asha Rao, a backend engineer in Bengaluru, the same person the
// outreach fixtures already write as), Indian companies and cities, and a script in which the
// agent keeps working so the living hero and the pipeline move. Built on the rich baseline, then
// localized, so every screen (Review, Needs You, replies, cold email, interview prep) has content.
import Foundation

enum MockSample {
    // MARK: Persona

    static var profile: Profile {
        var p = Profile()
        p.fullName = "Asha Rao"
        p.firstName = "Asha"
        p.lastName = "Rao"
        p.email = MockOutreach.mailbox
        p.phone = "+91 98450 21734"
        p.location = "Bengaluru, India"
        p.headline = "Backend engineer · payments and high-traffic APIs"
        p.summary = "Five years building payment rails and Go services that stay up on sale days."
        p.links = ["linkedin": "https://www.linkedin.com/in/example", "github": "https://github.com/example"]
        p.workHistory = [
            WorkHistoryItem(company: "Paywise", title: "Senior Backend Engineer", start: "2023-01", end: nil, location: "Bengaluru",
                            highlights: ["Scaled the UPI ledger service to 12k TPS", "Led the move to event sourcing"]),
            WorkHistoryItem(company: "Shipfast", title: "Backend Engineer", start: "2020-07", end: "2022-12", location: "Pune",
                            highlights: ["Built the courier-rate engine in Go"]),
        ]
        p.education = [EducationItem(school: "NIT Karnataka, Surathkal", degree: "B.Tech", field: "Computer Science",
                                     start: "2016", end: "2020")]
        p.skills = ["go", "python", "postgres", "kafka", "kubernetes", "grpc"]
        p.yearsExperience = 5
        return p
    }

    static var neverGuess: NeverGuess {
        var n = NeverGuess()
        n.workAuth = ["IN": "citizen"]
        n.sponsorship = "Not needed in India"
        n.salaryExpectation = "₹38L fixed"
        n.salaryNegotiable = true
        n.noticePeriod = "60 days"
        n.relocation = "case_by_case"
        n.eeoPolicy = "decline"
        n.attestAccuracy = true
        return n
    }

    static var preferences: Preferences {
        var p = Preferences()
        p.roles = ["Backend Engineer", "Platform Engineer", "ML Engineer"]
        p.seniority = [.mid, .senior]
        p.locations = ["Bengaluru", "Remote (India)", "Pune"]
        p.salaryFloor = 3_000_000
        p.salaryCurrency = "INR"
        p.workAuthSummary = "Indian citizen"
        // Owner decision: start in Review, so nothing is sent without a look.
        p.mode = .review
        return p
    }

    // MARK: Companies and places

    /// Companies from the shared fixtures that already read as Indian employers; jobs at these keep their company.
    static let keptCompanies: Set<String> = [
        "Razorpay", "CRED", "Swiggy", "Zepto", "Groww", "Meesho", "Zomato", "Freshworks", "Browserstack", "Hasura", "Sarvam AI", "Postman",
    ]

    /// Replacements for every other fixture company (ids from 101 so they never collide).
    static let companies: [MockFixtures.Company] = {
        let raw: [(String, String, Ats)] = [
            ("Flipkart", "flipkart.com", .workday), ("PhonePe", "phonepe.com", .lever), ("Juspay", "juspay.in", .lever),
            ("Zerodha", "zerodha.com", .lever), ("Dream11", "dream11.com", .greenhouse), ("Myntra", "myntra.com", .workday),
            ("Urban Company", "urbancompany.com", .lever), ("ShareChat", "sharechat.com", .greenhouse), ("Chargebee", "chargebee.com", .greenhouse),
            ("InMobi", "inmobi.com", .greenhouse), ("Nykaa", "nykaa.com", .lever), ("Setu", "setu.co", .ashby),
            ("Navi", "navi.com", .greenhouse), ("Licious", "licious.in", .lever), ("Jar", "myjar.app", .ashby),
            ("Unacademy", "unacademy.com", .greenhouse), ("Cars24", "cars24.com", .workday), ("Krutrim", "olakrutrim.com", .ashby),
        ]
        return raw.enumerated().map { MockFixtures.Company(id: 101 + $0.offset, name: $0.element.0, domain: $0.element.1, ats: $0.element.2) }
    }()

    /// The pool new jobs are discovered from while exploring (the kept companies plus the replacements).
    static let discoveryPool: [MockFixtures.Company] =
        MockFixtures.companies.filter { keptCompanies.contains($0.name) } + companies

    static let locations = ["Bengaluru, India", "Hybrid · Bengaluru", "Remote (India)", "Pune, India", "Hybrid · Gurugram",
                            "Hyderabad, India", "Mumbai, India", "Chennai, India"]

    static func replacement(for company: MockFixtures.Company) -> MockFixtures.Company {
        keptCompanies.contains(company.name) ? company : companies[company.id % companies.count]
    }

    static func location(for jobID: Int) -> String { locations[jobID % locations.count] }

    static func remote(for location: String) -> RemotePolicy {
        location.contains("Remote") ? .remote : (location.contains("Hybrid") ? .hybrid : .onsite)
    }

    // MARK: Localize the baseline

    /// Rewrite the baseline for the sample persona: profile and facts, Indian companies and cities,
    /// answers and descriptions that name the new company, and log lines that follow the rename.
    static func localize(_ data: inout RepositoryData, now: Date) {
        data.profile = profile
        data.neverGuess = neverGuess
        for i in data.memoryAnswers.indices where data.memoryAnswers[i].canonicalQuestion == "Preferred pronouns" {
            data.memoryAnswers[i].answer = "she/her"
        }
        let byName = Dictionary(MockFixtures.companies.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var renames: [Int: (from: String, to: String)] = [:]
        for i in data.jobs.indices {
            var job = data.jobs[i]
            if let original = byName[job.company] {
                let target = replacement(for: original)
                if target.name != job.company {
                    renames[job.id] = (job.company, target.name)
                    job.company = target.name
                    job.companyID = target.id
                    job.companyDomain = target.domain
                    if !job.easyApply { job.ats = target.ats }
                    job.applyURL = "https://jobs.example.com/\(target.domain)/\(job.id)"
                    job.sourceURL = job.applyURL
                }
            }
            if !job.easyApply {
                job.location = location(for: job.id)
                job.remote = remote(for: job.location ?? "")
            }
            data.jobs[i] = job
            if data.jobDescriptions[job.id] != nil {
                data.jobDescriptions[job.id] = MockFixtures.description(company: job.company, title: job.title)
            }
        }
        // Answers carry the person and the company: rebuild them for the sample persona.
        let jobsByApp = Dictionary(data.jobs.compactMap { j in j.applicationID.map { ($0, j) } }, uniquingKeysWith: { a, _ in a })
        for (appID, answers) in data.applicationAnswers {
            guard let job = jobsByApp[appID], let first = answers.first else { continue }
            let low = answers.contains { ($0.confidence ?? 1) < 0.6 }
            let rebuilt = MockFixtures.applicationAnswers(applicationID: appID, company: job.company, lowConfidence: low, startID: first.id,
                                                          profile: data.profile, neverGuess: data.neverGuess)
            data.applicationAnswers[appID] = rebuilt
            if job.state == .awaitingReview, let i = data.jobIndex(applicationID: appID) {
                data.jobs[i].screenshotPath = MockFrames.preSubmitScreenshot(
                    company: job.company, answers: rebuilt, name: "sample-" + MockScripts.screenshotName(appID, job.company)) ?? data.jobs[i].screenshotPath
            }
        }
        // Log lines name the company ("stripe/12 scored 80"); follow the rename.
        for i in data.activity.indices {
            guard let jobID = data.activity[i].jobID, let r = renames[jobID] else { continue }
            data.activity[i].message = data.activity[i].message
                .replacingOccurrences(of: slug(r.from), with: slug(r.to))
                .replacingOccurrences(of: r.from, with: r.to)
        }
    }

    static func slug(_ company: String) -> String { company.lowercased().replacingOccurrences(of: " ", with: "") }

    /// A fresh job from the sample pool (discovered while exploring).
    static func job(id: Int, now: Date) -> JobItem {
        let company = discoveryPool[id % discoveryPool.count]
        let title = MockFixtures.titles[(id / 3) % MockFixtures.titles.count]
        var job = MockFixtures.job(id: id, company: company, title: title, location: location(for: id), discoveredAt: now)
        if id % 3 == 0 {
            job.salaryMin = (28 + id % 12) * 100_000
            job.salaryMax = job.salaryMin! + 8 * 100_000
            job.salaryCurrency = "INR"
        }
        return job
    }

    // MARK: Script

    /// The agent keeps working: a first run a moment after you arrive (find, score, fill into Review,
    /// park one question for you), then a short check every ~45 s that finds and scores a few more and
    /// now and then fills one. Bounded so a long session never grows without limit.
    static func script() -> [ScriptStep] {
        [ScriptStep(at: 1.5) { world in
            await firstRun(world)
            for cycle in 0..<40 {
                await world.sleepRespectingPause(45)
                if Task.isCancelled { return }
                await watchlistCheck(world, cycle: cycle)
            }
        }]
    }

    static func firstRun(_ world: MockWorld) async {
        world.startRun(.full, trigger: .scheduled)
        world.setState(.discovering, message: "LinkedIn · 'backend engineer' · Bengaluru", progress: Progress(done: 0, total: 8))
        var ids: [Int] = []
        for k in 0..<8 {
            await world.sleepRespectingPause(0.7)
            let id = world.nextJobID()
            ids.append(id)
            world.discover(job(id: id, now: Date()))
            world.setState(.discovering, message: "LinkedIn · 'backend engineer' · Bengaluru", progress: Progress(done: k + 1, total: 8))
        }
        world.setState(.scoring, progress: Progress(done: 0, total: ids.count))
        let scores = [91, 64, 86, 58, 79, 88, 52, 74]
        for (k, id) in ids.enumerated() {
            await world.sleepRespectingPause(0.5)
            world.score(jobID: id, score: scores[k % scores.count])
            world.setState(.scoring, progress: Progress(done: k + 1, total: ids.count))
        }
        // 91 → Review, 86 → a question for you, 88 → Review with one unsure answer.
        let plan: [(Int, MockScripts.FillOutcome)] = [(ids[0], .review(lowConfidence: false)), (ids[2], .park(templateIndex: 1)),
                                                      (ids[5], .review(lowConfidence: true))]
        for (n, item) in plan.enumerated() {
            await MockScripts.fill(world, jobID: item.0, index: n, of: plan.count, outcome: item.1, stepDuration: 0.9)
            await world.sleepRespectingPause(0.6)
        }
        world.finishRun(.completed)
    }

    static func watchlistCheck(_ world: MockWorld, cycle: Int) async {
        world.startRun(.full, trigger: .scheduled)
        world.setState(.discovering, message: "Careers pages · watchlist", progress: Progress(done: 0, total: 3))
        var ids: [Int] = []
        for k in 0..<3 {
            await world.sleepRespectingPause(0.8)
            let id = world.nextJobID()
            ids.append(id)
            world.discover(job(id: id, now: Date()))
            world.setState(.discovering, message: "Careers pages · watchlist", progress: Progress(done: k + 1, total: 3))
        }
        world.setState(.scoring, progress: Progress(done: 0, total: 3))
        for (k, id) in ids.enumerated() {
            await world.sleepRespectingPause(0.6)
            world.score(jobID: id, score: k == 0 ? 76 + (cycle * 7) % 18 : 50 + (cycle * 11 + k * 5) % 18)
            world.setState(.scoring, progress: Progress(done: k + 1, total: 3))
        }
        if cycle % 2 == 0 {
            await MockScripts.fill(world, jobID: ids[0], index: 0, of: 1, outcome: .review(lowConfidence: cycle % 4 == 2), stepDuration: 0.9)
        }
        world.finishRun(.completed)
    }
}
