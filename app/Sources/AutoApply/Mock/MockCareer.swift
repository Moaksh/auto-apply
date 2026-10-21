// MockCareer.swift — the daemon's career-helper commands against the mock world
// (contract/protocol.md §5.1.1, §5.1.2, §5.3, §5.4), so What's working, Job detail ▸ Interview
// prep, the LinkedIn import and Settings ▸ Writing voice show realistic data in mock mode,
// previews and tests. Like the real daemon: insights are computed from the user's own rows and
// change nothing; packs are only built from the job, stored company data and the story bank (a
// behavioural question without a fitting story gets a gap, never an invented story); a thank-you
// draft with a placeholder is not grounded; nothing is ever sent; LinkedIn is never opened.
import Foundation

enum MockCareer {
    struct State: Sendable {
        var packs: [Int: InterviewPrepPack] = [:]
        var voice = VoiceProfile()
        var insightsSummary: String?
    }

    typealias Handled = MockCommandHandler.Handled

    static func handle(_ command: Command, world: MockWorld) -> Handled {
        switch command {
        case .getInsights(let p):
            var summary = world.read { $0.career.insightsSummary }
            var tokens = (0, 0)
            if p.summarize {
                summary = "Kubernetes and Terraform keep showing up in infrastructure roles you were skipped for. Worth a look only if you want to move toward platform work."
                tokens = (1_840, 96)
                world.mutate { $0.career.insightsSummary = summary }
            }
            var insights = world.repository.read { insights(from: $0, threshold: world.read { $0.preferences.matchThreshold }) }
            insights.upskill.summary = summary
            insights.cached = !p.force && !p.summarize
            insights.tokensIn = tokens.0
            insights.tokensOut = tokens.1
            return Handled(reply: MockCommandHandler.ack(encoding: insights))

        case .getInterviewPrep(let p):
            if let pack = world.read({ $0.career.packs[p.applicationId] }) {
                return Handled(reply: MockCommandHandler.ack(encoding: pack))
            }
            // The daemon writes a pack in the background when a card moves to Interview / Assessment.
            guard let job = world.repository.read({ d in d.jobIndex(applicationID: p.applicationId).map { d.jobs[$0] } }) else {
                return Handled(reply: MockCommandHandler.error(.notFound, "application \(p.applicationId) not found"))
            }
            if job.state == .submitted, job.status == .interview || job.status == .assessment {
                let pack = world.repository.read { pack(for: job, data: $0, trigger: .statusChange) }
                world.mutate { $0.career.packs[p.applicationId] = pack }
                return Handled(reply: MockCommandHandler.ack(encoding: pack))
            }
            return Handled(reply: MockCommandHandler.ack())

        case .generateInterviewPrep(let p):
            if !p.force, let pack = world.read({ $0.career.packs[p.applicationId] }) {
                return Handled(reply: MockCommandHandler.ack(encoding: pack))
            }
            guard let job = world.repository.read({ d in d.jobIndex(applicationID: p.applicationId).map { d.jobs[$0] } }) else {
                return Handled(reply: MockCommandHandler.error(.notFound, "application \(p.applicationId) not found"))
            }
            let pack = world.repository.read { pack(for: job, data: $0, trigger: .user) }
            world.mutate { $0.career.packs[p.applicationId] = pack }
            return Handled(reply: MockCommandHandler.ack(encoding: pack))

        case .interviewDebrief(let p):
            let notes = p.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else {
                return Handled(reply: MockCommandHandler.error(.invalidPayload, "notes must not be blank"))
            }
            guard let job = world.repository.read({ d in d.jobIndex(applicationID: p.applicationId).map { d.jobs[$0] } }) else {
                return Handled(reply: MockCommandHandler.error(.notFound, "application \(p.applicationId) not found"))
            }
            let name = world.repository.read { $0.profile.firstName ?? "Me" }
            return Handled(reply: MockCommandHandler.ack(encoding: debrief(notes: notes, job: job, applicationID: p.applicationId, signer: name)))

        case .importLinkedinConnections(let p):
            return importConnections(path: p.filePath, world: world)

        case .getVoiceProfile:
            return Handled(reply: MockCommandHandler.ack(encoding: world.read { $0.career.voice }))

        case .updateVoiceProfile(let p):
            var profile = world.read { $0.career.voice }
            let defaults = VoiceProfile()
            if let v = p.signOff {
                let trimmed = v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ","))
                profile.signOff = trimmed.isEmpty ? defaults.signOff : trimmed
            }
            if let v = p.formality { profile.formality = v }
            if let v = p.maxWords { profile.maxWords = v }
            if let v = p.avoidPhrases {
                var seen = Set<String>()
                profile.avoidPhrases = v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            if let v = p.writingSample {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                profile.writingSample = trimmed.isEmpty ? nil : trimmed
            }
            if profile.signOff.count > 40 || !(60...600).contains(profile.maxWords) || profile.avoidPhrases.count > 20
                || profile.avoidPhrases.contains(where: { $0.count > 80 }) || (profile.writingSample ?? "").count > 1500 {
                return Handled(reply: MockCommandHandler.error(.invalidPayload, "voice profile value out of range"))
            }
            world.mutate { $0.career.voice = profile }
            return Handled(reply: MockCommandHandler.ack(encoding: profile))

        default:
            return Handled(reply: MockCommandHandler.ack())
        }
    }

    // MARK: Score evidence fixtures

    /// Requirement evidence on most scored jobs (every fifth keeps the older shape, without it),
    /// with a dealbreaker quoted from the job and an occasional dropped quote. Deterministic.
    static func seedScoreEvidence(_ data: inout RepositoryData) {
        for i in data.jobs.indices {
            let job = data.jobs[i]
            guard let score = job.score, job.id % 5 != 0 else { continue }
            data.jobs[i].scoreRequirements = requirements(title: job.title, score: score, seed: job.id)
            if job.id % 7 == 0 { data.jobs[i].scoreGrounding = ScoreGrounding(evidenceDropped: 1) }
        }
    }

    static func requirements(title: String, score: Int, seed: Int) -> [RequirementEvidence] {
        var pool: [(String, String)] = [
            ("5+ years building backend services", "Five years building payment rails and high-throughput Go services."),
            ("Go or another systems language", "go"),
            ("Distributed systems at scale", "Scaled ledger service to 12k TPS"),
            ("Event-driven architecture (Kafka)", "Led migration to event sourcing"),
        ]
        if title.contains("ML") { pool.append(("Production ML model serving", "")) }
        if title.contains("Infra") || title.contains("Platform") || title.contains("Reliability") {
            pool.append(("Terraform and infrastructure as code", ""))
        } else {
            pool.append(("Payments or fintech domain", "Backend engineer · payments & distributed systems"))
        }
        var out: [RequirementEvidence] = []
        for (n, (req, quote)) in pool.enumerated() {
            // Lower scores lose evidence from the bottom of the list first.
            let keep = score >= 85 ? 5 : (score >= 70 ? 4 : 2)
            let status: RequirementEvidence.Status = quote.isEmpty ? .missing : (n < keep ? .met : .partial)
            out.append(RequirementEvidence(index: n, requirement: req, status: status, evidence: status == .missing ? "" : quote,
                                           confidence: status == .met ? .high : .medium, dealbreaker: false, jdQuote: nil))
        }
        if seed % 3 == 0 {
            out.append(RequirementEvidence(index: out.count, requirement: "On-call rotation", status: .partial,
                                           evidence: "", confidence: .low, dealbreaker: true,
                                           jdQuote: "You must be able to join our weekly on-call rotation."))
        }
        return out
    }

    // MARK: Insights

    static func insights(from data: RepositoryData, threshold: Int, now: Date = Date()) -> Insights {
        let submitted = data.jobs.filter { $0.state == .submitted }
        func responded(_ j: JobItem) -> Bool { [.assessment, .interview, .offer, .rejected].contains(j.status ?? .applied) }
        func interviewed(_ j: JobItem) -> Bool { [.assessment, .interview, .offer].contains(j.status ?? .applied) }
        let inFlight = submitted.filter { !responded($0) && ($0.submittedAt.map { now.timeIntervalSince($0) < 14 * 86_400 } ?? false) }
        let counted = submitted.filter { j in !inFlight.contains { $0.id == j.id } }
        let ranges: [(String, Int, Int)] = [("<60", 0, 59), ("60–69", 60, 69), ("70–79", 70, 79), ("80–89", 80, 89), ("90+", 90, 100)]
        let bands = ranges.map { label, lo, hi -> ScoreBand in
            let jobs = counted.filter { ($0.score ?? -1) >= lo && ($0.score ?? -1) <= hi }
            let n = jobs.count, r = jobs.filter(responded).count, iv = jobs.filter(interviewed).count
            let enough = n >= 8
            return ScoreBand(label: label, minScore: lo, maxScore: hi, applications: n, responses: r, interviews: iv,
                             responseRate: enough ? Double(r) / Double(n) : nil, interviewRate: enough ? Double(iv) / Double(n) : nil,
                             enoughData: enough)
        }
        let rated = bands.filter(\.enoughData)
        var verdict = ScoreCalibration.Verdict.insufficient
        var finding = "Not enough outcomes yet: a score range needs 8 applications with an answer before it's compared."
        if rated.count >= 2, let low = rated.first, let high = rated.last {
            let gap = Int((((high.responseRate ?? 0) - (low.responseRate ?? 0)) * 100).rounded())
            func pct(_ x: Double?) -> String { "\(Int(((x ?? 0) * 100).rounded()))%" }
            if gap >= 10 {
                verdict = .separating
                finding = "Your match score predicts replies: jobs scored \(high.label) heard back \(pct(high.responseRate)) of the time vs \(pct(low.responseRate)) for \(low.label). Trusting the score is paying off."
            } else if gap <= -10 {
                verdict = .inverted
                finding = "Lower-scored jobs are doing better: \(low.label) heard back \(pct(low.responseRate)) of the time vs \(pct(high.responseRate)) for \(high.label)."
            } else {
                verdict = .flat
                finding = "No clear difference yet: \(high.label) heard back \(pct(high.responseRate)) of the time vs \(pct(low.responseRate)) for \(low.label). This usually sharpens with more outcomes."
            }
        }
        let calibration = ScoreCalibration(bands: bands, minBandSample: 8, matchThreshold: threshold, resolved: counted.count,
                                           inFlight: inFlight.count, unscored: submitted.filter { $0.score == nil }.count,
                                           verdict: verdict, finding: finding)

        let skipped = data.jobs.filter { $0.state == .skipped && $0.discoveredAt > now.addingTimeInterval(-30 * 86_400) }
            .sorted { $0.discoveredAt > $1.discoveredAt }
        var reasonCounts: [String: [JobItem]] = [:]
        for j in skipped { reasonCounts[j.stateReason ?? j.skipReason ?? "other", default: []].append(j) }
        let reasons = reasonCounts.map { reason, jobs in
            SkipReasonCount(reason: reason, label: skipLabel(reason), count: jobs.count, examples: jobs.prefix(3).map(\.displayName))
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        var reqJobs: [String: [JobItem]] = [:]
        for j in skipped {
            for r in j.scoreRequirements ?? [] where r.status == .missing { reqJobs[r.requirement, default: []].append(j) }
        }
        let requirements = reqJobs.filter { $0.value.count >= 2 }.map { label, jobs in
            RequirementBlocker(label: label, kind: label.contains("Terraform") || label.contains("ML") ? .skill : .requirement,
                               count: jobs.count, wordings: [label.lowercased()], examples: jobs.prefix(3).map(\.displayName))
        }
        .sorted { $0.count > $1.count }

        let infra = skipped.filter { $0.title.contains("Infra") || $0.title.contains("Platform") || $0.title.contains("Reliability") }
        var hints: [UpskillHint] = []
        if infra.count >= 3 {
            hints.append(UpskillHint(skill: "Terraform", jobs: infra.count, skipped: infra.count, rejected: 0, examples: infra.prefix(3).map(\.displayName)))
        }
        let rejected = submitted.filter { $0.status == .rejected }
        if rejected.count >= 3 {
            hints.append(UpskillHint(skill: "Rust", jobs: rejected.count, skipped: 0, rejected: rejected.count, examples: rejected.prefix(3).map(\.displayName)))
        }
        let upskill = UpskillHints(windowDays: 90, jobsConsidered: infra.count + rejected.count, minJobs: 3, hints: hints, summary: nil,
                                   note: "Learn it if it fits your direction; never claim a skill you don't have.")

        let variants = data.resumeVariants.compactMap { v -> VariantPerformance? in
            let jobs = counted.filter { $0.resumeVariantID == v.id }
            guard !jobs.isEmpty else { return nil }
            let r = jobs.filter(responded).count
            return VariantPerformance(resumeVariantId: v.id, label: v.label, applications: jobs.count, responses: r,
                                      interviews: jobs.filter(interviewed).count, responseRate: Double(r) / Double(jobs.count),
                                      lowSample: jobs.count < 10)
        }
        let ratedVariants = variants.filter { !$0.lowSample }.sorted { $0.responseRate > $1.responseRate }
        let variantFinding: String
        if ratedVariants.count >= 2, let best = ratedVariants.first, let worst = ratedVariants.last,
           best.responseRate - worst.responseRate >= 0.10 {
            variantFinding = "“\(best.label)” heard back \(Int((best.responseRate * 100).rounded()))% of the time vs \(Int((worst.responseRate * 100).rounded()))% for “\(worst.label)”."
        } else {
            variantFinding = "No resume stands out yet; compare again after more applications."
        }
        return Insights(computedAt: now, cached: false, calibration: calibration,
                        skipBlockers: SkipBlockers(windowDays: 30, skipped: skipped.count, reasons: Array(reasons.prefix(8)), requirements: requirements),
                        upskill: upskill, variants: VariantInsights(variants: variants, finding: variantFinding))
    }

    static func skipLabel(_ reason: String) -> String {
        switch reason {
        case "below_threshold": "Below your match threshold"
        case "company_cooldown": "Applied there recently"
        case "salary_floor": "Below your salary floor"
        case "location_mismatch": "Location doesn't fit"
        default:
            reason.hasPrefix("excluded_keyword:") ? "Excluded keyword: \(reason.dropFirst("excluded_keyword:".count))" : reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: Interview prep

    static func pack(for job: JobItem, data: RepositoryData, trigger: InterviewPrepPack.Trigger, now: Date = Date()) -> InterviewPrepPack {
        let stories = data.stories
        func story(_ tag: String) -> StoryItem? { stories.first { $0.tags.contains(tag) } }
        func behavioural(_ q: String, basis: String, tag: String, gap: String) -> InterviewQuestion {
            guard let s = story(tag) else { return InterviewQuestion(kind: .behavioural, question: q, basis: basis, storyGap: gap) }
            return InterviewQuestion(kind: .behavioural, question: q, basis: basis, storyId: s.id, storyTitle: s.title,
                                     star: StarOutline(situation: s.situation, task: s.task, action: s.action, result: s.result),
                                     starSource: .story)
        }
        let questions: [InterviewQuestion] = [
            behavioural("Tell us about a system you scaled under load.", basis: "The posting stresses high-throughput services.",
                        tag: "scale", gap: "Add a story about scaling a system: the load, what you changed and the result."),
            behavioural("Describe a time you led an incident.", basis: "On-call is part of the role.",
                        tag: "leadership", gap: "Add a story where you led during an outage."),
            behavioural("Tell us about a time you changed a team's mind with data.", basis: "The team values written design reviews.",
                        tag: "influence", gap: "Add a story where you persuaded others with evidence: what was decided and what changed."),
            InterviewQuestion(kind: .technical, question: "How would you make a payment write idempotent across retries?",
                              basis: "Payments reliability is the team's focus."),
            InterviewQuestion(kind: .technical, question: "Walk through partitioning a Kafka topic for ordered processing per account."),
            InterviewQuestion(kind: .role, question: "Why \(job.company), and why this team now?"),
        ]
        let replies = data.applicationReplies.filter { $0.applicationID == job.applicationID }
        var checklist: [ChecklistItem] = replies.prefix(2).map {
            ChecklistItem(text: "Re-read “\($0.subject ?? "their email")” from \($0.fromName ?? $0.fromEmail)", url: nil, source: .employerReply)
        }
        if let url = job.applyURL ?? job.sourceURL { checklist.append(ChecklistItem(text: "Re-read the job posting", url: url, source: .job)) }
        checklist.append(ChecklistItem(text: "Test your camera, microphone and the meeting link 10 minutes early", source: .general))
        checklist.append(ChecklistItem(text: "Have two questions ready for them", source: .general))
        let others = data.jobs.filter { $0.companyID == job.companyID && $0.id != job.id }.map(\.title)
        let brief = CompanyBrief(name: job.company, domain: job.companyDomain, careersUrl: job.companyDomain.map { "https://\($0)/careers" },
                                 summary: nil, summaryUrl: nil, otherRoles: Array(Set(others)).sorted().prefix(3).map { $0 })
        return InterviewPrepPack(
            applicationId: job.applicationID ?? 0, jobId: job.id, company: job.company, title: job.title, status: job.status,
            generatedAt: now, trigger: trigger, questions: questions,
            questionsToAsk: ["What does a great first 90 days look like on this team?",
                             "How does the team split on-call, and what was the last big incident?",
                             "What is the hardest open problem the team is working on right now?"],
            companyBrief: brief.domain == nil && brief.otherRoles.isEmpty ? nil : brief,
            checklist: checklist, unsupportedClaims: ["Led a team of 12 engineers"], rejectedStoryIds: [],
            tokensIn: 6_420, tokensOut: 1_310)
    }

    /// A placeholder ("[Name]") makes the thank-you draft ungrounded, like the real fact check.
    static func debrief(notes: String, job: JobItem, applicationID: Int, signer: String, now: Date = Date()) -> InterviewDebrief {
        let interviewer = interviewerName(in: notes)
        let greeting = interviewer.map { "Hi \($0)," } ?? "Hi [Name],"
        let body = """
        \(greeting)

        Thank you for taking the time to talk about the \(job.title) role today. I enjoyed our conversation and \
        I'm still thinking about the problems your team is working on.

        Best regards,
        \(signer)
        """
        let draft = ThankYouDraft(subject: "Thank you · \(job.title)", body: body, grounded: interviewer != nil,
                                  unsupportedClaims: interviewer == nil ? ["[Name]"] : [])
        let lower = notes.lowercased()
        var wentWell = ["You walked through a concrete example from your own work"]
        if lower.contains("kafka") || lower.contains("system design") { wentWell.append("The system design discussion went into real depth") }
        var gaps: [String] = []
        if lower.contains("stuck") || lower.contains("didn't know") || lower.contains("blank") { gaps.append("One question you didn't have an answer ready for") }
        return InterviewDebrief(applicationId: applicationID, createdAt: now, wentWell: wentWell, gaps: gaps,
                                followUps: ["Send a thank-you within 24 hours", "Note the questions they asked for next time"],
                                thankYou: draft, tokensIn: 2_100, tokensOut: 420)
    }

    /// "with Priya" / "spoke to Priya Raman" → "Priya".
    static func interviewerName(in notes: String) -> String? {
        let words = notes.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." }).map(String.init)
        for (i, w) in words.enumerated() where ["with", "to"].contains(w.lowercased()) && i + 1 < words.count {
            let next = words[i + 1]
            if let first = next.first, first.isUppercase, next.count > 1 { return next }
        }
        return nil
    }

    // MARK: Warm intros

    static func importConnections(path: String, world: MockWorld) -> Handled {
        guard FileManager.default.fileExists(atPath: path), let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Handled(reply: MockCommandHandler.error(.notFound, "no file at \(path)"))
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.firstIndex(where: { $0.lowercased().contains("first name") && $0.lowercased().contains("company") }) else {
            return Handled(reply: MockCommandHandler.error(.invalidPayload, "That doesn't look like LinkedIn's Connections.csv (no header row with First Name and Company)."))
        }
        let rows = lines[(header + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let companies: [String] = rows.compactMap { row in
            let cells = row.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            return cells.count > 4 ? cells[4] : nil
        }
        let now = Date()
        let result: LinkedInImportResult = world.repository.update { data in
            var matched: [Int: LinkedInImportResult.MatchedCompany] = [:]
            var created = 0
            var nextID = (data.outreach.referrals.map(\.id).max() ?? 0) + 1
            for (n, company) in companies.enumerated() {
                guard let job = data.jobs.first(where: { $0.state == .submitted && $0.company.caseInsensitiveCompare(company) == .orderedSame })
                else { continue }
                matched[job.companyID, default: .init(companyId: job.companyID, name: job.company, why: "You applied", connections: 0)].connections += 1
                data.outreach.referrals.append(ReferralItem(
                    id: nextID, companyID: job.companyID, company: job.company, jobID: job.id, jobTitle: job.title,
                    personName: "Connection \(n + 1)", basis: .user, basisDetail: "We're connected on LinkedIn.", state: .suggested,
                    stateUpdatedAt: now, createdAt: now))
                nextID += 1
                created += 1
            }
            return LinkedInImportResult(imported: rows.count, merged: 0, skipped: 0,
                                        matchedCompanies: matched.values.sorted { $0.connections > $1.connections },
                                        referralSuggestions: created)
        }
        return Handled(reply: MockCommandHandler.ack(encoding: result))
    }
}

extension LinkedInImportResult: Encodable {
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(imported, forKey: .imported)
        try c.encode(merged, forKey: .merged)
        try c.encode(skipped, forKey: .skipped)
        try c.encode(matchedCompanies, forKey: .matchedCompanies)
        try c.encode(referralSuggestions, forKey: .referralSuggestions)
    }
}

extension LinkedInImportResult.MatchedCompany: Encodable {
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(companyId, forKey: .companyId)
        try c.encode(name, forKey: .name)
        try c.encode(why, forKey: .why)
        try c.encode(connections, forKey: .connections)
    }
}
