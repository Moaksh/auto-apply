// AutonomyTests.swift — earned autonomy (protocol.md §5.3.1): the one-time suggestion toast, its two
// choices, the mock `get_autonomy` / `dismiss_autonomy_suggestion`, and the Settings trust line.
import Foundation
import Testing
@testable import AutoApply

@MainActor
@Suite("Earned autonomy", .serialized)
struct AutonomyTests {
    func makeStore() -> (AppStore, StubDaemon) {
        let daemon = StubDaemon()
        let store = AppStore(client: daemon, repository: InMemoryRepository(RepositoryData()))
        store.commandTimeout = .milliseconds(200)
        return (store, daemon)
    }

    func suggestion() -> EventEnvelope {
        EventEnvelope(event: .autonomySuggestion(AutonomySuggestionPayload(ats: .greenhouse, cleanApprovals: 10, since: Samples.now)))
    }

    @Test func suggestionShowsOneCalmToastWithTwoChoices() {
        let (store, _) = makeStore()
        store.apply(suggestion())
        let toast = store.toasts.current
        #expect(toast?.message == "10 Greenhouse applications approved without changes")
        #expect(toast?.actionTitle == "Turn on Auto for Greenhouse")
        #expect(toast?.secondaryTitle == "Not now")
        #expect(toast?.style == .info)
    }

    @Test func turnOnAutoSendsThePerSiteMode() async {
        let (store, daemon) = makeStore()
        store.apply(suggestion())
        store.toasts.performAction()
        #expect(store.toasts.current == nil || store.toasts.current?.actionTitle == nil)
        let sent = await waitUntil {
            daemon.sent.contains { if case .updatePreferences(let p) = $0 { return p.preferences.values["per_ats_mode"] != nil } else { return false } }
        }
        #expect(sent)
        let patch = daemon.sent.compactMap { if case .updatePreferences(let p) = $0 { return p.preferences.values["per_ats_mode"] } else { return nil } }.first
        #expect(patch == .object(["workday": .string("review"), "greenhouse": .string("auto")]), "merged with the existing per-site map")
    }

    @Test func notNowDismissesTheSuggestion() async {
        let (store, daemon) = makeStore()
        store.apply(suggestion())
        store.toasts.performSecondaryAction()
        let sent = await waitUntil {
            daemon.sent.contains { if case .dismissAutonomySuggestion(let p) = $0 { return p.ats == .greenhouse } else { return false } }
        }
        #expect(sent)
        #expect(!daemon.sent.contains { if case .updatePreferences = $0 { return true } else { return false } }, "Not now changes no mode")
    }

    @Test func mockReportsTrustAndRemembersNotNow() async {
        let world = MockDaemon(scenario: .idle, speed: 400).world
        world.mutate { $0.preferences.mode = .review; $0.preferences.perAtsMode = [:] }
        func greenhouse() -> AutonomySite? { MockCommandHandler.autonomyReport(world).sites.first { $0.ats == .greenhouse } }
        #expect(greenhouse()?.suggestion == .pending && greenhouse()?.cleanApprovals == 12)
        #expect(MockCommandHandler.autonomyReport(world).sites.count == Ats.allCases.count)
        _ = await MockCommandHandler.handle(.dismissAutonomySuggestion(DismissAutonomySuggestionPayload(ats: .greenhouse)), world: world)
        #expect(greenhouse()?.suggestion == .dismissed)
        world.mutate { $0.preferences.perAtsMode = ["greenhouse": .auto] }
        #expect(greenhouse()?.suggestion == AutonomySite.Suggestion.none && greenhouse()?.mode == .auto && greenhouse()?.modeSource == .site)
    }

    @Test func trustLineReadsPlainly() {
        var site = AutonomySite(ats: .greenhouse, mode: .review, modeSource: .global, approved: 13, approvedWithoutEdits: 12, edited: 1,
                                cleanApprovals: 12, eligible: true, suggestion: .pending)
        #expect(SiteTrustLine.summary(site) == "12 approved without edits · Auto suggested")
        site.suggestion = .dismissed
        #expect(SiteTrustLine.summary(site) == "12 approved without edits · 1 edited")
        site.rejectedWrongAnswers = 2
        #expect(SiteTrustLine.summary(site) == "12 approved without edits · 1 edited · 2 skipped for wrong answers")
    }
}
