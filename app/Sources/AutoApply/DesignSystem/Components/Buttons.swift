// Buttons.swift — the two in-content button styles.
//
// `.primaryPill`: the one obvious action on a screen. An ink pill on light, a white pill on
// dark (`primaryFill` / `onPrimaryFill`). At most one is visible per screen; a render test
// checks this through `ProminenceAudit`.
// `.secondaryLink`: every other in-content action, as accent text with no chrome. System
// `.bordered` stays available for plain secondary buttons (form Save / Cancel pairs).
// Glass buttons never appear in content; glass is for the floating control layer.
import SwiftUI

struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryPillBody(configuration: configuration)
    }
}

private struct PrimaryPillBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.prominenceAudit) private var audit
    @State private var token = UUID()

    var body: some View {
        let _ = audit?.record(token)
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .font(small ? Typography.callout.weight(.medium) : Typography.bodyEmph)
            .lineLimit(1)
            .foregroundStyle(Palette.onPrimaryFill)
            .padding(.horizontal, small ? Space.m - 2 : Space.l - 2)
            .padding(.vertical, small ? 3 : 6)
            .background(Palette.primaryFill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Capsule())
    }
}

struct SecondaryLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryLinkBody(configuration: configuration)
    }
}

private struct SecondaryLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? Palette.accent : Palette.textTertiary)
            .underline(hovering && isEnabled, color: Palette.accent.opacity(0.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == PrimaryPillStyle {
    /// The screen's one in-content primary action.
    static var primaryPill: PrimaryPillStyle { PrimaryPillStyle() }
}

extension ButtonStyle where Self == SecondaryLinkStyle {
    /// Any other in-content action: accent text, no chrome.
    static var secondaryLink: SecondaryLinkStyle { SecondaryLinkStyle() }
}

// MARK: - Prominence audit

/// Collects the distinct primary pills drawn while rendering a screen (tests only; nil in the app).
@MainActor
final class ProminenceAudit {
    private(set) var tokens: Set<UUID> = []
    var count: Int { tokens.count }
    func record(_ token: UUID) { tokens.insert(token) }
}

extension EnvironmentValues {
    @Entry var prominenceAudit: ProminenceAudit? = nil
}

#Preview("Buttons") {
    HStack(spacing: Space.l) {
        Button("Approve & submit") {}.buttonStyle(.primaryPill)
        Button("Skip") {}.buttonStyle(.secondaryLink)
        Button("Disabled") {}.buttonStyle(.primaryPill).disabled(true)
        Button("Cancel") {}.buttonStyle(.bordered)
    }
    .padding()
}
