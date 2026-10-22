// AppStore+Commands.swift — every mutation the app performs, as a socket command with
// optimistic UI, a 2 s ack timeout, rollback, and a toast on failure (§8.4 rule 6).
import Foundation

extension AppStore {
    /// Send `command`, applying `optimistic` immediately and `rollback` if the daemon errors
    /// or doesn't ack in time. Returns the reply on success.
    @discardableResult
    func perform(_ command: Command,
                 optimistic: (() -> Void)? = nil,
                 rollback: (() -> Void)? = nil,
                 timeout: Duration? = nil,
                 silent: Bool = false) async -> Result<EventEnvelope, DaemonClientError> {
        optimistic?()
        do {
            let reply = try await client.request(command, timeout: timeout ?? commandTimeout)
            lastCommandError = nil
            return .success(reply)
        } catch {
            let clientError = (error as? DaemonClientError) ?? .decoding(String(describing: error))
            lastCommandError = clientError
            rollback?()
            if !silent { toasts.error(clientError.errorDescription ?? "Command failed") }
            return .failure(clientError)
        }
    }

    /// Send and decode `ack.result` into `T`.
    func performResult<T: Decodable>(_ command: Command, as type: T.Type, timeout: Duration? = nil, silent: Bool = false) async -> T? {
        switch await perform(command, timeout: timeout, silent: silent) {
        case .success(let reply):
            guard case .ack(let ack) = reply.event else { return nil }
            return try? JSONValue.object(ack.result ?? [:]).decode(T.self)
        case .failure:
            return nil
        }
    }

    // MARK: Agent control

    /// Kill switch: instant in the UI, confirmed by the daemon; retries while unacknowledged.
    func togglePause() async {
        if live.paused || live.pauseRequest == .pausing { await resume() } else { await pauseAll() }
    }

    func pauseAll() async {
        let wasPaused = live.paused
        live.paused = true
        live.pauseRequest = .pausing
        for attempt in 1...3 {
            switch await perform(.pauseAll(PauseAllPayload()), silent: true) {
            case .success:
                live.pauseRequest = nil
                return
            case .failure(.timeout(_)) where attempt < 3:
                continue   // keep showing "Pausing…" and retry
            case .failure(let error):
                live.paused = wasPaused
                live.pauseRequest = nil
                toasts.error(error.errorDescription ?? "Couldn't pause")
                return
            }
        }
    }

    func resume() async {
        let wasPaused = live.paused
        live.paused = false
        live.pauseRequest = .resuming
        let result = await perform(.resume(ResumePayload()), rollback: { [live] in live.paused = wasPaused })
        live.pauseRequest = nil
        _ = result
    }

    @discardableResult
    func runNow(_ kind: RunKind = .full) async -> String? {
        struct RunResult: Decodable { var runId: String?
            enum CodingKeys: String, CodingKey { case runId = "run_id" } }
        return await performResult(.runNow(RunNowPayload(kind: kind)), as: RunResult.self)?.runId
    }

    func runPrepPass() async { await runNow(.prep) }

    /// Fill and submit only the jobs already queued (answered Needs-You jobs come back here), without
    /// a new search or scoring pass.
    func applyQueued() async { await runNow(.apply) }

    /// Jobs waiting in the queue for the agent (not yet being worked on).
    var queuedCount: Int { jobs.all.reduce(0) { $0 + ($1.state == .queued ? 1 : 0) } }

    /// Returns true once the daemon acks; on failure the local mode is rolled back.
    @discardableResult
    func setMode(_ mode: Mode) async -> Bool {
        let old = preferences.mode
        var patch = PreferencesPatch()
        try? patch.set(.mode, mode)
        return await updatePreferences(patch, optimistic: { $0.mode = mode }, rollback: { $0.mode = old })
    }

    /// Partial preferences update; `optimistic` edits the local copy immediately.
    /// Returns true when the daemon acked with the updated preferences (see `lastCommandError`
    /// for why it didn't).
    @discardableResult
    func updatePreferences(_ patch: PreferencesPatch,
                           optimistic: ((inout Preferences) -> Void)? = nil,
                           rollback: ((inout Preferences) -> Void)? = nil) async -> Bool {
        struct Result: Decodable { var preferences: Preferences }
        if let optimistic { var p = preferences; optimistic(&p); setPreferences(p) }
        if let result = await performResult(.updatePreferences(UpdatePreferencesPayload(preferences: patch)), as: Result.self) {
            setPreferences(result.preferences)
            return true
        }
        if let rollback {
            var p = preferences; rollback(&p); setPreferences(p)
        }
        return false
    }

    @discardableResult
    func updateNeverGuess(_ patch: NeverGuessPatch) async -> NeverGuess? {
        struct Result: Decodable { var neverGuess: NeverGuess
            enum CodingKeys: String, CodingKey { case neverGuess = "never_guess" } }
        let result = await performResult(.updateNeverGuess(UpdateNeverGuessPayload(values: patch)), as: Result.self,
                                         timeout: .seconds(10))
        if let ng = result?.neverGuess { library.neverGuess = ng }
        return result?.neverGuess
    }

    @discardableResult
    func updateProfile(_ patch: ProfilePatch) async -> Profile? {
        struct Result: Decodable { var profile: Profile }
        let result = await performResult(.updateProfile(UpdateProfilePayload(profile: patch)), as: Result.self)
        if let p = result?.profile { library.profile = p }
        return result?.profile
    }

    // MARK: Inbox

    /// Answer a whole cluster. The cluster leaves the list immediately; restored on failure.
    @discardableResult
    func answerQuestion(clusterID: String, answer: String, saveToMemory: Bool = true, saveToProfile: Bool = false,
                        perJobAnswers: [PerJobAnswer] = []) async -> Bool {
        var removed: QuestionCluster?
        let result = await perform(
            .answerQuestion(AnswerQuestionPayload(clusterId: clusterID, answer: answer, saveToMemory: saveToMemory,
                                                  saveToProfile: saveToProfile, perJobAnswers: perJobAnswers)),
            optimistic: { [inbox] in removed = inbox.removeOptimistically(clusterID: clusterID) },
            rollback: { [inbox] in if let removed { inbox.restore(removed) } })
        if case .success = result { return true }
        return false
    }

    /// A grounded draft for a question, or a revision of `currentAnswer` as `instructions` ask
    /// (protocol.md §5.5). Answers nothing: the caller puts the text in the editor.
    func draftAnswer(clusterID: String, jobID: Int? = nil, instructions: String? = nil,
                     currentAnswer: String? = nil) async -> Result<DraftAnswerResult, DaemonClientError> {
        let command = Command.draftAnswer(DraftAnswerPayload(clusterId: clusterID, jobId: jobID, instructions: instructions,
                                                             currentAnswer: currentAnswer))
        switch await perform(command, timeout: draftAnswerTimeout, silent: true) {
        case .success(let reply):
            guard case .ack(let ack) = reply.event else { return .failure(.decoding("no result")) }
            do {
                return .success(try JSONValue.object(ack.result ?? [:]).decode(DraftAnswerResult.self))
            } catch {
                return .failure(.decoding(String(describing: error)))
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    /// One model call, sometimes two (a fact-check retry).
    var draftAnswerTimeout: Duration { .seconds(120) }

    @discardableResult
    func skipQuestion(clusterID: String, reason: String? = nil) async -> Bool {
        var removed: QuestionCluster?
        let result = await perform(
            .skipQuestion(SkipQuestionPayload(clusterId: clusterID, reason: reason)),
            optimistic: { [inbox] in removed = inbox.removeOptimistically(clusterID: clusterID) },
            rollback: { [inbox] in if let removed { inbox.restore(removed) } })
        if case .success = result { return true }
        return false
    }

    // MARK: Review

    /// Approve reviewed applications for submission. Returns true once the daemon acks.
    ///
    /// This sends immediately. The UI never calls it directly: every approve (Review, Job detail,
    /// ⌘K / the Job menu) goes through `SendHoldModel`, which calls this only after its ≈5 s
    /// Undo window closes, and never on quit.
    ///
    /// An explicit error reply rolls the optimistic `submitting` state back. A *timeout* does
    /// not: the daemon may already have accepted the approval and be submitting, so the rows
    /// stay `submitting` (the DB poll reconciles them) and the user gets a calm info toast
    /// instead of a failure. Returns false in both cases (not confirmed).
    @discardableResult
    func approve(applicationIDs: [Int]) async -> Bool {
        guard !applicationIDs.isEmpty else { return false }
        let previous = applicationIDs.compactMap { id in jobs.job(applicationID: id).map { (id, $0.state) } }
        let result = await perform(
            .approve(ApprovePayload(applicationIds: applicationIDs)),
            optimistic: { [jobs] in
                jobs.performBatch { for id in applicationIDs { jobs.mutate(applicationID: id) { $0.state = .submitting } } }
            },
            timeout: approvalTimeout,
            silent: true)
        switch result {
        case .success:
            return true
        case .failure(.timeout):
            toasts.show("Approval sent; waiting for the agent to confirm", symbol: "clock", style: .info)
            return false
        case .failure(let error):
            jobs.performBatch { for (id, state) in previous { jobs.mutate(applicationID: id) { $0.state = state } } }
            toasts.error(approveErrorMessage(error) ?? error.errorDescription ?? "Couldn't approve")
            return false
        }
    }

    /// Plain-English text for a `cap_reached` refusal (the daemon's message is "<reason>: cannot submit application N now").
    private func approveErrorMessage(_ error: DaemonClientError) -> String? {
        guard case .daemon(let p) = error, p.code == .capReached else { return nil }
        let job = p.applicationId.flatMap { jobs.job(applicationID: $0) }
        let company = job?.company ?? "this company"
        let title = job.map { " · \($0.title)" } ?? ""
        let reason = p.message.split(separator: ":").first.map(String.init) ?? ""
        switch reason {
        case "company_cooldown":
            return "Not sent: you applied to \(company) in the last \(preferences.perCompanyCooldownDays) days (or picked two \(company) jobs). \(company)\(title) stays in Review."
        case "company_attempt_unconfirmed":
            return "Not sent: another \(company) application is still being confirmed. \(company)\(title) stays in Review."
        case "daily_cap":
            return "Not sent: today's limit of \(preferences.dailyCap) applications is reached. Nothing was submitted; try again tomorrow."
        default:
            return nil
        }
    }

    @discardableResult
    func reject(applicationID: Int, reason: String) async -> Bool {
        let previous = jobs.job(applicationID: applicationID).map { ($0.state, $0.stateReason) }
        let result = await perform(
            .reject(RejectPayload(applicationId: applicationID, reason: reason)),
            optimistic: { [jobs] in jobs.mutate(applicationID: applicationID) { $0.state = .skipped; $0.stateReason = reason } },
            rollback: { [jobs] in
                if let (state, stateReason) = previous {
                    jobs.mutate(applicationID: applicationID) { $0.state = state; $0.stateReason = stateReason }
                }
            })
        if case .success = result { return true }
        return false
    }

    func editApplicationAnswer(id: Int, answer: String) async {
        await perform(.editApplicationAnswer(EditApplicationAnswerPayload(applicationAnswerId: id, answer: answer)))
    }

    // MARK: Board / jobs

    /// Manual board status (only for submitted applications). Optimistic; offers Undo.
    @discardableResult
    func setStatus(applicationID: Int, status: BoardStatus, offerUndo: Bool = true) async -> Bool {
        guard let job = jobs.job(applicationID: applicationID), job.state == .submitted else { return false }
        let previous = job.status
        let result = await perform(
            .setStatus(SetStatusPayload(applicationId: applicationID, status: status)),
            optimistic: { [jobs] in jobs.mutate(applicationID: applicationID) { $0.status = status; $0.statusUpdatedAt = Date() } },
            rollback: { [jobs] in jobs.mutate(applicationID: applicationID) { $0.status = previous } })
        guard case .success = result else { return false }
        // A fresh submission has status nil, which the board shows as Applied: undo goes back there.
        let undoTarget = previous ?? .applied
        if offerUndo, undoTarget != status {
            toasts.show("Moved to \(status.label)", symbol: "arrow.right", style: .success, duration: .seconds(4),
                        actionTitle: "Undo") { [weak self] in
                Task { await self?.setStatus(applicationID: applicationID, status: undoTarget, offerUndo: false) }
            }
        }
        return true
    }

    func setJobMode(jobID: Int, mode: Mode?) async {
        let previous = jobs.job(id: jobID)?.modeOverride
        await perform(.setJobMode(SetJobModePayload(jobId: jobID, mode: mode)),
                      optimistic: { [jobs] in jobs.mutate(jobID: jobID) { $0.modeOverride = mode } },
                      rollback: { [jobs] in jobs.mutate(jobID: jobID) { $0.modeOverride = previous } })
    }

    @discardableResult
    func retryApplication(applicationID: Int) async -> Bool {
        if case .success = await perform(.retryApplication(RetryApplicationPayload(applicationId: applicationID))) { return true }
        return false
    }

    /// Override a skip: skipped → queued (user only). Returns true on ack.
    @discardableResult
    func applyAnyway(applicationID: Int) async -> Bool {
        let previous = jobs.job(applicationID: applicationID)
        let result = await perform(
            .applyAnyway(ApplyAnywayPayload(applicationId: applicationID)),
            optimistic: { [jobs] in jobs.mutate(applicationID: applicationID) { $0.state = .queued; $0.stateReason = "user_apply_anyway" } },
            rollback: { [jobs] in
                jobs.mutate(applicationID: applicationID) { $0.state = previous?.state ?? .skipped; $0.stateReason = previous?.stateReason }
            })
        guard case .success = result else { return false }
        toasts.show("Queued — the agent will apply on the next run", symbol: "arrow.uturn.forward", style: .success)
        return true
    }

    /// Board: a card dropped on Queued (discovered / scored / skipped / failed → queued). The agent
    /// starts on it right away unless paused. Returns true on ack.
    @discardableResult
    func queueApplication(applicationID: Int) async -> Bool {
        struct Reply: Decodable { var started: Bool }
        let previous = jobs.job(applicationID: applicationID)
        let result = await perform(
            .queueApplication(QueueApplicationPayload(applicationId: applicationID, applyNow: true)),
            optimistic: { [jobs] in jobs.mutate(applicationID: applicationID) { $0.state = .queued; $0.stateReason = "user_queued" } },
            rollback: { [jobs] in
                jobs.mutate(applicationID: applicationID) { $0.state = previous?.state ?? .discovered; $0.stateReason = previous?.stateReason }
            })
        guard case .success(let reply) = result else { return false }
        var started = false
        if case .ack(let ack) = reply.event { started = (try? JSONValue.object(ack.result ?? [:]).decode(Reply.self))?.started ?? false }
        toasts.show(started ? "Queued · the agent is applying now" : "Queued · the agent applies when it resumes",
                    symbol: "paperplane.fill", style: .success)
        return true
    }

    /// Board: "I applied myself" — a job the agent never submitted, dropped on Applied or a later
    /// column. It becomes a manual application with that board status. Returns true on ack.
    @discardableResult
    func markApplied(applicationID: Int, status: BoardStatus) async -> Bool {
        let previous = jobs.job(applicationID: applicationID)
        let result = await perform(
            .markApplied(MarkAppliedPayload(applicationId: applicationID, status: status)),
            optimistic: { [jobs] in
                jobs.mutate(applicationID: applicationID) {
                    $0.state = .submitted; $0.stateReason = "user_applied"; $0.status = status; $0.statusUpdatedAt = Date()
                }
            },
            rollback: { [jobs] in
                jobs.mutate(applicationID: applicationID) {
                    $0.state = previous?.state ?? .discovered; $0.stateReason = previous?.stateReason; $0.status = previous?.status
                }
            })
        guard case .success = result else { return false }
        toasts.show(status == .applied ? "Marked as applied by you" : "Marked as applied · moved to \(status.label)",
                    symbol: StatusKind(status: status).symbol, style: .success)
        return true
    }

    struct AddedJob: Decodable, Sendable, Equatable {
        var jobId: Int
        var applicationId: Int
        var created: Bool
        var state: AppState
        var title: String
        var company: String
        var started: Bool

        enum CodingKeys: String, CodingKey {
            case jobId = "job_id", applicationId = "application_id", created, state, title, company, started
        }
    }

    /// Add a job from any apply link; the daemon reads the page, queues it and (unless paused)
    /// starts filling right away. Reading the page can take a few seconds, hence the long timeout.
    func addJob(url: String, title: String? = nil, company: String? = nil, applyNow: Bool = true) async -> AddedJob? {
        let clean = { (s: String?) in s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        let payload = AddJobUrlPayload(url: url.trimmingCharacters(in: .whitespacesAndNewlines), title: clean(title),
                                       company: clean(company), applyNow: applyNow)
        guard let added = await performResult(.addJobUrl(payload), as: AddedJob.self, timeout: .seconds(45)) else { return nil }
        let name = "\(added.company) · \(added.title)"
        switch (added.created, added.started) {
        case (_, true): toasts.show("Added \(name) · filling now", symbol: "link.badge.plus", style: .success)
        case (true, false) where isPaused: toasts.show("Added \(name) · applies when you resume", symbol: "pause.fill", style: .info)
        case (true, false): toasts.show("Added \(name) · applies on the next run", symbol: "link.badge.plus", style: .success)
        case (false, false): toasts.show("Already tracked: \(name) (\(added.state.rawValue.replacingOccurrences(of: "_", with: " ")))",
                                         symbol: "info.circle", style: .info)
        }
        return added
    }

    /// Save free-form notes on a job (null/empty clears them).
    @discardableResult
    func updateJobNotes(jobID: Int, notes: String?) async -> Bool {
        let previous = jobs.job(id: jobID)?.notes
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let result = await perform(
            .updateJobNotes(UpdateJobNotesPayload(jobId: jobID, notes: value)),
            optimistic: { [jobs] in jobs.mutate(jobID: jobID) { $0.notes = value } },
            rollback: { [jobs] in jobs.mutate(jobID: jobID) { $0.notes = previous } })
        if case .success = result { return true }
        return false
    }

    /// Swap the resume an application uses (Review ↻). An application awaiting review goes
    /// back to queued so the form is re-filled with the new file.
    @discardableResult
    func setApplicationResume(applicationID: Int, resumeVariantID: Int) async -> Bool {
        let previous = jobs.job(applicationID: applicationID)?.resumeVariantID
        let result = await perform(
            .setApplicationResume(SetApplicationResumePayload(applicationId: applicationID, resumeVariantId: resumeVariantID)),
            optimistic: { [jobs] in jobs.mutate(applicationID: applicationID) { $0.resumeVariantID = resumeVariantID } },
            rollback: { [jobs] in jobs.mutate(applicationID: applicationID) { $0.resumeVariantID = previous } })
        if case .success = result { return true }
        return false
    }

    @discardableResult
    func resolveUnknown(applicationID: Int, submitted: Bool) async -> Bool {
        if case .success = await perform(.resolveUnknown(ResolveUnknownPayload(applicationId: applicationID, submitted: submitted))) { return true }
        return false
    }

    // MARK: Easy Apply

    func markEasyApplyDone(jobID: Int) async {
        await perform(.markEasyApplyDone(MarkEasyApplyDonePayload(jobId: jobID)))
    }

    func markEasyApplyOpened(jobID: Int) async {
        await perform(.markEasyApplyOpened(MarkEasyApplyOpenedPayload(jobId: jobID)), silent: true)
    }

    func dismissEasyApply(jobID: Int) async {
        await perform(.dismissEasyApply(DismissEasyApplyPayload(jobId: jobID)))
    }

    func openAgentChrome(url: String? = nil) async {
        await perform(.openAgentChrome(OpenAgentChromePayload(url: url)))
    }

    // MARK: Library

    @discardableResult
    func addResumeVariant(filePath: String, label: String, tags: [String] = [], isDefault: Bool = false) async -> Int? {
        struct Result: Decodable { var resumeVariantId: Int
            enum CodingKeys: String, CodingKey { case resumeVariantId = "resume_variant_id" } }
        return await performResult(.addResumeVariant(AddResumeVariantPayload(filePath: filePath, label: label, tags: tags, isDefault: isDefault)),
                                   as: Result.self, timeout: .seconds(30))?.resumeVariantId
    }

    @discardableResult
    func updateResumeVariant(_ payload: UpdateResumeVariantPayload) async -> Bool {
        if case .success = await perform(.updateResumeVariant(payload)) { return true }
        return false
    }

    @discardableResult
    func upsertStory(_ payload: UpsertStoryPayload) async -> Int? {
        struct Result: Decodable { var storyId: Int
            enum CodingKeys: String, CodingKey { case storyId = "story_id" } }
        return await performResult(.upsertStory(payload), as: Result.self)?.storyId
    }

    func deleteStory(id: Int) async {
        await perform(.deleteStory(DeleteStoryPayload(id: id)))
    }

    func updateAnswer(id: Int, answer: String, canonicalQuestion: String? = nil) async {
        await perform(.updateAnswer(UpdateAnswerPayload(answerId: id, answer: answer, canonicalQuestion: canonicalQuestion)))
    }

    func deleteAnswer(id: Int) async {
        await perform(.deleteAnswer(DeleteAnswerPayload(answerId: id)))
    }

    // MARK: Onboarding

    func onboardingSystemCheck() async -> SystemCheckResult? {
        await performResult(.onboardingSystemCheck(OnboardingSystemCheckPayload()), as: SystemCheckResult.self,
                            timeout: .seconds(20), silent: true)
    }

    func onboardingParseResume(filePath: String, label: String?) async -> ParseResumeResult? {
        await performResult(.onboardingParseResume(OnboardingParseResumePayload(filePath: filePath, label: label)),
                            as: ParseResumeResult.self, timeout: .seconds(90))
    }

    /// Roles / seniority / locations suggested from the stored profile (nothing is saved).
    func suggestPreferences() async -> SuggestedPreferences? {
        await performResult(.suggestPreferences(SuggestPreferencesPayload()), as: SuggestedPreferences.self,
                            timeout: .seconds(40), silent: true)
    }

    /// Save just the years of experience (Settings → Preferences).
    func setYearsExperience(_ years: Double) async {
        var patch = ProfilePatch()
        try? patch.set(.yearsExperience, years)
        await updateProfile(patch)
    }

    func onboardingConnectSource(_ source: OnboardingConnectSourcePayload.Source) async -> Bool {
        if case .success = await perform(.onboardingConnectSource(OnboardingConnectSourcePayload(source: source)), timeout: .seconds(10)) {
            return true
        }
        return false
    }

    /// Mailbox for emailed security codes (IMAP + app password; the password lives in the Keychain).
    struct MailAccountStatus: Codable, Equatable, Sendable {
        var email: String?
        var connected: Bool
        var error: String?
    }

    func setMailAccount(email: String, appPassword: String) async -> MailAccountStatus? {
        await performResult(.setMailAccount(SetMailAccountPayload(email: email, appPassword: appPassword)),
                            as: MailAccountStatus.self, timeout: .seconds(40))
    }

    func getMailAccount(test: Bool = false) async -> MailAccountStatus? {
        await performResult(.getMailAccount(GetMailAccountPayload(test: test)), as: MailAccountStatus.self,
                            timeout: .seconds(test ? 40 : 10), silent: true)
    }

    func clearMailAccount() async -> MailAccountStatus? {
        await performResult(.clearMailAccount(ClearMailAccountPayload()), as: MailAccountStatus.self, timeout: .seconds(15))
    }

    /// A job-site account the agent created (Settings ▸ Guardrails). Passwords stay in the Keychain;
    /// `revealSiteAccountPassword` reads one on demand.
    struct SiteAccount: Codable, Equatable, Sendable, Identifiable {
        var host: String
        var email: String?
        var company: String?
        var status: String?
        var createdAt: String?
        var updatedAt: String?
        var id: String { host }

        enum CodingKeys: String, CodingKey {
            case host, email, company, status
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct SiteAccountList: Codable, Equatable, Sendable {
        var accounts: [SiteAccount]
        var enabled: Bool
    }

    func listSiteAccounts() async -> SiteAccountList? {
        await performResult(.listSiteAccounts(ListSiteAccountsPayload()), as: SiteAccountList.self, timeout: .seconds(10), silent: true)
    }

    func revealSiteAccountPassword(host: String) async -> String? {
        struct Reply: Decodable { var password: String }
        return await performResult(.revealSiteAccountPassword(RevealSiteAccountPasswordPayload(host: host)), as: Reply.self,
                                   timeout: .seconds(15))?.password
    }

    func deleteSiteAccount(host: String) async -> Bool {
        if case .success = await perform(.deleteSiteAccount(DeleteSiteAccountPayload(host: host)), timeout: .seconds(15)) { return true }
        return false
    }

    /// Settings: zero today's LinkedIn/Glassdoor browsing-session counter. The daemon answers with a
    /// `cap_reached` event (used 0) that updates the dashboard caps.
    func resetSourceCap(_ source: ResetSourceCapPayload.Source) async -> Bool {
        if case .success = await perform(.resetSourceCap(ResetSourceCapPayload(source: source)), timeout: .seconds(10)) {
            toasts.show("Today's \(source == .linkedin ? "LinkedIn" : "Glassdoor") reads reset.", symbol: "arrow.counterclockwise", style: .info, duration: .seconds(2))
            return true
        }
        return false
    }

    /// Settings ▸ Sources ▸ Suggested companies: "Add" watches the company (its ATS board, else its career page).
    @discardableResult
    func acceptCompanySuggestion(_ item: CompanySuggestionItem) async -> Bool {
        let before = library.companySuggestions
        let result = await perform(.acceptCompanySuggestion(AcceptCompanySuggestionPayload(suggestionId: item.id)),
                                   optimistic: { [weak self] in self?.library.companySuggestions.removeAll { $0.id == item.id } },
                                   rollback: { [weak self] in self?.library.companySuggestions = before },
                                   timeout: .seconds(10))
        if case .success = result {
            toasts.show("Watching \(item.companyName).", symbol: "building.2", style: .info, duration: .seconds(2))
            return true
        }
        return false
    }

    /// "Dismiss": never suggest this company again (one the agent added by itself is unwatched).
    @discardableResult
    func dismissCompanySuggestion(_ item: CompanySuggestionItem) async -> Bool {
        let before = library.companySuggestions
        let result = await perform(.dismissCompanySuggestion(DismissCompanySuggestionPayload(suggestionId: item.id)),
                                   optimistic: { [weak self] in self?.library.companySuggestions.removeAll { $0.id == item.id } },
                                   rollback: { [weak self] in self?.library.companySuggestions = before },
                                   timeout: .seconds(10))
        if case .success = result { return true }
        return false
    }

    /// "Check now": asks the daemon to look at the saved Chrome login in a background window.
    /// The result arrives as a `source_status` event; the return value is just success of the command.
    func checkSourceLogin(_ source: CheckSourceLoginPayload.Source) async -> Bool {
        if case .success = await perform(.checkSourceLogin(CheckSourceLoginPayload(source: source)), timeout: .seconds(60)) {
            return true
        }
        return false
    }

    func onboardingSetStep(_ step: Int) async {
        var state = onboarding
        state.step = step
        setOnboarding(state)
        await perform(.onboardingSetStep(OnboardingSetStepPayload(step: step)), silent: true)
    }

    @discardableResult
    func onboardingComplete(runPrep: Bool) async -> Bool {
        let result = await perform(.onboardingComplete(OnboardingCompletePayload(runPrep: runPrep)), timeout: .seconds(5))
        if case .success = result {
            var state = onboarding
            state.completed = true
            state.step = 7
            setOnboarding(state)
            return true
        }
        return false
    }
}
