// ClosedDrawer.swift — a kind no (DESIGN_AWARD_VISION 1F): Rejected and Ghosted fold into one
// quiet "Closed" drawer at the end of the Pipeline. Folded by default it is a narrow strip with a
// count; opened, it shows both columns in calm neutral styling. Never red, never celebrated.
// While folded it still takes a drop ("Close it"), so closing a card never needs the drawer open.
import SwiftUI

struct ClosedDrawer<Columns: View>: View {
    var columns: [BoardColumn]
    var count: Int
    var model: BoardModel
    /// The drawer is open (by the user, or because the filter asks for a closed column).
    var expanded: Bool
    /// Only the user's own toggle can fold it again.
    var canFold: Bool
    @ViewBuilder var content: () -> Columns

    @Environment(\.undoManager) private var undoManager
    @Environment(\.motionReduced) private var reduced

    static var strip: CGFloat { 132 }

    var body: some View {
        Group {
            if expanded {
                VStack(alignment: .leading, spacing: Space.s) {
                    header
                    HStack(alignment: .top, spacing: Space.gutter) { content() }
                }
                .transition(.opacity)
            } else {
                folded.transition(.opacity)
            }
        }
        .motion(Motion.snappy, value: expanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Closed, \(count) jobs")
    }

    private var header: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "archivebox").imageScale(.small).foregroundStyle(Palette.textTertiary)
            Text("Closed").eyebrowStyle()
            Text("\(count)").font(Typography.metricSmall).foregroundStyle(Palette.textSecondary).monospacedDigit()
            if canFold {
                Button("Fold") { toggle() }
                    .buttonStyle(.secondaryLink)
                    .help("Fold the Closed drawer")
            }
            Spacer()
        }
        .padding(.horizontal, Space.xs)
        .accessibilityAddTraits(.isHeader)
    }

    private var folded: some View {
        let legal = model.draggingJobID != nil && model.isLegalTarget(.rejected)
        return Button { toggle() } label: {
            VStack(alignment: .leading, spacing: Space.s) {
                Image(systemName: "archivebox").foregroundStyle(Palette.textTertiary)
                Text("Closed").eyebrowStyle()
                Text("\(count)").font(Typography.metricSmall).foregroundStyle(Palette.textSecondary).monospacedDigit()
                Text(legal ? "Close it" : "They went another way, or never replied.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Space.s)
            .frame(width: Self.strip, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .well(cornerRadius: Radius.card)
            .overlay {
                if legal {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Palette.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(model.draggingJobID != nil && !legal ? 0.4 : 1)
        .onDrop(of: [.text], delegate: ColumnDropDelegate(column: .rejected, model: model, undoManager: undoManager))
        .help("Open the Closed drawer")
        .accessibilityLabel("Closed, \(count) jobs. Open the drawer")
    }

    private func toggle() {
        withMotion(Motion.snappy, reduceMotion: reduced) { model.toggleClosed() }
    }
}
