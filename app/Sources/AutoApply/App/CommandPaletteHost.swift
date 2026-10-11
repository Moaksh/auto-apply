// CommandPaletteHost.swift — presents the ⌘K palette as a floating glass panel in the upper
// third of the window. Content comes from the registry (`.commandPalette`, owned by C3); until
// C3 registers one, a basic functional palette (actions, navigation, jobs) is shown.
import SwiftUI

struct CommandPaletteHost: View {
    @Environment(Router.self) private var router
    @Environment(ScreenRegistry.self) private var registry
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        ZStack(alignment: .top) {
            if router.isPalettePresented {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { router.isPalettePresented = false }
                Group {
                    if registry.isRegistered(.commandPalette) {
                        registry.view(for: .commandPalette)
                    } else {
                        BasicCommandPalette()
                    }
                }
                .frame(width: LayoutMetrics.paletteWidth)
                .glassPanel()
                .padding(.top, 90)
                .transition(reduced ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: router.isPalettePresented)
    }
}

/// Minimal palette: fuzzy filter over actions, navigation and jobs. ↑↓ moves, ↵ runs, esc closes.
struct BasicCommandPalette: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private enum Item: Identifiable {
        case action(AppAction)
        case job(JobItem)

        var id: String {
            switch self {
            case .action(let a): "a.\(a.id)"
            case .job(let j): "j.\(j.id)"
            }
        }
    }

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let actions = AppAction.paletteActions.filter { q.isEmpty || $0.title(in: store).lowercased().contains(q) }.map(Item.action)
        guard !q.isEmpty else { return actions }
        let jobs = store.jobs.all.lazy.filter { $0.company.lowercased().contains(q) || $0.title.lowercased().contains(q) }.prefix(8).map(Item.job)
        return Array(jobs) + actions
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                TextField("Search jobs and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typography.title2)
                    .focused($focused)
                    .onSubmit { run(list) }
                KeyCap("esc")
            }
            .padding(Space.l)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(list.prefix(12).enumerated()), id: \.element.id) { index, item in
                        row(item, selected: index == selection)
                            .onTapGesture { selection = index; run(list) }
                    }
                    if list.isEmpty {
                        Text("No matches").font(Typography.callout).foregroundStyle(Palette.textTertiary).padding(Space.l)
                    }
                }
                .padding(Space.s)
            }
            .frame(maxHeight: 360)
        }
        .onAppear {
            query = router.paletteSeed
            focused = true
        }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, min(list.count, 12) - 1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { router.isPalettePresented = false; return .handled }
    }

    @ViewBuilder
    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: Space.s) {
            switch item {
            case .action(let action):
                Image(systemName: action.symbol(in: store)).frame(width: 20)
                Text(action.title(in: store)).font(Typography.body)
                Spacer()
                if let shortcut = action.shortcut { KeyCap(shortcut) }
            case .job(let job):
                StatusDot(kind: StatusKind(job: job))
                Text(job.displayName).font(Typography.body).lineLimit(1)
                Spacer()
                if let score = job.score { ScorePill(score: score, threshold: store.preferences.matchThreshold) }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(selected ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .contentShape(Rectangle())
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(selection) else { return }
        router.isPalettePresented = false
        switch list[selection] {
        case .action(let action): Task { await store.perform(action) }
        case .job(let job):
            router.go(.pipeline)
            router.openJob(id: job.id)
        }
    }
}
