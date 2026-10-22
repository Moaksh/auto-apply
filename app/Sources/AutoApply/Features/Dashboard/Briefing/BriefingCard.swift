// BriefingCard.swift — "Today's ten minutes" (docs/DESIGN_AWARD_VISION.md §3.3, owner decision 2):
// the Dashboard's briefing, right under the living hero. What is waiting for you, one row per kind
// with a rough time estimate, the total, and Start: the Dashboard's one primary action while
// there is work (Run lives in the toolbar). Start begins the guided session (Features/Session).
// With nothing waiting it reads "You're done for today." Flat content on a Surface; no glass,
// no continuous motion.
import SwiftUI

struct BriefingCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        let session = SessionModel.shared(for: store)
        let summary = BriefingSummary(items: SessionSources.live(store: store).items)
        Group {
            if session.isActive {
                inProgress(session)
            } else if summary.isDone {
                done
            } else {
                waiting(summary, session: session)
            }
        }
        .padding(Space.cardPadding + Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: summary)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: session.phase)
        .task(id: store.jobs.awaitingReview.map(\.id)) {
            // Flagged answers make a review take longer: load them so the estimate is honest.
            ReviewModel.shared(for: store).syncSubscriptions()
        }
        .task(id: stageApplicationIDs) {
            // A stored prep pack means that interview is already prepared for (no model call).
            let prep = InterviewPrepModel.shared(for: store)
            for id in stageApplicationIDs { await prep.load(applicationID: id) }
        }
    }

    private var stageApplicationIDs: [Int] {
        store.jobs.all.filter { [.assessment, .interview].contains($0.status ?? .applied) && $0.state == .submitted }
            .compactMap(\.applicationID)
    }

    // MARK: States

    private func waiting(_ summary: BriefingSummary, session: SessionModel) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Today's ten minutes").eyebrowStyle().accessibilityAddTraits(.isHeader)
                    Text(summary.headline)
                        .font(Typography.title2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                startButton(summary, session: session)
            }
            VStack(spacing: 0) {
                ForEach(Array(summary.groups.enumerated()), id: \.element.id) { offset, group in
                    if offset > 0 { Divider().overlay(Palette.hairline) }
                    BriefingRow(group: group)
                }
            }
            Text("Times are rough estimates.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    @ViewBuilder
    private func startButton(_ summary: BriefingSummary, session: SessionModel) -> some View {
        let start = { session.start(SessionSources.live(store: store).items) }
        // Before the very first run the live agent's "Run now" is the one primary.
        if store.heroState == .firstRun {
            Button(summary.startTitle, action: { _ = start() }).buttonStyle(.secondaryLink).font(Typography.bodyEmph)
        } else {
            Button(action: { _ = start() }) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                    Text(summary.startTitle)
                }
            }
            .buttonStyle(.primaryPill)
            .help("Walk through each one in order. \(summary.totalLabel.prefix(1).uppercased() + summary.totalLabel.dropFirst()), estimated.")
            .accessibilityLabel("Start, \(summary.totalLabel), estimated")
        }
    }

    private func inProgress(_ session: SessionModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Today's ten minutes").eyebrowStyle().accessibilityAddTraits(.isHeader)
                Text("In progress · \(session.progressLabel)")
                    .font(Typography.title2)
                Text(session.remainingLabel.prefix(1).uppercased() + session.remainingLabel.dropFirst() + " (an estimate).")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: Space.m)
            Button("Show the current item") { session.showCurrent() }
                .buttonStyle(.secondaryLink)
                .font(Typography.bodyEmph)
        }
    }

    private var done: some View {
        HStack(alignment: .center, spacing: Space.l) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Today's ten minutes").eyebrowStyle().accessibilityAddTraits(.isHeader)
                Text("You're done for today.")
                    .font(Typography.title2)
                Text(doneLine)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var doneLine: String {
        let base = "Nothing is waiting for you. The agent keeps going and asks when it needs you."
        guard !store.isPaused, let next = DashboardFormat.nextRunLabel(nextRun: store.nextRunAt, now: Date()) else { return base }
        return "\(base) \(next)."
    }
}

/// One kind of work: symbol, "2 questions to answer", "about 1 min".
private struct BriefingRow: View {
    var group: BriefingSummary.Group

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: group.kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(group.kind <= .question ? Palette.needsYou : Palette.textSecondary)
                .frame(width: 20)
            Text(group.label)
                .font(Typography.body)
                .lineLimit(1)
            Spacer(minLength: Space.m)
            Text(group.estimate)
                .font(Typography.callout)
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.label), \(group.estimate), estimated")
    }
}
