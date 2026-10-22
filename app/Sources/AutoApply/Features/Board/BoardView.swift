// BoardView.swift — the Pipeline screen: header with Board | Table, filter, Source, Score ≥,
// Resume and "Show skipped"; the kanban board (horizontal columns, keyboard selection,
// legal-only drag & drop) or the sortable table. No primary action: you move jobs by dragging.
// While the agent is unreachable, dragging is off and a line says why.
import SwiftUI

@objc(BoardFeature)
final class BoardFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.board) { BoardScreen() }
        registry.registerJobInspector { id in JobInspector(jobID: id) }
    }
}

/// Owns the BoardModel for the lifetime of the screen.
struct BoardScreen: View {
    @Environment(AppStore.self) private var store
    @State private var model: BoardModel?

    var body: some View {
        Group {
            if let model {
                BoardView(model: model)
            } else {
                Color.clear
            }
        }
        .onAppear { if model == nil { model = BoardModel(store: store) } }
    }
}

struct BoardView: View {
    @Bindable var model: BoardModel
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced
    @AppStorage("board.viewMode") private var modeRaw = BoardViewMode.board.rawValue
    @State private var resumeFilter: Int?
    @State private var now = Date()
    @FocusState private var boardFocused: Bool
    @FocusState private var searchFocused: Bool
    @Namespace private var flightNS

    private var mode: BoardViewMode { BoardViewMode(rawValue: modeRaw) ?? .board }

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            header(filter: $router.pipelineFilter)
            if store.hasSnapshot && !store.isConnected {
                Label("Can't reach the agent. Moving jobs is off until it's back.", systemImage: "bolt.horizontal.circle")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Space.contentPadding)
                    .padding(.bottom, Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            content
        }
        .background(Palette.windowBackground)
        .onAppear { model.announceGhostedSinceLastVisit() }
        .confirmationDialog(manualApplyTitle, isPresented: Binding(
            get: { model.pendingManualApply != nil }, set: { if !$0 { model.pendingManualApply = nil } }),
                            titleVisibility: .visible) {
            Button(model.pendingManualApply?.status == .applied ? "Mark as Applied"
                   : "Mark as Applied · \(model.pendingManualApply?.status.label ?? "")") {
                Task { await model.confirmManualApply() }
            }
            Button("Cancel", role: .cancel) { model.pendingManualApply = nil }
        } message: {
            Text("The agent won't apply to it. It's recorded as your own application, so it counts toward cooldowns, and you can keep moving it between statuses.")
        }
        .task {
            // Ages ("3d") and nudges refresh once a minute; nothing else ticks.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
        .onContinuousHover { _ in
            // Hover events resume only after a drag session ends: clear a cancelled drag.
            if model.draggingJobID != nil { model.endDrag() }
        }
    }

    private var manualApplyTitle: String {
        guard let job = model.pendingManualApply.flatMap({ store.jobs.job(id: $0.jobID) }) else { return "Applied yourself?" }
        return "Did you apply to \(job.company) yourself?"
    }

    // MARK: Header

    private func header(filter: Binding<PipelineFilter>) -> some View {
        ScreenHeader("Pipeline", summary: C3Format.plural(store.jobs.all.count, "job")) {
            Picker("View", selection: $modeRaw) {
                ForEach(BoardViewMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            HStack(spacing: Space.xs) {
                // ⌘F focuses the filter (local to Pipeline).
                Button { searchFocused = true } label: {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.filter)
                .help("Filter (\(AppShortcut.filter.displayString))")
                .accessibilityLabel("Filter")
                TextField("Filter", text: filter.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(width: 160)
                    .onSubmit { boardFocused = true }
            }
            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
            .well()

            Menu(filter.wrappedValue.source?.label ?? "Source") {
                Button("Any source") { filter.wrappedValue.source = nil }
                Divider()
                ForEach(JobSource.allCases, id: \.self) { source in
                    Button(source.label) { filter.wrappedValue.source = source }
                }
            }
            .fixedSize()

            Menu(filter.wrappedValue.minScore.map { "Score ≥ \($0)" } ?? "Score") {
                Button("Any score") { filter.wrappedValue.minScore = nil }
                Divider()
                ForEach([50, 60, 70, 80, 90], id: \.self) { s in
                    Button("≥ \(s)") { filter.wrappedValue.minScore = s }
                }
            }
            .fixedSize()

            Menu(resumeFilter.flatMap { store.library.resume(id: $0)?.label } ?? "Resume") {
                Button("Any resume") { resumeFilter = nil }
                Divider()
                ForEach(store.library.resumeVariants) { v in
                    Button(v.label) { resumeFilter = v.id }
                }
            }
            .fixedSize()

            Toggle("Show skipped", isOn: filter.showSkipped)
                .toggleStyle(.checkbox)

            if hasActiveFilter(filter.wrappedValue) {
                Button("Clear") {
                    filter.wrappedValue = PipelineFilter()
                    resumeFilter = nil
                }
                .buttonStyle(.secondaryLink)
            }
        }
    }

    private func hasActiveFilter(_ f: PipelineFilter) -> Bool {
        f != PipelineFilter() || resumeFilter != nil
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let filter = effectiveFilter
        if !store.jobs.isLoaded {
            if store.repository.isAvailable {
                boardSkeleton
            } else {
                ErrorState(title: "Couldn't read the pipeline", message: "The local database isn't available yet.",
                           actionTitle: "Try again") { store.recomputeStats() }
                    .frame(maxHeight: .infinity)
            }
        } else if store.jobs.all.isEmpty {
            EmptyState(symbol: "rectangle.split.3x1", title: "No jobs yet",
                       message: "Jobs appear here as the agent finds them. Start a run from the toolbar or with \(AppShortcut.runNow.displayString).")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mode == .table {
            tableView(filter: filter)
        } else {
            board(filter: filter)
        }
    }

    private var effectiveFilter: PipelineFilter { router.pipelineFilter }

    private func filteredJobs(_ jobs: [JobItem]) -> [JobItem] {
        guard let resumeFilter else { return jobs }
        return jobs.filter { $0.resumeVariantID == resumeFilter }
    }

    private var resumeLabels: [Int: String] {
        Dictionary(store.library.resumeVariants.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
    }

    private func board(filter: PipelineFilter) -> some View {
        let visible = BoardRules.visibleColumns(filter: filter)
        let byColumn = BoardRules.columns(from: store.jobs.columns, visible: visible, filter: filter).mapValues(filteredJobs)
        let questionCounts = BoardRules.questionCounts(store.inbox.clusters)
        let outreachMarks = BoardRules.outreachMarks(store.outreach)
        let replySuggestions = Dictionary(store.outreach.pendingSuggestions.compactMap { r in r.suggestedStatus.map { (r.applicationID, $0) } },
                                          uniquingKeysWith: { a, _ in a })
        let labels = resumeLabels
        let skipGroups = BoardRules.skipReasonGroups(filteredJobs(BoardRules.filtered(store.jobs.jobs(in: .skipped), filter: PipelineFilter(source: filter.source, minScore: filter.minScore, searchText: filter.searchText))))
        let signature = visible.map { col in (byColumn[col] ?? []).map(\.id) }
        let selected = router.focusedJobID

        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Space.gutter) {
                ForEach(visible) { column in
                    KanbanColumn(
                        column: column, jobs: byColumn[column] ?? [], model: model,
                        threshold: store.preferences.matchThreshold, questionCounts: questionCounts,
                        resumeLabels: labels, outreachMarks: outreachMarks, replySuggestions: replySuggestions,
                        selectedJobID: selected, now: now,
                        nudgeDays: store.preferences.nudgeDays, ghostAfterDays: store.preferences.ghostAfterDays,
                        skipGroups: skipGroups, skipReasonFilter: filter.skipReason, namespace: flightNS,
                        firstName: store.library.firstName,
                        onSelect: { id in
                            router.focusedJobID = id
                            boardFocused = true
                        },
                        onOpen: { id in router.openJob(id: id) },
                        onSkipReason: { reason in router.pipelineFilter.skipReason = reason })
                }
            }
            .padding(Space.contentPadding)
            .motion(Motion.flow, value: signature)
        }
        .focusable()
        // The selected row / card shows keyboard focus; the system ring would outline the whole pane.
        .focusEffectDisabled()
        .focused($boardFocused)
        .onKeyPress(phases: .down) { press in
            handleKey(press, visible: visible, byColumn: byColumn)
        }
        .onAppear { boardFocused = true }
        .accessibilityLabel("Pipeline board")
    }

    private func handleKey(_ press: KeyPress, visible: [BoardColumn], byColumn: [BoardColumn: [JobItem]]) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        var dx = 0, dy = 0
        switch press.key {
        case .upArrow: dy = -1
        case .downArrow: dy = 1
        case .leftArrow: dx = -1
        case .rightArrow: dx = 1
        case .return:
            if let id = router.focusedJobID { router.openJob(id: id); return .handled }
            return .ignored
        case .space:
            if let id = router.focusedJobID { router.openJob(id: id); return .handled }
            return .ignored
        case .escape:
            router.focusedJobID = nil
            return .handled
        default:
            switch press.characters {
            case "k": dy = -1
            case "j": dy = 1
            case "h": dx = -1
            case "l": dx = 1
            default: return .ignored
            }
        }
        let next = BoardRules.moveSelection(from: router.focusedJobID, columns: visible, jobs: byColumn, dx: dx, dy: dy)
        if next != router.focusedJobID {
            withMotion(Motion.snappy, reduceMotion: reduced) { router.focusedJobID = next }
            if dx != 0 { Haptics.alignment() }
        }
        return .handled
    }

    private func tableView(filter: PipelineFilter) -> some View {
        // Table view browses everything matching the filter, Discovered/Skipped included.
        let labels = resumeLabels
        let rows = filteredJobs(BoardRules.filtered(store.jobs.all, filter: filter))
            .filter { job in
                guard let cols = filter.columns, !cols.isEmpty else { return true }
                return job.boardColumn.map(cols.contains) ?? false
            }
            .map { PipelineTableRow(job: $0, resumeLabels: labels) }
        return PipelineTable(rows: rows,
                             selection: Binding(get: { router.focusedJobID }, set: { router.focusedJobID = $0 }),
                             onOpen: { id in router.openJob(id: id) })
    }

    private var boardSkeleton: some View {
        HStack(alignment: .top, spacing: Space.gutter) {
            ForEach(BoardColumn.defaultVisible) { column in
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(column.title).eyebrowStyle()
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBlock(lines: 2).padding(Space.s).surface(cornerRadius: Radius.inner)
                    }
                }
                .padding(Space.s)
                .frame(width: LayoutMetrics.boardColumnWidth)
            }
        }
        .padding(Space.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
