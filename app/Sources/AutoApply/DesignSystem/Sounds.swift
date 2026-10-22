// Sounds.swift — short system sounds for the moments that deserve one (Settings ▸ General ▸ Sounds:
// Off · Moments only · All; docs/DESIGN_AWARD_VISION.md §7). Default "Moments only": an interview or
// offer landing, inbox zero and an easter egg found play a sound; routine cues (each answer, each
// card move, each approval) only play under "All". Nothing signals failure: `denied` is silent.
// Built-in macOS sounds only, played quietly; each cue is a fresh copy so quick repeats (heart taps)
// overlap instead of cutting each other off. The custom paper palette replaces these in Phase 3 (3A).
import AppKit

enum Sounds {
    /// Settings ▸ General ▸ Sounds.
    enum Level: String, CaseIterable, Identifiable, Sendable {
        case off
        case moments
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .moments: "Moments only"
            case .all: "All"
            }
        }
    }

    /// How loud a cue is allowed to be: a moment plays under Moments only and All; routine only under All.
    enum Kind: Sendable { case moment, routine, never }

    enum Cue: String, CaseIterable, Sendable {
        /// A light touch: heart taps, hints. Routine.
        case tap
        /// A card landing in a new column, an answer sent. Routine.
        case pop
        /// An application approved / handed to the agent. Routine.
        case send
        /// Interview, offer, inbox zero, an easter egg found. A moment.
        case celebrate
        /// Retired (§7.1: no sound signals failure). Kept so old call sites compile; never plays.
        case denied

        var kind: Kind {
            switch self {
            case .celebrate: .moment
            case .tap, .pop, .send: .routine
            case .denied: .never
            }
        }

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
            case .denied: 0
            }
        }
    }

    /// UserDefaults key for `Level` (raw value).
    static let levelKey = "soundLevel"
    /// The old "Play sounds" toggle (Bool, default on). Read only to migrate: off stays Off.
    static let legacyEnabledKey = GeneralSettings.soundsKey
    static let defaultLevel = Level.moments

    /// The saved level; with none saved, the old toggle decides (off → Off), else Moments only.
    static func level(in defaults: UserDefaults = .standard) -> Level {
        if let raw = defaults.string(forKey: levelKey), let level = Level(rawValue: raw) { return level }
        if let enabled = defaults.object(forKey: legacyEnabledKey) as? Bool, !enabled { return .off }
        return defaultLevel
    }

    static func shouldPlay(_ cue: Cue, at level: Level) -> Bool {
        switch (cue.kind, level) {
        case (.never, _), (_, .off): false
        case (.moment, _): true
        case (.routine, .all): true
        case (.routine, _): false
        }
    }

    /// Only the real app plays sounds (never tests / previews).
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @MainActor static func play(_ cue: Cue) {
        guard isAppBundle, shouldPlay(cue, at: level()),
              let sound = (NSSound(named: NSSound.Name(cue.systemName))?.copy() as? NSSound) else { return }
        sound.volume = cue.volume
        sound.play()
    }
}
