// JobCard.swift — the pipeline card: 2pt status bar, company monogram, company + title, meta
// row (score, application site by full name, age, resume initial) and optional badges ("2
// questions", "Heard back?", "7 days"). Equatable value props so rows don't re-render needlessly.
import SwiftUI

struct JobCard: View, Equatable {
    var job: JobItem
    var threshold: Int
    var questionCount: Int
    var nudge: BoardRules.Nudge?
    var resumeLabel: String?
    var isSelected: Bool
    var isDragging: Bool
    var now: Date
    /// Cold outreach on this application (the envelope badge).
    var outreach: JobOutreachMark? = nil
    /// An employer reply's suggested board move, waiting for Accept / Keep as is.
    var replySuggestion: BoardStatus? = nil
    var onNudgeAnswer: (BoardStatus) -> Void = { _ in }

    nonisolated static func == (a: JobCard, b: JobCard) -> Bool {
        a.job == b.job && a.threshold == b.threshold && a.questionCount == b.questionCount && a.nudge == b.nudge
            && a.resumeLabel == b.resumeLabel && a.isSelected == b.isSelected && a.isDragging == b.isDragging
            && a.outreach == b.outreach && a.replySuggestion == b.replySuggestion
            && BoardRules.ageText(since: BoardRules.ageReference(a.job), now: a.now) == BoardRules.ageText(since: BoardRules.ageReference(b.job), now: b.now)
    }

    var body: some View {
        let kind = StatusKind(job: job)
        HStack(spacing: 0) {
            // A kind no: a closed card wears the neutral grey, never a red bar.
            StatusBar(kind: kind == .rejected ? .ghosted : kind).padding(.vertical, Space.s)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    CompanyMonogram(name: job.company)
                        // Where Job detail's monogram flies from (JobFlight).
                        .background(CascadeAnchor(key: JobFlight.sourceKey(job.id)))
                    Text(job.company).font(Typography.bodyEmph).lineLimit(1)
                    Spacer(minLength: 0)
                    if job.status == .offer {
                        Image(systemName: "star.fill").foregroundStyle(Palette.offer).imageScale(.small)
                    }
                }
                Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                HStack(spacing: Space.xs) {
                    if let score = job.score { Badge(score: score, threshold: threshold) }
                    Text(job.ats.label).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        .help("Application site: \(job.ats.label)")
                    Text(BoardRules.ageText(since: BoardRules.ageReference(job), now: now))
                        .font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                    Spacer(minLength: 0)
                    if let resumeLabel, let initial = resumeLabel.first {
                        Text(String(initial)).font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                            .frame(width: 14, height: 14).background(Palette.sunken, in: Circle())
                            .help("Resume: \(resumeLabel)")
                    }
                }
                if job.state == .skipped {
                    Badge(BoardRules.skipTag(job.skipReason ?? job.stateReason, score: job.score, threshold: threshold))
                        .help("Why AutoApply skipped this job")
                }
                chips
            }
            .padding(.horizontal, Space.s + 2)
            .padding(.vertical, Space.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: Radius.inner)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous)
                    .stroke(Palette.accent, lineWidth: 2)
                    .padding(-2)
            }
        }
        .opacity(isDragging ? 0.4 : 1)
        .motion(Motion.snappy, value: isDragging)
        .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var chips: some View {
        let stalled = job.state == .queued || job.state == .failed || job.state == .unknownVerify
        if questionCount > 0 || nudge != nil || job.state == .failed || job.state == .unknownVerify || job.state == .awaitingReview || (stalled && ageDays >= 7)
            || outreach != nil || replySuggestion != nil {
            HStack(spacing: Space.xs) {
                if questionCount > 0 {
                    Badge(C3Format.plural(questionCount, "question"), symbol: StatusKind.needsYou.symbol, tone: .warning)
                }
                if job.state == .awaitingReview { Badge("Waiting for review", symbol: "checkmark.rectangle.stack", tone: .accent) }
                if job.state == .failed { Badge("Failed", symbol: StatusKind.error.symbol, tone: .error) }
                if job.state == .unknownVerify { Badge("Check if applied", symbol: StatusKind.error.symbol, tone: .error) }
                if case .heardBack? = nudge {
                    Menu {
                        Button("Interview") { onNudgeAnswer(.interview) }
                        Button("Assessment") { onNudgeAnswer(.assessment) }
                        Button("They went another way") { onNudgeAnswer(.rejected) }
                    } label: {
                        Text("Heard back?").font(Typography.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                    .background(Palette.sunken, in: Capsule())
                }
                if stalled && ageDays >= 7 { Badge("\(ageDays) days", symbol: "clock") }
                if let replySuggestion {
                    Badge("Reply: \(replySuggestion.label)?", symbol: "envelope.badge", tone: .warning)
                        .help("An email about this application suggests moving it to \(replySuggestion.label). Accept it in Needs You or the job's details.")
                }
                if let outreach {
                    Badge(outreach.text, symbol: outreach.symbol, tone: { if case .replied = outreach { return .status(.interview) } else { return .neutral } }())
                        .help("Cold email for this application")
                }
            }
        }
    }

    private var ageDays: Int { Int(now.timeIntervalSince(BoardRules.ageReference(job)) / 86_400) }

    private var accessibilityText: String {
        var parts = [job.company, job.title, StatusKind(job: job) == .rejected ? "closed, they went another way" : StatusKind(job: job).label]
        if let score = job.score { parts.append("match \(score)") }
        if job.state == .skipped { parts.append("skipped: " + BoardRules.skipTag(job.skipReason ?? job.stateReason, score: job.score, threshold: threshold)) }
        parts.append(job.ats.label)
        if questionCount > 0 { parts.append("\(questionCount) open questions") }
        if case .heardBack(let days)? = nudge { parts.append("applied \(days) days ago, heard back?") }
        if let outreach { parts.append(outreach.text) }
        if let replySuggestion { parts.append("an employer reply suggests \(replySuggestion.label)") }
        return parts.joined(separator: ", ")
    }
}
