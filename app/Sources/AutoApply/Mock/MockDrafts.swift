// MockDrafts.swift — the daemon's `draft_answer` (contract/protocol.md §5.5) against the mock
// world, so "Draft with AI" works in mock mode, previews and tests. Like the real agent it refuses
// tasks, never-guess / always-ask facts and choice questions, writes only from the profile, the
// stories and the job, treats facts in the user's instructions as theirs, and names anything it
// can't back ("add a metric" makes it invent one, which is then flagged). Nothing is answered.
import Foundation

enum MockDrafts {
    typealias Handled = MockCommandHandler.Handled

    static func handle(_ p: DraftAnswerPayload, world: MockWorld) -> Handled {
        guard let cluster = world.cluster(id: p.clusterId) else {
            return Handled(reply: MockCommandHandler.error(.notFound, "open cluster \(p.clusterId) not found"))
        }
        if let refusal = refusal(for: cluster) {
            return Handled(reply: .error(ErrorPayload(code: .invalidPayload, message: refusal.message,
                                                      details: ["reason": .string(refusal.reason)])))
        }
        if let jobID = p.jobId, !cluster.jobIds.contains(jobID) {
            return Handled(reply: MockCommandHandler.error(.invalidPayload, "job \(jobID) is not waiting on this question"))
        }
        let jobID = p.jobId ?? cluster.jobIds.first
        let (profile, stories, job) = world.repository.read { d in
            (d.profile, d.stories, jobID.flatMap { id in d.jobs.first { $0.id == id } })
        }
        let template = p.jobId == nil && Set(cluster.companies).count > 1
        let result = draft(cluster: cluster, profile: profile, stories: stories, job: job, template: template,
                           instructions: p.instructions, current: p.currentAnswer)
        return Handled(reply: MockCommandHandler.ack(encoding: result))
    }

    static func refusal(for cluster: QuestionCluster) -> (reason: String, message: String)? {
        if cluster.isAction { return ("action", "This is a task for you to do in the agent's Chrome, not a question to answer.") }
        if cluster.reason == .alwaysAsk { return ("always_ask", "You asked to always answer this one yourself, so the agent won't draft it.") }
        if cluster.neverGuessKey != nil || cluster.reason == .neverGuess {
            return ("never_guess", "The agent never guesses this (work authorisation, sponsorship, salary, notice period and "
                    + "similar facts). Only you can answer it; you can also save the answer to your profile.")
        }
        if !cluster.options.isEmpty || cluster.fieldType == .boolean {
            return ("no_option", "Your profile doesn't settle this one, so the agent won't pick an option for you.")
        }
        return nil
    }

    static func draft(cluster: QuestionCluster, profile: Profile, stories: [StoryItem], job: JobItem?, template: Bool,
                      instructions: String?, current: String?) -> DraftAnswerResult {
        let instruction = instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let currentText = current?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let story = StorySuggester.rank(question: cluster.canonicalQuestion, stories: stories, limit: 1).first ?? stories.first
        var answer: String
        var unsupported: [String] = []
        if let instruction, let currentText {
            (answer, unsupported) = revise(currentText, instruction: instruction)
        } else {
            answer = firstDraft(profile: profile, story: story, job: job, template: template)
            if let instruction { (answer, unsupported) = revise(answer, instruction: instruction) }
        }
        var sources = ["Profile"]
        if !(profile.rawText ?? "").isEmpty { sources.append("Resume") }
        if let story, currentText == nil { sources.append("Story: \(story.title)") }
        if let job { sources.append("Job: \(job.title) at \(job.company)") }
        if instruction != nil { sources.append("Your instructions") }
        return DraftAnswerResult(clusterId: cluster.clusterId, jobId: job?.id, answer: answer, grounded: unsupported.isEmpty,
                                 unsupportedClaims: unsupported, sources: sources,
                                 tokensIn: 1_400 + (currentText?.count ?? 0) / 4, tokensOut: max(1, answer.count / 4))
    }

    private static func firstDraft(profile: Profile, story: StoryItem?, job: JobItem?, template: Bool) -> String {
        var parts: [String] = []
        if let role = profile.workHistory.first {
            parts.append("I work as \(role.title) at \(role.company).")
        } else if let headline = profile.headline, !headline.isEmpty {
            parts.append("I'm a \(headline).")
        }
        if let story {
            let snippet = StorySuggester.snippet(story)
            if !snippet.isEmpty { parts.append(snippet) }
        }
        if template {
            parts.append("That's the kind of work I want to keep doing as {role} at {company}.")
        } else if let job {
            parts.append("That's the kind of work I want to keep doing as \(job.title) at \(job.company).")
        }
        return parts.isEmpty ? "I'd be glad to talk this through." : parts.joined(separator: " ")
    }

    /// "make it shorter" keeps the first two sentences; "more casual" / "more formal" swap
    /// contractions; "mention X" adds X (the user's own fact); "add a metric" invents one, which
    /// the fact check then flags.
    private static func revise(_ text: String, instruction: String) -> (String, [String]) {
        let lower = instruction.lowercased()
        var out = text
        var unsupported: [String] = []
        if lower.contains("short") || lower.contains("concise") || lower.contains("trim") {
            let sentences = out.split(separator: ".", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            out = sentences.prefix(2).joined(separator: ". ") + "."
        }
        if lower.contains("casual") || lower.contains("friendl") {
            for (a, b) in [("I am ", "I'm "), ("I have ", "I've "), ("do not ", "don't "), ("I would ", "I'd ")] {
                out = out.replacingOccurrences(of: a, with: b)
            }
        }
        if lower.contains("formal") {
            for (a, b) in [("I'm ", "I am "), ("I've ", "I have "), ("don't ", "do not "), ("I'd ", "I would "), ("That's ", "That is ")] {
                out = out.replacingOccurrences(of: a, with: b)
            }
        }
        if let range = lower.range(of: "mention ") {
            let topic = instruction[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
                .replacingOccurrences(of: "my ", with: "")
            if !topic.isEmpty { out += " I've also worked on \(topic)." }
        }
        if lower.contains("metric") || lower.contains("number") {
            out += " That cut costs by 30%."
            unsupported.append("30%")
        }
        return (out, unsupported)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
