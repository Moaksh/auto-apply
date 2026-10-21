// MatchBreakdown.swift — match score + factor bars (animate from 0 on first open with
// `.gentle`, 40 ms stagger) + the agent's 1–2 sentence rationale (§5.4).
import SwiftUI

struct FactorBar: View {
    var name: String
    var value: Int
    var animateFromZero: Bool
    var delay: Double

    @Environment(\.motionReduced) private var reduced
    @State private var shown = false

    var body: some View {
        HStack(spacing: Space.s) {
            Text(name).font(Typography.callout).frame(width: 76, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.sunken)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(shown || !animateFromZero ? value : 0) / 100)
                }
            }
            .frame(height: 6)
            Text("\(value)").font(Typography.metricSmall).frame(width: 30, alignment: .trailing)
        }
        .onAppear {
            guard animateFromZero, !shown else { return }
            if reduced { shown = true } else { withAnimation(Motion.gentle.delay(delay)) { shown = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(value) out of 100")
    }

    private var color: Color {
        value >= 85 ? Palette.applied : (value >= 65 ? Palette.accent : Palette.needsYou)
    }
}

struct MatchBreakdown: View {
    var job: JobItem
    var threshold: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("Match").eyebrowStyle()
                if let score = job.score {
                    MetricText(score, size: .regular, color: score >= threshold ? Palette.textPrimary : Palette.needsYou)
                }
                Spacer()
            }
            let factors = JobDetailRules.orderedFactors(job.scoreFactors)
            if factors.isEmpty {
                Text(job.score == nil ? "Not scored yet." : "No factor breakdown recorded.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(Array(factors.enumerated()), id: \.element.name) { i, f in
                        FactorBar(name: f.name, value: f.value, animateFromZero: true, delay: Double(i) * 0.04)
                    }
                }
                .padding(Space.m)
                .surface(cornerRadius: Radius.inner)
            }
            if let summary = job.scoreSummary, !summary.isEmpty {
                Text("Why: \(summary)").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
