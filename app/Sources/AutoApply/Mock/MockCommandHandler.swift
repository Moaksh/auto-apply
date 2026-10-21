// MockCommandHandler.swift — autoapplyd's command semantics (contract/protocol.md §5) against
// MockWorld: validation errors, ack results, and follow-up side-effect events.
import Foundation

enum MockCommandHandler {
    struct Handled: Sendable {
        var reply: DaemonEvent
        var followUp: (@Sendable (MockWorld) async -> Void)?
    }

    static func ack(_ result: [String: JSONValue]? = nil) -> DaemonEvent { .ack(AckPayload(ok: true, result: result)) }

    static func ack<T: Encodable>(encoding value: T) -> DaemonEvent {
        if case .object(let o)? = try? JSONValue.encode(value) { return .ack(AckPayload(ok: true, result: o)) }
        return .ack(AckPayload(ok: true, result: nil))
    }

    static func error(_ code: ErrorCode, _ message: String, applicationID: Int? = nil, jobID: Int? = nil) -> DaemonEvent {
        .error(ErrorPayload(code: code, message: message, jobId: jobID, applicationId: applicationID))
    }

    /// Overlay `patch` keys onto `value` (JSON object merge); explicit null → field default.
    static func merge<T: Codable>(_ value: T, patch: [String: JSONValue]) throws -> T {
        guard case .object(var object) = try JSONValue.encode(value) else { return value }
        for (k, v) in patch {
            if v == .null { object.removeValue(forKey: k) } else { object[k] = v }
        }
        return try JSONValue.object(object).decode(T.self)
    }

    static func handle(_ command: Command, world: MockWorld) async -> Handled {
        switch command {
        case .hello:
            return Handled(reply: .snapshot(world.snapshot()))

        case .ping:
            return Handled(reply: ack())

        case .runNow(let p):
            if world.isPaused { return Handled(reply: error(.paused, "Agent is paused")) }
            if world.isRunning { return Handled(reply: error(.conflict, "A run is already in progress")) }
            let runID = String(format: "mockrun%04d", world.read { $0.runCounter } + 1)
            return Handled(reply: ack(["run_id": .string(runID)])) { world in await MockScripts.miniRun(world, kind: p.kind) }

        case .pauseAll:
            return Handled(reply: ack()) { $0.setPaused(true) }

        case .resume:
            return Handled(reply: ack()) { $0.setPaused(false) }

        case .answerQuestion(let p):
            guard let cluster = world.cluster(id: p.clusterId) else {
                return Handled(reply: error(.notFound, "cluster \(p.clusterId) is not open"))
            }
            var answerID: Int?
            // Agent actions ("Done, retry") never reach answer memory or the profile.
            if p.saveToMemory && !p.saveToProfile && !cluster.isAction {
                answerID = world.read { $0.nextMemoryID }
                world.mutate { $0.nextMemoryID += 1 }
                let id = answerID!
                world.repository.update { data in
                    data.memoryAnswers.append(MemoryAnswerItem(id: id, canonicalQuestion: cluster.canonicalQuestion, answer: p.answer,
                                                               fieldType: cluster.fieldType, isTemplate: p.answer.contains("{company}"),
                                                               source: "user", updatedAt: Date()))
                }
            }
            if p.saveToProfile, !cluster.isAction, let key = cluster.neverGuessKey {
                world.repository.update { data in
                    data.neverGuess = (try? merge(data.neverGuess, patch: [key: .string(p.answer)])) ?? data.neverGuess
                }
            }
            let parkedApps: [Int] = world.repository.read { data in
                cluster.jobIds.compactMap { jid in data.jobs.first { $0.id == jid && $0.state == .needsYou }?.applicationID }
            }
            let resolvedAnswerID = answerID
            return Handled(reply: ack(["answer_id": answerID.map { .int($0) } ?? .null,
                                       "resumed_application_ids": .array(parkedApps.map { .int($0) })])) { world in
                world.resolveCluster(id: p.clusterId, status: .answered, answerID: resolvedAnswerID)
            }

        case .skipQuestion(let p):
            guard let cluster = world.cluster(id: p.clusterId) else {
                return Handled(reply: error(.notFound, "cluster \(p.clusterId) is not open"))
            }
            let apps = world.repository.read { data in cluster.jobIds.compactMap { jid in data.jobs.first { $0.id == jid }?.applicationID } }
            return Handled(reply: ack(["skipped_application_ids": .array(apps.map { .int($0) })])) { world in
                world.resolveCluster(id: p.clusterId, status: .skipped)
            }

        case .approve(let p):
            for id in p.applicationIds {
                let state = world.repository.read { $0.jobs.first { $0.applicationID == id }?.state }
                guard let state else { return Handled(reply: error(.notFound, "application \(id) not found", applicationID: id)) }
                guard state == .awaitingReview else {
                    return Handled(reply: .error(ErrorPayload(code: .illegalTransition, message: "application \(id) is not awaiting review",
                                                              details: ["state": .string(state.rawValue)], applicationId: id)))
                }
            }
            if world.isPaused { return Handled(reply: error(.paused, "Agent is paused")) }
            return Handled(reply: ack(["application_ids": .array(p.applicationIds.map { .int($0) })])) { world in
                for id in p.applicationIds {
                    world.transition(applicationID: id, to: .submitting, actor: .user)
                }
                for id in p.applicationIds {
                    await world.sleep(1.2)
                    world.transition(applicationID: id, to: .submitted)
                }
            }

        case .reject(let p):
            let state = world.repository.read { $0.jobs.first { $0.applicationID == p.applicationId }?.state }
            guard state == .awaitingReview else {
                return Handled(reply: error(.illegalTransition, "application \(p.applicationId) is not awaiting review", applicationID: p.applicationId))
            }
            return Handled(reply: ack()) { $0.transition(applicationID: p.applicationId, to: .skipped, reason: p.reason, actor: .user) }

        case .setStatus(let p):
            let previous: (BoardStatus?, Int)? = world.repository.update { data in
                guard let i = data.jobIndex(applicationID: p.applicationId), data.jobs[i].state == .submitted else { return nil }
                let prev = data.jobs[i].status
                data.jobs[i].status = p.status
                data.jobs[i].statusUpdatedAt = Date()
                data.log("status", "moved to \(p.status.label)", actor: .user, jobID: data.jobs[i].id, applicationID: p.applicationId)
                return (prev, data.jobs[i].id)
            }
            guard let previous else {
                return Handled(reply: error(.illegalTransition, "application \(p.applicationId) is not submitted", applicationID: p.applicationId))
            }
            return Handled(reply: ack()) { world in
                world.emit(.applicationStatus(ApplicationStatusPayload(applicationId: p.applicationId, jobId: previous.1,
                                                                       previousStatus: previous.0, status: p.status, actor: .user, at: Date())))
            }

        case .updatePreferences(let p):
            do {
                let current = world.read { $0.preferences }
                let merged = try merge(current, patch: p.preferences.values)
                world.mutate { $0.preferences = merged }
                return Handled(reply: ack(["preferences": try JSONValue.encode(merged)]))
            } catch {
                return Handled(reply: Self.error(.invalidPayload, "invalid preferences: \(error)"))
            }

        case .updateNeverGuess(let p):
            do {
                let current = world.repository.read { $0.neverGuess }
                let merged = try merge(current, patch: p.values.values)
                world.repository.update { $0.neverGuess = merged }
                return Handled(reply: ack(["never_guess": try JSONValue.encode(merged)]))
            } catch {
                return Handled(reply: Self.error(.invalidPayload, "invalid never-guess values: \(error)"))
            }

        case .updateProfile(let p):
            do {
                let current = world.repository.read { $0.profile }
                var merged = try merge(current, patch: p.profile.values)
                merged.updatedAt = Date()
                let updated = merged
                world.repository.update { $0.profile = updated }
                return Handled(reply: ack(["profile": try JSONValue.encode(updated)]))
            } catch {
                return Handled(reply: Self.error(.invalidPayload, "invalid profile: \(error)"))
            }

        case .addResumeVariant(let p):
            let id = addResume(world: world, label: p.label, path: p.filePath, tags: p.tags, isDefault: p.isDefault)
            return Handled(reply: ack(["resume_variant_id": .int(id)]))

        case .updateResumeVariant(let p):
            let found = world.repository.update { data -> Bool in
                guard let i = data.resumeVariants.firstIndex(where: { $0.id == p.id }) else { return false }
                if let l = p.label { data.resumeVariants[i].label = l }
                if let t = p.tags { data.resumeVariants[i].tags = t }
                if let e = p.enabled { data.resumeVariants[i].enabled = e }
                if p.isDefault == true {
                    for j in data.resumeVariants.indices { data.resumeVariants[j].isDefault = false }
                    data.resumeVariants[i].isDefault = true
                }
                data.resumeVariants[i].updatedAt = Date()
                return true
            }
            return Handled(reply: found ? ack() : error(.notFound, "resume variant \(p.id) not found"))

        case .upsertStory(let p):
            let id: Int = world.repository.update { data in
                let story = StoryItem(id: p.id ?? 0, title: p.title, situation: p.situation, task: p.task, action: p.action,
                                      result: p.result, tags: p.tags, updatedAt: Date())
                if let existing = p.id, let i = data.stories.firstIndex(where: { $0.id == existing }) {
                    var s = story
                    s.uses = data.stories[i].uses
                    data.stories[i] = s
                    return existing
                }
                var s = story
                s.id = (data.stories.map(\.id).max() ?? 0) + 1
                data.stories.append(s)
                return s.id
            }
            return Handled(reply: ack(["story_id": .int(id)]))

        case .deleteStory(let p):
            world.repository.update { $0.stories.removeAll { $0.id == p.id } }
            return Handled(reply: ack())

        case .updateAnswer(let p):
            let found = world.repository.update { data -> Bool in
                guard let i = data.memoryAnswers.firstIndex(where: { $0.id == p.answerId }) else { return false }
                data.memoryAnswers[i].answer = p.answer
                if let q = p.canonicalQuestion { data.memoryAnswers[i].canonicalQuestion = q }
                data.memoryAnswers[i].updatedAt = Date()
                return true
            }
            return Handled(reply: found ? ack() : error(.notFound, "answer \(p.answerId) not found"))

        case .deleteAnswer(let p):
            world.repository.update { $0.memoryAnswers.removeAll { $0.id == p.answerId } }
            return Handled(reply: ack())

        case .editApplicationAnswer(let p):
            let found = world.repository.update { data -> Bool in
                for (app, answers) in data.applicationAnswers {
                    if let i = answers.firstIndex(where: { $0.id == p.applicationAnswerId }) {
                        data.applicationAnswers[app]?[i].answer = p.answer
                        data.applicationAnswers[app]?[i].origin = .user
                        data.applicationAnswers[app]?[i].confidence = 1
                        return true
                    }
                }
                return false
            }
            return Handled(reply: found ? ack() : error(.notFound, "application answer \(p.applicationAnswerId) not found"))

        case .setJobMode(let p):
            world.repository.update { data in
                if let i = data.jobIndex(jobID: p.jobId) { data.jobs[i].modeOverride = p.mode }
            }
            return Handled(reply: ack())

        case .retryApplication(let p):
            let state = world.repository.read { $0.jobs.first { $0.applicationID == p.applicationId }?.state }
            guard state == .failed else {
                return Handled(reply: error(.illegalTransition, "application \(p.applicationId) is not failed", applicationID: p.applicationId))
            }
            return Handled(reply: ack()) { $0.transition(applicationID: p.applicationId, to: .queued, reason: "retry", actor: .user) }

        case .applyAnyway(let p):
            let state = world.repository.read { $0.jobs.first { $0.applicationID == p.applicationId }?.state }
            guard state == .skipped else {
                return Handled(reply: error(.illegalTransition, "application \(p.applicationId) is not skipped", applicationID: p.applicationId))
            }
            return Handled(reply: ack()) { $0.transition(applicationID: p.applicationId, to: .queued, reason: "user_apply_anyway", actor: .user) }

        case .queueApplication(let p):
            let job = world.repository.read { $0.jobs.first { $0.applicationID == p.applicationId } }
            guard let job, BoardRules.canQueue(job) else {
                return Handled(reply: error(.conflict, "application \(p.applicationId) can't be queued", applicationID: p.applicationId))
            }
            struct Reply: Encodable { var state = "queued"; var started: Bool }
            return Handled(reply: ack(encoding: Reply(started: p.applyNow))) {
                $0.transition(applicationID: p.applicationId, to: .queued, reason: "user_queued", actor: .user)
            }

        case .markApplied(let p):
            let ok: Bool = world.repository.update { data in
                guard let i = data.jobIndex(applicationID: p.applicationId), BoardRules.canMarkApplied(data.jobs[i]) else { return false }
                let now = Date()
                data.jobs[i].state = .submitted
                data.jobs[i].mode = .manual
                data.jobs[i].stateReason = "user_applied"
                data.jobs[i].submittedAt = now
                data.jobs[i].status = p.status
                data.jobs[i].statusUpdatedAt = now
                data.log("state", "marked as applied by you", actor: .user, jobID: data.jobs[i].id, applicationID: p.applicationId)
                return true
            }
            guard ok else {
                return Handled(reply: error(.conflict, "application \(p.applicationId) can't be marked applied", applicationID: p.applicationId))
            }
            struct Reply: Encodable { var applicationId: Int; var status: String
                enum CodingKeys: String, CodingKey { case applicationId = "application_id", status } }
            return Handled(reply: ack(encoding: Reply(applicationId: p.applicationId, status: p.status.rawValue)))

        case .addJobUrl(let p):
            if let problem = AddJobLink.problem(p.url) { return Handled(reply: error(.invalidPayload, problem)) }
            let url = AddJobLink.url(p.url)?.absoluteString ?? p.url
            if let existing = world.repository.read({ $0.jobs.first { $0.applyURL == url } }) {
                return Handled(reply: ack(["job_id": .int(existing.id), "application_id": .int(existing.applicationID ?? existing.id),
                                           "created": .bool(false), "state": .string(existing.state.rawValue),
                                           "title": .string(existing.title), "company": .string(existing.company), "started": .bool(false)]))
            }
            let id = world.nextJobID()
            let host = AddJobLink.url(p.url)?.host() ?? "example.com"
            let company = p.company ?? host.split(separator: ".").first.map { $0.capitalized } ?? "Company"
            let title = p.title ?? "Software Engineer"
            let job = JobItem(id: id, applicationID: id, companyID: id, company: company, title: title, location: nil, remote: nil,
                              source: .manual, ats: .other, applyURL: url, sourceURL: url, discoveredAt: Date())
            return Handled(reply: ack(["job_id": .int(id), "application_id": .int(id), "created": .bool(true), "state": .string("queued"),
                                       "title": .string(title), "company": .string(company), "started": .bool(false)])) { world in
                world.discover(job)
                _ = world.transition(applicationID: id, to: .scored, reason: "user_added_link", actor: .user)
                _ = world.transition(applicationID: id, to: .queued, reason: "user_added_link", actor: .user)
            }

        case .updateJobNotes(let p):
            let found: Bool = world.repository.update { data in
                guard let i = data.jobIndex(jobID: p.jobId) else { return false }
                let trimmed = p.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                data.jobs[i].notes = trimmed.isEmpty ? nil : trimmed
                return true
            }
            return Handled(reply: found ? ack() : error(.notFound, "job \(p.jobId) not found"))

        case .setApplicationResume(let p):
            let state = world.repository.read { $0.jobs.first { $0.applicationID == p.applicationId }?.state }
            guard let state else { return Handled(reply: error(.notFound, "application \(p.applicationId) not found", applicationID: p.applicationId)) }
            let swappable: Set<AppState> = [.discovered, .scored, .queued, .needsYou, .awaitingReview, .failed, .skipped]
            guard swappable.contains(state) else {
                return Handled(reply: error(.conflict, "cannot change the resume while the application is \(state.rawValue)", applicationID: p.applicationId))
            }
            world.repository.update { data in
                if let i = data.jobIndex(applicationID: p.applicationId) { data.jobs[i].resumeVariantID = p.resumeVariantId }
            }
            let requeue = state == .awaitingReview
            return Handled(reply: ack(["requeued": .bool(requeue)])) { world in
                if requeue { world.transition(applicationID: p.applicationId, to: .queued, reason: "resume_swapped") }
            }

        case .resolveUnknown(let p):
            let state = world.repository.read { $0.jobs.first { $0.applicationID == p.applicationId }?.state }
            guard state == .unknownVerify else {
                return Handled(reply: error(.illegalTransition, "application \(p.applicationId) is not awaiting verification", applicationID: p.applicationId))
            }
            return Handled(reply: ack()) { $0.transition(applicationID: p.applicationId, to: p.submitted ? .submitted : .failed, actor: .user) }

        case .markEasyApplyDone(let p):
            let appID: Int? = world.repository.update { data in
                guard let i = data.jobIndex(jobID: p.jobId) else { return nil }
                let now = Date()
                data.jobs[i].state = .submitted
                data.jobs[i].mode = .manual
                data.jobs[i].stateReason = "manual_easy_apply"
                data.jobs[i].submittedAt = now
                data.jobs[i].status = .applied
                data.jobs[i].statusUpdatedAt = now
                if let e = data.easyApply.firstIndex(where: { $0.jobID == p.jobId }) {
                    data.easyApply[e].done = true
                    data.easyApply[e].doneAt = now
                }
                data.log("user", "applied manually via LinkedIn Easy Apply", actor: .user, jobID: p.jobId, applicationID: data.jobs[i].applicationID)
                return data.jobs[i].applicationID
            }
            guard let appID else { return Handled(reply: error(.notFound, "job \(p.jobId) not found", jobID: p.jobId)) }
            return Handled(reply: ack(["application_id": .int(appID)]))

        case .markEasyApplyOpened(let p):
            world.repository.update { data in
                if let e = data.easyApply.firstIndex(where: { $0.jobID == p.jobId }) { data.easyApply[e].opened = true }
            }
            return Handled(reply: ack())

        case .dismissEasyApply(let p):
            world.repository.update { data in
                if let e = data.easyApply.firstIndex(where: { $0.jobID == p.jobId }) { data.easyApply[e].dismissed = true }
            }
            return Handled(reply: ack())

        case .acceptCompanySuggestion(let p):
            let name: String? = world.repository.update { data in
                guard let i = data.companySuggestions.firstIndex(where: { $0.id == p.suggestionId }) else { return nil }
                data.companySuggestions[i].status = .accepted
                data.log("user", "added \(data.companySuggestions[i].companyName) to the watched companies", actor: .user)
                return data.companySuggestions[i].companyName
            }
            guard name != nil else { return Handled(reply: error(.notFound, "company suggestion \(p.suggestionId) not found")) }
            return Handled(reply: ack(["company_id": .int(1000 + p.suggestionId)]))

        case .dismissCompanySuggestion(let p):
            let found: Bool = world.repository.update { data in
                guard let i = data.companySuggestions.firstIndex(where: { $0.id == p.suggestionId }) else { return false }
                data.companySuggestions[i].status = .dismissed
                return true
            }
            guard found else { return Handled(reply: error(.notFound, "company suggestion \(p.suggestionId) not found")) }
            return Handled(reply: ack())

        case .openAgentChrome:
            return Handled(reply: ack())

        case .onboardingSystemCheck:
            await world.sleep(0.6)
            let result = SystemCheckResult(items: [
                SystemCheckItem(name: .claudeCli, ok: true, required: true, version: "2.4.1", detail: "logged in"),
                SystemCheckItem(name: .uv, ok: true, required: true, version: "0.6.2", detail: "/opt/homebrew/bin/uv"),
                SystemCheckItem(name: .node, ok: true, required: true, version: "v22.11.0", detail: "/opt/homebrew/bin/node"),
                SystemCheckItem(name: .autoapplyd, ok: true, required: true, version: "0.1.0-mock", detail: "LaunchAgent loaded"),
                SystemCheckItem(name: .chrome, ok: true, required: false, version: "142.0", detail: "Google Chrome"),
            ], allRequiredOk: true)
            return Handled(reply: ack(encoding: result))

        case .onboardingParseResume(let p):
            await world.sleep(1.4)
            let label = p.label ?? URL(fileURLWithPath: p.filePath).deletingPathExtension().lastPathComponent
            let id = addResume(world: world, label: label, path: p.filePath, tags: [], isDefault: false)
            let profile = MockFixtures.profile
            world.repository.update { $0.profile = profile }
            return Handled(reply: ack(encoding: ParseResumeResult(resumeVariantId: id, profile: profile, uncertainFields: ["phone", "years_experience"],
                                                                  suggestedPreferences: Self.mockSuggestion)))

        case .suggestPreferences:
            return Handled(reply: ack(encoding: Self.mockSuggestion))

        case .onboardingConnectSource(let p):
            let source: SourceName = p.source == .linkedin ? .linkedin : .glassdoor
            return Handled(reply: ack()) { world in
                world.setSource(source, connected: false, detail: "Waiting for you to log in in Chrome…")
                await world.sleep(2.5)
                world.setSource(source, connected: true, detail: "Connected")
            }

        case .resetSourceCap:
            return Handled(reply: ack())

        case .setMailAccount(let p):
            return Handled(reply: ack(encoding: AppStore.MailAccountStatus(email: p.email, connected: true, error: nil)))
        case .getMailAccount:
            return Handled(reply: ack(encoding: AppStore.MailAccountStatus(email: nil, connected: false, error: nil)))
        case .clearMailAccount:
            return Handled(reply: ack(encoding: AppStore.MailAccountStatus(email: nil, connected: false, error: nil)))
        case .listSiteAccounts:
            return Handled(reply: ack(encoding: AppStore.SiteAccountList(accounts: [
                AppStore.SiteAccount(host: "acme.wd5.myworkdayjobs.com", email: "jane@gmail.com", company: "Acme", status: "active",
                                     createdAt: "2026-10-20T10:00:00Z", updatedAt: "2026-10-20T10:01:00Z"),
            ], enabled: true)))
        case .revealSiteAccountPassword:
            struct Reply: Encodable { var host = "acme.wd5.myworkdayjobs.com"; var password = "mock-Pa55word!" }
            return Handled(reply: ack(encoding: Reply()))
        case .deleteSiteAccount:
            return Handled(reply: ack())

        case .checkSourceLogin(let p):
            let source: SourceName = p.source == .linkedin ? .linkedin : .glassdoor
            return Handled(reply: ack()) { world in
                await world.sleep(1.0)
                world.setSource(source, connected: true, detail: "Connected")
            }

        case .onboardingSetStep(let p):
            world.mutate { $0.onboarding.step = p.step }
            return Handled(reply: ack())

        case .onboardingComplete(let p):
            world.mutate { $0.onboarding.completed = true; $0.onboarding.step = 7 }
            if p.runPrep {
                return Handled(reply: ack(["run_id": .string("mockrun-prep")])) { world in await MockScripts.miniRun(world, kind: .prep) }
            }
            return Handled(reply: ack(["run_id": .null]))
        }
    }

    private static func addResume(world: MockWorld, label: String, path: String, tags: [String], isDefault: Bool) -> Int {
        let id: Int = world.read { $0.nextResumeID }
        world.mutate { $0.nextResumeID += 1 }
        world.repository.update { data in
            if isDefault || data.resumeVariants.isEmpty {
                for j in data.resumeVariants.indices { data.resumeVariants[j].isDefault = false }
            }
            data.resumeVariants.append(ResumeVariantItem(id: id, label: label, filePath: path, tags: tags,
                                                         isDefault: isDefault || data.resumeVariants.isEmpty,
                                                         createdAt: Date(), updatedAt: Date()))
        }
        return id
    }

    static let mockSuggestion = SuggestedPreferences(roles: ["AI Engineer", "ML Engineer", "Backend Engineer"],
                                                     seniority: [.junior, .mid], locations: ["Bengaluru", "India"], yearsExperience: 2.3)
}
