// SecretIcon.swift — "Midnight Gold", the app icon unlocked by finding every easter egg. The same
// paper plane as app/scripts/make_icon.swift (same tile, same geometry), folded from gold foil and
// flying through a night sky: an aurora behind it, a holographic trail, eight bright stars (one
// per secret) and a small coral heart at its nose where the everyday icon has a dot.
// It's drawn at runtime and set as the Dock icon (`NSApp.applicationIconImage`): changing the
// bundle's own icon would break the app's signature and be undone by the next update.
import AppKit

enum SecretIcon {
    /// The 1024 px icon (drawn once).
    @MainActor static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.addRepresentation(draw(pixels: 1024))
        return image
    }()

    // Plane geometry in the tile's unit square, y down (`Plane` in make_icon.swift).
    private static let nose = CGPoint(x: 0.80, y: 0.22)
    private static let wingTip = CGPoint(x: 0.15, y: 0.47)
    private static let fold = CGPoint(x: 0.43, y: 0.57)
    private static let keel = CGPoint(x: 0.47, y: 0.80)
    private static let farTip = CGPoint(x: 0.60, y: 0.64)

    /// The eight secrets, as stars along the plane's path (unit square, radius as a fraction of the tile).
    static let constellation: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 0.12, y: 0.16), 0.014), (CGPoint(x: 0.27, y: 0.10), 0.010), (CGPoint(x: 0.44, y: 0.14), 0.017),
        (CGPoint(x: 0.88, y: 0.42), 0.011), (CGPoint(x: 0.80, y: 0.60), 0.015), (CGPoint(x: 0.86, y: 0.80), 0.010),
        (CGPoint(x: 0.66, y: 0.88), 0.013), (CGPoint(x: 0.22, y: 0.70), 0.009),
    ]

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    private static func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Apple-style continuous corners, approximated with a superellipse.
    private static func squircle(_ r: CGRect, exponent n: CGFloat = 5.0) -> CGPath {
        let p = CGMutablePath()
        let steps = 720
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let pt = CGPoint(x: r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c),
                             y: r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }

    private static func polygon(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts)
        p.closeSubpath()
        return p
    }

    /// A four-point sparkle centred on `c`.
    private static func sparkle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let w = r * 0.22
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
        p.closeSubpath()
        return p
    }

    /// A heart centred on `c`, `r` wide from the centre, point down (y down).
    private static func heart(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + r * 0.95))
        p.addCurve(to: CGPoint(x: c.x - r, y: c.y - r * 0.2),
                   control1: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.6), control2: CGPoint(x: c.x - r, y: c.y + r * 0.3))
        p.addArc(center: CGPoint(x: c.x - r * 0.5, y: c.y - r * 0.3), radius: r * 0.51, startAngle: .pi * 1.06, endAngle: .pi * 1.94, clockwise: false)
        p.addArc(center: CGPoint(x: c.x + r * 0.5, y: c.y - r * 0.3), radius: r * 0.51, startAngle: .pi * 1.06, endAngle: .pi * 1.94, clockwise: false)
        p.addCurve(to: CGPoint(x: c.x, y: c.y + r * 0.95),
                   control1: CGPoint(x: c.x + r, y: c.y + r * 0.3), control2: CGPoint(x: c.x + r * 0.35, y: c.y + r * 0.6))
        p.closeSubpath()
        return p
    }

    static func draw(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        let ctx = gc.cgContext
        let small = pixels <= 40
        let k = CGFloat(pixels) / 1024
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: k, y: -k)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        let inset: CGFloat = small ? 64 : 100
        let tile = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
        let tilePath = squircle(tile)
        func P(_ u: CGPoint) -> CGPoint { CGPoint(x: tile.minX + u.x * tile.width, y: tile.minY + u.y * tile.height) }
        func Q(_ u: CGPoint) -> CGPoint {
            let s: CGFloat = small ? 1.0 : 0.9
            return P(CGPoint(x: 0.5 + (u.x - 0.5) * s - 0.005, y: 0.5 + (u.y - 0.5) * s + 0.025))
        }

        // 1. Drop shadow under the tile.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: (small ? 10 : 28) * k, color: rgb(0x000000, 0.36))
        ctx.addPath(tilePath)
        ctx.setFillColor(rgb(0x07061A))
        ctx.fillPath()
        ctx.restoreGState()

        // 2. The night: indigo falling to near-black, an aurora (violet and teal) behind the plane.
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0x2A1B5C), rgb(0x120C33), rgb(0x05040F)], [0, 0.55, 1]),
                               start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
        for (center, color, radius) in [(CGPoint(x: 0.30, y: 0.30), rgb(0x9B5CFF, 0.55), 0.62),
                                        (CGPoint(x: 0.78, y: 0.70), rgb(0x1FD1B5, 0.30), 0.55),
                                        (CGPoint(x: 0.62, y: 0.22), rgb(0xFF6FA8, 0.22), 0.40)] {
            ctx.drawRadialGradient(gradient([color, color.copy(alpha: 0)!]), startCenter: P(center), startRadius: 0,
                                   endCenter: P(center), endRadius: tile.width * radius, options: [])
        }

        // 3. Dust (faint, deterministic) and the eight secret stars.
        if !small {
            var seed: UInt64 = 0x5EC12E7
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(1 << 31)
            }
            for _ in 0..<70 {
                let c = P(CGPoint(x: next(), y: next()))
                let r = 1.2 + next() * 2.2
                ctx.setFillColor(rgb(0xFFFFFF, 0.18 + next() * 0.35))
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            for (u, r) in constellation {
                let c = P(u), rr = tile.width * r
                ctx.drawRadialGradient(gradient([rgb(0xFFE7A3, 0.55), rgb(0xFFE7A3, 0)]), startCenter: c, startRadius: 0,
                                       endCenter: c, endRadius: rr * 3.2, options: [])
                ctx.addPath(sparkle(c, rr * 1.6))
                ctx.setFillColor(rgb(0xFFF6DA))
                ctx.fillPath()
            }
        }

        // 4. The holographic trail.
        if !small {
            let trail = CGMutablePath()
            trail.move(to: P(CGPoint(x: -0.02, y: 0.98)))
            trail.addCurve(to: Q(fold), control1: P(CGPoint(x: 0.22, y: 0.92)), control2: P(CGPoint(x: 0.20, y: 0.66)))
            ctx.saveGState()
            ctx.addPath(trail)
            ctx.setLineWidth(18)
            ctx.setLineCap(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(gradient([rgb(0x1FD1B5, 0), rgb(0x5AB8FF, 0.7), rgb(0xB57BFF, 0.85), rgb(0xFF8FC0, 0.95)], [0, 0.35, 0.7, 1]),
                                   start: P(CGPoint(x: 0.02, y: 0.98)), end: Q(fold), options: [])
            ctx.restoreGState()
        }

        // 5. The plane's glow and shadow, then gold foil facets.
        let wing = polygon([Q(nose), Q(wingTip), Q(fold)])
        let keelPath = polygon([Q(nose), Q(fold), Q(keel)])
        let far = polygon([Q(nose), Q(keel), Q(farTip)])
        let whole = CGMutablePath()
        whole.addPath(far); whole.addPath(keelPath); whole.addPath(wing)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: (small ? 12 : 60) * k, color: rgb(0xFFC85A, 0.55))
        ctx.addPath(whole)
        ctx.setFillColor(rgb(0xE9B54E))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: (small ? 6 : 14) * k, height: (small ? -14 : -34) * k), blur: (small ? 18 : 46) * k, color: rgb(0x000000, 0.6))
        ctx.addPath(whole)
        ctx.setFillColor(rgb(0xE9B54E))
        ctx.fillPath()
        ctx.restoreGState()

        func facet(_ path: CGPath, _ colors: [CGColor], _ locations: [CGFloat], _ a: CGPoint, _ b: CGPoint) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient(colors, locations), start: Q(a), end: Q(b), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        facet(far, [rgb(0xC98F2E), rgb(0x8A5A14)], [0, 1], nose, farTip)
        facet(keelPath, [rgb(0xB57A22), rgb(0x6E440C)], [0, 1], nose, keel)
        facet(wing, [rgb(0xFFF1C2), rgb(0xF6CB62), rgb(0xE0A23A), rgb(0xFFE29A)], [0, 0.35, 0.7, 1], wingTip, nose)
        if !small {
            // The crease, and two engraved field lines (the form it was folded from).
            ctx.setLineCap(.round)
            ctx.setStrokeColor(rgb(0x5A3608, 0.55))
            ctx.setLineWidth(3)
            ctx.move(to: Q(fold))
            ctx.addLine(to: Q(nose))
            ctx.strokePath()
            ctx.setStrokeColor(rgb(0x7A4E12, 0.32))
            ctx.setLineWidth(14)
            for (s, from, to) in [(CGFloat(0.30), CGFloat(0.30), CGFloat(0.80)), (CGFloat(0.55), CGFloat(0.42), CGFloat(0.78))] {
                let a = lerp(wingTip, fold, s), b = lerp(nose, fold, s)
                ctx.move(to: Q(lerp(a, b, from)))
                ctx.addLine(to: Q(lerp(a, b, to)))
            }
            ctx.strokePath()
            // Foil sheen and a lit leading edge.
            ctx.saveGState()
            ctx.addPath(whole)
            ctx.clip()
            ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.65), rgb(0xFFFFFF, 0)], [0.35, 0.5, 0.65]),
                                   start: P(CGPoint(x: 0.30, y: 0.30)), end: P(CGPoint(x: 0.62, y: 0.58)), options: [])
            ctx.restoreGState()
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(rgb(0xFFF8E0, 0.95))
            ctx.setLineWidth(5)
            ctx.move(to: Q(wingTip))
            ctx.addLine(to: Q(nose))
            ctx.strokePath()
        }

        // 6. The coral heart ahead of the nose (a dot when tiny): made with love.
        let dir = CGPoint(x: nose.x - fold.x, y: nose.y - fold.y)
        let len = hypot(dir.x, dir.y)
        let hc = Q(CGPoint(x: nose.x + dir.x / len * 0.075, y: nose.y + dir.y / len * 0.075))
        let hr = tile.width * (small ? 0.072 : 0.05)
        let mark = small ? CGPath(ellipseIn: CGRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2), transform: nil) : heart(hc, hr)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: (small ? 6 : 30) * k, color: rgb(0xFF5A7A, 0.8))
        ctx.addPath(mark)
        ctx.setFillColor(rgb(0xFF6A6A))
        ctx.fillPath()
        ctx.restoreGState()
        if !small {
            ctx.saveGState()
            ctx.addPath(mark)
            ctx.clip()
            ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.6), rgb(0xFFFFFF, 0)]),
                                   startCenter: CGPoint(x: hc.x - hr * 0.4, y: hc.y - hr * 0.45), startRadius: 0,
                                   endCenter: CGPoint(x: hc.x - hr * 0.4, y: hc.y - hr * 0.45), endRadius: hr * 0.9, options: [])
            ctx.restoreGState()
        }

        // 7. A gold glass rim.
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        ctx.addPath(tilePath)
        ctx.setLineWidth(small ? 10 : 7)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFFE7A3, 0.75), rgb(0xFFE7A3, 0.08), rgb(0xB57BFF, 0.35)], [0, 0.5, 1]),
                               start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
        ctx.restoreGState()
        ctx.restoreGState()

        gc.flushGraphics()
        return rep
    }
}
