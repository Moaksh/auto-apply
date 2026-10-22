// ReviewTicket.swift — Review's ticket (Settings ▸ General ▸ Approve style ▸ Ticket, the
// default): the job you're deciding on, printed as a ticket. The body carries the company, the
// role and its printed facts (MATCH, POSTED, SITE, ENCLOSED); the stub on the trailing side, past
// a dashed perforation, is the screen's one primary action. Tearing the stub is consent: drag it
// past the commit point (`Motion.Budget.tearCommit`), click it, or press ⌘↵ / A. A tear is
// exactly Approve (`ReviewModel.tear` → `SendHoldModel`'s ≈5 s hold with Undo / ⌘Z): nothing
// is sent sooner than before. The torn stub rests off to the side with the countdown and Undo,
// an "APPROVED" stamp lands on the body, and the next ticket takes focus within 0.3 s.
//
// A ticket held for your answer (answers that need a look, or not loaded yet) refuses to tear:
// the stub reads "ANSWER TO RELEASE", gives a little and springs back, the ticket shakes and the
// next flagged answer is spotlit. A soft coral glow sits under it (Reduce Transparency: a coral
// rim instead). The ticket is content, so it's the flat surface, never glass.
import SwiftUI

/// How Review asks for consent. A local app preference (never sent to the agent).
enum ApproveStyle: String, CaseIterable, Identifiable, Sendable {
    /// Tear the stub off the ticket.
    case ticket
    /// The Approve & send button (Review as it was).
    case classic

    static let storageKey = "review.approveStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ticket: "Ticket"
        case .classic: "Classic"
        }
    }
}

extension EnvironmentValues {
    /// Pins the approve style (tests, previews); nil reads the app preference.
    @Entry var approveStyleOverride: ApproveStyle? = nil
    /// Counts what Review drew (tests only; nil in the app).
    @Entry var reviewRenderProbe: ReviewRenderProbe? = nil
}

/// What Review drew while rendering (tests only), so a test can tell the ticket from the classic UI.
@MainActor
final class ReviewRenderProbe {
    private(set) var tickets = 0
    private(set) var classicActions = 0
    func ticket() { tickets += 1 }
    func classic() { classicActions += 1 }
}

// MARK: - Facts

/// The ticket's printed facts, from real fields only; anything missing is left off.
enum TicketFacts {
    typealias Field = (label: String, value: String, tint: Color?)

    /// MATCH, POSTED, SITE, ENCLOSED (the last once the answers have loaded).
    static func fields(job: JobItem, answers: [ApplicationAnswerItem], answersLoaded: Bool, threshold: Int) -> [Field] {
        var out: [Field] = []
        if let score = job.score { out.append(("Match", "\(score)", scoreTint(score, threshold: threshold))) }
        if let posted = job.postedAt { out.append(("Posted", posted.formatted(.dateTime.month(.abbreviated).day()), nil)) }
        if let site = site(job) { out.append(("Site", site, nil)) }
        if answersLoaded, let enclosed = enclosed(job: job, answers: answers) { out.append(("Enclosed", enclosed, nil)) }
        return out
    }

    /// The compact pair for a Review row: MATCH and SITE.
    static func rowFields(job: JobItem, threshold: Int) -> [Field] {
        var out: [Field] = []
        if let score = job.score { out.append(("Match", "\(score)", scoreTint(score, threshold: threshold))) }
        if let site = site(job) { out.append(("Site", site, nil)) }
        return out
    }

    /// The application site, short ("Greenhouse", "LinkedIn"); nil for an unknown one.
    static func site(_ job: JobItem) -> String? {
        switch job.ats {
        case .other: nil
        case .linkedinEasyApply: "LinkedIn"
        default: job.ats.label
        }
    }

    /// "Letter + 9 answers", "9 answers", "Letter"; nil when nothing is enclosed.
    static func enclosed(job: JobItem, answers: [ApplicationAnswerItem]) -> String? {
        let letter = job.coverLetterPath != nil
            || answers.contains { $0.fieldType == .file && $0.question.localizedCaseInsensitiveContains("cover letter") }
        let count = answers.filter { $0.fieldType != .file }.count
        let written = count == 1 ? "1 answer" : "\(count) answers"
        switch (letter, count > 0) {
        case (true, true): return "Letter + \(written)"
        case (true, false): return "Letter"
        case (false, true): return written
        case (false, false): return nil
        }
    }

    /// The same tones as the score badge: well over the bar green, over it accent, just under coral.
    static func scoreTint(_ score: Int, threshold: Int) -> Color? {
        if score >= threshold + 10 { return Palette.applied }
        if score >= threshold { return Palette.accent }
        if score >= threshold - 10 { return Palette.needsYou }
        return nil
    }
}

// MARK: - Ticket

struct ReviewTicket: View {
    var model: ReviewModel
    var job: JobItem
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.undoManager) private var undoManager
    @Environment(\.prominenceAudit) private var audit
    @Environment(\.reviewRenderProbe) private var probe
    @State private var token = UUID()
    /// The stub's live drag toward the trailing edge (pt, after resistance).
    @State private var drag: CGFloat = 0
    /// Past the commit point during a drag (the alignment haptic fires as it turns true).
    @State private var pastCommit = false
    /// Re-attaching after an Undo: the stub starts torn and springs home.
    @State private var reattaching = false

    static let stubWidth: CGFloat = 168

    var body: some View {
        let hold = model.sendHold.entry(for: job.id)
        let torn = hold != nil
        let heldForAnswer = !torn && model.needsLook(job)
        // The stub is the screen's one primary while nothing else asks (no ticks, no bar question).
        let isPrimary = !torn && !heldForAnswer && model.selection.isEmpty && model.barMode == .actions
        let _ = isPrimary ? audit?.record(token) : nil
        let _ = probe?.ticket()
        let rim: Color? = heldForAnswer && reduceTransparency ? Palette.coral : nil
        HStack(spacing: 0) {
            ticketBody(torn: torn, rim: rim)
            stub(hold: hold, heldForAnswer: heldForAnswer, isPrimary: isPrimary, rim: rim)
                .offset(x: stubOffset(torn: torn))
                .rotationEffect(.degrees(torn && !reduced ? 2 : 0), anchor: .bottomLeading)
                .animation(Motion.resolve(torn ? Motion.tear : Motion.tug, reduceMotion: reduced), value: torn)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .bottom) {
            if heldForAnswer && !reduceTransparency { HeldGlow() }
        }
        // Room for the torn stub to rest off to the side.
        .padding(.trailing, Motion.Budget.tornOffset)
        .ticketDip(torn)
        .errorShake(trigger: model.tearRefusals)
        .sensoryFeedback(.alignment, trigger: pastCommit) { _, now in now && Haptics.isEnabled }
        .sensoryFeedback(.levelChange, trigger: torn) { _, now in now && Haptics.isEnabled }
        .onChange(of: torn) { _, now in if !now { _ = model.takeReattach(job.id) } }
        .onAppear {
            guard model.takeReattach(job.id), !torn else { return }
            reattaching = true
            Task { @MainActor in withMotion(Motion.tug, reduceMotion: reduced) { reattaching = false } }
        }
    }

    private func stubOffset(torn: Bool) -> CGFloat {
        (torn || reattaching) && !reduced ? Motion.Budget.tornOffset + drag : drag
    }

    // MARK: Body

    private func ticketBody(torn: Bool, rim: Color?) -> some View {
        let facts = TicketFacts.fields(job: job, answers: model.answers(for: job), answersLoaded: model.answersLoaded(job),
                                       threshold: store.preferences.matchThreshold)
        return VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.company).font(Typography.title2).lineLimit(1)
                Text(job.title).font(Typography.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            if !facts.isEmpty {
                // Narrow panes print fewer facts rather than squeezing them.
                ViewThatFits(in: .horizontal) {
                    TicketFieldRow(fields: facts)
                    TicketFieldRow(fields: Array(facts.prefix(3)))
                    TicketFieldRow(fields: Array(facts.prefix(2)))
                }
            }
        }
        .padding(Space.cardPadding)
        .padding(.trailing, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { TicketPaper(side: .body, rim: rim) }
        .overlay(alignment: .trailing) {
            TicketPerforation()
                .stroke(Palette.strokeStrong, style: TicketPart.perforationStyle)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .trailing) {
            TicketStamp(text: "Approved")
                .padding(.trailing, Space.xl)
                .stampLanding(torn)
                .opacity(torn ? 1 : 0)
                .animation(torn ? nil : Motion.resolve(Motion.fade, reduceMotion: reduced), value: torn)
                .accessibilityHidden(!torn)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Stub

    @ViewBuilder
    private func stub(hold: SendHoldModel.Entry?, heldForAnswer: Bool, isPrimary: Bool, rim: Color?) -> some View {
        if let hold {
            // Torn: the stub rests off to the side and carries the hold (countdown, Undo).
            SendHoldStubCountdown(entry: hold) { model.undoHold(jobID: job.id) }
                .padding(Space.m)
                .frame(width: Self.stubWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background { TicketPaper(side: .stub) }
                .transition(.opacity)
        } else {
            intactStub(heldForAnswer: heldForAnswer, isPrimary: isPrimary)
                .padding(Space.m)
                .frame(width: Self.stubWidth)
                .frame(maxHeight: .infinity)
                .background {
                    TicketPaper(side: .stub, fill: isPrimary ? Palette.primaryFill : Palette.surface, rim: rim)
                        .opacity(isPrimary && !store.isConnected ? 0.35 : 1)
                }
                .contentShape(TicketPart(side: .stub))
                .gesture(stubGesture(heldForAnswer: heldForAnswer))
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(heldForAnswer ? "Approve \(job.company): some answers need a look first" : "Approve and send \(job.company)")
                .accessibilityHint(heldForAnswer ? "Answer or edit the flagged answers to release it."
                                                 : "Sends after a \(holdSeconds) second hold you can undo.")
                .accessibilityAction { tearByPress() }
                .help(heldForAnswer ? "Answer or edit the flagged answers to release it (A asks to approve anyway)"
                                    : (store.isConnected ? "Tear off, click or press ⌘↵. Sends after a \(holdSeconds) s hold you can undo."
                                                         : "The agent isn't running, so nothing can send."))
        }
    }

    private var holdSeconds: Int { Int(SendHoldTiming.seconds(model.sendHold.window)) }

    @ViewBuilder
    private func intactStub(heldForAnswer: Bool, isPrimary: Bool) -> some View {
        if heldForAnswer {
            let loaded = model.answersLoaded(job)
            let flagged = model.flaggedAnswers(for: job).count
            VStack(spacing: Space.xs) {
                Image(systemName: loaded ? "exclamationmark.triangle.fill" : "hourglass")
                    .foregroundStyle(Palette.coral)
                stubCaption(loaded ? "Answer to release" : "Checking answers", ink: Palette.coral)
                if loaded && flagged > 0 {
                    Text(flagged == 1 ? "1 needs a look" : "\(flagged) need a look")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
        } else {
            let ink = isPrimary ? Palette.onPrimaryFill : Palette.textPrimary
            VStack(spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "paperplane.fill")
                    Text("Approve & send").lineLimit(1)
                }
                .font(Typography.bodyEmph)
                .foregroundStyle(ink)
                stubCaption("Tear · ⌘↵", ink: ink.opacity(0.7))
            }
        }
    }

    private func stubCaption(_ text: String, ink: Color) -> some View {
        Text(text)
            .font(Typography.ticketLabel)
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// Drag toward the trailing edge to tear; a click (no real movement) tears too. A held ticket
    /// gives a little, then springs back.
    private func stubGesture(heldForAnswer: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = max(0, value.translation.width)
                let commit = Motion.Budget.tearCommit
                if heldForAnswer {
                    drag = min(t * 0.3, 18)
                } else {
                    drag = t <= commit ? t : commit + (t - commit) * 0.4
                    pastCommit = t >= commit
                }
            }
            .onEnded { value in
                let moved = abs(value.translation.width) >= 4 || abs(value.translation.height) >= 4
                pastCommit = false
                // Like the classic button: nothing to tear while the agent isn't running.
                guard store.isConnected else {
                    withMotion(Motion.tug, reduceMotion: reduced) { drag = 0 }
                    return
                }
                let outcome = moved
                    ? model.releaseStub(jobID: job.id, translation: value.translation.width, undoManager: undoManager)
                    : model.tear(jobID: job.id, undoManager: undoManager)
                if outcome == .torn {
                    // The hold flips `torn`; the stub's offset animates from here to its resting place with `tear`.
                    drag = 0
                } else {
                    withMotion(Motion.tug, reduceMotion: reduced) { drag = 0 }
                }
            }
    }

    private func tearByPress() {
        guard store.isConnected else { return }
        _ = model.tear(jobID: job.id, undoManager: undoManager)
    }
}

/// "APPROVED", inked on the ticket body. Accent ink: your own consent, going through (coral
/// stays the "needs you" ink, so a held ticket and an approved one never read alike).
private struct TicketStamp: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Typography.ticketValue)
            .textCase(.uppercase)
            .tracking(2.4)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, Space.s + 2)
            .padding(.vertical, Space.xs)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.accent, lineWidth: 1.5)
            }
            .rotationEffect(.degrees(-8))
            .allowsHitTesting(false)
    }
}

/// The held ticket's warm light: a blurred coral ellipse under the ticket's lower edge. Static.
private struct HeldGlow: View {
    var body: some View {
        Ellipse()
            .fill(Palette.coral.opacity(0.32))
            .frame(height: 34)
            .padding(.horizontal, Space.xxl)
            .offset(y: 12)
            .blur(radius: 18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Row facts

/// MATCH and SITE in a Review row (ticket style), in place of the score badge: two compact mono
/// fields stacked to the rows' two text lines, so the row keeps its height.
struct ReviewRowFacts: View {
    var job: JobItem
    var threshold: Int

    var body: some View {
        let fields = TicketFacts.rowFields(job: job, threshold: threshold)
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                TicketField(label: field.label, value: field.value, tint: field.tint, axis: .horizontal)
            }
        }
        .fixedSize()
    }
}
