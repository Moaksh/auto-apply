// LibraryStore.swift — profile, never-guess facts, resumes, stories, answer memory and the
// Easy Apply list, all read from the DB.
import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    var profile = Profile()
    var neverGuess = NeverGuess()
    var resumeVariants: [ResumeVariantItem] = []
    var stories: [StoryItem] = []
    var memoryAnswers: [MemoryAnswerItem] = []
    var easyApply: [EasyApplyItem] = []
    /// Settings ▸ Sources: companies found while browsing (pending + added by the agent).
    var companySuggestions: [CompanySuggestionItem] = []
    var runs: [RunItem] = []

    init() {}

    var defaultResume: ResumeVariantItem? { resumeVariants.first(where: \.isDefault) ?? resumeVariants.first }
    var easyApplyOpenCount: Int { easyApply.reduce(0) { $0 + ($1.isOpen && !$1.opened ? 1 : 0) } }
    var easyApplyToDoCount: Int { easyApply.reduce(0) { $0 + ($1.isOpen ? 1 : 0) } }
    var pendingSuggestions: [CompanySuggestionItem] { companySuggestions.filter { $0.status == .pending } }
    var autoAddedCompanies: [CompanySuggestionItem] { companySuggestions.filter { $0.status == .auto } }
    /// Badge on Settings ▸ Sources.
    var pendingSuggestionCount: Int { companySuggestions.reduce(0) { $0 + ($1.status == .pending ? 1 : 0) } }

    func resume(id: Int?) -> ResumeVariantItem? {
        guard let id else { return nil }
        return resumeVariants.first { $0.id == id }
    }

    func easyApplyItem(jobID: Int) -> EasyApplyItem? { easyApply.first { $0.jobID == jobID } }

    /// "Moaksh" — for greetings.
    var firstName: String? {
        if let f = profile.firstName, !f.isEmpty { return f }
        return profile.fullName?.split(separator: " ").first.map(String.init)
    }
}
