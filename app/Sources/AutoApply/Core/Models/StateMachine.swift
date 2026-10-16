// StateMachine.swift — Swift mirror of the application state machine (contract/protocol.md §7)
// so the UI only offers legal moves. The daemon remains the enforcer.
import Foundation

extension AppState {
    /// Every allowed (from -> to) edge. `userOnly` edges require actor = user.
    static let allowedTransitions: [AppState: [(to: AppState, userOnly: Bool)]] = [
        .discovered: [(.scored, false), (.skipped, false), (.failed, false)],
        .scored: [(.queued, false), (.skipped, false)],
        .queued: [(.prepping, false), (.filling, false), (.skipped, false), (.failed, false)],
        .prepping: [(.queued, false), (.needsYou, false), (.filling, false), (.skipped, false), (.failed, false)],
        .needsYou: [(.queued, false), (.skipped, false), (.failed, false)],
        .filling: [(.needsYou, false), (.awaitingReview, false), (.submitting, false), (.queued, false), (.failed, false)],
        .awaitingReview: [(.submitting, true), (.skipped, true), (.queued, false)],
        .submitting: [(.submitted, false), (.failed, false), (.unknownVerify, false)],
        .unknownVerify: [(.submitted, true), (.failed, true)],
        .failed: [(.queued, true)],
        .skipped: [(.queued, true), (.discovered, false)],
        .submitted: [],
    ]

    func canTransition(to target: AppState, actor: Actor) -> Bool {
        guard let edges = Self.allowedTransitions[self] else { return false }
        return edges.contains { $0.to == target && (!$0.userOnly || actor == .user) }
    }

    /// States where the agent is actively working on the application.
    var isActive: Bool { self == .prepping || self == .filling || self == .submitting }

    /// Human label ("Needs you", "Awaiting review"…).
    var label: String {
        switch self {
        case .discovered: "Discovered"
        case .scored: "Scored"
        case .skipped: "Skipped"
        case .queued: "Queued"
        case .prepping: "Prepping"
        case .needsYou: "Needs you"
        case .filling: "Filling"
        case .awaitingReview: "Awaiting review"
        case .submitting: "Submitting"
        case .submitted: "Submitted"
        case .failed: "Failed"
        case .unknownVerify: "Verify submission"
        }
    }

    /// Stage on the dashboard's live pipeline flow.
    var flowStage: FlowStage {
        switch self {
        case .discovered: .discovered
        case .scored: .scored
        case .skipped: .skipped
        case .queued, .prepping: .queued
        case .needsYou: .needsYou
        case .filling, .awaitingReview, .submitting: .filling
        case .submitted: .submitted
        case .failed, .unknownVerify: .failed
        }
    }
}

extension BoardStatus {
    /// Board statuses in column order (⌘← / ⌘→ move through these).
    static let ordered: [BoardStatus] = [.applied, .assessment, .interview, .offer, .rejected, .ghosted]

    var next: BoardStatus? {
        guard let i = Self.ordered.firstIndex(of: self), i + 1 < Self.ordered.count else { return nil }
        return Self.ordered[i + 1]
    }

    var previous: BoardStatus? {
        guard let i = Self.ordered.firstIndex(of: self), i > 0 else { return nil }
        return Self.ordered[i - 1]
    }

    var label: String {
        switch self {
        case .applied: "Applied"
        case .assessment: "Assessment"
        case .interview: "Interview"
        case .offer: "Offer"
        case .rejected: "Rejected"
        case .ghosted: "Ghosted"
        }
    }

    /// Counts as a "response" for the response-rate KPI (ghosted does not).
    var isResponse: Bool { self == .assessment || self == .interview || self == .offer || self == .rejected }
}

/// Stages of the live pipeline flow (hero card).
enum FlowStage: String, CaseIterable, Sendable, Hashable {
    case discovered, scored, queued, filling, submitted
    // Branches
    case skipped, needsYou, failed

    /// The five main nodes, in order.
    static let main: [FlowStage] = [.discovered, .scored, .queued, .filling, .submitted]

    var title: String {
        switch self {
        case .discovered: "Discovered"
        case .scored: "Scored"
        case .queued: "Queued"
        case .filling: "Filling"
        case .submitted: "Submitted"
        case .skipped: "Skipped"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        }
    }
}

extension Ats {
    var label: String {
        switch self {
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .workday: "Workday"
        case .linkedinEasyApply: "LinkedIn Easy Apply"
        case .other: "Other"
        }
    }

    var shortLabel: String {
        switch self {
        case .greenhouse: "GH"
        case .lever: "LV"
        case .ashby: "AB"
        case .workday: "WD"
        case .linkedinEasyApply: "EA"
        case .other: "—"
        }
    }
}

extension JobSource {
    var label: String {
        switch self {
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .careers: "Career pages"
        case .linkedin: "LinkedIn"
        case .glassdoor: "Glassdoor"
        case .google: "Google Jobs"
        case .manual: "Manual"
        }
    }
}

extension DaemonActivity {
    var verb: String {
        switch self {
        case .idle: "Idle"
        case .discovering: "Discovering"
        case .scoring: "Scoring"
        case .prepping: "Prepping"
        case .applying: "Applying"
        }
    }
}
