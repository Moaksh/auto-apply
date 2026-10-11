// JobTimeline.swift — the Timeline tab (§5.4): a vertical list of events with SF Mono
// timestamps; agent events get a `cpu` mini-icon, user events a `person`.
import SwiftUI

struct JobTimeline: View {
    var items: [JobDetailRules.TimelineItem]

    var body: some View {
        if items.isEmpty {
            Text("No events yet.").font(Typography.callout).foregroundStyle(Palette.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: Space.m) {
                        Text(item.at.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                            .frame(width: 96, alignment: .trailing)
                        VStack(spacing: 0) {
                            Image(systemName: symbol(item))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(item.isError ? Palette.error : (item.actor == .user ? Palette.accent : Palette.textSecondary))
                                .frame(width: 20, height: 20)
                                .background(Palette.sunken, in: Circle())
                            if index < items.count - 1 {
                                Rectangle().fill(Palette.hairline).frame(width: 1).frame(maxHeight: .infinity)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(Typography.bodyEmph)
                            if let detail = item.detail, !detail.isEmpty {
                                Text(detail).font(Typography.mono).foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.bottom, Space.m)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.title), \(item.at.formatted(date: .abbreviated, time: .shortened)), by \(actorWord(item.actor))\(item.detail.map { ". \($0)" } ?? "")")
                }
            }
        }
    }

    private func symbol(_ item: JobDetailRules.TimelineItem) -> String {
        if item.isError { return "exclamationmark.triangle.fill" }
        switch item.actor {
        case .agent: return "cpu"
        case .user: return "person.fill"
        case .system: return "gearshape"
        }
    }

    private func actorWord(_ actor: Actor) -> String {
        switch actor {
        case .agent: "the agent"
        case .user: "you"
        case .system: "the system"
        }
    }
}
