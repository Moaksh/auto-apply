// PreferenceSteps.swift — onboarding steps 3–5: job preferences, never-guess facts (locked
// styling everywhere), and the optional story bank.
import SwiftUI

// MARK: - Step 3: Preferences

struct PreferencesStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(title: "What are you looking for?")
        if model.lastSuggestion != nil {
            Label("Pre-filled from your resume. Change anything that's off.", systemImage: "doc.text.magnifyingglass")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
        Grid(alignment: .topLeading, horizontalSpacing: Space.l, verticalSpacing: Space.l) {
            row("Roles") { ChipField(values: $model.preferencesDraft.roles, placeholder: "+ add role") }
            row("Experience") {
                YearsField(years: Binding(
                    get: { model.profileDraft.yearsExperience },
                    set: { new in
                        // Keep seniority in step with years unless the user picked levels by hand.
                        let old = model.profileDraft.yearsExperience.map(OnboardingModel.seniority(forYears:)) ?? []
                        if let new, model.preferencesDraft.seniority.isEmpty || model.preferencesDraft.seniority == old {
                            model.preferencesDraft.seniority = OnboardingModel.seniority(forYears: new)
                        }
                        model.profileDraft.yearsExperience = new
                    }))
            }
            row("Seniority") {
                ToggleChips(options: Seniority.allCases, selection: setBinding(\.seniority), label: { $0.rawValue.capitalized })
            }
            row("Location") {
                VStack(alignment: .leading, spacing: Space.s) {
                    ToggleChips(options: RemotePolicy.allCases, selection: setBinding(\.remotePolicy), label: { $0.rawValue.capitalized })
                    ChipField(values: $model.preferencesDraft.locations, placeholder: "+ city or country")
                }
            }
            row("Work auth") {
                TextField("e.g. India citizen; needs US visa sponsorship", text: Binding(
                    get: { model.preferencesDraft.workAuthSummary ?? "" },
                    set: { model.preferencesDraft.workAuthSummary = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            row("Salary floor") {
                HStack(spacing: Space.s) {
                    Picker("Currency", selection: $model.preferencesDraft.salaryCurrency) {
                        ForEach(["USD", "INR", "EUR", "GBP", "SGD"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    TextField("Amount", value: $model.preferencesDraft.salaryFloor, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("per year").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Toggle("Hide jobs without salary", isOn: $model.preferencesDraft.hideWithoutSalary)
                        .toggleStyle(.checkbox)
                }
            }
            row("Exclude") {
                VStack(alignment: .leading, spacing: Space.s) {
                    ChipField(values: $model.preferencesDraft.excludeCompanies, placeholder: "+ company")
                    ChipField(values: $model.preferencesDraft.excludeKeywords, placeholder: "+ keyword (e.g. crypto)")
                }
            }
            row("Daily cap") {
                HStack(spacing: Space.m) {
                    Slider(value: Binding(get: { Double(model.preferencesDraft.dailyCap) },
                                          set: { model.preferencesDraft.dailyCap = Int($0.rounded()) }), in: 1...40, step: 1)
                    Text("\(model.preferencesDraft.dailyCap) applications / day")
                        .font(Typography.metricSmall)
                        .numericRoll(Double(model.preferencesDraft.dailyCap))
                        .frame(width: 170, alignment: .leading)
                }
            }
            row("Match threshold") {
                ThresholdSlider(value: $model.preferencesDraft.matchThreshold, bins: histogram, weeklyEstimate: weeklyEstimate)
            }
        }
    }

    /// Real score distribution when data exists, else a benchmark (teaches the concept in place).
    private var histogram: [Int] {
        let bins = model.store.stats.scoreHistogram.map(\.total)
        return bins.reduce(0, +) >= 20 ? bins : MiniHistogram.benchmark
    }

    private func weeklyEstimate(_ threshold: Int) -> Int {
        let jobs = model.store.jobs.all
        if jobs.count >= 20 { return StatsCalculator.weeklyQualifying(jobs: jobs, threshold: threshold) }
        // Benchmark: ~200 discovered/week distributed like MiniHistogram.benchmark.
        let total = MiniHistogram.benchmark.reduce(0, +)
        let above = MiniHistogram.benchmark.enumerated().filter { $0.offset * 5 >= threshold }.map(\.element).reduce(0, +)
        return Int((Double(above) / Double(total) * 200).rounded())
    }

    private func setBinding<T: Hashable>(_ keyPath: WritableKeyPath<Preferences, [T]>) -> Binding<Set<T>> {
        Binding(get: { Set(model.preferencesDraft[keyPath: keyPath]) },
                set: { new in
                    // Keep declaration order stable.
                    let order = model.preferencesDraft[keyPath: keyPath]
                    model.preferencesDraft[keyPath: keyPath] = order.filter(new.contains) + new.filter { !order.contains($0) }
                })
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title).font(Typography.bodyEmph).frame(width: 120, alignment: .leading).padding(.top, 4)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Step 4: Never-guess facts

struct NeverGuessStep: View {
    @Bindable var model: OnboardingModel

    private static let sponsorshipOptions = [
        "Requires sponsorship (H-1B)", "Requires sponsorship", "No sponsorship needed", "Authorized to work (citizen)",
    ]

    var body: some View {
        StepHeader(title: "Facts the agent will never guess",
                   subtitle: "These only ever come from you. If a form asks something not listed, the agent stops and asks.")
        // Same editor as Settings ▸ Never-guess, so onboarding also asks *where you can work*
        // (per country). Without it every "authorized to work in …?" question stops the agent.
        NeverGuessEditor(draft: $model.neverGuessDraft)
        Text("Leave anything blank to always be asked.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
    }

    private func optionalString(_ keyPath: WritableKeyPath<NeverGuess, String?>) -> Binding<String> {
        Binding(get: { model.neverGuessDraft[keyPath: keyPath] ?? "" },
                set: { model.neverGuessDraft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Step 5: Story bank (optional)

struct StoriesStep: View {
    @Bindable var model: OnboardingModel
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        StepHeader(title: "Story bank", subtitle: "Cover letters and “why” answers only use facts from your stories and profile. Fewer stories = more questions later.")
        ForEach($model.stories) { $story in
            StoryCard(story: $story) { model.removeStory(story.id) }
                .transition(AnyTransition.reduced(.cardIn, reduced))
        }
        .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: model.stories.map(\.id))
        HStack {
            Button {
                model.addStory()
            } label: {
                Label("Add another story", systemImage: "plus")
            }
            .buttonStyle(.glass)
            Spacer()
            Button("Skip for now") { model.go(to: .sources) }
                .buttonStyle(.link)
        }
        Text("The agent quotes these; it won't invent metrics.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
    }
}

private struct StoryCard: View {
    @Binding var story: OnboardingModel.StoryDraft
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                TextField("Story title (e.g. Payments ledger at scale)", text: $story.title)
                    .textFieldStyle(.plain)
                    .font(Typography.title2)
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove story")
            }
            starField("Situation", text: $story.situation)
            starField("Task", text: $story.task)
            starField("Action", text: $story.action)
            starField("Result", text: $story.result)
            ChipField(values: $story.tags, placeholder: "+ tag (leadership, conflict, scale…)")
        }
        .padding(Space.l)
        .surfaceCard()
    }

    private func starField(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Text(label).font(Typography.callout).foregroundStyle(Palette.textSecondary).frame(width: 70, alignment: .leading).padding(.top, 4)
            TextField(label, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(Space.s)
                .sunkenWell()
        }
    }
}

/// "2.5 years" stepper + field, shared by onboarding and Settings.
struct YearsField: View {
    @Binding var years: Double?

    var body: some View {
        HStack(spacing: Space.s) {
            TextField("0", value: $years, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).frame(width: 64)
            Stepper("", value: Binding(get: { years ?? 0 }, set: { years = max(0, min(60, ($0 * 2).rounded() / 2)) }),
                    in: 0...60, step: 0.5)
                .labelsHidden()
            Text("years of experience").font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
    }
}
