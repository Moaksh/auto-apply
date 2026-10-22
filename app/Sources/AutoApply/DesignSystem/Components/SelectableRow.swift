// SelectableRow.swift — the one list-row treatment: consistent padding and radius, a hover
// wash, and the selected fill (accent 14%). Used by Needs You, Review, Easy Apply, Story Bank,
// the palette and the menu bar so a selected row looks the same everywhere.
//
// Motion: the hover wash fades with `Motion.snappy`. Inside a `.selectionHighlightGroup` the
// selected fill is one shared shape (`matchedGeometryEffect`) that travels from row to row with
// `Motion.move`; outside one it simply cross-fades.
import SwiftUI

struct SelectableRow: ViewModifier {
    var isSelected: Bool
    var horizontalPadding: CGFloat = Space.m
    var verticalPadding: CGFloat = Space.s
    @State private var hovering = false
    @Environment(\.selectionHighlightNamespace) private var namespace

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                ZStack {
                    shape.fill(hovering && !isSelected ? Palette.hairline.opacity(0.6) : .clear)
                        .motion(Motion.snappy, value: hovering)
                    if isSelected {
                        if let namespace {
                            shape.fill(Palette.accent.opacity(0.14))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        } else {
                            shape.fill(Palette.accent.opacity(0.14))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// The shared list-row look (padding, hover, selection).
    func selectableRow(isSelected: Bool, horizontalPadding: CGFloat = Space.m, verticalPadding: CGFloat = Space.s) -> some View {
        modifier(SelectableRow(isSelected: isSelected, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding))
    }
}
