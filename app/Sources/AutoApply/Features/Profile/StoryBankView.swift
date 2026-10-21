// StoryBankView.swift — the Story bank (docs/UI_UX_PLAN.md §5.8): stories on the left (title +
// tags + usage), a STAR editor on the right with one gentle text area per part, a "facts only"
// reminder, and an empty state with Import from text.
import SwiftUI

struct StoryBankView: View {
    @Environment(AppStore.self) private var store

    private var model: StoryBankModel { StoryBankModel.shared(for: store) }

    var body: some View {
        let model = self.model
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Story Bank").font(Typography.title1)
                Text(C3Format.plural(model.stories.count, "story", "stories")).font(Typography.body).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button { model.isImporting.toggle() } label: { Label("Import from text", systemImage: "doc.text") }
                    .buttonStyle(.glass)
                Button { model.newStory() } label: { Label("New story", systemImage: "plus") }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, Space.contentPadding)
            .padding(.vertical, Space.l)
            Divider()
            if model.isImporting {
                ImportStoryPanel(model: model)
                Divider()
            }
            if model.stories.isEmpty && model.draft == nil {
                EmptyState(symbol: "text.book.closed", title: "Add your first story",
                           message: "Stories make “why” and “tell us about a time” answers sound like you.",
                           actionTitle: "Import from text", prominent: true) { model.isImporting = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(get: { model.selectedStoryID }, set: { model.select($0) })) {
                        ForEach(model.stories) { story in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(story.title).font(Typography.bodyEmph).lineLimit(1)
                                if !story.tags.isEmpty {
                                    Text(story.tags.joined(separator: " · ")).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                                }
                                Text(model.usageLine(story)).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.vertical, 2)
                            .tag(story.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(width: 280)
                    Divider()
                    if model.draft != nil {
                        StoryEditor(model: model)
                    } else {
                        EmptyState(symbol: "text.book.closed", title: "Pick a story").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Palette.windowBackground)
        .onAppear { model.ensureSelection() }
        .onChange(of: store.library.stories) { model.ensureSelection() }
    }
}

private struct ImportStoryPanel: View {
    @Bindable var model: StoryBankModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Paste a story. “Situation: / Task: / Action: / Result:” labels are recognized; otherwise paragraphs fill S, T, A, R in order.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            TextEditor(text: $model.importText)
                .font(Typography.body).scrollContentBackground(.hidden).frame(height: 120).padding(Space.xs).sunkenWell()
            HStack {
                Spacer()
                Button("Cancel") { model.isImporting = false; model.importText = "" }.buttonStyle(.glass)
                Button("Create story") { model.applyImport() }
                    .buttonStyle(.glassProminent)
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, Space.contentPadding)
        .padding(.vertical, Space.m)
    }
}

private struct StoryEditor: View {
    @Bindable var model: StoryBankModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    TextField("Story title", text: draft(\.title))
                        .textFieldStyle(.plain)
                        .font(Typography.title2)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Competency tags").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        ChipField(values: Binding(get: { model.draft?.tags ?? [] }, set: { model.draft?.tags = $0 }),
                                  placeholder: "+ tag (leadership, scale…)")
                    }
                    starField("Situation", "The context: where, when, what was at stake.", \.situation)
                    starField("Task", "What you were responsible for.", \.task)
                    starField("Action", "What you did, specifically.", \.action)
                    starField("Result", "The outcome, with real numbers if you have them.", \.result)
                }
                .padding(Space.contentPadding)
                .frame(maxWidth: 720, alignment: .leading)
            }
            Divider()
            HStack(spacing: Space.s) {
                Image(systemName: "checkmark.shield").foregroundStyle(Palette.textSecondary)
                Text("Facts only. The agent quotes these; it won't invent metrics.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Spacer()
                if model.draft?.id != nil {
                    if model.confirmingDelete {
                        Text("Delete this story?").font(Typography.callout)
                        Button("Delete") { Task { await model.delete() } }.buttonStyle(.borderedProminent).tint(Palette.error)
                        Button("Keep") { model.confirmingDelete = false }.buttonStyle(.bordered)
                    } else {
                        Button("Delete") { model.confirmingDelete = true }.buttonStyle(.glass)
                    }
                }
                Button("Save") { Task { await model.save() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasUnsavedChanges || model.isSaving)
            }
            .padding(.horizontal, Space.contentPadding)
            .padding(.vertical, Space.m)
        }
    }

    private func draft(_ keyPath: WritableKeyPath<StoryDraftValue, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? "" }, set: { model.draft?[keyPath: keyPath] = $0 })
    }

    private func starField(_ title: String, _ hint: String, _ keyPath: WritableKeyPath<StoryDraftValue, String>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(title).font(Typography.bodyEmph)
                Text(hint).font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            TextEditor(text: draft(keyPath))
                .font(Typography.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64)
                .padding(Space.s)
                .sunkenWell()
        }
    }
}

#Preview("Story bank") {
    let daemon = MockDaemon(scenario: .idle)
    let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
    store.start()
    return StoryBankView()
        .environment(store)
        .environment(store.router)
        .frame(width: 1000, height: 700)
}
