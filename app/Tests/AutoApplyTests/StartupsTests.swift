// StartupsTests.swift — Startups near you (schema v14): company facts and the startup score read
// from the real contract schema, the model's filters and formatting, the store's commands through
// the mock daemon (discover, find people at the top N, people in your city), and the Companies tab
// rendering with one primary action in either finder.
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AutoApply

private let schemaURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("contract/schema.sql")

@MainActor
@Suite("Startups near you", .serialized)
struct StartupsTests {

    // MARK: Decoding (GRDB, contract schema)

    @Test func factsAndScoreDecodeFromTheContractSchema() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aa-startups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("autoapply.db").path
        let writer = try DatabaseQueue(path: path)
        let sql = try String(contentsOf: schemaURL, encoding: .utf8)
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: sql)
        }
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO companies (id, name, normalized_name, domain) VALUES (1, 'Kolam Data', 'kolam data', 'kolam.example'), (2, 'Plain Co', 'plain co', NULL)")
            try db.execute(sql: """
                INSERT INTO prospects (company_id, status, fit_score, fit_reasons, found_via, search_query, startup_score, startup_confidence,
                                       startup_reasons, rank_score)
                VALUES (1, 'suggested', 70, '{"summary":"data infra"}', 'startups', 'Chennai, India', 94, 100,
                        '[{"key":"recency","label":"Fresh funding","points":25,"max":25,"reason":"Raised a $4M seed round 2 months ago","known":true},
                          {"key":"yc","label":"Y Combinator","points":0,"max":15,"reason":"No YC batch on record","known":false}]', 84),
                       (2, 'suggested', 90, '{}', 'search', NULL, NULL, 0, '[]', 90)
                """)
            try db.execute(sql: """
                INSERT INTO company_facts (company_id, hq_city, hq_country, yc_batch, last_round_stage, last_round_amount, last_round_currency,
                                           last_round_usd, last_round_date, investors, team_size, is_hiring, founders, sources)
                VALUES (1, 'Chennai', 'India', 'S24', 'seed', 4000000, 'USD', 4000000, '2026-08-14', '["Peak XV Partners","Blume Ventures"]',
                        22, 1, '[{"name":"Meera Iyer","title":"CEO"}]',
                        '{"last_round_amount":{"url":"https://news.example/a","quote":"raised $4 million"},
                          "last_round_stage":{"url":"https://news.example/a","quote":"raised $4 million"},
                          "yc_batch":{"url":"https://www.ycombinator.com/companies/kolam"}}')
                """)
        }
        let repo = GRDBRepository(path: path, pollInterval: .milliseconds(50))
        let data = try #require(await collect(repo.outreach(), count: 1).first)
        #expect(data.prospects.map(\.company) == ["Plain Co", "Kolam Data"], "ordered by rank (90, 84)")
        let p = try #require(data.prospects.first { $0.company == "Kolam Data" })
        #expect(p.startupScore == 94 && p.startupConfidence == 100 && p.rankScore == 84 && p.score == 84)
        #expect(p.startupReasons.map(\.key) == ["recency", "yc"] && p.startupReasons[1].known == false)
        #expect(p.startupReasons[0].reason == "Raised a $4M seed round 2 months ago" && p.startupReasons[0].max == 25)
        let f = try #require(p.facts)
        #expect(f.lastRoundStage == .seed && f.amountLabel == "$4M" && f.ycLabel == "YC S24" && f.teamSize == 22 && f.isHiring == true)
        #expect(f.investors == ["Peak XV Partners", "Blume Ventures"] && f.founders.first?.name == "Meera Iyer")
        #expect(f.roundDateLabel == "Aug 2026")
        #expect(p.factsLine == "Seed · $4M · Aug 2026 · YC S24 · Chennai")
        let links = f.sourceLinks
        #expect(links.count == 2)
        #expect(links.first { $0.url == "https://news.example/a" }?.facts == ["Last round"])
        #expect(links.first { $0.url == "https://news.example/a" }?.quote == "raised $4 million")
        let plain = try #require(data.prospects.first { $0.company == "Plain Co" })
        #expect(plain.facts == nil && plain.startupReasons.isEmpty && plain.startupScore == nil)
    }

    @Test func moneyAndLabels() {
        #expect(CompanyFactsItem.money(4_000_000, currency: "USD") == "$4M")
        #expect(CompanyFactsItem.money(750_000, currency: "USD") == "$750K")
        #expect(CompanyFactsItem.money(350_000_000, currency: "INR") == "₹35 crore")
        #expect(CompanyFactsItem.money(500_000, currency: "INR") == "₹5 lakh")
        #expect(CompanyFactsItem.money(3_000_000, currency: "EUR") == "€3M")
        #expect(CompanyFactsItem.money(nil, currency: "USD") == nil)
        let inr = CompanyFactsItem(lastRoundAmount: 350_000_000, lastRoundCurrency: "INR", lastRoundUSD: 4_166_667)
        #expect(inr.usdNote == "≈ $4.2M")
        #expect(FundingStage.seriesDPlus.label == "Series D+")
        let r = ReferralItem(id: 1, companyID: 1, company: "Lab0", personName: "Priya", basis: .sameCity, basisDetail: "Bengaluru",
                             stateUpdatedAt: Date(), createdAt: Date())
        #expect(r.basisLabel == "Same city · Bengaluru")
    }

    // MARK: Store + mock daemon

    func mockStore() async -> AppStore {
        let daemon = MockDaemon(scenario: .idle, speed: 50)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.outreach.isLoaded && store.isConnected }
        return store
    }

    @Test func mockSeedsStartupsRankedWithFacts() async {
        let store = await mockStore()
        let startups = store.outreach.activeProspects.filter { $0.foundVia == "startups" }
        #expect(startups.map(\.company).sorted() == ["Ledgerline", "Nimbu Health", "Patang AI"])
        #expect(startups.allSatisfy { $0.facts != nil && !$0.startupReasons.isEmpty && $0.rankScore != nil })
        let scores = store.outreach.activeProspects.compactMap(\.score)
        #expect(scores == scores.sorted(by: >), "best first")
        let patang = startups.first { $0.company == "Patang AI" }!
        #expect(store.outreach.referrals(companyID: patang.companyID).map(\.basis) == [.user, .sameCity], "your connection first")
        await store.stop()
    }

    @Test func filtersShapeTheList() async {
        let store = await mockStore()
        let model = ColdEmailModel(store: store)
        #expect(model.prospectFinder == .startups)
        let all = model.visibleProspects.count
        model.startupsYCOnly = true
        #expect(model.visibleProspects.map(\.company) == ["Patang AI"])
        model.startupsYCOnly = false
        model.startupStage = .seriesA
        #expect(Set(model.visibleProspects.map(\.company)) == ["Ledgerline", "Nimbu Health"])
        model.startupStage = .any
        model.startupsHiringOnly = true
        #expect(!model.visibleProspects.contains { $0.company == "Nimbu Health" })
        model.startupsHiringOnly = false
        #expect(model.visibleProspects.count == all)
        model.prospectFinder = .search
        model.startupsYCOnly = true
        #expect(model.visibleProspects.count == all, "filters only apply to Startups near you")
        model.prefillStartupLocation()
        #expect(model.startupLocation == "Bangalore, India" && model.homeCity == "Bangalore")
        await store.stop()
    }

    @Test func discoverFindPeopleAndPeopleNearYouThroughTheMock() async {
        let store = await mockStore()
        let model = ColdEmailModel(store: store)
        model.prefillStartupLocation()
        await model.discoverStartups()
        #expect(await waitUntil { store.outreach.data.prospects.contains { $0.company == "Kolam Data" } })
        let kolam = store.outreach.data.prospects.first { $0.company == "Kolam Data" }!
        #expect(kolam.facts?.ycBatch == "S24" && kolam.searchQuery == "Bangalore, India")

        let shortlisted = store.outreach.activeProspects.filter { $0.status == .shortlisted }.count
        #expect(await store.scoutTopProspects(limit: ColdEmailModel.topN) == ColdEmailModel.topN)
        // Companies already shortlisted stay; suggested ones among the top become shortlisted.
        #expect(store.outreach.activeProspects.filter { $0.status == .shortlisted }.count > shortlisted)
        let best = store.outreach.activeProspects.first { $0.company == "Ledgerline" }!
        #expect(await waitUntil { !store.outreach.contacts(companyID: best.companyID).isEmpty })

        #expect(await store.suggestReferrers(companyID: kolam.companyID, location: "Bangalore"))
        #expect(await waitUntil { store.outreach.referrals(companyID: kolam.companyID).contains { $0.basis == .sameCity } })
        await store.stop()
    }

    // MARK: Render + one primary

    private func render<V: View>(store: AppStore, scheme: ColorScheme = .light, @ViewBuilder _ view: () -> V) -> (CGImage?, Int) {
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

    @Test func companiesTabRendersStartupsWithOnePrimary() async {
        let store = await mockStore()
        for finder in ProspectFinder.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let model = ColdEmailModel(store: store)
                model.tab = .prospects
                model.prospectFinder = finder
                model.selectedProspectID = store.outreach.activeProspects.first { $0.company == "Patang AI" }?.id
                let (image, primaries) = render(store: store, scheme: scheme) { ColdEmailView(modelOverride: model) }
                #expect(image != nil, "Companies (\(finder.rawValue))")
                #expect(primaries == 1, "Companies ▸ \(finder.title) shows \(primaries) primary actions")
                await Task.yield()
            }
        }
        // A company with nothing known renders without the Funding & signals section.
        let model = ColdEmailModel(store: store)
        model.tab = .prospects
        model.prospectFinder = .search
        model.selectedProspectID = store.outreach.activeProspects.first { $0.facts == nil }?.id
        #expect(render(store: store) { ColdEmailView(modelOverride: model) }.0 != nil)
        await store.stop()
    }
}
