// SidebarView.swift — the app's spine: Now / Library / System sections with badges, and the
// Agent Pill footer (§3.2). Needs You badge is amber and wiggles once when a question lands.
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        @Bindable var router = router
        List(selection: Binding(get: { router.selection }, set: { if let s = $0 { router.go(s) } })) {
            ForEach(SidebarItem.Section.allCases, id: \.self) { section in
                if let title = section.title {
                    Section(title) { rows(section) }
                } else {
                    Section { rows(section) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            AgentPill(status: store.agentStatus) { router.go(.dashboard) }
                .padding(Space.s)
        }
    }

    @ViewBuilder
    private func rows(_ section: SidebarItem.Section) -> some View {
        ForEach(section.items) { item in
            SidebarRow(item: item, badge: badge(for: item), arrivalCount: item == .needsYou ? store.inbox.arrivalCount : 0)
                .tag(item)
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .needsYou: store.inbox.openCount
        case .review: (store.mode == .auto && store.counts.awaitingReview == 0) ? 0 : store.counts.awaitingReview
        case .easyApply: store.library.easyApplyOpenCount
        default: 0
        }
    }
}

private struct SidebarRow: View {
    var item: SidebarItem
    var badge: Int
    var arrivalCount: Int
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        Label {
            Text(item.title)
            if item == .coldEmail {
                Text("BETA").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Palette.accent.opacity(0.14), in: Capsule())
            }
        } icon: {
            Image(systemName: item.symbol)
                .symbolEffect(.wiggle, options: .nonRepeating, value: reduced ? 0 : arrivalCount)
        }
        .badge(badge)
        .badgeProminence(item == .needsYou && badge > 0 ? .increased : .standard)
        .accessibilityLabel(badge > 0 ? "\(item.title), \(badge)" : item.title)
    }
}
