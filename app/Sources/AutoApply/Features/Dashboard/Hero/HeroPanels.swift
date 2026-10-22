// HeroPanels.swift — the glass panels that float on the Dashboard's brand field under the
// pipeline. Never an empty grey box: every state has something true to say.
// - Idle / needs you / done for today / paused: `HeroNextRunPanel` (a breathing ring counting
//   down to the next run) beside `HeroTodayPanel` (today's numbers and the last application).
// - Discovering / scoring / collecting questions (or filling before the first frame):
//   `HeroRunPulsePanel` — the stage's live count with a light sweeping across a track.
// - Filling: the live Chrome frame (`LiveBrowserThumb`) in a glass frame, beside the steps.
import SwiftUI

/// Shape and padding shared by the hero panels.
enum HeroPanel {
    static let radius: CGFloat = 18
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

extension View {
    /// A hero panel: padded content on Liquid Glass, stretched to the row's height.
    func heroPanel(tint: Color? = nil, padding: CGFloat = Space.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .heroGlass(in: HeroPanel.shape, tint: tint)
    }
}

// MARK: - Next run

/// A ring counting down to the next run, with a slow breathing glow behind it.
struct HeroNextRunPanel: View {
    enum Kind: Equatable {
        case idle
        case needsYou
        case doneForToday(used: Int, limit: Int)
        case paused
    }

    var kind: Kind
    var nextRun: Date?
    /// When the last run ended (the ring's start).
    var since: Date?
    var mode: Mode

    var body: some View {
        let refresh = HeroCountdown.refreshInterval(nextRun: nextRun, now: Date())
        TimelineView(.periodic(from: .now, by: refresh)) { timeline in
            let now = timeline.date
            HStack(alignment: .center, spacing: Space.l) {
                ring(now: now)
                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrow).eyebrowStyle()
                    Text(headline(now: now))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(caption)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .motion(Motion.numeric, value: headline(now: now))
        }
        .heroPanel(tint: kind == .needsYou ? Palette.Brand.coral : nil)
        .accessibilityElement(children: .combine)
    }

    private var accent: Color {
        switch kind {
        case .needsYou: Palette.Brand.coral
        case .doneForToday: Palette.applied
        case .paused: Color.white.opacity(0.6)
        case .idle: Palette.Brand.signal
        }
    }

    private var symbol: String {
        switch kind {
        case .idle: "clock"
        case .needsYou: "bubble.left.and.exclamationmark.bubble.right"
        case .doneForToday: "moon.stars"
        case .paused: "pause"
        }
    }

    private func progress(now: Date) -> Double {
        switch kind {
        case .doneForToday: return 1
        case .paused: return 0
        default: return HeroCountdown.progress(from: since, to: nextRun, now: now) ?? 0
        }
    }

    private func ring(now: Date) -> some View {
        let p = progress(now: now)
        return ZStack {
            HeroBreath(color: accent, period: 6, radius: 46, minOpacity: 0.10, maxOpacity: 0.34)
            Circle().stroke(.white.opacity(0.10), lineWidth: 5)
                .frame(width: 64, height: 64)
            Circle()
                .trim(from: 0, to: max(0.001, p))
                .stroke(AngularGradient(colors: [accent.opacity(0.35), accent], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, p))),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 64, height: 64)
                .opacity(p > 0 ? 1 : 0)
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(accent)
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
    }

    private var eyebrow: String {
        switch kind {
        case .idle, .needsYou: "Next run"
        case .doneForToday: "Done for today"
        case .paused: "Paused"
        }
    }

    private func headline(now: Date) -> String {
        switch kind {
        case .doneForToday(let used, let limit): return "\(used) of \(limit)"
        case .paused: return "On hold"
        case .idle, .needsYou:
            guard let nextRun else { return "Not scheduled" }
            return HeroCountdown.phrase(nextRun: nextRun, now: now)
        }
    }

    private var caption: String {
        let modeText = mode == .auto ? "Auto: sends on its own" : "Review: waits for your OK"
        let at = nextRun.map { "at \($0.formatted(date: .omitted, time: .shortened))" }
        switch kind {
        case .idle:
            return [at, modeText].compactMap { $0 }.joined(separator: " · ")
        case .needsYou:
            return [at, "your answers free up waiting jobs"].compactMap { $0 }.joined(separator: " · ")
        case .doneForToday:
            return "Daily limit reached" + (nextRun.map { " · continues \($0.formatted(.dateTime.weekday(.wide))) \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .paused:
            return "Nothing runs until you resume"
        }
    }
}

// MARK: - Today

/// Today's numbers and the last application, so idle never means empty.
struct HeroTodayPanel: View {
    struct LastApplied: Equatable {
        var jobID: Int
        var company: String
        var title: String
        var at: Date
    }

    var applied: Int
    var found: Int
    var needYou: Int
    var queued: Int
    var lastApplied: LastApplied?
    var lastFrame: DecodedFrame?
    var onOpenLast: (Int) -> Void = { _ in }

    @Environment(\.dashboardCountUp) private var countUp

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Today so far").eyebrowStyle()
            HStack(alignment: .firstTextBaseline, spacing: Space.xl) {
                stat(applied, "applied", color: Palette.applied)
                stat(found, "found", color: .white)
                stat(needYou, needYou == 1 ? "needs you" : "need you", color: needYou > 0 ? Palette.Brand.coral : .white.opacity(0.7))
                Spacer(minLength: 0)
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
            lastRow
        }
        .heroPanel()
    }

    private func stat(_ value: Int, _ label: String, color: Color) -> some View {
        let shown = countUp ? 0 : value
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(shown)")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .numericRoll(Double(shown))
            Text(label).font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    @ViewBuilder
    private var lastRow: some View {
        if let last = lastApplied {
            Button { onOpenLast(last.jobID) } label: {
                HStack(spacing: Space.m) {
                    thumb(company: last.company)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Last applied").font(Typography.monoSmall).textCase(.uppercase).foregroundStyle(Palette.textSecondary)
                        Text("\(last.company) · \(last.title)")
                            .font(Typography.bodyEmph)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.s)
                    Text(last.at.formatted(date: .omitted, time: .shortened))
                        .font(Typography.monoSmall)
                        .foregroundStyle(Palette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open job detail")
            .accessibilityLabel("Last applied: \(last.company), \(last.title), at \(last.at.formatted(date: .omitted, time: .shortened))")
        } else {
            HStack(spacing: Space.s) {
                Image(systemName: queued > 0 ? "tray.full" : "sparkles")
                    .foregroundStyle(Palette.Brand.signal)
                Text(queued > 0 ? "\(queued) job\(queued == 1 ? "" : "s") queued for the next run" : "Nothing applied yet today")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// The last page the agent applied on, else a monogram of the company.
    @ViewBuilder
    private func thumb(company: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if let lastFrame {
            Image(decorative: lastFrame.image, scale: 2)
                .resizable()
                .aspectRatio(16 / 10, contentMode: .fill)
                .frame(width: 56, height: 35)
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.5))
        } else {
            Text(String(company.prefix(1)).uppercased())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 35, height: 35)
                .background(LinearGradient(colors: [Palette.Brand.deepGreen, Palette.applied.opacity(0.7)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}

// MARK: - Working

/// The live count of the stage the agent is on, with a light sweeping across a track.
struct HeroRunPulsePanel: View {
    var eyebrow: String
    var value: Int
    var unit: String
    var since: Date?
    var message: String?

    @Environment(\.heroMotionActive) private var active

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text(eyebrow).eyebrowStyle()
                Spacer()
                if let since {
                    TimelineView(.periodic(from: since, by: 1)) { timeline in
                        Text(DashboardFormat.elapsed(timeline.date.timeIntervalSince(since)))
                            .font(Typography.monoSmall)
                            .foregroundStyle(Palette.textSecondary)
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Elapsed")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("\(value)")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .numericRoll(Double(value))
                Text(unit).font(Typography.body).foregroundStyle(Palette.textSecondary)
            }
            sweep
            if let message {
                Text(message)
                    .font(Typography.mono)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
        }
        .heroPanel(tint: Palette.Brand.signal)
        .accessibilityElement(children: .combine)
    }

    /// A thin track with a light travelling across it (≤ 30 fps while hero motion runs).
    private var sweep: some View {
        TimelineView(.animation(minimumInterval: 1 / HeroFrameRate.flow, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let x = active ? (t / 1.8).truncatingRemainder(dividingBy: 1) : 0.5
            Canvas { ctx, size in
                let track = Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1.5, width: size.width, height: 3), cornerRadius: 1.5)
                ctx.fill(track, with: .color(.white.opacity(0.08)))
                let cx = size.width * x
                let w = size.width * 0.28
                ctx.clip(to: track)
                ctx.fill(Path(CGRect(x: cx - w / 2, y: 0, width: w, height: size.height)),
                         with: .linearGradient(Gradient(colors: [Palette.Brand.signal.opacity(0), Palette.Brand.signal, Palette.Brand.signal.opacity(0)]),
                                               startPoint: CGPoint(x: cx - w / 2, y: 0), endPoint: CGPoint(x: cx + w / 2, y: 0)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
