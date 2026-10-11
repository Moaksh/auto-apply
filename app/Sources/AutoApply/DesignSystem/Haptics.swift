// Haptics.swift — trackpad haptics (§6). Toggle: Settings ▸ General ▸ Haptics (default on).
import AppKit

enum Haptics {
    static let settingsKey = "hapticsEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }

    /// Snapping chart scrub to a day, threshold rule snapping, kanban insertion slot changing.
    @MainActor static func alignment() { perform(.alignment) }
    /// Successful drop on a new column, inbox zero, toggling Pause.
    @MainActor static func levelChange() { perform(.levelChange) }
    /// Drag entering a drop zone (resume upload, kanban column).
    @MainActor static func generic() { perform(.generic) }

    @MainActor private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
