// ActivityHeatmap.swift — W12: applications per day for the last 26 weeks, GitHub-style:
// 11pt cells, 3pt gap, 3pt radius, 5-step accent ramp (0 = sunken). Drawn with ONE Canvas
// for performance, with invisible per-week accessibility elements on top. Hover shows a
// tooltip; click opens Activity filtered to that day.
import SwiftUI

struct ActivityHeatmap: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var hovered: ChartMath.HeatCell?
    @State private var interviewsByDay: [Date: Int] = [:]

    static let cell: CGFloat = 11
    static let gap: CGFloat = 3
    static let labelWidth: CGFloat = 16

    var body: some View {
        let cells = ChartMath.heatmapCells(store.stats.heatmap)
        let weeks = ChartMath.weekCount(cells)
        let base = WidgetDataState.resolve(isLoaded: store.jobs.isLoaded, isAvailable: store.repository.isAvailable)

        Surface("Activity · 26 weeks", state: base, onRetry: { store.recomputeStats() }) {
            legend
        } content: {
            // 26 weeks × 14pt ≈ 364pt: fits every card width, so no scroll view is needed.
            HStack(alignment: .top, spacing: Space.xs) {
                weekdayLabels
                grid(cells: cells, weeks: weeks)
            }
            if let hovered {
                Text(ChartMath.cellTooltip(hovered, interviewsLater: interviewsByDay[hovered.day] ?? 0))
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .transition(.opacity)
            } else {
                Text("Hover a day for details · click to open its activity").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        }
        .task(id: store.stats.computedAt) {
            interviewsByDay = ChartMath.interviewsByDay(jobs: store.jobs.all)
        }
    }

    private var weekdayLabels: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 0 ? ["M", "T", "W", "T", "F", "S", "S"][row] : "")
                    .font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                    .frame(width: Self.labelWidth, height: Self.cell, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private func grid(cells: [ChartMath.HeatCell], weeks: Int) -> some View {
        let pitch = Self.cell + Self.gap
        let width = CGFloat(max(weeks, 1)) * pitch - Self.gap
        let height = 7 * pitch - Self.gap
        return Canvas { ctx, _ in
            for c in cells {
                let rect = CGRect(x: CGFloat(c.week) * pitch, y: CGFloat(c.weekday) * pitch, width: Self.cell, height: Self.cell)
                let path = RoundedRectangle(cornerRadius: 3, style: .continuous).path(in: rect)
                ctx.fill(path, with: .color(Self.color(level: c.level)))
                if c.id == hovered?.id {
                    ctx.stroke(path, with: .color(Palette.textPrimary.opacity(0.6)), lineWidth: 1)
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hovered = cell(at: p, cells: cells)
            case .ended: hovered = nil
            }
        }
        .onTapGesture { p in
            if let c = cell(at: p, cells: cells) {
                router.showActivity(filter: ActivityFilter(day: c.day))
            }
        }
        .overlay(alignment: .topLeading) { accessibilityWeeks(cells: cells, weeks: weeks, pitch: pitch) }
    }

    /// One invisible accessibility element per week column (§7).
    private func accessibilityWeeks(cells: [ChartMath.HeatCell], weeks: Int, pitch: CGFloat) -> some View {
        let byWeek = Dictionary(grouping: cells, by: \.week)
        return HStack(spacing: 0) {
            ForEach(0..<weeks, id: \.self) { w in
                Color.clear
                    .frame(width: pitch, height: 7 * pitch)
                    .accessibilityElement()
                    .accessibilityLabel(ChartMath.weekSummary(byWeek[w] ?? []))
            }
        }
        .allowsHitTesting(false)
    }

    private func cell(at p: CGPoint, cells: [ChartMath.HeatCell]) -> ChartMath.HeatCell? {
        let pitch = Self.cell + Self.gap
        let week = Int(p.x / pitch), weekday = Int(p.y / pitch)
        return cells.first { $0.week == week && $0.weekday == weekday }
    }

    static func color(level: Int) -> Color {
        switch level {
        case 0: Palette.sunken
        case 1: Palette.accent.opacity(0.25)
        case 2: Palette.accent.opacity(0.45)
        case 3: Palette.accent.opacity(0.7)
        default: Palette.accent
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.color(level: level)).frame(width: 11, height: 11)
            }
            Text("More").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
        }
        .accessibilityHidden(true)
    }
}
