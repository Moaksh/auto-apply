// StatusViews.swift — StatusDot, StatusChip, StatusBar, ScorePill, ProvenanceTag,
// ConfidenceDot, LockedField. Status color appears only as a dot, symbol tint or 2pt bar.
import SwiftUI

/// 8pt status dot.
struct StatusDot: View {
    var kind: StatusKind
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(kind.color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Symbol + label capsule. `.small` hides the label but keeps the symbol (differentiate
/// without color).
struct StatusChip: View {
    enum Size { case small, regular }

    var kind: StatusKind
    var size: Size = .regular
    var label: String?

    init(_ kind: StatusKind, size: Size = .regular, label: String? = nil) {
        self.kind = kind
        self.size = size
        self.label = label
    }

    init(job: JobItem, size: Size = .regular) {
        self.init(StatusKind(job: job), size: size, label: job.state == .submitted ? nil : job.state.label)
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: kind.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(kind.color, Palette.textSecondary)
                .imageScale(.small)
            if size == .regular {
                Text(label ?? kind.label).font(Typography.callout).foregroundStyle(Palette.textPrimary)
            }
        }
        .padding(.horizontal, size == .regular ? Space.s : Space.xs)
        .padding(.vertical, Space.xxs)
        .background(Palette.sunken, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? kind.label)
    }
}

/// The 2pt leading status bar on cards.
struct StatusBar: View {
    var kind: StatusKind

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(kind.color)
            .frame(width: 2)
            .accessibilityHidden(true)
    }
}

/// 0–100 match score, tinted by distance to the threshold.
struct ScorePill: View {
    var score: Int
    var threshold: Int = 70

    private var tint: Color {
        if score >= threshold + 10 { return Palette.applied }
        if score >= threshold { return Palette.accent }
        if score >= threshold - 10 { return Palette.needsYou }
        return Palette.textTertiary
    }

    var body: some View {
        Text("\(score)")
            .font(Typography.metricSmall)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("Match score \(score)\(score < threshold ? ", below threshold \(threshold)" : "")")
    }
}

/// profile / CV / memory / story / generated / you.
struct ProvenanceTag: View {
    var origin: AnswerOrigin
    var reference: String?

    var body: some View {
        HStack(spacing: 3) {
            if origin == .neverGuess { Image(systemName: "lock.fill").imageScale(.small) }
            Text(reference.map { "\(origin.label) \($0)" } ?? origin.label)
        }
        .font(Typography.monoSmall)
        .foregroundStyle(origin == .user ? Palette.accent : Palette.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Palette.sunken, in: Capsule())
        .accessibilityLabel("Source: \(origin.label)")
    }
}

/// green high · amber medium · grey low/n.a.
struct ConfidenceDot: View {
    var level: ApplicationAnswerItem.ConfidenceLevel

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch level {
        case .high: Palette.applied
        case .medium: Palette.needsYou
        case .low: Palette.error
        case .notApplicable: Palette.textTertiary
        }
    }

    private var label: String {
        switch level {
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .low: "Low confidence"
        case .notApplicable: "Confidence not applicable"
        }
    }
}

/// Never-guess field styling: lock glyph + sunken well, everywhere ("locked = only I set this").
struct LockedField<Content: View>: View {
    var title: String
    var isEmpty: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Palette.textSecondary)
                .imageScale(.small)
            Text(title)
                .font(Typography.body)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xxs) {
                content()
                if isEmpty {
                    Text("Always ask me").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .sunkenWell()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), locked, set only by you")
    }
}

#Preview("Status") {
    VStack(alignment: .leading, spacing: Space.s) {
        HStack { ForEach(StatusKind.allCases, id: \.self) { StatusChip($0, size: .small) } }
        HStack { StatusChip(.needsYou); StatusChip(.applied); ScorePill(score: 91); ScorePill(score: 64) }
        HStack { ProvenanceTag(origin: .cv); ProvenanceTag(origin: .neverGuess); ProvenanceTag(origin: .user) }
        LockedField(title: "Notice period") { Text("60 days") }
        LockedField(title: "Start date", isEmpty: true) { EmptyView() }
    }
    .padding()
}
