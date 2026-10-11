// WindowVisibility.swift — pauses Canvas/TimelineView work when the hosting window is
// occluded or the app is hidden (§2.7 "Charts and the Canvas pause when the window is
// occluded"). Used by the Dashboard hero and heatmap.
import AppKit
import SwiftUI

private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            guard let window else { return }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible) && !NSApp.isHidden
            onChange?(visible)
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

extension View {
    /// Keeps `isVisible` in sync with the hosting window's occlusion state.
    func trackWindowVisibility(_ isVisible: Binding<Bool>) -> some View {
        background(WindowVisibilityReader(isVisible: isVisible).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
