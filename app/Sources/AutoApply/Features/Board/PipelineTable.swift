// PipelineTable.swift — Pipeline's Table view (§5.3): sortable columns (Company, Title, Status,
// Score, Source, ATS, Resume, Applied, Last update) for power filtering and browsing
// Discovered/Skipped with reasons. NSTableView-backed, so it virtualizes thousands of rows.
import SwiftUI

struct PipelineTableRow: Identifiable, Hashable, Sendable {
    var id: Int
    var company: String
    var title: String
    var status: String
    var statusOrder: Int
    var kind: StatusKind
    var score: Int
    var source: String
    var ats: String
    var resume: String
    var applied: Date
    var lastUpdate: Date
    var reason: String

    init(job: JobItem, resumeLabels: [Int: String]) {
        id = job.id
        company = job.company
        title = job.title
        kind = StatusKind(job: job)
        status = job.state == .submitted ? (job.status ?? .applied).label : job.state.label
        statusOrder = AppState.allCases.firstIndex(of: job.state) ?? 0
        if job.state == .submitted { statusOrder = 100 + (BoardStatus.ordered.firstIndex(of: job.status ?? .applied) ?? 0) }
        score = job.score ?? -1
        source = job.source.label
        ats = job.ats.label
        resume = job.resumeVariantID.flatMap { resumeLabels[$0] } ?? ""
        applied = job.submittedAt ?? .distantPast
        lastUpdate = job.statusUpdatedAt ?? job.stateUpdatedAt ?? job.discoveredAt
        reason = job.state == .skipped ? BoardRules.skipReasonLabel(job.skipReason ?? job.stateReason) : (job.stateReason ?? "")
    }
}

struct PipelineTable: View {
    var rows: [PipelineTableRow]
    @Binding var selection: Int?
    var onOpen: (Int) -> Void

    @State private var sortOrder = [KeyPathComparator(\PipelineTableRow.lastUpdate, order: .reverse)]

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Company", value: \.company) { row in
                HStack(spacing: Space.s) {
                    StatusDot(kind: row.kind)
                    Text(row.company).font(Typography.bodyEmph)
                }
            }
            .width(min: 110, ideal: 140)
            TableColumn("Title", value: \.title)
                .width(min: 140, ideal: 220)
            TableColumn("Status", value: \.statusOrder) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.status)
                    if !row.reason.isEmpty {
                        Text(row.reason).font(Typography.callout).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    }
                }
            }
            .width(min: 90, ideal: 130)
            TableColumn("Score", value: \.score) { row in
                if row.score >= 0 { Text("\(row.score)").font(Typography.metricSmall) } else { Text("—").foregroundStyle(Palette.textTertiary) }
            }
            .width(min: 44, ideal: 54)
            TableColumn("Source", value: \.source).width(min: 70, ideal: 90)
            TableColumn("Application site", value: \.ats).width(min: 90, ideal: 120)
            TableColumn("Resume", value: \.resume).width(min: 60, ideal: 80)
            TableColumn("Applied", value: \.applied) { row in
                Text(row.applied == .distantPast ? "—" : row.applied.formatted(date: .abbreviated, time: .omitted))
                    .font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Last update", value: \.lastUpdate) { row in
                Text(row.lastUpdate.formatted(.relative(presentation: .named)))
                    .font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first { Button("Open") { onOpen(id) } }
        } primaryAction: { ids in
            if let id = ids.first { onOpen(id) }
        }
    }

    private var sorted: [PipelineTableRow] { rows.sorted(using: sortOrder) }
}
