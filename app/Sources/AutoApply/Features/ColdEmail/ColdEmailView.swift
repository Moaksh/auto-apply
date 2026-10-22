// ColdEmailView.swift — Cold Email (docs/COLD_EMAIL_PLAN.md §G.6, app/COLD_EMAIL_UX.md). One
// focused surface, Up next: drafts waiting for your OK, replies, and applications nobody has been
// written to yet, with the email itself on the right. People (everyone found or added, and who
// could refer you) and Companies (places you'd like to work) are one step away, not peers.
// Every email waits for your approval; at most one gentle follow-up goes out, only if you approve
// that too. LinkedIn is never automated.
import SwiftUI

@objc(ColdEmailFeature)
final class ColdEmailFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.coldEmail) { ColdEmailView() }
    }
}

struct ColdEmailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    /// Tests: render a given model (surface / phase) instead of the shared one.
    var modelOverride: ColdEmailModel?

    private var model: ColdEmailModel { modelOverride ?? ColdEmailModel.shared(for: store) }

    var body: some View {
        @Bindable var model = self.model
        VStack(alignment: .leading, spacing: 0) {
            ColdEmailHeader(model: model)
            Divider()
            Group {
                switch model.phase {
                case .loading:
                    LoadingState(message: "Loading your outreach…")
                case .error(let message):
                    ErrorState(title: "Can't show Cold Email", message: message)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    switch model.tab {
                    case .outbox: OutboxTab(model: model)
                    case .people: PeopleView(model: model)
                    case .prospects: ProspectsTab(model: model)
                    }
                }
            }
            // A fixed ideal height: the scrolling content's natural height (huge when probed at a
            // near-zero width, as wrapped text grows) must never become the screen's size, or the
            // split view is laid out taller than the window (BlankWindowRegressionTests).
            .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 400, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
            .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: model.tab)
        }
        .background(Palette.windowBackground)
        .sheet(isPresented: $model.isSendSheetPresented) { SendConfirmSheet(model: model).environment(store) }
        .sheet(isPresented: $model.isEnableSheetPresented) { EnableSendingSheet(model: model).environment(store) }
        .sheet(isPresented: $model.isAddContactPresented) { AddContactSheet().environment(store) }
        .sheet(isPresented: $model.isAddReferralPresented) { AddReferralSheet().environment(store) }
        .sheet(isPresented: $model.isLinkedInImportPresented) { LinkedInImportSheet(model: model).environment(store) }
    }
}

/// Home shows "Cold Email" with quiet doors to People and Companies; a secondary surface shows
/// its own name with a way back. No segmented control: the queue is the screen.
private struct ColdEmailHeader: View {
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        if model.tab == .outbox {
            ScreenHeader("Cold Email", summary: model.phase == .ready ? model.summary : "") {
                HStack(spacing: Space.l) {
                    door("People", symbol: "person.2", count: store.outreach.data.contacts.count) { model.showPeople(.everyone) }
                    door("Companies", symbol: "building.2", count: store.outreach.activeProspects.count) { model.tab = .prospects }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Button {
                    model.tab = .outbox
                } label: {
                    Label("Cold Email", systemImage: "chevron.left").font(Typography.callout)
                }
                .buttonStyle(.secondaryLink)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Up next (⌘[)")
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(model.tab == .people ? "People" : "Companies")
                        .font(Typography.title1)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.tab == .people
                         ? "Who you could write to, and who could refer you"
                         : "Places you'd like to work, even without an opening")
                        .font(Typography.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    Spacer(minLength: Space.s)
                    if model.tab == .people {
                        door("Companies", symbol: "building.2", count: store.outreach.activeProspects.count) { model.tab = .prospects }
                    } else {
                        door("People", symbol: "person.2", count: store.outreach.data.contacts.count) { model.showPeople(.everyone) }
                    }
                }
            }
            .padding(.horizontal, Space.contentPadding)
            .padding(.top, Space.m)
            .padding(.bottom, Space.l)
        }
    }

    private func door(_ title: String, symbol: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: symbol)
                Text(title)
                if count > 0 {
                    Text("\(count)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .buttonStyle(.secondaryLink)
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("\(title), \(count)")
    }
}
