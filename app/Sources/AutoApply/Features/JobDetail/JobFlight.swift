// JobFlight.swift — the Pipeline card → Job detail flight (docs/DESIGN_AWARD_VISION.md §6.3 #1).
// Opening a job from the Pipeline board or table in the same window flies its company monogram
// from the card into Job detail's header (`Motion.flight`), while the detail screen rises in
// (`screenArrival`). It says "this is the same job, now up close".
//
// Why not `matchedGeometryEffect`: the card and the header live in different NavigationStack
// destinations (and the table is NSTableView-backed), so SwiftUI can't pair them. Like the
// answer cascade, the flight is drawn in a borderless, click-through child window for about half
// a second; its ends come from the cascade's zero-cost AppKit probes (`CascadeAnchor`), read once
// when the job opens and once when the header appears. Nothing here writes view state from
// geometry. Reduce Motion, a job opened in its own window, or a missing probe: no flight.
import AppKit
import SwiftUI

@MainActor
enum JobFlight {
    /// The probe on a Pipeline card's (or table row's) monogram / company.
    static func sourceKey(_ jobID: Int) -> String { "jobflight.source.\(jobID)" }
    /// The probe on Job detail's header monogram.
    static func targetKey(_ jobID: Int) -> String { "jobflight.target.\(jobID)" }

    /// How long a flight takes (the `flight` spring, settled).
    static let duration: Double = 0.5

    struct Pending {
        var jobID: Int
        var from: CGRect
        var window: NSWindow
        var at: Date
    }

    private(set) static var pending: Pending?
    private static var panel: NSPanel?
    private static var closeTask: Task<Void, Never>?

    /// A source calls this just before opening the job in the detail column.
    static func prepare(jobID: Int) {
        pending = nil
        guard !CascadeFlight.reduceMotion, let source = CascadeAnchors.frame(sourceKey(jobID)) else { return }
        pending = Pending(jobID: jobID, from: source.rect, window: source.window, at: Date())
    }

    /// Job detail's header calls this when it appears: fly if this job was just opened from a card.
    static func land(jobID: Int, company: String) {
        guard let p = pending, p.jobID == jobID, Date().timeIntervalSince(p.at) < 1 else { return }
        pending = nil
        Task { @MainActor in
            // One frame for the pushed screen to lay out before reading where the header is.
            try? await Task.sleep(for: .milliseconds(16))
            guard let target = CascadeAnchors.frame(targetKey(jobID), in: p.window) else { return }
            present(company: company, from: p.from, to: target.rect, window: p.window)
        }
    }

    private static func present(company: String, from: CGRect, to: CGRect, window: NSWindow) {
        dismiss()
        let height = window.frame.height
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
        let overlay = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        overlay.appearance = window.effectiveAppearance
        let host = NSHostingView(rootView: JobFlightView(company: company, from: local(from), to: local(to)))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        overlay.contentView = host
        window.addChildWindow(overlay, ordered: .above)
        panel = overlay
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int((duration + 0.08) * 1000)))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private static func dismiss() {
        closeTask?.cancel()
        closeTask = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    /// Where the monogram starts: a square on the source's leading edge (a card's monogram is
    /// already square; a table row's company cell gives its leading square).
    static func startSquare(for source: CGRect) -> CGRect {
        let side = min(source.width, source.height, 22)
        return CGRect(x: source.minX, y: source.midY - side / 2, width: side, height: side)
    }
}

/// The monogram in flight: from the card's square to the header's, growing on the way. It lands
/// exactly on the real monogram, so closing the overlay is seamless. `progress` pins a pose (tests).
struct JobFlightView: View {
    var company: String
    var from: CGRect
    var to: CGRect
    var progress: Double?
    @State private var launched = false

    var body: some View {
        let start = JobFlight.startSquare(for: from)
        let t = progress ?? (launched ? 1 : 0)
        ZStack(alignment: .topLeading) {
            Color.clear
            CompanyMonogram(name: company, size: to.width)
                .modifier(FlightPose(from: start, to: to, progress: t))
                .animation(Motion.flight, value: launched)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if progress == nil { launched = true } }
    }
}

/// Interpolates a square's centre and size; animatable so the spring drives it.
private struct FlightPose: ViewModifier, Animatable {
    var from: CGRect
    var to: CGRect
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = CGFloat(progress)
        let x = from.midX + (to.midX - from.midX) * t
        let y = from.midY + (to.midY - from.midY) * t
        let scale = (from.width + (to.width - from.width) * t) / max(1, to.width)
        content
            .scaleEffect(scale)
            .position(x: x, y: y)
    }
}
