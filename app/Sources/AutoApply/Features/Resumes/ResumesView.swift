// ResumesView.swift — resume variants grid (docs/UI_UX_PLAN.md §5.9): LazyVGrid cards with real
// PDF first-page thumbnails (PDFKit, off-main), tags, sent/response stats and the default dot;
// hover lifts 2pt. Selecting a card drives the inspector: tags, default, enabled, and the jobs
// it was used for with outcome dots.
import SwiftUI
import UniformTypeIdentifiers

@objc(ResumesFeature)
final class ResumesFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.resumes) { ResumesView() }
        registry.registerInspector(for: .resumes) { ResumeInspector() }
    }
}

struct ResumesView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.motionReduced) private var reduced
    @State private var dropTargeted = false

    private var model: ResumesModel { ResumesModel.shared(for: store) }

    var body: some View {
        let model = self.model
        let variants = model.variants
        ScrollView {
            ScreenHeader("Resumes", summary: C3Format.plural(variants.count, "resume")) {
                if !model.adding.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Adding \(model.adding.joined(separator: ", "))…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .motionTransition(.fade)
                }
                Button { model.chooseAndAdd() } label: { Label("Add resume", systemImage: "plus") }
                    .buttonStyle(.primaryPill)
            }
            VStack(alignment: .leading, spacing: Space.l) {
                if variants.isEmpty {
                    DropZone(title: "Drop approved resume PDFs here or", subtitle: "They're copied into AutoApply and never modified.",
                             onDrop: { urls in Task { await model.add(urls) } }, onChoose: { model.chooseAndAdd() })
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: Space.gutter)], spacing: Space.gutter) {
                        ForEach(variants) { variant in
                            ResumeCard(model: model, variant: variant, isSelected: variant.id == model.selectedID)
                                .hoverResponse(cornerRadius: Radius.card)
                                .onTapGesture {
                                    model.selectedID = variant.id
                                    router.isInspectorPresented = true
                                }
                                .motionTransition(.scaleIn)
                        }
                    }
                    // A new resume scales in; the grid makes room with `move`.
                    .motion(Motion.move, value: variants.map(\.id))
                }
                HStack(spacing: Space.s) {
                    Text("How the agent picks:").eyebrowStyle()
                    Text("role keywords → tag overlap → past response rate").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                .padding(.top, Space.s)
            }
            .padding(.horizontal, Space.contentPadding)
            .padding(.bottom, Space.contentPadding)
        }
        .background(dropTargeted ? Palette.accent.opacity(0.05) : Palette.windowBackground)
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            Task { await model.add(pdfs) }
            return true
        } isTargeted: { targeted in
            if targeted && !dropTargeted { Haptics.generic() }
            dropTargeted = targeted
        }
        .onAppear { model.ensureSelection() }
        .onChange(of: store.library.resumeVariants) {
            model.reconcilePending()
            model.ensureSelection()
        }
    }
}

private struct ResumeCard: View {
    var model: ResumesModel
    var variant: ResumeVariantItem
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            PDFThumbnailView(path: variant.filePath)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .background(Palette.sunken, in: .inner)
                .clipShape(.inner)
            HStack(spacing: Space.xs) {
                Text(variant.label)
                    .font(Typography.bodyEmph).lineLimit(1)
                if variant.version > 1 {
                    Text("v\(variant.version)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                }
            }
            Text(model.tags(for: variant).isEmpty ? "no tags" : model.tags(for: variant).joined(separator: " · "))
                .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            HStack(spacing: Space.xs) {
                Text(model.statLine(for: variant)).font(Typography.callout).monospacedDigit()
                Spacer()
                if variant.isDefault {
                    HStack(spacing: 3) {
                        Circle().fill(Palette.accent).frame(width: 6, height: 6)
                        Text("default").font(Typography.callout)
                    }
                    .foregroundStyle(Palette.accent)
                } else if !variant.enabled {
                    Text("disabled").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .padding(Space.m)
        .surface()
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.card + 2, style: .continuous).stroke(Palette.accent, lineWidth: 2).padding(-2)
                    .motionTransition(.fade)
            }
        }
        .opacity(variant.enabled ? 1 : 0.6)
        .motion(Motion.fade, value: variant.enabled)
        .contentShape(Rectangle())
        .contextMenu {
            if let url = LocalFiles.existing(variant.filePath) {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") { LocalFiles.reveal(url) }
            }
            if !variant.isDefault { Button("Make default") { Task { await model.makeDefault(variant) } } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(variant.label) resume, \(model.statLine(for: variant))\(variant.isDefault ? ", default" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// First page of a PDF, rendered off-main and cached.
struct PDFThumbnailView: View {
    var path: String
    @State private var image: DecodedImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(Space.xs)
            } else {
                VStack(spacing: Space.xs) {
                    Image(systemName: missing ? "doc.questionmark" : "doc.richtext")
                        .font(.system(size: 30)).foregroundStyle(Palette.textTertiary)
                    if missing { Text("File not found").font(Typography.callout).foregroundStyle(Palette.textTertiary) }
                }
            }
        }
        .task(id: path) {
            missing = false
            guard let url = LocalFiles.existing(path) else { missing = true; image = nil; return }
            image = await C3Thumbnails.shared.pdfFirstPage(url, maxPixel: 480)
            missing = image == nil
        }
    }
}

// MARK: - Inspector

struct ResumeInspector: View {
    @Environment(AppStore.self) private var store
    @State private var labelDraft = ""

    private var model: ResumesModel { ResumesModel.shared(for: store) }

    var body: some View {
        let model = self.model
        if let variant = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        TextField("Label", text: $labelDraft)
                            .textFieldStyle(.plain)
                            .font(Typography.title2)
                            .onSubmit { Task { await model.rename(variant, to: labelDraft) } }
                        Text("v\(variant.version) · added \(variant.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Tags").eyebrowStyle()
                        ChipField(values: Binding(get: { model.tags(for: variant) }, set: { model.setTags($0, for: variant) }),
                                  placeholder: "+ tag (backend, go…)")
                        Text("Use for roles like these. The agent matches tags against the job.")
                            .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        Toggle("Default resume", isOn: Binding(get: { variant.isDefault }, set: { if $0 { Task { await model.makeDefault(variant) } } }))
                            .disabled(variant.isDefault)
                        Toggle("Enabled (the agent may pick it)", isOn: Binding(get: { variant.enabled }, set: { v in Task { await model.setEnabled(v, variant) } }))
                    }
                    if let url = LocalFiles.existing(variant.filePath) {
                        HStack {
                            Button("Open PDF") { NSWorkspace.shared.open(url) }
                            Button("Reveal in Finder") { LocalFiles.reveal(url) }
                        }
                        .buttonStyle(.secondaryLink)
                    }
                    Text("The file is read-only here: it's your approved resume and is never modified.")
                        .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    let used = model.jobs(usedBy: variant)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Used for \(C3Format.plural(used.count, "job"))").eyebrowStyle()
                        ForEach(used.prefix(30)) { job in
                            HStack(spacing: Space.s) {
                                StatusDot(kind: StatusKind(job: job))
                                Text(job.displayName).font(Typography.callout).lineLimit(1)
                                Spacer()
                                Text(StatusKind(job: job).label).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.router.go(.pipeline)
                                store.router.openJob(id: job.id)
                            }
                        }
                        if used.count > 30 {
                            Text("+\(used.count - 30) more").font(Typography.callout).foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
                .padding(Space.l)
            }
            .onAppear { labelDraft = variant.label }
            .onChange(of: variant.id) { labelDraft = variant.label }
            .onChange(of: variant.label) { labelDraft = variant.label }
        } else {
            EmptyState(symbol: "doc.on.doc", title: "Select a resume", message: "Its tags, usage and settings show here.")
        }
    }
}

#Preview("Resumes") {
    let daemon = MockDaemon(scenario: .idle)
    let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: "idle")
    store.start()
    return ResumesView()
        .environment(store)
        .environment(store.router)
        .frame(width: 1000, height: 700)
}
