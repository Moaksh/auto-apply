// PaletteModel.swift — Raycast-style ⌘K palette logic (docs/UI_UX_PLAN.md §3.3): fuzzy search
// across jobs, inbox questions, stories, settings keys and actions; scope prefixes (`>`
// actions, `@` companies, `?` inbox questions, `/` settings); inline result actions (↵ open,
// ⌘↵ open posting in the browser, ⌥↵ show in Pipeline).
import AppKit
import Foundation
import Observation

/// Subsequence fuzzy matcher with word-boundary, prefix and contiguity bonuses.
enum FuzzyMatcher {
    /// nil when `query` isn't a (case-insensitive) subsequence of `candidate`; higher is better.
    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        let original = Array(candidate)
        var qi = 0
        var score = 0
        var lastMatch = -2
        var firstMatch: Int?
        for (ci, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var bonus = 1
            let atBoundary = ci == 0 || !c[ci - 1].isLetter && !c[ci - 1].isNumber || (original[ci].isUppercase && ci > 0 && original[ci - 1].isLowercase)
            if atBoundary { bonus += 8 }
            if lastMatch == ci - 1 { bonus += 5 }
            if ci == 0 { bonus += 6 }
            score += bonus
            if firstMatch == nil { firstMatch = ci }
            lastMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Whole-substring hits beat scattered ones; shorter candidates beat longer ones.
        let needle = String(q)
        if candidate.lowercased().replacingOccurrences(of: " ", with: "").contains(needle) { score += 10 }
        if candidate.lowercased().hasPrefix(query.lowercased()) { score += 15 }
        score -= min(20, c.count / 8)
        score -= min(10, firstMatch ?? 0)
        return score
    }
}

enum PaletteScope: Equatable, Sendable {
    case all, actions, companies, questions, settings

    /// Split "> pause" into (.actions, "pause").
    static func parse(_ raw: String) -> (scope: PaletteScope, text: String) {
        let trimmed = raw.drop { $0 == " " }
        guard let first = trimmed.first else { return (.all, "") }
        let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch first {
        case ">": return (.actions, rest)
        case "@": return (.companies, rest)
        case "?": return (.questions, rest)
        case "/": return (.settings, rest)
        default: return (.all, String(trimmed).trimmingCharacters(in: .whitespaces))
        }
    }

    var placeholder: String {
        switch self {
        case .all: "Search jobs, questions, stories, settings and actions"
        case .actions: "Actions"
        case .companies: "Companies"
        case .questions: "Inbox questions"
        case .settings: "Settings"
        }
    }
}

/// A settings key searchable from the palette ("salary floor" → Preferences tab).
struct PaletteSettingEntry: Sendable, Hashable {
    var title: String
    var keywords: String
    var tab: SettingsTab
    var key: String

    static let all: [PaletteSettingEntry] = [
        .init(title: "Roles", keywords: "job titles", tab: .preferences, key: "roles"),
        .init(title: "Seniority", keywords: "level junior senior staff", tab: .preferences, key: "seniority"),
        .init(title: "Locations & remote policy", keywords: "city remote hybrid onsite", tab: .preferences, key: "locations"),
        .init(title: "Salary floor", keywords: "minimum pay compensation currency", tab: .preferences, key: "salary_floor"),
        .init(title: "Excluded companies & keywords", keywords: "exclude blocklist industries", tab: .preferences, key: "exclude_companies"),
        .init(title: "Match threshold", keywords: "score minimum", tab: .preferences, key: "match_threshold"),
        .init(title: "Never-guess facts", keywords: "sponsorship visa salary expectation notice start relocation eeo", tab: .guardrails, key: "never_guess"),
        .init(title: "Ask confidence", keywords: "strict balanced lenient confidence threshold", tab: .guardrails, key: "ask_confidence"),
        .init(title: "Always-ask patterns", keywords: "always ask questions", tab: .guardrails, key: "always_ask_patterns"),
        .init(title: "Global mode", keywords: "auto review autonomy", tab: .modes, key: "mode"),
        .init(title: "Per-ATS modes", keywords: "greenhouse lever ashby workday override", tab: .modes, key: "per_ats_mode"),
        .init(title: "Per-company modes", keywords: "company override", tab: .modes, key: "per_company_mode"),
        .init(title: "Sources", keywords: "linkedin glassdoor greenhouse lever ashby career pages", tab: .sources, key: "sources_enabled"),
        .init(title: "Career page URLs", keywords: "careers websites", tab: .sources, key: "career_page_urls"),
        .init(title: "Run schedule", keywords: "times hours when runs", tab: .schedule, key: "schedule"),
        .init(title: "Daily cap", keywords: "limit applications per day", tab: .schedule, key: "daily_cap"),
        .init(title: "Agents at once", keywords: "parallel concurrent applications simultaneous agents", tab: .schedule, key: "parallel_applications"),
        .init(title: "Per-company cooldown", keywords: "days company", tab: .schedule, key: "per_company_cooldown_days"),
        .init(title: "Auto-ghost & nudges", keywords: "ghosted heard back follow up days", tab: .schedule, key: "ghost_after_days"),
        .init(title: "Notifications", keywords: "alerts notify", tab: .general, key: "notifications"),
        .init(title: "Show in Dock / launch at login", keywords: "dock login startup menu bar", tab: .general, key: "show_in_dock"),
        .init(title: "Haptics & sounds", keywords: "feedback trackpad", tab: .general, key: "haptics"),
        .init(title: "Daemon status", keywords: "autoapplyd launchagent restart install", tab: .agent, key: "daemon"),
        .init(title: "Export tracker CSV", keywords: "export data csv backup", tab: .data, key: "export"),
    ]
}

struct PaletteItem: Identifiable, Hashable, Sendable {
    enum Section: String, CaseIterable, Sendable {
        case jobs, questions, stories, settings, actions, navigate

        var title: String {
            switch self {
            case .jobs: "Jobs"
            case .questions: "Inbox"
            case .stories: "Stories"
            case .settings: "Settings"
            case .actions: "Actions"
            case .navigate: "Navigate"
            }
        }
    }

    enum Kind: Hashable, Sendable {
        case job(Int)
        case question(String)
        case story(Int)
        case setting(SettingsTab, String)
        case action(AppAction)
        case easterEgg(String)
    }

    var id: String
    var section: Section
    var kind: Kind
    var title: String
    var subtitle: String?
    var symbol: String
    var trailing: String?
    var shortcut: AppShortcut?
    var statusKind: StatusKind?
    var score: Int
}

@MainActor
@Observable
final class PaletteModel {
    let store: AppStore
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Per-section caps so one section can't drown the rest.
    static let limits: [PaletteItem.Section: Int] = [.jobs: 6, .questions: 5, .stories: 4, .settings: 5, .actions: 8, .navigate: 9]

    init(store: AppStore) {
        self.store = store
    }

    var scope: PaletteScope { PaletteScope.parse(query).scope }

    // MARK: Results

    var results: [PaletteItem] {
        let (scope, text) = PaletteScope.parse(query)
        var items: [PaletteItem] = []
        if scope == .all || scope == .companies { items += jobItems(text, companiesOnly: scope == .companies) }
        if scope == .all || scope == .questions { items += questionItems(text) }
        if scope == .all { items += storyItems(text) }
        if scope == .all || scope == .settings { items += settingItems(text) }
        if scope == .all || scope == .actions { items += actionItems(text) }
        if let egg = EasterEggs.phrase(for: text) {
            items.append(PaletteItem(id: "egg.\(egg.trigger)", section: .actions, kind: .easterEgg(egg.trigger), title: egg.title,
                                     subtitle: "Psst…", symbol: egg.symbol, trailing: nil, score: 10_000))
        }
        // Group by section (fixed order), best first within a section, capped.
        var out: [PaletteItem] = []
        for section in PaletteItem.Section.allCases {
            let inSection = items.filter { $0.section == section }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }
            out += inSection.prefix(Self.limits[section] ?? 6)
        }
        // With a query, put the section holding the single best hit first.
        if !text.isEmpty, let best = out.max(by: { $0.score < $1.score }) {
            out = out.filter { $0.section == best.section } + out.filter { $0.section != best.section }
        }
        return out
    }

    var selectedItem: PaletteItem? {
        let r = results
        return r.indices.contains(selection) ? r[selection] : nil
    }

    func moveSelection(by delta: Int) {
        let count = results.count
        guard count > 0 else { selection = 0; return }
        selection = (selection + delta + count) % count
    }

    private func jobItems(_ text: String, companiesOnly: Bool) -> [PaletteItem] {
        guard !text.isEmpty else { return [] }
        let threshold = store.preferences.matchThreshold
        var out: [PaletteItem] = []
        for job in store.jobs.all {
            let s = companiesOnly ? FuzzyMatcher.score(text, job.company) : max(FuzzyMatcher.score(text, job.company) ?? Int.min,
                                                                                 FuzzyMatcher.score(text, job.title) ?? Int.min,
                                                                                 FuzzyMatcher.score(text, job.displayName) ?? Int.min)
            guard let s, s != Int.min else { continue }
            out.append(PaletteItem(id: "job.\(job.id)", section: .jobs, kind: .job(job.id), title: job.displayName,
                                   subtitle: job.location, symbol: "briefcase", trailing: jobTrailing(job, threshold: threshold),
                                   statusKind: StatusKind(job: job), score: s))
        }
        return out
    }

    private func jobTrailing(_ job: JobItem, threshold: Int) -> String {
        if job.state == .submitted {
            let label = (job.status ?? .applied).label
            if let days = job.daysSinceSubmitted() { return "\(label) · \(days)d" }
            return label
        }
        if job.state == .skipped, let score = job.score { return "Skipped (\(score))" }
        return job.state.label
    }

    private func questionItems(_ text: String) -> [PaletteItem] {
        store.inbox.clusters.compactMap { c in
            let s = text.isEmpty ? 0 : (FuzzyMatcher.score(text, c.canonicalQuestion) ?? c.variants.compactMap { FuzzyMatcher.score(text, $0) }.max())
            guard let s else { return nil }
            return PaletteItem(id: "q.\(c.clusterId)", section: .questions, kind: .question(c.clusterId), title: c.canonicalQuestion,
                               subtitle: nil, symbol: "hand.raised.fill", trailing: C3Format.plural(c.jobCount, "job"),
                               statusKind: .needsYou, score: s + c.jobCount)
        }
    }

    private func storyItems(_ text: String) -> [PaletteItem] {
        guard !text.isEmpty else { return [] }
        return store.library.stories.compactMap { story in
            let s = FuzzyMatcher.score(text, story.title) ?? story.tags.compactMap { FuzzyMatcher.score(text, $0) }.max().map { $0 - 5 }
            guard let s else { return nil }
            return PaletteItem(id: "story.\(story.id)", section: .stories, kind: .story(story.id), title: story.title,
                               subtitle: story.tags.joined(separator: " · "), symbol: "text.book.closed", trailing: nil, score: s)
        }
    }

    private func settingItems(_ text: String) -> [PaletteItem] {
        guard !text.isEmpty || scope == .settings else { return [] }
        return PaletteSettingEntry.all.compactMap { entry in
            let s = text.isEmpty ? 0 : (FuzzyMatcher.score(text, entry.title) ?? FuzzyMatcher.score(text, entry.keywords).map { $0 - 8 })
            guard let s else { return nil }
            return PaletteItem(id: "set.\(entry.key)", section: .settings, kind: .setting(entry.tab, entry.key), title: entry.title,
                               subtitle: "Settings ▸ \(entry.tab.title)", symbol: entry.tab.symbol, trailing: nil, score: s)
        }
    }

    private func actionItems(_ text: String) -> [PaletteItem] {
        AppAction.paletteActions.compactMap { action in
            let title = action.title(in: store)
            let s = text.isEmpty ? 0 : FuzzyMatcher.score(text, title)
            guard let s else { return nil }
            return PaletteItem(id: "act.\(action.id)", section: action.isNavigation ? .navigate : .actions, kind: .action(action),
                               title: title, subtitle: nil, symbol: action.symbol(in: store), trailing: nil,
                               shortcut: action.shortcut, score: s)
        }
    }

    // MARK: Run

    enum Invocation: Sendable { case open, openPosting, showInPipeline }

    /// Perform the selected (or given) item. Returns true when the palette should close.
    @discardableResult
    func run(_ item: PaletteItem? = nil, _ how: Invocation = .open) async -> Bool {
        guard let item = item ?? selectedItem else { return false }
        let router = store.router
        switch item.kind {
        case .job(let id):
            switch how {
            case .open:
                router.go(.pipeline)
                router.openJob(id: id)
            case .openPosting:
                if let job = store.jobs.job(id: id), let url = (job.applyURL ?? job.sourceURL).flatMap(URL.init(string:)) { openURL(url) }
            case .showInPipeline:
                router.go(.pipeline)
                router.focusedJobID = id
            }
        case .question(let clusterID):
            router.go(.needsYou)
            InboxModel.shared(for: store).select(clusterID)
        case .story(let id):
            router.go(.stories)
            StoryBankModel.shared(for: store).select(id)
        case .setting(let tab, let key):
            SettingsNavigation.shared.open(tab, key: key, router: router)
        case .action(let action):
            router.isPalettePresented = false
            await store.perform(action)
            return true
        case .easterEgg(let trigger):
            if let egg = EasterEggs.phrases.first(where: { $0.trigger == trigger }) { EasterEggs.play(egg, toasts: store.toasts) }
        }
        router.isPalettePresented = false
        return true
    }
}
