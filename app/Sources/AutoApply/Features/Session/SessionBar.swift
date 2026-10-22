// SessionBar.swift — the guided session's floating control: a slim Liquid Glass bar at the bottom
// of the window ("2 of 7 · Answer a question · about 1 min left · Skip · Next ⌘→ · End"). It is
// the control layer (GlassBar), never content. When the last item is done it morphs
// (glassEffectID) into "Done for today. The agent takes it from here." with one check draw-on;
// under Reduce Motion the two cross-fade. No continuous motion.
//
// `SessionHost` is the window's one overlay hook (RootView): it keeps the session in step with the
// stores (items finish when their work is done) and navigates to each item.
import SwiftUI

/// Overlay on the main window's detail column. Draws nothing when no session is running.
struct SessionHost: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        let session = SessionModel.shared(for: store)
        let open: Set<SessionItem.Key> = session.isActive ? Set(SessionSources.live(store: store).items.map(\.key)) : []
        SessionBar(session: session, escapeEnabled: !store.router.isPalettePresented && !store.router.isInspectorPresented)
            // Lift above a toast so the two never overlap.
            .padding(.bottom, store.toasts.current == nil ? Space.xl : Space.xl + 52)
            .padding(.horizontal, Space.l)
            .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: store.toasts.current == nil)
            // Floating chrome: its own primary never counts against the screen underneath.
            .environment(\.prominenceAudit, nil)
            .onChange(of: open) { _, keys in session.reconcile(open: keys) }
            .onChange(of: session.navigationSerial) {
                if let item = session.current { SessionNavigator.show(item, store: store) }
            }
            .task(id: session.doneSerial) {
                // The "Done for today" moment rests a few seconds, then gets out of the way.
                guard session.phase == .done else { return }
                try? await Task.sleep(for: .seconds(6))
                if session.phase == .done { session.dismissDone() }
            }
    }
}

/// The bar itself (rendered on its own in tests).
struct SessionBar: View {
    var session: SessionModel
    /// Esc ends the session unless the palette or the details panel is open (Esc closes those).
    var escapeEnabled = true

    @Environment(\.motionReduced) private var reduced
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            ZStack {
                switch session.phase {
                case .active:
                    if let item = session.current {
                        activeBar(item)
                            .glassEffectID("session", in: glass)
                            .transition(.reduced(.slideIn(from: .bottom), reduced))
                    }
                case .done:
                    doneBar
                        .glassEffectID("session", in: glass)
                        .transition(.opacity)
                case .idle:
                    EmptyView()
                }
            }
        }
        .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: session.phase)
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: session.index)
    }

    private func activeBar(_ item: SessionItem) -> some View {
        GlassBar(interactive: true) {
            HStack(spacing: Space.s) {
                Text(session.progressLabel)
                    .font(Typography.metricSmall)
                    .contentTransition(.numericText(value: Double(session.position)))
                Text("·").foregroundStyle(Palette.textTertiary)
                Label(item.kind.stepTitle, systemImage: item.kind.symbol)
                    .font(Typography.bodyEmph)
                    .lineLimit(1)
                    .help(item.subject)
                Text("·").foregroundStyle(Palette.textTertiary)
                Text(session.remainingLabel)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .help("Time left is an estimate")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(session.position) of \(session.total): \(item.kind.stepTitle). \(item.subject). \(session.remainingLabel), estimated.")

            Button("Skip") { session.skip() }
                .buttonStyle(.secondaryLink)
                .font(Typography.bodyEmph)
                .help("Leave this one for later")
            Button {
                session.next()
            } label: {
                HStack(spacing: Space.xs) {
                    Text("Next")
                    KeyCap("⌘→")
                }
            }
            .buttonStyle(.primaryPill)
            .controlSize(.small)
            .help("Done with this one: go to the next (⌘→)")
            endButton
        }
    }

    private var endButton: some View {
        Button("End") { session.end() }
        .modifier(EscapeShortcut(enabled: escapeEnabled))
        .buttonStyle(.secondaryLink)
        .font(Typography.bodyEmph)
        .foregroundStyle(Palette.textSecondary)
        .help("End the session (Esc). Anything left stays where it is.")
    }

    private var doneBar: some View {
        GlassBar(interactive: true) {
            SubmittedCheck(trigger: session.doneSerial, color: Palette.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Done for today.").font(Typography.bodyEmph)
                Text(session.doneMessage).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Button {
                session.dismissDone()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .modifier(EscapeShortcut(enabled: escapeEnabled))
            .help("Close")
            .accessibilityLabel("Close")
        }
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Esc for the bar's End / Close, only while nothing else (⌘K, the details panel) wants Esc.
private struct EscapeShortcut: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.cancelAction) } else { content }
    }
}
