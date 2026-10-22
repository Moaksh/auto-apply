// EasyApplyView.swift — Easy Apply manual list (docs/UI_UX_PLAN.md §5.7): Unopened|All|Done
// filter, copy rows for drafted answers (click or C copies; icon morphs to a checkmark, the row
// flashes, HUD toast), "Open on LinkedIn" in the user's browser, a draggable resume PDF, and
// Mark as applied / Dismiss. ↑↓ move through rows so you can alt-tab and paste in sequence.
import SwiftUI
import UniformTypeIdentifiers

@objc(EasyApplyFeature)
final class EasyApplyFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.easyApply) { EasyApplyView() }
    }
}

struct EasyApplyView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced

    private var model: EasyApplyModel { EasyApplyModel.shared(for: store) }

    var body: some View {
        @Bindable var model = self.model
        let visible = model.visible
        VStack(spacing: 0) {
            ScreenHeader("Easy Apply", summary: "\(model.toDoCount) to do · LinkedIn jobs you apply to yourself") {
                Picker("Filter", selection: $model.filter) {
                    ForEach(EasyApplyModel.Filter.allCases) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            Divider()
            if visible.isEmpty {
                EmptyState(symbol: "bolt.horizontal",
                           title: model.filter == .done ? "Nothing marked as applied yet" : "No Easy Apply jobs to do",
                           message: "LinkedIn Easy Apply jobs land here with answers I've drafted. I never send them for you.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(get: { model.selectedJobID }, set: { model.select($0) })) {
                        ForEach(visible) { entry in
                            EasyApplyListRow(entry: entry, threshold: store.preferences.matchThreshold).tag(entry.id)
                        }
                    }
                    .listStyle(.inset)
                    // Rows marked done / dismissed leave (and new ones arrive) with the list's own animation.
                    .motion(Motion.move, value: visible.map(\.id))
                    .frame(width: 320)
                    Divider()
                    if let entry = model.selected {
                        EasyApplyDetail(model: model, entry: entry)
                            .id(entry.id)
                            .motionTransition(.fade)
                    } else {
                        EmptyState(symbol: "hand.point.left", title: "Pick a job").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Palette.windowBackground)
        .onAppear { model.ensureSelection() }
        .onChange(of: model.filter) { model.ensureSelection() }
        .onChange(of: store.library.easyApply) { model.ensureSelection() }
    }
}

private struct EasyApplyListRow: View {
    var entry: EasyApplyEntry
    var threshold: Int

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: entry.item.done ? "checkmark" : (entry.item.opened ? "circle" : "circle.fill"))
                .imageScale(.small)
                .foregroundStyle(entry.item.done ? Palette.applied : (entry.item.opened ? Palette.textTertiary : Palette.accent))
                .contentTransition(.symbolEffect(.replace))
                .motion(Motion.snappy, value: entry.item.done ? 2 : (entry.item.opened ? 1 : 0))
                .frame(width: 14)
                .accessibilityLabel(entry.item.done ? "Done" : (entry.item.opened ? "Opened" : "Unopened"))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.company).font(Typography.bodyEmph).lineLimit(1)
                Text(entry.title).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            if let score = entry.score { Badge(score: score, threshold: threshold) }
        }
        .padding(.vertical, 2)
        .opacity(entry.item.done ? 0.6 : 1)
    }
}

private struct EasyApplyDetail: View {
    var model: EasyApplyModel
    var entry: EasyApplyEntry
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @FocusState private var rowsFocused: Bool

    var body: some View {
        let rows = model.copyableAnswers(entry)
        let askMe = model.askMeAnswers(entry)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("\(entry.company) · \(entry.title)").font(Typography.title2)
                        HStack(spacing: Space.s) {
                            if let score = entry.score { Text("Match \(score)") }
                            if let posted = entry.job?.postedAt { Text("· posted \(C3Format.relative(posted))") }
                            if let loc = entry.job?.location { Text("· \(loc)") }
                        }
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Button {
                        model.openPosting()
                    } label: {
                        HStack(spacing: Space.xs) {
                            Text("Open on LinkedIn")
                            KeyCap(.openPosting)
                        }
                    }
                    .buttonStyle(.primaryPill)
                    .help("Opens in your browser. You apply; the agent never touches LinkedIn Easy Apply.")
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    HStack {
                        Text("Pre-drafted answers").eyebrowStyle()
                        Spacer()
                        Button {
                            model.copyAll()
                        } label: {
                            HStack(spacing: Space.xs) {
                                Text("Copy all")
                                KeyCap(.copyAll)
                            }
                        }
                        .buttonStyle(.secondaryLink)
                        .keyboardShortcut(.copyAll)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, answer in
                            CopyRow(answer: answer,
                                    isFocused: rowsFocused && index == model.focusedRow,
                                    isCopied: model.copiedRowID == answer.id,
                                    flashSerial: model.copiedRowID == answer.id ? model.copyFlashSerial : 0) {
                                model.focusedRow = index
                                model.copy(answer)
                            }
                            Divider()
                        }
                        ForEach(askMe) { answer in
                            HStack(spacing: Space.s) {
                                Text(answer.question).font(Typography.body).frame(width: 200, alignment: .leading)
                                Label("Ask me", systemImage: "hand.raised.fill")
                                    .font(Typography.callout)
                                    .foregroundStyle(Palette.needsYou)
                                Spacer()
                                Button("Answer in Needs You") { store.router.go(.needsYou) }.buttonStyle(.secondaryLink)
                            }
                            .padding(.horizontal, Space.m)
                            .padding(.vertical, Space.s)
                            Divider()
                        }
                        ResumeUploadRow(model: model, entry: entry)
                    }
                    .surface(cornerRadius: Radius.inner)
                    .focusable()
                    // The selected row / card shows keyboard focus; the system ring would outline the whole pane.
                    .focusEffectDisabled()
                    .focused($rowsFocused)
                    .onKeyPress(.downArrow) { model.moveFocusedRow(by: 1); return .handled }
                    .onKeyPress(.upArrow) { model.moveFocusedRow(by: -1); return .handled }
                    .onShortcut(.copyFocused) { model.copyFocused() }
                    .onShortcut(.openPosting) { model.openPosting() }
                    .onAppear { rowsFocused = true }
                }

                HStack(spacing: Space.s) {
                    Spacer()
                    if entry.item.done {
                        Label("Applied manually\(entry.item.doneAt.map { " · \(C3Format.relative($0))" } ?? "")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.applied)
                    } else {
                        Button("Dismiss") { Task { await model.dismiss() } }.buttonStyle(.secondaryLink)
                        Button {
                            Task { await model.markApplied() }
                        } label: {
                            Label("Mark as applied", systemImage: "checkmark")
                        }
                        .buttonStyle(.bordered)
                        .help("Moves the job to the Pipeline as Applied (LinkedIn Easy Apply, by you)")
                    }
                }
            }
            .padding(Space.contentPadding)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

/// Easy Apply copyable field: click (or C when focused) copies; icon morphs to a checkmark
/// and the row flashes a 10% accent tint for 0.3 s.
struct CopyRow: View {
    var answer: DraftedAnswer
    var isFocused: Bool
    var isCopied: Bool
    var flashSerial: Int
    var onCopy: () -> Void
    @State private var flashing = false
    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: Space.s) {
                HStack(spacing: 3) {
                    Text(answer.question).font(Typography.body)
                    if answer.locked { Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(Palette.textSecondary) }
                }
                .frame(width: 200, alignment: .leading)
                Text(answer.answer)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(isCopied ? Palette.applied : (hovering || isFocused ? Palette.accent : Palette.textTertiary))
                    .frame(width: 18)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .contentShape(Rectangle())
            .background(flashing ? Palette.accent.opacity(0.10) : (isFocused ? Palette.accent.opacity(0.06) : Color.clear))
            .overlay(alignment: .leading) {
                if isFocused { Rectangle().fill(Palette.accent).frame(width: 2) }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onChange(of: flashSerial) { _, serial in
            guard serial > 0 else { return }
            flashing = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(Motion.fade) { flashing = false }
            }
        }
        .accessibilityLabel("\(answer.question): \(answer.answer)")
        .accessibilityHint("Copies the answer")
    }
}

/// "Resume to upload": Reveal in Finder + a drag handle that drops the actual PDF file.
private struct ResumeUploadRow: View {
    var model: EasyApplyModel
    var entry: EasyApplyEntry

    var body: some View {
        let resume = model.resume(for: entry)
        let url = model.resumeURL(for: entry)
        HStack(spacing: Space.s) {
            Text("Resume to upload").font(Typography.body).frame(width: 200, alignment: .leading)
            if let resume {
                HStack(spacing: Space.xs) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(Palette.textTertiary)
                    Image(systemName: "doc.richtext").foregroundStyle(Palette.accent)
                    Text(url?.lastPathComponent ?? "\(resume.label).pdf").font(Typography.bodyEmph)
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, 3)
                .background(Palette.sunken, in: Capsule())
                .onDrag {
                    guard let url else { return NSItemProvider() }
                    let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
                    provider.suggestedName = url.lastPathComponent
                    return provider
                }
                .help(url == nil ? "The PDF isn't on disk yet" : "Drag into the LinkedIn upload field")
                Spacer()
                if let url {
                    Button("Reveal in Finder") { LocalFiles.reveal(url) }.buttonStyle(.secondaryLink)
                }
            } else {
                Text("No resume yet").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                Spacer()
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }
}

#Preview("Easy Apply") {
    let daemon = MockDaemon(scenario: .idle)
    let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
    store.start()
    return EasyApplyView()
        .environment(store)
        .environment(store.router)
        .frame(width: 1100, height: 720)
}
