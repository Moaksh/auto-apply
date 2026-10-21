// Materials.swift — the two content surfaces and the one glass material.
//
// Content sits on exactly two things: a flat `surface()` (white / near-black + a 0.5pt hairline,
// radius 8, no shadow) and a sunken `well()` (stone) for inputs, quotes, screenshots and logs.
// Liquid Glass is only for the floating control layer (toolbar and sidebar come from the system;
// in-window: `GlassBar`, toasts, the ⌘K palette, the menu-bar panel chrome). Never content.
import SwiftUI

extension View {
    /// The content surface: flat, hairline, radius 8. No shadow, no tint, no glow.
    func surface(cornerRadius: CGFloat = Radius.card) -> some View {
        modifier(SurfaceModifier(cornerRadius: cornerRadius))
    }

    /// The sunken well (stone): inputs, quotes, screenshots, logs.
    func well(cornerRadius: CGFloat = Radius.inner) -> some View {
        background(Palette.sunken, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Liquid Glass for the floating control layer only. Falls back to an opaque surface +
    /// hairline under Reduce Transparency.
    func glassChrome<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassChrome(shape: shape, interactive: interactive))
    }

    /// A dragged card: a slight lift in scale only (no shadow).
    func dragLift(isDragging: Bool, rotation: Double = 0) -> some View {
        scaleEffect(isDragging ? 1.03 : 1)
            .rotationEffect(.degrees(isDragging ? max(-1.5, min(1.5, rotation)) : 0))
    }
}

private struct SurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Palette.surface, in: shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? Palette.strokeStrong : Palette.hairline,
                                   lineWidth: contrast == .increased ? 1 : 0.5)
            }
    }
}

private struct GlassChrome<S: Shape>: ViewModifier {
    let shape: S
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Palette.surface, in: shape)
                .overlay(shape.stroke(Palette.strokeStrong, lineWidth: 0.5))
        } else {
            content.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        }
    }
}
