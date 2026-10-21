// IssueBannerView.swift — the single global issue banner wired to the store: agent down, login
// expired, unexpected agent errors. Sits under the dashboard greeting.
import SwiftUI

struct IssueBannerView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    /// Issue ids another view on screen already shows (e.g. the live agent's "can't reach").
    var excluding: Set<String> = []
    @State private var showAll = false

    var body: some View {
        let issues = store.issues.filter { !excluding.contains($0.id) }
        Banner(issues: issues,
               onFix: { issue in Task { await store.fix(issue) } },
               onShowAll: { showAll = true },
               onDismiss: { issue in store.dismissIssue(issue.id) })
            .popover(isPresented: $showAll) {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(issues) { issue in
                        HStack(spacing: Space.s) {
                            Image(systemName: issue.severity == .error ? StatusKind.error.symbol : "exclamationmark.circle.fill")
                                .foregroundStyle(issue.severity == .error ? Palette.error : Palette.needsYou)
                            Text(issue.message).font(Typography.body)
                            Spacer()
                            if let title = issue.fixTitle {
                                Button(title) { Task { await store.fix(issue) } }.buttonStyle(.secondaryLink)
                            }
                        }
                    }
                }
                .padding(Space.l)
                .frame(width: 420)
            }
            .animation(Motion.snappy, value: issues.map(\.id))
    }
}
