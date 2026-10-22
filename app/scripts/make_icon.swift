// make_icon.swift — draws the AutoApply app icon with CoreGraphics (no assets, no Xcode).
//
//   swift make_icon.swift out.png                    one 1024 px PNG (light)
//   swift make_icon.swift AppIcon.iconset            every size iconutil needs (16 … 512@2x)
//   swift make_icon.swift out.png --appearance dark  light · dark · tinted (previews of the variants)
//
// Concept (docs/DESIGN_AWARD_VISION.md §5.5): a stone-white paper plane folded from an application
// form, two faint ink field lines across its wing, flying up-right over a deep-green field, with one
// small coral dot at its nose: "you", the human it flies for. Layers, back to front: the green field
// (lit from the top-left), the plane's soft shadow on the field, the two-facet plane, the field lines,
// a specular sheen on the plane only, the coral dot, then the glass rim of the tile. macOS 26 grid:
// an 824 pt continuous-corner tile centred on the 1024 canvas with a soft drop shadow.
// Test: at 16 px it should still read as "a pale plane on green with a warm dot", so small sizes
// drop the field lines and sheen and get a slightly larger dot.
import AppKit

enum Appearance: String { case light, dark, tinted }

struct Palette {
    var fieldTop: CGColor, fieldBottom: CGColor, fieldGlow: CGColor
    var plane: CGColor, planeShade: CGColor, planeEdge: CGColor
    var lines: CGColor, dot: CGColor, shadow: CGColor, trail: CGColor

    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    static func make(_ a: Appearance) -> Palette {
        switch a {
        case .light: // brand: #0F5C4F → #003C33, stone plane, coral #FF7759
            Palette(fieldTop: rgb(0x16705F), fieldBottom: rgb(0x003C33), fieldGlow: rgb(0x2E8F78, 0.55),
                    plane: rgb(0xF6F3EC), planeShade: rgb(0xD5CEC0), planeEdge: rgb(0xFFFFFF, 0.9),
                    lines: rgb(0x17171C, 0.22), dot: rgb(0xFF7759), shadow: rgb(0x00211C, 0.55), trail: rgb(0x5FD9B9, 0.55))
        case .dark: // ink field, stone plane
            Palette(fieldTop: rgb(0x26262D), fieldBottom: rgb(0x0B0B0E), fieldGlow: rgb(0x0F5C4F, 0.35),
                    plane: rgb(0xEDE9E0), planeShade: rgb(0xBDB6A8), planeEdge: rgb(0xFFFFFF, 0.8),
                    lines: rgb(0x17171C, 0.26), dot: rgb(0xFF7759), shadow: rgb(0x000000, 0.6), trail: rgb(0x29AB8B, 0.6))
        case .tinted: // monochrome: the system tints it
            Palette(fieldTop: rgb(0x5A5A5E), fieldBottom: rgb(0x2C2C30), fieldGlow: rgb(0x8A8A90, 0.3),
                    plane: rgb(0xF2F2F2), planeShade: rgb(0xC4C4C6), planeEdge: rgb(0xFFFFFF, 0.9),
                    lines: rgb(0x000000, 0.22), dot: rgb(0xFFFFFF), shadow: rgb(0x000000, 0.5), trail: rgb(0xFFFFFF, 0.35))
        }
    }
}

// MARK: - Geometry (unit square of the tile, y down; shared with DesignSystem/Symbols/AASymbols.swift)

struct Plane {
    static let nose = CGPoint(x: 0.80, y: 0.22)
    /// The near wing: nose · wingTip · fold.
    static let wingTip = CGPoint(x: 0.15, y: 0.47)
    static let fold = CGPoint(x: 0.43, y: 0.57)
    /// The keel hanging under the fold: nose · fold · keel.
    static let keel = CGPoint(x: 0.47, y: 0.80)
    /// The far wing peeking out beyond the keel: nose · keel · farTip.
    static let farTip = CGPoint(x: 0.60, y: 0.64)
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

/// Apple-style continuous corners, approximated with a superellipse.
func squircle(_ r: CGRect, exponent n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c)
        let y = r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func polygon(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: pts)
    p.closeSubpath()
    return p
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

// MARK: - Drawing

func drawIcon(pixels: Int, appearance: Appearance) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gc.cgContext
    let pal = Palette.make(appearance)
    let small = pixels <= 40
    let k = CGFloat(pixels) / 1024

    // Work in 1024 space, y down.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: k, y: -k)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS grid: 824 tile at 100; small sizes use more of the canvas so the mark stays legible.
    let inset: CGFloat = small ? 64 : 100
    let tile = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    let tilePath = squircle(tile)
    /// Unit square of the tile → canvas.
    func P(_ u: CGPoint) -> CGPoint { CGPoint(x: tile.minX + u.x * tile.width, y: tile.minY + u.y * tile.height) }
    /// The plane's own frame inside the tile: slightly smaller and lower-left so the dot has air.
    func Q(_ u: CGPoint) -> CGPoint {
        let s: CGFloat = small ? 1.0 : 0.9
        return P(CGPoint(x: 0.5 + (u.x - 0.5) * s - 0.005, y: 0.5 + (u.y - 0.5) * s + 0.025))
    }

    // 1. Drop shadow under the tile (y down: positive y offset falls downward visually after the flip).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: (0) * k, height: (-12) * k), blur: (small ? 10 : 28) * k, color: Palette.rgb(0x000000, 0.32))
    ctx.addPath(tilePath)
    ctx.setFillColor(pal.fieldBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // 2. The field: top-left light falling to deep green, plus a soft glow behind the plane.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(linearGradient([pal.fieldTop, pal.fieldBottom]),
                           start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    ctx.drawRadialGradient(linearGradient([pal.fieldGlow, pal.fieldGlow.copy(alpha: 0)!]),
                           startCenter: P(CGPoint(x: 0.42, y: 0.38)), startRadius: 0,
                           endCenter: P(CGPoint(x: 0.42, y: 0.38)), endRadius: tile.width * 0.62, options: [])

    // 2b. The trail: the one illustrative motif (§5.6), a soft line the plane leaves behind it.
    if !small {
        let trail = CGMutablePath()
        trail.move(to: P(CGPoint(x: -0.02, y: 0.98)))
        trail.addCurve(to: Q(Plane.fold), control1: P(CGPoint(x: 0.22, y: 0.92)), control2: P(CGPoint(x: 0.20, y: 0.66)))
        ctx.saveGState()
        ctx.addPath(trail)
        ctx.setLineWidth(14)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(linearGradient([pal.trail.copy(alpha: 0)!, pal.trail]),
                               start: P(CGPoint(x: 0.02, y: 0.98)), end: Q(Plane.fold), options: [])
        ctx.restoreGState()
    }

    // 3. The plane's shadow on the field: the plane floats above it.
    let wing = polygon([Q(Plane.nose), Q(Plane.wingTip), Q(Plane.fold)])
    let keel = polygon([Q(Plane.nose), Q(Plane.fold), Q(Plane.keel)])
    let far = polygon([Q(Plane.nose), Q(Plane.keel), Q(Plane.farTip)])
    let whole = CGMutablePath()
    whole.addPath(far); whole.addPath(keel); whole.addPath(wing)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: (small ? 6 : 14) * k, height: (small ? -14 : -34) * k), blur: (small ? 18 : 46) * k, color: pal.shadow)
    ctx.addPath(whole)
    ctx.setFillColor(pal.plane)
    ctx.fillPath()
    ctx.restoreGState()

    // 4. The plane, back to front: the far wing in shade, the keel, then the bright near wing.
    func facet(_ path: CGPath, _ from: CGColor, _ to: CGColor, _ a: CGPoint, _ b: CGPoint) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(linearGradient([from, to]), start: Q(a), end: Q(b), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    let deep = pal.planeShade.blended(with: Palette.rgb(0x000000), 0.16)
    facet(far, pal.planeShade.blended(with: pal.plane, 0.3), pal.planeShade, Plane.nose, Plane.farTip)
    facet(keel, pal.planeShade, deep, Plane.nose, Plane.keel)
    facet(wing, pal.plane, pal.plane.blended(with: pal.planeShade, 0.3), Plane.wingTip, Plane.nose)
    // The crease where the wing folds over the keel.
    if !small {
        ctx.setLineCap(.round)
        ctx.setStrokeColor(deep.copy(alpha: 0.55)!)
        ctx.setLineWidth(3)
        ctx.move(to: Q(Plane.fold))
        ctx.addLine(to: Q(Plane.nose))
        ctx.strokePath()
    }

    // 5. The form: two ink field lines across the wing, parallel to its leading edge.
    if !small {
        ctx.setLineCap(.round)
        ctx.setStrokeColor(pal.lines)
        ctx.setLineWidth(15)
        for (s, from, to) in [(CGFloat(0.30), CGFloat(0.30), CGFloat(0.80)), (CGFloat(0.55), CGFloat(0.42), CGFloat(0.78))] {
            let a = lerp(Plane.wingTip, Plane.fold, s), b = lerp(Plane.nose, Plane.fold, s)
            ctx.move(to: Q(lerp(a, b, from)))
            ctx.addLine(to: Q(lerp(a, b, to)))
        }
        ctx.strokePath()
    }

    // 6. Glass: a specular sheen on the plane only, and a crisp lit leading edge.
    if !small {
        ctx.saveGState()
        ctx.addPath(whole)
        ctx.clip()
        ctx.drawLinearGradient(linearGradient([Palette.rgb(0xFFFFFF, 0.55), Palette.rgb(0xFFFFFF, 0)], [0, 0.55]),
                               start: P(CGPoint(x: 0.36, y: 0.28)), end: P(CGPoint(x: 0.5, y: 0.55)), options: [])
        ctx.restoreGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(pal.planeEdge)
        ctx.setLineWidth(5)
        ctx.move(to: Q(Plane.wingTip))
        ctx.addLine(to: Q(Plane.nose))
        ctx.strokePath()
    }

    // 7. The coral dot just ahead of the nose: the human it flies for.
    let dir = CGPoint(x: Plane.nose.x - Plane.fold.x, y: Plane.nose.y - Plane.fold.y)
    let len = hypot(dir.x, dir.y)
    let dotUnit = CGPoint(x: Plane.nose.x + dir.x / len * 0.058, y: Plane.nose.y + dir.y / len * 0.058)
    let dotR = tile.width * (small ? 0.072 : 0.034)
    let dc = Q(dotUnit)
    let dotRect = CGRect(x: dc.x - dotR, y: dc.y - dotR, width: dotR * 2, height: dotR * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: (0) * k, height: (-8) * k), blur: (small ? 6 : 18) * k, color: pal.shadow)
    ctx.setFillColor(pal.dot)
    ctx.fillEllipse(in: dotRect)
    ctx.restoreGState()
    if !small {
        ctx.saveGState()
        ctx.addEllipse(in: dotRect)
        ctx.clip()
        ctx.drawRadialGradient(linearGradient([Palette.rgb(0xFFFFFF, 0.55), Palette.rgb(0xFFFFFF, 0)]),
                               startCenter: CGPoint(x: dc.x - dotR * 0.35, y: dc.y - dotR * 0.4), startRadius: 0,
                               endCenter: CGPoint(x: dc.x - dotR * 0.35, y: dc.y - dotR * 0.4), endRadius: dotR * 0.9, options: [])
        ctx.restoreGState()
    }

    // 8. The tile's glass rim: a bright top edge fading out, and a faint inner hairline all round.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.addPath(tilePath)
    ctx.setLineWidth(small ? 10 : 6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(linearGradient([Palette.rgb(0xFFFFFF, 0.45), Palette.rgb(0xFFFFFF, 0.06), Palette.rgb(0xFFFFFF, 0.14)], [0, 0.5, 1]),
                           start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    gc.flushGraphics()
    return rep
}

extension CGColor {
    func blended(with other: CGColor, _ t: CGFloat) -> CGColor {
        let a = converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!.components!
        let b = other.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!.components!
        return CGColor(srgbRed: a[0] + (b[0] - a[0]) * t, green: a[1] + (b[1] - a[1]) * t,
                       blue: a[2] + (b[2] - a[2]) * t, alpha: a[3] + (b[3] - a[3]) * t)
    }
}

func write(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
var appearance = Appearance.light
if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
    appearance = Appearance(rawValue: args[i + 1]) ?? .light
    args.removeSubrange(i...(i + 1))
}
guard let out = args.first else {
    FileHandle.standardError.write("usage: swift make_icon.swift <out.png | AppIcon.iconset> [--appearance light|dark|tinted]\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: out)
if url.pathExtension == "iconset" {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for s in [16, 32, 128, 256, 512] {
        write(drawIcon(pixels: s, appearance: appearance), to: url.appendingPathComponent("icon_\(s)x\(s).png"))
        write(drawIcon(pixels: s * 2, appearance: appearance), to: url.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
    }
} else {
    write(drawIcon(pixels: 1024, appearance: appearance), to: url)
}
