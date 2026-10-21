// StatusViews.swift — the one Badge (status, score, answer source, site, plain labels), plus
// StatusDot, StatusBar, ConfidenceDot and LockedField. Status colour is never the only signal:
// every status badge carries a symbol and a word.
import SwiftUI

/// A small symbol + label capsule on the sunken stone. One component for every badge.
struct Badge: View {
    enum Tone: Equatable {
        case neutral
        case accent
        case warning
        case error
        case status(StatusKind)

        var color: Color {
            switch self {
            case .neutral: Palette.textSecondary
            case .accent: Palette.accent
            case .warning: Palette.needsYou
            case .error: Palette.error
            case .status(let kind): kind.color
            }
        }
    }

    var text: String?
    var symbol: String?
    var tone: Tone = .neutral
    /// Numbers (scores) use the rounded metric face.
    var numeric = false
    var accessibilityText: String?

    init(_ text: String?, symbol: String? = nil, tone: Tone = .neutral, numeric: Bool = false, accessibilityText: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
        self.numeric = numeric
        self.accessibilityText = accessibilityText
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(tone.color)
            }
            if let text {
                Text(text)
                    .font(numeric ? Typography.metricSmall : Typography.callout)
                    .foregroundStyle(numeric ? tone.color : Palette.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, text == nil ? Space.xs : Space.s)
        .padding(.vertical, Space.xxs)
        .background(Palette.sunken, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? text ?? "")
    }
}

extension Badge {
    /// A status ("Applied", "Needs you"). `compact` keeps only the symbol.
    init(status kind: StatusKind, label: String? = nil, compact: Bool = false) {
        self.init(compact ? nil : (label ?? kind.label), symbol: kind.symbol, tone: .status(kind),
                  accessibilityText: label ?? kind.label)
    }

    /// A job's current status.
    init(job: JobItem, compact: Bool = false) {
        self.init(status: StatusKind(job: job), label: job.state == .submitted ? nil : job.state.label, compact: compact)
    }

    /// 0–100 match score, tinted by distance to the threshold.
    init(score: Int, threshold: Int = 70) {
        let tone: Tone = score >= threshold + 10 ? .status(.applied) : (score >= threshold ? .accent : (score >= threshold - 10 ? .warning : .neutral))
        self.init("\(score)", tone: tone, numeric: true,
                  accessibilityText: "Match score \(score)\(score < threshold ? ", below threshold \(threshold)" : "")")
    }

    /// Where an answer came from (profile / CV / memory / story / drafted / you).
    init(origin: AnswerOrigin, reference: String? = nil) {
        let text = reference.map { "\(origin.label) \($0)" } ?? origin.label
        self.init(text, symbol: origin == .neverGuess ? "lock.fill" : nil, tone: origin == .user ? .accent : .neutral,
                  accessibilityText: "Source: \(origin.label)")
    }

    /// The application site, by its full name.
    init(site: Ats) {
        self.init(site.label, accessibilityText: "Application site: \(site.label)")
    }
}

/// 8pt status dot.
struct StatusDot: View {
    var kind: StatusKind
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(kind.color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The 2pt leading status bar on pipeline cards.
struct StatusBar: View {
    var kind: StatusKind

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(kind.color)
            .frame(width: 2)
            .accessibilityHidden(true)
    }
}

/// green high · amber medium · red low · grey n/a.
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

/// A fact only you set: lock glyph + well. The agent never guesses these.
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
                    Text("Not set: the agent will ask you").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .well()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), a fact only you set")
    }
}

#Preview("Badges") {
    VStack(alignment: .leading, spacing: Space.s) {
        HStack { ForEach(StatusKind.allCases, id: \.self) { Badge(status: $0, compact: true) } }
        HStack { Badge(status: .needsYou); Badge(status: .applied); Badge(score: 91); Badge(score: 64); Badge(site: .greenhouse) }
        HStack { Badge(origin: .cv); Badge(origin: .neverGuess); Badge(origin: .user) }
        LockedField(title: "Notice period") { Text("60 days") }
        LockedField(title: "Start date", isEmpty: true) { EmptyView() }
    }
    .padding()
}
