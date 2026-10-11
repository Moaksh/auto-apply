// RepositoryAndRegistryTests.swift — GRDB read-only repository against the real contract
// schema (incl. cross-connection change detection), the screen registry's runtime feature
// discovery, the shortcut registry, and design-token coverage.
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AutoApply

private let schemaURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("contract/schema.sql")

@Suite("GRDBRepository", .serialized)
struct GRDBRepositoryTests {
    /// A writable DB built from contract/schema.sql (the daemon's role in production).
    func makeDatabase() throws -> (path: String, writer: DatabaseQueue) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aa-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("autoapply.db").path
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let writer = try DatabaseQueue(path: path, configuration: config)
        let sql = try String(contentsOf: schemaURL, encoding: .utf8)
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: sql)
        }
        try writer.write { db in
            try db.execute(sql: "INSERT INTO companies (id, name, normalized_name, domain, ats) VALUES (1, 'Stripe', 'stripe', 'stripe.com', 'greenhouse')")
            try db.execute(sql: """
                INSERT INTO jobs (id, source, apply_url, ats, company_id, title, location, remote, discovered_at, dedupe_key, description)
                VALUES (1, 'greenhouse', 'https://boards.greenhouse.io/stripe/1', 'greenhouse', 1, 'Backend Engineer', 'Remote (India)',
                        'remote', '2026-10-09T09:00:00.000Z', 'stripe|backend engineer|remote', 'Build payments.')
                """)
            try db.execute(sql: "INSERT INTO applications (id, job_id, state) VALUES (11, 1, 'queued')")
            try db.execute(sql: """
                INSERT INTO scores (job_id, score, reasons) VALUES (1, 91, '{"summary":"strong Go","factors":{"skills":95,"salary":70.4}}')
                """)
            try db.execute(sql: """
                INSERT INTO application_answers (application_id, question, answer, confidence, origin, bbox)
                VALUES (11, 'Years with Go?', '4', 0.93, 'cv', '{"x":10,"y":20,"w":300,"h":40}')
                """)
            try db.execute(sql: "INSERT INTO never_guess (key, value) VALUES ('notice_period', '\"60 days\"'), ('salary_negotiable', 'true'), ('sponsorship', 'null')")
            try db.execute(sql: "UPDATE profile SET full_name = 'Moaksh Kakkar', skills = '[\"go\",\"python\"]' WHERE id = 1")
            try db.execute(sql: "INSERT INTO events (kind, message) VALUES ('discover', 'found job'), ('score', 'scored 91')")
            try db.execute(sql: "INSERT INTO resume_variants (id, label, file_path, tags, is_default) VALUES (1, 'Backend', '/r/b.pdf', '[\"go\"]', 1)")
            try db.execute(sql: """
                INSERT INTO easy_apply (job_id, url, drafted_answers) VALUES (1, 'https://linkedin.com/jobs/1',
                '[{"question":"Phone","answer":"+91","origin":"profile","locked":false,"ask_me":false}]')
                """)
        }
        return (path, writer)
    }

    @Test func mapsRowsIntoDomainModels() async throws {
        let (path, _) = try makeDatabase()
        let repo = GRDBRepository(path: path, pollInterval: .milliseconds(50))
        let jobs = await collect(repo.jobs(), count: 1).first ?? []
        let job = try #require(jobs.first)
        #expect(job.company == "Stripe")
        #expect(job.applicationID == 11)
        #expect(job.state == .queued)
        #expect(job.score == 91)
        #expect(job.scoreFactors == ["skills": 95, "salary": 70])
        #expect(job.scoreSummary == "strong Go")
        #expect(job.remote == .remote)
        #expect(job.discoveredAt == ProtocolCoding.date("2026-10-09T09:00:00Z"))
        #expect(await repo.jobDescription(jobID: 1) == "Build payments.")

        let answers = await collect(repo.applicationAnswers(applicationID: 11), count: 1).first ?? []
        #expect(answers.first?.origin == .cv)
        #expect(answers.first?.bbox == CGRect(x: 10, y: 20, width: 300, height: 40))
        #expect(answers.first?.confidenceLevel == .high)

        let ng = await collect(repo.neverGuess(), count: 1).first
        #expect(ng?.noticePeriod == "60 days")
        #expect(ng?.salaryNegotiable == true)
        #expect(ng?.sponsorship == nil)
        let profile = await collect(repo.profile(), count: 1).first
        #expect(profile?.fullName == "Moaksh Kakkar")
        #expect(profile?.skills == ["go", "python"])
        let variants = await collect(repo.resumeVariants(), count: 1).first
        #expect(variants?.first?.isDefault == true)
        let easy = await collect(repo.easyApply(), count: 1).first
        #expect(easy?.first?.draftedAnswers.first?.question == "Phone")
        let activity = await collect(repo.activity(initialLimit: 10), count: 1).first
        #expect(activity?.isInitial == true)
        #expect(activity?.appended.map(\.message) == ["found job", "scored 91"])
    }

    @Test func detectsWritesFromAnotherConnection() async throws {
        let (path, writer) = try makeDatabase()
        let repo = GRDBRepository(path: path, pollInterval: .milliseconds(50))
        let jobsStream = repo.jobs()
        let activityStream = repo.activity(initialLimit: 10)
        let collector = Task { await collect(jobsStream, count: 2, timeout: .seconds(5)) }
        let activityCollector = Task { await collect(activityStream, count: 2, timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(300))
        try await writer.write { db in
            try db.execute(sql: "UPDATE applications SET state = 'prepping' WHERE id = 11")
            try db.execute(sql: "INSERT INTO events (kind, message) VALUES ('state', 'queued → prepping')")
        }
        let emissions = await collector.value
        #expect(emissions.count == 2)
        #expect(emissions.last?.first?.state == .prepping)
        let deltas = await activityCollector.value
        #expect(deltas.last?.isInitial == false)
        #expect(deltas.last?.appended.map(\.message) == ["queued → prepping"], "activity is incremental")
    }

    @Test func missingDatabaseIsUnavailableUntilCreated() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("aa-none-\(UUID().uuidString).db").path
        let repo = GRDBRepository(path: path, pollInterval: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(120))
        #expect(!repo.isAvailable)
    }
}

@objc(AATestRegistryFeature)
final class AATestRegistryFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.resumes) { Text("Registered resumes") }
        registry.registerJobDetail { id in Text("Job \(id)") }
    }
}

@MainActor
@Suite("Registry, shortcuts, tokens")
struct RegistryShortcutTokenTests {
    @Test func discoversFeaturesByRuntimeName() {
        let registry = ScreenRegistry()
        #expect(!registry.isRegistered(.resumes))
        registry.discoverFeatures(extra: ["AATestRegistryFeature", "NoSuchFeatureClass"])
        #expect(registry.isRegistered(.resumes))
        #expect(registry.hasJobDetail)
        #expect(registry.discoveredFeatures.contains("AATestRegistryFeature"))
        #expect(!ScreenRegistry().isRegistered(.dashboard), "a registry before discovery falls back to placeholders")
        registry.discoverFeatures(extra: ["AATestRegistryFeature"])
        #expect(registry.discoveredFeatures.filter { $0 == "AATestRegistryFeature" }.count == 1, "idempotent")
    }

    @Test func everyScreenIsWiredToARealFeature() {
        let registry = ScreenRegistry()
        registry.discoverFeatures()
        for screen in ScreenID.allCases {
            #expect(registry.isRegistered(screen), "\(screen) has no registered view (would render a placeholder)")
        }
        #expect(registry.hasJobDetail, "job detail must be registered by JobDetailFeature")
        for name in ScreenRegistry.featureClassNames {
            #expect(registry.discoveredFeatures.contains(name), "feature class \(name) not discovered")
        }
    }

    @Test func everyScreenHasAnExpectedOwner() {
        for screen in ScreenID.allCases {
            #expect(!screen.expectedViewName.isEmpty)
            #expect(["C2", "C3"].contains(screen.owner))
        }
        #expect(SidebarItem.allCases.count == 10, "⌘1…⌘9 + Cold Email on ⌘0")
        #expect(Set(SidebarItem.allCases.map(\.screen)).count == 10)
    }

    @Test func shortcutsAreUniqueWithinScope() {
        let menu = AppShortcut.allCases.filter { $0.scope == .menu }
        #expect(Set(menu.map(\.combo)).count == menu.count, "duplicate menu shortcut")
        let local = AppShortcut.allCases.filter { $0.scope == .local }
        #expect(Set(local.map(\.combo)).count == local.count, "duplicate local shortcut")
        #expect(AppShortcut.togglePause.displayString == "⇧⌘P")
        #expect(AppShortcut.toggleInspector.displayString == "⌥⌘I")
        #expect(AppShortcut.goActivity.displayString == "⌘9")
        #expect(AppShortcut.approve.displayString == "A")
        for item in SidebarItem.allCases {
            #expect(AppShortcut.go(item).key == KeyEquivalent(Character("\(item.shortcutNumber)")))
        }
    }

    @Test func statusKindsCoverEveryStateAndStatus() {
        for state in AppState.allCases { _ = StatusKind(state: state) }
        #expect(Set(BoardStatus.allCases.map { StatusKind(status: $0) }).count == BoardStatus.allCases.count)
        #expect(Set(StatusKind.allCases.map(\.symbol)).count == StatusKind.allCases.count, "every status has a distinct symbol")
        #expect(StatusKind(state: .failed) == .error)
        #expect(StatusKind(column: .needsYou) == .needsYou)
    }

    @Test func motionResolvesToFadeUnderReduceMotion() {
        #expect(Motion.resolve(Motion.celebrate, reduceMotion: true) == Motion.reducedFade)
        #expect(Motion.resolve(Motion.celebrate, reduceMotion: false) == Motion.celebrate)
        #expect(Motion.staggerDelay(index: 3) == 0.09)
        #expect(Motion.staggerDelay(index: 20) == Motion.staggerDelay(index: 8), "max 8 staggered")
        #expect(Motion.flowEase(0) == 0 && Motion.flowEase(1) == 1)
        #expect(abs(Motion.flowEase(0.5) - 0.5) < 0.0001)
    }

    @Test func routerNavigation() {
        let router = Router()
        router.openJob(id: 4)
        #expect(router.path == [.job(id: 4)])
        router.openJob(id: 4)
        #expect(router.path.count == 1)
        router.go(.needsYou)
        #expect(router.path.isEmpty, "changing section pops the stack")
        router.isPalettePresented = true
        router.isInspectorPresented = true
        router.escape()
        #expect(!router.isPalettePresented && router.isInspectorPresented)
        router.escape()
        #expect(!router.isInspectorPresented)
        router.showPipeline(filter: PipelineFilter(skipReason: "below_threshold", showSkipped: true))
        #expect(router.selection == .pipeline)
        #expect(router.pipelineFilter.showSkipped)
    }

    @Test func leavingPipelineDisarmsJobContext() {
        let router = Router()
        router.go(.pipeline)
        router.focusedJobID = 7
        #expect(router.isJobContextActive)
        router.go(.needsYou)
        #expect(router.focusedJobID == nil, "focus doesn't survive leaving Pipeline")
        #expect(!router.isJobContextActive)
        router.openJob(id: 9)                 // pushed detail from another section
        #expect(router.isJobContextActive)
        router.back()
        #expect(!router.isJobContextActive, "Needs You without a pushed job is not a job context")
    }

    @Test func toastQueueCoalescesAndAdvances() {
        let toasts = ToastCenter()
        toasts.show("Copied")
        toasts.show("Copied")
        toasts.show("Moved")
        #expect(toasts.current?.message == "Copied")
        #expect(toasts.queue.map(\.message) == ["Moved"])
        toasts.dismiss()
        #expect(toasts.current?.message == "Moved")
    }
}
