// JobCard.swift — the kanban card (§5.3): 2pt status bar, company monogram, company + title,
// meta row (score pill, ATS badge, age, resume initial) and optional chips ("✋ 2 Qs",
// "Heard back?", "⏱ 7d"). Equatable value props so rows don't re-render needlessly.
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
    var onNudgeAnswer: (BoardStatus) -> Void = { _ in }

    nonisolated static func == (a: JobCard, b: JobCard) -> Bool {
        a.job == b.job && a.threshold == b.threshold && a.questionCount == b.questionCount && a.nudge == b.nudge
            && a.resumeLabel == b.resumeLabel && a.isSelected == b.isSelected && a.isDragging == b.isDragging
            && BoardRules.ageText(since: BoardRules.ageReference(a.job), now: a.now) == BoardRules.ageText(since: BoardRules.ageReference(b.job), now: b.now)
    }

    var body: some View {
        let kind = StatusKind(job: job)
        HStack(spacing: 0) {
            StatusBar(kind: kind).padding(.vertical, Space.s)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    CompanyMonogram(name: job.company)
                    Text(job.company).font(Typography.bodyEmph).lineLimit(1)
                    Spacer(minLength: 0)
                    if job.status == .offer {
                        Image(systemName: "star.fill").foregroundStyle(Palette.offer).imageScale(.small)
                    }
                }
                Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                HStack(spacing: Space.xs) {
                    if let score = job.score { ScorePill(score: score, threshold: threshold) }
                    Text(job.ats.shortLabel).font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 4).background(Palette.sunken, in: RoundedRectangle(cornerRadius: 3))
                        .help(job.ats.label)
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
                    Text(BoardRules.skipTag(job.skipReason ?? job.stateReason, score: job.score, threshold: threshold))
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.sunken, in: Capsule())
                        .lineLimit(1)
                        .help("Why AutoApply skipped this job")
                }
                chips
            }
            .padding(.horizontal, Space.s + 2)
            .padding(.vertical, Space.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: Radius.inner, raised: isSelected)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous)
                    .stroke(Palette.accent, lineWidth: 2)
                    .padding(-2)
            }
        }
        .opacity(isDragging ? 0.4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var chips: some View {
        let stalled = job.state == .queued || job.state == .failed || job.state == .unknownVerify
        if questionCount > 0 || nudge != nil || job.state == .failed || job.state == .unknownVerify || job.state == .awaitingReview || (stalled && ageDays >= 7) {
            HStack(spacing: Space.xs) {
                if questionCount > 0 {
                    chip("✋ \(questionCount) Q\(questionCount == 1 ? "" : "s")", tint: Palette.needsYou)
                }
                if job.state == .awaitingReview { chip("Awaiting review", tint: Palette.accent) }
                if job.state == .failed { chip("Failed", tint: Palette.error) }
                if job.state == .unknownVerify { chip("Verify submission", tint: Palette.error) }
                if case .heardBack? = nudge {
                    Menu {
                        Button("Interview") { onNudgeAnswer(.interview) }
                        Button("Assessment") { onNudgeAnswer(.assessment) }
                        Button("Rejected") { onNudgeAnswer(.rejected) }
                        Divider()
                        Button("Not yet") {}
                    } label: {
                        Text("Heard back?").font(Typography.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.accent.opacity(0.12), in: Capsule())
                }
                if stalled && ageDays >= 7 { chip("⏱ \(ageDays)d", tint: Palette.textTertiary) }
            }
        }
    }

    private var ageDays: Int { Int(now.timeIntervalSince(BoardRules.ageReference(job)) / 86_400) }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).font(Typography.callout)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var accessibilityText: String {
        var parts = [job.company, job.title, StatusKind(job: job).label]
        if let score = job.score { parts.append("match \(score)") }
        if job.state == .skipped { parts.append("skipped: " + BoardRules.skipTag(job.skipReason ?? job.stateReason, score: job.score, threshold: threshold)) }
        parts.append(job.ats.label)
        if questionCount > 0 { parts.append("\(questionCount) open questions") }
        if case .heardBack(let days)? = nudge { parts.append("applied \(days) days ago, heard back?") }
        return parts.joined(separator: ", ")
    }
}
