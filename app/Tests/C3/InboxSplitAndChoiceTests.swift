// InboxSplitAndChoiceTests.swift — Needs-You split into agent blockers ("actions") and form
// questions, the "Done, retry" flow (never saved to memory), and the choice picker logic.
import Foundation
import Testing
@testable import AutoApply

private func action(_ id: String, jobs: [Int], question: String, type: String = "account", companies: [String] = ["JPMC"]) -> QuestionCluster {
    var c = C3Fixtures.cluster(id, jobs: jobs, question: question, companies: companies)
    c.kind = "action"
    c.actionType = type
    return c
}

@MainActor
@Suite("C3 · Inbox split (actions vs questions)", .serialized)
struct InboxSplitTests {
    private func setup(_ clusters: [QuestionCluster]) async -> (AppStore, C3StubDaemon, InboxModel) {
        var data = RepositoryData()
        data.jobs = [1, 2, 3, 4].map { C3Fixtures.job(id: $0, company: ["JPMC", "Bayer", "Stripe", "Ramp"][$0 - 1], state: .needsYou) }
        let (store, daemon, _) = await makeC3Store(data: data, clusters: clusters)
        let model = InboxModel(store: store)
        model.clipboard = RecordingClipboard()
        model.undoWindow = .milliseconds(100)
        _ = await c3WaitUntil { store.inbox.openCount == clusters.count }
        return (store, daemon, model)
    }

    @Test func actionsComeFirstInTheirOwnSectionAndCountsSplit() async {
        let (store, _, model) = await setup([
            C3Fixtures.cluster("q_big", jobs: [1, 2, 3], question: "Notice period?"),
            action("a_account", jobs: [1], question: "Account required to apply at jpmc.fa.oraclecloud.com"),
            C3Fixtures.cluster("q_small", jobs: [4], question: "Years of Go?", fieldType: .number),
        ])
        #expect(model.actionClusters.map(\.clusterId) == ["a_account"])
        #expect(model.questionClusters.map(\.clusterId) == ["q_big", "q_small"])
        // List order (and keyboard navigation) puts the blocker first even with fewer jobs.
        #expect(model.clusters.map(\.clusterId) == ["a_account", "q_big", "q_small"])
        #expect(store.inbox.clusters.first?.clusterId == "a_account")
        #expect(model.summary == "1 to do · 2 questions")
        #expect(store.inbox.summary == "1 to do · 2 questions")
        model.ensureSelection()
        #expect(model.selectedClusterID == "a_account")
        #expect(model.title(for: model.clusters[0]) == "Create an account or sign in at JPMC")
        #expect(model.kind(for: model.clusters[0]) == .action)
        #expect(!AnswerDraft(cluster: model.clusters[0]).saveToMemory)
    }

    @Test func doneRetrySendsNoMemoryAndSubmitShortcutDoesTheSame() async throws {
        let (_, daemon, model) = await setup([
            action("a_account", jobs: [1, 2], question: "Choose Password", companies: ["Bayer"]),
            C3Fixtures.cluster("q", jobs: [3], question: "Notice period?"),
        ])
        model.ensureSelection()
        #expect(model.selectedClusterID == "a_account")
        // ⌘↩ (submitSelected) on an action == "Done, retry": no text needed.
        #expect(model.submitSelected())
        #expect(model.clusters.map(\.clusterId) == ["q"])
        #expect(await c3WaitUntil { daemon.sent("answer_question").count == 1 })
        let payload = try #require(daemon.sent("answer_question").first?.answerPayload)
        #expect(payload.clusterId == "a_account")
        #expect(!payload.saveToMemory)
        #expect(!payload.saveToProfile)
        #expect(payload.perJobAnswers.isEmpty)
    }

    @Test func olderDaemonCaptchaReadsAsAnAction() {
        var c = C3Fixtures.cluster("c", jobs: [1], question: "Solve the CAPTCHA")
        c.reason = .captcha
        #expect(c.isAction && c.action == .captcha)
        var unknown = C3Fixtures.cluster("u", jobs: [1], question: "x")
        unknown.kind = "something_new"
        #expect(!unknown.isAction)
        #expect(InboxStore.summary(actions: 3, questions: 34) == "3 to do · 34 questions")
        #expect(InboxStore.summary(actions: 0, questions: 1) == "1 question")
    }
}

@Suite("C3 · Choice picker")
struct ChoicePickerTests {
    @Test func optionsDecideTheComposerNotFieldType() {
        let scale = C3Fixtures.cluster("s", jobs: [1], question: "Comfortable with working from office?",
                                       options: ["Strong No", "No", "Yes", "Strong Yes"])  // field_type text
        #expect(AnswerKind(cluster: scale) == .choice(multi: false))
        #expect(ChoiceLogic.allowsOther(scale))
        let strict = C3Fixtures.cluster("a", jobs: [1], question: "Availability", fieldType: .select,
                                        options: ["Immediate", "Less than 30 days", "30 days", "More than 30 days"])
        #expect(!ChoiceLogic.allowsOther(strict))
        #expect(AnswerKind(cluster: C3Fixtures.cluster("m", jobs: [1], question: "Stack", fieldType: .multiselect, options: ["Go", "Rust"])) == .choice(multi: true))
        #expect(AnswerKind(cluster: C3Fixtures.cluster("b", jobs: [1], question: "Relocate?", fieldType: .boolean)) == .yesNo)
    }

    @Test func chipsForFewShortOptionsSearchForMore() {
        #expect(ChoiceLogic.style(for: ["Strong No", "No", "Yes", "Strong Yes"]) == .chips)
        #expect(ChoiceLogic.style(for: (1...8).map { "Option \($0)" }) == .searchable)
        #expect(ChoiceLogic.style(for: ["Yes", "A very long option label that would not fit as a chip"]) == .searchable)
        let countries = ["India", "Indonesia", "Ireland", "United States"]
        #expect(ChoiceLogic.filter(countries, query: "ind") == ["India", "Indonesia"])
        #expect(ChoiceLogic.filter(countries, query: " ") == countries)
    }

    @Test func numberKeysAndPicking() {
        let opts = ["Strong No", "No", "Yes", "Strong Yes"]
        #expect(ChoiceLogic.option(forKey: "3", in: opts) == "Yes")
        #expect(ChoiceLogic.option(forKey: "5", in: opts) == nil)
        #expect(ChoiceLogic.option(forKey: "0", in: opts) == nil)
        #expect(ChoiceLogic.pick("Yes", in: ["No"], multi: false, order: opts) == ["Yes"])
        #expect(ChoiceLogic.pick("Strong No", in: ["Yes"], multi: true, order: opts) == ["Strong No", "Yes"])
        #expect(ChoiceLogic.pick("Yes", in: ["Strong No", "Yes"], multi: true, order: opts) == ["Strong No"])
        #expect(ChoiceLogic.match("strong yes", options: opts, multi: false) == ["Strong Yes"])
        #expect(ChoiceLogic.match("Maybe", options: opts, multi: false) == nil)
    }

    @Test func choiceResolvesToTheExactOptionOrOtherText() throws {
        var d = AnswerDraft()
        d.choices = ["Strong Yes"]
        #expect(try AnswerComposerLogic.resolve(d, kind: .choice(multi: false), jobIDs: [1]).get().answer == "Strong Yes")
        d.useOther = true
        d.text = "  Hybrid only "
        #expect(try AnswerComposerLogic.resolve(d, kind: .choice(multi: false), jobIDs: [1]).get().answer == "Hybrid only")
        d.text = ""
        #expect(AnswerComposerLogic.resolve(d, kind: .choice(multi: false), jobIDs: [1]) == .failure(.empty))
    }
}
