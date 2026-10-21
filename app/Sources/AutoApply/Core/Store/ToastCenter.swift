// ToastCenter.swift — queue-managed HUD toasts ("Copied · Years of experience", "Moved to
// Interview · Undo", "Daemon didn't respond"). Rendered by HUDToastHost in the shell.
import Foundation
import Observation

@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        enum Style: Sendable { case info, success, warning, error }

        let id = UUID()
        var message: String
        var symbol: String?
        var style: Style = .info
        var duration: Duration = .milliseconds(1200)
        var actionTitle: String?
        var action: (@MainActor () -> Void)?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private(set) var current: Toast?
    private(set) var queue: [Toast] = []
    private var dismissTask: Task<Void, Never>?

    init() {}

    func show(_ message: String, symbol: String? = nil, style: Toast.Style = .info,
              duration: Duration = .milliseconds(1200), actionTitle: String? = nil,
              action: (@MainActor () -> Void)? = nil) {
        enqueue(Toast(message: message, symbol: symbol, style: style, duration: duration, actionTitle: actionTitle, action: action))
    }

    func error(_ message: String) {
        show(message, symbol: "exclamationmark.triangle.fill", style: .error, duration: .seconds(3))
    }

    func enqueue(_ toast: Toast) {
        if current == nil {
            present(toast)
        } else if toast.action != nil, current?.action == nil {
            // A toast with an action (Undo) has a running clock: show it now, never behind an
            // informational one, so its whole window is visible.
            present(toast)
        } else {
            // Coalesce identical consecutive messages.
            if current?.message == toast.message || queue.last?.message == toast.message { return }
            queue.append(toast)
        }
    }

    /// Run the current toast's action (e.g. Undo) and dismiss it.
    func performAction() {
        let action = current?.action
        dismiss()
        action?()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
        if !queue.isEmpty {
            present(queue.removeFirst())
        }
    }

    private func present(_ toast: Toast) {
        current = toast
        dismissTask?.cancel()
        let id = toast.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: toast.duration)
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.dismiss()
        }
    }
}
