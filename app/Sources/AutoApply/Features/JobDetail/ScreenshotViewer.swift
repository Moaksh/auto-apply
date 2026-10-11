// ScreenshotViewer.swift — full-page screenshot viewer (§5.4): tall scroll preview with a
// minimap strip on the right, Q&A-linked field highlights (hover a Q&A row → the viewer
// scrolls to and outlines that field), ⌘+ / ⌘− zoom, a pre/post filmstrip and Space for Quick
// Look. Images decode off-main (thumbnails ≤ 640 px via CGImageSource) and are cached.
import AppKit
import ImageIO
import QuickLook
import SwiftUI

/// Pure geometry (unit-tested).
enum ScreenshotGeometry {
    /// Points per image pixel when the image is fitted to `viewWidth` at `zoom`.
    static func scale(imagePixelWidth: CGFloat, viewWidth: CGFloat, zoom: CGFloat) -> CGFloat {
        guard imagePixelWidth > 0 else { return 1 }
        return max(0.01, viewWidth * zoom / imagePixelWidth)
    }

    /// The visible window drawn on the minimap, in minimap coordinates.
    static func viewport(contentOffsetY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat, minimapHeight: CGFloat) -> (y: CGFloat, height: CGFloat) {
        guard contentHeight > 0 else { return (0, minimapHeight) }
        let ratio = minimapHeight / contentHeight
        let height = min(minimapHeight, visibleHeight * ratio)
        let y = min(max(0, contentOffsetY * ratio), max(0, minimapHeight - height))
        return (y, height)
    }

    /// Content offset that centers the viewport on minimap point `y`.
    static func contentOffset(forMinimapY y: CGFloat, minimapHeight: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        guard minimapHeight > 0 else { return 0 }
        let target = y / minimapHeight * contentHeight - visibleHeight / 2
        return clamp(target, contentHeight: contentHeight, visibleHeight: visibleHeight)
    }

    /// Content offset that centers a field's bbox (image pixels) in the visible area.
    static func scrollTarget(for bbox: CGRect, scale: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        let mid = bbox.midY * scale
        return clamp(mid - visibleHeight / 2, contentHeight: contentHeight, visibleHeight: visibleHeight)
    }

    /// bbox (image pixels) → rect in the displayed image (points).
    static func displayRect(for bbox: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: bbox.minX * scale, y: bbox.minY * scale, width: bbox.width * scale, height: bbox.height * scale)
    }

    static func clamp(_ y: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        min(max(0, y), max(0, contentHeight - visibleHeight))
    }

    static let zoomSteps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    static func zoom(_ current: CGFloat, step: Int) -> CGFloat {
        let index = zoomSteps.firstIndex { $0 >= current - 0.001 } ?? 2
        return zoomSteps[min(zoomSteps.count - 1, max(0, index + step))]
    }
}

/// A decoded image that can cross actors.
struct LoadedScreenshot: @unchecked Sendable {
    let image: CGImage
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// Off-main decode + NSCache (thumbnails and full-res kept separately).
final class ScreenshotCache: @unchecked Sendable {
    static let shared = ScreenshotCache()
    private let cache = NSCache<NSString, CGImageBox>()

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    init() { cache.countLimit = 64 }

    func load(path: String, maxPixel: Int?) async -> LoadedScreenshot? {
        let key = "\(path)#\(maxPixel ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return LoadedScreenshot(image: hit.image) }
        let decoded: LoadedScreenshot? = await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
            if let maxPixel {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(LoadedScreenshot.init)
            }
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary).map(LoadedScreenshot.init)
        }.value
        if let decoded { cache.setObject(CGImageBox(decoded.image), forKey: key) }
        return decoded
    }
}

struct ScreenshotViewer: View {
    var shots: [JobDetailRules.Shot]
    /// Q&A row hovered in the audit table (highlights its bbox on the pre-submit shot).
    var highlighted: ApplicationAnswerItem?

    @State private var selectedPath: String?
    @State private var full: LoadedScreenshot?
    @State private var minimap: LoadedScreenshot?
    @State private var loadFailed = false
    @State private var zoom: CGFloat = 1
    @State private var position = ScrollPosition()
    @State private var scrollGeometry: ScrollGeometry?
    @State private var quickLookURL: URL?
    @Environment(\.motionReduced) private var reduced

    static let minimapWidth: CGFloat = 64

    private var selected: JobDetailRules.Shot? {
        shots.first { $0.path == selectedPath } ?? shots.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            toolbar
            if shots.isEmpty {
                EmptyState(symbol: "photo.on.rectangle", title: "No screenshot yet",
                           message: "The agent records a full-page screenshot before every submit.")
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else if loadFailed {
                EmptyState(symbol: "photo.badge.exclamationmark", title: "Screenshot not available",
                           message: "\(selected?.path ?? "") couldn't be read.")
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else if let full {
                viewer(full)
            } else {
                SkeletonBlock(lines: 6, lineHeight: 28).frame(maxWidth: .infinity, minHeight: 260).padding(Space.l)
            }
            if shots.count > 1 { filmstrip }
        }
        .task(id: selected?.path) { await load() }
        .onChange(of: highlighted?.id) { scrollToHighlight() }
        .quickLookPreview($quickLookURL)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            openQuickLook()
            return .handled
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Space.s) {
            Text(selected?.label ?? "Submitted page").eyebrowStyle()
            Spacer()
            Button { zoom = ScreenshotGeometry.zoom(zoom, step: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")
                .disabled(full == nil)
            Text("\(Int((zoom * 100).rounded()))%").font(Typography.monoSmall).frame(width: 40)
            Button { zoom = ScreenshotGeometry.zoom(zoom, step: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: .command)
                .help("Zoom in (⌘+)")
                .disabled(full == nil)
            Button { openQuickLook() } label: { Label("Quick Look", systemImage: "eye") }
                .help("Quick Look (Space)")
                .disabled(full == nil)
        }
        .buttonStyle(.borderless)
    }

    // MARK: Viewer

    private func viewer(_ image: LoadedScreenshot) -> some View {
        GeometryReader { proxy in
            let viewWidth = max(1, proxy.size.width - Self.minimapWidth - Space.s)
            let scale = ScreenshotGeometry.scale(imagePixelWidth: image.pixelSize.width, viewWidth: viewWidth, zoom: zoom)
            let size = CGSize(width: image.pixelSize.width * scale, height: image.pixelSize.height * scale)
            HStack(alignment: .top, spacing: Space.s) {
                ScrollView([.vertical, .horizontal]) {
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .overlay(alignment: .topLeading) { highlight(scale: scale) }
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in scrollGeometry = new }
                .background(Palette.sunken)
                .clipShape(.thumb)
                .accessibilityLabel("Full-page screenshot, \(selected?.label ?? "")")
                minimapView(contentHeight: size.height, visibleHeight: proxy.size.height)
            }
        }
        .frame(minHeight: 320, idealHeight: 520)
    }

    @ViewBuilder
    private func highlight(scale: CGFloat) -> some View {
        if let bbox = highlighted?.bbox, selected?.path == shots.first?.path {
            let rect = ScreenshotGeometry.displayRect(for: bbox, scale: scale)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Palette.accent, lineWidth: 2)
                .background(Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(width: rect.width + 8, height: rect.height + 8)
                .offset(x: rect.minX - 4, y: rect.minY - 4)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func minimapView(contentHeight: CGFloat, visibleHeight: CGFloat) -> some View {
        GeometryReader { geo in
            let thumb = minimap ?? full
            let aspect = thumb.map { $0.pixelSize.height / max(1, $0.pixelSize.width) } ?? 3
            let mapHeight = min(geo.size.height, Self.minimapWidth * aspect)
            let offset = scrollGeometry?.contentOffset.y ?? 0
            let vp = ScreenshotGeometry.viewport(contentOffsetY: offset, visibleHeight: visibleHeight,
                                                 contentHeight: contentHeight, minimapHeight: mapHeight)
            ZStack(alignment: .topLeading) {
                if let thumb {
                    Image(decorative: thumb.image, scale: 1).resizable()
                        .frame(width: Self.minimapWidth, height: mapHeight)
                        .opacity(0.85)
                }
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Palette.accent, lineWidth: 1.5)
                    .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    .frame(width: Self.minimapWidth, height: max(8, vp.height))
                    .offset(y: vp.y)
            }
            .frame(width: Self.minimapWidth, height: mapHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let y = ScreenshotGeometry.contentOffset(forMinimapY: value.location.y, minimapHeight: mapHeight,
                                                         contentHeight: contentHeight, visibleHeight: visibleHeight)
                position.scrollTo(y: y)
            })
            .accessibilityElement()
            .accessibilityLabel("Screenshot minimap")
            .accessibilityValue("\(Int(contentHeight > 0 ? (offset / contentHeight * 100) : 0)) percent scrolled")
            .accessibilityAdjustableAction { direction in
                let delta = (direction == .increment ? 1 : -1) * visibleHeight * 0.8
                position.scrollTo(y: ScreenshotGeometry.clamp(offset + delta, contentHeight: contentHeight, visibleHeight: visibleHeight))
            }
        }
        .frame(width: Self.minimapWidth)
    }

    private var filmstrip: some View {
        HStack(spacing: Space.s) {
            ForEach(shots) { shot in
                Button { selectedPath = shot.path } label: {
                    VStack(spacing: 2) {
                        FilmstripThumb(path: shot.path)
                            .frame(width: 72, height: 48)
                            .clipShape(.thumb)
                            .overlay(RoundedRectangle(cornerRadius: Radius.thumb).stroke(selected?.path == shot.path ? Palette.accent : Palette.hairline,
                                                                                    lineWidth: selected?.path == shot.path ? 2 : 0.5))
                        Text(shot.label).font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shot.label)
                .accessibilityAddTraits(selected?.path == shot.path ? .isSelected : [])
            }
        }
    }

    // MARK: Actions

    private func load() async {
        full = nil
        minimap = nil
        loadFailed = false
        guard let path = selected?.path else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            loadFailed = true
            return
        }
        async let thumb = ScreenshotCache.shared.load(path: path, maxPixel: 640)
        async let image = ScreenshotCache.shared.load(path: path, maxPixel: nil)
        minimap = await thumb
        full = await image
        loadFailed = full == nil
    }

    private func scrollToHighlight() {
        guard let bbox = highlighted?.bbox, let full, let geo = scrollGeometry, selected?.path == shots.first?.path else { return }
        let scale = geo.contentSize.width / max(1, full.pixelSize.width)
        let y = ScreenshotGeometry.scrollTarget(for: bbox, scale: scale, visibleHeight: geo.containerSize.height,
                                                contentHeight: geo.contentSize.height)
        withMotion(Motion.snappy, reduceMotion: reduced) { position.scrollTo(y: y) }
    }

    private func openQuickLook() {
        guard let path = selected?.path, FileManager.default.fileExists(atPath: path) else { return }
        quickLookURL = URL(fileURLWithPath: path)
    }
}

private struct FilmstripThumb: View {
    var path: String
    @State private var image: LoadedScreenshot?

    var body: some View {
        ZStack {
            Palette.sunken
            if let image {
                Image(decorative: image.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(Palette.textTertiary)
            }
        }
        .task(id: path) {
            guard FileManager.default.fileExists(atPath: path) else { return }
            image = await ScreenshotCache.shared.load(path: path, maxPixel: 240)
        }
    }
}
