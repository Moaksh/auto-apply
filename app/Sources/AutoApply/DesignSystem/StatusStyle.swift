// StatusStyle.swift — every status is a hue + an SF Symbol + a label (never color alone).
import SwiftUI

enum StatusKind: String, CaseIterable, Sendable, Hashable {
    case discovered, skipped, queued, filling, needsYou, applied, assessment, interview, offer, rejected, ghosted, error

    var color: Color {
        switch self {
        case .discovered: Palette.discovered
        case .skipped: Palette.skipped
        case .queued: Palette.queued
        case .filling: Palette.accent
        case .needsYou: Palette.needsYou
        case .applied: Palette.applied
        case .assessment: Palette.assessment
        case .interview: Palette.interview
        case .offer: Palette.offer
        case .rejected: Palette.rejected
        case .ghosted: Palette.ghosted
        case .error: Palette.error
        }
    }

    var symbol: String {
        switch self {
        case .discovered: "sparkle.magnifyingglass"
        case .skipped: "arrow.uturn.right"
        case .queued: "tray.full"
        case .filling: "pencil.and.outline"
        case .needsYou: "hand.raised.fill"
        case .applied: "paperplane.fill"
        case .assessment: "doc.text.magnifyingglass"
        case .interview: "person.2.fill"
        case .offer: "star.fill"
        case .rejected: "xmark"
        case .ghosted: "moon.zzz"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .discovered: "Discovered"
        case .skipped: "Skipped"
        case .queued: "Queued"
        case .filling: "Filling"
        case .needsYou: "Needs you"
        case .applied: "Applied"
        case .assessment: "Assessment"
        case .interview: "Interview"
        case .offer: "Offer"
        case .rejected: "Rejected"
        case .ghosted: "Ghosted"
        case .error: "Error"
        }
    }

    init(state: AppState, status: BoardStatus? = nil) {
        switch state {
        case .discovered, .scored: self = .discovered
        case .skipped: self = .skipped
        case .queued: self = .queued
        case .prepping, .filling, .submitting, .awaitingReview: self = .filling
        case .needsYou: self = .needsYou
        case .failed, .unknownVerify: self = .error
        case .submitted: self = StatusKind(status: status ?? .applied)
        }
    }

    init(status: BoardStatus) {
        switch status {
        case .applied: self = .applied
        case .assessment: self = .assessment
        case .interview: self = .interview
        case .offer: self = .offer
        case .rejected: self = .rejected
        case .ghosted: self = .ghosted
        }
    }

    init(job: JobItem) { self.init(state: job.state, status: job.status) }

    init(column: BoardColumn) {
        switch column {
        case .discovered: self = .discovered
        case .skipped: self = .skipped
        case .queued: self = .queued
        case .needsYou: self = .needsYou
        case .applied: self = .applied
        case .assessment: self = .assessment
        case .interview: self = .interview
        case .offer: self = .offer
        case .rejected: self = .rejected
        case .ghosted: self = .ghosted
        }
    }
}
