// JobQuestionsPane.swift — Job detail's Questions tab: every open Needs You question blocking
// this job, answered in place with the Needs You composer (same drafts, Undo window and memory).
// An answer applies to every job that asks the same question, as it does in Needs You.
import SwiftUI

struct JobQuestionsPane: View {
    var job: JobItem
    /// Open questions blocking this job, in Needs You (impact) order; never empty while shown.
    var clusters: [QuestionCluster]
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    private var model: InboxModel { InboxModel.shared(for: store) }

    /// The question being answered: Needs You's selection when it's one of this job's, else the first.
    private var current: QuestionCluster? {
        clusters.first { $0.clusterId == model.selectedClusterID } ?? clusters.first
    }

    var body: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: Space.l) {
            Text(clusters.count == 1
                 ? "The agent stopped on this question. Answer it and the application resumes."
                 : "The agent stopped on \(clusters.count) questions. Answer them and the application resumes.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
            if clusters.count > 1 {
                VStack(spacing: 2) {
                    ForEach(Array(clusters.enumerated()), id: \.element.clusterId) { i, cluster in
                        questionRow(cluster, index: i + 1, isCurrent: cluster.clusterId == current?.clusterId)
                    }
                }
            }
            if let cluster = current {
                Divider()
                Group {
                    if cluster.isAction {
                        ActionPane(model: model, cluster: cluster, undoManager: undoManager, embedded: true)
                    } else {
                        AnswerComposer(model: model, cluster: cluster, undoManager: undoManager, embedded: true)
                    }
                }
                .id(cluster.clusterId)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        // The composer answers Needs You's selected question: keep it on one of this job's.
        .onAppear(perform: syncSelection)
        .onChange(of: clusters.map(\.clusterId)) { syncSelection() }
        .onChange(of: model.selectedClusterID) { syncSelection() }
    }

    private func questionRow(_ cluster: QuestionCluster, index: Int, isCurrent: Bool) -> some View {
        Button {
            model.select(cluster.clusterId)
        } label: {
            HStack(spacing: Space.s) {
                Text("\(index)")
                    .font(Typography.monoSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Palette.sunken, in: Circle())
                Image(systemName: cluster.isAction ? "hand.raised.fill" : "questionmark.bubble")
                    .foregroundStyle(cluster.isAction ? Palette.needsYou : Palette.textSecondary)
                Text(cluster.isAction ? InboxActionCopy.title(cluster) : cluster.canonicalQuestion)
                    .font(Typography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.s)
                if cluster.jobCount > 1 {
                    Text("\(cluster.jobCount) jobs").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(isCurrent ? Palette.accent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cluster.canonicalQuestion)\(isCurrent ? ", selected" : "")")
    }

    private func syncSelection() {
        guard let first = clusters.first else { return }
        if !clusters.contains(where: { $0.clusterId == model.selectedClusterID }) {
            model.select(first.clusterId)
        }
    }
}
