// CommandPaletteView.swift — the ⌘K palette content (docs/UI_UX_PLAN.md §3.3). The shell's
// CommandPaletteHost supplies the floating glass panel (640 wide, upper third, scale-in); this
// view renders the search field, sectioned results, and a single matched-geometry selection
// capsule that slides between rows. ↑↓ move, ↵ opens, ⌘↵ opens the posting, ⌥↵ shows the job
// in Pipeline, esc closes.
import SwiftUI

@objc(CommandPaletteFeature)
final class CommandPaletteFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.commandPalette) { CommandPaletteView() }
    }
}

struct CommandPaletteView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced
    @State private var model: PaletteModel?
    @FocusState private var focused: Bool
    @Namespace private var selectionNS

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear.frame(height: 60)
            }
        }
        .onAppear {
            let m = PaletteModel(store: store)
            m.query = router.paletteSeed
            model = m
            focused = true
        }
    }

    private func content(_ model: PaletteModel) -> some View {
        @Bindable var model = model
        let results = model.results
        return VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                TextField(model.scope.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(Typography.title2)
                    .focused($focused)
                    .onSubmit { Task { await model.run() } }
                if model.scope != .all {
                    Text(scopeLabel(model.scope)).font(Typography.monoSmall).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.12), in: Capsule())
                }
                KeyCap("esc")
            }
            .padding(Space.l)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if results.isEmpty {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("No matches").font(Typography.body).foregroundStyle(Palette.textSecondary)
                                Text("Try > for actions, @ for companies, ? for inbox questions, / for settings.")
                                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                            }
                            .padding(Space.l)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || results[index - 1].section != item.section {
                                Text(item.section.title).eyebrowStyle()
                                    .padding(.horizontal, Space.m)
                                    .padding(.top, index == 0 ? Space.xs : Space.m)
                                    .padding(.bottom, Space.xxs)
                            }
                            PaletteRow(item: item, isSelected: index == model.selection, selectionNS: selectionNS)
                                .id(item.id)
                                .onTapGesture {
                                    model.selection = index
                                    Task { await model.run(item) }
                                }
                                .onHover { inside in if inside { model.selection = index } }
                        }
                    }
                    .padding(Space.s)
                    .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: model.selection)
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: model.selection) { _, i in
                    if results.indices.contains(i) { proxy.scrollTo(results[i].id) }
                }
            }
            footer(model)
        }
        .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: results.count)
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.escape) { router.isPalettePresented = false; return .handled }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) { Task { await model.run(nil, .openPosting) }; return .handled }
            if press.modifiers.contains(.option) { Task { await model.run(nil, .showInPipeline) }; return .handled }
            return .ignored
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func footer(_ model: PaletteModel) -> some View {
        HStack(spacing: Space.m) {
            hint("↵", "open")
            if case .job? = model.selectedItem?.kind {
                hint("⌘↵", "open posting")
                hint("⌥↵", "show in Pipeline")
            }
            Spacer()
            hint(">", "actions")
            hint("@", "companies")
            hint("?", "inbox")
            hint("/", "settings")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(Palette.textPrimary.opacity(0.03))
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            KeyCap(key)
            Text(text).font(Typography.callout).foregroundStyle(Palette.textTertiary)
        }
    }

    private func scopeLabel(_ scope: PaletteScope) -> String {
        switch scope {
        case .all: ""
        case .actions: "ACTIONS"
        case .companies: "COMPANIES"
        case .questions: "INBOX"
        case .settings: "SETTINGS"
        }
    }
}

private struct PaletteRow: View {
    var item: PaletteItem
    var isSelected: Bool
    var selectionNS: Namespace.ID

    var body: some View {
        HStack(spacing: Space.s) {
            if let status = item.statusKind {
                StatusDot(kind: status)
                    .frame(width: 20)
            } else {
                Image(systemName: item.symbol).frame(width: 20).foregroundStyle(Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Typography.body).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(Typography.callout).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: Space.s)
            if let trailing = item.trailing {
                Text(trailing).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            if let shortcut = item.shortcut { KeyCap(shortcut) }
            if isSelected { Text("↵").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary) }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(Palette.accent.opacity(0.16))
                    .matchedGeometryEffect(id: "palette.selection", in: selectionNS)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
