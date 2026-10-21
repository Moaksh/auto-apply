// SelectableRow.swift — the one list-row treatment: consistent padding and radius, a hover
// wash, and the selected fill (accent 14%). Used by Needs You, Review, Easy Apply, Story Bank,
// the palette and the menu bar so a selected row looks the same everywhere.
import SwiftUI

struct SelectableRow: ViewModifier {
    var isSelected: Bool
    var horizontalPadding: CGFloat = Space.m
    var verticalPadding: CGFloat = Space.s
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return Palette.accent.opacity(0.14) }
        return hovering ? Palette.hairline.opacity(0.6) : .clear
    }
}

extension View {
    /// The shared list-row look (padding, hover, selection).
    func selectableRow(isSelected: Bool, horizontalPadding: CGFloat = Space.m, verticalPadding: CGFloat = Space.s) -> some View {
        modifier(SelectableRow(isSelected: isSelected, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding))
    }
}
