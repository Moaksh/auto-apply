// Sounds.swift — short system sounds for the moments that deserve one (Settings ▸ General ▸
// Play sounds). Built-in macOS sounds only, played quietly; each cue is a fresh copy so quick
// repeats (heart taps) overlap instead of cutting each other off.
import AppKit

enum Sounds {
    enum Cue: String, CaseIterable, Sendable {
        /// A light touch: heart taps, hints.
        case tap
        /// A card landing in a new column, an answer sent.
        case pop
        /// An application approved / handed to the agent.
        case send
        /// Interview, offer, inbox zero, an easter egg found.
        case celebrate
        /// "Permission denied" (sudo apply).
        case denied

        /// System sound name (/System/Library/Sounds).
        var systemName: String {
            switch self {
            case .tap: "Tink"
            case .pop: "Pop"
            case .send: "Purr"
            case .celebrate: "Glass"
            case .denied: "Basso"
            }
        }

        var volume: Float {
            switch self {
            case .tap: 0.35
            case .pop, .send: 0.45
            case .celebrate: 0.5
            case .denied: 0.4
            }
        }
    }

    /// On unless the user turned "Play sounds" off. Only the real app plays them (never tests / previews).
    static var isEnabled: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && (UserDefaults.standard.object(forKey: GeneralSettings.soundsKey) as? Bool ?? true)
    }

    @MainActor static func play(_ cue: Cue) {
        guard isEnabled, let sound = (NSSound(named: NSSound.Name(cue.systemName))?.copy() as? NSSound) else { return }
        sound.volume = cue.volume
        sound.play()
    }
}
