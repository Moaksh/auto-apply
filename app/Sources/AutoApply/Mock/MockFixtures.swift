// MockFixtures.swift — deterministic, realistic sample data (real-looking companies, varied
// ATSes, titles, Q&A with provenance) so the UI is designed against true density.
import CoreGraphics
import Foundation

/// SplitMix64 — tiny deterministic RNG so fixtures are identical on every launch and in tests.
struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func double(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
    mutating func chance(_ p: Double) -> Bool { double(0...1) < p }
}

enum MockFixtures {
    struct Company: Sendable {
        var id: Int
        var name: String
        var domain: String
        var ats: Ats
    }

    static let companies: [Company] = {
        let raw: [(String, String, Ats)] = [
            ("Stripe", "stripe.com", .greenhouse), ("Ramp", "ramp.com", .ashby), ("Notion", "notion.so", .greenhouse),
            ("Figma", "figma.com", .greenhouse), ("Linear", "linear.app", .ashby), ("Vercel", "vercel.com", .ashby),
            ("Plaid", "plaid.com", .lever), ("Brex", "brex.com", .greenhouse), ("Datadog", "datadoghq.com", .greenhouse),
            ("Razorpay", "razorpay.com", .lever), ("CRED", "cred.club", .lever), ("Swiggy", "swiggy.com", .workday),
            ("Zepto", "zeptonow.com", .lever), ("Atlassian", "atlassian.com", .workday), ("Canva", "canva.com", .lever),
            ("Postman", "postman.com", .greenhouse), ("Rippling", "rippling.com", .ashby), ("Retool", "retool.com", .ashby),
            ("Snowflake", "snowflake.com", .workday), ("Coinbase", "coinbase.com", .greenhouse), ("Cloudflare", "cloudflare.com", .greenhouse),
            ("GitLab", "gitlab.com", .greenhouse), ("Grafana Labs", "grafana.com", .greenhouse), ("Supabase", "supabase.com", .ashby),
            ("PostHog", "posthog.com", .ashby), ("Sentry", "sentry.io", .greenhouse), ("Temporal", "temporal.io", .greenhouse),
            ("Airtable", "airtable.com", .greenhouse), ("Miro", "miro.com", .greenhouse), ("Deel", "deel.com", .ashby),
            ("Freshworks", "freshworks.com", .other), ("Zomato", "zomato.com", .lever), ("Meesho", "meesho.com", .lever),
            ("Groww", "groww.in", .greenhouse), ("Browserstack", "browserstack.com", .greenhouse), ("Hasura", "hasura.io", .lever),
            ("Sarvam AI", "sarvam.ai", .ashby), ("Clickhouse", "clickhouse.com", .greenhouse), ("Neon", "neon.tech", .ashby),
            ("Modal", "modal.com", .ashby),
        ]
        return raw.enumerated().map { Company(id: $0.offset + 1, name: $0.element.0, domain: $0.element.1, ats: $0.element.2) }
    }()

    static let titles = [
        "Backend Engineer", "Senior Backend Engineer", "Backend Engineer, Payments", "Staff Engineer, Infrastructure",
        "Platform Engineer", "Software Engineer II", "ML Engineer", "Site Reliability Engineer",
        "Distributed Systems Engineer", "Data Platform Engineer", "Senior Software Engineer, API", "Infrastructure Engineer",
    ]

    static let locations = ["Remote (India)", "Bangalore, India", "Remote (Global)", "Hybrid · Bangalore", "Remote (APAC)", "Singapore"]

    static let skipReasons = ["below_threshold", "below_threshold", "below_threshold", "excluded_keyword:crypto",
                              "company_cooldown", "salary_floor", "location_mismatch"]

    static let resumeVariants: [ResumeVariantItem] = {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        return [
            ResumeVariantItem(id: 1, label: "Backend", filePath: "/mock/resumes/Backend.pdf", tags: ["backend", "go", "payments"], isDefault: true, createdAt: base, updatedAt: base),
            ResumeVariantItem(id: 2, label: "ML", filePath: "/mock/resumes/ML.pdf", tags: ["ml", "python"], createdAt: base, updatedAt: base),
            ResumeVariantItem(id: 3, label: "Infra", filePath: "/mock/resumes/Infra.pdf", tags: ["k8s", "sre"], createdAt: base, updatedAt: base),
        ]
    }()

    static var profile: Profile {
        var p = Profile()
        p.fullName = "Moaksh Kakkar"
        p.firstName = "Moaksh"
        p.lastName = "Kakkar"
        p.email = "moaksh@example.com"
        p.phone = "+91 98765 43210"
        p.location = "Bangalore, India"
        p.headline = "Backend engineer · payments & distributed systems"
        p.summary = "Five years building payment rails and high-throughput Go services."
        p.links = ["linkedin": "https://www.linkedin.com/in/example", "github": "https://github.com/example"]
        p.workHistory = [
            WorkHistoryItem(company: "Paywise", title: "Senior Backend Engineer", start: "2023-01", end: nil, location: "Bangalore",
                            highlights: ["Scaled ledger service to 12k TPS", "Led migration to event sourcing"]),
            WorkHistoryItem(company: "Shipfast", title: "Backend Engineer", start: "2020-06", end: "2022-12", location: "Remote",
                            highlights: ["Built carrier-rate engine in Go"]),
        ]
        p.education = [EducationItem(school: "IIIT Hyderabad", degree: "B.Tech", field: "Computer Science", start: "2016", end: "2020")]
        p.skills = ["go", "python", "postgres", "kafka", "kubernetes", "grpc"]
        p.yearsExperience = 5
        return p
    }

    static var neverGuess: NeverGuess {
        var n = NeverGuess()
        n.workAuth = ["IN": "citizen", "US": "requires_sponsorship"]
        n.sponsorship = "Requires sponsorship (H-1B)"
        n.salaryExpectation = "₹45L"
        n.salaryNegotiable = true
        n.noticePeriod = "60 days"
        n.relocation = "case_by_case"
        n.eeoPolicy = "decline"
        n.attestAccuracy = true
        return n
    }

    static func stories(now: Date) -> [StoryItem] {
        [
            StoryItem(id: 1, title: "Payments ledger at scale", situation: "Ledger writes were failing at peak (2k TPS).",
                      task: "Own the redesign without downtime.", action: "Introduced idempotent event sourcing and partitioned Kafka topics.",
                      result: "12k TPS sustained, zero double-posts in 14 months.", tags: ["scale", "ownership"], uses: 7, updatedAt: now.addingTimeInterval(-86_400 * 3)),
            StoryItem(id: 2, title: "Resolving an API design conflict", situation: "Two teams disagreed on a breaking API change.",
                      task: "Find a path both could ship.", action: "Ran a design review with versioned contracts and a migration shim.",
                      result: "Shipped in 3 weeks; no client breakage.", tags: ["conflict", "collaboration"], uses: 3, updatedAt: now.addingTimeInterval(-86_400 * 10)),
            StoryItem(id: 3, title: "On-call incident leadership", situation: "Checkout latency spiked to 9s during a sale.",
                      task: "Coordinate the response as incident lead.", action: "Bisected a bad cache config, rolled back, wrote the postmortem.",
                      result: "Restored in 22 minutes; added canary checks.", tags: ["leadership", "reliability"], uses: 5, updatedAt: now.addingTimeInterval(-86_400 * 20)),
            StoryItem(id: 4, title: "Mentoring two new hires", situation: "Team doubled in a quarter.", task: "Get new engineers productive fast.",
                      action: "Wrote onboarding labs and paired weekly.", result: "Both shipped to prod in week 2.", tags: ["mentoring"], uses: 1, updatedAt: now.addingTimeInterval(-86_400 * 40)),
        ]
    }

    static func memoryAnswers(now: Date) -> [MemoryAnswerItem] {
        let qa: [(String, String, Bool, Int)] = [
            ("Why do you want to work at {company}?", "I'm drawn to {company} because of its focus on developer-grade infrastructure. In my last role I…", true, 31),
            ("Years of experience with Go?", "4", false, 18),
            ("Years of Kubernetes experience?", "3", false, 4),
            ("Are you willing to work PST hours?", "Partial overlap (until 1pm PST)", false, 6),
            ("Portfolio URL", "https://github.com/example", false, 9),
            ("How did you hear about us?", "Company careers page", false, 22),
            ("Preferred pronouns", "he/him", false, 12),
            ("Describe a technical challenge you solved", "At Paywise our ledger…", true, 8),
            ("Are you comfortable with on-call?", "Yes", false, 7),
            ("Highest level of education", "Bachelor's degree", false, 25),
            ("LinkedIn profile", "https://www.linkedin.com/in/example", false, 30),
            ("Earliest start date", "60 days from offer", false, 11),
        ]
        return qa.enumerated().map { i, item in
            MemoryAnswerItem(id: i + 1, canonicalQuestion: item.0, answer: item.1, fieldType: item.2 ? .textarea : .text,
                             isTemplate: item.2, source: "user", uses: item.3,
                             lastUsedAt: now.addingTimeInterval(-Double(i) * 7_200), updatedAt: now.addingTimeInterval(-Double(i) * 86_400))
        }
    }

    /// A realistic Q&A audit for one application.
    /// `profile` / `neverGuess`, when given (and filled in), supply the person's own answers;
    /// otherwise the baseline persona's.
    static func applicationAnswers(applicationID: Int, company: String, lowConfidence: Bool = false, startID: Int,
                                   profile: Profile? = nil, neverGuess: NeverGuess? = nil) -> [ApplicationAnswerItem] {
        let person = profile.flatMap { ($0.fullName ?? "").isEmpty ? nil : $0 } ?? Self.profile
        let facts = neverGuess.flatMap { $0.salaryExpectation == nil ? nil : $0 } ?? Self.neverGuess
        let sponsorship = (facts.sponsorship ?? "").lowercased().hasPrefix("requires") ? "Yes" : "No"
        var items: [(String, String, FieldType, Double?, AnswerOrigin, String?)] = [
            ("Full name", person.fullName ?? "", .text, nil, .profile, nil),
            ("Email", person.email ?? "", .email, nil, .profile, nil),
            ("Phone", person.phone ?? "", .phone, nil, .profile, nil),
            ("Years with Go?", "4", .number, 0.93, .cv, "resume_variants:1"),
            ("Requires sponsorship?", sponsorship, .boolean, nil, .neverGuess, nil),
            ("Expected salary", facts.salaryExpectation ?? "", .text, nil, .neverGuess, nil),
            ("Why \(company)?", "I'm drawn to \(company) because of its focus on developer-grade infrastructure…", .textarea, 0.88, .memory, "answers:1"),
            ("Tell us about a time you scaled a system", "At Paywise, ledger writes were failing at peak…", .textarea, 0.86, .story, "stories:1"),
            ("Cover letter", "Generated · 212 words", .file, 0.9, .generated, nil),
            ("Resume", "Backend.pdf", .file, 0.91, .cv, "resume_variants:1"),
        ]
        if lowConfidence {
            items.append(("Earliest start date", "2 months", .text, 0.55, .generated, nil))
        }
        return items.enumerated().map { i, a in
            ApplicationAnswerItem(id: startID + i, applicationID: applicationID, fieldKey: "q\(i)", question: a.0, answer: a.1,
                                  fieldType: a.2, confidence: a.3, origin: a.4, originRef: a.5,
                                  bbox: CGRect(x: 40, y: 120 + i * 86, width: 640, height: 56))
        }
    }

    static func description(company: String, title: String) -> String {
        """
        \(company) is hiring a \(title) to build and operate core services used by millions.

        What you'll do
        • Design, build and run high-throughput backend services in Go and Python.
        • Own reliability: SLOs, on-call, incident reviews.
        • Partner with product and infra teams on APIs and data models.

        What we're looking for
        • 4+ years building production backend systems.
        • Experience with Postgres, Kafka and Kubernetes.
        • Clear written communication; comfort with ambiguity.
        """
    }

    /// A job (not yet in any state beyond `discovered`).
    static func job(id: Int, company: Company, title: String, location: String, discoveredAt: Date, source: JobSource? = nil) -> JobItem {
        var job = JobItem(id: id, applicationID: id, companyID: company.id, company: company.name, companyDomain: company.domain,
                          title: title, location: location, remote: location.contains("Remote") ? .remote : (location.contains("Hybrid") ? .hybrid : .onsite),
                          source: source ?? (company.ats == .workday || company.ats == .other ? .linkedin : JobSource(rawValue: company.ats.rawValue) ?? .careers),
                          ats: company.ats,
                          applyURL: "https://jobs.example.com/\(company.domain)/\(id)",
                          sourceURL: "https://jobs.example.com/\(company.domain)/\(id)",
                          discoveredAt: discoveredAt)
        job.stateUpdatedAt = discoveredAt
        job.postedAt = discoveredAt.addingTimeInterval(-86_400 * 2)
        return job
    }

    /// The rich baseline dataset: ~220 jobs over the last 120 days in every state/status.
    static func baseline(now: Date = Date(), jobCount: Int = 220, extraActivity: Int = 0, seed: UInt64 = 42) -> RepositoryData {
        var rng = SeededRandom(seed: seed)
        var data = RepositoryData()
        data.profile = profile
        data.neverGuess = neverGuess
        data.resumeVariants = resumeVariants
        data.stories = stories(now: now)
        data.memoryAnswers = memoryAnswers(now: now)
        var answerID = 1

        for id in 1...max(1, jobCount) {
            let company = rng.pick(companies)
            let title = rng.pick(titles)
            // The first dozen jobs are recent so every live state (queued, needs you) is represented.
            let ageDays = id <= 14 ? rng.double(0...1.8) : rng.double(0...120)
            let discoveredAt = now.addingTimeInterval(-ageDays * 86_400)
            var job = job(id: id, company: company, title: title, location: rng.pick(locations), discoveredAt: discoveredAt)
            if rng.chance(0.3) {
                job.salaryMin = rng.int(30...45) * 100_000
                job.salaryMax = job.salaryMin! + rng.int(5...15) * 100_000
                job.salaryCurrency = "INR"
            }
            let score = rng.int(38...97)
            job.score = score
            job.scoredAt = discoveredAt.addingTimeInterval(120)
            job.scoreSummary = score >= 70 ? "Strong \(rng.pick(["Go", "payments", "infra", "API"])) match, \(rng.pick(["senior level", "remote ok", "good domain fit"]))." : "Weak overlap with role requirements."
            job.scoreFactors = ["skills": min(100, score + rng.int(-5...8)), "seniority": min(100, score + rng.int(-12...6)),
                                "location": rng.pick([70, 100, 100]), "salary": rng.int(55...100), "domain": min(100, score + rng.int(-10...10))]
            job.resumeVariantID = title.contains("ML") ? 2 : (title.contains("Reliability") || title.contains("Infra") ? 3 : 1)
            job.resumePickScore = rng.double(0.6...0.95)

            let r = rng.double(0...1)
            if score < 70 {
                job.state = .skipped
                job.skipReason = rng.pick(skipReasons)
                job.stateReason = job.skipReason
                job.stateUpdatedAt = discoveredAt.addingTimeInterval(180)
            } else if ageDays < 2 && r < 0.45 {
                job.state = .queued
            } else if ageDays < 4 && r < 0.8 {
                job.state = .needsYou
                job.stateReason = "unknown_question"
            } else if r < 0.05 {
                job.state = .failed
                job.stateReason = "selector timeout on step 5"
            } else {
                job.state = .submitted
                let submittedAt = discoveredAt.addingTimeInterval(rng.double(3_600...20_000))
                job.submittedAt = min(submittedAt, now.addingTimeInterval(-60))
                job.mode = .auto
                job.screenshotPath = "/mock/screenshots/\(id)-pre.png"
                job.confirmationScreenshotPath = "/mock/screenshots/\(id)-post.png"
                job.coverLetterPath = "/mock/cover_letters/\(id).md"
                job.tokensIn = rng.int(4_000...18_000)
                job.tokensOut = rng.int(600...2_400)
                let days = now.timeIntervalSince(job.submittedAt!) / 86_400
                let s = rng.double(0...1)
                if days > 21 && s < 0.35 { job.status = .ghosted }
                else if s < 0.18 { job.status = .rejected }
                else if s < 0.24 { job.status = .assessment }
                else if s < 0.29 { job.status = .interview }
                else if s < 0.30 && days > 10 { job.status = .offer }
                else { job.status = .applied }
                job.statusUpdatedAt = job.submittedAt!.addingTimeInterval(min(days, 10) * 86_400 * 0.5)
                job.stateUpdatedAt = job.submittedAt
                job.nudgesSent = days > 14 ? 2 : (days > 7 ? 1 : 0)
                let answers = applicationAnswers(applicationID: id, company: company.name, startID: answerID)
                answerID += answers.count
                data.applicationAnswers[id] = answers
            }
            data.jobDescriptions[id] = description(company: company.name, title: title)
            data.jobs.append(job)
        }

        // Easy Apply list (LinkedIn, manual).
        let easyCompanies = ["Razorpay", "CRED", "Swiggy", "Zepto", "Meesho", "Groww", "Zomato", "Browserstack", "Hasura"]
        for (i, name) in easyCompanies.enumerated() {
            let company = companies.first { $0.name == name } ?? companies[i]
            let id = jobCount + 1 + i
            var job = job(id: id, company: company, title: rng.pick(titles), location: "Bangalore, India",
                          discoveredAt: now.addingTimeInterval(-Double(i) * 30_000), source: .linkedin)
            job.ats = .linkedinEasyApply
            job.easyApply = true
            job.score = 88 - i * 2
            job.state = .scored
            data.jobs.append(job)
            data.jobDescriptions[id] = description(company: company.name, title: job.title)
            data.easyApply.append(EasyApplyItem(
                id: i + 1, jobID: id, url: "https://www.linkedin.com/jobs/view/\(4_000_000 + id)",
                draftedAnswers: [
                    DraftedAnswer(question: "Phone", answer: "+91 98765 43210", origin: "profile"),
                    DraftedAnswer(question: "Years of experience", answer: "5", origin: "cv"),
                    DraftedAnswer(question: "Notice period", answer: "60 days", origin: "never_guess", locked: true),
                    DraftedAnswer(question: "Why \(company.name)?", answer: "Payments infra at \(company.name)'s scale is exactly…", origin: "memory"),
                    DraftedAnswer(question: "Expected CTC", answer: "", origin: nil, askMe: i % 3 == 0),
                ],
                resumeVariantID: 1, opened: i >= 6, done: i == 8, dismissed: false,
                doneAt: i == 8 ? now.addingTimeInterval(-3_600) : nil, createdAt: job.discoveredAt))
        }
        data.companySuggestions = [
            CompanySuggestionItem(id: 1, companyName: "Sarvam AI", url: "https://jobs.ashbyhq.com/sarvam", ats: .ashby,
                                  boardToken: "sarvam", source: "linkedin", sampleTitle: "AI Engineer", matchingRoles: 3,
                                  suggestedAt: now.addingTimeInterval(-7_200)),
            CompanySuggestionItem(id: 2, companyName: "Zepto", url: "https://www.zeptonow.com/careers", source: "google",
                                  sampleTitle: "Backend Engineer", matchingRoles: 2, suggestedAt: now.addingTimeInterval(-86_400)),
            CompanySuggestionItem(id: 3, companyName: "Plivo", url: "https://job-boards.greenhouse.io/plivo", ats: .greenhouse,
                                  boardToken: "plivo", source: "company_finder", sampleTitle: "Platform Engineer",
                                  matchingRoles: 2, openRoles: 14, verified: true, status: .auto,
                                  suggestedAt: now.addingTimeInterval(-3_600)),
        ]

        // Runs: three a day for the last 30 days.
        var runID = 1
        for day in (0..<30).reversed() {
            for hour in [9, 13, 18] {
                guard let start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0,
                                                        of: now.addingTimeInterval(-Double(day) * 86_400)), start < now else { continue }
                var stats = RunStats()
                stats.discovered = rng.int(10...45)
                stats.scored = stats.discovered - rng.int(0...3)
                stats.skipped = Int(Double(stats.scored) * 0.65)
                stats.queued = stats.scored - stats.skipped
                stats.submitted = min(stats.queued, rng.int(2...8))
                stats.needsYou = rng.int(0...2)
                data.runs.append(RunItem(id: runID, runUID: String(format: "run%06d", runID), kind: .full, trigger: .scheduled,
                                         startedAt: start, finishedAt: start.addingTimeInterval(rng.double(300...1_500)), outcome: .completed,
                                         stats: stats, tokensIn: rng.int(40_000...160_000), tokensOut: rng.int(6_000...20_000)))
                runID += 1
            }
        }

        data.activity = activity(for: data.jobs, now: now, extra: extraActivity, rng: &rng)
        return data
    }

    /// Activity rows derived from the jobs (plus `extra` synthetic log lines for stress).
    static func activity(for jobs: [JobItem], now: Date, extra: Int, rng: inout SeededRandom) -> [ActivityEvent] {
        var rows: [(Date, String, Actor, LogLevel, Int?, String)] = []
        rows.reserveCapacity(jobs.count * 4 + extra)
        for job in jobs {
            let slug = "\(job.company.lowercased().replacingOccurrences(of: " ", with: ""))/\(job.id)"
            rows.append((job.discoveredAt, "discover", .agent, .info, job.id, "found \(job.title) via \(job.source.label)"))
            if let score = job.score {
                rows.append((job.discoveredAt.addingTimeInterval(120), "score", .agent, .info, job.id, "\(slug) scored \(score)"))
            }
            switch job.state {
            case .skipped:
                rows.append((job.stateUpdatedAt ?? job.discoveredAt, "skip", .agent, .info, job.id, "\(slug) \(job.skipReason ?? "skipped")"))
            case .submitted:
                let at = job.submittedAt ?? job.discoveredAt
                rows.append((at.addingTimeInterval(-40), "resume", .agent, .info, job.id, "picked Backend.pdf (0.91 vs ML 0.62)"))
                rows.append((at.addingTimeInterval(-20), "fill", .agent, .info, job.id, "filled 9 standard fields"))
                rows.append((at, "submit", .agent, .info, job.id, "submitted \(slug)"))
                if let status = job.status, status != .applied, let su = job.statusUpdatedAt {
                    rows.append((su, "status", .user, .info, job.id, "moved to \(status.label)"))
                }
            case .needsYou:
                rows.append((job.stateUpdatedAt ?? job.discoveredAt, "ask", .agent, .warning, job.id, "parked: unknown question → inbox"))
            case .failed:
                rows.append((job.stateUpdatedAt ?? job.discoveredAt, "error", .agent, .error, job.id, "\(slug) \(job.stateReason ?? "failed")"))
            default:
                break
            }
        }
        let verbs = ["FILL answered \"Years with Go\" = 4 (cv, 0.93)", "SCORE 86 ✓ queued", "DISCOVER LinkedIn · 'backend engineer' · page 3",
                     "RESUME picked Infra.pdf (0.88)", "SKIP 64 below threshold", "FILL uploaded resume"]
        for i in 0..<extra {
            let at = now.addingTimeInterval(-Double(extra - i) * 2.5)
            rows.append((at, "log", .agent, i % 97 == 0 ? .error : .info, nil, rng.pick(verbs)))
        }
        rows.sort { $0.0 < $1.0 }
        return rows.enumerated().map { i, r in
            ActivityEvent(id: i + 1, ts: r.0, kind: r.1, actor: r.2, level: r.3, jobID: r.4, applicationID: r.4, message: r.5)
        }
    }
}
