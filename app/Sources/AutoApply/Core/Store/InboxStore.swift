// InboxStore.swift — Needs-You clusters (snapshot.open_clusters + question_opened/resolved).
import Foundation
import Observation

/// A cluster answered/skipped this session (the inbox's collapsed "Answered today" section).
struct ResolvedCluster: Identifiable, Sendable, Hashable {
    var id: String { clusterID }
    var clusterID: String
    var question: String
    var status: QuestionResolvedPayload.Status
    var jobCount: Int
    var resumedApplicationIDs: [Int]
    var at: Date
}

/// Needs-You items come in two kinds (wire `QuestionCluster.kind`): form *questions* the user
/// answers with a value, and agent *actions* — the agent is blocked and the user must do
/// something (create an account / sign in, solve a CAPTCHA, verify an email) and then retry.
/// Unknown kinds are treated as questions; an older daemon's CAPTCHA (reason only) is an action.
extension QuestionCluster {
    enum ActionType: String, Sendable {
        case account, captcha, verification, other
    }

    var isAction: Bool { kind == "action" || reason == .captcha }

    /// The blocker's subtype (nil for questions). Unknown values read as `.other`.
    var action: ActionType? {
        guard isAction else { return nil }
        if reason == .captcha { return .captcha }
        return actionType.flatMap(ActionType.init(rawValue:)) ?? .other
    }
}

@MainActor
@Observable
final class InboxStore {
    /// Open clusters, impact first (job count desc, then oldest first).
    private(set) var clusters: [QuestionCluster] = []
    private(set) var resolvedToday: [ResolvedCluster] = []
    /// Increments whenever a brand-new cluster arrives (drive `.symbolEffect(.bounce, value:)`).
    private(set) var arrivalCount = 0
    private(set) var lastArrivalAt: Date?

    init() {}

    var openCount: Int { clusters.count }

    /// Agent blockers ("to do") vs form questions.
    var actionCount: Int { clusters.filter(\.isAction).count }
    var questionCount: Int { clusters.count - actionCount }

    /// "3 to do · 34 questions" / "1 question" (empty when the inbox is empty).
    var summary: String { Self.summary(actions: actionCount, questions: questionCount) }

    nonisolated static func summary(actions: Int, questions: Int) -> String {
        var parts: [String] = []
        if actions > 0 { parts.append("\(actions) to do") }
        if questions > 0 { parts.append("\(questions) question\(questions == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Distinct jobs blocked by any open cluster.
    var jobsWaiting: Int { Set(clusters.flatMap(\.jobIds)).count }

    var next: QuestionCluster? { clusters.first }

    func cluster(id: String) -> QuestionCluster? { clusters.first { $0.clusterId == id } }

    // MARK: Reducer

    func reset(_ open: [QuestionCluster]) {
        clusters = Self.sorted(open)
    }

    func apply(_ event: DaemonEvent, now: Date = Date()) {
        switch event {
        case .snapshot(let snap):
            reset(snap.openClusters)
        case .questionOpened(let p):
            upsert(p.cluster, now: now)
        case .questionResolved(let p):
            resolve(p, now: now)
        default:
            break
        }
    }

    func upsert(_ cluster: QuestionCluster, now: Date = Date()) {
        if let i = clusters.firstIndex(where: { $0.clusterId == cluster.clusterId }) {
            clusters[i] = cluster
        } else {
            clusters.append(cluster)
            arrivalCount += 1
            lastArrivalAt = now
        }
        clusters = Self.sorted(clusters)
    }

    func resolve(_ p: QuestionResolvedPayload, now: Date = Date()) {
        let removed = clusters.first { $0.clusterId == p.clusterId }
        clusters.removeAll { $0.clusterId == p.clusterId }
        if !resolvedToday.contains(where: { $0.clusterID == p.clusterId }) {
            resolvedToday.insert(ResolvedCluster(
                clusterID: p.clusterId, question: removed?.canonicalQuestion ?? "Question", status: p.status,
                jobCount: removed?.jobCount ?? p.resumedApplicationIds.count,
                resumedApplicationIDs: p.resumedApplicationIds, at: now), at: 0)
        }
    }

    /// Optimistic removal; returns the cluster so callers can `restore` it on failure.
    @discardableResult
    func removeOptimistically(clusterID: String) -> QuestionCluster? {
        guard let i = clusters.firstIndex(where: { $0.clusterId == clusterID }) else { return nil }
        return clusters.remove(at: i)
    }

    func restore(_ cluster: QuestionCluster) {
        guard !clusters.contains(where: { $0.clusterId == cluster.clusterId }) else { return }
        clusters = Self.sorted(clusters + [cluster])
        resolvedToday.removeAll { $0.clusterID == cluster.clusterId }
    }

    nonisolated static func sorted(_ list: [QuestionCluster]) -> [QuestionCluster] {
        list.sorted { a, b in
            // Blockers first (the agent can't move until they're done), then impact.
            if a.isAction != b.isAction { return a.isAction }
            if a.jobCount != b.jobCount { return a.jobCount > b.jobCount }
            return a.createdAt < b.createdAt
        }
    }
}
