// MatchBreakdown.swift — match score + factor bars (animate from 0 on first open with
// `.gentle`, 40 ms stagger) + the agent's 1–2 sentence rationale (§5.4), and for newer scores the
// requirements table: met / partly / missing with the quote from your own profile, dealbreakers
// with the job's own words.
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
            // Older scores have no requirement evidence: nothing is shown for them.
            if let requirements = job.scoreRequirements, !requirements.isEmpty {
                RequirementsTable(requirements: requirements, grounding: job.scoreGrounding)
            }
        }
    }
}

/// The job's key requirements, each with whether your profile shows it (met / partly / missing),
/// the quote from your own profile or resume that backs it, and, for a dealbreaker, the job's
/// own words saying it is mandatory.
struct RequirementsTable: View {
    var requirements: [RequirementEvidence]
    var grounding: ScoreGrounding?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Requirements").eyebrowStyle()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(requirements) { r in
                    if r.index > 0 { Divider() }
                    row(r)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.xs)
            .surface(cornerRadius: Radius.inner)
            if let note = Self.groundingNote(grounding) {
                Text(note).font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ r: RequirementEvidence) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(r.requirement).font(Typography.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.xs)
                if r.dealbreaker { Badge("Must have", symbol: "exclamationmark.octagon", tone: .warning, accessibilityText: "Dealbreaker") }
                Badge(r.status.label, symbol: r.status.symbol, tone: Self.tone(r.status), accessibilityText: "Requirement \(r.status.label.lowercased())")
            }
            if !r.evidence.isEmpty {
                Text("“\(r.evidence)”").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("From your profile: \(r.evidence)")
            } else if r.status != .met {
                Text("Nothing in your profile or resume shows this.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            if r.dealbreaker, let quote = r.jdQuote {
                Text("The job says: “\(quote)”").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
    }

    static func tone(_ status: RequirementEvidence.Status) -> Badge.Tone {
        switch status {
        case .met: .status(.applied)
        case .partial: .accent
        case .missing: .warning
        }
    }

    /// A quiet line when the scorer's guard removed evidence it couldn't find in your own text.
    static func groundingNote(_ g: ScoreGrounding?) -> String? {
        guard let g, g.evidenceDropped > 0 else { return nil }
        return g.evidenceDropped == 1
            ? "One quote couldn't be found in your profile or resume, so it was left out and that requirement marked down."
            : "\(g.evidenceDropped) quotes couldn't be found in your profile or resume, so they were left out and those requirements marked down."
    }
}
