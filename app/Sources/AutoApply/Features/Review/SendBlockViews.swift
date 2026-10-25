// SendBlockViews.swift — Review's answer to "why won't this send?" (issue #4). A job the agent
// can't send yet shows it on its ticket / detail instead of offering a doomed Approve:
//
// * cooldown: "You applied to Prodigal on Oct 12. I can send this from Nov 11." ·
//   Keep for Nov 11 (the one primary: it stays parked and comes back by itself) · Skip
// * unconfirmed attempt: "I'm not sure your Prodigal application on Oct 12 went through." ·
//   It went through · It didn't go through · Open it (`resolve_unknown` on the other one)
// * in flight: "I'm sending your other Prodigal application now…" · Skip
// * another job at the company waiting too (not a block): a one-line heads-up above Approve.
//
// No new motion: the notice cross-fades in with the detail (`Motion.fade`), Reduce Motion
// keeps it static. Content sits on the flat sunken surface, never glass.
import SwiftUI

struct SendBlockNotice: View {
    var model: ReviewModel
    var job: JobItem
    var block: SendBlock
    /// The screen's one primary (nothing else is asking: no ticks, no bar question).
    var isPrimary: Bool
    /// Off under the ticket, whose footer already has Skip.
    var showsSkip = true
    @Environment(AppStore.self) private var store
    @State private var resolving = false

    var body: some View {
        Group {
            if model.isKept(job.id) {
                keptLine
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label {
                        Text(ReviewSendability.message(block, in: store.jobs.all))
                            .font(Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: ReviewSendability.rowSymbol(block)).foregroundStyle(tint)
                    }
                    actions
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.sunken, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Can't send yet")
    }

    private var tint: Color {
        block.needsResolution ? Palette.needsYou : Palette.textSecondary
    }

    private var keptLine: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(Palette.textSecondary)
            Text("Kept for \(ReviewSendability.day(block.resetsAt)). It comes back here, ready to send, once it can go.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
            Spacer(minLength: Space.s)
            skipButton
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Space.s) {
            switch block.kind {
            case .cooldown:
                let keep = Button("Keep for \(ReviewSendability.day(block.resetsAt))") { model.keep(jobID: job.id) }
                if isPrimary { keep.buttonStyle(.primaryPill) } else { keep.buttonStyle(.bordered) }
                skipButton
            case .unconfirmedAttempt(inFlight: false):
                // A factual question: both answers weigh the same (neither is the default).
                Button("It went through") { resolve(sent: true) }
                    .buttonStyle(.bordered)
                    .disabled(resolving || !store.isConnected)
                Button("It didn't go through") { resolve(sent: false) }
                    .buttonStyle(.bordered)
                    .disabled(resolving || !store.isConnected)
                if let other = block.otherJobID {
                    Button("Open it") { store.router.openJob(id: other) }
                        .buttonStyle(.secondaryLink)
                        .help("See that application, its confirmation screenshot and the posting, then tell me here")
                }
                Spacer(minLength: Space.s)
                skipButton
            case .unconfirmedAttempt(inFlight: true), .sameCompanyInReview:
                skipButton
            }
        }
    }

    @ViewBuilder
    private var skipButton: some View {
        if showsSkip {
            Button("Skip") { model.requestSkip(only: [job.id]) }
                .buttonStyle(.secondaryLink)
        }
    }

    private func resolve(sent: Bool) {
        resolving = true
        Task {
            await model.resolveOther(for: job.id, sent: sent)
            resolving = false
        }
    }
}

/// Above Approve when another job at the same company waits in Review too (not a block).
struct SameCompanyHint: View {
    var block: SendBlock

    var body: some View {
        Label(ReviewSendability.message(block), systemImage: ReviewSendability.rowSymbol(block))
            .font(Typography.callout)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(2)
    }
}

/// A Review row's compact "can't send yet" mark, in place of the score facts.
struct SendBlockRowMark: View {
    var block: SendBlock

    var body: some View {
        Label(ReviewSendability.rowLabel(block), systemImage: ReviewSendability.rowSymbol(block))
            .font(Typography.callout)
            .foregroundStyle(block.needsResolution ? Palette.needsYou : Palette.textSecondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
    }
}
