// ColdEmailModel.swift — Cold Email screen state (docs/COLD_EMAIL_PLAN.md §A, §C, §F.1, §G.6):
// the tab, Outbox selection and the "Send N…" approval flow with conflict handling, the draft
// editor, Enable sending (test email to yourself), prospect search, and the referral copilot's
// copy-and-open (clipboard + the user's own browser; LinkedIn is never automated).
import AppKit
import Foundation
import Observation

enum ColdEmailTab: String, CaseIterable, Identifiable, Sendable {
    case followUps, prospects, contacts, outbox, referrals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followUps: "Follow-ups"
        case .prospects: "Prospects"
        case .contacts: "Contacts"
        case .outbox: "Outbox"
        case .referrals: "Referrals"
        }
    }
}

/// Whether the outreach data is readable yet.
enum ColdEmailPhase: Equatable, Sendable {
    case loading
    case error(String)
    case ready
}

@MainActor
@Observable
final class ColdEmailModel {
    enum ApproveState: Equatable {
        case idle
        case sending
        case conflicts(OutreachConflicts, message: String)
        case failed(String)
    }

    enum EnableState: Equatable {
        case idle
        case testing
        case enabled(sentTo: String)
        case failed(String)
    }

    /// A referral text the user copied; we ask whether they sent it before changing its state.
    struct SentCheck: Equatable {
        enum Kind: Equatable { case note, message }
        var referralID: Int
        var kind: Kind
    }

    let store: AppStore
    var tab: ColdEmailTab = .followUps
    /// Tests / previews: force a phase instead of deriving it from the store.
    var phaseOverride: ColdEmailPhase?

    // Outbox
    var selectedDraftIDs: Set<Int> = []
    var focusedMessageID: Int?
    var isSendSheetPresented = false
    /// "Also send one gentle follow-up…": off unless the user ticks it (owner decision Q3).
    var includeFollowups = false
    /// Drafts the user OK'd below the confidence bar ("Send anyway").
    var sendAnyway: Set<Int> = []
    private(set) var approveState: ApproveState = .idle
    /// Message id being re-drafted for another contact.
    private(set) var redraftingMessageID: Int?

    // Enable sending
    var isEnableSheetPresented = false
    private(set) var enableState: EnableState = .idle

    // Prospects
    var prospectQuery = ""
    var prospectLocation = ""
    var newProspect = ""
    var selectedProspectID: Int?

    // Contacts
    var contactSearch = ""
    var isAddContactPresented = false

    // Warm intros (LinkedIn export)
    var isLinkedInImportPresented = false
    var linkedInImport: LinkedInImportState = .idle

    // Referrals
    var isAddReferralPresented = false
    private(set) var sentCheck: SentCheck?

    @ObservationIgnored var clipboard: ClipboardWriting = SystemClipboard.shared
    /// Opens a link in the user's default browser (never the agent's Chrome).
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    static func shared(for store: AppStore) -> ColdEmailModel {
        FeatureModels.model(ColdEmailModel.self, for: store) { ColdEmailModel(store: store) }
    }

    init(store: AppStore) {
        self.store = store
    }

    var outreach: OutreachStore { store.outreach }

    var phase: ColdEmailPhase {
        if let phaseOverride { return phaseOverride }
        if outreach.isLoaded { return .ready }
        if store.isDaemonUnreachable && !store.repository.isAvailable {
            return .error("Can't read your outreach yet. It shows here once the agent has created its database.")
        }
        return .loading
    }

    /// "3 drafts ready for your review · 1 new reply"
    var summary: String {
        var parts: [String] = []
        let drafts = outreach.draftCount
        parts.append(drafts == 0 ? "No drafts waiting" : "\(C3Format.plural(drafts, "draft")) ready for your review")
        if outreach.unreadReplyCount > 0 { parts.append(C3Format.plural(outreach.unreadReplyCount, "new reply", "new replies")) }
        if !outreach.scheduled.isEmpty { parts.append("\(outreach.scheduled.count) scheduled") }
        return parts.joined(separator: " · ")
    }

    // MARK: Outbox selection

    var drafts: [OutreachMessageItem] { outreach.drafts }

    /// Selected ids that are still drafts (a draft that left the list drops out).
    var selection: [Int] {
        let live = Set(drafts.map(\.id))
        return drafts.map(\.id).filter { selectedDraftIDs.contains($0) && live.contains($0) }
    }

    func toggle(_ id: Int) {
        if selectedDraftIDs.contains(id) { selectedDraftIDs.remove(id) } else { selectedDraftIDs.insert(id) }
    }

    func selectAllDrafts() { selectedDraftIDs = Set(drafts.map(\.id)) }
    func clearSelection() { selectedDraftIDs.removeAll() }

    var focusedMessage: OutreachMessageItem? { outreach.message(id: focusedMessageID) }

    func focus(_ messageID: Int?) {
        focusedMessageID = messageID
        if let id = messageID, let m = outreach.message(id: id), m.isInbound, let t = outreach.thread(id: m.threadID), t.unreadReply {
            Task { await store.markReplyRead(threadID: t.id) }
        }
    }

    /// Keep the editor on something sensible: the first draft, else the first scheduled email.
    func ensureFocus() {
        if focusedMessage == nil { focusedMessageID = drafts.first?.id ?? outreach.scheduled.first?.id }
    }

    /// Show a thread from another tab (Follow-ups "Open thread", the job inspector).
    func open(threadID: Int) {
        tab = .outbox
        let ms = outreach.messages(threadID: threadID)
        focusedMessageID = (ms.last { !$0.isInbound && $0.state == .draft } ?? ms.last)?.id
    }

    // MARK: Send N…

    var canSend: Bool { outreach.sendEnabled && !selection.isEmpty }

    /// Why "Send N…" is unavailable, in one line (nil when it's available).
    var sendBlocker: String? {
        if !outreach.mailAccount.isConnected { return "Connect a mailbox first" }
        if !outreach.sendEnabled { return "Turn on sending first" }
        if selection.isEmpty { return "Select the drafts to send" }
        return nil
    }

    func beginSend() {
        guard canSend else { return }
        approveState = .idle
        sendAnyway = sendAnyway.intersection(selection)
        isSendSheetPresented = true
    }

    /// The sheet's promise, in plain words.
    func sendSentence(count: Int, preferences: Preferences) -> String {
        let from = outreach.mailAccount.email ?? "your mailbox"
        let window = preferences.outreachSendWindow.count == 2
            ? "between \(preferences.outreachSendWindow[0]) and \(preferences.outreachSendWindow[1])" : "inside your send window"
        let days = preferences.outreachWeekdaysOnly ? " on weekdays" : ""
        let spacing = count > 1 ? ", a few minutes apart" : ""
        return "\(C3Format.plural(count, "email")) from \(from)\(spacing), \(window)\(days). Each goes out as written, with the footer below it."
    }

    /// The one approval click. Conflicts keep the sheet open with what to fix.
    func approveSelected() async {
        let ids = selection
        guard !ids.isEmpty else { return }
        approveState = .sending
        let result = await store.approveOutreach(messageIDs: ids, includeFollowups: includeFollowups && store.preferences.outreachMaxFollowups > 0,
                                                 sendAnyway: Array(sendAnyway.intersection(ids)).sorted())
        switch result {
        case .scheduled:
            approveState = .idle
            isSendSheetPresented = false
            selectedDraftIDs.subtract(ids)
            sendAnyway.subtract(ids)
        case .conflicts(let conflicts, let message):
            approveState = .conflicts(conflicts, message: message)
        case .failed(let message):
            approveState = .failed(message)
        }
    }

    /// "Send anyway" for addresses below the confidence bar, then try again.
    func sendAnywayAndRetry(_ ids: [Int]) async {
        sendAnyway.formUnion(ids)
        await approveSelected()
    }

    /// Take drafts out of this batch (they stay in Drafts).
    func leaveOut(_ ids: [Int]) {
        selectedDraftIDs.subtract(ids)
        if case .conflicts(var c, let message) = approveState {
            let drop = Set(ids)
            c.ungrounded.removeAll(where: drop.contains)
            c.lowConfidence.removeAll(where: drop.contains)
            c.doNotContact.removeAll(where: drop.contains)
            c.threadClosed.removeAll(where: drop.contains)
            approveState = c.isEmpty ? .idle : .conflicts(c, message: message)
        }
        if selection.isEmpty { isSendSheetPresented = false }
    }

    /// Close the sheet and open a draft that needs editing.
    func review(_ messageID: Int) {
        isSendSheetPresented = false
        approveState = .idle
        tab = .outbox
        focusedMessageID = messageID
    }

    func cancelSendSheet() {
        isSendSheetPresented = false
        approveState = .idle
    }

    // MARK: Draft editor

    /// Re-draft the thread for another contact at the same company.
    func switchContact(message: OutreachMessageItem, to contactID: Int) async {
        guard let thread = outreach.thread(id: message.threadID) else { return }
        redraftingMessageID = message.id
        defer { redraftingMessageID = nil }
        if let check = await store.draftOutreach(contactID: contactID, kind: thread.kind, applicationID: thread.applicationID),
           let newID = check.messageId {
            selectedDraftIDs.remove(message.id)
            focusedMessageID = newID
        }
    }

    func isRedrafting(_ messageID: Int) -> Bool { redraftingMessageID == messageID }

    // MARK: Enable sending

    func enableSending() async {
        guard outreach.mailAccount.isConnected else {
            enableState = .failed("Connect a mailbox first, in Settings ▸ Sources.")
            return
        }
        enableState = .testing
        if let result = await store.enableSending(true), result.sendEnabled {
            enableState = .enabled(sentTo: result.testSentTo ?? outreach.mailAccount.email ?? "you")
        } else {
            enableState = .failed(store.lastOutreachErrorMessage)
        }
    }

    func resetEnableState() { enableState = .idle }

    // MARK: Referral copilot

    /// A LinkedIn profile link that is safe to hand to the user's browser.
    static func profileURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    /// "Copy note & open profile": the note goes to the clipboard and the profile opens in the
    /// user's default browser. AutoApply never opens or drives LinkedIn itself.
    @discardableResult
    func copyNoteAndOpenProfile(_ referral: ReferralItem) -> Bool {
        copyAndOpen(text: referral.connectNote, referral: referral, kind: .note)
    }

    /// "Copy message & open": the referral request goes to the clipboard, the profile opens.
    @discardableResult
    func copyMessageAndOpen(_ referral: ReferralItem) -> Bool {
        copyAndOpen(text: referral.referralDM, referral: referral, kind: .message)
    }

    private func copyAndOpen(text: String?, referral: ReferralItem, kind: SentCheck.Kind) -> Bool {
        guard let url = Self.profileURL(referral.linkedinURL) else {
            store.toasts.show("No profile link for \(referral.personName)", symbol: "link", style: .warning)
            return false
        }
        if let text = text.c3Trimmed {
            clipboard.write(text)
        }
        openURL(url)
        sentCheck = SentCheck(referralID: referral.id, kind: kind)
        store.toasts.show(text.c3Trimmed == nil ? "Opened \(referral.personName)'s profile"
                          : "\(kind == .note ? "Note" : "Message") copied · paste it on LinkedIn",
                          symbol: "doc.on.clipboard", style: .success, duration: .seconds(3))
        return true
    }

    /// The answer to "Did you send it?".
    func confirmSent(_ sent: Bool) async {
        guard let check = sentCheck else { return }
        sentCheck = nil
        guard sent, let referral = outreach.referral(id: check.referralID) else { return }
        let target: ReferralState = check.kind == .note ? .requested : .asked
        guard referral.state.nextStates.contains(target) else { return }
        await store.updateReferral(id: referral.id, state: target)
    }

    func dismissSentCheck() { sentCheck = nil }

    /// Referral invitations marked sent in the last 7 days (pacing advice, not a limit).
    var requestsThisWeek: Int {
        let since = Date().addingTimeInterval(-7 * 86_400)
        return outreach.data.referrals.filter { $0.state == .requested && $0.stateUpdatedAt >= since }.count
    }

    // MARK: Contacts

    var filteredContacts: [ContactItem] {
        let q = contactSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let all = outreach.data.contacts
        guard !q.isEmpty else { return all }
        return all.filter { c in
            [c.fullName, c.title ?? "", c.company ?? "", c.email ?? ""].contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: Prospects

    var selectedProspect: ProspectItem? { outreach.prospect(id: selectedProspectID) ?? outreach.activeProspects.first }

    func search() async {
        guard await store.searchProspects(query: prospectQuery, location: prospectLocation) else { return }
    }

    func addProspect() async {
        let text = newProspect.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let isURL = text.contains(".") && !text.contains(" ")
        if await store.addProspect(name: isURL ? nil : text, url: isURL ? CareerURL.normalize(text) : nil) { newProspect = "" }
    }
}
