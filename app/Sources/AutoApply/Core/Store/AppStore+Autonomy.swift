// AppStore+Autonomy.swift — earned autonomy (contract/protocol.md §5.3.1). Auto is offered per
// application site after a run of approvals without edits; it is never switched on by itself, and
// every mode stays the user's choice (Settings ▸ Modes) at any level, at any time.
import Foundation

extension AppStore {
    /// Per-site trust and suggestion state (`get_autonomy`). Stored in `autonomy` for Settings ▸ Modes.
    @discardableResult
    func fetchAutonomy() async -> AutonomyReport? {
        let report = await performResult(.getAutonomy(GetAutonomyPayload()), as: AutonomyReport.self, timeout: .seconds(10), silent: true)
        if let report { autonomy = report }
        return report
    }

    /// "Turn on Auto for <site>": the existing `update_preferences` with the merged per-site map.
    @discardableResult
    func turnOnAuto(for ats: Ats) async -> Bool {
        var map = preferences.perAtsMode
        let old = map
        map[ats.rawValue] = .auto
        var patch = PreferencesPatch()
        try? patch.set(.perAtsMode, map)
        let ok = await updatePreferences(patch, optimistic: { $0.perAtsMode = map }, rollback: { $0.perAtsMode = old })
        if ok {
            toasts.show("\(ats.label) jobs now send on their own · change it any time in Settings ▸ Modes",
                        symbol: "checkmark.circle", style: .success, duration: .seconds(3))
        }
        await fetchAutonomy()
        return ok
    }

    /// "Not now": the site is not offered again. Any mode can still be chosen in Settings.
    @discardableResult
    func dismissAutonomySuggestion(_ ats: Ats) async -> Bool {
        if case .success = await perform(.dismissAutonomySuggestion(DismissAutonomySuggestionPayload(ats: ats)), silent: true) {
            await fetchAutonomy()
            return true
        }
        return false
    }

    /// The one-time offer, as a calm toast with two quiet choices.
    func presentAutonomySuggestion(_ p: AutonomySuggestionPayload) {
        let site = p.ats.label
        toasts.enqueue(ToastCenter.Toast(
            message: "\(p.cleanApprovals) \(site) applications approved without changes",
            symbol: "checkmark.seal", style: .info, duration: .seconds(12),
            actionTitle: "Turn on Auto for \(site)",
            action: { [weak self] in Task { await self?.turnOnAuto(for: p.ats) } },
            secondaryTitle: "Not now",
            secondaryAction: { [weak self] in Task { await self?.dismissAutonomySuggestion(p.ats) } }))
        Task { [weak self] in await self?.fetchAutonomy() }
    }
}
