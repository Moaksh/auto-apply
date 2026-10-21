// ActivityLogView.swift — the Activity log (docs/UI_UX_PLAN.md §5.11): SF Mono throughout, a
// fixed-width colored type tag, scope filter (All | Agent | You | Errors), text filter, run
// picker and follow mode. NSTableView-backed `Table` virtualizes rows (smooth at 100k).
// Scrolling away or selecting a row pauses follow; a floating glass bar "12 new events ↑" resumes it.
import SwiftUI

@objc(ActivityLogFeature)
final class ActivityLogFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.activityLog) { ActivityLogView() }
        registry.registerInspector(for: .activityLog) { ActivityInspector() }
    }
}

struct ActivityLogView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced
    @State private var model = ActivityLogModel.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            header(filter: $router.activityFilter)
                .padding(.horizontal, Space.contentPadding)
                .padding(.vertical, Space.m)
            Divider()
            content
        }
        .background(Palette.windowBackground)
        .onAppear { resync() }
        .onChange(of: store.activity.events.last?.id) { resync() }
        .onChange(of: store.activity.events.count) { resync() }
        .onChange(of: router.activityFilter) { resync() }
        .onChange(of: model.runID) { resync() }
        .onChange(of: model.selection) { _, new in
            if new != nil {
                model.pauseFollow()
                if !router.isInspectorPresented { router.isInspectorPresented = true }
            }
        }
    }

    private func resync() {
        let jobs = store.jobs
        model.sync(events: store.activity.events, filter: router.activityFilter) { id in
            jobs.job(id: id).map { ActivityRules.slug(company: $0.company, title: $0.title) }
        }
    }

    // MARK: Header

    private func header(filter: Binding<ActivityFilter>) -> some View {
        // One line when it fits, two when the column is narrow (inspector open, small window): a
        // rigid one-line header made the column wider than the window and pushed the inspector
        // off-screen. The window title already says "Activity".
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                scopePicker(filter)
                searchField(filter)
                runMenu
                chips(filter)
                Spacer(minLength: 0)
                eventCount
                followButton
            }
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.m) {
                    scopePicker(filter)
                    Spacer(minLength: 0)
                    followButton
                }
                HStack(spacing: Space.m) {
                    searchField(filter)
                    runMenu
                    chips(filter)
                    Spacer(minLength: 0)
                    eventCount
                }
            }
        }
    }

    private func scopePicker(_ filter: Binding<ActivityFilter>) -> some View {
        Picker("Scope", selection: filter.scope) {
            Text("All").tag(ActivityFilter.Scope.all)
            Text("Agent").tag(ActivityFilter.Scope.agent)
            Text("You").tag(ActivityFilter.Scope.you)
            Text("Errors").tag(ActivityFilter.Scope.errors)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func searchField(_ filter: Binding<ActivityFilter>) -> some View {
        HStack(spacing: Space.xs) {
            // ⌘F focuses the filter (local to Activity).
            Button { searchFocused = true } label: {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.filter)
            .help("Filter (\(AppShortcut.filter.displayString))")
            .accessibilityLabel("Filter")
            TextField("Filter", text: filter.searchText)
                .textFieldStyle(.plain)
                .font(Typography.mono)
                .focused($searchFocused)
                .frame(minWidth: 80, maxWidth: 220)
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .well()
    }

    private var runMenu: some View {
        Menu(runTitle) {
            Button("All runs") { model.runID = nil }
            Divider()
            ForEach(store.library.runs.prefix(20)) { run in
                Button(runLabel(run)) { model.runID = run.id }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func chips(_ filter: Binding<ActivityFilter>) -> some View {
        if let day = filter.wrappedValue.day {
            chip("Day: \(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))") { filter.wrappedValue.day = nil }
        }
        if let jobID = filter.wrappedValue.jobID {
            chip("Job: \(store.jobs.job(id: jobID)?.company ?? "#\(jobID)")") { filter.wrappedValue.jobID = nil }
        }
    }

    private var eventCount: some View {
        Text("\(model.rows.count.formatted()) events").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            .fixedSize()
    }

    private var followButton: some View {
        Button {
            model.toggleFollow()
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: model.isFollowing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                Text("Follow").fixedSize()
                Circle().fill(model.isFollowing ? Palette.applied : Palette.textTertiary).frame(width: 7, height: 7)
            }
        }
        .buttonStyle(.secondaryLink)
        .help(model.isFollowing ? "Pause follow mode" : "Resume follow mode")
    }

    private func chip(_ text: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: Space.xs) {
            Badge(text)
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                .accessibilityLabel("Clear \(text)")
        }
    }

    private var runTitle: String {
        guard let id = model.runID, let run = store.library.runs.first(where: { $0.id == id }) else { return "Run: All" }
        return "Run: \(runLabel(run))"
    }

    private func runLabel(_ run: RunItem) -> String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(run.startedAt) ? "Today" : run.startedAt.formatted(.dateTime.day().month(.abbreviated))
        return "\(day) \(run.startedAt.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Table

    @ViewBuilder
    private var content: some View {
        if !store.activity.isLoaded {
            if store.repository.isAvailable {
                SkeletonBlock(lines: 12).padding(Space.xl).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ErrorState(title: "Couldn't read the activity log", message: "The local database isn't available yet.")
                    .frame(maxHeight: .infinity)
            }
        } else if model.rows.isEmpty {
            EmptyState(symbol: "list.bullet.rectangle", title: store.activity.events.isEmpty ? "No activity yet" : "No matching events",
                       message: store.activity.events.isEmpty ? "Everything the agent does is logged here." : "Try a different filter.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                table
                    .overlay(alignment: .top) { newEventsPill(proxy: proxy) }
                    .onChange(of: model.scrollToTopRequest) {
                        if let newest = model.displayed.first?.id {
                            withMotion(Motion.flow, reduceMotion: reduced) { proxy.scrollTo(newest, anchor: .top) }
                        }
                    }
            }
        }
    }

    /// Fixed-width columns in a plain `List` (no `Table`): a `Table` hosted next to the inspector kept
    /// re-reporting its column-driven size to the window and crashed AppKit's constraint pass
    /// ("needs another Update Constraints in Window pass") as soon as a row was selected.
    private var table: some View {
        let jobs = store.jobs
        return VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Text("Time").frame(width: 92, alignment: .leading)
                Text("Type").frame(width: 64, alignment: .leading)
                Text("Job").frame(width: 150, alignment: .leading)
                Text("Message").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Typography.monoSmall)
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.xs)
            Divider()
            List(model.displayed, selection: $model.selection) { (e: ActivityEvent) in
                HStack(spacing: Space.m) {
                    Text(ActivityRules.timestamp(e.ts)).foregroundStyle(Palette.textTertiary)
                        .frame(width: 92, alignment: .leading)
                    let tag = ActivityRules.tag(for: e)
                    Text(tag.text).foregroundStyle(tag.kind?.color ?? Palette.textSecondary).fontWeight(.medium)
                        .frame(width: 64, alignment: .leading)
                    Group {
                        if let id = e.jobID, let job = jobs.job(id: id) {
                            Text(ActivityRules.slug(company: job.company, title: job.title)).foregroundStyle(Palette.textSecondary)
                        } else {
                            Text("—").foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                    Text(e.message)
                        .foregroundStyle(ActivityRules.isError(e) ? Palette.error : (e.actor == .user ? Palette.accent : Palette.textPrimary))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .lineLimit(1)
                .id(e.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .font(Typography.mono)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y > geo.contentInsets.top + 24
        } action: { _, scrolledAway in
            if scrolledAway { model.pauseFollow() }
        }
        .contextMenu(forSelectionType: ActivityEvent.ID.self) { ids in
            if let id = ids.first, let e = model.rows.first(where: { $0.id == id }) {
                if let jobID = e.jobID { Button("Open Job") { router.openJobFromDashboard(jobID) } }
                Button("Copy Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e.message, forType: .string)
                }
                if ActivityRules.isError(e) {
                    Button("Copy Diagnostic") { model.copyDiagnostic(e, jobLabel: e.jobID.flatMap { jobs.job(id: $0)?.displayName }) }
                }
                if let jobID = e.jobID {
                    Button("Show Only This Job") { router.activityFilter.jobID = jobID }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let e = model.rows.first(where: { $0.id == id }), let jobID = e.jobID {
                router.openJobFromDashboard(jobID)
            }
        }
        .accessibilityLabel("Activity log, \(model.visibleCount) events")
    }

    @ViewBuilder
    private func newEventsPill(proxy: ScrollViewProxy) -> some View {
        if !model.isFollowing && model.newEventCount > 0 {
            GlassBar(interactive: true) {
                Button {
                    model.resumeFollow()
                } label: {
                    Text("\(model.newEventCount) new event\(model.newEventCount == 1 ? "" : "s") ↑").font(Typography.bodyEmph)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, Space.l)
            .transition(reduced ? .opacity : .move(edge: .top).combined(with: .opacity))
            .accessibilityHint("Resumes follow mode and scrolls to the newest event")
        }
    }
}
