// EasterEggs.swift — small surprises for new people: the Konami code (↑↑↓↓←→←→BA), a few
// secret phrases in the ⌘K palette, and the heart in the Settings footer. Each one plays a
// "moment" (a glass reveal card + a flavored animation, see EasterEggOverlay.swift) and
// counts toward "secrets found"; typing "secret" in ⌘K offers a riddle for the next one.
// All harmless: nothing here touches jobs, settings, the daemon or the network.
import AppKit
import SwiftUI

enum EasterEggs {
    static let momentNotification = Notification.Name("AutoApply.easterEggMoment")

    // MARK: Flavors

    /// Every secret. Case order is also the order hints are handed out (easiest first).
    enum Flavor: String, CaseIterable, Sendable {
        case heart, wave, coffee, answer, hire, sudo, maker, konami

        /// The riddle "secret" offers while this one is still unfound.
        var riddle: String {
            switch self {
            case .heart: "The heart at the bottom of Settings likes attention. Lots of it."
            case .wave: "Greet the palette the way a Jedi would."
            case .coffee: "The agent runs on tokens. What do you run on?"
            case .answer: "Ask for the answer to life, the universe and everything."
            case .hire: "Say the thing every job hunter wants to say to a recruiter."
            case .sudo: "Try applying with superuser powers."
            case .maker: "Type the name of the person who made this."
            case .konami: "Some codes never die: ↑ ↑ ↓ ↓ … (anywhere in the main window)"
            }
        }

        var script: Script {
            switch self {
            case .heart:
                Script(headline: "Seven beats!", line: "You found the heart. Moaksh says hi. Go land that job.",
                       symbol: "heart.fill", tone: .love, burst: .hearts)
            case .wave:
                Script(headline: "General Kenobi!", line: "A bold one. Your applications are in good hands.",
                       symbol: "hand.wave.fill", tone: .accent, burst: .none)
            case .coffee:
                Script(headline: "Brewing…", line: "The agent runs on tokens. You run on this. Fair trade.",
                       symbol: "cup.and.saucer.fill", tone: .amber, burst: .none)
            case .answer:
                Script(headline: "Don't panic.", line: "The answer to life, the universe and job hunting. Bring a towel.",
                       symbol: "sparkles", tone: .cosmic, burst: .stars, mono: "> 42")
            case .hire:
                Script(headline: "Consider it done.", line: "The agent heard you. It's already on it.",
                       symbol: "briefcase.fill", tone: .mint, burst: .cannon)
            case .sudo:
                Script(headline: "Permission denied.", line: "Nice try. Even root waits for your review.",
                       symbol: "lock.fill", tone: .alert, burst: .none, mono: "$ sudo apply")
            case .maker:
                Script(headline: "Hi, it's me.", line: "Made with love by Moaksh Kakkar. Thanks for using AutoApply!",
                       symbol: "heart.fill", tone: .love, burst: .hearts)
            case .konami:
                Script(headline: "You found the secret", line: "+30 lives for your job hunt. The agent applies with extra style.",
                       symbol: "gamecontroller.fill", tone: .gold, burst: .storm, mono: "↑ ↑ ↓ ↓ ← → ← → B A")
            }
        }
    }

    /// What a moment says and how it looks.
    struct Script: Sendable, Equatable {
        var headline: String
        var line: String
        var symbol: String
        var tone: Tone
        var burst: Burst
        var mono: String?
    }

    /// Card tint family (resolved to Palette tokens in the overlay).
    enum Tone: Sendable, Equatable { case accent, love, amber, cosmic, mint, alert, gold }

    /// Particle effect played with a moment.
    enum Burst: Sendable, Equatable {
        case none
        /// Paper falling from the top edge.
        case rain
        /// One cone of confetti fired upward from the trigger point.
        case cannon
        /// Rain plus two corner cannons — the big one.
        case storm
        /// Hearts (and a little confetti) floating up from the trigger point.
        case hearts
        /// A slow twinkle of stars from the trigger point.
        case stars
    }

    /// One played surprise, as posted to the overlays.
    struct Moment: Sendable, Equatable, Identifiable {
        let id = UUID()
        var flavor: Flavor?
        var eyebrow: String
        var script: Script
        var found: Int
        var total: Int
        var isNew: Bool
        /// Where the trigger happened, in window (`.global`) coordinates; nil = under the card.
        var origin: CGPoint?
        var duration: Double = 4.5
    }

    // MARK: Discoveries

    /// Which secrets this Mac has found (pure; persisted by `discoveries`).
    struct Discoveries: Sendable, Equatable {
        private(set) var found: Set<Flavor> = []

        init(found: Set<Flavor> = []) { self.found = found }

        /// Records a find; true the first time.
        mutating func record(_ flavor: Flavor) -> Bool { found.insert(flavor).inserted }

        var count: Int { found.count }
        var total: Int { Flavor.allCases.count }
        var isComplete: Bool { count == total }

        /// The riddle for the first unfound secret, nil once everything is found.
        var nextHint: String? { Flavor.allCases.first { !found.contains($0) }?.riddle }

        func eyebrow(for flavor: Flavor, isNew: Bool) -> String {
            if isNew && isComplete { return "All secrets found" }
            if flavor == .konami { return isNew ? "Achievement unlocked" : "Achievement" }
            return isNew ? "New secret" : "Secret"
        }
    }

    private static let foundKey = "easterEggs.found"

    @MainActor static var discoveries: Discoveries {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: foundKey) ?? []
            return Discoveries(found: Set(raw.compactMap(Flavor.init(rawValue:))))
        }
        set { UserDefaults.standard.set(newValue.found.map(\.rawValue).sorted(), forKey: foundKey) }
    }

    /// Plays `flavor`: records it, posts the moment, taps the trackpad and tells VoiceOver.
    @MainActor
    static func reveal(_ flavor: Flavor, origin: CGPoint? = nil) {
        var d = discoveries
        let isNew = d.record(flavor)
        discoveries = d
        var script = flavor.script
        if isNew && d.isComplete { script.burst = .storm }
        post(Moment(flavor: flavor, eyebrow: d.eyebrow(for: flavor, isNew: isNew), script: script,
                    found: d.count, total: d.total, isNew: isNew, origin: origin))
        if flavor == .sudo { Haptics.generic() } else { Haptics.levelChange() }
        Sounds.play(flavor == .sudo ? .denied : .celebrate)
    }

    /// The "secret" palette row: progress plus a riddle (no discovery recorded).
    @MainActor
    static func revealHint() {
        let d = discoveries
        let script = Script(headline: d.isComplete ? "You found them all." : "A little birdie says…",
                            line: d.nextHint ?? "Every secret, found. Moaksh is genuinely impressed.",
                            symbol: d.isComplete ? "trophy.fill" : "bubble.left.and.text.bubble.right.fill",
                            tone: d.isComplete ? .gold : .accent, burst: d.isComplete ? .stars : .none)
        post(Moment(flavor: nil, eyebrow: "Secrets", script: script, found: d.count, total: d.total, isNew: false,
                    origin: nil, duration: 6))
        Haptics.alignment()
        Sounds.play(.tap)
    }

    @MainActor
    private static func post(_ moment: Moment) {
        NotificationCenter.default.post(name: momentNotification, object: moment)
        AccessibilityNotification.Announcement("\(moment.script.headline) \(moment.script.line)").post()
    }

    /// Overlays in several windows (or nested in one) all hear a moment; the first active one claims it.
    @MainActor private static var lastClaimed: UUID?

    @MainActor
    static func claim(_ id: UUID) -> Bool {
        guard lastClaimed != id else { return false }
        lastClaimed = id
        return true
    }

    // MARK: Konami code

    /// ↑ ↑ ↓ ↓ ← → ← → B A, as macOS key codes.
    static let konami: [UInt16] = [126, 126, 125, 125, 123, 124, 123, 124, 11, 0]

    /// Feeds key codes in and reports when the full sequence was typed (pure; tested).
    struct SequenceMatcher {
        let target: [UInt16]
        private(set) var progress = 0

        init(_ target: [UInt16]) { self.target = target }

        mutating func feed(_ code: UInt16) -> Bool {
            if code == target[progress] {
                progress += 1
            } else {
                progress = code == target[0] ? 1 : 0
            }
            if progress == target.count {
                progress = 0
                return true
            }
            return false
        }
    }

    @MainActor private static var monitor: Any?
    @MainActor private static var matcher = SequenceMatcher(konami)

    /// Watches key presses (never swallows them) for the Konami code.
    @MainActor
    static func installKonami() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if matcher.feed(event.keyCode) { reveal(.konami) }
            return event
        }
    }

    // MARK: Palette phrases

    struct Phrase: Sendable {
        var trigger: String
        var title: String
        var flavor: Flavor
        var symbol: String { flavor.script.symbol }
    }

    static let phrases: [Phrase] = [
        Phrase(trigger: "hire me", title: "Hire me", flavor: .hire),
        Phrase(trigger: "coffee", title: "Coffee", flavor: .coffee),
        Phrase(trigger: "42", title: "42", flavor: .answer),
        Phrase(trigger: "sudo apply", title: "sudo apply", flavor: .sudo),
        Phrase(trigger: "hello there", title: "Hello there", flavor: .wave),
        Phrase(trigger: "moaksh", title: "Moaksh", flavor: .maker),
    ]

    /// Queries that answer with the hint row.
    static let hintTriggers: Set<String> = ["secret", "secrets", "easter egg", "easter eggs", "psst"]
    static let hintTrigger = "secret"

    /// Lowercased, whitespace-collapsed.
    static func normalize(_ query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The phrase typed exactly (case and extra spaces ignored), if any.
    static func phrase(for query: String) -> Phrase? {
        let q = normalize(query)
        return phrases.first { $0.trigger == q }
    }

    /// A palette row for a secret phrase or the hint query (pure; tested).
    struct PaletteRow: Sendable, Equatable {
        var trigger: String
        var title: String
        var subtitle: String
        var symbol: String
    }

    static func paletteRow(for query: String, discoveries: Discoveries) -> PaletteRow? {
        if let p = phrase(for: query) {
            let seen = discoveries.found.contains(p.flavor)
            return PaletteRow(trigger: p.trigger, title: p.title, subtitle: seen ? "Psst… again?" : "Psst…", symbol: p.symbol)
        }
        guard hintTriggers.contains(normalize(query)) else { return nil }
        let title = discoveries.isComplete ? "All \(discoveries.total) secrets found" : "Secrets found: \(discoveries.count) of \(discoveries.total)"
        return PaletteRow(trigger: hintTrigger, title: title, subtitle: discoveries.isComplete ? "Show-off." : "Want a hint?",
                          symbol: "eyes")
    }

    @MainActor
    static func paletteRow(for query: String) -> PaletteRow? { paletteRow(for: query, discoveries: discoveries) }

    /// Runs a palette row picked by trigger.
    @MainActor
    static func play(trigger: String) {
        if trigger == hintTrigger {
            revealHint()
        } else if let p = phrases.first(where: { $0.trigger == trigger }) {
            reveal(p.flavor)
        }
    }

    // MARK: Heart meter

    /// Escalation for the Settings heart: seven taps (no pause over `cooldown`) burst it (pure; tested).
    enum HeartMeter {
        static let tapsToBurst = 7
        static let cooldown: Duration = .milliseconds(2500)

        /// Grows a little each tap, then pops back once it bursts.
        static func scale(taps: Int) -> Double { 1 + 0.08 * Double(min(max(taps, 0), tapsToBurst - 1)) }
        /// Color strength: a soft heart at rest, fully saturated just before it bursts.
        static func intensity(taps: Int) -> Double { 0.55 + 0.45 * Double(min(max(taps, 0), tapsToBurst - 1)) / Double(tapsToBurst - 1) }
        /// The playful count shown next to the heart from the second tap.
        static func badge(taps: Int) -> String? { taps >= 2 && taps < tapsToBurst ? "×\(taps)" : nil }
    }
}
