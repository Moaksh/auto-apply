// ApplicationsChart.swift — W7 Applications · 30 days: daily bars (accent 70%) + 7-day moving
// average (accent, 1.5pt, catmull-rom) + dashed daily-cap rule; scrubbing snaps to days with
// an alignment haptic and an annotation ("Tue 7 Oct · 12 applied · 3 skipped").
import Charts
import SwiftUI

struct ApplicationsChart: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @State private var selectedDate: Date?
    @State private var hasAppeared = false

    private struct Point: Identifiable {
        var id: Date { day.day }
        var day: DayCount
        var average: Double
    }

    var body: some View {
        let days = store.stats.daily30
        let averages = ChartMath.movingAverage(days.map(\.applied))
        let points = zip(days, averages).map { Point(day: $0, average: $1) }
        let total = days.reduce(0) { $0 + $1.applied }
        let cap = store.preferences.dailyCap
        let state = chartState(total: total)

        Card("Applications · 30 days", state: state, onRetry: { store.recomputeStats() }) {
            Chart {
                ForEach(points) { p in
                    BarMark(x: .value("Day", p.day.day, unit: .day),
                            y: .value("Applied", hasAppeared || reduced ? p.day.applied : 0))
                        .foregroundStyle(Palette.accentRamp(1))
                        .accessibilityLabel(p.day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .accessibilityValue("\(p.day.applied) applied")
                    LineMark(x: .value("Day", p.day.day, unit: .day), y: .value("7-day average", p.average))
                        .foregroundStyle(Palette.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                        .accessibilityHidden(true)
                }
                RuleMark(y: .value("Daily cap", cap))
                    .foregroundStyle(Palette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("cap \(cap)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                    }
                    .accessibilityLabel("Daily cap \(cap)")
                if let selected = selectedDay(days) {
                    RuleMark(x: .value("Selected", selected.day, unit: .day))
                        .foregroundStyle(Palette.textSecondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text(ChartMath.dayAnnotation(selected))
                                .font(Typography.callout)
                                .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                                .glassPanel(cornerRadius: Radius.inner)
                        }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Palette.hairline); AxisValueLabel() } }
            .frame(height: 170)
            .motion(Motion.gentle, value: days)
            .accessibilityChartDescriptor(ApplicationsDescriptor(days: days))
        }
        .onChange(of: selectedDay(days)?.day) { _, new in if new != nil { Haptics.alignment() } }
        .onAppear {
            guard !hasAppeared else { return }
            // Bars grow from the baseline only on first appearance.
            withMotion(Motion.gentle, reduceMotion: reduced) { hasAppeared = true }
        }
    }

    private func selectedDay(_ days: [DayCount]) -> DayCount? {
        selectedDate.flatMap { ChartMath.nearestDay(to: $0, in: days) }
    }

    private func chartState(total: Int) -> CardState {
        let base = WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable)
        guard base == .content else { return base }
        if store.stats.totalApplied == 0 {
            return .empty(symbol: "chart.bar", message: "Charts fill in after your first ~10 applications")
        }
        return .content
    }
}

/// Audio-graph descriptor (§7).
struct ApplicationsDescriptor: AXChartDescriptorRepresentable {
    var days: [DayCount]

    func makeChartDescriptor() -> AXChartDescriptor {
        let maxValue = Double(days.map(\.applied).max() ?? 0)
        let x = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: days.map { $0.day.formatted(date: .abbreviated, time: .omitted) })
        let y = AXNumericDataAxisDescriptor(title: "Applications", range: 0...max(1, maxValue), gridlinePositions: []) { "\(Int($0))" }
        let series = AXDataSeriesDescriptor(name: "Applications per day", isContinuous: false,
                                            dataPoints: days.map { .init(x: $0.day.formatted(date: .abbreviated, time: .omitted), y: Double($0.applied)) })
        return AXChartDescriptor(title: "Applications, last 30 days", summary: "\(days.reduce(0) { $0 + $1.applied }) applications",
                                 xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
