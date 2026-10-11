// LiveBrowserThumb.swift — the hero's live Chrome well (§4.3 W2c) built on C1's LiveThumbnail:
// adds the once-per-frame accent scan line, the ATS chip (click brings the real Chrome window
// forward) and the "Last: Ramp · 13:58" caption when not filling.
import SwiftUI

struct LiveBrowserThumb: View {
    var frame: DecodedFrame?
    var isLive: Bool
    var atsLabel: String?
    var caption: String?
    var accessibilityDescription: String
    var onBringChromeForward: () -> Void

    @Environment(\.motionReduced) private var reduced
    @State private var scanStart: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            LiveThumbnail(frame: frame, isLive: isLive)
                .overlay { scanLine }
                .overlay(alignment: .topTrailing) {
                    if let atsLabel {
                        Button(action: onBringChromeForward) {
                            HStack(spacing: 3) {
                                Image(systemName: "globe").imageScale(.small)
                                Text(atsLabel)
                            }
                            .font(Typography.monoSmall)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .glassCapsule(interactive: true)
                        .padding(Space.s)
                        .help("Bring the agent's Chrome window forward")
                    }
                }
                .accessibilityLabel(accessibilityDescription)
            if let caption {
                Text(caption).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
            }
        }
        .onChange(of: frame?.receivedAt) { _, new in
            guard new != nil, isLive, !reduced else { return }
            scanStart = Date()
        }
    }

    /// A thin accent line sweeping top → bottom once per new frame (0.4 s, 20% opacity).
    @ViewBuilder
    private var scanLine: some View {
        if let start = scanStart, !reduced {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
                let t = timeline.date.timeIntervalSince(start) / 0.4
                GeometryReader { geo in
                    if t < 1 {
                        Rectangle()
                            .fill(Palette.accent.opacity(0.2))
                            .frame(height: 2)
                            .offset(y: geo.size.height * t)
                    }
                }
            }
            .allowsHitTesting(false)
            .clipShape(.thumb)
            .task(id: start) {
                try? await Task.sleep(for: .milliseconds(450))
                if scanStart == start { scanStart = nil }
            }
        }
    }
}
