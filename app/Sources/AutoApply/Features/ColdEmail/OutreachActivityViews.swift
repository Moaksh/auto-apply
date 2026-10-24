// OutreachActivityViews.swift — what outreach is doing, where you look for it: a strip under the
// Companies finder (searches by stage, people being found, referrer searches, and a finished
// search's result for ten minutes), a small state on each prospect row ("Finding people…",
// "Google results queued") and a sentence in the prospect's People section. A small ProgressView
// shows only while work is really running; waiting shows a still clock with the reason. Lines
// arrive as rows and swap words in place (Motion.swift); nothing else moves.
import SwiftUI

/// The Companies tab's activity strip. Renders nothing when outreach is quiet.
struct OutreachActivityStrip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        // Re-read every 30 s so a finished result goes quiet and a wait's wording stays true.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            OutreachActivityLines(activity: store.outreach.activity(now: context.date))
        }
    }
}

struct OutreachActivityLines: View {
    var activity: OutreachActivity
    /// At most this many lines; the rest are summarised.
    var limit = 4

    var body: some View {
        let lines = Array(activity.lines.prefix(limit))
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(lines) { line in
                ActivityLineRow(line: line)
                    .motionTransition(.row)
            }
            if activity.lines.count > limit {
                Text("and \(activity.lines.count - limit) more")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .padding(.leading, Space.l + Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, lines.isEmpty ? 0 : Space.l)
        .padding(.vertical, lines.isEmpty ? 0 : Space.s)
        .background { if !lines.isEmpty { Palette.sunken.opacity(0.6) } }
        .motion(Motion.move, value: lines.map(\.id))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lines.map(\.text).joined(separator: ". "))
    }
}

private struct ActivityLineRow: View {
    var line: OutreachActivity.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            ActivityGlyph(phase: line.phase)
                .frame(width: Space.l, alignment: .center)
            Text(line.text)
                .font(Typography.callout)
                .foregroundStyle(line.phase == .waiting ? Palette.textSecondary : Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .wordSwap(line.text)
                .textSelection(.enabled)
        }
    }
}

/// Running: the standard small spinner. Waiting: a still clock. Done: a check.
private struct ActivityGlyph: View {
    var phase: OutreachActivity.Line.Phase

    var body: some View {
        switch phase {
        case .working:
            ProgressView().controlSize(.mini).accessibilityHidden(true)
        case .waiting:
            Image(systemName: "clock").imageScale(.small).foregroundStyle(Palette.textSecondary).accessibilityHidden(true)
        case .done:
            Image(systemName: "checkmark.circle.fill").imageScale(.small).foregroundStyle(Palette.accent).accessibilityHidden(true)
        }
    }
}

/// A prospect row's people state: "Finding people…" with a spinner, or "Google results queued".
struct ScoutPhaseTag: View {
    var phase: OutreachActivity.ScoutPhase

    var body: some View {
        HStack(spacing: Space.xs) {
            if phase.working {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "clock").imageScale(.small)
            }
            Text(phase.rowLabel).wordSwap(phase.rowLabel)
        }
        .font(Typography.callout)
        .foregroundStyle(Palette.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.rowLabel)
    }
}

/// The People section's sentence while people are being found at a company.
struct ScoutPhaseNote: View {
    var phase: OutreachActivity.ScoutPhase
    var company: String

    private var text: String {
        switch phase {
        case .site: "Finding people at \(company): reading their site, YC's page and GitHub…"
        case .googleRunning: "Reading Google results for people at \(company)…"
        case .googleQueued(let wait):
            "I looked on their site. Google results are next: " + OutreachActivity.waitText(wait, now: Date())
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            if phase.working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "clock").imageScale(.small).foregroundStyle(Palette.textSecondary)
            }
            Text(text).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .wordSwap(text)
        }
        .accessibilityElement(children: .combine)
    }
}
