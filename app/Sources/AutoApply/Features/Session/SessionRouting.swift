// SessionRouting.swift — reads the session's work from the existing stores (Needs You clusters
// and replies, the Review queue, interview stages, Outbox drafts), and takes the user to an item:
// the right screen with that item selected. Read-only over other features; it selects through
// their public models (InboxModel, ReviewModel, ColdEmailModel) and the Router.
import Foundation

extension SessionSources {
    /// Everything waiting for the user right now, from the live stores.
    @MainActor
    static func live(store: AppStore) -> SessionSources {
        let inbox = InboxModel.shared(for: store)
        let review = ReviewModel.shared(for: store)
        let prep = InterviewPrepModel.shared(for: store)
        var sources = SessionSources()

        for cluster in inbox.clusters {
            let kind = inbox.kind(for: cluster)
            let item = SessionItem(key: .cluster(cluster.clusterId), kind: cluster.isAction ? .blocker : .question,
                                   subject: inbox.title(for: cluster), seconds: SessionEstimate.seconds(for: kind))
            if cluster.isAction { sources.blockers.append(item) } else { sources.questions.append(item) }
        }

        sources.reviews = review.queue.map { job in
            SessionItem(key: .review(jobID: job.id), kind: .review, subject: job.displayName,
                        seconds: SessionEstimate.review(flagged: review.isFlagged(job)))
        }

        sources.replies = inbox.replyItems.map { reply in
            SessionItem(key: .reply(reply.key), kind: .reply, subject: subject(of: reply, inbox: inbox),
                        seconds: SessionEstimate.reply(reply))
        }

        sources.preps = prepDue(store: store, prep: prep).map { job in
            SessionItem(key: .prep(jobID: job.id), kind: .prep, subject: job.displayName, seconds: SessionEstimate.prep)
        }

        sources.drafts = store.outreach.drafts.map { message in
            let thread = store.outreach.thread(id: message.threadID)
            let subject = [thread?.company, message.subject ?? thread?.subject].compactMap { $0 }.joined(separator: " · ")
            return SessionItem(key: .draft(messageID: message.id), kind: .draft,
                               subject: subject.isEmpty ? "Cold email" : subject, seconds: SessionEstimate.draft)
        }
        return sources
    }

    /// Jobs at Assessment or Interview with no interview prep pack yet (generating counts as
    /// started, so it isn't asked for twice).
    @MainActor
    static func prepDue(store: AppStore, prep: InterviewPrepModel) -> [JobItem] {
        store.jobs.all
            .filter { job in
                guard job.state == .submitted, let appID = job.applicationID else { return false }
                guard [.assessment, .interview].contains(job.status ?? .applied) else { return false }
                return prep.pack(appID) == nil && !prep.generating.contains(appID)
            }
            .sorted { ($0.statusUpdatedAt ?? $0.discoveredAt) > ($1.statusUpdatedAt ?? $1.discoveredAt) }
    }

    @MainActor
    private static func subject(of reply: NeedsYouReply, inbox: InboxModel) -> String {
        switch reply {
        case .outreach(let thread): thread.subject.map { "\(thread.company) · \($0)" } ?? thread.company
        case .employer(let r): inbox.jobName(applicationID: r.applicationID) ?? r.subject
        case .possiblySent(let m): m.subject ?? "An email that may not have gone out"
        }
    }
}

/// Takes the user to a session item: the right screen, with that item selected.
@MainActor
enum SessionNavigator {
    static func show(_ item: SessionItem, store: AppStore) {
        let router = store.router
        switch item.key {
        case .cluster(let id):
            InboxModel.shared(for: store).select(id)
            go(.needsYou, router: router)
        case .reply(let key):
            InboxModel.shared(for: store).selectReply(key)
            go(.needsYou, router: router)
        case .review(let jobID):
            let review = ReviewModel.shared(for: store)
            review.focusedJobID = jobID
            go(.review, router: router)
        case .prep(let jobID):
            router.openJob(id: jobID, tab: JobDetailTab.prep.rawValue)
        case .draft(let messageID):
            let cold = ColdEmailModel.shared(for: store)
            cold.tab = .outbox
            cold.focus(messageID)
            go(.coldEmail, router: router)
        }
    }

    /// Switch screens and drop anything pushed on top (e.g. a job detail from the last item).
    private static func go(_ item: SidebarItem, router: Router) {
        router.go(item)
        if !router.path.isEmpty { router.path.removeAll() }
    }
}
