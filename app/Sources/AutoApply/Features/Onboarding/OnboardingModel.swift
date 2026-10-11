// OnboardingModel.swift — state and actions for the 7-step first-launch flow (§5.1). Every
// step's primary action sends its onboarding_* / update_* command; progress is persisted with
// onboarding_set_step (and locally) so quitting resumes at the same step.
import AppKit
import Foundation
import Observation
import PDFKit

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Comparable {
        case ignition = 0, systemCheck, resumes, preferences, neverGuess, stories, sources, mode, ready

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        /// Steps shown on the rail (1…7).
        static let railSteps: [Step] = [.systemCheck, .resumes, .preferences, .neverGuess, .stories, .sources, .mode]

        var title: String {
            switch self {
            case .ignition: "Welcome"
            case .systemCheck: "System check"
            case .resumes: "Resumes"
            case .preferences: "Preferences"
            case .neverGuess: "Never-guess facts"
            case .stories: "Story bank"
            case .sources: "Sources"
            case .mode: "Mode"
            case .ready: "Ready"
            }
        }

        var isOptional: Bool { self == .stories }
    }

    // MARK: System check
    enum CheckState: Equatable { case pending, checking, done }
    struct CheckRow: Identifiable, Equatable {
        var id: SystemCheckItem.Name { name }
        var name: SystemCheckItem.Name
        var state: CheckState = .pending
        var item: SystemCheckItem?
        var fixOutput: String = ""
        var isFixing = false
    }

    // MARK: Resumes
    struct UploadedResume: Identifiable, Equatable {
        enum Status: Equatable { case parsing, parsed, failed(String) }
        let id = UUID()
        var url: URL
        var label: String
        var tags: [String] = []
        var status: Status = .parsing
        var variantID: Int?
        var thumbnail: NSImage?

        static func == (a: UploadedResume, b: UploadedResume) -> Bool {
            a.id == b.id && a.label == b.label && a.tags == b.tags && a.status == b.status && a.variantID == b.variantID
                && (a.thumbnail == nil) == (b.thumbnail == nil)
        }
    }

    // MARK: Stories
    struct StoryDraft: Identifiable, Equatable {
        let id = UUID()
        var storyID: Int?
        var title = ""
        var situation = ""
        var task = ""
        var action = ""
        var result = ""
        var tags: [String] = []
        var isEmpty: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: State
    private(set) var step: Step = .ignition
    /// Direction of the last navigation (drives the slide transition).
    private(set) var movingForward = true
    var checks: [CheckRow] = SystemCheckMerger.order.map { CheckRow(name: $0) }
    private(set) var isCheckingSystem = false
    var resumes: [UploadedResume] = []
    var showProfileConfirm = false
    var profileDraft = Profile()
    var uncertainFields: Set<String> = []
    var preferencesDraft = Preferences()
    var neverGuessDraft = NeverGuess()
    var stories: [StoryDraft] = [StoryDraft()]
    var careerURLDraft = ""
    var careerURLs: [String] = []
    var selectedMode: Mode = .review
    private(set) var isSaving = false
    /// Bumped to trigger the error shake on invalid input.
    var shakeTrigger = 0
    var validationMessage: String?

    @ObservationIgnored let store: AppStore
    @ObservationIgnored let checker: any SystemChecking
    @ObservationIgnored private var didLoad = false

    static let stepDefaultsKey = "onboarding.step"

    init(store: AppStore, checker: any SystemChecking = LocalSystemChecker()) {
        self.store = store
        self.checker = checker
    }

    /// Seed drafts from the snapshot/DB and resume a persisted step.
    func load() {
        guard !didLoad else { return }
        didLoad = true
        preferencesDraft = store.preferences
        if preferencesDraft.roles.isEmpty { preferencesDraft.roles = [] }
        neverGuessDraft = store.library.neverGuess
        profileDraft = store.library.profile
        careerURLs = store.preferences.careerPageUrls
        selectedMode = .review
        // Resumes already stored by the daemon: show them instead of asking for the upload again.
        if resumes.isEmpty {
            for v in store.library.resumeVariants where v.replacedBy == nil {
                var r = UploadedResume(url: URL(fileURLWithPath: v.filePath), label: v.label)
                r.tags = v.tags
                r.status = .parsed
                r.variantID = v.id
                resumes.append(r)
                let (id, url) = (r.id, r.url)
                Task { await self.loadThumbnail(id: id, url: url) }
            }
        }
        let saved = max(store.onboarding.step, UserDefaults.standard.integer(forKey: Self.stepDefaultsKey))
        if saved > 0, let s = Step(rawValue: min(saved, Step.mode.rawValue)) {
            step = s
        }
    }

    // MARK: Navigation

    var railIndex: Int { max(0, (Step.railSteps.firstIndex(of: step) ?? (step == .ready ? Step.railSteps.count : 0))) }

    func go(to target: Step) {
        movingForward = target > step
        step = target
        validationMessage = nil
        UserDefaults.standard.set(target.rawValue, forKey: Self.stepDefaultsKey)
        if target.rawValue >= 1 && target.rawValue <= 7 {
            Task { await store.onboardingSetStep(target.rawValue) }
        }
        if target == .systemCheck && checks.allSatisfy({ $0.state == .pending }) {
            Task { await runSystemCheck() }
        }
    }

    func begin() { go(to: .systemCheck) }

    func back() {
        if step == .resumes && showProfileConfirm { showProfileConfirm = false; return }
        guard let prev = Step(rawValue: step.rawValue - 1), prev != .ignition else { return }
        go(to: prev)
    }

    var canGoBack: Bool { step.rawValue > Step.systemCheck.rawValue || (step == .resumes && showProfileConfirm) }

    var canContinue: Bool {
        switch step {
        case .systemCheck: SystemCheckMerger.allRequiredOK(checks.compactMap(\.item)) && checks.allSatisfy { $0.state == .done }
        case .resumes: showProfileConfirm ? !(profileDraft.fullName ?? "").isEmpty : resumes.contains { $0.status == .parsed }
        case .preferences: !preferencesDraft.roles.isEmpty
        default: !isSaving
        }
    }

    var continueTitle: String {
        switch step {
        case .resumes: showProfileConfirm ? "Confirm profile" : "Continue"
        case .stories: stories.allSatisfy(\.isEmpty) ? "Skip for now" : "Save stories"
        case .mode: "Start AutoApply"
        default: "Continue"
        }
    }

    /// The step's one primary action.
    func primaryAction() async {
        guard canContinue else {
            invalid(continueBlockedReason)
            return
        }
        isSaving = true
        defer { isSaving = false }
        switch step {
        case .ignition: begin()
        case .systemCheck: go(to: .resumes)
        // Each save step advances only once the daemon has acked it; otherwise the daemon's
        // message is shown inline and the user stays put (so Ready → onboarding_complete is
        // never reached with unsaved profile / preferences / never-guess data).
        case .resumes:
            if showProfileConfirm {
                guard await saveProfile() else { return saveFailed() }
                showProfileConfirm = false
                go(to: .preferences)
            } else {
                showProfileConfirm = true
            }
        case .preferences:
            guard validatePreferences() else { return }
            guard await savePreferences() else { return saveFailed() }
            go(to: .neverGuess)
        case .neverGuess:
            guard await saveNeverGuess() else { return saveFailed() }
            go(to: .stories)
        case .stories:
            guard await saveStories() else { return saveFailed() }
            go(to: .sources)
        case .sources:
            guard await saveSources() else { return saveFailed() }
            go(to: .mode)
        case .mode:
            guard await store.setMode(selectedMode) else { return saveFailed() }
            go(to: .ready)
        case .ready:
            break
        }
    }

    /// Surface the last command failure inline (validation message + shake).
    private func saveFailed() {
        invalid(Self.failureMessage(for: store.lastCommandError))
    }

    /// Human message for a failed save. `invalid_payload` lists the pydantic field errors.
    static func failureMessage(for error: DaemonClientError?) -> String {
        switch error {
        case .daemon(let p)?:
            if case .array(let items)? = p.details?["errors"] {
                let lines = items.compactMap { item -> String? in
                    switch item {
                    case .string(let s): return s
                    case .object(let o):
                        guard case .string(let msg)? = o["msg"] ?? o["message"] else { return nil }
                        if case .array(let loc)? = o["loc"] {
                            let path = loc.compactMap { part -> String? in
                                switch part {
                                case .string(let s): return s
                                case .int(let i): return String(i)
                                default: return nil
                                }
                            }.filter { !["preferences", "profile", "values", "body"].contains($0) }
                            if !path.isEmpty { return "\(path.joined(separator: ".")): \(msg)" }
                        }
                        return msg
                    default: return nil
                    }
                }
                if !lines.isEmpty { return "Couldn't save: " + lines.joined(separator: "; ") }
            }
            return "Couldn't save: \(p.message)"
        case .timeout?:
            return "Couldn't save: the agent didn't respond. Try again."
        case .notConnected?:
            return "Couldn't save: the agent isn't running. AutoApply is restarting it; press Continue again in a few seconds."
        case let other?:
            return "Couldn't save: \(other.errorDescription ?? "unknown error")"
        case nil:
            return "Couldn't save. Try again."
        }
    }

    /// Why Continue is disabled on the resumes step: distinguishes "none added" from "still reading" and "failed".
    private var resumesBlockedReason: String {
        if resumes.isEmpty { return "Add at least one resume." }
        if resumes.contains(where: { $0.status == .parsing }) {
            return "Still reading your resume. Continue unlocks in a few seconds."
        }
        for r in resumes {
            if case .failed(let why) = r.status {
                return "Couldn't read \(r.label) (\(why)). Remove it and add the PDF again."
            }
        }
        return "Add at least one resume."
    }

    private var continueBlockedReason: String {
        switch step {
        case .systemCheck: "Required tools are missing. Fix them, then Re-check."
        case .resumes: showProfileConfirm ? "Your name is required." : resumesBlockedReason
        case .preferences: "Add at least one role."
        default: "Please complete this step."
        }
    }

    func invalid(_ message: String) {
        validationMessage = message
        shakeTrigger += 1
    }

    // MARK: Step 1 — system check

    func runSystemCheck() async {
        guard !isCheckingSystem else { return }
        isCheckingSystem = true
        defer { isCheckingSystem = false }
        for i in checks.indices {
            checks[i].state = .checking
            checks[i].item = nil
        }
        async let local = checker.checkLocalTools()
        async let daemon = store.isConnected ? store.onboardingSystemCheck() : nil
        let merged = SystemCheckMerger.merge(local: await local, daemon: await daemon, daemonReachable: store.isConnected)
        // Cascade rows to their results with a 150 ms stagger.
        for item in merged {
            if let i = checks.firstIndex(where: { $0.name == item.name }) {
                checks[i].item = item
                checks[i].state = .done
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Run a row's fix command (shown in the terminal well). `claude login` needs an interactive
    /// browser login, so it opens Terminal instead.
    func runFix(for name: SystemCheckItem.Name) async {
        guard let i = checks.firstIndex(where: { $0.name == name }), let command = checks[i].item?.fixCommand else { return }
        if command.contains("login") || command.contains("claude.ai/install") {  // interactive: needs Terminal
            await DaemonControl.openInTerminal(command)
            checks[i].fixOutput = "$ \(command)\n(opened in Terminal)"
            return
        }
        checks[i].isFixing = true
        checks[i].fixOutput = "$ \(command)\n"
        // Stream output into the terminal well while a long install runs.
        let result = await ProcessRunner.run("/bin/zsh", ["-lc", command], timeout: .seconds(600)) { [weak self] chunk in
            Task { @MainActor in
                guard let self, let j = self.checks.firstIndex(where: { $0.name == name }), self.checks[j].isFixing else { return }
                self.checks[j].fixOutput += chunk
                if self.checks[j].fixOutput.count > 20_000 {
                    self.checks[j].fixOutput = String(self.checks[j].fixOutput.suffix(20_000))
                }
            }
        }
        if let j = checks.firstIndex(where: { $0.name == name }) {
            // Replace the streamed text with the complete, ordered transcript.
            let tail = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            checks[j].fixOutput = "$ \(command)\n" + String(tail.suffix(20_000))
            checks[j].fixOutput += "\n[exit \(result.status)]"
            checks[j].isFixing = false
        }
        if name == .autoapplyd { try? await Task.sleep(for: .seconds(2)) }  // let the daemon open its socket
        await runSystemCheck()
    }

    // MARK: Step 2 — resumes & profile

    func addResumes(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" && !resumes.contains(where: { $0.url == url }) {
            let label = url.deletingPathExtension().lastPathComponent
            let resume = UploadedResume(url: url, label: label)
            resumes.append(resume)
            let id = resume.id
            Task { await self.loadThumbnail(id: id, url: url) }
            Task { await self.parse(id: id) }
        }
    }

    func removeResume(_ id: UUID) {
        resumes.removeAll { $0.id == id }
    }

    private func parse(id: UUID) async {
        guard let resume = resumes.first(where: { $0.id == id }) else { return }
        let accessing = resume.url.startAccessingSecurityScopedResource()
        defer { if accessing { resume.url.stopAccessingSecurityScopedResource() } }
        guard let result = await store.onboardingParseResume(filePath: resume.url.path, label: resume.label) else {
            update(id) { $0.status = .failed("Couldn't parse this PDF") }
            return
        }
        update(id) {
            $0.status = .parsed
            $0.variantID = result.resumeVariantId
        }
        // First parse pre-fills the profile; later ones only fill gaps.
        profileDraft = Self.mergeProfile(profileDraft, with: result.profile)
        uncertainFields.formUnion(result.uncertainFields)
    }

    private func loadThumbnail(id: UUID, url: URL) async {
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 240, height: 310), for: .mediaBox)
        }.value
        update(id) { $0.thumbnail = image }
    }

    private func update(_ id: UUID, _ body: (inout UploadedResume) -> Void) {
        guard let i = resumes.firstIndex(where: { $0.id == id }) else { return }
        body(&resumes[i])
    }

    /// Persist edited labels/tags for parsed variants.
    @discardableResult
    func saveResumeEdits() async -> Bool {
        for r in resumes {
            guard let id = r.variantID else { continue }
            guard await store.updateResumeVariant(UpdateResumeVariantPayload(id: id, label: r.label, tags: r.tags)) else { return false }
        }
        return true
    }

    static func mergeProfile(_ base: Profile, with parsed: Profile) -> Profile {
        var p = base
        p.fullName = p.fullName.nonEmpty ?? parsed.fullName
        p.firstName = p.firstName.nonEmpty ?? parsed.firstName
        p.lastName = p.lastName.nonEmpty ?? parsed.lastName
        p.email = p.email.nonEmpty ?? parsed.email
        p.phone = p.phone.nonEmpty ?? parsed.phone
        p.location = p.location.nonEmpty ?? parsed.location
        p.headline = p.headline.nonEmpty ?? parsed.headline
        p.summary = p.summary.nonEmpty ?? parsed.summary
        if p.links.isEmpty { p.links = parsed.links }
        if p.workHistory.isEmpty { p.workHistory = parsed.workHistory }
        if p.education.isEmpty { p.education = parsed.education }
        if p.skills.isEmpty { p.skills = parsed.skills }
        p.yearsExperience = p.yearsExperience ?? parsed.yearsExperience
        return p
    }

    @discardableResult
    func saveProfile() async -> Bool {
        guard await saveResumeEdits() else { return false }
        var patch = ProfilePatch()
        let p = profileDraft
        try? patch.set(.fullName, p.fullName.nonEmpty)
        try? patch.set(.email, p.email.nonEmpty)
        try? patch.set(.phone, p.phone.nonEmpty)
        try? patch.set(.location, p.location.nonEmpty)
        try? patch.set(.headline, p.headline.nonEmpty)
        try? patch.set(.links, p.links)
        try? patch.set(.skills, p.skills)
        try? patch.set(.workHistory, p.workHistory)
        try? patch.set(.education, p.education)
        if let y = p.yearsExperience { try? patch.set(.yearsExperience, y) }
        if let full = p.fullName.nonEmpty {
            let parts = full.split(separator: " ")
            if let first = parts.first { try? patch.set(.firstName, String(first)) }
            if parts.count > 1 { try? patch.set(.lastName, parts.dropFirst().joined(separator: " ")) }
        }
        return await store.updateProfile(patch) != nil
    }

    // MARK: Step 3 — preferences

    func validatePreferences() -> Bool {
        if let floor = preferencesDraft.salaryFloor, floor < 0 {
            invalid("Salary floor can't be negative.")
            return false
        }
        if preferencesDraft.remotePolicy.isEmpty {
            invalid("Pick at least one of Remote, Hybrid or Onsite.")
            return false
        }
        return true
    }

    @discardableResult
    func savePreferences() async -> Bool {
        let d = preferencesDraft
        var patch = PreferencesPatch()
        try? patch.set(.roles, d.roles)
        try? patch.set(.seniority, d.seniority)
        try? patch.set(.locations, d.locations)
        try? patch.set(.remotePolicy, d.remotePolicy)
        try? patch.set(.workAuthSummary, d.workAuthSummary.nonEmpty)
        try? patch.set(.salaryFloor, d.salaryFloor)
        try? patch.set(.salaryCurrency, d.salaryCurrency)
        try? patch.set(.hideWithoutSalary, d.hideWithoutSalary)
        try? patch.set(.excludeCompanies, d.excludeCompanies)
        try? patch.set(.excludeKeywords, d.excludeKeywords)
        try? patch.set(.dailyCap, d.dailyCap)
        try? patch.set(.matchThreshold, d.matchThreshold)
        return await store.updatePreferences(patch)
    }

    // MARK: Step 4 — never-guess

    @discardableResult
    func saveNeverGuess() async -> Bool {
        let n = neverGuessDraft
        var patch = NeverGuessPatch()
        // Blank = "always ask me" → explicit null.
        try? patch.set(.sponsorship, n.sponsorship.nonEmpty)
        try? patch.set(.salaryExpectation, n.salaryExpectation.nonEmpty)
        try? patch.set(.salaryNegotiable, n.salaryExpectation.nonEmpty == nil ? nil : n.salaryNegotiable)
        try? patch.set(.noticePeriod, n.noticePeriod.nonEmpty)
        try? patch.set(.startDate, n.startDate.nonEmpty)
        try? patch.set(.relocation, n.relocation.nonEmpty)
        try? patch.set(.eeoPolicy, n.eeoPolicy)
        try? patch.set(.attestAccuracy, n.attestAccuracy)
        try? patch.set(.attestBackgroundCheck, n.attestBackgroundCheck)
        if !n.workAuth.isEmpty { try? patch.set(.workAuth, n.workAuth) }
        return await store.updateNeverGuess(patch) != nil
    }

    // MARK: Step 5 — stories

    func addStory() { stories.append(StoryDraft()) }
    func removeStory(_ id: UUID) {
        stories.removeAll { $0.id == id }
        if stories.isEmpty { stories = [StoryDraft()] }
    }

    @discardableResult
    func saveStories() async -> Bool {
        for i in stories.indices where !stories[i].isEmpty {
            let s = stories[i]
            guard let id = await store.upsertStory(UpsertStoryPayload(id: s.storyID, title: s.title, situation: s.situation, task: s.task,
                                                                      action: s.action, result: s.result, tags: s.tags)) else { return false }
            if i < stories.count { stories[i].storyID = id }
        }
        return true
    }

    // MARK: Step 6 — sources

    func sourceStatus(_ name: SourceName) -> SourceStatus? { store.sources[name] }

    func connect(_ source: OnboardingConnectSourcePayload.Source) async {
        _ = await store.onboardingConnectSource(source)
    }

    func checkLogin(_ source: CheckSourceLoginPayload.Source) async {
        _ = await store.checkSourceLogin(source)
    }

    func addCareerURL() {
        let trimmed = careerURLDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let normalized = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host?.contains(".") == true else {
            invalid("That doesn't look like a URL.")
            return
        }
        if !careerURLs.contains(normalized) { careerURLs.append(normalized) }
        careerURLDraft = ""
    }

    @discardableResult
    func saveSources() async -> Bool {
        var enabled = store.preferences.sourcesEnabled
        for name in ["greenhouse", "lever", "ashby"] { enabled[name] = true }
        enabled["careers"] = !careerURLs.isEmpty || (enabled["careers"] ?? true)
        if store.sources[.linkedin]?.connected == true { enabled["linkedin"] = true }
        if store.sources[.glassdoor]?.connected == true { enabled["glassdoor"] = true }
        var patch = PreferencesPatch()
        try? patch.set(.sourcesEnabled, enabled)
        try? patch.set(.careerPageUrls, careerURLs)
        return await store.updatePreferences(patch)
    }

    // MARK: Finish

    /// "Run Prep pass" / "Not now". Returns true when onboarding is complete.
    func finish(runPrep: Bool) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.onboardingComplete(runPrep: runPrep)
        if ok {
            OnboardingGate.markCompleted()
            UserDefaults.standard.removeObject(forKey: Self.stepDefaultsKey)
        }
        return ok
    }

    /// First scheduled run time for the Ready screen ("Your agent starts at 09:00").
    var firstRunText: String {
        if let next = store.nextRunAt { return next.formatted(date: .omitted, time: .shortened) }
        return store.preferences.schedule.first ?? "09:00"
    }
}

extension Optional where Wrapped == String {
    /// nil for nil or whitespace-only strings.
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
