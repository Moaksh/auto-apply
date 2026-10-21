// CommandPaletteView.swift — the ⌘K palette content. The shell's CommandPaletteHost supplies
// the floating glass panel (640 wide, upper third); this view renders the search field,
// sectioned results and the shared selected-row look. ↑↓ move, ↵ opens, ⌘↵ opens the posting, ⌥↵ shows the job
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
                    Badge(scopeLabel(model.scope), tone: .accent)
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
                                Text("Try > for actions, @ for companies, ? for Needs You, / for settings.")
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
                            PaletteRow(item: item, isSelected: index == model.selection)
                                .id(item.id)
                                .onTapGesture {
                                    model.selection = index
                                    Task { await model.run(item) }
                                }
                                .onHover { inside in if inside { model.selection = index } }
                        }
                    }
                    .padding(Space.s)
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
            hint("?", "Needs You")
            hint("/", "settings")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
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
        case .actions: "Actions"
        case .companies: "Companies"
        case .questions: "Needs You"
        case .settings: "Settings"
        }
    }
}

private struct PaletteRow: View {
    var item: PaletteItem
    var isSelected: Bool

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
        .selectableRow(isSelected: isSelected, verticalPadding: Space.xs + 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
