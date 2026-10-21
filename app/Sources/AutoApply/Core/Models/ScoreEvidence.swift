// ScoreEvidence.swift — the parts of `scores.reasons` the app shows (engine/autoapply/scoring.py):
// summary, factor scores, and (newer scores only) requirement-level evidence plus the grounding
// guard's counts. Older scores have no `requirements` key; that stays `nil` so the UI hides the
// table instead of claiming "no requirements".
import Foundation

/// One of the job's key requirements, checked against the candidate's own text.
struct RequirementEvidence: Sendable, Hashable, Identifiable {
    enum Status: String, Sendable, Hashable, CaseIterable {
        case met, partial, missing

        var label: String {
            switch self {
            case .met: "Met"
            case .partial: "Partly"
            case .missing: "Missing"
            }
        }

        var symbol: String {
            switch self {
            case .met: "checkmark.circle.fill"
            case .partial: "circle.lefthalf.filled"
            case .missing: "xmark.circle"
            }
        }
    }

    enum Confidence: String, Sendable, Hashable {
        case high, medium, low
    }

    /// Position in the scorer's list (most important first).
    var index: Int
    var requirement: String
    var status: Status
    /// A verbatim quote from the user's profile / resume, or empty when none was found.
    var evidence: String
    var confidence: Confidence
    /// Only true when the job text says it is mandatory; `jdQuote` then holds that text.
    var dealbreaker: Bool
    var jdQuote: String?

    var id: Int { index }
}

/// What the grounding guard removed: evidence not found in the user's own text, and
/// dealbreakers whose quote isn't in the job text.
struct ScoreGrounding: Sendable, Hashable {
    var evidenceDropped: Int = 0
    var dealbreakersDropped: Int = 0
}

enum ScoreEvidence {
    /// Copy summary, factors, requirements and grounding from `reasons` onto `job`.
    static func apply(_ reasons: JSONValue, to job: inout JobItem) {
        if case .string(let summary)? = reasons["summary"] { job.scoreSummary = summary }
        if case .object(let factors)? = reasons["factors"] {
            for (k, v) in factors {
                switch v {
                case .int(let i): job.scoreFactors[k] = i
                case .double(let d): job.scoreFactors[k] = Int(d.rounded())
                default: break
                }
            }
        }
        job.scoreRequirements = requirements(from: reasons)
        job.scoreGrounding = grounding(from: reasons)
    }

    static func apply(_ reasons: [String: JSONValue], to job: inout JobItem) {
        apply(.object(reasons), to: &job)
    }

    /// nil when the score predates requirement evidence (no `requirements` key, or not a list).
    /// Malformed entries (no requirement text) are dropped; unknown statuses read as missing and
    /// unknown confidences as low, like the engine's own guard.
    static func requirements(from reasons: JSONValue) -> [RequirementEvidence]? {
        guard case .array(let raw)? = reasons["requirements"] else { return nil }
        var out: [RequirementEvidence] = []
        for item in raw {
            guard case .string(let text)? = item["requirement"] else { continue }
            let requirement = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requirement.isEmpty else { continue }
            let status = string(item["status"]).flatMap(RequirementEvidence.Status.init(rawValue:)) ?? .missing
            let confidence = string(item["confidence"]).flatMap(RequirementEvidence.Confidence.init(rawValue:)) ?? .low
            let quote = string(item["jd_quote"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            var dealbreaker = false
            if case .bool(true)? = item["dealbreaker"] { dealbreaker = true }
            out.append(RequirementEvidence(
                index: out.count, requirement: requirement, status: status,
                evidence: (string(item["evidence"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: confidence,
                // A dealbreaker is only shown with the job's own words.
                dealbreaker: dealbreaker && !(quote ?? "").isEmpty,
                jdQuote: (quote ?? "").isEmpty ? nil : quote))
        }
        return out
    }

    static func grounding(from reasons: JSONValue) -> ScoreGrounding? {
        guard case .object(let g)? = reasons["grounding"] else { return nil }
        func int(_ key: String) -> Int {
            switch g[key] {
            case .int(let i)?: i
            case .double(let d)?: Int(d)
            default: 0
            }
        }
        return ScoreGrounding(evidenceDropped: int("evidence_dropped"), dealbreakersDropped: int("dealbreakers_dropped"))
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }
}
