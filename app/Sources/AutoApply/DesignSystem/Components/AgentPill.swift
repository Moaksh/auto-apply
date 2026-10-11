// AgentPill.swift — compact live agent status (sidebar footer, menu bar popover, hero
// compact): dot + sentence + progress ring. Same component everywhere (§3.2).
import SwiftUI

struct AgentPill: View {
    enum Size { case compact, large }

    var status: AgentStatus
    var size: Size = .compact
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: Space.s) {
                AgentStatusDot(kind: status.kind, size: size == .large ? 10 : 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(size == .large ? Typography.title2 : Typography.bodyEmph)
                        .contentTransition(.interpolate)
                    if let detail = status.detail {
                        Text(detail)
                            .font(size == .large ? Typography.callout : Typography.monoSmall)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let progress = status.progress, status.isActive {
                    ProgressRing(progress: progress)
                        .frame(width: size == .large ? 22 : 16, height: size == .large ? 22 : 16)
                } else if status.kind == .pausing || status.kind == .resuming {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Palette.surfaceRaised.opacity(size == .compact ? 1 : 0), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .overlay {
            if size == .compact {
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).stroke(Palette.hairline, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent: \(status.sentence)")
        .accessibilityHint(action == nil ? "" : "Shows the live agent on the dashboard")
    }
}

/// Status dot: accent + pulse while active, amber when it needs you, red on error, grey idle.
struct AgentStatusDot: View {
    var kind: AgentStatus.Kind
    var size: CGFloat = 8
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: isActive && !reduced)
            .symbolEffect(.breathe, options: .repeating, isActive: kind == .idle && !reduced)
            .accessibilityHidden(true)
    }

    private var isActive: Bool { [.discovering, .scoring, .prepping, .applying].contains(kind) }

    private var color: Color {
        switch kind {
        case .discovering, .scoring, .prepping, .applying: Palette.accent
        case .needsYou: Palette.needsYou
        case .paused, .pausing, .resuming, .capReached: Palette.textSecondary
        case .error, .disconnected: Palette.error
        case .idle, .loading: Palette.textTertiary
        }
    }
}

/// Thin determinate progress ring (accent on hairline track).
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .motion(Motion.snappy, value: progress)
        .accessibilityLabel("\(Int((progress * 100).rounded())) percent")
    }
}

#Preview("Agent pill") {
    VStack(spacing: Space.s) {
        AgentPill(status: AgentStatus(kind: .applying, title: "Applying", detail: "3 of 12 today", progress: 0.25))
        AgentPill(status: AgentStatus(kind: .idle, title: "Idle", detail: "next run 14:00"))
        AgentPill(status: AgentStatus(kind: .pausing, title: "Pausing…"))
        AgentPill(status: AgentStatus(kind: .disconnected, title: "Can't reach autoapplyd"), size: .large)
    }
    .padding()
    .frame(width: 260)
}
