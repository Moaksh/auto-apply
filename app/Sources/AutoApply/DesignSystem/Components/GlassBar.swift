// GlassBar.swift — the floating control layer inside a window: GlassBar (the one in-window
// glass capsule), the bulk-action bar built on it, HUD toasts, the paused bar, and the single
// global Banner (flat, it's content).
import SwiftUI

/// A floating Liquid Glass capsule holding controls. The only in-window glass besides the
/// ⌘K palette; it floats over content and never contains content itself.
struct GlassBar<Content: View>: View {
    var interactive = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: Space.m) { content() }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .glassChrome(in: Capsule(), interactive: interactive)
    }
}

/// HUD toast: one sentence, an optional action.
struct HUDToast: View {
    var toast: ToastCenter.Toast
    var onAction: () -> Void
    var onSecondary: () -> Void = {}

    var body: some View {
        GlassBar {
            HStack(spacing: Space.s) {
                if let symbol = toast.symbol {
                    Image(systemName: symbol).foregroundStyle(iconColor)
                }
                Text(toast.message).font(Typography.body)
            }
            if let actionTitle = toast.actionTitle {
                if toast.countdown, let start = toast.presentedAt {
                    UndoRing(start: start, duration: toast.duration)
                }
                Button(actionTitle, action: onAction)
                    .buttonStyle(.secondaryLink)
                    .font(Typography.bodyEmph)
            }
            if let secondaryTitle = toast.secondaryTitle {
                Button(secondaryTitle, action: onSecondary)
                    .buttonStyle(.secondaryLink)
                    .font(Typography.body)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var iconColor: Color {
        switch toast.style {
        case .info: Palette.textSecondary
        case .success: Palette.applied
        case .warning: Palette.needsYou
        case .error: Palette.error
        }
    }
}

/// The draining ring beside a toast's Undo: full when the toast appears, empty when the window
/// closes. Steps once a second under Reduce Motion; holds still while the window is hidden.
struct UndoRing: View {
    var start: Date
    var duration: Duration
    var size: CGFloat = 14
    @Environment(\.motionReduced) private var reduced
    @State private var windowVisible = true

    var body: some View {
        TimelineView(.animation(minimumInterval: reduced ? 1 : 1.0 / 30, paused: !windowVisible)) { context in
            let left = Self.remaining(start: start, duration: duration, now: context.date)
            ZStack {
                Circle().stroke(Palette.hairline, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: left)
                    .stroke(Palette.applied, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
        }
        .trackWindowVisibility($windowVisible)
        .accessibilityHidden(true)
    }

    /// Fraction of the window still open, 1 -> 0.
    static func remaining(start: Date, duration: Duration, now: Date) -> Double {
        let total = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - now.timeIntervalSince(start) / total))
    }
}

/// Bottom-centered toast presenter; attach once per window.
struct HUDToastHost: ViewModifier {
    var center: ToastCenter
    @Environment(\.motionReduced) private var reduced

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let toast = center.current {
                    HUDToast(toast: toast, onAction: { center.performAction() }, onSecondary: { center.performSecondaryAction() })
                        .id(toast.id)
                        .transition(.reduced(.slideIn(from: .bottom), reduced))
                        .onTapGesture { if toast.actionTitle == nil { center.dismiss() } }
                }
            }
            .padding(.bottom, Space.xl)
            .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: center.current?.id)
        }
    }
}

extension View {
    func toastHost(_ center: ToastCenter) -> some View { modifier(HUDToastHost(center: center)) }
}

/// The single global banner: one sentence and one fix, on a faint tint. With several issues it
/// reads "2 issues · View".
struct Banner: View {
    var issues: [AppIssue]
    var onFix: (AppIssue) -> Void
    var onShowAll: () -> Void
    var onDismiss: ((AppIssue) -> Void)?

    var body: some View {
        if let first = issues.first {
            let tint = first.severity == .error ? Palette.error : Palette.needsYou
            HStack(spacing: Space.s) {
                Image(systemName: first.severity == .error ? StatusKind.error.symbol : "exclamationmark.circle.fill")
                    .foregroundStyle(tint)
                Text(issues.count > 1 ? "\(issues.count) issues · \(first.message)" : first.message)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Space.s)
                if issues.count > 1 {
                    Button("View", action: onShowAll).buttonStyle(.secondaryLink)
                } else if let title = first.fixTitle {
                    Button(title) { onFix(first) }.buttonStyle(.secondaryLink)
                }
                if let onDismiss, issues.count == 1 {
                    Button { onDismiss(first) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }
}

/// One button in the floating bulk action bar.
struct BulkAction: Identifiable {
    var id: String
    var title: String
    var symbol: String?
    var shortcut: AppShortcut?
    var isProminent = false
    var isDestructive = false
    /// Shown but not pressable (e.g. Approve while an approve is in flight).
    var isDisabled = false
    var action: () -> Void
}

/// Floating bulk-action bar (Review): "N selected", the actions (one primary pill), clear.
/// An optional accessory row (a confirmation question) sits above it.
struct BulkActionBar<Accessory: View>: View {
    var selectionCount: Int
    var actions: [BulkAction]
    var onClear: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    init(selectionCount: Int, actions: [BulkAction], onClear: @escaping () -> Void,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.selectionCount = selectionCount
        self.actions = actions
        self.onClear = onClear
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: Space.s) {
            accessory()
            GlassBar {
                HStack(spacing: Space.xs) {
                    Text("\(selectionCount)").font(Typography.metricSmall).numericRoll(Double(selectionCount))
                    Text("selected").font(Typography.body).foregroundStyle(Palette.textSecondary)
                }
                ForEach(actions) { action in
                    let label = HStack(spacing: Space.xs) {
                        if let symbol = action.symbol { Image(systemName: symbol) }
                        Text(action.title)
                        if let shortcut = action.shortcut { KeyCap(shortcut) }
                    }
                    if action.isProminent {
                        Button(action: action.action) { label }
                            .buttonStyle(.primaryPill)
                            .disabled(action.isDisabled)
                    } else {
                        Button(action: action.action) { label }
                            .buttonStyle(.secondaryLink)
                            .foregroundStyle(action.isDestructive ? Palette.error : Palette.accent)
                            .disabled(action.isDisabled)
                    }
                }
                Button(action: onClear) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Clear selection")
                    .accessibilityLabel("Clear selection")
            }
        }
    }
}

/// A confirmation question shown above the bulk bar: text, then its choices.
struct GlassBarPrompt<Actions: View>: View {
    var symbol: String?
    var message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        GlassBar {
            if let symbol { Image(systemName: symbol).foregroundStyle(Palette.needsYou) }
            Text(message).font(Typography.bodyEmph)
            actions()
        }
    }
}

/// "Paused · Resume ⇧⌘P" — floats over the live agent while paused.
struct PausedBar: View {
    var onResume: () -> Void

    var body: some View {
        GlassBar(interactive: true) {
            Label("Paused", systemImage: "pause.fill").font(Typography.bodyEmph)
            Button(action: onResume) {
                HStack(spacing: Space.xs) {
                    Text("Resume")
                    KeyCap(.togglePause)
                }
            }
            .buttonStyle(.secondaryLink)
            .font(Typography.bodyEmph)
        }
    }
}

#Preview("Glass bar") {
    VStack(spacing: Space.l) {
        Banner(issues: [AppIssue(id: "d", severity: .error, message: "Can't reach the agent.", fixTitle: "Restart agent", fix: .restartDaemon)],
               onFix: { _ in }, onShowAll: {})
        BulkActionBar(selectionCount: 2, actions: [
            BulkAction(id: "approve", title: "Approve & send", shortcut: .approve, isProminent: true) {},
            BulkAction(id: "skip", title: "Skip", shortcut: .skip) {},
        ], onClear: {})
        PausedBar {}
    }
    .padding()
    .frame(width: 640)
}
