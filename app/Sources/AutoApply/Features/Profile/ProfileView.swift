// ProfileView.swift — Profile as a form-style document (docs/UI_UX_PLAN.md §5.8): Identity,
// Contact, Links, Experience, Education, Skills, Facts only you set (locked styling), and Saved
// answers (from Needs You, with inline edit / delete).
import SwiftUI

@objc(ProfileFeature)
final class ProfileFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.profile) { ProfileView() }
        registry.register(.stories) { StoryBankView() }
    }
}

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced

    private var model: ProfileModel { ProfileModel.shared(for: store) }

    var body: some View {
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Profile").font(Typography.title1)
                    Spacer()
                    if let updated = model.profile.updatedAt {
                        Text("Last updated \(C3Format.relative(updated))").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                    if model.isEditing {
                        Button("Cancel") { model.cancelEditing() }.buttonStyle(.secondaryLink)
                        Button("Save") { Task { await model.save() } }
                            .buttonStyle(.primaryPill)
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(model.isSaving)
                    } else {
                        Button { model.beginEditing() } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(.secondaryLink)
                    }
                }
                if model.isEditing {
                    ProfileEditor(model: model)
                        .transition(.opacity)
                } else {
                    ProfileDocument(profile: model.profile)
                        .transition(.opacity)
                }
                NeverGuessSummary()
                MemorySection(model: model)
            }
            .padding(Space.contentPadding)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(Motion.resolve(Motion.snappy, reduceMotion: reduced), value: model.isEditing)
        }
        .background(Palette.windowBackground)
    }
}

/// "─ IDENTITY ────" section rule.
struct DocumentSection<Trailing: View, Content: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(title).eyebrowStyle()
                Rectangle().fill(Palette.hairline).frame(height: 0.5)
                trailing()
            }
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

// MARK: - Read-only document

private struct ProfileDocument: View {
    var profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            DocumentSection("Identity") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(profile.fullName ?? "Your name").font(Typography.title2)
                        .foregroundStyle(profile.fullName == nil ? Palette.textTertiary : Palette.textPrimary)
                    Text([profile.headline, profile.location].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(Typography.body).foregroundStyle(Palette.textSecondary)
                    if let years = profile.yearsExperience {
                        Text("\(years.formatted(.number.precision(.fractionLength(0...1)))) years of experience")
                            .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                    if let summary = profile.summary { Text(summary).font(Typography.body).padding(.top, Space.xs) }
                }
            }
            DocumentSection("Contact") {
                Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.xs) {
                    field("Email", profile.email)
                    field("Phone", profile.phone)
                }
            }
            DocumentSection("Links") {
                if profile.links.isEmpty { empty("No links yet") }
                ForEach(profile.links.keys.sorted(), id: \.self) { key in
                    HStack(spacing: Space.s) {
                        Text(key.capitalized).font(Typography.body).frame(width: 110, alignment: .leading)
                        if let url = URL(string: profile.links[key] ?? "") {
                            Link(profile.links[key] ?? "", destination: url).font(Typography.mono)
                        }
                    }
                }
            }
            DocumentSection("Experience") {
                if profile.workHistory.isEmpty { empty("No experience parsed yet") }
                ForEach(Array(profile.workHistory.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(item.title.isEmpty ? "Role" : item.title) · \(item.company)").font(Typography.bodyEmph)
                            Spacer()
                            Text([item.start, item.end ?? "present"].compactMap { $0 }.joined(separator: " – "))
                                .font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                        }
                        ForEach(item.highlights, id: \.self) { h in
                            Text("• \(h)").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            DocumentSection("Education") {
                if profile.education.isEmpty { empty("No education listed") }
                ForEach(Array(profile.education.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text([item.degree, item.field].compactMap { $0 }.joined(separator: ", ") + " · \(item.school)").font(Typography.body)
                        Spacer()
                        Text([item.start, item.end].compactMap { $0 }.joined(separator: " – ")).font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            DocumentSection("Skills") {
                if profile.skills.isEmpty { empty("No skills listed") }
                FlowLayout(spacing: Space.xs) {
                    ForEach(profile.skills, id: \.self) { skill in
                        Text(skill).font(Typography.body)
                            .padding(.horizontal, Space.s).padding(.vertical, 3)
                            .background(Palette.sunken, in: Capsule())
                    }
                }
            }
        }
    }

    private func field(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).font(Typography.body).foregroundStyle(Palette.textSecondary)
            Text(value ?? "—").font(Typography.body).textSelection(.enabled)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Typography.callout).foregroundStyle(Palette.textTertiary)
    }
}

// MARK: - Editor

private struct ProfileEditor: View {
    @Bindable var model: ProfileModel

    var body: some View {
        if model.draft != nil {
            VStack(alignment: .leading, spacing: Space.xl) {
                DocumentSection("Identity") {
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                        row("Full name", \.fullName)
                        row("First name", \.firstName)
                        row("Last name", \.lastName)
                        row("Headline", \.headline)
                        row("Location", \.location)
                        GridRow {
                            Text("Years of experience").font(Typography.body)
                            TextField("5", value: binding(\.yearsExperience), format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                        }
                    }
                    Text("Summary").font(Typography.body).padding(.top, Space.xs)
                    TextEditor(text: Binding(get: { model.draft?.summary ?? "" }, set: { model.draft?.summary = $0 }))
                        .font(Typography.body).scrollContentBackground(.hidden).frame(minHeight: 70).padding(Space.xs).well()
                }
                DocumentSection("Contact") {
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                        row("Email", \.email)
                        row("Phone", \.phone)
                    }
                }
                DocumentSection("Links") {
                    ForEach((model.draft?.links ?? [:]).keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key.capitalized).frame(width: 110, alignment: .leading)
                            TextField("https://…", text: Binding(get: { model.draft?.links[key] ?? "" }, set: { model.draft?.links[key] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button { model.draft?.links.removeValue(forKey: key) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("name (github)", text: $model.linkDraftKey).textFieldStyle(.roundedBorder).frame(width: 140)
                        TextField("https://…", text: $model.linkDraftValue).textFieldStyle(.roundedBorder).onSubmit { model.addLink() }
                        Button("Add") { model.addLink() }
                    }
                }
                DocumentSection("Experience") {
                    ForEach(Array((model.draft?.workHistory ?? []).indices), id: \.self) { i in
                        WorkHistoryEditor(item: Binding(
                            get: { model.draft?.workHistory[c3Safe: i] ?? WorkHistoryItem(company: "", title: "") },
                            set: { if model.draft?.workHistory.indices.contains(i) == true { model.draft?.workHistory[i] = $0 } }),
                            onRemove: { model.draft?.workHistory.remove(at: i) })
                    }
                    Button { model.draft?.workHistory.append(WorkHistoryItem(company: "", title: "")) } label: { Label("Add role", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
                DocumentSection("Education") {
                    ForEach(Array((model.draft?.education ?? []).indices), id: \.self) { i in
                        HStack {
                            TextField("School", text: eduBinding(i, \.school)).textFieldStyle(.roundedBorder)
                            TextField("Degree", text: eduOptional(i, \.degree)).textFieldStyle(.roundedBorder).frame(width: 110)
                            TextField("Field", text: eduOptional(i, \.field)).textFieldStyle(.roundedBorder).frame(width: 150)
                            TextField("End", text: eduOptional(i, \.end)).textFieldStyle(.roundedBorder).frame(width: 70)
                            Button { model.draft?.education.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    Button { model.draft?.education.append(EducationItem(school: "")) } label: { Label("Add school", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
                DocumentSection("Skills") {
                    ChipField(values: Binding(get: { model.draft?.skills ?? [] }, set: { model.draft?.skills = $0 }), placeholder: "+ skill")
                }
            }
        }
    }

    private func row(_ title: String, _ keyPath: WritableKeyPath<Profile, String?>) -> some View {
        GridRow {
            Text(title).font(Typography.body)
            TextField(title, text: Binding(get: { model.draft?[keyPath: keyPath] ?? "" },
                                           set: { model.draft?[keyPath: keyPath] = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Profile, T?>) -> Binding<T?> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? nil }, set: { model.draft?[keyPath: keyPath] = $0 })
    }

    private func eduBinding(_ i: Int, _ keyPath: WritableKeyPath<EducationItem, String>) -> Binding<String> {
        Binding(get: { model.draft?.education[c3Safe: i]?[keyPath: keyPath] ?? "" },
                set: { if model.draft?.education.indices.contains(i) == true { model.draft?.education[i][keyPath: keyPath] = $0 } })
    }

    private func eduOptional(_ i: Int, _ keyPath: WritableKeyPath<EducationItem, String?>) -> Binding<String> {
        Binding(get: { model.draft?.education[c3Safe: i]?[keyPath: keyPath] ?? "" },
                set: { if model.draft?.education.indices.contains(i) == true { model.draft?.education[i][keyPath: keyPath] = $0.isEmpty ? nil : $0 } })
    }
}

private struct WorkHistoryEditor: View {
    @Binding var item: WorkHistoryItem
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                TextField("Company", text: $item.company).textFieldStyle(.roundedBorder)
                TextField("Title", text: $item.title).textFieldStyle(.roundedBorder)
                TextField("Start", text: Binding(get: { item.start ?? "" }, set: { item.start = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                TextField("End", text: Binding(get: { item.end ?? "" }, set: { item.end = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            TextEditor(text: Binding(get: { item.highlights.joined(separator: "\n") },
                                     set: { item.highlights = $0.components(separatedBy: "\n") }))
                .font(Typography.callout).scrollContentBackground(.hidden).frame(minHeight: 44).padding(Space.xs).well()
            Text("One highlight per line. Facts only: the agent draws on these.").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
        }
        .padding(.vertical, Space.xs)
    }
}

// MARK: - Facts only you set (locked)

private struct NeverGuessSummary: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let ng = store.library.neverGuess
        DocumentSection("Facts only you set", trailing: {
            Label("the agent never guesses these", systemImage: "lock.fill").font(Typography.callout).foregroundStyle(Palette.textSecondary).fixedSize()
        }) {
            VStack(spacing: Space.xs) {
                LockedField(title: "Sponsorship", isEmpty: ng.sponsorship == nil) { Text(ng.sponsorship ?? "") }
                LockedField(title: "Salary", isEmpty: ng.salaryExpectation == nil) {
                    Text([ng.salaryExpectation, ng.salaryNegotiable == true ? "negotiable" : nil].compactMap { $0 }.joined(separator: ", "))
                }
                LockedField(title: "Notice", isEmpty: ng.noticePeriod == nil) { Text(ng.noticePeriod ?? "") }
                LockedField(title: "Start date", isEmpty: ng.startDate == nil) { Text(ng.startDate ?? "") }
                LockedField(title: "Relocate", isEmpty: ng.relocation == nil) { Text(relocation(ng.relocation)) }
                LockedField(title: "Work authorization", isEmpty: ng.workAuth.isEmpty) {
                    Text(ng.workAuth.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.replacingOccurrences(of: "_", with: " "))" }.joined(separator: " · "))
                }
            }
            Button("Edit in Settings ▸ Guardrails") { SettingsNavigation.shared.open(.guardrails, router: store.router) }
                .buttonStyle(.secondaryLink)
        }
    }

    private func relocation(_ value: String?) -> String {
        switch value {
        case "yes": "Yes"
        case "no": "No"
        case "case_by_case": "Case by case"
        default: value ?? ""
        }
    }
}

// MARK: - Memory

private struct MemorySection: View {
    @Bindable var model: ProfileModel

    var body: some View {
        let items = model.memory
        DocumentSection("Saved answers · \(model.store.library.memoryAnswers.count)", trailing: {
            TextField("Filter", text: $model.memoryFilter).textFieldStyle(.roundedBorder).frame(width: 160)
        }) {
            if items.isEmpty {
                Text(model.memoryFilter.isEmpty ? "Answers you save from Needs You show up here and are reused for future jobs." : "No matches")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    MemoryRow(model: model, item: item)
                    Divider()
                }
            }
        }
    }
}

private struct MemoryRow: View {
    @Bindable var model: ProfileModel
    var item: MemoryAnswerItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(item.canonicalQuestion).font(Typography.body).frame(width: 230, alignment: .leading).lineLimit(2)
            if model.editingMemoryID == item.id {
                VStack(alignment: .leading, spacing: Space.xs) {
                    TextEditor(text: $model.memoryDraft)
                        .font(Typography.body).scrollContentBackground(.hidden).frame(minHeight: 56).padding(Space.xs).well()
                    HStack {
                        Button("Save") { Task { await model.saveMemory(item) } }.buttonStyle(.bordered).controlSize(.small)
                        Button("Cancel") { model.editingMemoryID = nil }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isTemplate ? "template · \(item.answer)" : item.answer).font(Typography.body).lineLimit(2)
                    Text("used \(item.uses)×\(item.lastUsedAt.map { " · last \(C3Format.relative($0))" } ?? "")")
                        .font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                if model.confirmingDeleteMemoryID == item.id {
                    Text("Delete?").font(Typography.callout)
                    Button("Delete", role: .destructive) { Task { await model.deleteMemory(item) } }.buttonStyle(.bordered).controlSize(.small)
                    Button("Keep") { model.confirmingDeleteMemoryID = nil }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button { model.beginEditingMemory(item) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).accessibilityLabel("Edit answer")
                    Button { model.confirmingDeleteMemoryID = item.id } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Delete answer")
                }
            }
        }
        .padding(.vertical, Space.s)
    }
}

extension Array {
    subscript(c3Safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
