// SetupSteps.swift — onboarding steps 1–2: System check (cascading rows, fix-it terminal well,
// "why this matters") and Resumes (drop zone, thumbnails, parse status) + Confirm profile.
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Step 1: System check

struct SystemCheckStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(title: "System check", subtitle: "AutoApply drives Chrome with Claude. Let's make sure the tools are here.")
        VStack(spacing: 0) {
            ForEach(Array(model.checks.enumerated()), id: \.element.id) { index, row in
                SystemCheckRowView(row: row) { Task { await model.runFix(for: row.name) } }
                if index < model.checks.count - 1 { Divider().padding(.leading, 40) }
            }
        }
        .surface()
        if model.checks.contains(where: { $0.item?.ok == false && $0.item?.required == true }) {
            Text("Continue unlocks once the required checks pass.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
    }
}

private struct SystemCheckRowView: View {
    var row: OnboardingModel.CheckRow
    var onFix: () -> Void
    @State private var showWhy = false
    @State private var showWell = false
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                statusIcon.frame(width: 20)
                Text(row.name.title).font(Typography.bodyEmph).frame(width: 130, alignment: .leading)
                Text(detail).font(Typography.mono).foregroundStyle(Palette.textSecondary).lineLimit(1)
                Spacer()
                if let version = row.item?.version, row.item?.ok == true {
                    Text(version).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                }
                if let item = row.item, !item.ok, item.fixCommand != nil {
                    Button(fixTitle(item)) {
                        showWell = true
                        onFix()
                    }
                    .buttonStyle(.secondaryLink)
                    .disabled(row.isFixing)
                }
            }
            if let item = row.item, !item.ok {
                DisclosureGroup("Why this matters", isExpanded: $showWhy) {
                    Text(row.name.whyItMatters).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Typography.callout)
                .padding(.leading, 32)
                if !item.required {
                    Text("Optional").font(Typography.callout).foregroundStyle(Palette.textTertiary).padding(.leading, 32)
                }
            }
            if showWell && !row.fixOutput.isEmpty {
                ScrollView {
                    Text(row.fixOutput)
                        .font(Typography.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s)
                }
                .frame(maxHeight: 120)
                .well()
                .padding(.leading, 32)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name.title): \(detail)")
    }

    private var detail: String {
        switch row.state {
        case .pending: "waiting"
        case .checking: "checking…"
        case .done: row.item?.detail ?? (row.item?.ok == true ? "ok" : "not found")
        }
    }

    private func fixTitle(_ item: SystemCheckItem) -> String {
        guard let cmd = item.fixCommand else { return "Fix" }
        if cmd.contains("claude.ai/install") { return "Install & log in…" }
        if cmd.contains("astral.sh/uv") { return "Install uv" }
        if cmd.contains("nodejs") { return "Install Node" }
        if cmd.contains("chrome") { return "Install Chrome" }
        if cmd.hasPrefix("brew") { return "Install with brew" }
        if cmd.contains("login") { return "Log in…" }
        if cmd.hasPrefix("npm") { return "Install with npm" }
        if item.name == .autoapplyd { return "Install agent" }
        return "Fix"
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(Palette.textTertiary)
        case .checking:
            Image(systemName: "circle.dotted")
                .foregroundStyle(Palette.accent)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduced)
        case .done:
            if row.item?.ok == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.applied)
                    .transition(.symbolEffect(.drawOn))
            } else if row.item?.required == false {
                Image(systemName: "minus.circle.fill").foregroundStyle(Palette.textTertiary)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.error)
            }
        }
    }
}

// MARK: - Step 2: Resumes

struct ResumesStep: View {
    @Bindable var model: OnboardingModel
    @State private var showImporter = false
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        StepHeader(title: "Your resumes", subtitle: "Add every approved version. The agent picks the best one per job, and never edits them.")
        DropZone(title: "Drop PDFs here or", subtitle: "PDF only", onDrop: { model.addResumes($0) }, onChoose: { showImporter = true })
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.addResumes(urls) }
            }
        if !model.resumes.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: Space.m)], alignment: .leading, spacing: Space.m) {
                ForEach($model.resumes) { $resume in
                    ResumeTile(resume: $resume) { model.removeResume(resume.id) }
                        .transition(AnyTransition.reduced(.cardIn, reduced))
                }
            }
            .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: model.resumes.map(\.id))
        }
    }
}

private struct ResumeTile: View {
    @Binding var resume: OnboardingModel.UploadedResume
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ZStack {
                Palette.sunken
                if let thumb = resume.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.richtext").font(.system(size: 28)).foregroundStyle(Palette.textTertiary)
                }
            }
            .frame(height: 150)
            .clipShape(.thumb)
            TextField("Label", text: $resume.label)
                .textFieldStyle(.plain)
                .font(Typography.bodyEmph)
            ChipField(values: $resume.tags, placeholder: "+ tag")
            HStack(spacing: Space.xs) {
                switch resume.status {
                case .parsing:
                    ProgressView().controlSize(.mini)
                    Text("parsing").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                case .parsed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.applied)
                    Text("parsed").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                case .failed(let message):
                    Image(systemName: StatusKind.error.symbol).foregroundStyle(Palette.error)
                    Text(message).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Spacer()
                Button(action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(resume.label)")
            }
        }
        .padding(Space.m)
        .surface()
    }
}

// MARK: - Step 2b: Confirm profile

struct ConfirmProfileStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(title: "Confirm your profile", subtitle: "Prefilled from your resume. Fix anything marked “Check this”.")
        Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.m) {
            GridRow {
                field("Full name", key: "full_name", text: binding(\.fullName))
                field("Email", key: "email", text: binding(\.email))
            }
            GridRow {
                field("Phone", key: "phone", text: binding(\.phone))
                field("Location", key: "location", text: binding(\.location))
            }
            GridRow {
                field("Headline", key: "headline", text: binding(\.headline))
                VStack(alignment: .leading, spacing: Space.xs) {
                    label("Years of experience", key: "years_experience")
                    TextField("5", value: $model.profileDraft.yearsExperience, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .underlineIfUncertain(model.uncertainFields.contains("years_experience"))
                }
            }
        }
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Skills").eyebrowStyle()
            ChipField(values: $model.profileDraft.skills, placeholder: "+ skill")
        }
        if !model.profileDraft.workHistory.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Experience").eyebrowStyle()
                ForEach(Array(model.profileDraft.workHistory.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: Space.s) {
                        Image(systemName: "doc.text.viewfinder").foregroundStyle(Palette.textTertiary)
                            .help("Parsed from your resume")
                        Text("\(item.title) · \(item.company)").font(Typography.body)
                        Spacer()
                        Text([item.start, item.end ?? "present"].compactMap { $0 }.joined(separator: " – "))
                            .font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .padding(Space.m)
            .surface()
        }
        if !model.profileDraft.education.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Education").eyebrowStyle()
                ForEach(Array(model.profileDraft.education.enumerated()), id: \.offset) { _, e in
                    Text([e.degree, e.field, e.school].compactMap { $0 }.joined(separator: " · ")).font(Typography.body)
                }
            }
            .padding(Space.m)
            .surface()
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Profile, String?>) -> Binding<String> {
        Binding(get: { model.profileDraft[keyPath: keyPath] ?? "" },
                set: { model.profileDraft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func label(_ title: String, key: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "doc.text.viewfinder").foregroundStyle(Palette.textTertiary).imageScale(.small)
                .help("Parsed from your resume")
            Text(title).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            if model.uncertainFields.contains(key) {
                Text("Check this").font(Typography.callout).foregroundStyle(Palette.needsYou)
            }
        }
    }

    private func field(_ title: String, key: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            label(title, key: key)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .underlineIfUncertain(model.uncertainFields.contains(key))
        }
        .frame(minWidth: 240)
    }
}

private extension View {
    /// Amber underline for uncertain parses.
    func underlineIfUncertain(_ uncertain: Bool) -> some View {
        overlay(alignment: .bottom) {
            if uncertain { Rectangle().fill(Palette.needsYou).frame(height: 1.5).offset(y: 2) }
        }
    }
}
