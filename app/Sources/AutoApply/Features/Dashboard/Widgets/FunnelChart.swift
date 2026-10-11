// FunnelChart.swift — W8: Applied → Responded → Assessment → Interview → Offer over 30d / 90d /
// All. Horizontal bars in status colors with the count and share labeled directly; hover
// shows step conversion; clicking a bar opens Pipeline filtered to that status. Swift Charts
// BarMarks with trailing annotations.
import Charts
import SwiftUI

struct FunnelChart: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @AppStorage("dashboard.funnelWindow") private var windowRaw = StatsWindow.days30.rawValue
    @State private var hovered: FunnelStep.Stage?

    private var window: StatsWindow { StatsWindow(rawValue: windowRaw) ?? .days30 }

    var body: some View {
        let steps = store.stats.funnel(window)
        let applied = steps.first?.count ?? 0
        let base = WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable)
        let state: CardState = base != .content ? base
            : (applied == 0 ? .empty(symbol: "chart.bar.xaxis", message: "Charts fill in after your first ~10 applications") : .content)

        Card("Funnel", state: state, onRetry: { store.recomputeStats() }) {
            Picker("Window", selection: $windowRaw) {
                Text("30d").tag(StatsWindow.days30.rawValue)
                Text("90d").tag(StatsWindow.days90.rawValue)
                Text("All").tag(StatsWindow.all.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        } content: {
            Chart(steps) { step in
                BarMark(x: .value("Count", step.count), y: .value("Stage", ChartMath.funnelTitle(step.stage)))
                    .foregroundStyle(color(step.stage).opacity(hovered == nil || hovered == step.stage ? 1 : 0.45))
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.xs) {
                            Text("\(step.count)").font(Typography.metricSmall)
                            Text(hovered == step.stage ? conversionText(step) : ChartMath.funnelShareLabel(step, applied: applied))
                                .font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .accessibilityLabel(ChartMath.funnelTitle(step.stage))
                    .accessibilityValue("\(step.count)\(step.conversion.map { ", \(ChartMath.percent($0)) from previous step" } ?? "")")
            }
            .chartXScale(domain: 0...max(1, Double(applied) * 1.35))
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { _ in AxisValueLabel().font(Typography.callout) } }
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = stage(at: location, proxy: proxy, steps: steps)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in
                            if let stage = stage(at: location, proxy: proxy, steps: steps) {
                                router.showPipeline(filter: PipelineFilter(columns: ChartMath.funnelColumns(stage)))
                            }
                        }
                }
            }
            .frame(height: 150)
            .motion(Motion.gentle, value: steps)
            .accessibilityChartDescriptor(FunnelDescriptor(steps: steps))
        }
    }

    private func stage(at location: CGPoint, proxy: ChartProxy, steps: [FunnelStep]) -> FunnelStep.Stage? {
        guard let title: String = proxy.value(atY: location.y) else { return nil }
        return steps.first { ChartMath.funnelTitle($0.stage) == title }?.stage
    }

    private func conversionText(_ step: FunnelStep) -> String {
        guard let c = step.conversion else { return "" }
        return "\(ChartMath.percent(c, decimals: c > 0 && c < 0.01 ? 1 : 0)) of prev"
    }

    private func color(_ stage: FunnelStep.Stage) -> Color {
        switch stage {
        case .applied: Palette.applied
        case .responded: Palette.accent
        case .assessment: Palette.assessment
        case .interview: Palette.interview
        case .offer: Palette.offer
        }
    }
}

struct FunnelDescriptor: AXChartDescriptorRepresentable {
    var steps: [FunnelStep]

    func makeChartDescriptor() -> AXChartDescriptor {
        let names = steps.map { ChartMath.funnelTitle($0.stage) }
        let maxValue = Double(steps.map(\.count).max() ?? 0)
        return AXChartDescriptor(
            title: "Application funnel", summary: nil,
            xAxis: AXCategoricalDataAxisDescriptor(title: "Stage", categoryOrder: names),
            yAxis: AXNumericDataAxisDescriptor(title: "Applications", range: 0...max(1, maxValue), gridlinePositions: []) { "\(Int($0))" },
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(name: "Funnel", isContinuous: false,
                                            dataPoints: steps.map { .init(x: ChartMath.funnelTitle($0.stage), y: Double($0.count)) })])
    }
}
