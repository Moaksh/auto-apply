// MockStartups.swift — Startups near you in mock mode: plausible, made-up Indian startups (the names,
// numbers and `.example` domains are fictional) with company facts, the startup score's reasons and
// sources, and the daemon's semantics for discover_startups / scout_top_prospects (contract/protocol.md
// §5.1.3). The scores follow engine/autoapply/outreach/startup_score.py's formula.
import Foundation

enum MockStartups {
    struct Startup {
        var name: String
        var domain: String
        var city: String
        var oneLiner: String
        var yc: String?
        var stage: FundingStage?
        var amount: Double?
        var currency: String?
        var usd: Double?
        var daysAgo: Int?
        var investors: [String]
        var teamSize: Int?
        var hiring: Bool?
        var matchingRoles: Int?
        var founders: [(String, String)]
        var reasons: [StartupScoreReason]
        var fit: Int
        var fitSummary: String
    }

    private static func r(_ key: String, _ label: String, _ points: Int, _ max: Int, _ reason: String, known: Bool = true) -> StartupScoreReason {
        StartupScoreReason(key: key, label: label, points: points, max: max, reason: reason, known: known)
    }

    /// Shown from the start (a search already ran).
    static let first: [Startup] = [
        Startup(name: "Patang AI", domain: "patang-ai.example", city: "Bengaluru", oneLiner: "Voice agents for Indian-language customer support.",
                yc: "W25", stage: .seed, amount: 3_500_000, currency: "USD", usd: 3_500_000, daysAgo: 70,
                investors: ["Peak XV Partners", "Y Combinator"], teamSize: 18, hiring: true, matchingRoles: 2,
                founders: [("Ananya Rao", "Co-founder & CEO"), ("Vikram Shetty", "Co-founder & CTO")],
                reasons: [r("recency", "Fresh funding", 25, 25, "Raised a $3.5M seed round 2 months ago"),
                          r("stage", "Round", 17, 20, "Last round: seed ($3.5M)"),
                          r("investors", "Investors", 15, 15, "Backed by Peak XV Partners and Y Combinator"),
                          r("yc", "Y Combinator", 15, 15, "YC W25"),
                          r("team", "Team size", 10, 10, "Team of 18: small enough that founders still read email"),
                          r("roles", "Open roles for you", 12, 15, "2 open roles match yours")],
                fit: 84, fitSummary: "Go services and payments-grade reliability for a voice platform."),
        Startup(name: "Ledgerline", domain: "ledgerline.example", city: "Pune", oneLiner: "Reconciliation and payouts API for Indian marketplaces.",
                yc: nil, stage: .seriesA, amount: 600_000_000, currency: "INR", usd: 7_142_857, daysAgo: 150,
                investors: ["Blume Ventures", "Elevation Capital"], teamSize: 64, hiring: true, matchingRoles: 3,
                founders: [], reasons: [r("recency", "Fresh funding", 20, 25, "Raised ₹60 crore (~$7.1M) in a Series A round 4 months ago"),
                                        r("stage", "Round", 20, 20, "Last round: Series A (₹60 crore (~$7.1M))"),
                                        r("investors", "Investors", 15, 15, "Backed by Blume Ventures and Elevation Capital"),
                                        r("yc", "Y Combinator", 0, 15, "No YC batch on record", known: false),
                                        r("team", "Team size", 10, 10, "Team of 64: small enough that founders still read email"),
                                        r("roles", "Open roles for you", 15, 15, "3 open roles match yours")],
                fit: 88, fitSummary: "Payments reconciliation is exactly your last two roles."),
        Startup(name: "Nimbu Health", domain: "nimbu-health.example", city: "Bengaluru", oneLiner: "Clinics and a care app for people with diabetes.",
                yc: nil, stage: .seriesA, amount: 350_000_000, currency: "INR", usd: 4_166_667, daysAgo: 300,
                investors: ["Lightbox"], teamSize: 140, hiring: nil, matchingRoles: nil,
                founders: [], reasons: [r("recency", "Fresh funding", 13, 25, "Raised ₹35 crore (~$4.2M) in a Series A round 9 months ago"),
                                        r("stage", "Round", 20, 20, "Last round: Series A (₹35 crore (~$4.2M))"),
                                        r("investors", "Investors", 10, 15, "Backed by Lightbox"),
                                        r("yc", "Y Combinator", 0, 15, "No YC batch on record", known: false),
                                        r("team", "Team size", 10, 10, "Team of 140: small enough that founders still read email"),
                                        r("roles", "Open roles for you", 0, 15, "Open roles not known", known: false)],
                fit: 61, fitSummary: "Backend work on a care app; less overlap with payments."),
    ]

    /// Found by a new "Find startups" in mock mode.
    static let more: [Startup] = [
        Startup(name: "Kolam Data", domain: "kolam-data.example", city: "Chennai", oneLiner: "Data pipelines for regional banks.",
                yc: "S24", stage: .seed, amount: 4_000_000, currency: "USD", usd: 4_000_000, daysAgo: 40,
                investors: ["Accel", "Kalaari Capital"], teamSize: 22, hiring: true, matchingRoles: 1,
                founders: [("Meera Iyer", "Co-founder & CEO"), ("Karthik Raman", "Co-founder & CTO")],
                reasons: [r("recency", "Fresh funding", 25, 25, "Raised a $4M seed round a month ago"),
                          r("stage", "Round", 17, 20, "Last round: seed ($4M)"),
                          r("investors", "Investors", 15, 15, "Backed by Accel and Kalaari Capital"),
                          r("yc", "Y Combinator", 15, 15, "YC S24"),
                          r("team", "Team size", 10, 10, "Team of 22: small enough that founders still read email"),
                          r("roles", "Open roles for you", 12, 15, "1 open role matches yours")],
                fit: 79, fitSummary: "Kafka and Postgres pipelines, close to your platform work."),
        Startup(name: "Tarang Robotics", domain: "tarang-robotics.example", city: "Hyderabad", oneLiner: "Autonomous carts for warehouses.",
                yc: "X26", stage: nil, amount: nil, currency: nil, usd: nil, daysAgo: nil, investors: [], teamSize: 6, hiring: false,
                matchingRoles: nil, founders: [("Rahul Varma", "Founder")],
                reasons: [r("recency", "Fresh funding", 0, 25, "I haven't found a dated funding round", known: false),
                          r("stage", "Round", 0, 20, "Round size and stage not known", known: false),
                          r("investors", "Investors", 0, 15, "Investors not known", known: false),
                          r("yc", "Y Combinator", 15, 15, "YC X26"),
                          r("team", "Team size", 6, 10, "Team of 6: very early, hiring is often founder-led"),
                          r("roles", "Open roles for you", 0, 15, "Not hiring right now, per YC's directory")],
                fit: 42, fitSummary: "Robotics; little overlap with your backend work."),
    ]

    static func companyID(_ name: String) -> Int { 3_000 + (first + more).firstIndex { $0.name == name }! }

    static func item(_ s: Startup, id: Int, now: Date, label: String) -> ProspectItem {
        let score = s.reasons.reduce(0) { $0 + $1.points }
        let confidence = s.reasons.filter(\.known).reduce(0) { $0 + $1.max }
        let date = s.daysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let iso: String? = date.map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: $0)
        }
        let news = "https://news.example/funding/\(s.domain.split(separator: ".")[0])"
        let yc = s.yc.map { _ in "https://www.ycombinator.com/companies/\(s.domain.split(separator: ".")[0])" }
        var sources: [String: CompanyFactsItem.Source] = [:]
        if s.stage != nil {
            let quote = "\(s.city)-based \(s.name) has raised \(CompanyFactsItem.money(s.amount, currency: s.currency) ?? "funding") in its \(s.stage!.label) round"
                + (s.investors.isEmpty ? "." : " led by \(s.investors[0]).")
            for key in ["last_round_stage", "last_round_amount", "last_round_date", "investors"] {
                sources[key] = .init(url: news, quote: quote)
            }
        }
        if let yc { for key in ["yc_batch", "team_size", "is_hiring", "hq_city", "founders"] { sources[key] = .init(url: yc) } }
        let facts = CompanyFactsItem(
            hqCity: s.city, hqCountry: "India", ycBatch: s.yc, ycURL: yc, ycStatus: s.yc == nil ? nil : "Active", industry: nil,
            lastRoundStage: s.stage, lastRoundAmount: s.amount, lastRoundCurrency: s.currency, lastRoundUSD: s.usd, lastRoundDate: iso,
            investors: s.investors, teamSize: s.teamSize, isHiring: s.hiring, openRoles: s.matchingRoles,
            founders: s.founders.map { .init(name: $0.0, title: $0.1) }, sources: sources)
        return ProspectItem(
            id: id, companyID: companyID(s.name), company: s.name, domain: s.domain, status: .suggested, fitScore: s.fit,
            fitSummary: s.fitSummary, summary: s.oneLiner, summaryURL: yc ?? "https://\(s.domain)", matchingRoles: s.matchingRoles,
            foundVia: "startups", searchQuery: label, createdAt: now.addingTimeInterval(-3_600), facts: facts, startupScore: score,
            startupConfidence: confidence, startupReasons: s.reasons, rankScore: Int((0.6 * Double(score) + 0.4 * Double(s.fit)).rounded()))
    }

    /// The first startups, a connection who works at one, and someone in your city at another.
    static func seed(_ o: inout OutreachData, now: Date) {
        var next = (o.prospects.map(\.id).max() ?? 0) + 1
        for s in first {
            o.prospects.append(item(s, id: next, now: now, label: "Bengaluru, India"))
            next += 1
        }
        var ref = (o.referrals.map(\.id).max() ?? 0) + 1
        let patang = companyID("Patang AI")
        o.referrals.append(ReferralItem(
            id: ref, companyID: patang, company: "Patang AI", personName: "Kabir Shah", title: "Backend Engineer",
            linkedinURL: "https://www.linkedin.com/in/kabir-shah-example", basis: .user, basisDetail: "We're connected on LinkedIn.",
            evidenceSnippet: "From your LinkedIn export: Backend Engineer at Patang AI (connected 2025-03-02)", state: .suggested,
            stateUpdatedAt: now.addingTimeInterval(-7_200), createdAt: now.addingTimeInterval(-7_200)))
        ref += 1
        o.referrals.append(ReferralItem(
            id: ref, companyID: patang, company: "Patang AI", personName: "Priya Nair", title: "Software Engineer",
            linkedinURL: "https://www.linkedin.com/in/priya-nair-example", basis: .sameCity, basisDetail: "Bengaluru",
            evidenceURL: "https://www.linkedin.com/in/priya-nair-example",
            evidenceSnippet: "Priya Nair – Software Engineer – Patang AI · Bengaluru, Karnataka, India", state: .suggested,
            stateUpdatedAt: now.addingTimeInterval(-3_600), createdAt: now.addingTimeInterval(-3_600)))
    }

    /// discover_startups: the next startups appear after a moment (filters respected).
    static func discover(_ data: inout RepositoryData, payload p: DiscoverStartupsPayload, label: String) -> Int {
        var next = (data.outreach.prospects.map(\.id).max() ?? 0) + 1
        var added = 0
        for s in more where !data.outreach.prospects.contains(where: { $0.company == s.name }) {
            if p.ycOnly && s.yc == nil { continue }
            if p.hiringOnly && s.hiring != true { continue }
            if !p.stages.isEmpty && !p.stages.contains(where: { $0 == s.stage }) { continue }
            data.outreach.prospects.append(item(s, id: next, now: Date(), label: label))
            next += 1
            added += 1
        }
        data.log("outreach", "startups in \(label): \(added) found")
        return added
    }

    /// scout_top_prospects: the best-ranked open companies, skipping the ones the guardrails block.
    static func topProspects(_ data: RepositoryData, limit: Int) -> (queued: [ProspectItem], skipped: [(ProspectItem, String)]) {
        var queued: [ProspectItem] = []
        var skipped: [(ProspectItem, String)] = []
        let open = data.outreach.prospects.filter { $0.status == .suggested || $0.status == .shortlisted }
            .sorted { ($0.score ?? -1) > ($1.score ?? -1) }
        for p in open {
            if queued.count >= limit { break }
            if let until = p.cooldownUntil, until > Date() {
                skipped.append((p, "\(p.company) is cooling down (no reply last time)"))
                continue
            }
            if data.jobs.contains(where: { $0.companyID == p.companyID && $0.state == .submitted }) {
                skipped.append((p, "you applied to \(p.company): use an application follow-up instead"))
                continue
            }
            queued.append(p)
        }
        return (queued, skipped)
    }

    /// People found at a startup: its founders first (from YC's page), else a recruiter.
    static func people(for p: ProspectItem) -> [(String, String, ContactRoleCategory)] {
        let founders = p.facts?.founders ?? []
        if !founders.isEmpty {
            return founders.map { ($0.name, $0.title ?? "Founder", $0.title?.contains("CTO") == true ? .engLeader : .founder) }
        }
        return [("Riya Sen", "Talent Partner", .recruiter), ("Omar Haddad", "Head of Engineering", .engLeader)]
    }
}
