// AASymbols.swift — AutoApply's small custom symbol set (docs/DESIGN_AWARD_VISION.md §5.5), drawn as
// SwiftUI `Shape`s so they need no asset catalog. They behave like SF Symbols: one colour from the
// foreground style, a square frame, a stroke weight close to SF's regular.
//
//   aa.plane        the agent and the app: a paper plane folded from a form, two field lines on the wing
//   aa.plane.fill   the same plane, filled (field lines and the crease cut out)
//   aa.plane.trail  variable-draw progress: the trail draws behind the plane as `progress` goes 0 → 1
//   aa.onetomany    answer once, many jobs: one dot fanning out to three
//   aa.record       the record / receipt: a slip with a torn edge and two lines
//   aa.closed       the Closed drawer: a page with a soft folded corner, not an X
//
// The plane matches the app icon's geometry (app/scripts/make_icon.swift, `Plane`), normalised to the
// unit square. `AASymbol.image(_:pointSize:)` makes a template NSImage for places that need one (the
// menu-bar label).
import AppKit
import SwiftUI

enum AASymbol: String, CaseIterable, Sendable {
    case plane = "aa.plane"
    case planeFill = "aa.plane.fill"
    case planeTrail = "aa.plane.trail"
    case oneToMany = "aa.onetomany"
    case record = "aa.record"
    case closed = "aa.closed"

    /// VoiceOver label.
    var accessibilityLabel: String {
        switch self {
        case .plane, .planeFill: "AutoApply"
        case .planeTrail: "Progress"
        case .oneToMany: "One answer, many jobs"
        case .record: "Record"
        case .closed: "Closed"
        }
    }

    /// The symbol's shape. `progress` only affects `aa.plane.trail`.
    func shape(progress: Double = 1) -> AnyShape {
        switch self {
        case .plane: AnyShape(AAPlaneShape(filled: false))
        case .planeFill: AnyShape(AAPlaneShape(filled: true))
        case .planeTrail: AnyShape(AAPlaneTrailShape(progress: progress))
        case .oneToMany: AnyShape(AAOneToManyShape())
        case .record: AnyShape(AARecordShape())
        case .closed: AnyShape(AAClosedShape())
        }
    }

    /// A template image (tinted by the system, like an SF Symbol) for AppKit hosts such as the menu bar.
    @MainActor static func image(_ symbol: AASymbol, pointSize: CGFloat = 16, progress: Double = 1) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(symbol.shape(progress: progress).path(in: rect).cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = symbol.accessibilityLabel
        return image
    }
}

/// A custom symbol as a view: `AASymbolView(.plane, size: 16)`. Fills with the current foreground style.
struct AASymbolView: View {
    let symbol: AASymbol
    var size: CGFloat = 16
    var progress: Double = 1

    init(_ symbol: AASymbol, size: CGFloat = 16, progress: Double = 1) {
        self.symbol = symbol
        self.size = size
        self.progress = progress
    }

    var body: some View {
        symbol.shape(progress: progress)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(symbol.accessibilityLabel)
    }
}

// MARK: - Geometry

/// Points in the unit square (y down). Kept in step with `Plane` in app/scripts/make_icon.swift.
enum AAGeometry {
    static let nose = CGPoint(x: 1.0, y: 0.054)
    static let wingTip = CGPoint(x: 0.0, y: 0.438)
    static let fold = CGPoint(x: 0.431, y: 0.592)
    static let keel = CGPoint(x: 0.492, y: 0.946)
    static let farTip = CGPoint(x: 0.692, y: 0.700)
    /// Two field lines across the wing: (offset toward the fold, start, end) along the leading edge.
    static let fieldLines: [(CGFloat, CGFloat, CGFloat)] = [(0.30, 0.30, 0.80), (0.55, 0.42, 0.78)]
    /// Stroke weight as a fraction of the symbol's side (about SF regular).
    static let weight: CGFloat = 0.085

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Maps unit points into `rect`, inset so strokes stay inside the frame.
    static func mapper(_ rect: CGRect, inset: CGFloat) -> (CGPoint) -> CGPoint {
        let side = min(rect.width, rect.height)
        let inner = side - 2 * inset
        let ox = rect.midX - side / 2 + inset, oy = rect.midY - side / 2 + inset
        return { CGPoint(x: ox + $0.x * inner, y: oy + $0.y * inner) }
    }

    static func stroke(_ path: Path, _ width: CGFloat) -> Path {
        path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// The plane mapped into `rect`; outline (stroked) or filled with the crease and lines cut out.
    static func plane(in rect: CGRect, filled: Bool) -> Path {
        let side = min(rect.width, rect.height)
        let w = side * weight
        let m = mapper(rect, inset: filled ? side * 0.02 : w / 2 + side * 0.01)
        var silhouette = Path()
        silhouette.addLines([nose, wingTip, fold, keel, farTip].map(m))
        silhouette.closeSubpath()
        var crease = Path()
        crease.move(to: m(fold)); crease.addLine(to: m(nose))
        var lines = Path()
        // Small outline sizes keep one field line so the wing doesn't clog.
        for (s, from, to) in (filled || side >= 24 ? fieldLines : Array(fieldLines.prefix(1))) {
            let a = lerp(wingTip, fold, s), b = lerp(nose, fold, s)
            lines.move(to: m(lerp(a, b, from)))
            lines.addLine(to: m(lerp(a, b, to)))
        }
        if filled {
            return silhouette
                .subtracting(stroke(crease, w * 0.6))
                .subtracting(stroke(lines, w * 0.75))
        }
        return stroke(silhouette, w)
            .union(stroke(crease, w * 0.7))
            .union(stroke(lines, w * 0.6))
    }
}

// MARK: - Shapes

/// `aa.plane` / `aa.plane.fill`.
struct AAPlaneShape: Shape {
    var filled = false
    func path(in rect: CGRect) -> Path { AAGeometry.plane(in: rect, filled: filled) }
}

/// `aa.plane.trail`: a filled plane in the top-right and the trail it leaves, drawn to `progress`.
/// Animatable, so a change in progress draws the trail on (Reduce Motion: set it without animation).
struct AAPlaneTrailShape: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let planeRect = CGRect(x: origin.x + side * 0.32, y: origin.y, width: side * 0.68, height: side * 0.68)
        var result = AAGeometry.plane(in: planeRect, filled: true)
        let w = side * AAGeometry.weight
        // From the bottom-left up into the plane's tail.
        let tail = CGPoint(x: planeRect.minX + AAGeometry.fold.x * planeRect.width * 0.96,
                           y: planeRect.minY + AAGeometry.fold.y * planeRect.height)
        var trail = Path()
        trail.move(to: CGPoint(x: origin.x + w / 2, y: origin.y + side - w / 2))
        trail.addCurve(to: tail,
                       control1: CGPoint(x: origin.x + side * 0.30, y: origin.y + side * 0.98),
                       control2: CGPoint(x: origin.x + side * 0.22, y: origin.y + side * 0.45))
        let p = min(max(progress, 0), 1)
        if p > 0 {
            result = result.union(AAGeometry.stroke(trail.trimmedPath(from: 0, to: p), w))
        }
        return result
    }
}

/// `aa.onetomany`: one answer (a dot) fanning out to three jobs.
struct AAOneToManyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let w = side * AAGeometry.weight
        let m = AAGeometry.mapper(rect, inset: side * 0.02)
        let source = m(CGPoint(x: 0.14, y: 0.5))
        let targets = [0.16, 0.5, 0.84].map { m(CGPoint(x: 0.88, y: $0)) }
        var fan = Path()
        for t in targets {
            fan.move(to: source)
            fan.addCurve(to: CGPoint(x: t.x - side * 0.08, y: t.y),
                         control1: CGPoint(x: source.x + side * 0.30, y: source.y),
                         control2: CGPoint(x: t.x - side * 0.36, y: t.y))
        }
        var dots = Path()
        let r = side * 0.13
        dots.addEllipse(in: CGRect(x: source.x - r, y: source.y - r, width: 2 * r, height: 2 * r))
        let tr = side * 0.085
        for t in targets { dots.addEllipse(in: CGRect(x: t.x - tr, y: t.y - tr, width: 2 * tr, height: 2 * tr)) }
        return AAGeometry.stroke(fan, w).union(dots)
    }
}

/// `aa.record`: a receipt slip with a torn bottom edge and two lines of text.
struct AARecordShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let w = side * AAGeometry.weight
        let m = AAGeometry.mapper(rect, inset: w / 2 + side * 0.02)
        let left: CGFloat = 0.14, right: CGFloat = 0.86, top: CGFloat = 0.0, bottom: CGFloat = 0.92
        var slip = Path()
        slip.move(to: m(CGPoint(x: left, y: bottom)))
        slip.addLine(to: m(CGPoint(x: left, y: top + 0.08)))
        slip.addQuadCurve(to: m(CGPoint(x: left + 0.08, y: top)), control: m(CGPoint(x: left, y: top)))
        slip.addLine(to: m(CGPoint(x: right - 0.08, y: top)))
        slip.addQuadCurve(to: m(CGPoint(x: right, y: top + 0.08)), control: m(CGPoint(x: right, y: top)))
        slip.addLine(to: m(CGPoint(x: right, y: bottom)))
        // Torn edge: four teeth back to the left.
        let teeth = 4
        let step = (right - left) / CGFloat(teeth)
        for i in 0..<teeth {
            let x0 = right - CGFloat(i) * step
            slip.addLine(to: m(CGPoint(x: x0 - step / 2, y: bottom - 0.08)))
            slip.addLine(to: m(CGPoint(x: x0 - step, y: bottom)))
        }
        slip.closeSubpath()
        var lines = Path()
        lines.move(to: m(CGPoint(x: 0.32, y: 0.30))); lines.addLine(to: m(CGPoint(x: 0.68, y: 0.30)))
        lines.move(to: m(CGPoint(x: 0.32, y: 0.52))); lines.addLine(to: m(CGPoint(x: 0.56, y: 0.52)))
        return AAGeometry.stroke(slip, w).union(AAGeometry.stroke(lines, w * 0.85))
    }
}

/// `aa.closed`: a page with its corner folded softly down: put away, not crossed out.
struct AAClosedShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let w = side * AAGeometry.weight
        let m = AAGeometry.mapper(rect, inset: w / 2 + side * 0.02)
        let left: CGFloat = 0.12, right: CGFloat = 0.88, top: CGFloat = 0.0, bottom: CGFloat = 1.0, fold: CGFloat = 0.32
        var page = Path()
        page.move(to: m(CGPoint(x: left + 0.08, y: top)))
        page.addLine(to: m(CGPoint(x: right - 0.08, y: top)))
        page.addQuadCurve(to: m(CGPoint(x: right, y: top + 0.08)), control: m(CGPoint(x: right, y: top)))
        page.addLine(to: m(CGPoint(x: right, y: bottom - fold)))
        page.addLine(to: m(CGPoint(x: right - fold, y: bottom)))
        page.addLine(to: m(CGPoint(x: left + 0.08, y: bottom)))
        page.addQuadCurve(to: m(CGPoint(x: left, y: bottom - 0.08)), control: m(CGPoint(x: left, y: bottom)))
        page.addLine(to: m(CGPoint(x: left, y: top + 0.08)))
        page.addQuadCurve(to: m(CGPoint(x: left + 0.08, y: top)), control: m(CGPoint(x: left, y: top)))
        page.closeSubpath()
        // The folded-over corner: a soft curl back onto the page.
        var flap = Path()
        flap.move(to: m(CGPoint(x: right, y: bottom - fold)))
        flap.addQuadCurve(to: m(CGPoint(x: right - fold, y: bottom)),
                          control: m(CGPoint(x: right - fold * 0.95, y: bottom - fold * 0.95)))
        flap.closeSubpath()
        // One calm line of text.
        var line = Path()
        line.move(to: m(CGPoint(x: 0.30, y: 0.30))); line.addLine(to: m(CGPoint(x: 0.70, y: 0.30)))
        return AAGeometry.stroke(page, w).union(flap).union(AAGeometry.stroke(line, w * 0.85))
    }
}
