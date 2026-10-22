// KanbanColumn.swift — one Pipeline column: header with rolling count, a lazily scrolled card
// stack, and drop logic. Only legal targets accept a drop: while dragging, illegal columns dim
// to 40% and the cursor shows "forbidden"; legal ones get a 1.5pt accent dashed outline and an
// insertion slot that opens at the top and says what the drop does (the agent applies / applied
// by you / move).
import SwiftUI

struct KanbanColumn: View {
    var column: BoardColumn
    var jobs: [JobItem]
    var model: BoardModel
    var threshold: Int
    var questionCounts: [Int: Int]
    var resumeLabels: [Int: String]
    /// Application id → envelope (emailed / replied).
    var outreachMarks: [Int: JobOutreachMark] = [:]
    /// Application id → an employer reply's suggested move.
    var replySuggestions: [Int: BoardStatus] = [:]
    var selectedJobID: Int?
    var now: Date
    var nudgeDays: [Int]
    var ghostAfterDays: Int
    var skipGroups: [(key: String, label: String, count: Int)]
    var skipReasonFilter: String?
    var namespace: Namespace.ID
    var firstName: String?
    var onSelect: (Int) -> Void
    var onOpen: (Int) -> Void
    var onSkipReason: (String?) -> Void
    /// Inside the Closed drawer: neutral header, kind title, no status hue.
    var calm: Bool = false

    @Environment(\.undoManager) private var undoManager
    @Environment(\.motionReduced) private var reduced
    @State private var headerTint = false

    private var isDragging: Bool { model.draggingJobID != nil }
    private var isLegal: Bool { model.isLegalTarget(column) }
    private var isTargeted: Bool { model.targetColumn == column && isLegal }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
            ScrollView(.vertical) {
                LazyVStack(spacing: Space.s) {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                            .strokeBorder(Palette.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(height: 64)
                            .overlay {
                                if let hint = dropHint {
                                    Label(hint.text, systemImage: hint.symbol)
                                        .font(Typography.callout)
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                    }
                    if column == .skipped && skipReasonFilter == nil {
                        skipReasonList
                    } else {
                        ForEach(jobs) { job in card(job) }
                    }
                    if jobs.isEmpty && !isTargeted && column != .skipped {
                        Text(emptyText).font(Typography.callout).foregroundStyle(Palette.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, Space.l)
                .motion(Motion.snappy, value: isTargeted)
            }
            .scrollIndicators(.automatic)
        }
        .padding(Space.s)
        .frame(width: LayoutMetrics.boardColumnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .well(cornerRadius: Radius.card)
        .overlay {
            if isDragging && isLegal {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
        .opacity(isDragging && !isLegal ? 0.4 : 1)
        .motion(Motion.snappy, value: isDragging)
        .onDrop(of: [.text], delegate: ColumnDropDelegate(column: column, model: model, undoManager: undoManager))
        .onChange(of: model.celebrationSerial) {
            guard let id = model.celebratedJobID, jobs.contains(where: { $0.id == id }) || model.store.jobs.job(id: id)?.boardColumn == column,
                  column == .interview || column == .offer else { return }
            headerTint = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                headerTint = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(calm ? BoardRules.closedTitle(column) : column.title), \(jobs.count) jobs")
    }

    private var header: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: calm ? BoardRules.closedSymbol(column) : StatusKind(column: column).symbol)
                .foregroundStyle(calm ? Palette.textTertiary : StatusKind(column: column).color)
                .imageScale(.small)
            Text(calm ? BoardRules.closedTitle(column) : column.title).eyebrowStyle()
            Text("\(column == .skipped ? skipGroups.reduce(0) { $0 + $1.count } : jobs.count)")
                .font(Typography.metricSmall)
                .foregroundStyle(Palette.textSecondary)
                .numericRoll(Double(jobs.count))
            Spacer()
            if column == .skipped, skipReasonFilter != nil {
                Button { onSkipReason(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Show all skip reasons")
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 2)
        .background((headerTint ? StatusKind(column: column).color.opacity(0.15) : .clear), in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.3), value: headerTint)
        .accessibilityAddTraits(.isHeader)
    }

    private func card(_ job: JobItem) -> some View {
        let celebrating = model.celebratedJobID == job.id
        return VStack(alignment: .leading, spacing: Space.xs) {
            JobCard(job: job, threshold: threshold, questionCount: questionCounts[job.id] ?? 0,
                    nudge: BoardRules.nudge(for: job, now: now, nudgeDays: nudgeDays, ghostAfterDays: ghostAfterDays),
                    resumeLabel: job.resumeVariantID.flatMap { resumeLabels[$0] },
                    isSelected: selectedJobID == job.id, isDragging: model.draggingJobID == job.id, now: now,
                    outreach: job.applicationID.flatMap { outreachMarks[$0] },
                    replySuggestion: job.applicationID.flatMap { replySuggestions[$0] }) { status in
                Task { await model.move(jobID: job.id, to: status, undoManager: undoManager) }
            }
            .equatable()
            .keyframeAnimator(initialValue: 1.0, trigger: celebrating && !reduced ? model.celebrationSerial : 0) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.06, duration: 0.25, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
                }
            }
            if model.firstInterviewNoteJobID == job.id {
                Text("First interview. Nice. Good luck\(firstName.map { ", \($0)" } ?? "").")
                    .font(Typography.callout).foregroundStyle(Palette.interview)
                    .transition(.opacity)
            }
        }
        .matchedGeometryEffect(id: job.id, in: namespace)
        .onTapGesture(count: 2) { onOpen(job.id) }
        .onTapGesture { onSelect(job.id) }
        .modifier(DragSource(job: job, model: model, threshold: threshold))
        .contextMenu { contextMenu(job) }
        .accessibilityAddTraits(selectedJobID == job.id ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { onOpen(job.id) }
        .accessibilityActions {
            ForEach(BoardRules.legalTargets(for: job), id: \.self) { status in
                Button("Move to \(BoardRules.moveLabel(status))") {
                    Task { await model.move(jobID: job.id, to: status, undoManager: undoManager) }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ job: JobItem) -> some View {
        Button("Open") { onOpen(job.id) }
        Button("Open in New Window") { model.store.router.openJobInWindow(id: job.id) }
        if let url = (job.applyURL ?? job.sourceURL).flatMap(URL.init(string:)) {
            Button("Open Posting") { NSWorkspace.shared.open(url) }
        }
        let targets = BoardRules.legalTargets(for: job)
        if !targets.isEmpty {
            Divider()
            Menu("Move to") {
                ForEach(targets, id: \.self) { status in
                    Button(BoardRules.moveLabel(status)) { Task { await model.move(jobID: job.id, to: status, undoManager: undoManager) } }
                }
            }
        }
        if BoardRules.canQueue(job) || BoardRules.canMarkApplied(job) { Divider() }
        if BoardRules.canQueue(job) {
            Button("Apply with the Agent") { Task { await model.queue(jobID: job.id) } }
        }
        if BoardRules.canMarkApplied(job) {
            Menu("I Applied Myself") {
                ForEach(BoardStatus.ordered, id: \.self) { status in
                    Button(status == .applied ? "Applied" : "Applied · \(status.label)") {
                        model.pendingManualApply = BoardModel.ManualApply(jobID: job.id, status: status)
                    }
                }
            }
        }
    }

    private var skipReasonList: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(skipGroups, id: \.key) { group in
                Button { onSkipReason(group.key) } label: {
                    HStack {
                        Text(group.label).font(Typography.body)
                        Spacer()
                        Text("\(group.count)").font(Typography.metricSmall).foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, Space.s).padding(.vertical, Space.s)
                    .surface(cornerRadius: Radius.inner)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.label), \(group.count) jobs")
            }
            if skipGroups.isEmpty {
                Text("Nothing skipped").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    /// What dropping the dragged card here does.
    private var dropHint: (text: String, symbol: String)? {
        guard let job = model.draggingJob, let action = BoardRules.dropAction(job, on: column) else { return nil }
        return switch action {
        case .queue: ("The agent applies", "paperplane.fill")
        case .markApplied: ("Applied by you", "hand.raised.fill")
        case .setStatus(.rejected): ("Close it · they went another way", BoardRules.closedSymbol(.rejected))
        case .setStatus(.ghosted): ("Close it · no reply", BoardRules.closedSymbol(.ghosted))
        case .setStatus(let status): ("Move to \(status.label)", StatusKind(status: status).symbol)
        }
    }

    private var emptyText: String {
        switch column {
        case .queued: "Drag a job here and the agent applies to it"
        case .needsYou: "Nothing waiting on you"
        case .applied: "Drop applications here"
        case _ where calm: isDragging ? "Drop here" : "Nothing here"
        default: isDragging ? "Drop here" : "Empty"
        }
    }
}

/// Starts a drag for cards the user may move (submitted ones between statuses; earlier ones to
/// Queued or to "applied by you"). Cards the agent is working on aren't draggable.
private struct DragSource: ViewModifier {
    var job: JobItem
    var model: BoardModel
    var threshold: Int

    func body(content: Content) -> some View {
        if BoardRules.isDraggable(job) && model.store.isConnected {
            content.onDrag {
                model.beginDrag(jobID: job.id)
                return NSItemProvider(object: BoardModel.payload(for: job.id) as NSString)
            } preview: {
                JobCard(job: job, threshold: threshold, questionCount: 0, nudge: nil, resumeLabel: nil,
                        isSelected: false, isDragging: false, now: Date())
                    .frame(width: LayoutMetrics.boardColumnWidth - 16)
                    .dragLift(isDragging: true, rotation: 1.2)
                    .padding(20)
            }
        } else {
            content
        }
    }
}

struct ColumnDropDelegate: DropDelegate {
    var column: BoardColumn
    var model: BoardModel
    var undoManager: UndoManager?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text]) && model.draggingJobID != nil
    }

    func dropEntered(info: DropInfo) {
        model.targetColumn = column
        if model.isLegalTarget(column) {
            Haptics.generic()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: model.isLegalTarget(column) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        if model.targetColumn == column { model.targetColumn = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = model.draggingJobID else {
            model.endDrag()
            return false
        }
        return model.performDrop(payload: BoardModel.payload(for: id), on: column, undoManager: undoManager)
    }
}
