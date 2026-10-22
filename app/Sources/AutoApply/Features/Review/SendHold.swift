// SendHold.swift — the send hold on Approve (docs/DESIGN_AWARD_VISION.md §4.3, item 1E).
// Approving never sends straight away: the jobs wait here for `SendHoldTiming.window` (≈5 s)
// with a draining "Sending in 5…" ring and Undo (⌘Z), and only then is the `approve` command
// sent to the agent. Every approve path goes through it: the Review queue (row, bar, A key, a
// batch), Job detail (button, ⌘↵), ⌘K / the Job menu (which route through Job detail) and the
// "Ready for review" notification's Approve button (`AppNotifier`).
//
// The hold is client-side, like Needs You's undo window, with one difference on quit: held
// approvals are NOT flushed. Quitting (or a crash) during a hold drops them; they stay in Review
// and are marked "Not sent — approve again" on the next launch.
import AppKit
import Foundation
import Observation

enum SendHoldTiming {
    /// How long an approval waits before it is sent to the agent.
    static let window: Duration = .seconds(5)

    /// Whole seconds left, rounded up ("Sending in 5…" → … "Sending in 1…").
    static func secondsLeft(until deadline: Date, now: Date = Date()) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// 1 → 0 as the window drains (linear: an honest countdown).
    static func fraction(until deadline: Date, window: TimeInterval, now: Date = Date()) -> Double {
        guard window > 0 else { return 0 }
        return min(1, max(0, deadline.timeIntervalSince(now) / window))
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

@MainActor
@Observable
final class SendHoldModel {
    struct Entry: Equatable, Sendable {
        var jobID: Int
        var applicationID: Int
        var batch: UUID
        var heldAt: Date
        var deadline: Date
        /// The window closed and the `approve` command is on its way (no longer undoable).
        var isSending = false

        var window: TimeInterval { deadline.timeIntervalSince(heldAt) }
    }

    /// The jobs an Undo just put back (Review refocuses the first one).
    struct UndoEvent: Equatable, Sendable {
        var serial: Int
        var jobIDs: [Int]
    }

    let store: AppStore
    /// Held (and sending) approvals by job id.
    private(set) var entries: [Int: Entry] = [:]
    /// Jobs whose hold was cut short by quitting (or a crash): never sent, still in Review.
    private(set) var notSent: Set<Int> = []
    private(set) var lastUndo: UndoEvent?

    /// The hold length (tests shorten it).
    @ObservationIgnored var window: Duration = SendHoldTiming.window
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Batch → job ids in the order they were approved.
    @ObservationIgnored private var batches: [UUID: [Int]] = [:]
    @ObservationIgnored private var undoRegistrations: [UUID: (token: SendHoldUndoToken, manager: WeakUndoManager)] = [:]
    /// Batch → what to call once its `approve` reply is in (true = confirmed). Never called for a
    /// batch that was undone, abandoned on quit, or had nothing left to send.
    @ObservationIgnored private var completions: [UUID: @MainActor (Bool) -> Void] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    /// Only the real app remembers holds across launches (tests and `swift run` pass their own).
    static var appDefaults: UserDefaults? {
        Bundle.main.bundleURL.pathExtension == "app" ? .standard : nil
    }

    /// One hold per store, kept outside `FeatureModels` on purpose: dropping cached screen models
    /// (`FeatureModels.reset()`) must never drop, or duplicate, approvals that are on hold.
    private static var registry: [ObjectIdentifier: SendHoldModel] = [:]

    static func shared(for store: AppStore) -> SendHoldModel {
        let key = ObjectIdentifier(store)
        if let existing = registry[key] { return existing }
        let created = SendHoldModel(store: store)
        registry[key] = created
        return created
    }

    init(store: AppStore, defaults: UserDefaults? = SendHoldModel.appDefaults) {
        self.store = store
        self.defaults = defaults
        // Anything still marked held from the last run was never sent.
        let heldBefore = defaults?.array(forKey: heldKey) as? [Int] ?? []
        let notSentBefore = defaults?.array(forKey: notSentKey) as? [Int] ?? []
        notSent = Set(heldBefore).union(notSentBefore)
        defaults?.removeObject(forKey: heldKey)
        persist()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.abandonAll() }
        }
    }

    // MARK: Keys

    private var keyScope: String { store.mockScenarioName.map { "sample.\($0)" } ?? "live" }
    private var heldKey: String { "sendHold.\(keyScope).held" }
    private var notSentKey: String { "sendHold.\(keyScope).notSent" }

    private func persist() {
        guard let defaults else { return }
        let held = entries.values.filter { !$0.isSending }.map(\.jobID).sorted()
        if held.isEmpty { defaults.removeObject(forKey: heldKey) } else { defaults.set(held, forKey: heldKey) }
        if notSent.isEmpty { defaults.removeObject(forKey: notSentKey) } else { defaults.set(notSent.sorted(), forKey: notSentKey) }
    }

    // MARK: Queries

    func entry(for jobID: Int) -> Entry? { entries[jobID] }

    func isHeld(_ jobID: Int) -> Bool { entries[jobID] != nil }

    var heldJobIDs: [Int] { entries.keys.sorted() }

    var hasHolds: Bool { !entries.isEmpty }

    /// "Not sent — approve again": the job is still waiting and its last hold never went out.
    func wasNotSent(_ jobID: Int) -> Bool {
        guard notSent.contains(jobID), entries[jobID] == nil else { return false }
        return store.jobs.job(id: jobID)?.state == .awaitingReview
    }

    // MARK: Hold

    /// Start the hold for these jobs (one batch, one countdown, one Undo). Jobs already held,
    /// gone from Review, or without an application are ignored. Returns the jobs now held.
    /// `onSent` hears whether the agent confirmed the approve once the window closes (the
    /// notification path uses it to say "Not approved yet"; the UI relies on toasts).
    @discardableResult
    func hold(jobIDs: [Int], undoManager: UndoManager? = nil, onSent: (@MainActor (Bool) -> Void)? = nil) -> [Int] {
        var seen: Set<Int> = []
        let fresh: [(Int, Int)] = jobIDs.compactMap { id in
            guard seen.insert(id).inserted, entries[id] == nil, let job = store.jobs.job(id: id),
                  job.state == .awaitingReview, let appID = job.applicationID else { return nil }
            return (id, appID)
        }
        guard !fresh.isEmpty else { return [] }
        let batch = UUID()
        let now = Date()
        let deadline = now.addingTimeInterval(SendHoldTiming.seconds(window))
        for (id, appID) in fresh {
            entries[id] = Entry(jobID: id, applicationID: appID, batch: batch, heldAt: now, deadline: deadline)
            notSent.remove(id)
        }
        let ids = fresh.map(\.0)
        batches[batch] = ids
        if let onSent { completions[batch] = onSent }
        persist()
        let window = self.window
        tasks[batch] = Task { [weak self] in
            try? await Task.sleep(for: window)
            // Cancelled (Undo / quit) or the model is gone: nothing is sent.
            guard !Task.isCancelled, let self else { return }
            await self.commit(batch: batch)
        }
        if let undoManager {
            let token = SendHoldUndoToken(model: self, batch: batch)
            undoManager.registerUndo(withTarget: token) { token in
                MainActor.assumeIsolated { token.fire() }
            }
            undoManager.setActionName(ids.count == 1 ? "Approve" : "Approve \(ids.count)")
            undoRegistrations[batch] = (token, WeakUndoManager(manager: undoManager))
        }
        return ids
    }

    // MARK: Undo

    /// Cancel a whole batch inside its window. Returns the jobs put back.
    @discardableResult
    func undo(batch: UUID) -> [Int] {
        let ids = (batches[batch] ?? []).filter { entries[$0]?.batch == batch && entries[$0]?.isSending == false }
        guard !ids.isEmpty else { return [] }
        tasks.removeValue(forKey: batch)?.cancel()
        batches.removeValue(forKey: batch)
        completions.removeValue(forKey: batch)
        dropUndoRegistration(batch)
        for id in ids { entries.removeValue(forKey: id) }
        persist()
        lastUndo = UndoEvent(serial: (lastUndo?.serial ?? 0) + 1, jobIDs: ids)
        return ids
    }

    /// The row's Undo: put back just this job (the rest of its batch still sends).
    @discardableResult
    func undo(jobID: Int) -> Bool {
        guard let entry = entries[jobID], !entry.isSending else { return false }
        entries.removeValue(forKey: jobID)
        batches[entry.batch]?.removeAll { $0 == jobID }
        if batches[entry.batch]?.isEmpty ?? true {
            tasks.removeValue(forKey: entry.batch)?.cancel()
            batches.removeValue(forKey: entry.batch)
            completions.removeValue(forKey: entry.batch)
            dropUndoRegistration(entry.batch)
        }
        persist()
        lastUndo = UndoEvent(serial: (lastUndo?.serial ?? 0) + 1, jobIDs: [jobID])
        return true
    }

    /// ⌘Z without a registered undo manager: the most recent batch still on hold.
    @discardableResult
    func undoLatest() -> [Int] {
        guard let latest = entries.values.filter({ !$0.isSending }).max(by: { $0.heldAt < $1.heldAt }) else { return [] }
        return undo(batch: latest.batch)
    }

    private func dropUndoRegistration(_ batch: UUID) {
        guard let reg = undoRegistrations.removeValue(forKey: batch) else { return }
        reg.manager.manager?.removeAllActions(withTarget: reg.token)
    }

    // MARK: Quit

    /// Quitting during a hold: nothing held is sent. The jobs stay in Review and read
    /// "Not sent — approve again" next time. (Approvals already sending are the agent's now.)
    func abandonAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        completions.removeAll()
        let held = entries.values.filter { !$0.isSending }.map(\.jobID)
        for id in held { entries.removeValue(forKey: id) }
        for batch in Array(undoRegistrations.keys) { dropUndoRegistration(batch) }
        batches = batches.filter { _, ids in ids.contains { entries[$0] != nil } }
        notSent.formUnion(held)
        persist()
    }

    // MARK: Send

    /// The window closed: send the batch's jobs that are still waiting for review.
    private func commit(batch: UUID) async {
        tasks.removeValue(forKey: batch)
        dropUndoRegistration(batch)
        let onSent = completions.removeValue(forKey: batch)
        let ids = (batches.removeValue(forKey: batch) ?? []).filter { entries[$0]?.batch == batch }
        // Skipped / sent elsewhere meanwhile: drop quietly.
        let live = ids.filter { store.jobs.job(id: $0)?.state == .awaitingReview }
        for id in ids where !live.contains(id) { entries.removeValue(forKey: id) }
        let appIDs = live.compactMap { entries[$0]?.applicationID }
        guard !appIDs.isEmpty else { persist(); return }
        for id in live { entries[id]?.isSending = true }
        persist()
        let ok = await store.approve(applicationIDs: appIDs)
        for id in live { entries.removeValue(forKey: id) }
        if ok {
            Sounds.play(.send)
            store.toasts.show(appIDs.count == 1 ? "Approved · sending now" : "Approved \(appIDs.count) · sending now",
                              symbol: "paperplane.fill", style: .success)
        }
        onSent?(ok)
    }
}

/// The undo target for one held batch (so committing a batch removes only its own ⌘Z).
final class SendHoldUndoToken: NSObject {
    private weak var model: SendHoldModel?
    private let batch: UUID

    @MainActor init(model: SendHoldModel, batch: UUID) {
        self.model = model
        self.batch = batch
    }

    @MainActor func fire() { _ = model?.undo(batch: batch) }
}

struct WeakUndoManager {
    weak var manager: UndoManager?
}
