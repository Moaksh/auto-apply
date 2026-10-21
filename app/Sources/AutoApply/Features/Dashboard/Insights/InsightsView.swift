// InsightsView.swift — Dashboard ▸ What's working: an advisory read of your own results. Does the
// match score predict replies (rates only where a score range has enough applications), why jobs
// were skipped and which requirements keep blocking you, skills worth a look (never claim one you
// don't have), and how each resume variant does. Nothing is changed automatically.
// One primary action: Refresh. Summarize (one Claude request) is a secondary link.
import SwiftUI

struct InsightsView: View {
    @Environment(AppStore.self) private var store
    /// Tests: render a given model instead of the shared one.
    var modelOverride: InsightsModel?

    private var model: InsightsModel { modelOverride ?? InsightsModel.shared(for: store) }

    var body: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader("What's working", summary: model.insights.map { InsightsFormat.updated($0) } ?? "From your own applications") {
                HStack(spacing: Space.m) {
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    Button(model.isRefreshing ? "Refreshing…" : "Refresh") { Task { await model.load(force: true) } }
                        .buttonStyle(.primaryPill)
                        .disabled(model.isRefreshing || model.phase == .loading || !store.isConnected)
                        .help("Recompute from your latest outcomes (no Claude request)")
                }
            }
            Divider()
            content(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.windowBackground)
        .navigationTitle("What's working")
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private func content(_ model: InsightsModel) -> some View {
        switch model.phase {
        case .idle, .loading:
            LoadingState(message: "Reading your results…")
        case .failed(let message):
            ErrorState(title: "Couldn't read your results", message: message, actionTitle: nil, action: nil,
                       secondaryTitle: "Try again", secondaryAction: { Task { await model.load() } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let insights = model.insights {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.gutter) {
                        Label(InsightsFormat.advisory, systemImage: "info.circle")
                            .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        if let error = model.actionError { ErrorState(title: error, compact: true) }
                        CalibrationSurface(calibration: insights.calibration)
                        AdaptiveColumns(minColumnWidth: 380, maxColumns: 2) {
                            SkipReasonsSurface(blockers: insights.skipBlockers)
                            RequirementBlockersSurface(blockers: insights.skipBlockers)
                            UpskillSurface(upskill: insights.upskill, model: model)
                            VariantsSurface(variants: insights.variants)
                        }
                        .environment(\.surfaceFillsHeight, true)
                    }
                    .padding(Space.contentPadding)
                    .frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
    }
}

/// Does the match score predict replies? One row per score range.
private struct CalibrationSurface: View {
    var calibration: ScoreCalibration

    var body: some View {
        Surface("Does your match score predict replies?") {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(calibration.finding).font(Typography.body).fixedSize(horizontal: false, vertical: true)
                if !calibration.bands.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(calibration.bands.enumerated()), id: \.element.label) { i, band in
                            if i > 0 { Divider() }
                            HStack(spacing: Space.m) {
                                Text("Score \(band.label)").font(Typography.callout.weight(.medium)).frame(width: 96, alignment: .leading)
                                Text(InsightsFormat.bandCounts(band)).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                                    .frame(width: 180, alignment: .leading)
                                Text(InsightsFormat.bandRates(band))
                                    .font(band.enoughData ? Typography.callout : Typography.callout.italic())
                                    .foregroundStyle(band.enoughData ? Palette.textPrimary : Palette.textTertiary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, Space.s)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal, Space.m)
                    .well()
                }
                Text(InsightsFormat.calibrationFootnote(calibration))
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SkipReasonsSurface: View {
    var blockers: SkipBlockers

    var body: some View {
        let state: SurfaceState = blockers.reasons.isEmpty
            ? .empty(symbol: "arrow.uturn.right", message: "No jobs skipped in the last \(blockers.windowDays) days.") : .content
        Surface("Why jobs were skipped · last \(blockers.windowDays) days", state: state) {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(blockers.reasons, id: \.reason) { r in
                    CountRow(title: r.label, count: r.count, examples: r.examples)
                }
                Text("\(C3Format.plural(blockers.skipped, "job")) skipped in total.")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

private struct RequirementBlockersSurface: View {
    var blockers: SkipBlockers

    var body: some View {
        let state: SurfaceState = blockers.requirements.isEmpty
            ? .empty(symbol: "list.bullet.clipboard", message: "No requirement stood in the way on more than one skipped job.") : .content
        Surface("Requirements that keep coming up", state: state) {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(blockers.requirements, id: \.label) { r in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        CountRow(title: r.label, count: r.count, examples: r.examples, badge: InsightsFormat.kindLabel(r.kind))
                        if !r.wordings.isEmpty {
                            Text("Worded as: \(r.wordings.prefix(3).map { "“\($0)”" }.joined(separator: ", "))")
                                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("From the scorer's concerns on jobs you skipped.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

private struct UpskillSurface: View {
    var upskill: UpskillHints
    var model: InsightsModel
    @Environment(AppStore.self) private var store

    var body: some View {
        Surface("Skills to consider · last \(upskill.windowDays) days") {
            VStack(alignment: .leading, spacing: Space.s) {
                if upskill.hints.isEmpty {
                    Text("Nothing stands out yet. A skill shows here once it's named in \(upskill.minJobs) or more jobs you were skipped for or rejected from.")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(upskill.hints, id: \.skill) { h in
                    CountRow(title: h.skill, count: h.jobs, examples: h.examples,
                             detail: [h.skipped > 0 ? "\(h.skipped) skipped" : nil, h.rejected > 0 ? "\(h.rejected) rejected" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                }
                if let summary = upskill.summary, !summary.isEmpty {
                    Text(summary).font(Typography.body).fixedSize(horizontal: false, vertical: true)
                        .padding(Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .well()
                }
                Label(InsightsFormat.upskillAdvice, systemImage: "hand.raised")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !upskill.hints.isEmpty && (upskill.summary ?? "").isEmpty {
                    HStack(spacing: Space.s) {
                        Button(model.isSummarizing ? "Summarizing…" : "Summarize") { Task { await model.summarize() } }
                            .buttonStyle(.secondaryLink)
                            .disabled(model.isSummarizing || !store.isConnected)
                        Text("Uses one Claude request (counts toward your tokens).")
                            .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
    }
}

private struct VariantsSurface: View {
    var variants: VariantInsights

    var body: some View {
        let stats = InsightsFormat.variantStats(variants)
        let state: SurfaceState = stats.isEmpty ? .empty(symbol: "doc.on.doc", message: "Shows which resume hears back after your first applications.") : .content
        Surface("Resume variants", state: state) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(variants.finding).font(Typography.body).fixedSize(horizontal: false, vertical: true)
                VariantBars(variants: stats)
            }
        }
    }
}

/// "Title   12 jobs" with up to three examples underneath.
private struct CountRow: View {
    var title: String
    var count: Int
    var examples: [String]
    var badge: String?
    var detail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(title).font(Typography.body).fixedSize(horizontal: false, vertical: true)
                if let badge { Badge(badge) }
                Spacer(minLength: Space.s)
                if !detail.isEmpty { Text(detail).font(Typography.callout).foregroundStyle(Palette.textSecondary) }
                Text(C3Format.plural(count, "job")).font(Typography.metricSmall).foregroundStyle(Palette.textSecondary)
            }
            if !examples.isEmpty {
                Text(examples.prefix(3).joined(separator: " · "))
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Dashboard's way in: the score finding in one line and a link to the full report.
struct InsightsCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let model = InsightsModel.shared(for: store)
        Surface("What's working", accessory: {
            Button("Open") { router.showInsights() }
                .buttonStyle(.secondaryLink)
                .font(Typography.callout)
        }) {
            Text(teaser(model))
                .font(Typography.body)
                .foregroundStyle(model.insights == nil ? Palette.textSecondary : Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        }
        .task { await model.loadIfNeeded() }
    }

    private func teaser(_ model: InsightsModel) -> String {
        if let finding = model.insights?.calibration.finding, !finding.isEmpty { return finding }
        return "Which scores, resumes and requirements lead to replies, from your own results. Advisory only."
    }
}
