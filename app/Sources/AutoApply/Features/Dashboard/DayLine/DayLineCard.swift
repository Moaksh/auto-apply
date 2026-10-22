// DayLineCard.swift — "Today so far": a horizontal dotted line across today with a chip per event
// (applications sent or approved, replies, follow-ups, things held for you), a printed time on
// each, and a coral "now" cursor. Time runs left to right, like the agent's work everywhere else
// on the Dashboard, and the card spans the full width like the briefing above it. Chips that wait
// for you carry the coral dot and open the right screen (Review, Needs You); the rest open the job.
// Flat content on a Surface: no glass, no shadows, nothing loops. New chips rise in (`.row`) and the
// line makes room with `Motion.move`; under Reduce Motion both are a cross-fade. Rules live in
// DayLineModel.swift.
import SwiftUI

struct DayLineCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        // The now cursor walks once a minute; there is no animation between ticks.
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let o = store.outreach
        let items = DayLine.items(jobs: store.jobs.all, replies: o.replies, messages: o.data.messages, threads: o.data.threads,
                                  clusters: store.inbox.clusters, now: now)
        let summary = DayLine.summary(items)
        return Surface("Today so far") {
            if !summary.isEmpty {
                Text(summary)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .contentTransition(.numericText())
                    .motion(Motion.numeric, value: summary)
            }
        } content: {
            VStack(alignment: .leading, spacing: Space.s) {
                DayLineTrack(items: items, window: DayLine.window(items: items, now: now), now: now, open: open)
                if items.isEmpty {
                    Text(DayLine.emptyNote)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func open(_ target: DayLineItem.Target) {
        switch target {
        case .review(let jobID):
            router.go(.review)
            ReviewModel.shared(for: store).focusedJobID = jobID
        case .question(let clusterID):
            router.go(.needsYou)
            InboxModel.shared(for: store).select(clusterID)
        case .reply(let key):
            router.go(.needsYou)
            InboxModel.shared(for: store).selectReply(key)
        case .job(let id):
            router.openJobFromDashboard(id)
        }
    }
}

/// The line itself: the dotted rule, hour marks, a dot per event, the chips and the now cursor,
/// laid out by `DayLineLayout`.
struct DayLineTrack: View {
    var items: [DayLineItem]
    var window: DayLineWindow
    var now: Date
    var open: (DayLineItem.Target) -> Void = { _ in }

    var body: some View {
        let nowAt = window.fraction(now)
        DayLineLayout {
            DottedRule()
                .stroke(Palette.strokeStrong, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))
                .frame(height: 1)
                .layoutValue(key: DayLineSlotKey.self, value: .axis)
            Rectangle()
                .fill(Palette.coral.opacity(0.55))
                .frame(width: 1)
                .layoutValue(key: DayLineSlotKey.self, value: .cursor(nowAt))
                .accessibilityHidden(true)
            ForEach(window.hourMarks(), id: \.self) { mark in
                Text(DayLine.time(mark))
                    .font(Typography.ticketLabel)
                    .foregroundStyle(Palette.textTertiary)
                    .layoutValue(key: DayLineSlotKey.self, value: .hour(window.fraction(mark)))
                    .accessibilityHidden(true)
            }
            ForEach(items) { item in
                Circle()
                    .fill(dotColor(item))
                    .frame(width: 7, height: 7)
                    .layoutValue(key: DayLineSlotKey.self, value: .dot(window.fraction(item.at)))
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            Circle()
                .fill(Palette.coral)
                .frame(width: 9, height: 9)
                .padding(2)
                .background(Palette.surface, in: Circle())
                .layoutValue(key: DayLineSlotKey.self, value: .dot(nowAt))
                .accessibilityHidden(true)
            ForEach(items) { item in
                DayLineChip(item: item, open: item.target.map { target in { open(target) } })
                    .layoutValue(key: DayLineSlotKey.self, value: .chip(window.fraction(item.at)))
                    .motionTransition(.row)
            }
            Text("Now \(DayLine.time(now))")
                .font(Typography.ticketLabel)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Palette.coral)
                .layoutValue(key: DayLineSlotKey.self, value: .now(nowAt))
                .accessibilityLabel("Now, \(DayLine.time(now))")
        }
        .motion(Motion.move, value: items.map(\.id))
    }

    private func dotColor(_ item: DayLineItem) -> Color {
        if item.needsYou { return Palette.coral }
        switch item.kind {
        case .sent, .approved: return Palette.accent
        default: return Palette.textTertiary
        }
    }
}

/// One event: "14:12 · SENT" over "Razorpay", with the coral dot when it waits for you.
struct DayLineChip: View {
    var item: DayLineItem
    var open: (() -> Void)?

    static let maxWidth: CGFloat = 168

    var body: some View {
        let chip = HStack(alignment: .center, spacing: 6) {
            if item.needsYou {
                Circle().fill(Palette.coral).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            TicketField(label: "\(DayLine.time(item.at)) · \(item.label)", value: item.title)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .well()
        if let open {
            Button(action: open) { chip.contentShape(.inner) }
                .buttonStyle(.plain)
                .hoverResponse()
                .help(help)
                .accessibilityLabel(DayLine.accessibilityLabel(item))
                .accessibilityHint(help)
        } else {
            chip
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DayLine.accessibilityLabel(item))
        }
    }

    private var help: String {
        switch item.target {
        case .review: "Open it in Review"
        case .question, .reply: "Open it in Needs You"
        case .job: "Open the job"
        case nil: ""
        }
    }
}

/// A horizontal hairline (stroked dotted by the caller).
struct DottedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Layout

/// What a subview of `DayLineLayout` is, and where on the line (0…1) it belongs.
enum DayLineSlot: Equatable {
    case axis
    case cursor(Double)
    case hour(Double)
    case dot(Double)
    case chip(Double)
    case now(Double)
}

struct DayLineSlotKey: LayoutValueKey {
    static let defaultValue = DayLineSlot.axis
}

/// Places the line's parts. Chips sit above the line in up to `maxLanes` lanes, each starting at
/// its own time; a chip that would overlap the one before it takes the next lane up, and when every
/// lane is taken it waits its turn to the right (its printed time still says when). The now label
/// has a row of its own at the top, the hour marks sit under the line. Stateless (no geometry
/// reads), so it renders offscreen.
struct DayLineLayout: Layout {
    var maxLanes = 3
    var laneGap: CGFloat = 6
    var chipGap: CGFloat = 6

    struct Plan {
        var chips: [Int: CGRect] = [:]
        var lineY: CGFloat = 0
        var nowRow: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Lane packing, exposed for tests: leading x per chip (in time order) and its lane (0 nearest
    /// the line).
    static func pack(widths: [CGFloat], preferred: [CGFloat], width: CGFloat, maxLanes: Int, gap: CGFloat) -> [(x: CGFloat, lane: Int)] {
        var laneEnds: [CGFloat] = []
        var out: [(x: CGFloat, lane: Int)] = []
        for (w, want) in zip(widths, preferred) {
            let x = min(max(0, want), max(0, width - w))
            if let lane = laneEnds.firstIndex(where: { $0 + gap <= x }) {
                laneEnds[lane] = x + w
                out.append((x, lane))
            } else if laneEnds.count < maxLanes {
                laneEnds.append(x + w)
                out.append((x, laneEnds.count - 1))
            } else {
                let lane = laneEnds.indices.min { laneEnds[$0] < laneEnds[$1] }!
                let shifted = min(laneEnds[lane] + gap, max(0, width - w))
                laneEnds[lane] = shifted + w
                out.append((shifted, lane))
            }
        }
        return out
    }

    private func plan(width: CGFloat, subviews: Subviews) -> Plan {
        var plan = Plan()
        let nowView = subviews.first { $0[DayLineSlotKey.self].isNow }
        plan.nowRow = (nowView?.sizeThatFits(.unspecified).height ?? 12) + Space.xs

        var indices: [Int] = []
        var sizes: [CGSize] = []
        var preferred: [CGFloat] = []
        for (i, view) in subviews.enumerated() {
            guard case .chip(let f) = view[DayLineSlotKey.self] else { continue }
            let ideal = view.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, DayLineChip.maxWidth), height: ideal.height)
            indices.append(i)
            sizes.append(size)
            // The chip starts a hair before its dot, so the dot reads as its corner.
            preferred.append(CGFloat(f) * width - 4)
        }
        let packed = Self.pack(widths: sizes.map(\.width), preferred: preferred, width: width, maxLanes: maxLanes, gap: chipGap)
        let lanes = (packed.map(\.lane).max() ?? -1) + 1
        let laneHeight = sizes.map(\.height).max() ?? 0
        let chipsTop = plan.nowRow + Space.xs
        for (k, i) in indices.enumerated() {
            let lane = packed[k].lane
            let y = chipsTop + CGFloat(lanes - 1 - lane) * (laneHeight + laneGap)
            plan.chips[i] = CGRect(x: packed[k].x, y: y, width: sizes[k].width, height: sizes[k].height)
        }
        plan.lineY = chipsTop + CGFloat(lanes) * (laneHeight + laneGap) + (lanes == 0 ? Space.s : Space.xs)
        let hourHeight = subviews.first { if case .hour = $0[DayLineSlotKey.self] { true } else { false } }?
            .sizeThatFits(.unspecified).height ?? 12
        plan.height = plan.lineY + Space.s + hourHeight
        return plan
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: plan(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(width: bounds.width, subviews: subviews)
        func x(_ f: Double) -> CGFloat { bounds.minX + CGFloat(f) * bounds.width }
        for (i, view) in subviews.enumerated() {
            switch view[DayLineSlotKey.self] {
            case .axis:
                view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + p.lineY), anchor: .leading,
                           proposal: ProposedViewSize(width: bounds.width, height: 1))
            case .cursor(let f):
                view.place(at: CGPoint(x: x(f), y: bounds.minY + p.nowRow), anchor: .top,
                           proposal: ProposedViewSize(width: 1, height: max(0, p.lineY - p.nowRow)))
            case .dot(let f):
                view.place(at: CGPoint(x: x(f), y: bounds.minY + p.lineY), anchor: .center, proposal: .unspecified)
            case .hour(let f):
                let w = view.sizeThatFits(.unspecified).width
                let cx = min(max(x(f), bounds.minX + w / 2), bounds.maxX - w / 2)
                view.place(at: CGPoint(x: cx, y: bounds.minY + p.lineY + Space.s), anchor: .top, proposal: .unspecified)
            case .now(let f):
                let w = view.sizeThatFits(.unspecified).width
                let cx = min(max(x(f), bounds.minX + w / 2), bounds.maxX - w / 2)
                view.place(at: CGPoint(x: cx, y: bounds.minY), anchor: .top, proposal: .unspecified)
            case .chip:
                guard let frame = p.chips[i] else { continue }
                view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                           proposal: ProposedViewSize(width: frame.width, height: frame.height))
            }
        }
    }
}

private extension DayLineSlot {
    var isNow: Bool { if case .now = self { true } else { false } }
}

#Preview("Day line") {
    let now = Date()
    let items = [
        DayLineItem(id: "a", at: now.addingTimeInterval(-5 * 3_600), kind: .sent, label: "Sent", title: "Razorpay", needsYou: false, target: nil),
        DayLineItem(id: "b", at: now.addingTimeInterval(-3 * 3_600), kind: .reply, label: "Reply", title: "Stripe", needsYou: true, target: .job(1)),
        DayLineItem(id: "c", at: now.addingTimeInterval(-1_200), kind: .review, label: "Review", title: "Notion", needsYou: true, target: .review(jobID: 2)),
    ]
    DayLineTrack(items: items, window: DayLine.window(items: items, now: now), now: now)
        .padding()
        .frame(width: 900)
}
