// Materials.swift — glass is for the navigation/control layer, never content (§1.5).
// Every helper falls back to an opaque raised surface + hairline under Reduce Transparency.
import SwiftUI

extension View {
    /// Floating glass panel (⌘K palette, menu bar popover content, HUDs).
    func glassPanel(cornerRadius: CGFloat = Radius.palette, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: false))
    }

    /// Glass capsule (toasts, floating action buttons, the Paused overlay).
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: Capsule(), tint: tint, interactive: interactive))
    }

    /// Solid content surface: card background, hairline, and depth level 2 (§1.4).
    func surfaceCard(cornerRadius: CGFloat = Radius.card, raised: Bool = false) -> some View {
        modifier(SurfaceCard(cornerRadius: cornerRadius, raised: raised))
    }

    /// Inputs, code/log wells, screenshot wells.
    func sunkenWell(cornerRadius: CGFloat = Radius.inner) -> some View {
        background(Palette.sunken, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Floating depth for a dragged card: scale 1.03 + heavy shadow + velocity rotation.
    func dragLift(isDragging: Bool, rotation: Double = 0) -> some View {
        scaleEffect(isDragging ? 1.03 : 1)
            .rotationEffect(.degrees(isDragging ? max(-1.5, min(1.5, rotation)) : 0))
            .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: isDragging ? 12 : 0, y: isDragging ? 12 : 0)
    }
}

struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Palette.surfaceRaised, in: shape)
                .overlay(shape.stroke(Palette.hairline, lineWidth: 0.5))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

struct SurfaceCard: ViewModifier {
    var cornerRadius: CGFloat
    var raised: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(raised ? Palette.surfaceRaised : Palette.surface, in: shape)
            .overlay {
                shape.stroke(contrast == .increased ? Palette.strokeStrong : Palette.hairline,
                             lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .overlay(alignment: .top) {
                // Dark mode lifts with a 1pt top inner highlight instead of a shadow.
                if colorScheme == .dark {
                    shape.stroke(LinearGradient(colors: [.white.opacity(0.04), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.04), radius: 1, y: 1)
    }
}
