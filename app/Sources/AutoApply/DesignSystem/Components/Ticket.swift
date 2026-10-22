// Ticket.swift — the ticket's paper: a body and a stub that meet at a dashed perforation, with
// half-circle die-cut notches where they meet. Content material, so it's the flat surface (fill +
// hairline, continuous corners, no shadow), never glass. Used by Review's ticket (ReviewTicket).
import SwiftUI

/// One side of a ticket. The body keeps its leading corners rounded and is notched on its trailing
/// edge; the stub mirrors it. Put side by side, the two notches make the die-cut circles.
struct TicketPart: Shape {
    enum Side: Sendable { case body, stub }

    var side: Side
    var notchRadius: CGFloat = 7
    var cornerRadius: CGFloat = Radius.card

    func path(in rect: CGRect) -> Path {
        let c = cornerRadius
        let radii = side == .body
            ? RectangleCornerRadii(topLeading: c, bottomLeading: c, bottomTrailing: 0, topTrailing: 0)
            : RectangleCornerRadii(topLeading: 0, bottomLeading: 0, bottomTrailing: c, topTrailing: c)
        let paper = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect)
        let x = side == .body ? rect.maxX : rect.minX
        let r = notchRadius
        var notches = Path()
        notches.addEllipse(in: CGRect(x: x - r, y: rect.minY - r, width: 2 * r, height: 2 * r))
        notches.addEllipse(in: CGRect(x: x - r, y: rect.maxY - r, width: 2 * r, height: 2 * r))
        return paper.subtracting(notches)
    }
}

/// The perforation: a vertical line down the middle of its rect, stopping short of the notches.
/// Stroke it dashed (`TicketPart.perforationStyle`).
struct TicketPerforation: Shape {
    var inset: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY + inset))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - inset))
        return p
    }
}

extension TicketPart {
    static let perforationStyle = StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3])
}

/// The ticket's paper: the surface fill and its hairline (stronger under Increase Contrast),
/// exactly like `surface()` but in the ticket's shape.
struct TicketPaper: View {
    var side: TicketPart.Side
    var fill: Color = Palette.surface
    /// Reduce Transparency's stand-in for the held glow: a coral rim.
    var rim: Color? = nil
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = TicketPart(side: side)
        shape.fill(fill)
            .overlay {
                shape.stroke(rim ?? (contrast == .increased ? Palette.strokeStrong : Palette.hairline),
                             lineWidth: rim != nil || contrast == .increased ? 1 : 0.5)
            }
    }
}

#Preview("Ticket paper") {
    HStack(spacing: 0) {
        TicketPaper(side: .body).frame(width: 320)
            .overlay(alignment: .trailing) {
                TicketPerforation().stroke(Palette.strokeStrong, style: TicketPart.perforationStyle).frame(width: 1)
            }
        TicketPaper(side: .stub, fill: Palette.primaryFill).frame(width: 140)
    }
    .frame(height: 100)
    .padding()
}
