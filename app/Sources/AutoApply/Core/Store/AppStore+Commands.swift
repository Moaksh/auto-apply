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
            toasts.show("Approval sent; waiting for the daemon to confirm", symbol: "clock", style: .info)
            return false
        case .failure(let error):
            jobs.performBatch { for (id, state) in previous { jobs.mutate(applicationID: id) { $0.state = state } } }
            toasts.error(error.errorDescription ?? "Couldn't approve")
            return false
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

    func retryApplication(applicationID: Int) async {
        await perform(.retryApplication(RetryApplicationPayload(applicationId: applicationID)))
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

    func resolveUnknown(applicationID: Int, submitted: Bool) async {
        await perform(.resolveUnknown(ResolveUnknownPayload(applicationId: applicationID, submitted: submitted)))
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

    /// Settings: zero today's LinkedIn/Glassdoor browsing-session counter. The daemon answers with a
    /// `cap_reached` event (used 0) that updates the dashboard caps.
    func resetSourceCap(_ source: ResetSourceCapPayload.Source) async -> Bool {
        if case .success = await perform(.resetSourceCap(ResetSourceCapPayload(source: source)), timeout: .seconds(10)) {
            toasts.show("Today's \(source == .linkedin ? "LinkedIn" : "Glassdoor") reads reset.", symbol: "arrow.counterclockwise", style: .info, duration: .seconds(2))
            return true
        }
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
