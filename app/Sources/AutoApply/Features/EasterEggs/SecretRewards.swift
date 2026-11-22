// SecretRewards.swift — what finding every easter egg unlocks: the accent pad and the Midnight
// Gold app icon, both in Settings ▸ General. Before that, the row there says how many are left.
import AppKit
import Observation

@MainActor
@Observable
final class SecretRewards {
    static let shared = SecretRewards()
    static let iconKey = "appIcon.choice"

    enum Icon: String, CaseIterable, Identifiable, Sendable {
        case standard, midnightGold
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "AutoApply"
            case .midnightGold: "Midnight Gold"
            }
        }
    }

    /// Mirrors `EasterEggs.discoveries` so Settings updates the moment the last secret is found.
    private(set) var found: Int
    let total = EasterEggs.Flavor.allCases.count
    private(set) var icon: Icon

    @ObservationIgnored var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        found = EasterEggs.discoveries.count
        icon = defaults.string(forKey: Self.iconKey).flatMap(Icon.init(rawValue:)) ?? .standard
    }

    var isUnlocked: Bool { found >= total }

    func refresh() { found = EasterEggs.discoveries.count }

    func setIcon(_ new: Icon) {
        guard isUnlocked || new == .standard else { return }
        icon = new
        defaults.set(new.rawValue, forKey: Self.iconKey)
        applyIcon()
    }

    /// Sets the Dock icon. At launch and after every change; `nil` falls back to the bundle's icon.
    func applyIcon() {
        NSApplication.shared.applicationIconImage = isUnlocked && icon == .midnightGold ? SecretIcon.image : nil
    }
}
