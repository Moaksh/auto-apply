// PipelineFlowView.swift — the hero's live pipeline (§4.3 W2b, §8.4 "Live viz core"):
// Discovered → Scored → Queued → Filling → Submitted with skipped / needs-you branches, drawn
// in ONE Canvas inside a TimelineView. Particles are not state: positions are derived from
// (transition.start, now), so redraws are stateless. Counts are real Text views overlaid at the
// node positions (numericText + accessibility).
//
// On the Dashboard's brand field (`onBrand`) it glows: while the agent works, light streams
// along the edges the jobs travel (ambient flow), the stage in hand pulses, and real transitions
// fly as haloed particles. Redraws are capped at 30 fps and stop when the agent is idle, the
// window is hidden, or Reduce Motion is on (then it's a static, lit diagram).
import SwiftUI

/// Pure geometry for the flow (unit-tested). All points are in the view's coordinate space.
struct FlowGeometry: Sendable, Equatable {
    var size: CGSize

    static let travelDuration: TimeInterval = 0.7
    static let nodeRadius: CGFloat = 5
    static let particleRadius: CGFloat = 1.5

    /// Horizontal inset so labels at the ends aren't clipped.
    var inset: CGFloat { min(56, size.width * 0.08) }
    var railY: CGFloat { size.height * 0.42 }
    var branchY: CGFloat { size.height * 0.86 }

    var spacing: CGFloat {
        let usable = max(1, size.width - inset * 2)
        return usable / CGFloat(FlowStage.main.count - 1)
    }

    /// Position of a main node; branch stages hang below their parent.
    func node(_ stage: FlowStage) -> CGPoint {
        if let i = FlowStage.main.firstIndex(of: stage) {
            return CGPoint(x: inset + CGFloat(i) * spacing, y: railY)
        }
        return branchEnd(stage)
    }

    /// Main stage a branch peels off from.
    static func branchParent(_ stage: FlowStage) -> FlowStage {
        switch stage {
        case .skipped: .scored
        case .needsYou, .failed: .filling
        default: stage
        }
    }

    func branchEnd(_ stage: FlowStage) -> CGPoint {
        let parent = node(Self.branchParent(stage))
        let dx: CGFloat = stage == .failed ? spacing * 0.55 : spacing * 0.42
        return CGPoint(x: parent.x + dx, y: branchY)
    }

    /// Where a particle sits `progress` (0…1, already eased) along `from → to`.
    /// `from == nil` means the job just appeared: it drifts into Discovered from the left.
    func point(from: FlowStage?, to: FlowStage, progress: Double) -> CGPoint {
        let t = CGFloat(min(1, max(0, progress)))
        let end = node(to)
        guard let from else {
            let start = CGPoint(x: end.x - min(inset, spacing * 0.5), y: end.y)
            return lerp(start, end, t)
        }
        let isBranchTarget = !FlowStage.main.contains(to)
        if isBranchTarget {
            // Curve down from the parent node (quadratic Bézier, control point under the start).
            let start = node(from == to ? Self.branchParent(to) : from)
            let control = CGPoint(x: start.x + (end.x - start.x) * 0.15, y: end.y)
            return quad(start, control, end, t)
        }
        let start = FlowStage.main.contains(from) ? node(from) : branchEnd(from)
        if !FlowStage.main.contains(from) {
            // Back from a branch (needs you → queued): curve up.
            let control = CGPoint(x: start.x, y: end.y)
            return quad(start, control, end, t)
        }
        return lerp(start, end, t)
    }

    /// Eased progress of a transition at `now` (nil once it has arrived + faded).
    static func progress(of transition: StageTransition, at now: Date) -> Double? {
        let elapsed = now.timeIntervalSince(transition.start)
        guard elapsed >= 0 else { return 0 }
        guard elapsed <= travelDuration + 0.25 else { return nil }
        return Motion.flowEase(elapsed / travelDuration)
    }

    /// Particle opacity: fades in over the first 10%, fades out after arrival.
    static func opacity(of transition: StageTransition, at now: Date) -> Double {
        let elapsed = now.timeIntervalSince(transition.start)
        if elapsed < 0.07 { return max(0, elapsed / 0.07) }
        if elapsed <= travelDuration { return 1 }
        return max(0, 1 - (elapsed - travelDuration) / 0.25)
    }

    /// Ambient flow along a main edge while the agent works: `perEdge` evenly spaced dots
    /// travelling left → right once every `period` seconds, fading in and out at the ends.
    /// Returns (progress along the edge 0…1, opacity 0…1). Pure, so tests can pin it.
    static func ambientDots(edge: Int, at t: TimeInterval, perEdge: Int = 3, period: Double = 2.2) -> [(progress: Double, opacity: Double)] {
        guard perEdge > 0, period > 0 else { return [] }
        return (0..<perEdge).map { k in
            let raw = t / period + Double(k) / Double(perEdge) + Double(edge) * 0.17
            let p = raw - floor(raw)
            return (p, sin(p * .pi))
        }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

/// VoiceOver text for the flow (§7): one element per stage plus a summary.
enum FlowAccessibility {
    static func summary(verb: String, counts: RunStats, filling: Int, isRunning: Bool) -> String {
        let prefix = isRunning ? "Agent \(verb.lowercased()). Current run" : "Last run"
        return "\(prefix): \(counts.discovered) discovered, \(counts.scored) scored, \(counts.queued) queued, "
            + "\(filling) filling, \(counts.submitted) applied"
    }

    static func stage(_ stage: FlowStage, counts: RunStats, filling: Int, threshold: Int) -> String {
        let n = count(stage, counts, filling: filling)
        var s = "\(stage.title), \(n) job\(n == 1 ? "" : "s")"
        if stage == .scored, counts.skipped > 0 { s += ", \(counts.skipped) skipped below threshold \(threshold)" }
        if stage == .filling, counts.needsYou > 0 { s += ", \(counts.needsYou) need you" }
        return s
    }

    /// `filling` is the application in hand (0 or 1): RunStats has no live "filling" counter.
    static func count(_ stage: FlowStage, _ c: RunStats, filling: Int) -> Int {
        switch stage {
        case .discovered: c.discovered
        case .scored: c.scored
        case .queued: c.queued
        case .filling: filling
        case .submitted: c.submitted
        case .skipped: c.skipped
        case .needsYou: c.needsYou
        case .failed: c.failed
        }
    }
}

struct PipelineFlowView: View {
    var snapshot: FlowSnapshot
    var isRunning: Bool
    /// Last-run totals render greyed out when idle.
    var isIdle: Bool
    var isSkeleton: Bool = false
    var threshold: Int = 70
    var verb: String = "Idle"
    var isVisible: Bool = true
    /// Drawn on the Dashboard's brand field: glowing rails, ambient flow, pulsing focus.
    var onBrand: Bool = false
    /// The stage the agent is working on (glows while running).
    var focus: FlowStage? = nil
    var onSelectStage: (FlowStage) -> Void = { _ in }
    var jobsAtStage: (FlowStage) -> [JobItem] = { _ in [] }

    @Environment(\.motionReduced) private var reduced
    @Environment(\.dashboardCountUp) private var countUp
    @State private var hoveredStage: FlowStage?

    private var fillingCount: Int { snapshot.activeJobID != nil && isRunning ? 1 : 0 }

    var body: some View {
        GeometryReader { proxy in
            let geo = FlowGeometry(size: proxy.size)
            ZStack(alignment: .topLeading) {
                canvas(geo)
                labels(geo)
            }
        }
        .frame(minHeight: 120)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FlowAccessibility.summary(verb: verb, counts: snapshot.counts, filling: fillingCount, isRunning: isRunning))
    }

    // MARK: Canvas

    private func canvas(_ geo: FlowGeometry) -> some View {
        let animate = isRunning && isVisible && !reduced && !isSkeleton
        return TimelineView(.animation(minimumInterval: 1 / HeroFrameRate.flow, paused: !animate)) { timeline in
            Canvas(rendersAsynchronously: false) { ctx, _ in
                if onBrand && !isSkeleton { drawFocusGlow(&ctx, geo, now: timeline.date, animate: animate) }
                drawRails(&ctx, geo)
                if isSkeleton { return }
                if onBrand && animate { drawAmbientFlow(&ctx, geo, now: timeline.date) }
                if !reduced { drawParticles(&ctx, geo, now: timeline.date) }
                drawActiveOrb(&ctx, geo, now: timeline.date, animate: animate)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static let glow = Palette.Brand.signal

    /// Index of the furthest main stage the current run has reached (lit rail up to it).
    private var litIndex: Int {
        let c = snapshot.counts
        if c.submitted > 0 { return 4 }
        if fillingCount > 0 { return 3 }
        if c.queued > 0 { return 2 }
        if c.scored > 0 { return 1 }
        return 0
    }

    /// A soft pulse of light under the stage the agent is working on.
    private func drawFocusGlow(_ ctx: inout GraphicsContext, _ geo: FlowGeometry, now: Date, animate: Bool) {
        guard isRunning, let focus else { return }
        let p = geo.node(focus)
        let phase = animate ? HeroBreathCurve.phase(at: now.timeIntervalSinceReferenceDate, period: 2) : 0.5
        let r = 46 + CGFloat(phase) * 10
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.fill(Circle().path(in: rect),
                 with: .radialGradient(Gradient(colors: [Self.glow.opacity(0.20 + 0.14 * phase), Self.glow.opacity(0)]),
                                       center: p, startRadius: 0, endRadius: r))
    }

    /// Light travelling along the edges jobs move through this run.
    private func drawAmbientFlow(_ ctx: inout GraphicsContext, _ geo: FlowGeometry, now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        let lit = max(litIndex, FlowStage.main.firstIndex(of: focus ?? .discovered) ?? 0)
        guard lit > 0 else { return }
        ctx.blendMode = .plusLighter
        for edge in 0..<lit {
            let a = geo.node(FlowStage.main[edge]), b = geo.node(FlowStage.main[edge + 1])
            for dot in FlowGeometry.ambientDots(edge: edge, at: t) {
                let p = CGPoint(x: a.x + (b.x - a.x) * dot.progress, y: a.y + (b.y - a.y) * dot.progress)
                let halo: CGFloat = 5, core: CGFloat = 1.6
                ctx.fill(Circle().path(in: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                         with: .color(Self.glow.opacity(0.16 * dot.opacity)))
                ctx.fill(Circle().path(in: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)),
                         with: .color(Self.glow.opacity(0.85 * dot.opacity)))
            }
        }
        ctx.blendMode = .normal
    }

    private func drawRails(_ ctx: inout GraphicsContext, _ geo: FlowGeometry) {
        let rail = onBrand ? Color.white.opacity(0.10) : Palette.hairline
        let strong = onBrand ? Color.white.opacity(0.22) : Palette.strokeStrong
        var main = Path()
        for (i, stage) in FlowStage.main.enumerated() {
            let p = geo.node(stage)
            if i == 0 { main.move(to: p) } else { main.addLine(to: p) }
        }
        ctx.stroke(main, with: .color(isSkeleton ? rail : strong), lineWidth: 1)
        if onBrand && !isSkeleton && litIndex > 0 {
            // The stretch of the pipeline this run has reached, lit in the brand signal.
            let start = geo.node(.discovered), end = geo.node(FlowStage.main[litIndex])
            var lit = Path()
            lit.move(to: start)
            lit.addLine(to: end)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Self.glow.opacity(0.15), Self.glow.opacity(isIdle ? 0.35 : 0.7)]),
                startPoint: start, endPoint: end)
            ctx.stroke(lit, with: shading, lineWidth: 1.5)
        }

        for branch in [FlowStage.skipped, .needsYou] {
            var path = Path()
            let start = geo.node(FlowGeometry.branchParent(branch))
            let end = geo.branchEnd(branch)
            path.move(to: start)
            path.addQuadCurve(to: end, control: CGPoint(x: start.x + (end.x - start.x) * 0.15, y: end.y))
            let color: Color = branch == .needsYou && snapshot.counts.needsYou > 0 && !isSkeleton
                ? Palette.needsYou.opacity(0.5) : rail
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        for (i, stage) in FlowStage.main.enumerated() {
            let p = geo.node(stage)
            let r = FlowGeometry.nodeRadius
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            if onBrand && !isSkeleton && i <= litIndex && FlowAccessibility.count(stage, snapshot.counts, filling: fillingCount) > 0 {
                // Reached stages are lit beads with a faint halo.
                let color = stage == .submitted ? Palette.applied : Self.glow
                let h = r + 5
                ctx.fill(Circle().path(in: CGRect(x: p.x - h, y: p.y - h, width: h * 2, height: h * 2)),
                         with: .radialGradient(Gradient(colors: [color.opacity(isIdle ? 0.18 : 0.32), color.opacity(0)]),
                                               center: p, startRadius: 0, endRadius: h))
                ctx.fill(Circle().path(in: rect), with: .color(color.opacity(isIdle ? 0.7 : 1)))
            } else {
                ctx.fill(Circle().path(in: rect), with: .color(onBrand ? Palette.Brand.ink2 : Palette.surface))
                ctx.stroke(Circle().path(in: rect), with: .color(isSkeleton ? rail : nodeColor(stage)), lineWidth: 1.25)
            }
        }
    }

    private func nodeColor(_ stage: FlowStage) -> Color {
        if onBrand { return isIdle ? Color.white.opacity(0.35) : Color.white.opacity(0.55) }
        if isIdle { return Palette.textTertiary }
        return switch stage {
        case .filling: Palette.accent
        case .submitted: Palette.applied
        default: Palette.textSecondary
        }
    }

    private func drawParticles(_ ctx: inout GraphicsContext, _ geo: FlowGeometry, now: Date) {
        for t in snapshot.transitions {
            guard let progress = FlowGeometry.progress(of: t, at: now) else { continue }
            let p = geo.point(from: t.from, to: t.to, progress: progress)
            let opacity = FlowGeometry.opacity(of: t, at: now)
            let color: Color = switch t.to {
            case .skipped: Palette.skipped
            case .needsYou: Palette.needsYou
            case .failed: Palette.error
            case .submitted: Palette.applied
            default: Palette.accent
            }
            let r = FlowGeometry.particleRadius * (onBrand ? 1.4 : 1)
            if onBrand {
                let h: CGFloat = 7
                ctx.fill(Circle().path(in: CGRect(x: p.x - h, y: p.y - h, width: h * 2, height: h * 2)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.45 * opacity), color.opacity(0)]),
                                               center: p, startRadius: 0, endRadius: h))
            }
            ctx.fill(Circle().path(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity(0.9 * opacity)))
        }
    }

    /// The Filling node holds the active job: an 8pt accent orb with a soft 12pt glow ring,
    /// breathing at 0.5 Hz while running.
    private func drawActiveOrb(_ ctx: inout GraphicsContext, _ geo: FlowGeometry, now: Date, animate: Bool) {
        guard snapshot.activeJobID != nil, isRunning else { return }
        let p = geo.node(.filling)
        let phase = animate ? (sin(now.timeIntervalSinceReferenceDate * .pi) + 1) / 2 : 0.5   // 0.5 Hz
        let glow: CGFloat = 12 + CGFloat(phase) * 3
        ctx.fill(Circle().path(in: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                 with: .color(Palette.accent.opacity(0.10 + 0.08 * phase)))
        let r: CGFloat = 4
        ctx.fill(Circle().path(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(Palette.accent))
    }

    // MARK: Labels (real views)

    @ViewBuilder
    private func labels(_ geo: FlowGeometry) -> some View {
        ForEach(FlowStage.main, id: \.self) { stage in
            let p = geo.node(stage)
            stageLabel(stage)
                .frame(width: max(64, geo.spacing - 8))
                .position(x: p.x, y: max(18, p.y - 30))
        }
        let submitted = snapshot.counts.submitted
        if submitted > 0 && !isSkeleton {
            Text(DashboardFormat.submittedGlyphs(submitted))
                .font(Typography.monoSmall)
                .foregroundStyle(onBrand ? Palette.applied.opacity(isIdle ? 0.75 : 1) : (isIdle ? Palette.textTertiary : Palette.applied))
                .lineLimit(1)
                .fixedSize()
                .position(x: geo.node(.submitted).x, y: geo.railY + 18)
                .accessibilityHidden(true)
        }
        if !isSkeleton {
            branchLabel(.skipped, text: snapshot.counts.skipped > 0 ? DashboardFormat.skippedLabel(snapshot.counts.skipped, threshold: threshold) : nil,
                        color: Palette.textTertiary, geo: geo)
            branchLabel(.needsYou, text: snapshot.counts.needsYou > 0 ? DashboardFormat.needsYouLabel(snapshot.counts.needsYou) : nil,
                        color: Palette.needsYou, geo: geo)
        }
    }

    private func stageLabel(_ stage: FlowStage) -> some View {
        let count = FlowAccessibility.count(stage, snapshot.counts, filling: fillingCount)
        return Button {
            onSelectStage(stage)
        } label: {
            VStack(spacing: 1) {
                Text(stage.title).eyebrowStyle().lineLimit(1).minimumScaleFactor(0.8)
                if isSkeleton {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.hairline).frame(width: 22, height: 14)
                } else {
                    let shown = countUp ? 0 : count
                    Text("\(shown)")
                        .font(onBrand ? Typography.metric.weight(.semibold) : Typography.metric)
                        .foregroundStyle(onBrand ? (isIdle ? Color.white.opacity(0.78) : Color.white)
                                                 : (isIdle ? Palette.textTertiary : Palette.textPrimary))
                        .numericRoll(Double(shown))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSkeleton)
        .onHover { inside in hoveredStage = inside ? stage : (hoveredStage == stage ? nil : hoveredStage) }
        .popover(isPresented: Binding(get: { hoveredStage == stage && !isSkeleton }, set: { if !$0 && hoveredStage == stage { hoveredStage = nil } }),
                 arrowEdge: .bottom) {
            StageJobsPopover(stage: stage, jobs: Array(jobsAtStage(stage).prefix(8)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FlowAccessibility.stage(stage, counts: snapshot.counts, filling: fillingCount, threshold: threshold))
        .accessibilityHint("Opens Pipeline filtered to this stage")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func branchLabel(_ stage: FlowStage, text: String?, color: Color, geo: FlowGeometry) -> some View {
        if let text {
            let end = geo.branchEnd(stage)
            Button { onSelectStage(stage) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.turn.down.right").imageScale(.small)
                    Text(text)
                }
                .font(Typography.callout)
                .foregroundStyle(color)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .position(x: end.x + 60, y: end.y)
            .accessibilityLabel(text)
            .accessibilityHint(stage == .needsYou ? "Opens Needs You" : "Opens Pipeline filtered by skip reason")
        }
    }
}

/// Hover popover: up to 8 jobs at a stage.
private struct StageJobsPopover: View {
    var stage: FlowStage
    var jobs: [JobItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(stage.title).eyebrowStyle()
            if jobs.isEmpty {
                Text("No jobs here right now").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            } else {
                ForEach(jobs) { job in
                    HStack(spacing: Space.s) {
                        StatusDot(kind: StatusKind(job: job))
                        Text(job.company).font(Typography.bodyEmph)
                        Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
            }
            Text("Click to open in Pipeline").font(Typography.callout).foregroundStyle(Palette.textTertiary)
        }
        .padding(Space.m)
        .frame(minWidth: 220, alignment: .leading)
    }
}
