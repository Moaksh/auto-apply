// SourcesChart.swift — W11: jobs discovered per source as a single 100% stacked bar with
// direct labels underneath (no legend-only encoding) and the LinkedIn Easy Apply (manual)
// segment hatched; apply rate per source in the label.
import Charts
import SwiftUI

struct SourcesChart: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let stats = store.stats
        let segments = ChartMath.sourceSegments(stats.sources, easyApply: stats.easyApplyCount)
        let applied = Dictionary(stats.sources.map { ($0.source.rawValue, $0.applied) }, uniquingKeysWith: { a, _ in a })
        let base = WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable)
        let state: SurfaceState = base != .content ? base
            : (segments.isEmpty ? .empty(symbol: "globe", message: "Sources appear after the first discovery run") : .content)

        Surface("Sources", state: state, onRetry: { store.recomputeStats() }) {
            VStack(alignment: .leading, spacing: Space.m) {
                Chart(segments) { segment in
                    BarMark(x: .value("Share", segment.share), y: .value("All", "Sources"), stacking: .normalized)
                        .foregroundStyle(segment.isManual ? Palette.categorical[segment.paletteIndex].opacity(0.35) : Palette.categorical[segment.paletteIndex])
                        .accessibilityLabel(segment.label)
                        .accessibilityValue("\(segment.count) jobs, \(ChartMath.percent(segment.share))")
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 16)
                .clipShape(Capsule())
                .overlay(alignment: .trailing) {
                    // Hatch the manual segment (it's always last).
                    if let manual = segments.last, manual.isManual {
                        GeometryReader { geo in
                            HatchedBar(color: Palette.categorical[manual.paletteIndex])
                                .frame(width: geo.size.width * manual.share)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .clipShape(Capsule())
                        .allowsHitTesting(false)
                    }
                }

                FlowLabels(segments: segments, applied: applied)
            }
            .motion(Motion.gentle, value: segments)
        }
    }
}

/// Direct labels under the bar: swatch + "Greenhouse 46 · 31 applied".
private struct FlowLabels: View {
    var segments: [ChartMath.SourceSegment]
    var applied: [String: Int]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.s, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.xs) {
            ForEach(segments) { s in
                HStack(spacing: Space.xs) {
                    Group {
                        if s.isManual {
                            HatchedBar(color: Palette.categorical[s.paletteIndex])
                        } else {
                            Palette.categorical[s.paletteIndex]
                        }
                    }
                    .frame(width: 8, height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    Text(s.label).font(Typography.callout).lineLimit(1)
                    Text("\(s.count)").font(Typography.metricSmall)
                    if let a = applied[s.id], a > 0, !s.isManual {
                        Text("· \(a) applied").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
