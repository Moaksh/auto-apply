// SidebarView.swift — the app's spine: Now / Library / System sections with badges, and the
// agent pill footer. The Needs You badge is prominent and its icon wiggles once when a question
// lands (an event, never idle). Badge counts roll (`numericRoll`) when they change and fade in
// and out at zero, so the sidebar's numbers move like the rest of the app's.
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
            SidebarRow(item: item, badge: badge(for: item), arrivalCount: item == .needsYou ? store.inbox.arrivalCount : 0,
                       cascade: item == .pipeline ? InboxModel.shared(for: store) : nil)
                .tag(item)
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .needsYou: store.needsYouCount
        case .review: (store.mode == .auto && store.counts.awaitingReview == 0) ? 0 : store.counts.awaitingReview
        case .easyApply: store.library.easyApplyOpenCount
        case .coldEmail: store.coldEmailBadge
        default: 0
        }
    }
}

private struct SidebarRow: View {
    var item: SidebarItem
    var badge: Int
    var arrivalCount: Int
    /// Pipeline only: Needs You's answer cascade lands here (Features/Inbox/AnswerCascade.swift).
    var cascade: InboxModel?
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        Label {
            HStack(spacing: Space.xs) {
                Text(item.title)
                Spacer(minLength: 0)
                if let cascade {
                    PipelineCascadeBadge(model: cascade)
                }
                SidebarCount(count: badge, prominent: item == .needsYou)
            }
        } icon: {
            Image(systemName: item.symbol)
                .symbolEffect(.wiggle, options: .nonRepeating, value: reduced ? 0 : arrivalCount)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduced ? 0 : cascade?.cascadePulse ?? 0)
                .background { if cascade != nil { CascadeAnchor(key: AnswerCascade.targetKey) } }
        }
        .accessibilityLabel(badge > 0 ? "\(item.title), \(badge)" : item.title)
    }
}

/// A sidebar row's count: rolls when it changes, fades in and out at zero. Needs You's is
/// prominent (amber on a faint amber capsule) because it's waiting on you.
private struct SidebarCount: View {
    var count: Int
    var prominent: Bool

    var body: some View {
        ZStack {
            if count > 0 {
                Text("\(count)")
                    .font(prominent ? Typography.callout.weight(.semibold) : Typography.callout)
                    .foregroundStyle(prominent ? Palette.needsYou : Palette.textSecondary)
                    .numericRoll(Double(count))
                    .padding(.horizontal, prominent ? 6 : 0)
                    .padding(.vertical, prominent ? 1 : 0)
                    .background(prominent ? Palette.needsYou.opacity(0.16) : .clear, in: Capsule())
                    .motionTransition(.scaleIn)
            }
        }
        .accessibilityHidden(true)
    }
}
