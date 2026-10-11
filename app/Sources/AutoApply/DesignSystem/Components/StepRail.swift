// StepRail.swift — onboarding step indicator (§5.1): completed steps get a drawn-on check and
// the connector fills with accent; the current dot is filled accent with a soft ring.
// Also CompanyMonogram, the 20pt r5 logo stand-in used in lists and cards.
import SwiftUI

struct StepRail: View {
    struct Step: Identifiable, Hashable {
        var id: Int
        var title: String
        var isOptional = false
    }

    var steps: [Step]
    /// Index into `steps` of the current step.
    var current: Int
    var onSelect: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .center, spacing: Space.m) {
                    StepDot(state: index < current ? .done : (index == current ? .current : .upcoming))
                    Text(step.title)
                        .font(index == current ? Typography.bodyEmph : Typography.body)
                        .foregroundStyle(index <= current ? Palette.textPrimary : Palette.textSecondary)
                    if step.isOptional {
                        Text("opt.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .onTapGesture { if index < current { onSelect?(index) } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == current ? .isSelected : [])
                .accessibilityValue(index < current ? "completed" : (index == current ? "current" : "upcoming"))

                if index < steps.count - 1 {
                    ZStack(alignment: .top) {
                        Rectangle().fill(Palette.hairline)
                        Rectangle().fill(Palette.accent).frame(height: index < current ? 18 : 0)
                    }
                    .frame(width: 1.5, height: 18)
                    .padding(.leading, 7.25)
                    .motion(Motion.flow, value: current)
                }
            }
        }
    }
}

private struct StepDot: View {
    enum State { case done, current, upcoming }
    var state: State

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Palette.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.symbolEffect(.drawOn))
            case .current:
                Circle().fill(Palette.accent.opacity(0.18)).frame(width: 16, height: 16)
                Circle().fill(Palette.accent).frame(width: 9, height: 9)
            case .upcoming:
                Circle().stroke(Palette.strokeStrong, lineWidth: 1.5).frame(width: 9, height: 9)
            }
        }
        .frame(width: 16, height: 16)
        .motion(Motion.settle, value: state == .done)
    }
}

/// Company "logo": a monogram tile (favicon fetching is a network call we avoid).
struct CompanyMonogram: View {
    var name: String
    var size: CGFloat = 20

    var body: some View {
        let letter = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        Text(letter)
            .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(for: name), in: RoundedRectangle(cornerRadius: Radius.logo * size / 20, style: .continuous))
            .accessibilityHidden(true)
    }

    /// Stable categorical color per company name.
    static func color(for name: String) -> Color {
        var hash: UInt64 = 1469598103934665603
        for b in name.lowercased().utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return Palette.categorical[Int(hash % UInt64(Palette.categorical.count))]
    }
}

#Preview("Step rail") {
    HStack(spacing: Space.xxl) {
        StepRail(steps: [
            .init(id: 1, title: "System check"), .init(id: 2, title: "Resumes"), .init(id: 3, title: "Preferences"),
            .init(id: 4, title: "Never-guess facts"), .init(id: 5, title: "Story bank", isOptional: true),
            .init(id: 6, title: "Sources"), .init(id: 7, title: "Mode"),
        ], current: 2)
        VStack { CompanyMonogram(name: "Stripe"); CompanyMonogram(name: "Ramp", size: 32) }
    }
    .padding()
}
