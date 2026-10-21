// InterviewPrepPane.swift — Job detail ▸ Interview prep: likely questions grouped by kind (each
// behavioural one with your best-matching story as a STAR outline, or the "no story fits" gap
// with a link to the Story Bank), questions to ask, the company brief (only when AutoApply has
// stored something), the checklist with links, and the debrief: your notes → went well / gaps /
// follow-ups and a thank-you draft you can copy. Nothing here is sent.
// One primary action: "Prepare for this interview" until a pack exists, then "Write debrief".
import AppKit
import SwiftUI

struct InterviewPrepPane: View {
    var job: JobItem
    var model: InterviewPrepModel
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    private var applicationID: Int? { job.applicationID }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            packSection
            Divider()
            DebriefSection(applicationID: applicationID, model: model, isPrimary: model.pack(applicationID) != nil)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder
    private var packSection: some View {
        let generating = applicationID.map { model.generating.contains($0) } ?? false
        if generating && model.pack(applicationID) == nil {
            LoadingState(message: "Writing your prep from the job and your stories. This can take a minute…")
                .frame(height: 160)
        } else {
            switch model.state(applicationID) {
            case .unknown, .loading:
                LoadingState(message: "Looking for your prep…").frame(height: 120)
            case .failed(let message):
                ErrorState(title: "Couldn't read your interview prep", message: message, compact: true, actionTitle: "Try again") {
                    Task { await model.load(applicationID: applicationID, force: true) }
                }
            case .empty:
                VStack(alignment: .leading, spacing: Space.s) {
                    EmptyState(symbol: "person.crop.rectangle.stack", title: "No interview prep yet",
                               message: "Likely questions with the stories from your Story Bank that fit them, questions to ask, and a checklist. Built only from the job description, what AutoApply has stored about \(job.company), and your profile, resume and stories. Uses one Claude request.",
                               actionTitle: "Prepare for this interview", isPrimary: true) {
                        Task { await model.generate(applicationID: applicationID, force: false) }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!store.isConnected)
                    generateError
                }
            case .ready:
                if let pack = model.pack(applicationID) { PrepPackView(pack: pack, model: model, generating: generating, generateError: generateErrorText) }
            }
        }
    }

    private var generateErrorText: String? { applicationID.flatMap { model.generateErrors[$0] } }

    @ViewBuilder
    private var generateError: some View {
        if let text = generateErrorText {
            ErrorState(title: text, compact: true)
        }
    }
}

/// A written pack.
private struct PrepPackView: View {
    var pack: InterviewPrepPack
    var model: InterviewPrepModel
    var generating: Bool
    var generateError: String?
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(provenance).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Spacer(minLength: Space.s)
                if generating { ProgressView().controlSize(.small) }
                Button(generating ? "Rewriting…" : "Regenerate") {
                    Task { await model.generate(applicationID: pack.applicationId, force: true) }
                }
                .buttonStyle(.secondaryLink)
                .disabled(generating || !store.isConnected)
                .help("Write the pack again (one more Claude request). Useful after you add stories.")
            }
            if let generateError { ErrorState(title: generateError, compact: true) }
            if !pack.unsupportedClaims.isEmpty {
                Label(pack.unsupportedClaims.count == 1
                      ? "1 line the model wrote wasn't backed by your profile or stories, so it was left out."
                      : "\(pack.unsupportedClaims.count) lines the model wrote weren't backed by your profile or stories, so they were left out.",
                      systemImage: "checkmark.shield")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .help(pack.unsupportedClaims.joined(separator: "\n"))
            }
            questions
            if !pack.questionsToAsk.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionHeader("Questions to ask them")
                    ForEach(Array(pack.questionsToAsk.enumerated()), id: \.offset) { _, q in
                        Label(q, systemImage: "questionmark.bubble")
                            .font(Typography.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let brief = pack.companyBrief { CompanyBriefView(brief: brief) }
            if !pack.checklist.isEmpty { ChecklistView(items: pack.checklist) }
        }
    }

    private var provenance: String {
        let when = pack.generatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let how = pack.trigger == .statusChange ? "Written automatically when this moved to \((pack.status ?? .interview).label)" : "Written on request"
        return "\(how) · \(when) · from your profile, resume and stories"
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionHeader("Likely questions")
            if pack.questions.isEmpty {
                Text("No questions in this pack.").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            ForEach(InterviewPrepModel.grouped(pack.questions), id: \.kind) { group in
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(group.kind.title).font(Typography.bodyEmph)
                    ForEach(Array(group.questions.enumerated()), id: \.offset) { _, q in
                        QuestionRow(question: q)
                    }
                }
            }
        }
    }
}

private struct QuestionRow: View {
    var question: InterviewQuestion
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(question.question).font(Typography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let basis = question.basis, !basis.isEmpty {
                Text("Why it may come up: \(basis)").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.kind == .behavioural {
                if let star = question.star, let title = question.storyTitle {
                    StarOutlineView(title: title, star: star, fromStory: question.starSource == .story)
                } else if let gap = question.storyGap {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Image(systemName: "text.badge.plus").foregroundStyle(Palette.needsYou)
                        Text("No story fits yet. \(gap)").font(Typography.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Space.s)
                        Button("Add one in Story Bank") { router.go(.stories) }
                            .buttonStyle(.secondaryLink)
                            .font(Typography.callout)
                            .fixedSize()
                    }
                    .padding(Space.s)
                    .well()
                }
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
    }
}

/// Talking points for one story, in STAR order.
private struct StarOutlineView: View {
    var title: String
    var star: StarOutline
    var fromStory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Badge(title, symbol: "text.book.closed", tone: .accent, accessibilityText: "Your story: \(title)")
                if fromStory {
                    Text("In your story's own words").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                }
            }
            ForEach(lines, id: \.letter) { line in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(line.letter).font(Typography.monoSmall).foregroundStyle(Palette.textSecondary).frame(width: 14, alignment: .leading)
                        .accessibilityLabel(line.name)
                    Text(line.text).font(Typography.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }

    private var lines: [(letter: String, name: String, text: String)] {
        [("S", "Situation", star.situation), ("T", "Task", star.task), ("A", "Action", star.action), ("R", "Result", star.result)]
            .filter { !$0.2.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

private struct CompanyBriefView: View {
    var brief: CompanyBrief

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("About \(brief.name)")
            if let summary = brief.summary, !summary.isEmpty {
                Text(summary).font(Typography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.l) {
                if let domain = brief.domain { Text(domain).font(Typography.mono).foregroundStyle(Palette.textSecondary) }
                link("Where this summary came from", brief.summaryUrl)
                link("Careers page", brief.careersUrl)
            }
            if !brief.otherRoles.isEmpty {
                Text("Other roles seen there: \(brief.otherRoles.joined(separator: " · "))")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Only what AutoApply already stored; nothing new was looked up.")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
        }
    }

    @ViewBuilder
    private func link(_ title: String, _ raw: String?) -> some View {
        if let url = raw.flatMap(URL.init(string:)) {
            Button(title) { NSWorkspace.shared.open(url) }.buttonStyle(.secondaryLink).font(Typography.callout)
        }
    }
}

private struct ChecklistView: View {
    var items: [ChecklistItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Checklist")
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: "checklist").foregroundStyle(Palette.textTertiary)
                    Text(item.text).font(Typography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.s)
                    if item.source != .general { Badge(item.source.label) }
                    if let url = item.url.flatMap(URL.init(string:)) {
                        Button("Open") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.secondaryLink)
                            .help(url.absoluteString)
                    }
                }
            }
        }
    }
}

// MARK: - Debrief

/// Notes → debrief. The thank-you draft is only ever copied by you; AutoApply never sends it.
private struct DebriefSection: View {
    var applicationID: Int?
    var model: InterviewPrepModel
    /// The pane's one primary action once a pack exists (before that, "Prepare" is).
    var isPrimary: Bool
    @Environment(AppStore.self) private var store
    @State private var copied = false

    var body: some View {
        let id = applicationID ?? -1
        let busy = model.debriefing.contains(id)
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("After the interview")
            Text("Write what happened in your own words. You get what went well, gaps and follow-ups, plus a thank-you draft to copy. Nothing is sent.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(get: { model.notes[id] ?? "" }, set: { model.notes[id] = $0 }))
                .font(Typography.body)
                .frame(minHeight: 96, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(Space.xs)
                .well()
                .accessibilityLabel("Interview notes")
            HStack(spacing: Space.m) {
                if let error = model.debriefErrors[id] {
                    ErrorState(title: error, compact: true)
                }
                Spacer(minLength: Space.s)
                if busy { ProgressView().controlSize(.small) }
                debriefButton(busy: busy)
            }
            if let debrief = model.latestDebrief(applicationID) {
                DebriefResultView(debrief: debrief, copied: copied) {
                    let text = InterviewPrepModel.clipboardText(debrief.thankYou)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    store.toasts.show("Copied the thank-you draft", symbol: "checkmark", style: .success)
                }
            }
        }
    }

    @ViewBuilder
    private func debriefButton(busy: Bool) -> some View {
        let empty = InterviewPrepModel.notesIssue(model.notes[applicationID ?? -1] ?? "") == .empty
        let button = Button(busy ? "Writing debrief…" : "Write debrief") {
            Task { await model.debrief(applicationID: applicationID) }
        }
        .disabled(busy || empty || applicationID == nil || !store.isConnected)
        .help("One Claude request. Your notes count as your own facts for the draft.")
        if isPrimary {
            button.buttonStyle(.primaryPill)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

private struct DebriefResultView: View {
    var debrief: InterviewDebrief
    var copied: Bool
    var copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Debrief · \(debrief.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            AdaptiveColumns(minColumnWidth: 200, maxColumns: 3) {
                list("Went well", debrief.wentWell, symbol: "checkmark.circle", tone: Palette.applied)
                list("Gaps", debrief.gaps, symbol: "exclamationmark.circle", tone: Palette.needsYou)
                list("Follow-ups", debrief.followUps, symbol: "arrow.turn.down.right", tone: Palette.accent)
            }
            thankYou
        }
    }

    private func list(_ title: String, _ items: [String], symbol: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).eyebrowStyle()
            if items.isEmpty {
                Text("Nothing noted.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Image(systemName: symbol).imageScale(.small).foregroundStyle(tone)
                    Text(item).font(Typography.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var thankYou: some View {
        let draft = debrief.thankYou
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Thank-you draft").eyebrowStyle()
                Spacer()
                Button(copied ? "Copied" : "Copy") { copy() }.buttonStyle(.secondaryLink)
            }
            if !draft.grounded {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label("Don't send this as written. Some lines aren't backed by your notes or profile:", systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.callout.weight(.medium))
                        .foregroundStyle(Palette.needsYou)
                    ForEach(Array(draft.unsupportedClaims.enumerated()), id: \.offset) { _, claim in
                        Text("· \(claim)").font(Typography.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Edit those parts (including any [placeholders]) after you copy it.")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                .padding(Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.needsYou.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                if !draft.subject.isEmpty {
                    Text(draft.subject).font(Typography.bodyEmph).textSelection(.enabled)
                }
                Text(draft.body).font(Typography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .well()
            Text("Never sent. AutoApply doesn't email interviewers; copy it into your own email if you want to use it.")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
        }
    }
}
