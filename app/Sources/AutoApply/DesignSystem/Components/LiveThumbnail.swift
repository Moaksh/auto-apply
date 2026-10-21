// LiveThumbnail.swift — the live Chrome frame well (LiveBrowserThumb in the spec, §4.3 W2c):
// 16:10, sunken, radius 6; new frames cross-fade in 0.25 s; desaturated when showing the last
// submitted page instead of a live one.
import SwiftUI

/// Cross-fading live Chrome frame well (16:10); desaturated when showing the last page.
struct LiveThumbnail: View {
    var frame: DecodedFrame?
    var isLive: Bool

    var body: some View {
        ZStack {
            Palette.sunken
            if let frame {
                Image(decorative: frame.image, scale: 2)
                    .resizable()
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .saturation(isLive ? 1 : 0.4)
                    .id(frame.receivedAt)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                Image(systemName: "macwindow").font(.system(size: 28)).foregroundStyle(Palette.textTertiary)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(.thumb)
        .accessibilityLabel(isLive ? "Live view of the agent's Chrome window" : "Last page the agent applied on")
    }
}
