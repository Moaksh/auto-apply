// FeatureSupport.swift — small helpers shared by the C3 feature folders (Inbox, Review, Easy
// Apply, Profile, Resumes, Settings, Command palette): per-store model cache, clipboard,
// local file resolution, off-main thumbnails, and a generic "what changed" JSON diff used to
// build the protocol's partial-update patches.
import AppKit
import Foundation
import ImageIO
import Observation
import PDFKit

// MARK: - Per-store model cache

/// Feature models that must outlive a single screen appearance (pending undo windows, the
/// Resumes inspector's selection, Review selection). The app has one AppStore for its whole
/// lifetime (backends are swapped in place), so models are cached per store identity.
@MainActor
enum FeatureModels {
    private static var storage: [ObjectIdentifier: [ObjectIdentifier: AnyObject]] = [:]

    static func model<M: AnyObject>(_ type: M.Type, for store: AppStore, make: () -> M) -> M {
        let storeKey = ObjectIdentifier(store), typeKey = ObjectIdentifier(type)
        if let existing = storage[storeKey]?[typeKey] as? M { return existing }
        let created = make()
        storage[storeKey, default: [:]][typeKey] = created
        return created
    }

    /// Drop every cached model (tests).
    static func reset() { storage.removeAll() }
}

// MARK: - Clipboard

/// Clipboard seam so copy flows are testable without touching the real pasteboard.
@MainActor
protocol ClipboardWriting: AnyObject {
    func write(_ string: String)
}

@MainActor
final class SystemClipboard: ClipboardWriting {
    static let shared = SystemClipboard()

    func write(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

/// Records writes instead of touching NSPasteboard (tests, previews).
@MainActor
final class RecordingClipboard: ClipboardWriting {
    private(set) var writes: [String] = []
    func write(_ string: String) { writes.append(string) }
    var last: String? { writes.last }
}

// MARK: - Local files

enum LocalFiles {
    /// Resolve a path stored in the DB: absolute paths are used as-is, relative ones are taken
    /// relative to the AutoApply home. Returns nil for empty input.
    static func url(for path: String?, home: URL = AppPaths.resolve().home) -> URL? {
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return home.appendingPathComponent(expanded)
    }

    /// The URL only if the file currently exists.
    static func existing(_ path: String?, home: URL = AppPaths.resolve().home) -> URL? {
        guard let url = url(for: path, home: home), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @MainActor
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Thumbnails (off-main, cached)

/// A decoded image that can cross actor boundaries (CGImage is immutable).
struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    var size: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
}

/// PDF first-page and image thumbnails, rendered off the main actor (§2.7) and memoized.
actor C3Thumbnails {
    static let shared = C3Thumbnails()

    private var cache: [String: DecodedImage] = [:]
    private var order: [String] = []
    private let capacity = 64

    /// First page of a PDF, longest side ≤ `maxPixel`.
    func pdfFirstPage(_ url: URL, maxPixel: CGFloat = 480) -> DecodedImage? {
        let key = "pdf|\(url.path)|\(Int(maxPixel))"
        if let hit = cache[key] { return hit }
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = maxPixel / max(bounds.width, bounds.height, 1)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let decoded = DecodedImage(cgImage: cg)
        insert(key, decoded)
        return decoded
    }

    /// Downsampled image (screenshots), longest side ≤ `maxPixel`.
    func image(_ url: URL, maxPixel: CGFloat = 1600) -> DecodedImage? {
        let key = "img|\(url.path)|\(Int(maxPixel))"
        if let hit = cache[key] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let decoded = DecodedImage(cgImage: cg)
        insert(key, decoded)
        return decoded
    }

    /// Pixel size of the original image (to map recorded field bboxes onto a thumbnail).
    func originalSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    private func insert(_ key: String, _ image: DecodedImage) {
        cache[key] = image
        order.append(key)
        if order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
    }
}

// MARK: - JSON diff → partial update patches

enum JSONDiff {
    /// Top-level keys whose encoded value differs between `old` and `new`. A key present in
    /// `old` but absent in `new` (an optional set to nil) comes back as an explicit `.null`, so
    /// the daemon clears it. `ignoring` keys are never included.
    static func changes<T: Encodable>(from old: T, to new: T, ignoring: Set<String> = []) -> [String: JSONValue] {
        guard case .object(let a)? = try? JSONValue.encode(old), case .object(let b)? = try? JSONValue.encode(new) else { return [:] }
        var out: [String: JSONValue] = [:]
        for key in Set(a.keys).union(b.keys) where !ignoring.contains(key) {
            let before = a[key] ?? .null, after = b[key] ?? .null
            if !equivalent(before, after) { out[key] = after }
        }
        return out
    }

    /// Numbers compare by value (`5` == `5.0`); everything else structurally.
    static func equivalent(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .double(let y)), (.double(let y), .int(let x)): return Double(x) == y
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { equivalent($0, $1) }
        case (.object(let x), .object(let y)):
            return Set(x.keys) == Set(y.keys) && x.allSatisfy { k, v in y[k].map { equivalent(v, $0) } ?? false }
        default: return a == b
        }
    }

    static func preferencesPatch(from old: Preferences, to new: Preferences) -> PreferencesPatch {
        var patch = PreferencesPatch()
        patch.values = changes(from: old, to: new)
        return patch
    }

    static func neverGuessPatch(from old: NeverGuess, to new: NeverGuess) -> NeverGuessPatch {
        var patch = NeverGuessPatch()
        patch.values = changes(from: old, to: new)
        return patch
    }

    /// Profile fields the user edits (derived/raw fields are never sent back).
    static func profilePatch(from old: Profile, to new: Profile) -> ProfilePatch {
        var patch = ProfilePatch()
        patch.values = changes(from: old, to: new, ignoring: ["updated_at", "raw_text", "extra"])
        return patch
    }
}

// MARK: - Formatting

enum C3Format {
    static func sourceName(_ source: SourceName) -> String {
        switch source {
        case .linkedin: "LinkedIn"
        case .glassdoor: "Glassdoor"
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .careers: "Career pages"
        }
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func plural(_ n: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (pluralForm ?? singular + "s"))"
    }
}

extension Optional where Wrapped == String {
    /// nil for nil / blank strings, else the trimmed value.
    var c3Trimmed: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
