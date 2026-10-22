// StepTicker.swift — SF Mono step list (§4.3 W2d): the last 4 completed steps plus the
// current one (with thinking dots), then upcoming step chips that check off as they complete.
// Fixed height, so layout never jumps; new lines insert with `rowInsert`.
import SwiftUI

struct StepTicker: View {
    var steps: [TickerStep]
    var isActive: Bool
    /// Lines shown when idle/discovering (e.g. "LinkedIn · 'backend engineer' · page 3").
    var fallbackLines: [String] = []

    @Environment(\.motionReduced) private var reduced
    static let visibleLines = 5
    static let lineHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Steps").eyebrowStyle()
            VStack(alignment: .leading, spacing: 2) {
                if steps.isEmpty {
                    ForEach(Array(fallbackLines.suffix(Self.visibleLines).enumerated()), id: \.offset) { offset, line in
                        let isLast = offset == min(fallbackLines.count, Self.visibleLines) - 1
                        Text(line).font(Typography.mono)
                            .foregroundStyle(isLast ? Palette.textPrimary : Palette.textSecondary)
                            .lineLimit(1)
                            .contentTransition(.interpolate)
                            .frame(height: Self.lineHeight, alignment: .leading)
                    }
                    if fallbackLines.isEmpty {
                        Text("Waiting for the next step…").font(Typography.mono).foregroundStyle(Palette.textTertiary)
                            .frame(height: Self.lineHeight, alignment: .leading)
                    }
                } else {
                    ForEach(Array(steps.suffix(Self.visibleLines).enumerated()), id: \.element.id) { offset, step in
                        let isCurrent = isActive && step.id == steps.last?.id
                        // New steps tick in from below (the list is bottom-aligned), the old top
                        // line fades out: a smooth odometer of what the agent is doing.
                        line(step, isCurrent: isCurrent)
                            .transition(reduced ? .opacity : .asymmetric(insertion: .push(from: .bottom).combined(with: .opacity),
                                                                         removal: .opacity))
                    }
                }
            }
            .frame(height: CGFloat(Self.visibleLines) * (Self.lineHeight + 2), alignment: .bottomLeading)
            .clipped()
            .motion(Motion.snappy, value: steps.map(\.id))
            .motion(Motion.snappy, value: fallbackLines)
            chips
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func line(_ step: TickerStep, isCurrent: Bool) -> some View {
        HStack(spacing: Space.s) {
            Text(DashboardFormat.tickerTime(step.at)).foregroundStyle(Palette.textTertiary)
            if step.isLowConfidence {
                Text("?").foregroundStyle(Palette.needsYou).fontWeight(.bold)
            } else if isCurrent {
                Text("◌").foregroundStyle(Palette.accent)
            } else {
                Text("✓").foregroundStyle(Palette.applied)
            }
            Text(text(step))
                .foregroundStyle(isCurrent ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .contentTransition(.interpolate)
            if step.isLowConfidence {
                Text("not sure → asking you").foregroundStyle(Palette.needsYou).lineLimit(1)
            }
            if isCurrent { ThinkingDots(isActive: true, color: Palette.accent) }
        }
        .font(Typography.mono)
        .frame(height: Self.lineHeight, alignment: .leading)
    }

    private func text(_ step: TickerStep) -> String {
        if let detail = step.detail, !detail.isEmpty { return "\(step.action.replacingOccurrences(of: "_", with: " ")) \(detail)" }
        return step.action.replacingOccurrences(of: "_", with: " ")
    }

    private var chips: some View {
        let done = TickerChips.completed(steps: steps)
        return HStack(spacing: Space.s) {
            ForEach(TickerChips.upcoming, id: \.self) { chip in
                HStack(spacing: 3) {
                    Image(systemName: done.contains(chip) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done.contains(chip) ? Palette.applied : Palette.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(chip)
                }
                .font(Typography.monoSmall)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .opacity(steps.isEmpty ? 0.5 : 1)
    }

    private var accessibilityText: String {
        guard let last = steps.last else { return "No steps yet" }
        var s = "Current step: \(text(last))"
        if let total = last.total { s += ", step \(last.index + 1) of \(total)" }
        if last.isLowConfidence { s += ", low confidence, asking you" }
        return s
    }
}
