// JobDetailModel.swift — data + rules for Job Detail (docs/UI_UX_PLAN.md §5.4): match factor
// ordering, the event timeline, "Copy all" text, the status menu's legal actions, and the
// loader that streams the Q&A audit and JD from the read-only repository.
import AppKit
import Foundation
import Observation

enum JobDetailRules {
    struct Factor: Hashable, Sendable {
        var name: String
        var value: Int
    }

    /// Factors in the spec's order (Skills, Seniority, Location, Salary, Domain), unknown ones
    /// after, alphabetically. Names are title-cased for display.
    static func orderedFactors(_ factors: [String: Int]) -> [Factor] {
        let order = ["skills", "seniority", "location", "salary", "domain"]
        return factors.map { Factor(name: $0.key, value: min(100, max(0, $0.value))) }
            .sorted { a, b in
                let ia = order.firstIndex(of: a.name.lowercased()) ?? Int.max
                let ib = order.firstIndex(of: b.name.lowercased()) ?? Int.max
                return ia != ib ? ia < ib : a.name < b.name
            }
            .map { Factor(name: $0.name.replacingOccurrences(of: "_", with: " ").capitalized, value: $0.value) }
    }

    /// Muted banner for skipped jobs: "Skipped · below threshold (64) · salary floor not met".
    static func skippedBanner(_ job: JobItem, threshold: Int) -> String? {
        guard job.state == .skipped else { return nil }
        var parts = ["Skipped"]
        let reason = job.skipReason ?? job.stateReason
        if BoardRules.skipReasonKey(reason) == "below_threshold", let score = job.score {
            parts.append("below threshold (\(score) < \(threshold))")
        } else {
            parts.append(BoardRules.skipReasonLabel(reason).lowercased())
            if let detail = reason?.split(separator: ":").dropFirst().first { parts.append(String(detail)) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Status menu

    enum StatusAction: Hashable, Sendable {
        case setStatus(BoardStatus)
        case retry
        case resolveSubmitted
        case resolveFailed
        case approve
        case reject
        case applyAnyway

        var title: String {
            switch self {
            case .setStatus(let s): s.label
            case .retry: "Retry application"
            case .resolveSubmitted: "It was submitted"
            case .resolveFailed: "It wasn't submitted"
            case .approve: "Approve & submit"
            case .reject: "Skip (reject)"
            case .applyAnyway: "Apply anyway"
            }
        }
    }

    /// Legal manual actions for the header status menu — the same rules as the board, plus the
    /// user-only edges the protocol exposes (retry, resolve unknown, approve/reject, apply anyway).
    static func statusActions(for job: JobItem) -> [StatusAction] {
        switch job.state {
        case .submitted: BoardRules.legalTargets(for: job).map { .setStatus($0) }
        case .failed: job.applicationID == nil ? [] : [.retry]
        case .unknownVerify: [.resolveSubmitted, .resolveFailed]
        case .awaitingReview: [.approve, .reject]
        case .skipped: job.applicationID == nil ? [] : [.applyAnyway]
        default: []
        }
    }

    // MARK: Copy all

    /// ⌘⇧C: all answers as formatted text.
    static func copyAllText(job: JobItem, answers: [ApplicationAnswerItem]) -> String {
        var lines = ["\(job.company) · \(job.title)", ""]
        for a in answers {
            lines.append("\(a.question)")
            lines.append(a.answer.isEmpty ? "—" : a.answer)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Timeline

    struct TimelineItem: Identifiable, Hashable, Sendable {
        var id: String
        var at: Date
        var title: String
        var detail: String?
        var actor: Actor
        var isError: Bool = false
    }

    /// Discovered (source) → Scored 91 → Queued → Filling (duration) → Submitted → Nudge day 7 →
    /// Moved to Interview (by you). Logged events win; milestones fill gaps when the log is
    /// missing them (e.g. trimmed history).
    static func timeline(job: JobItem, events: [ActivityEvent], now: Date = Date()) -> [TimelineItem] {
        var items: [TimelineItem] = []
        let kinds = Set(events.map { $0.kind.lowercased() })

        for e in events {
            items.append(TimelineItem(id: "e\(e.id)", at: e.ts, title: title(for: e), detail: e.message,
                                      actor: e.actor, isError: e.level == .error || e.kind.lowercased() == "error"))
        }
        if !kinds.contains("discover") {
            items.append(TimelineItem(id: "m-discovered", at: job.discoveredAt, title: "Discovered",
                                      detail: "via \(job.source.label)", actor: .agent))
        }
        if let score = job.score, !kinds.contains("score") {
            items.append(TimelineItem(id: "m-scored", at: job.scoredAt ?? job.discoveredAt, title: "Scored \(score)",
                                      detail: job.scoreSummary, actor: .agent))
        }
        if job.state == .skipped, !kinds.contains("skip") {
            items.append(TimelineItem(id: "m-skipped", at: job.stateUpdatedAt ?? job.discoveredAt, title: "Skipped",
                                      detail: BoardRules.skipReasonLabel(job.skipReason ?? job.stateReason), actor: .agent))
        }
        if let submitted = job.submittedAt, !kinds.contains("submit") {
            items.append(TimelineItem(id: "m-submitted", at: submitted, title: "Submitted",
                                      detail: job.mode == .manual ? "manually (Easy Apply)" : nil,
                                      actor: job.mode == .manual ? .user : .agent))
        }
        if let submitted = job.submittedAt {
            for (i, day) in [7, 14].enumerated() where job.nudgesSent > i {
                let at = submitted.addingTimeInterval(Double(day) * 86_400)
                if at <= now {
                    items.append(TimelineItem(id: "m-nudge\(day)", at: at, title: "Nudge · day \(day)", detail: "“Heard back?”", actor: .system))
                }
            }
        }
        if let status = job.status, status != .applied, let at = job.statusUpdatedAt, !kinds.contains("status") {
            items.append(TimelineItem(id: "m-status", at: at, title: "Moved to \(status.label)",
                                      detail: status == .ghosted ? "\(Int((at.timeIntervalSince(job.submittedAt ?? at)) / 86_400)) days without reply" : "by you",
                                      actor: status == .ghosted ? .system : .user))
        }
        return items.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    static func title(for event: ActivityEvent) -> String {
        switch event.kind.lowercased() {
        case "discover": "Discovered"
        case "score": "Scored"
        case "skip": "Skipped"
        case "queue", "queued": "Queued"
        case "fill": "Filling"
        case "resume": "Resume picked"
        case "cover_letter": "Cover letter"
        case "ask": "Asked you"
        case "answer": "Answered"
        case "review": "Ready for review"
        case "approve": "Approved"
        case "submit": "Submitted"
        case "status": event.actor == .user ? "Status changed (by you)" : "Status changed"
        case "nudge": "Nudge"
        case "error": "Error"
        default: event.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Screenshots

    struct Shot: Identifiable, Hashable, Sendable {
        var id: String { path }
        var label: String
        var path: String
    }

    /// Pre-submit page first, then the post-submit confirmation (filmstrip order).
    static func screenshots(for job: JobItem) -> [Shot] {
        var out: [Shot] = []
        if let p = job.screenshotPath, !p.isEmpty { out.append(Shot(label: "Pre-submit", path: p)) }
        if let p = job.confirmationScreenshotPath, !p.isEmpty { out.append(Shot(label: "Confirmation", path: p)) }
        return out
    }
}

/// Streams the Q&A audit and loads the JD for one job (repository is read-only).
@MainActor
@Observable
final class JobDetailLoader {
    private(set) var answers: [ApplicationAnswerItem] = []
    private(set) var answersLoaded = false
    private(set) var jobDescription: String?
    private(set) var descriptionLoaded = false

    init() {}

    func loadDescription(jobID: Int, fallback: String?, repository: any AppRepository) async {
        descriptionLoaded = false
        let text = await repository.jobDescription(jobID: jobID)
        jobDescription = text ?? fallback
        descriptionLoaded = true
    }

    /// Runs until cancelled (bind to `.task(id:)`).
    func streamAnswers(applicationID: Int?, repository: any AppRepository) async {
        answers = []
        answersLoaded = false
        guard let applicationID else {
            answersLoaded = true
            return
        }
        for await rows in repository.applicationAnswers(applicationID: applicationID) {
            answers = rows
            answersLoaded = true
        }
    }

    func copyAll(job: JobItem) {
        let text = JobDetailRules.copyAllText(job: job, answers: answers)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
