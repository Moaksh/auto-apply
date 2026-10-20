// ReviewComponents.swift — the review pieces shared by the Review queue (§5.6) and Job detail
// (§5.4) when a job is awaiting review: the low-confidence "needs a look" rule, the
// screenshot + Q&A side-by-side panel with hover-linked field highlights, the inline-editable
// answer row and the resume / cover letter rows.
import SwiftUI

/// The approve safeguard's rules (pure; unit-tested). Medium/low-confidence answers need a look,
/// and unknown confidence (Q&A not loaded yet) is never treated as clean.
enum ReviewSafeguard {
    static func flaggedAnswers(_ answers: [ApplicationAnswerItem]) -> [ApplicationAnswerItem] {
        answers.filter { $0.confidenceLevel == .medium || $0.confidenceLevel == .low }
    }

    /// 2 = has a low-confidence answer, 1 = medium, 0 = clean.
    static func flagRank(_ answers: [ApplicationAnswerItem]) -> Int {
        if answers.contains(where: { $0.confidenceLevel == .low }) { return 2 }
        if answers.contains(where: { $0.confidenceLevel == .medium }) { return 1 }
        return 0
    }

    /// Needs the inline confirmation before approval.
    static func needsLook(answers: [ApplicationAnswerItem], loaded: Bool) -> Bool {
        !loaded || flagRank(answers) > 0
    }
}

/// Screenshot (left) + every Q&A with provenance, confidence and ✎ edit (right). Hovering a row
/// outlines its field on the screenshot.
struct ReviewQAPanel: View {
    var job: JobItem
    var answers: [ApplicationAnswerItem]
    var answersLoaded: Bool
    /// Inside an outer ScrollView (Job detail): the Q&A list doesn't scroll on its own and the
    /// screenshot gets a fixed height.
    var embedded = false
    var onEdit: (ApplicationAnswerItem, String) async -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onQuickLook: (URL) -> Void
    @State private var hoveredAnswerID: Int?

    var body: some View {
        let flagged = ReviewSafeguard.flaggedAnswers(answers)
        HStack(alignment: .top, spacing: Space.l) {
            ReviewScreenshotPane(path: job.screenshotPath, highlight: answers.first { $0.id == hoveredAnswerID }?.bbox,
                                 onQuickLook: onQuickLook)
                .frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
                .frame(height: embedded ? 560 : nil)
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text("Q&A (\(answers.count))").eyebrowStyle()
                    Spacer()
                    if !flagged.isEmpty {
                        Label("\(flagged.count) need\(flagged.count == 1 ? "s" : "") a look", systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.needsYou)
                    }
                }
                if embedded {
                    rows
                } else {
                    ScrollView { rows.padding(.bottom, 90) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if !answersLoaded {
                SkeletonBlock(lines: 5).padding(.vertical, Space.m)
            } else if answers.isEmpty {
                Text("No answers were recorded for this application.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Space.m)
            }
            ForEach(answers) { answer in
                ReviewAnswerRow(answer: answer, isHovered: hoveredAnswerID == answer.id, onSave: onEdit, onEditingChanged: onEditingChanged)
                    .onHover { inside in hoveredAnswerID = inside ? answer.id : (hoveredAnswerID == answer.id ? nil : hoveredAnswerID) }
                Divider()
            }
            ReviewAttachmentRows(job: job)
        }
    }
}

/// One audited answer: question, answer, provenance, confidence, inline ✎ edit.
struct ReviewAnswerRow: View {
    var answer: ApplicationAnswerItem
    var isHovered: Bool
    var onSave: (ApplicationAnswerItem, String) async -> Void
    /// Reports when the inline editor opens/closes (Job detail holds ⌘↵ approve while typing).
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            HStack(spacing: 3) {
                Text(answer.question).font(Typography.body).lineLimit(2)
                if answer.isLocked { Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(Palette.textSecondary) }
            }
            .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xs) {
                if editing {
                    if answer.fieldType == .textarea || answer.answer.count > 80 {
                        TextEditor(text: $draft)
                            .font(Typography.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80)
                            .padding(Space.xs)
                            .sunkenWell()
                            .focused($fieldFocused)
                    } else {
                        TextField("Answer", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .focused($fieldFocused)
                            .onSubmit(save)
                    }
                    HStack {
                        Button("Save", action: save).buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { editing = false }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    Text(answer.answer)
                        .font(Typography.body)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    HStack(spacing: Space.xs) {
                        ProvenanceTag(origin: answer.origin)
                        if let c = answer.confidence {
                            Text(String(format: "%.2f", c)).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            ConfidenceDot(level: answer.confidenceLevel).padding(.top, 4)
            if !answer.isLocked && answer.fieldType != .file && !editing {
                Button {
                    draft = answer.answer
                    editing = true
                    fieldFocused = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit this answer")
                .accessibilityLabel("Edit \(answer.question)")
            }
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.xs)
        .background(isHovered ? Palette.accent.opacity(0.06) : Color.clear)
        .background(answer.confidenceLevel == .low || answer.confidenceLevel == .medium ? Palette.needsYou.opacity(0.06) : Color.clear)
        .onChange(of: editing) { _, now in onEditingChanged(now) }
        .onDisappear { if editing { onEditingChanged(false) } }
    }

    private func save() {
        let text = draft
        editing = false
        Task { await onSave(answer, text) }
    }
}

/// Resume + cover letter rows under the Q&A.
struct ReviewAttachmentRows: View {
    var job: JobItem
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let resume = store.library.resume(id: job.resumeVariantID) ?? store.library.defaultResume {
                // Two lines: the file name (truncated in the middle, never wrapped letter by letter in a
                // narrow column), then the pick score and the Swap / Reveal controls.
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text("Resume").font(Typography.body).frame(width: 170, alignment: .leading)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.xs) {
                            Image(systemName: "doc.richtext")
                            Text("\(resume.label).pdf").font(Typography.body).lineLimit(1).truncationMode(.middle)
                                .help("\(resume.label).pdf")
                        }
                        HStack(spacing: Space.s) {
                            if let pick = job.resumePickScore {
                                Text(String(format: "pick %.2f", pick)).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                                    .fixedSize()
                            }
                            Spacer(minLength: 0)
                            let alternatives = store.library.resumeVariants.filter { $0.enabled && $0.id != resume.id }
                            if !alternatives.isEmpty, let appID = job.applicationID {
                                Menu {
                                    ForEach(alternatives) { variant in
                                        Button(variant.label) {
                                            Task { await store.setApplicationResume(applicationID: appID, resumeVariantID: variant.id) }
                                        }
                                    }
                                } label: {
                                    Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Use a different resume (the form is re-filled before it can be approved)")
                                .disabled(!store.isConnected)
                            }
                            if let url = LocalFiles.existing(resume.filePath) {
                                Button("Reveal") { LocalFiles.reveal(url) }.buttonStyle(.link).fixedSize()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, Space.s)
                Divider()
            }
            if let path = job.coverLetterPath {
                HStack(spacing: Space.s) {
                    Text("Cover letter").font(Typography.body).frame(width: 170, alignment: .leading)
                    Image(systemName: "envelope.open")
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(Typography.body).lineLimit(1)
                    Spacer()
                    if let url = LocalFiles.existing(path) {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                    }
                }
                .padding(.vertical, Space.s)
            }
        }
    }
}

/// Full-page pre-submit screenshot: scrollable, solid well (never glass), highlights the field
/// of the hovered answer. Decoded off-main. Click / Space opens Quick Look.
struct ReviewScreenshotPane: View {
    var path: String?
    var highlight: CGRect?
    var onQuickLook: (URL) -> Void
    @State private var image: DecodedImage?
    @State private var originalSize: CGSize?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                ScrollView {
                    let scaleBase = originalSize ?? image.size
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                if let highlight, scaleBase.width > 0 {
                                    let s = geo.size.width / scaleBase.width
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .stroke(Palette.accent, lineWidth: 2)
                                        .background(Palette.accent.opacity(0.12))
                                        .frame(width: highlight.width * s, height: highlight.height * s)
                                        .offset(x: highlight.minX * s, y: highlight.minY * s)
                                        .transition(.opacity)
                                }
                            }
                        }
                        .onTapGesture { if let url = LocalFiles.existing(path) { onQuickLook(url) } }
                }
                .clipShape(.thumb)
            } else {
                VStack(spacing: Space.s) {
                    Image(systemName: loaded ? "photo.on.rectangle.angled" : "photo")
                        .font(.system(size: 28)).foregroundStyle(Palette.textTertiary)
                    Text(loaded ? "No screenshot recorded" : "Loading screenshot…")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        .padding(Space.xs)
        .sunkenWell()
        .accessibilityLabel("Pre-submit screenshot")
        .task(id: path) {
            loaded = false
            image = nil
            guard let url = LocalFiles.existing(path) else { loaded = true; return }
            image = await C3Thumbnails.shared.image(url, maxPixel: 1600)
            originalSize = await C3Thumbnails.shared.originalSize(url)
            loaded = true
        }
    }
}

