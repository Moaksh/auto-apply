// ScoreHistogram.swift — W10 match score distribution: bins of 5 stacked skipped (slate 40%)
// vs applied (accent) + a draggable threshold RuleMark. Dragging snaps every 5 points with an
// alignment haptic and previews "At 65: +23 jobs/week would qualify"; it never saves silently —
// the user presses Set threshold (update_preferences).
import Charts
import SwiftUI

struct ScoreHistogram: View {
    @Environment(AppStore.self) private var store
    @State private var proposed: Int?
    @State private var sortedScores: [Int] = []
    @State private var isSaving = false

    private struct Segment: Identifiable {
        var id: String { "\(bin)-\(kind)" }
        var bin: Int
        var kind: String
        var count: Int
        /// Stack offset (skipped sits on the baseline, applied on top of it).
        var base: Int
    }

    var body: some View {
        let bins = store.stats.scoreHistogram
        let current = store.preferences.matchThreshold
        let threshold = proposed ?? current
        let segments = bins.flatMap { b in
            [Segment(bin: b.lower, kind: "Skipped", count: b.skipped, base: 0), Segment(bin: b.lower, kind: "Applied", count: b.applied, base: b.skipped)]
        }.filter { $0.count > 0 }
        let hasData = bins.contains { $0.total > 0 }
        let base = WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable)
        let state: SurfaceState = base != .content ? base
            : (hasData ? .content : .empty(symbol: "chart.bar.doc.horizontal", message: "Scores appear after the first discovery run"))

        Surface("Match scores", state: state, onRetry: { store.recomputeStats() }) {
            VStack(alignment: .leading, spacing: Space.s) {
                Chart {
                    ForEach(segments) { s in bar(s, threshold: threshold) }
                    RuleMark(x: .value("Threshold", threshold))
                        .foregroundStyle(Palette.accent)
                        .lineStyle(StrokeStyle(lineWidth: proposed == nil ? 1.5 : 2))
                        .annotation(position: .top, alignment: .center) {
                            Text("\(threshold)").font(Typography.metricSmall).foregroundStyle(Palette.accent)
                        }
                        .accessibilityLabel("Match threshold \(threshold)")
                }
                .chartForegroundStyleScale(["Skipped": Palette.categorical[4].opacity(0.4), "Applied": Palette.accent])
                .chartXScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: [0, 25, 50, 70, 100]) { _ in AxisValueLabel() } }
                .chartYAxis(.hidden)
                .chartLegend(position: .bottom, alignment: .leading, spacing: Space.xs)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard let plot = proxy.plotFrame else { return }
                                    let x = value.location.x - geo[plot].origin.x
                                    guard let raw: Double = proxy.value(atX: x) else { return }
                                    let snapped = ChartMath.snapThreshold(raw)
                                    if snapped != threshold { Haptics.alignment() }
                                    proposed = snapped == current ? nil : snapped
                                })
                    }
                }
                .frame(height: 120)
                .accessibilityChartDescriptor(HistogramDescriptor(bins: bins))
                .accessibilityAdjustableAction { direction in
                    let step = direction == .increment ? 5 : -5
                    let next = min(100, max(0, threshold + step))
                    proposed = next == current ? nil : next
                }

                HStack(spacing: Space.s) {
                    if let proposed, let preview = ChartMath.thresholdPreview(sortedScores: sortedScores, current: current, proposed: proposed) {
                        Text(preview).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button("Cancel") { self.proposed = nil }.buttonStyle(.secondaryLink)
                        Button("Set threshold") { save(proposed, old: current) }
                            .buttonStyle(.bordered)
                            .disabled(isSaving || !store.isConnected)
                    } else {
                        Text("Drag the line to preview a new threshold").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    }
                }
                .frame(minHeight: 24)
            }
        }
        .task(id: store.stats.computedAt) {
            sortedScores = ChartMath.recentScores(jobs: store.jobs.all)
        }
    }

    private func bar(_ s: Segment, threshold: Int) -> some ChartContent {
        let x0 = Double(s.bin) + 0.4
        let x1 = Double(s.bin) + 4.6
        let top = s.base + s.count
        let dimmed = s.kind == "Applied" && s.bin + 5 <= threshold
        let label = "Scores \(s.bin) to \(s.bin + 4), \(s.kind.lowercased())"
        return RectangleMark(xStart: .value("Score", x0), xEnd: .value("Score", x1),
                       yStart: .value("Jobs", s.base), yEnd: .value("Jobs", top))
            .foregroundStyle(by: .value("Outcome", s.kind))
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityLabel(label)
            .accessibilityValue("\(s.count) jobs")
    }

    private func save(_ value: Int, old: Int) {
        isSaving = true
        Task {
            var patch = PreferencesPatch()
            try? patch.set(.matchThreshold, value)
            let ok = await store.updatePreferences(patch, optimistic: { $0.matchThreshold = value }, rollback: { $0.matchThreshold = old })
            isSaving = false
            if ok {
                proposed = nil
                store.toasts.show("Match threshold set to \(value)", symbol: "checkmark", style: .success)
            }
        }
    }
}

struct HistogramDescriptor: AXChartDescriptorRepresentable {
    var bins: [ScoreBin]

    func makeChartDescriptor() -> AXChartDescriptor {
        let maxValue = Double(bins.map(\.total).max() ?? 0)
        let x = AXNumericDataAxisDescriptor(title: "Match score", range: 0...100, gridlinePositions: []) { "\(Int($0))" }
        let y = AXNumericDataAxisDescriptor(title: "Jobs", range: 0...max(1, maxValue), gridlinePositions: []) { "\(Int($0))" }
        return AXChartDescriptor(title: "Match score distribution", summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [
            AXDataSeriesDescriptor(name: "Skipped", isContinuous: false, dataPoints: bins.map { .init(x: Double($0.lower), y: Double($0.skipped)) }),
            AXDataSeriesDescriptor(name: "Applied", isContinuous: false, dataPoints: bins.map { .init(x: Double($0.lower), y: Double($0.applied)) }),
        ])
    }
}
