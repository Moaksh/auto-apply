// VariantChart.swift — W9 response rate by resume variant: horizontal bars (categorical
// palette) with response % labeled and an "n=64" sample caption; n < 10 gets a hatched bar and
// "low sample". The most decision-relevant chart in the app.
import Charts
import SwiftUI

struct VariantChart: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let variants = store.stats.byVariant
        let base = WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable)
        let state: SurfaceState = base != .content ? base
            : (variants.isEmpty ? .empty(symbol: "doc.on.doc", message: "Shows which resume gets responses after your first applications") : .content)

        Surface("By resume", state: state, onRetry: { store.recomputeStats() }) {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Array(variants.enumerated()), id: \.element.id) { index, v in
                    row(v, color: Palette.categorical[index % Palette.categorical.count])
                }
            }
            .motion(Motion.gentle, value: variants)
            .accessibilityChartDescriptor(VariantDescriptor(variants: variants))
        }
    }

    private func row(_ v: VariantStat, color: Color) -> some View {
        HStack(spacing: Space.s) {
            Text(v.label).font(Typography.callout).lineLimit(1).frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.sunken)
                    let width = max(v.responses > 0 ? 3 : 0, geo.size.width * min(1, v.responseRate))
                    if v.isLowSample {
                        HatchedBar(color: color).frame(width: max(width, 6)).clipShape(Capsule())
                    } else {
                        Capsule().fill(color).frame(width: width)
                    }
                }
            }
            .frame(height: 10)
            Text(ChartMath.percent(v.responseRate)).font(Typography.metricSmall).frame(width: 40, alignment: .trailing)
            Text(ChartMath.variantCaption(v)).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                .frame(width: 104, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(v.label) resume")
        .accessibilityValue("\(ChartMath.percent(v.responseRate)) response rate, \(ChartMath.percent(v.interviewRate)) interview rate, \(v.applications) applications\(v.isLowSample ? ", low sample" : "")")
    }
}

/// Diagonal hatching for "low sample" / "manual" segments (pattern differentiation, §7).
struct HatchedBar: View {
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.25)))
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

struct VariantDescriptor: AXChartDescriptorRepresentable {
    var variants: [VariantStat]

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: "Response rate by resume variant", summary: nil,
            xAxis: AXCategoricalDataAxisDescriptor(title: "Resume", categoryOrder: variants.map(\.label)),
            yAxis: AXNumericDataAxisDescriptor(title: "Response rate", range: 0...1, gridlinePositions: []) { ChartMath.percent($0) },
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(name: "Response rate", isContinuous: false,
                                            dataPoints: variants.map { .init(x: $0.label, y: $0.responseRate) })])
    }
}
