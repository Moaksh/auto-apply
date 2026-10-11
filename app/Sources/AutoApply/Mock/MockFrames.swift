// MockFrames.swift — synthetic "live Chrome" frames (base64 JPEG ≤ 720 px) for MockDaemon's
// agent_step events: a stylized application form whose fields fill in step by step.
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

enum MockFrames {
    private static let cache = Mutex<[String: String]>([:])

    /// Base64 JPEG of a form at `step` of `total`, tinted per company.
    static func frame(company: String, step: Int, total: Int, width: Int = 720, height: Int = 450) -> String? {
        let key = "\(company)|\(step)|\(total)|\(width)"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        guard let data = render(company: company, step: step, total: total, width: width, height: height) else { return nil }
        let b64 = data.base64EncodedString()
        cache.withLock { $0[key] = b64 }
        return b64
    }

    static func render(company: String, step: Int, total: Int, width: Int, height: Int) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        // CoreGraphics origin is bottom-left; draw top-down by flipping.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Browser chrome
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 28))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 90, y: 6, width: w - 180, height: 16))
        for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.78, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 10 + CGFloat(i) * 16, y: 9, width: 10, height: 10))
        }

        // Company header band
        let hue = hueFor(company)
        ctx.setFillColor(CGColor(srgbRed: hue.0, green: hue.1, blue: hue.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 28, width: w, height: 56))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        ctx.fill(CGRect(x: 32, y: 48, width: 160, height: 14))

        // Form fields
        let fields = max(total, 7)
        let filled = min(step + 1, fields)
        for i in 0..<fields {
            let y = 104 + CGFloat(i) * 46
            guard y + 30 < h else { break }
            ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
            ctx.fill(CGRect(x: 40, y: y, width: 120, height: 8))
            let box = CGRect(x: 40, y: y + 13, width: w - 80, height: 24)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(box)
            if i < filled {
                ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
                ctx.fill(CGRect(x: 48, y: y + 21, width: CGFloat(80 + (i * 53) % 260), height: 8))
            }
            if i == step {
                ctx.setStrokeColor(CGColor(srgbRed: 0.31, green: 0.36, blue: 0.84, alpha: 1))
                ctx.setLineWidth(2)
                ctx.stroke(box.insetBy(dx: -1, dy: -1))
            } else {
                ctx.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
                ctx.setLineWidth(1)
                ctx.stroke(box)
            }
        }

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func hueFor(_ name: String) -> (CGFloat, CGFloat, CGFloat) {
        let palette: [(CGFloat, CGFloat, CGFloat)] = [(0.39, 0.36, 0.95), (0.18, 0.62, 0.72), (0.12, 0.13, 0.2), (0.85, 0.36, 0.5), (0.2, 0.5, 0.35)]
        var hash: UInt64 = 1469598103934665603
        for b in name.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
