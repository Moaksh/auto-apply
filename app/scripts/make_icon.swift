// Draws a simple 1024px app icon PNG: swift make_icon.swift out.png
import AppKit
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 40, y: 40, width: 944, height: 944)
let p = NSBezierPath(roundedRect: r, xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(red: 0.36, green: 0.40, blue: 0.98, alpha: 1), ending: NSColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 1))!.draw(in: p, angle: -60)
// The app's paper-plane mark (same glyph as onboarding), white on the brand gradient.
let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold).applying(.init(paletteColors: [.white]))
if let plane = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let ps = plane.size
    plane.draw(in: NSRect(x: (1024 - ps.width) / 2 - 10, y: (1024 - ps.height) / 2 - 10, width: ps.width, height: ps.height))
} else {
    let s = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 640, weight: .heavy), .foregroundColor: NSColor.white])
    let sz = s.size()
    s.draw(at: NSPoint(x: (1024 - sz.width) / 2, y: (1024 - sz.height) / 2))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
