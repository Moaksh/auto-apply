// AdaptiveColumns.swift — a stateless grid: as many equal columns as fit at `minColumnWidth`
// (capped at `maxColumns`), rows as tall as their tallest item. Replaces width-measuring
// `@State` + `onGeometryChange`, so it is safe in offscreen (ImageRenderer) renders.
import SwiftUI

struct AdaptiveColumns: Layout {
    var minColumnWidth: CGFloat
    var maxColumns: Int = 4
    var spacing: CGFloat = Space.gutter

    static func columns(for width: CGFloat, minColumnWidth: CGFloat, maxColumns: Int, spacing: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fit = Int((width + spacing) / (minColumnWidth + spacing))
        return max(1, min(maxColumns, fit))
    }

    private func plan(width: CGFloat, subviews: Subviews) -> (columns: Int, itemWidth: CGFloat, rowHeights: [CGFloat]) {
        let cols = Self.columns(for: width, minColumnWidth: minColumnWidth, maxColumns: maxColumns, spacing: spacing)
        let itemWidth = max(0, (width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
        var heights: [CGFloat] = []
        for (i, view) in subviews.enumerated() {
            let h = view.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height
            if i % cols == 0 { heights.append(h) } else { heights[heights.count - 1] = max(heights[heights.count - 1], h) }
        }
        return (cols, itemWidth, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth * CGFloat(maxColumns)
        let p = plan(width: width, subviews: subviews)
        let height = p.rowHeights.reduce(0, +) + spacing * CGFloat(max(0, p.rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in p.rowHeights.enumerated() {
            for col in 0..<p.columns {
                let index = row * p.columns + col
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(col) * (p.itemWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: p.itemWidth, height: height))
            }
            y += height + spacing
        }
    }
}
