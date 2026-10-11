// Overlays.swift — HUDToast (+ host), Banner (single global issue), BulkActionBar
// (floating glass, morphing), PausedOverlay.
import SwiftUI

/// Glass capsule toast.
struct HUDToast: View {
    var toast: ToastCenter.Toast
    var onAction: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            if let symbol = toast.symbol {
                Image(systemName: symbol).foregroundStyle(iconColor)
            }
            Text(toast.message).font(Typography.bodyEmph)
            if let actionTitle = toast.actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.plain)
                    .font(Typography.bodyEmph)
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .glassCapsule(tint: Palette.accent.opacity(0.15))
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

/// Bottom-centered toast presenter; attach once per window.
struct HUDToastHost: ViewModifier {
    var center: ToastCenter
    @Environment(\.motionReduced) private var reduced

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let toast = center.current {
                    HUDToast(toast: toast) { center.performAction() }
                        .id(toast.id)
                        .transition(reduced ? .opacity : .move(edge: .bottom).combined(with: .opacity))
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

/// The single global banner (§4.4): amber or red tint, one sentence, one fix button.
/// With several issues it reads "2 issues · View".
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
                    Button("View", action: onShowAll).buttonStyle(.glass)
                } else if let title = first.fixTitle {
                    Button(title) { onFix(first) }.buttonStyle(.glass)
                }
                if let onDismiss, issues.count == 1 {
                    Button { onDismiss(first) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
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

/// Floating glass action bar (Review queue): appears when ≥ 1 item is selected; buttons morph
/// in/out with `glassEffectID` as the selection changes; the count rolls.
struct BulkActionBar<Accessory: View>: View {
    var selectionCount: Int
    var actions: [BulkAction]
    var onClear: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @Namespace private var glassNS

    init(selectionCount: Int, actions: [BulkAction], onClear: @escaping () -> Void,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.selectionCount = selectionCount
        self.actions = actions
        self.onClear = onClear
        self.accessory = accessory
    }

    var body: some View {
        GlassEffectContainer(spacing: Space.s) {
            VStack(spacing: Space.s) {
                accessory()
                HStack(spacing: Space.s) {
                    HStack(spacing: Space.xs) {
                        Text("\(selectionCount)").font(Typography.metricSmall).numericRoll(Double(selectionCount))
                        Text("selected").font(Typography.body)
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .glassEffect(.regular, in: Capsule())
                    .glassEffectID("count", in: glassNS)

                    ForEach(actions) { action in
                        Button(action: action.action) {
                            HStack(spacing: Space.xs) {
                                if let symbol = action.symbol { Image(systemName: symbol) }
                                Text(action.title)
                                if let shortcut = action.shortcut { KeyCap(shortcut) }
                            }
                        }
                        .buttonStyle(action.isProminent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                        .tint(action.isDestructive ? Palette.error : nil)
                        .disabled(action.isDisabled)
                        .glassEffectID(action.id, in: glassNS)
                    }

                    Button(action: onClear) { Image(systemName: "xmark") }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Clear selection")
                        .glassEffectID("clear", in: glassNS)
                }
            }
        }
        .motion(Motion.snappy, value: actions.map(\.id))
    }
}

/// Type-erased primitive button style so a conditional can choose between glass styles.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// "Paused · Resume ⌘⇧P" glass capsule (hero, menu bar).
struct PausedCapsule: View {
    var onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: Space.s) {
                Image(systemName: "pause.fill")
                Text("Paused")
                Text("·").foregroundStyle(Palette.textTertiary)
                Text("Resume")
                KeyCap(.togglePause)
            }
            .font(Typography.bodyEmph)
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
    }
}

#Preview("Overlays") {
    VStack(spacing: Space.l) {
        Banner(issues: [AppIssue(id: "d", severity: .error, message: "Can't reach autoapplyd.", fixTitle: "Restart daemon", fix: .restartDaemon)],
               onFix: { _ in }, onShowAll: {})
        BulkActionBar(selectionCount: 2, actions: [
            BulkAction(id: "approve", title: "Approve & submit", shortcut: .approve, isProminent: true) {},
            BulkAction(id: "skip", title: "Skip", shortcut: .skip) {},
        ], onClear: {})
        PausedCapsule {}
    }
    .padding()
    .frame(width: 640)
}
