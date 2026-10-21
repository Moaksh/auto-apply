// AppStore+Career.swift — commands for the career helpers built on the user's own data
// (contract/protocol.md §5.1.1, §5.1.2, §5.3, §5.4): the advisory insights report, interview
// prep packs and debriefs, the LinkedIn connections import and the writing voice. None of these
// change a setting by themselves or send anything.
import Foundation

/// `ack.result` of `import_linkedin_connections`.
struct LinkedInImportResult: Decodable, Equatable, Sendable {
    struct MatchedCompany: Decodable, Equatable, Sendable, Identifiable {
        var companyId: Int
        var name: String
        /// Why it matched ("You applied", "Watched company", "Prospect").
        var why: String
        var connections: Int
        var id: Int { companyId }

        enum CodingKeys: String, CodingKey { case companyId = "company_id", name, why, connections }

        init(companyId: Int, name: String, why: String, connections: Int) {
            self.companyId = companyId
            self.name = name
            self.why = why
            self.connections = connections
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            companyId = try c.decode(Int.self, forKey: .companyId)
            name = try c.decode(String.self, forKey: .name)
            why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
            connections = try c.decodeIfPresent(Int.self, forKey: .connections) ?? 0
        }
    }

    var imported: Int
    var merged: Int
    var skipped: Int
    var matchedCompanies: [MatchedCompany]
    var referralSuggestions: Int

    enum CodingKeys: String, CodingKey {
        case imported, merged, skipped, matchedCompanies = "matched_companies", referralSuggestions = "referral_suggestions"
    }

    init(imported: Int, merged: Int, skipped: Int, matchedCompanies: [MatchedCompany], referralSuggestions: Int) {
        self.imported = imported
        self.merged = merged
        self.skipped = skipped
        self.matchedCompanies = matchedCompanies
        self.referralSuggestions = referralSuggestions
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imported = try c.decodeIfPresent(Int.self, forKey: .imported) ?? 0
        merged = try c.decodeIfPresent(Int.self, forKey: .merged) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        matchedCompanies = try c.decodeIfPresent([MatchedCompany].self, forKey: .matchedCompanies) ?? []
        referralSuggestions = try c.decodeIfPresent(Int.self, forKey: .referralSuggestions) ?? 0
    }
}

extension AppStore {
    /// Model calls (prep packs, debriefs, the insights summary) can take a while.
    static let careerSlowTimeout: Duration = .seconds(120)

    // MARK: Insights (§5.3)

    /// The advisory report. `force` recomputes instead of using the 6-hour cache; `summarize`
    /// also asks the model for a short summary of the upskill hints (costs tokens).
    func fetchInsights(force: Bool = false, summarize: Bool = false) async -> Insights? {
        await performResult(.getInsights(GetInsightsPayload(force: force, summarize: summarize)), as: Insights.self,
                            timeout: summarize ? Self.careerSlowTimeout : .seconds(20), silent: true)
    }

    // MARK: Interview prep (§5.4)

    /// The stored pack: `.success(nil)` when none has been written yet. Never calls a model.
    func interviewPrep(applicationID: Int) async -> Result<InterviewPrepPack?, DaemonClientError> {
        switch await perform(.getInterviewPrep(GetInterviewPrepPayload(applicationId: applicationID)), timeout: .seconds(10), silent: true) {
        case .success(let reply):
            guard case .ack(let ack) = reply.event, let result = ack.result, !result.isEmpty else { return .success(nil) }
            do {
                return .success(try JSONValue.object(result).decode(InterviewPrepPack.self))
            } catch {
                return .failure(.decoding(String(describing: error)))
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Write (or with `force`, rewrite) the pack. One model call; grounded in your stories.
    func generateInterviewPrep(applicationID: Int, force: Bool) async -> InterviewPrepPack? {
        await performResult(.generateInterviewPrep(GenerateInterviewPrepPayload(applicationId: applicationID, force: force)),
                            as: InterviewPrepPack.self, timeout: Self.careerSlowTimeout, silent: true)
    }

    /// Turn the user's notes into a debrief and a thank-you draft (never sent).
    func interviewDebrief(applicationID: Int, notes: String) async -> InterviewDebrief? {
        await performResult(.interviewDebrief(InterviewDebriefPayload(applicationId: applicationID, notes: notes)),
                            as: InterviewDebrief.self, timeout: Self.careerSlowTimeout, silent: true)
    }

    // MARK: Warm intros (§5.1.1)

    /// Read the user's own LinkedIn export. The file stays on this Mac; LinkedIn is never opened.
    func importLinkedInConnections(filePath: String) async -> LinkedInImportResult? {
        await performResult(.importLinkedinConnections(ImportLinkedinConnectionsPayload(filePath: filePath)),
                            as: LinkedInImportResult.self, timeout: .seconds(60), silent: true)
    }

    // MARK: Writing voice (§5.1.2)

    func voiceProfile() async -> VoiceProfile? {
        await performResult(.getVoiceProfile(GetVoiceProfilePayload()), as: VoiceProfile.self, timeout: .seconds(10), silent: true)
    }

    func updateVoiceProfile(_ payload: UpdateVoiceProfilePayload) async -> VoiceProfile? {
        await performResult(.updateVoiceProfile(payload), as: VoiceProfile.self, timeout: .seconds(10), silent: true)
    }
}
