// JobInspector.swift — the trailing inspector for the focused Pipeline job (⌘⌥I): status, score
// and factor bars, key facts, and actions (open detail / window / posting, legal moves).
import SwiftUI

struct JobInspector: View {
    var jobID: Int
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if let job = store.jobs.job(id: jobID) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    HStack(spacing: Space.s) {
                        CompanyMonogram(name: job.company, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.company).font(Typography.title2)
                            Text(job.title).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    HStack(spacing: Space.s) {
                        StatusChip(job: job)
                        if let score = job.score { ScorePill(score: score, threshold: store.preferences.matchThreshold) }
                    }
                    if !job.scoreFactors.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            SectionHeader("Match")
                            ForEach(JobDetailRules.orderedFactors(job.scoreFactors), id: \.name) { factor in
                                FactorBar(name: factor.name, value: factor.value, animateFromZero: false, delay: 0)
                            }
                        }
                    }
                    facts(job)
                    actions(job)
                }
                .padding(Space.l)
            }
        } else {
            EmptyState(symbol: "questionmark.folder", title: "Job not found")
        }
    }

    private func facts(_ job: JobItem) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeader("Details")
            fact("Location", job.location ?? "—")
            fact("Source", job.source.label)
            fact("ATS", job.ats.label)
            if let r = store.library.resume(id: job.resumeVariantID) { fact("Resume", r.label) }
            if let s = job.submittedAt { fact("Applied", s.formatted(date: .abbreviated, time: .shortened)) }
            fact("Discovered", job.discoveredAt.formatted(date: .abbreviated, time: .shortened))
            if job.state == .skipped { fact("Skipped", BoardRules.skipTag(job.skipReason ?? job.stateReason, score: job.score, threshold: store.preferences.matchThreshold)) }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typography.callout).foregroundStyle(Palette.textSecondary).frame(width: 84, alignment: .leading)
            Text(value).font(Typography.callout).textSelection(.enabled)
        }
    }

    private func actions(_ job: JobItem) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button("Open job detail") { router.openJob(id: job.id) }.buttonStyle(.glassProminent)
            HStack {
                Button("New window") { router.openJobInWindow(id: job.id) }.buttonStyle(.glass)
                if let url = (job.applyURL ?? job.sourceURL).flatMap(URL.init(string:)) {
                    Button("Open posting") { NSWorkspace.shared.open(url) }.buttonStyle(.glass)
                }
            }
            let targets = BoardRules.legalTargets(for: job)
            if !targets.isEmpty {
                Menu("Move to…") {
                    ForEach(targets, id: \.self) { status in
                        Button(status.label) {
                            Task { await BoardModel(store: store).move(jobID: job.id, to: status, undoManager: undoManager) }
                        }
                    }
                }
                .fixedSize()
            }
        }
    }
}
