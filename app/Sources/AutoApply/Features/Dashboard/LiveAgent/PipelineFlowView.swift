// PipelineFlowView.swift — the hero's live pipeline (§4.3 W2b, §8.4 "Live viz core"):
// Discovered → Scored → Queued → Filling → Submitted with skipped / needs-you branches, drawn
// in ONE Canvas inside a TimelineView. Particles are not state: positions are derived from
// (transition.start, now), so redraws are stateless. Counts are real Text views overlaid at the
// node positions (numericText + accessibility).
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
    var onSelectStage: (FlowStage) -> Void = { _ in }
    var jobsAtStage: (FlowStage) -> [JobItem] = { _ in [] }

    @Environment(\.motionReduced) private var reduced
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
        return TimelineView(.animation(minimumInterval: 1 / 60, paused: !animate)) { timeline in
            Canvas(rendersAsynchronously: false) { ctx, _ in
                drawRails(&ctx, geo)
                if isSkeleton { return }
                if !reduced { drawParticles(&ctx, geo, now: timeline.date) }
                drawActiveOrb(&ctx, geo, now: timeline.date, animate: animate)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func drawRails(_ ctx: inout GraphicsContext, _ geo: FlowGeometry) {
        let rail = Palette.hairline
        let strong = Palette.strokeStrong
        var main = Path()
        for (i, stage) in FlowStage.main.enumerated() {
            let p = geo.node(stage)
            if i == 0 { main.move(to: p) } else { main.addLine(to: p) }
        }
        ctx.stroke(main, with: .color(isSkeleton ? rail : strong), lineWidth: 1)

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

        for stage in FlowStage.main {
            let p = geo.node(stage)
            let r = FlowGeometry.nodeRadius
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.fill(Circle().path(in: rect), with: .color(Palette.surface))
            ctx.stroke(Circle().path(in: rect), with: .color(isSkeleton ? rail : nodeColor(stage)), lineWidth: 1.25)
        }
    }

    private func nodeColor(_ stage: FlowStage) -> Color {
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
            let r = FlowGeometry.particleRadius
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
                .foregroundStyle(isIdle ? Palette.textTertiary : Palette.applied)
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
                    Text("\(count)")
                        .font(Typography.metric)
                        .foregroundStyle(isIdle ? Palette.textTertiary : Palette.textPrimary)
                        .numericRoll(Double(count))
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
