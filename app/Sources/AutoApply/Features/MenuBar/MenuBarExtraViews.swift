// MenuBarExtraViews.swift — the menu bar glyph (state variants) and popover panel (§3.5):
// Agent Pill + kill switch, live Chrome thumbnail, current job + mono ticker, needs-you and
// review rows, today's sparkline, caps, next run, Open AutoApply.
import SwiftUI

/// Glyph states: idle outline · discovering (pulse) · applying filled + "3/12" · needs you ·
/// paused · error/daemon down.
struct MenuBarGlyph: View {
    let store: AppStore
    @AppStorage("menuBarCounter") private var showCounter = true

    enum GlyphState: Equatable { case idle, discovering, applying, needsYou, paused, error }

    static func state(for store: AppStore) -> GlyphState {
        let status = store.agentStatus
        switch status.kind {
        case .disconnected, .error: return .error
        case .paused, .pausing: return .paused
        case .discovering, .scoring, .prepping: return .discovering
        case .applying: return .applying
        default: return store.inbox.openCount > 0 ? .needsYou : .idle
        }
    }

    var body: some View {
        let state = Self.state(for: store)
        HStack(spacing: 3) {
            Image(systemName: symbol(state))
                .symbolEffect(.pulse, options: .repeating, isActive: state == .discovering || state == .applying)
                .symbolEffect(.bounce, value: state == .needsYou)
            if state == .applying && showCounter {
                let caps = store.caps
                Text("\(caps.dailyUsed)/\(caps.dailyLimit)").monospacedDigit()
            }
        }
        .accessibilityLabel("AutoApply: \(store.agentStatus.sentence)")
    }

    private func symbol(_ state: GlyphState) -> String {
        switch state {
        case .idle: "paperplane"
        case .discovering: "paperplane"
        case .applying: "paperplane.fill"
        case .needsYou: "paperplane.circle.fill"
        case .paused: "pause.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}

struct MenuBarPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                AgentPill(status: store.agentStatus, size: .large) { openMain(.dashboard) }
                Button {
                    Haptics.levelChange()
                    Task { await store.togglePause() }
                } label: {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .help(store.isPaused ? "Resume agent" : "Pause agent (kill switch)")
                .disabled(!store.isConnected)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Header band on the live brand field (pauses with the popover's window).
            .brandHeroBand(cornerRadius: Radius.palette - Space.xs)

            if store.live.isRunning || store.live.frame != nil || store.live.lastSubmittedFrame != nil {
                LiveThumbnail(frame: store.live.frame ?? store.live.lastSubmittedFrame,
                              isLive: store.live.frame != nil && store.live.isRunning)
                    .frame(height: 190)
            }

            if let title = store.activeJobTitle, store.live.activity == .applying {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typography.bodyEmph).lineLimit(1)
                    if let step = store.live.ticker.last {
                        HStack(spacing: Space.xs) {
                            if let progress = store.live.stepProgress {
                                Text("step \(progress.index)/\(progress.total)")
                            }
                            Text(step.detail ?? step.action).lineLimit(1)
                        }
                        .font(Typography.mono)
                        .foregroundStyle(step.isLowConfidence ? Palette.needsYou : Palette.textSecondary)
                    }
                }
            }

            if store.inbox.openCount > 0 || store.counts.awaitingReview > 0 {
                Divider()
                if store.inbox.openCount > 0 {
                    PanelRow(symbol: "hand.raised.fill", tint: Palette.needsYou,
                             text: "Needs you · \(store.inbox.summary)",
                             action: store.inbox.actionCount > 0 ? "Open" : "Answer") { openMain(.needsYou) }
                        .background(Palette.needsYou.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                }
                if store.counts.awaitingReview > 0 {
                    PanelRow(symbol: "checkmark.rectangle.stack", tint: Palette.accent,
                             text: "\(store.counts.awaitingReview) waiting for review", action: "Review") { openMain(.review) }
                }
            }

            Divider()
            HStack(spacing: Space.s) {
                Text("Today").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Sparkline(values: store.stats.appliedLast7).frame(width: 56, height: 16)
                Text("\(store.counts.submittedToday) applied · \(store.counts.discoveredToday) found")
                    .font(Typography.callout).monospacedDigit()
            }
            CapBar(title: "Caps", used: store.caps.dailyUsed, limit: max(store.caps.dailyLimit, 1))

            Divider()
            HStack {
                if let next = store.nextRunAt {
                    Text("Next run \(next.formatted(date: .omitted, time: .shortened))")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                } else if let mock = store.mockScenarioName {
                    Text("Mock · \(mock)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                Button {
                    openMain(nil)
                } label: {
                    HStack(spacing: Space.xs) { Text("Open AutoApply"); KeyCap(.openMainWindow) }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.openMainWindow)
            }
            HStack {
                Spacer()
                Button("Quit AutoApply") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary)
                    .keyboardShortcut("q")
            }
        }
        .padding(Space.l)
        .frame(width: LayoutMetrics.menuBarWidth)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: store.inbox.openCount)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: store.counts.awaitingReview)
    }

    private func openMain(_ item: SidebarItem?) {
        openWindow(id: WindowID.main)
        if let item { router.go(item) }
        NSApp.activate()
    }
}

private struct PanelRow: View {
    var symbol: String
    var tint: Color
    var text: String
    var action: String
    var perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(Typography.body)
                Spacer()
                Text("\(action) ›").font(Typography.bodyEmph).foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
