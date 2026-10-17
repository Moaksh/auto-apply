// SettingsTabs.swift — the preference-backed Settings tabs: Preferences (everything from
// onboarding step 3), Guardrails (never-guess facts + ask confidence + attestations + always-ask
// patterns), Modes (global, per-ATS, per-company, per-job), Sources, and Schedule & Caps.
import SwiftUI

// MARK: - Preferences

struct PreferencesSettingsTab: View {
    @Bindable var model: SettingsModel
    @Environment(AppStore.self) private var store
    @State private var suggestion: SuggestedPreferences?
    @State private var years: Double?
    @State private var saveYears: Task<Void, Never>?

    var body: some View {
        Group {
        if let s = suggestion, !resumeDiff(s).isEmpty {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your resume suggests").font(Typography.body.weight(.semibold))
                    Text(resumeDiff(s).joined(separator: "  ·  ")).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button("Fill from resume") { fill(from: s) }
                    .buttonStyle(.glass)
                    .help("Adds the suggested roles and locations and sets seniority. Review, then Save.")
            }
            .padding(Space.m)
            .sunkenWell()
        }
        SettingsRow("Roles") {
            ChipField(values: $model.preferencesDraft.roles, placeholder: "+ add role",
                      suggestions: QuickFillLists.roles(for: store.library.profile, chosen: model.preferencesDraft.roles))
        }
        SettingsRow("Experience", help: "Used to match seniority and score jobs. Saved to your profile right away.") {
            YearsField(years: Binding(get: { years }, set: { new in
                let old = years.map(OnboardingModel.seniority(forYears:)) ?? []
                if let new, model.preferencesDraft.seniority.isEmpty || model.preferencesDraft.seniority == old {
                    model.preferencesDraft.seniority = OnboardingModel.seniority(forYears: new)
                }
                years = new
                saveYears?.cancel()
                guard let new else { return }
                saveYears = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    await store.setYearsExperience(new)
                }
            }))
        }
        SettingsRow("Seniority") {
            ToggleChips(options: Seniority.allCases, selection: setBinding(\.seniority), label: { $0.rawValue.capitalized })
        }
        SettingsRow("Location", issue: model.issue(for: .remotePolicy)) {
            ToggleChips(options: RemotePolicy.allCases, selection: setBinding(\.remotePolicy), label: { $0.rawValue.capitalized })
            ChipField(values: $model.preferencesDraft.locations, placeholder: "+ city or country",
                      suggestions: QuickFillLists.locations(for: store.library.profile))
        }
        .errorShake(trigger: model.issue(for: .remotePolicy) == nil ? 0 : model.shakeTrigger)
        SettingsRow("Work authorization") {
            TextField("e.g. India citizen; needs US visa sponsorship", text: Binding(
                get: { model.preferencesDraft.workAuthSummary ?? "" },
                set: { model.preferencesDraft.workAuthSummary = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
        }
        SettingsRow("Salary floor", issue: model.issue(for: .salaryFloor)) {
            HStack(spacing: Space.s) {
                Picker("Currency", selection: $model.preferencesDraft.salaryCurrency) {
                    ForEach(["USD", "INR", "EUR", "GBP", "SGD", "CAD", "AUD"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                TextField("Amount", value: $model.preferencesDraft.salaryFloor, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Text("per year").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            Toggle("Hide jobs without a salary", isOn: $model.preferencesDraft.hideWithoutSalary).toggleStyle(.checkbox)
        }
        .errorShake(trigger: model.issue(for: .salaryFloor) == nil ? 0 : model.shakeTrigger)
        SettingsRow("Exclude companies") { ChipField(values: $model.preferencesDraft.excludeCompanies, placeholder: "+ company") }
        SettingsRow("Exclude industries") {
            ChipField(values: $model.preferencesDraft.excludeIndustries, placeholder: "+ industry", suggestions: QuickFillLists.excludeIndustries)
        }
        SettingsRow("Exclude keywords") {
            ChipField(values: $model.preferencesDraft.excludeKeywords, placeholder: "+ keyword (e.g. crypto)", suggestions: QuickFillLists.excludeKeywords)
        }
        SettingsRow("Match threshold", help: "Jobs scoring below this are skipped (you can still see them in Pipeline).") {
            ThresholdSlider(value: $model.preferencesDraft.matchThreshold, bins: histogram, weeklyEstimate: weeklyEstimate)
        }
        }
        .task {
            years = store.library.profile.yearsExperience
            suggestion = await store.suggestPreferences()
        }
    }

    /// What the resume would add that isn't already set.
    private func resumeDiff(_ s: SuggestedPreferences) -> [String] {
        let d = model.preferencesDraft
        let roles = s.roles.filter { r in !d.roles.contains { $0.caseInsensitiveCompare(r) == .orderedSame } }
        let locs = s.locations.filter { l in !d.locations.contains { $0.caseInsensitiveCompare(l) == .orderedSame } }
        var out: [String] = []
        if !roles.isEmpty { out.append(roles.joined(separator: ", ")) }
        if !s.seniority.isEmpty, Set(s.seniority) != Set(d.seniority) { out.append(s.seniority.map { $0.rawValue.capitalized }.joined(separator: "/")) }
        if !locs.isEmpty { out.append(locs.joined(separator: ", ")) }
        return out
    }

    private func fill(from s: SuggestedPreferences) {
        let d = model.preferencesDraft
        model.preferencesDraft.roles = d.roles + s.roles.filter { r in !d.roles.contains { $0.caseInsensitiveCompare(r) == .orderedSame } }
        if !s.seniority.isEmpty { model.preferencesDraft.seniority = s.seniority }
        model.preferencesDraft.locations = d.locations + s.locations.filter { l in !d.locations.contains { $0.caseInsensitiveCompare(l) == .orderedSame } }
        if years == nil, let y = s.yearsExperience { years = y; Task { await store.setYearsExperience(y) } }
    }

    private var histogram: [Int] {
        let bins = store.stats.scoreHistogram.map(\.total)
        return bins.reduce(0, +) >= 20 ? bins : MiniHistogram.benchmark
    }

    private func weeklyEstimate(_ threshold: Int) -> Int {
        let jobs = store.jobs.all
        if jobs.count >= 20 { return StatsCalculator.weeklyQualifying(jobs: jobs, threshold: threshold) }
        let total = MiniHistogram.benchmark.reduce(0, +)
        let above = MiniHistogram.benchmark.enumerated().filter { $0.offset * 5 >= threshold }.map(\.element).reduce(0, +)
        return Int((Double(above) / Double(total) * 200).rounded())
    }

    private func setBinding<T: Hashable>(_ keyPath: WritableKeyPath<Preferences, [T]>) -> Binding<Set<T>> {
        Binding(get: { Set(model.preferencesDraft[keyPath: keyPath]) },
                set: { new in
                    let order = model.preferencesDraft[keyPath: keyPath]
                    model.preferencesDraft[keyPath: keyPath] = order.filter(new.contains) + new.filter { !order.contains($0) }
                })
    }
}

// MARK: - Guardrails

struct GuardrailsSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Never-guess facts").font(Typography.title2)
                Spacer()
                Label("only you", systemImage: "lock.fill").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            Text("These only ever come from you. If a form asks something not listed here, the agent stops and asks.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            NeverGuessEditor(draft: $model.neverGuessDraft, profile: model.store.library.profile)
        }
        Divider()
        SettingsRow("Ask me when", help: confidenceHelp) {
            Picker("Confidence", selection: $model.preferencesDraft.askConfidence) {
                Text("Strict").tag(AskConfidence.strict)
                Text("Balanced").tag(AskConfidence.balanced)
                Text("Lenient").tag(AskConfidence.lenient)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
        }
        SettingsRow("Always ask about", help: "Questions matching these phrases always come to Needs You, even when the agent knows an answer.") {
            ChipField(values: $model.preferencesDraft.alwaysAskPatterns, placeholder: "+ phrase (e.g. criminal record)")
        }
    }

    private var confidenceHelp: String {
        switch model.preferencesDraft.askConfidence {
        case .strict: "Strict: anything generated below high confidence is parked for you. Fewer surprises, more questions."
        case .balanced: "Balanced: medium-confidence generated answers go through; low confidence asks you."
        case .lenient: "Lenient: only very low confidence asks you. Fastest, but review more receipts."
        }
    }
}

/// Never-guess facts editor (same fields as onboarding step 4) with locked styling. Blank
/// means "always ask me".
struct NeverGuessEditor: View {
    @Binding var draft: NeverGuess
    /// Orders the country quick-picks (home country first).
    var profile: Profile? = nil
    @State private var newCountry = ""
    @State private var newStatus = "citizen"

    static let sponsorshipOptions = [
        "Requires sponsorship (H-1B)", "Requires sponsorship", "No sponsorship needed", "Authorized to work (citizen)",
    ]
    static let workAuthStatuses = ["citizen", "permanent_resident", "work_visa", "requires_sponsorship", "not_authorized"]

    var body: some View {
        VStack(spacing: Space.s) {
            LockedField(title: "Work authorization", isEmpty: draft.workAuth.isEmpty) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(draft.workAuth.keys.sorted(), id: \.self) { country in
                        HStack(spacing: Space.s) {
                            Text(country).font(Typography.mono).frame(width: 40, alignment: .leading)
                                .help(QuickFillLists.countryName(country) ?? country)
                            Picker(country, selection: Binding(
                                get: { draft.workAuth[country] ?? "" },
                                set: { draft.workAuth[country] = $0 })) {
                                ForEach(Self.workAuthStatuses, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                            Button { draft.workAuth.removeValue(forKey: country) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(country)")
                        }
                    }
                    HStack(alignment: .top, spacing: Space.s) {
                        CountryCodeField(code: $newCountry, options: QuickFillLists.countries(for: profile, excluding: draft.workAuth.keys))
                        Picker("Status", selection: $newStatus) {
                            ForEach(Self.workAuthStatuses, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Button("Add") {
                            let code = newCountry.trimmingCharacters(in: .whitespaces).uppercased()
                            guard !code.isEmpty else { return }
                            draft.workAuth[code] = newStatus
                            newCountry = ""
                        }
                        .disabled(newCountry.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            LockedField(title: "Visa / sponsorship", isEmpty: draft.sponsorship.c3Trimmed == nil) {
                Picker("Sponsorship", selection: optionalString(\.sponsorship)) {
                    Text("Always ask me").tag("")
                    ForEach(Self.sponsorshipOptions, id: \.self) { Text($0).tag($0) }
                    if let custom = draft.sponsorship, !custom.isEmpty, !Self.sponsorshipOptions.contains(custom) {
                        Text(custom).tag(custom)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300, alignment: .leading)
            }
            LockedField(title: "Expected salary", isEmpty: draft.salaryExpectation.c3Trimmed == nil) {
                HStack {
                    TextField("e.g. ₹45L", text: optionalString(\.salaryExpectation)).textFieldStyle(.roundedBorder).frame(width: 160)
                    Toggle("Negotiable", isOn: Binding(get: { draft.salaryNegotiable ?? false }, set: { draft.salaryNegotiable = $0 }))
                        .toggleStyle(.checkbox)
                        .disabled(draft.salaryExpectation.c3Trimmed == nil)
                }
            }
            LockedField(title: "Notice period", isEmpty: draft.noticePeriod.c3Trimmed == nil) {
                TextField("e.g. 60 days", text: optionalString(\.noticePeriod)).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            LockedField(title: "Earliest start date", isEmpty: draft.startDate.c3Trimmed == nil) {
                TextField("e.g. 2 months from offer", text: optionalString(\.startDate)).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            LockedField(title: "Relocation") {
                Picker("Relocation", selection: optionalString(\.relocation)) {
                    Text("Yes").tag("yes")
                    Text("Case by case").tag("case_by_case")
                    Text("No").tag("no")
                    Text("Ask me").tag("")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
            }
            LockedField(title: "EEO / demographics") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Picker("EEO", selection: $draft.eeoPolicy) {
                        Text("Decline to answer").tag("decline")
                        Text("Fill from my answers").tag("fill")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    if draft.eeoPolicy == "fill" {
                        HStack {
                            TextField("Gender", text: optionalString(\.eeoGender)).textFieldStyle(.roundedBorder)
                            TextField("Race / ethnicity", text: optionalString(\.eeoRace)).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            TextField("Veteran status", text: optionalString(\.eeoVeteran)).textFieldStyle(.roundedBorder)
                            TextField("Disability", text: optionalString(\.eeoDisability)).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            LockedField(title: "Legal attestations") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("Agent may confirm “info is accurate”", isOn: $draft.attestAccuracy)
                    Toggle("Agent may accept background checks", isOn: $draft.attestBackgroundCheck)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func optionalString(_ keyPath: WritableKeyPath<NeverGuess, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" },
                set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Modes

struct ModesSettingsTab: View {
    @Bindable var model: SettingsModel
    @Environment(AppStore.self) private var store

    static let atsRows: [Ats] = [.greenhouse, .lever, .ashby, .workday, .other]

    var body: some View {
        SettingsRow("Global mode", help: "Auto submits when guardrails pass. Review parks filled applications for your OK.") {
            Picker("Mode", selection: Binding(get: { model.preferencesDraft.mode }, set: { m in Task { await model.setGlobalMode(m) } })) {
                Text("Auto").tag(Mode.auto)
                Text("Review").tag(Mode.review)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
        }
        SettingsRow("Per ATS", help: "Overrides win over the global mode. Workday defaults to Review.") {
            Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.s) {
                ForEach(Self.atsRows, id: \.self) { ats in
                    GridRow {
                        Text(ats.label).font(Typography.body).frame(width: 110, alignment: .leading)
                        Picker(ats.label, selection: Binding(
                            get: { model.preferencesDraft.perAtsMode[ats.rawValue] },
                            set: { m in Task { await model.setAtsMode(ats, m) } })) {
                            Text("Inherit").tag(Mode?.none)
                            Text("Auto").tag(Mode?.some(.auto))
                            Text("Review").tag(Mode?.some(.review))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
            }
        }
        SettingsRow("Per company") {
            let overrides = model.preferencesDraft.perCompanyMode.sorted { model.companyName($0.key) < model.companyName($1.key) }
            if overrides.isEmpty {
                Text("No company overrides.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            ForEach(overrides, id: \.key) { key, mode in
                HStack(spacing: Space.s) {
                    Text(model.companyName(key)).font(Typography.body).frame(width: 160, alignment: .leading)
                    Picker("Mode", selection: Binding(get: { mode }, set: { m in Task { await model.setCompanyMode(companyID: Int(key) ?? 0, m) } })) {
                        Text("Auto").tag(Mode.auto)
                        Text("Review").tag(Mode.review)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                    Button { if let id = Int(key) { Task { await model.setCompanyMode(companyID: id, nil) } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove override for \(model.companyName(key))")
                }
            }
            let available = model.knownCompanies.filter { model.preferencesDraft.perCompanyMode[String($0.id)] == nil }
            Menu("Add company override") {
                ForEach(available, id: \.id) { company in
                    Button(company.name) { Task { await model.setCompanyMode(companyID: company.id, .review) } }
                }
            }
            .fixedSize()
            .disabled(available.isEmpty)
        }
        SettingsRow("Per job", help: "Set from a job's detail or the Review queue.") {
            let jobs = model.jobsWithModeOverride
            if jobs.isEmpty {
                Text("No job overrides.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            ForEach(jobs) { job in
                HStack(spacing: Space.s) {
                    Text(job.displayName).font(Typography.body).lineLimit(1)
                    Text(job.modeOverride?.rawValue.capitalized ?? "").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("Clear") { Task { await store.setJobMode(jobID: job.id, mode: nil) } }.buttonStyle(.link)
                }
            }
        }
    }
}

// MARK: - Sources

struct SourcesSettingsTab: View {
    @Bindable var model: SettingsModel
    @Environment(AppStore.self) private var store
    @State private var newURL = ""
    @State private var urlShake = 0

    var body: some View {
        VStack(spacing: Space.s) {
            ForEach(SourceName.allCases, id: \.self) { source in
                sourceCard(source)
            }
        }
        SettingsRow("Career pages", help: "Company careers pages the agent checks for new roles.", issue: model.issue(for: .careerPageUrls)) {
            ForEach(model.preferencesDraft.careerPageUrls, id: \.self) { url in
                HStack {
                    Text(url).font(Typography.mono).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.preferencesDraft.careerPageUrls.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(url)")
                }
            }
            HStack {
                TextField("https://company.com/careers", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addURL)
                Button("Add", action: addURL).disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .errorShake(trigger: urlShake)
        }
        MailAccountRow()
        SettingsRow("Read budgets", help: "Short, human-paced read-only sessions per day. LinkedIn and Glassdoor are never used to apply.") {
            Stepper("LinkedIn: \(model.preferencesDraft.linkedinSessionsPerDay) sessions / day",
                    value: $model.preferencesDraft.linkedinSessionsPerDay, in: 0...10)
            Stepper("Glassdoor: \(model.preferencesDraft.glassdoorSessionsPerDay) sessions / day",
                    value: $model.preferencesDraft.glassdoorSessionsPerDay, in: 0...10)
            Stepper("Searches per session: \(model.preferencesDraft.searchesPerSession) result pages",
                    value: $model.preferencesDraft.searchesPerSession, in: 1...10)
            Stepper("Jobs per session: \(model.preferencesDraft.jobsPerSession) job pages",
                    value: $model.preferencesDraft.jobsPerSession, in: 5...200, step: 5)
            Text("A session is one LinkedIn or Glassdoor visit at human pace. More jobs per session finds more, but takes longer and looks more like a bot.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            HStack(spacing: Space.m) {
                Text("Used today: LinkedIn \(store.snapshotCaps.linkedinSessionsUsed) · Glassdoor \(store.snapshotCaps.glassdoorSessionsUsed)")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Reset LinkedIn") { Task { _ = await store.resetSourceCap(.linkedin) } }
                Button("Reset Glassdoor") { Task { _ = await store.resetSourceCap(.glassdoor) } }
            }
            .help("Starts today's count over. More reads means more automated page loads on your account.")
        }
    }

    private func addURL() {
        if model.addCareerURL(newURL) { newURL = "" } else { urlShake += 1 }
    }

    private func sourceCard(_ source: SourceName) -> some View {
        let status = store.sources[source]
        let needsLogin = source == .linkedin || source == .glassdoor
        return HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: needsLogin ? "person.crop.circle.badge.checkmark" : "building.2")
                .font(.system(size: 18))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(C3Format.sourceName(source)).font(Typography.bodyEmph)
                Text(statusLine(source, status)).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if needsLogin && model.isSourceEnabled(source) && status?.connected != true {
                Button("Reconnect") {
                    Task { _ = await store.onboardingConnectSource(source == .linkedin ? .linkedin : .glassdoor) }
                }
                .buttonStyle(.glass)
            }
            Toggle("Enabled", isOn: Binding(get: { model.isSourceEnabled(source) }, set: { model.toggleSource(source, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("\(C3Format.sourceName(source)) enabled")
        }
        .padding(Space.m)
        .surfaceCard(cornerRadius: Radius.inner)
    }

    private func statusLine(_ source: SourceName, _ status: SourceStatus?) -> String {
        guard model.isSourceEnabled(source) else { return "Off" }
        let needsLogin = source == .linkedin || source == .glassdoor
        if source == .google, status?.connected != false {
            return "Searches Google's Jobs tab in the agent's Chrome window · no login needed"
        }
        guard let status else { return needsLogin ? "Not connected" : "Public job boards · no login needed" }
        if needsLogin {
            let health = status.connected ? "\(C3Format.sourceName(source)) session valid" : (status.detail ?? "Session expired")
            return status.checkedAt.map { "\(health) · checked \(C3Format.relative($0))" } ?? health
        }
        return status.detail ?? "Public job boards · no login needed"
    }
}

// MARK: - Schedule & caps

struct ScheduleSettingsTab: View {
    @Bindable var model: SettingsModel
    @State private var nudgeDraft = ""

    var body: some View {
        SettingsRow("Run times", help: "Click hours to toggle scheduled runs. Missed runs fire when your Mac wakes.",
                    issue: model.issue(for: .schedule)) {
            ScheduleHourGrid(selected: ScheduleTimes.hours(model.preferencesDraft.schedule)) { model.toggleScheduleHour($0) }
            Text(model.preferencesDraft.schedule.isEmpty ? "No scheduled runs (manual only)"
                 : "\(C3Format.plural(model.preferencesDraft.schedule.count, "run")) per day: \(model.preferencesDraft.schedule.joined(separator: ", "))")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
                .monospacedDigit()
        }
        SettingsRow("Daily cap", issue: model.issue(for: .dailyCap)) {
            HStack(spacing: Space.m) {
                Slider(value: Binding(get: { Double(model.preferencesDraft.dailyCap) },
                                      set: { model.preferencesDraft.dailyCap = Int($0.rounded()) }), in: 1...60, step: 1)
                    .frame(maxWidth: 260)
                Text("\(model.preferencesDraft.dailyCap) applications / day")
                    .font(Typography.metricSmall)
                    .numericRoll(Double(model.preferencesDraft.dailyCap))
            }
        }
        SettingsRow("Agents at once", help: "More at once uses your Claude plan's limits faster.",
                    issue: model.issue(for: .parallelApplications)) {
            Stepper("Apply to up to \(model.preferencesDraft.parallelApplications) \(model.preferencesDraft.parallelApplications == 1 ? "job" : "jobs") at once",
                    value: $model.preferencesDraft.parallelApplications, in: 1...4)
                .monospacedDigit()
        }
        SettingsRow("Per-company cooldown", help: "At most one application per company in this window.",
                    issue: model.issue(for: .perCompanyCooldownDays)) {
            Stepper("\(model.preferencesDraft.perCompanyCooldownDays) days", value: $model.preferencesDraft.perCompanyCooldownDays, in: 0...365)
        }
        SettingsRow("Auto-ghost after", issue: model.issue(for: .ghostAfterDays)) {
            Stepper("\(model.preferencesDraft.ghostAfterDays) days without a reply", value: $model.preferencesDraft.ghostAfterDays, in: 1...180)
        }
        SettingsRow("“Heard back?” nudges", help: "Days after applying.", issue: model.issue(for: .nudgeDays)) {
            HStack(spacing: Space.xs) {
                ForEach(model.preferencesDraft.nudgeDays, id: \.self) { day in
                    HStack(spacing: 3) {
                        Text("day \(day)").font(Typography.body).monospacedDigit()
                        Button { model.preferencesDraft.nudgeDays.removeAll { $0 == day } } label: { Image(systemName: "xmark").imageScale(.small) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityLabel("Remove day \(day)")
                    }
                    .padding(.horizontal, Space.s).padding(.vertical, 3)
                    .background(Palette.sunken, in: Capsule())
                }
                TextField("+ day", text: $nudgeDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit {
                        if let d = Int(nudgeDraft.trimmingCharacters(in: .whitespaces)), d > 0 {
                            model.preferencesDraft.nudgeDays = Array(Set(model.preferencesDraft.nudgeDays + [d])).sorted()
                        }
                        nudgeDraft = ""
                    }
            }
        }
        .errorShake(trigger: model.issue(for: .nudgeDays) == nil ? 0 : model.shakeTrigger)
    }
}

/// 24 hour cells (accent when a run is scheduled at that hour). Click or drag to paint.
struct ScheduleHourGrid: View {
    var selected: Set<Int>
    var onToggle: (Int) -> Void
    @State private var dragVisited: Set<Int> = []

    var body: some View {
        GeometryReader { geo in
            let cell = geo.size.width / 24
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    let on = selected.contains(hour)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(on ? Palette.accent : Palette.sunken)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Palette.hairline, lineWidth: 0.5))
                        .padding(1)
                        .frame(width: cell, height: 26)
                        .overlay(alignment: .bottom) {
                            if hour % 3 == 0 {
                                Text("\(hour)").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary).offset(y: 14)
                            }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("\(ScheduleTimes.format(hour: hour))\(on ? ", scheduled" : "")")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onToggle(hour) }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let hour = Int(value.location.x / max(cell, 1))
                guard (0..<24).contains(hour), !dragVisited.contains(hour) else { return }
                dragVisited.insert(hour)
                onToggle(hour)
                Haptics.alignment()
            }.onEnded { _ in dragVisited.removeAll() })
        }
        .frame(height: 42)
        .frame(maxWidth: 440)
    }
}


/// "Email for security codes": some ATSs (Greenhouse) email a code that must be typed before the
/// application is accepted. With a connected mailbox the agent reads it itself.
struct MailAccountRow: View {
    @Environment(AppStore.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var status: AppStore.MailAccountStatus?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        SettingsRow("Email for security codes",
                    help: "Greenhouse and others email a code before they accept an application. Connect the inbox they send it to and the agent reads the code itself; otherwise it asks you in Needs You.") {
            VStack(alignment: .leading, spacing: Space.s) {
                if let s = status, s.connected, let addr = s.email {
                    HStack(spacing: Space.s) {
                        Label("Connected · \(addr)", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.applied)
                        Spacer()
                        Button("Test") { Task { await run { await store.getMailAccount(test: true) } } }.disabled(busy)
                        Button("Disconnect") { Task { await run { await store.clearMailAccount() } } }.disabled(busy)
                    }
                } else {
                    TextField("you@gmail.com", text: $email).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    SecureField("App password (16 letters)", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    HStack(spacing: Space.m) {
                        Button(busy ? "Connecting…" : "Connect") {
                            Task { await run { await store.setMailAccount(email: email, appPassword: password) } }
                        }
                        .buttonStyle(.glass)
                        .disabled(busy || !email.contains("@") || password.replacingOccurrences(of: " ", with: "").count < 8)
                        Link("Create a Gmail app password", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                            .font(Typography.callout)
                    }
                    Text("Needs 2-Step Verification on your Google account. The password is kept in your Mac's Keychain and only used to read security-code emails.")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                if let message {
                    Text(message).font(Typography.callout).foregroundStyle(status?.connected == true ? Palette.applied : Palette.needsYou)
                }
            }
        }
        .task {
            status = await store.getMailAccount()
            if let e = status?.email { email = e }
        }
    }

    private func run(_ op: () async -> AppStore.MailAccountStatus?) async {
        busy = true
        defer { busy = false }
        let result = await op()
        if let result {
            status = result
            message = result.error ?? (result.connected ? "Working: the agent will read security codes from this inbox." : "Disconnected.")
            if result.connected { password = "" }
        } else {
            message = store.lastCommandError.map { OnboardingModel.failureMessage(for: $0) } ?? "Couldn't reach the agent."
        }
    }
}
