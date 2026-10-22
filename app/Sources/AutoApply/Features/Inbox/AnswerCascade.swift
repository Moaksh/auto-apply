// AnswerCascade.swift — "One answer, many doors" (docs/DESIGN_AWARD_VISION.md §3.2, 1D). The
// composer shows who's waiting as a row of company monograms. When an answer sends several jobs
// back to the queue, the monograms fly one by one (30 ms stagger, at most 8, the rest as a "+N"
// chip) along an arc into the sidebar's Pipeline row, whose badge counts them in and pulses once.
// The toast says "Answered · 6 jobs back in the queue" with a ring draining over the Undo window;
// Undo takes the badge back. Under Reduce Motion nothing flies: the badge fades in with the count.
//
// The flight crosses the split view, so it's drawn in a borderless, click-through child window
// over the main window for about a second. Its start and end points come from zero-size AppKit
// probes (`CascadeAnchor`) placed on the monograms and on the Pipeline row, read once when the
// answer is sent: nothing here writes view state from geometry.
import AppKit
import SwiftUI

/// One cascade: which jobs fly, how many there are, and how many have landed on Pipeline.
struct AnswerCascade: Identifiable, Equatable, Sendable {
    struct Flyer: Identifiable, Equatable, Sendable {
        /// The job's id (negative placeholders when only company names are known).
        var id: Int
        var company: String
    }

    /// Monograms animated one by one; the rest fly together as a "+N" chip.
    static let maxFlyers = 8
    /// An answer has to unblock at least this many jobs to cascade (one job just gets the toast).
    static let minimumJobs = 2
    /// The sidebar Pipeline row's probe.
    static let targetKey = "cascade.pipeline"

    var id: Int
    var clusterID: String
    var jobCount: Int
    var flyers: [Flyer]
    var landedJobs = 0
    /// False when the answer also emptied Needs You (inbox zero plays its own haptic).
    var hapticOnLanding = true

    init(id: Int, clusterID: String, jobCount: Int, flyers: [Flyer], landedJobs: Int = 0, hapticOnLanding: Bool = true) {
        self.id = id
        self.clusterID = clusterID
        self.jobCount = jobCount
        self.flyers = flyers
        self.landedJobs = landedJobs
        self.hapticOnLanding = hapticOnLanding
    }

    /// Jobs beyond the animated monograms ("+6").
    var overflow: Int { max(0, jobCount - flyers.count) }

    var isLanded: Bool { landedJobs >= jobCount }

    /// Each flyer's launch delay: 30 ms apart, at most 8 staggered.
    static func delay(index: Int) -> Double { Motion.staggerDelay(index: index, maxStaggered: maxFlyers) }

    /// How long one flyer takes to land (the `.flow` spring, settled).
    static let flightDuration: Double = 0.62

    static func monogramKey(cluster: String, job: Int) -> String { "cascade.monogram.\(cluster).\(job)" }
    static func overflowKey(cluster: String) -> String { "cascade.overflow.\(cluster)" }
    /// The pane a cascade starts from when no single monogram is on screen (a task's pane).
    static func sourceKey(cluster: String) -> String { "cascade.source.\(cluster)" }
}

// MARK: - Probes

/// A zero-size, click-through AppKit view marking where something is on screen, read once when a
/// cascade launches. Registering writes no SwiftUI state.
struct CascadeAnchor: NSViewRepresentable {
    var key: String

    func makeNSView(context: Context) -> CascadeProbeView {
        let view = CascadeProbeView()
        view.key = key
        CascadeAnchors.register(view)
        return view
    }

    func updateNSView(_ view: CascadeProbeView, context: Context) {
        guard view.key != key else { return }
        view.key = key
        CascadeAnchors.register(view)
    }
}

final class CascadeProbeView: NSView {
    var key = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// Where the probes are. Weak: a probe that left the window is simply gone.
@MainActor
enum CascadeAnchors {
    private final class Weak { weak var view: CascadeProbeView?; init(_ v: CascadeProbeView) { view = v } }
    private static var probes: [Weak] = []

    static func register(_ view: CascadeProbeView) {
        probes.removeAll { $0.view == nil || $0.view === view }
        probes.append(Weak(view))
    }

    /// The probe's frame in its window's coordinates, if it's on screen in `window` (any window
    /// when nil) and not hidden.
    static func frame(_ key: String, in window: NSWindow? = nil) -> (rect: CGRect, window: NSWindow)? {
        probes.removeAll { $0.view == nil }
        for probe in probes.reversed() {
            guard let view = probe.view, view.key == key, let w = view.window, w.isVisible,
                  window == nil || w === window, !view.isHiddenOrHasHiddenAncestor else { continue }
            let rect = view.convert(view.bounds, to: nil)
            // A collapsed sidebar column sits outside the window: nothing to fly to.
            guard !rect.isEmpty, let content = w.contentView, content.frame.intersects(rect) else { continue }
            return (rect, w)
        }
        return nil
    }
}

// MARK: - Flight

/// Launches the flight overlay, or lands the cascade at once when there's nothing to fly
/// (Reduce Motion, the sidebar hidden, the composer in another window, tests).
@MainActor
enum CascadeFlight {
    struct Item: Identifiable, Equatable {
        var id: Int
        var company: String?    // nil: the "+N" chip
        var overflow: Int
        var from: CGRect        // top-left coordinates in the overlay
        var size: CGFloat
    }

    struct Plan {
        var items: [Item]
        var target: CGPoint
        var window: NSWindow
    }

    private static var panel: NSPanel?
    private static var closeTask: Task<Void, Never>?

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: DebugSettings.simulateReduceMotionKey)
    }

    static func launch(_ cascade: AnswerCascade, model: InboxModel) {
        guard !reduceMotion, let plan = plan(for: cascade) else {
            model.landCascade(id: cascade.id, jobs: cascade.jobCount)
            return
        }
        present(plan)
        // Each monogram counts one job in as it lands; the "+N" chip brings the rest.
        for (i, item) in plan.items.enumerated() {
            let at = AnswerCascade.delay(index: i) + AnswerCascade.flightDuration
            let jobs = item.company == nil ? item.overflow : 1
            Task { @MainActor [weak model] in
                try? await Task.sleep(for: .milliseconds(Int(at * 1000)))
                model?.landCascade(id: cascade.id, jobs: jobs)
            }
        }
        // Whatever didn't get a monogram (no source on screen) lands with the last one.
        let flown = plan.items.reduce(0) { $0 + ($1.company == nil ? $1.overflow : 1) }
        if flown < cascade.jobCount {
            let at = AnswerCascade.delay(index: plan.items.count) + AnswerCascade.flightDuration
            Task { @MainActor [weak model] in
                try? await Task.sleep(for: .milliseconds(Int(at * 1000)))
                model?.landCascade(id: cascade.id, jobs: cascade.jobCount - flown)
            }
        }
    }

    /// Where each monogram starts and where they all land, in the overlay's coordinates.
    static func plan(for cascade: AnswerCascade) -> Plan? {
        guard let target = CascadeAnchors.frame(AnswerCascade.targetKey) else { return nil }
        let window = target.window
        let height = window.frame.height
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
        let fallback = CascadeAnchors.frame(AnswerCascade.sourceKey(cluster: cascade.clusterID), in: window).map { local($0.rect) }
        var items: [Item] = []
        for (i, flyer) in cascade.flyers.enumerated() {
            let size: CGFloat = 22
            let from: CGRect
            if let probe = CascadeAnchors.frame(AnswerCascade.monogramKey(cluster: cascade.clusterID, job: flyer.id), in: window) {
                from = local(probe.rect)
            } else if let fallback {
                from = CGRect(x: fallback.minX + CGFloat(i) * 18, y: fallback.minY, width: size, height: size)
            } else {
                continue
            }
            items.append(Item(id: flyer.id, company: flyer.company, overflow: 0, from: from, size: size))
        }
        guard !items.isEmpty else { return nil }
        if cascade.overflow > 0 {
            let chip = CascadeAnchors.frame(AnswerCascade.overflowKey(cluster: cascade.clusterID), in: window).map { local($0.rect) }
                ?? items[items.count - 1].from.offsetBy(dx: 22, dy: 0)
            items.append(Item(id: Int.min, company: nil, overflow: cascade.overflow, from: chip, size: 22))
        }
        let t = local(target.rect)
        return Plan(items: items, target: CGPoint(x: t.midX, y: t.midY), window: window)
    }

    private static func present(_ plan: Plan) {
        dismiss()
        let window = plan.window
        let overlay = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        overlay.appearance = window.effectiveAppearance
        let host = NSHostingView(rootView: CascadeFlightView(items: plan.items, target: plan.target))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        overlay.contentView = host
        window.addChildWindow(overlay, ordered: .above)
        panel = overlay
        let total = AnswerCascade.delay(index: plan.items.count) + AnswerCascade.flightDuration + 0.2
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(total * 1000)))
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
}

/// The monograms in flight: each lifts off its spot in the composer and follows an arc into the
/// Pipeline row, shrinking and fading as it lands. It launches on appear; `progress` pins a pose (render tests).
struct CascadeFlightView: View {
    var items: [CascadeFlight.Item]
    var target: CGPoint
    @State private var launched = false
    var progress: Double?

    init(items: [CascadeFlight.Item], target: CGPoint, progress: Double? = nil) {
        self.items = items
        self.target = target
        self.progress = progress
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Group {
                    if let company = item.company {
                        CompanyMonogram(name: company, size: item.size)
                    } else {
                        OverflowChip(count: item.overflow)
                    }
                }
                .modifier(ArcFlight(from: CGPoint(x: item.from.midX, y: item.from.midY), to: target, progress: progress ?? (launched ? 1 : 0)))
                .animation(Motion.flow.delay(AnswerCascade.delay(index: i)), value: launched)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if progress == nil { launched = true } }
    }
}

/// Position along a quadratic arc that rises above both ends, shrinking to 55% and fading out
/// over the last stretch.
struct ArcFlight: ViewModifier, Animatable {
    var from: CGPoint
    var to: CGPoint
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static func point(from: CGPoint, to: CGPoint, progress: Double) -> CGPoint {
        let t = min(1, max(0, progress))
        let lift = max(60, abs(to.x - from.x) * 0.25)
        let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - lift)
        let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
        return CGPoint(x: a * from.x + b * control.x + c * to.x, y: a * from.y + b * control.y + c * to.y)
    }

    func body(content: Content) -> some View {
        let t = min(1, max(0, progress))
        content
            .scaleEffect(1 - 0.45 * t)
            .opacity(t < 0.8 ? 1 : max(0, (1 - t) / 0.2))
            .position(Self.point(from: from, to: to, progress: t))
    }
}

/// "+6": the jobs beyond the animated monograms.
struct OverflowChip: View {
    var count: Int

    var body: some View {
        Text("+\(count)")
            .font(Typography.monoSmall)
            .monospacedDigit()
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 22)
            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: Radius.logo * 22 / 20, style: .continuous))
    }
}

// MARK: - Who's waiting

/// "6 jobs are waiting on this answer", with their monograms (the cascade flies these).
struct WaitingMonogramRow: View {
    var model: InboxModel
    var cluster: QuestionCluster

    var body: some View {
        let (flyers, overflow) = model.waitingFlyers(for: cluster)
        if cluster.jobCount > 0 {
            HStack(spacing: Space.s) {
                HStack(spacing: -4) {
                    ForEach(flyers) { flyer in
                        CompanyMonogram(name: flyer.company, size: 22)
                            .overlay(RoundedRectangle(cornerRadius: Radius.logo * 22 / 20, style: .continuous)
                                .stroke(Palette.windowBackground, lineWidth: 1.5))
                            .background(CascadeAnchor(key: AnswerCascade.monogramKey(cluster: cluster.clusterId, job: flyer.id)))
                    }
                    if overflow > 0 {
                        OverflowChip(count: overflow)
                            .background(CascadeAnchor(key: AnswerCascade.overflowKey(cluster: cluster.clusterId)))
                            .padding(.leading, Space.xs)
                    }
                }
                Text(Self.caption(cluster.jobCount, task: cluster.isAction))
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            .background(CascadeAnchor(key: AnswerCascade.sourceKey(cluster: cluster.clusterId)), alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.caption(cluster.jobCount, task: cluster.isAction)): \(flyers.map(\.company).joined(separator: ", "))\(overflow > 0 ? " and \(overflow) more" : "")")
        }
    }

    static func caption(_ jobs: Int, task: Bool = false) -> String {
        let what = task ? "this" : "this answer"
        return jobs == 1 ? "1 job is waiting on \(what)" : "\(jobs) jobs are waiting on \(what)"
    }
}

// MARK: - Pipeline badge

/// The sidebar Pipeline row's part of the cascade: "+6" counting in as the monograms land, shown
/// while the answer can still be undone. Undo takes it away.
struct PipelineCascadeBadge: View {
    var model: InboxModel
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        let landed = model.cascade?.landedJobs ?? 0
        ZStack {
            if landed > 0 {
                Text("+\(landed)")
                    .font(Typography.monoSmall)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(landed)))
                    .foregroundStyle(Palette.applied)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Palette.applied.opacity(0.14), in: Capsule())
                    .keyframeAnimator(initialValue: 1.0, trigger: reduced ? 0 : model.cascadePulse) { view, scale in
                        view.scaleEffect(scale)
                    } keyframes: { _ in
                        KeyframeTrack {
                            SpringKeyframe(1.18, duration: 0.16)
                            SpringKeyframe(1.0, duration: 0.3)
                        }
                    }
                    .transition(.opacity)
                    .help("\(C3Format.plural(landed, "job")) back in the queue")
                    .accessibilityLabel("\(C3Format.plural(landed, "job")) back in the queue")
            }
        }
        .animation(Motion.resolve(Motion.numeric, reduceMotion: reduced), value: landed)
    }
}

#Preview("Cascade flight") {
    CascadeFlightView(items: [
        .init(id: 1, company: "Stripe", overflow: 0, from: CGRect(x: 420, y: 300, width: 22, height: 22), size: 22),
        .init(id: 2, company: "Ramp", overflow: 0, from: CGRect(x: 438, y: 300, width: 22, height: 22), size: 22),
        .init(id: Int.min, company: nil, overflow: 6, from: CGRect(x: 460, y: 300, width: 22, height: 22), size: 22),
    ], target: CGPoint(x: 80, y: 120), progress: 0.4)
    .frame(width: 700, height: 420)
}
