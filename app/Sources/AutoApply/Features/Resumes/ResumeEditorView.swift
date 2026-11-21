// ResumeEditorView.swift — "Edit with Claude", in its own window: the resume's lines on the left
// (click one to edit it by hand), the live PDF in the middle, a conversation with Claude on the
// right. Claude's suggestions show in place as before / after diffs with the reason and, when the
// fact check couldn't back a claim, what it couldn't find; Accept / Reject per change, or Accept
// all for the backed ones. The PDF re-renders a moment after each change. Save stores the next
// version (or a new resume); the uploaded PDF stays as it is.
import PDFKit
import SwiftUI

struct ResumeEditorWindow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let variantID: Int
    @State private var model: ResumeEditorModel?

    var body: some View {
        Group {
            if let model {
                ResumeEditorView(model: model, onClose: { dismiss() })
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store.library.resume(id: variantID).map { "Edit \($0.label)" } ?? "Edit Resume")
        .task {
            let m = ResumeEditorModel(store: store, variantID: variantID)
            model = m
            await m.load()
        }
    }
}

struct ResumeEditorView: View {
    @Bindable var model: ResumeEditorModel
    var onClose: () -> Void
    @State private var editingID: String?
    @State private var newLabel = ""
    @State private var askNewLabel = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                document
                    .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                LivePDFPane(model: model)
                    .frame(minWidth: 380, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                ResumeChatPanel(model: model)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480, maxHeight: .infinity)
            }
        }
        .background(Palette.windowBackground)
        .alert("Save as a new resume", isPresented: $askNewLabel) {
            TextField("Label", text: $newLabel)
            Button("Save") { Task { if await model.save(asNew: true, label: newLabel) { onClose() } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's added next to \(model.variant?.label ?? "this resume"), which stays as it is.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit \(model.variant?.label ?? "resume") with Claude").font(Typography.title2)
                Text(subtitle).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            if model.phase == .saving {
                ProgressView().controlSize(.small)
                Text("Making the PDF…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            Button("Close", action: onClose).buttonStyle(.secondaryLink)
            Button("Save as new resume") {
                newLabel = "\(model.variant?.label ?? "Resume") (edited)"
                askNewLabel = true
            }
            .buttonStyle(.secondaryLink)
            .disabled(!model.canSave)
            Button("Save as v\((model.variant?.version ?? 1) + 1)") {
                Task { if await model.save() { onClose() } }
            }
            .buttonStyle(.primaryPill)
            .disabled(!model.canSave)
            .help("Makes the PDF and keeps the current version, so you can go back to it.")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }

    private var subtitle: String {
        guard let source = model.source else { return "Loading the source…" }
        let changed = model.changedIDs.count
        let waiting = model.pending.count
        var parts = [source.fileName]
        if changed > 0 { parts.append("\(changed) changed") }
        if waiting > 0 { parts.append("\(waiting) to review") }
        if let r = source.renderer { parts.append("PDF by \(r)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Document

    @ViewBuilder
    private var document: some View {
        if let message = model.errorMessage, model.source == nil {
            EmptyState(symbol: "doc.questionmark", title: "Can't open the source", message: message)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(Typography.callout).foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .onTapGesture { model.dismissError() }
                    }
                    if model.pending.count > 1 {
                        HStack {
                            Text("\(model.pending.count) suggested changes").eyebrowStyle()
                            Spacer()
                            Button("Accept all backed changes") { model.acceptAllGrounded() }
                                .buttonStyle(.secondaryLink)
                                .disabled(!model.pending.contains { $0.unsupportedClaims.isEmpty })
                        }
                    }
                    Text("Click a line to edit it, or ask Claude.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    ForEach(model.segments, id: \.id) { segment in
                        SegmentRow(model: model, segmentID: segment.id, editingID: $editingID)
                    }
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.sunken)
        }
    }
}

/// One segment: its text (click to edit by hand), or Claude's suggestion as a diff.
private struct SegmentRow: View {
    var model: ResumeEditorModel
    var segmentID: String
    @Binding var editingID: String?

    var body: some View {
        let changed = model.text(segmentID) != model.original[segmentID]
        VStack(alignment: .leading, spacing: Space.xs) {
            if let edit = model.pendingEdit(for: segmentID) {
                suggestion(edit)
            } else if editingID == segmentID {
                TextField("Text", text: Binding(get: { model.text(segmentID) }, set: { model.setText($0, for: segmentID) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.body)
                    .onSubmit { editingID = nil }
                HStack {
                    Button("Done") { editingID = nil }.buttonStyle(.secondaryLink)
                    if changed { Button("Undo my change") { model.revert(segmentID); editingID = nil }.buttonStyle(.secondaryLink) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle().fill(changed ? Palette.accent : .clear).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(model.text(segmentID))
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .contentShape(Rectangle())
                .onTapGesture { editingID = segmentID }
                .help("Click to edit it yourself")
                .contextMenu {
                    Button("Edit") { editingID = segmentID }
                    if changed { Button("Undo my change") { model.revert(segmentID) } }
                }
            }
        }
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.s)
        .background(model.pendingEdit(for: segmentID) != nil ? Palette.surface : .clear, in: .rect(cornerRadius: Radius.inner))
        .motion(Motion.snappy, value: model.pendingEdit(for: segmentID)?.after)
        .accessibilityElement(children: .contain)
    }

    private func suggestion(_ edit: ResumeEdit) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(edit.before)
                .font(Typography.body)
                .strikethrough(true, color: Palette.textTertiary)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Before: \(edit.before)")
            Text(edit.after)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Space.xs)
                .background(Palette.accent.opacity(0.10), in: .rect(cornerRadius: Radius.logo))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel("After: \(edit.after)")
            if !edit.unsupportedClaims.isEmpty {
                Label("I couldn't find \(ResumeEditorModel.list(edit.unsupportedClaims)) in your profile, stories or this resume.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.callout).foregroundStyle(Palette.needsYou)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.m) {
                if !edit.reason.isEmpty {
                    Text(edit.reason).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Reject") { model.reject(edit) }.buttonStyle(.secondaryLink)
                Button("Accept") { model.accept(edit) }.buttonStyle(.primaryPill).controlSize(.small)
            }
        }
        .motionTransition(.fade)
    }
}

// MARK: - Live PDF

/// The resume as it will print: re-rendered a moment after each change.
private struct LivePDFPane: View {
    @Bindable var model: ResumeEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Text("Preview").font(Typography.bodyEmph)
                if model.previewRendering {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                } else if let pages = model.previewPages {
                    Text(pages == 1 ? "1 page" : "\(pages) pages").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Toggle("Show Claude's suggestions", isOn: $model.previewSuggestions)
                    .toggleStyle(.checkbox)
                    .font(Typography.callout)
                    .disabled(model.pending.isEmpty)
                    .help("Preview the suggested changes before you accept them")
                if let path = model.previewPath, let url = LocalFiles.existing(path) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.plain)
                        .help("Open this PDF in Preview")
                        .accessibilityLabel("Open the PDF")
                }
            }
            .padding(Space.m)
            Divider()
            ZStack(alignment: .bottom) {
                if let path = model.previewPath, LocalFiles.existing(path) != nil {
                    PDFKitView(path: path, revision: model.previewRevision)
                } else {
                    EmptyState(symbol: "doc.richtext", title: "No preview yet",
                               message: model.source?.renderer == nil
                                   ? (model.source?.renderHint ?? "Nothing on this Mac can make the PDF yet.")
                                   : "The PDF shows here as you edit.")
                }
                if let error = model.previewError {
                    ScrollView {
                        Text(error)
                            .font(Typography.mono)
                            .foregroundStyle(Palette.error)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.m)
                    }
                    .frame(maxHeight: 180)
                    .background(Palette.surface)
                    .motionTransition(.slideIn(.bottom))
                }
            }
        }
        .background(Palette.sunken)
    }
}

/// PDFKit page view; reloads when `revision` changes and keeps the page you were on.
private struct PDFKitView: NSViewRepresentable {
    var path: String
    var revision: Int

    final class Coordinator { var loaded: Int = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.loaded != revision else { return }
        context.coordinator.loaded = revision
        let page = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        view.document = PDFDocument(url: URL(fileURLWithPath: path))
        if let doc = view.document, page > 0, page < doc.pageCount, let p = doc.page(at: page) { view.go(to: p) }
    }
}

// MARK: - Chat

private struct ResumeChatPanel: View {
    @Bindable var model: ResumeEditorModel
    @Environment(\.motionReduced) private var reduced
    @FocusState private var focused: Bool

    private static let suggestions = ["Tighten every bullet", "Lead with impact", "Make the summary one line", "Fix tense and punctuation"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                Image(systemName: "sparkle").foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text("Claude").font(Typography.bodyEmph)
                Spacer()
            }
            .padding(Space.m)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(model.messages) { message in
                            bubble(message).id(message.id)
                        }
                        if model.phase == .thinking {
                            HStack(spacing: Space.xs) {
                                if reduced {
                                    Image(systemName: "hourglass").foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                                Text("Reading your resume and profile…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                            }
                            .id("thinking")
                            .motionTransition(.fade)
                        }
                    }
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: model.phase) {
                    if model.phase == .thinking { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        .background(Palette.surface)
    }

    @ViewBuilder
    private func bubble(_ m: ResumeEditorModel.Message) -> some View {
        switch m.role {
        case .user:
            HStack {
                Spacer(minLength: Space.xl)
                Text(m.text)
                    .font(Typography.body)
                    .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                    .background(Palette.accent.opacity(0.12), in: .rect(cornerRadius: Radius.inner))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .motionTransition(.rise)
        case .claude:
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(m.text).font(Typography.body).fixedSize(horizontal: false, vertical: true)
                if let w = m.warning {
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.callout).foregroundStyle(Palette.needsYou)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .motionTransition(.rise)
        case .note:
            Label(m.text, systemImage: "info.circle")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if model.history.isEmpty {
                FlowLayout(spacing: Space.xs) {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button(s) { model.input = s; Task { await model.send() } }
                            .buttonStyle(.secondaryLink)
                            .font(Typography.callout)
                            .disabled(model.isBusy)
                    }
                }
            }
            HStack(spacing: Space.xs) {
                Menu {
                    Button("No job") { model.tailorJobID = nil }
                    Divider()
                    ForEach(model.tailorCandidates) { job in
                        Button(job.displayName) { model.tailorJobID = job.id }
                    }
                } label: {
                    Label(model.job(model.tailorJobID).map { "For \($0.company)" } ?? "Tailor for a job", systemImage: "scope")
                        .font(Typography.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isBusy || model.tailorCandidates.isEmpty)
                .help("Claude reads the job's description and rewords what's already true to fit it.")
                Spacer()
            }
            HStack(alignment: .bottom, spacing: Space.xs) {
                TextField(model.tailorJobID == nil ? "Ask Claude to change something…" : "Anything to focus on? (optional)",
                          text: $model.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($focused)
                    .disabled(model.isBusy || model.source == nil)
                    .onSubmit { Task { await model.send() } }
                    .accessibilityLabel("Ask Claude to change the resume")
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .disabled(model.isBusy || model.source == nil
                          || (model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.tailorJobID == nil))
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
            Text("Facts you state here count as yours. Claude never adds what your sources don't say.")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .onAppear { focused = true }
    }
}

#Preview("Resume editor") {
    let daemon = MockDaemon(scenario: .idle)
    let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
    store.start()
    return ResumeEditorWindow(variantID: 1)
        .environment(store)
        .frame(width: 1400, height: 860)
}
