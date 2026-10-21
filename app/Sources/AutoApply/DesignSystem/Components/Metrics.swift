// Metrics.swift — MetricText (rounded, rolling digits), Sparkline, CapBar.
import Charts
import SwiftUI

/// A number that rolls digit by digit when it changes (§2.5). Rounded + monospaced digits.
struct MetricText: View {
    enum Size { case xl, regular, small }

    var value: Double
    var format: Format = .integer
    var size: Size = .regular
    var color: Color = Palette.textPrimary

    enum Format: Equatable {
        case integer
        case percent(decimals: Int)
        case decimal(Int)
        /// "—" placeholder (e.g. response rate with < 10 applications).
        case placeholder
    }

    init(_ value: Int, size: Size = .regular, color: Color = Palette.textPrimary) {
        self.value = Double(value)
        self.size = size
        self.color = color
    }

    init(_ value: Double, format: Format, size: Size = .regular, color: Color = Palette.textPrimary) {
        self.value = value
        self.format = format
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(formatted)
            .font(font)
            .foregroundStyle(color)
            .numericRoll(value)
            .accessibilityLabel(accessibilityText)
    }

    private var font: Font {
        switch size {
        case .xl: Typography.metricXL
        case .regular: Typography.metric
        case .small: Typography.metricSmall
        }
    }

    private var formatted: String {
        switch format {
        case .integer: Int(value.rounded()).formatted(.number)
        case .percent(let d): value.formatted(.percent.precision(.fractionLength(d)))
        case .decimal(let d): value.formatted(.number.precision(.fractionLength(d)))
        case .placeholder: "—"
        }
    }

    private var accessibilityText: String {
        format == .placeholder ? "not available" : formatted
    }
}

/// 7-day style sparkline: accent line + 15% area. Flat dotted line when all zero.
struct Sparkline: View {
    var values: [Int]
    var color: Color = Palette.accent

    var body: some View {
        if values.allSatisfy({ $0 == 0 }) {
            GeometryReader { geo in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height - 1))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1))
                }
                .stroke(Palette.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            .accessibilityLabel("No data yet")
        } else {
            Chart(Array(values.enumerated()), id: \.offset) { item in
                AreaMark(x: .value("Day", item.offset), y: .value("Count", item.element))
                    .foregroundStyle(color.opacity(0.15))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Day", item.offset), y: .value("Count", item.element))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .motion(Motion.gentle, value: values)
            .accessibilityLabel("Trend: \(values.map(String.init).joined(separator: ", "))")
        }
    }
}

/// Thin 4pt capsule progress. Amber at ≥ 80 %, neutral grey at 100 % — never red: reaching a
/// daily limit means the guardrail worked.
struct CapBar: View {
    var title: String
    var used: Int
    var limit: Int

    private var fraction: Double { limit > 0 ? min(1, Double(used) / Double(limit)) : 0 }
    private var fill: Color { fraction >= 1 ? Palette.textTertiary : (fraction >= 0.8 ? Palette.needsYou : Palette.accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("\(used) / \(limit)").font(Typography.metricSmall).numericRoll(Double(used))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.sunken)
                    Capsule().fill(fill).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .motion(Motion.snappy, value: fraction)
            if fraction >= 1 {
                Text("Daily limit reached · continues tomorrow").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(used) of \(limit)\(fraction >= 1 ? ", limit reached" : "")")
    }
}

#Preview("Metrics") {
    VStack(spacing: Space.gutter) {
        MetricText(9, size: .xl)
        Sparkline(values: [2, 3, 5, 3, 6, 7, 9]).frame(height: 28)
        CapBar(title: "Applications", used: 13, limit: 15)
        CapBar(title: "Per company", used: 1, limit: 1)
    }
    .padding()
    .frame(width: 320)
}
