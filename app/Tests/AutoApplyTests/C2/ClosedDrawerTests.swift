// ClosedDrawerTests.swift — a kind no (1F) on the Pipeline: Rejected and Ghosted fold into a
// quiet "Closed" drawer (collapsed by default, with a count), closing a card is named kindly and
// makes no sound, and the rejection card in Replies offers a facts-only thank-you note.
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("1F · Closed drawer", .serialized)
struct ClosedDrawerTests {
    @Test func drawerHoldsRejectedAndGhosted() {
        let visible = BoardColumn.defaultVisible
        #expect(BoardRules.drawerColumns(visible) == [.rejected, .ghosted])
        #expect(!BoardRules.openColumns(visible).contains(.rejected))
        #expect(!BoardRules.openColumns(visible).contains(.ghosted))
        #expect(BoardRules.openColumns(visible).last == .offer)
        // Arrow keys skip the folded drawer, and walk into it once it's open.
        #expect(BoardRules.navigableColumns(visible, drawerOpen: false) == BoardRules.openColumns(visible))
        #expect(BoardRules.navigableColumns(visible, drawerOpen: true) == visible)
        // A filter that asks for a closed column (a funnel click) opens it.
        #expect(BoardRules.drawerForcedOpen(filter: PipelineFilter(columns: [.rejected])))
        #expect(!BoardRules.drawerForcedOpen(filter: PipelineFilter(columns: [.interview])))
        #expect(!BoardRules.drawerForcedOpen(filter: PipelineFilter()))
    }

    @Test func kindWords() {
        #expect(BoardRules.moveLabel(.rejected) == "Closed · they went another way")
        #expect(BoardRules.moveLabel(.ghosted) == "Closed · no reply")
        #expect(BoardRules.moveLabel(.interview) == "Interview")
        #expect(BoardRules.closedTitle(.rejected) == "They went another way")
        #expect(BoardRules.closedSymbol(.rejected) != StatusKind.rejected.symbol, "a soft fold, not an X")
    }

    @Test func drawerCollapsesAndExpands() {
        let (store, _) = C2.store(jobs: [])
        let model = BoardModel(store: store)
        #expect(!model.closedExpanded, "collapsed by default")
        model.toggleClosed()
        #expect(model.closedExpanded)
        model.toggleClosed()
        #expect(!model.closedExpanded)
    }

    @Test func closingACardIsQuietAndKind() async {
        let (store, daemon) = C2.store(jobs: [C2.job(id: 1, state: .submitted, status: .applied)])
        let model = BoardModel(store: store)
        model.defaults = C2.isolatedDefaults()
        #expect(await model.move(jobID: 1, to: .rejected))
        #expect(C2.sentStatuses(daemon) == [.rejected])
        #expect(store.toasts.current?.message == "Closed · they went another way")
        #expect(store.toasts.current?.style == .info, "not a success flash, not an error")
        #expect(store.toasts.current?.actionTitle == "Undo")
    }

    @Test func thankYouNoteUsesOnlyKnownFacts() {
        let note = KindNo.thankYouNote(senderName: "Dana Lee", role: "Backend Engineer", company: "Acme", firstName: "Asha")
        #expect(note.hasPrefix("Hi Dana,"))
        #expect(note.contains("the Backend Engineer role at Acme"))
        #expect(note.contains("feedback"))
        #expect(note.hasSuffix("Asha"))
        let bare = KindNo.thankYouNote(senderName: nil, role: nil, company: nil, firstName: nil)
        #expect(bare.hasPrefix("Hello,"))
        #expect(!bare.contains("about the"))
        let reply = ApplicationReplyItem(id: 1, applicationID: 1, messageID: "<m@x>", fromEmail: "a@acme.com", subject: "Update",
                                         snippet: "", receivedAt: Samples.now, label: .other, suggestedStatus: .rejected)
        #expect(KindNo.applies(reply))
    }

    // MARK: Render

    private func render<V: View>(_ store: AppStore, width: CGFloat, height: CGFloat, scheme: ColorScheme, @ViewBuilder _ view: () -> V) -> CGImage? {
        let renderer = ImageRenderer(content: view()
            .appEnvironment(store, simulateReduceMotion: true)
            .frame(width: width, height: height)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme))
        renderer.scale = 1
        return renderer.cgImage
    }

    @Test func boardRendersWithTheDrawerFoldedAndOpen() async {
        var rejected = C2.job(id: 3, company: "Acme", state: .submitted, status: .rejected)
        rejected.submittedAt = Samples.now
        let jobs = [C2.job(id: 1, state: .submitted, status: .applied), C2.job(id: 2, state: .submitted, status: .interview),
                    rejected, C2.job(id: 4, state: .submitted, status: .ghosted)]
        let (store, _) = C2.store(jobs: jobs)
        let model = BoardModel(store: store)
        model.defaults = C2.isolatedDefaults()
        for scheme in [ColorScheme.light, .dark] {
            #expect(render(store, width: 1400, height: 700, scheme: scheme) { BoardView(model: model) } != nil)
        }
        model.toggleClosed()
        for scheme in [ColorScheme.light, .dark] {
            #expect(render(store, width: 1800, height: 700, scheme: scheme) { BoardView(model: model) } != nil)
        }
    }

    @Test func rejectionCardRenders() {
        let (store, _) = C2.store(jobs: [C2.job(id: 1, company: "Acme", state: .submitted, status: .applied)])
        let reply = ApplicationReplyItem(id: 1, applicationID: 1, messageID: "<m@x>", fromEmail: "a@acme.com", fromName: "Dana Lee",
                                         subject: "Your application", snippet: "We've decided to move forward with other candidates.",
                                         receivedAt: Samples.now, label: .rejection, suggestedStatus: .rejected, suggestionState: .pending)
        for scheme in [ColorScheme.light, .dark] {
            #expect(render(store, width: 640, height: 240, scheme: scheme) { KindNoCard(reply: reply).padding() } != nil)
        }
    }
}
