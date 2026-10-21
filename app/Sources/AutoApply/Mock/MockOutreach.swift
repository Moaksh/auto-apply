// MockOutreach.swift — cold-outreach fixtures and the daemon's outreach command semantics
// (contract/protocol.md §5.1–5.2, §7.1–7.2) against the in-memory DB, so the Cold Email screen,
// Needs You ▸ Replies and the job card envelope work in mock mode, previews and tests.
// Like the real daemon: nothing is scheduled without approve_outreach, sending is refused until
// enable_sending succeeds, opt-outs can't be removed, and LinkedIn is never touched.
import Foundation

enum MockOutreach {
    static let mailbox = "asha.rao@gmail.com"

    static func footer(_ source: String) -> String {
        "—\nI found your address on \(source). If you'd rather not hear from me, reply \"no thanks\" and I won't email again."
    }

    // MARK: Fixtures

    /// Seed outreach rows on the baseline's applied jobs: drafts (clean, with an unsupported claim,
    /// below the confidence bar), a scheduled email, sent, an unread reply, a "possibly sent" email,
    /// contacts without a thread, prospects, referrals, the do-not-contact list and employer replies.
    static func seed(_ data: inout RepositoryData, now: Date, sendEnabled: Bool = true) {
        var applied: [JobItem] = []
        var seenCompanies = Set<Int>()
        for job in data.jobs.filter({ $0.state == .submitted && $0.applicationID != nil })
            .sorted(by: { ($0.submittedAt ?? .distantPast) > ($1.submittedAt ?? .distantPast) })
            where seenCompanies.insert(job.companyID).inserted {
            applied.append(job)
            if applied.count == 10 { break }
        }
        var o = OutreachData()
        o.mailAccount = MailAccountInfo(email: mailbox, sendEnabled: sendEnabled)
        var evidence: [ContactEvidenceItem] = []
        var nextContact = 1, nextThread = 1, nextMessage = 1, nextEvidence = 1

        func domain(_ job: JobItem) -> String { job.companyDomain ?? "\(job.company.lowercased().filter(\.isLetter)).com" }

        @discardableResult
        func contact(_ job: JobItem, _ name: String, _ title: String, _ role: ContactRoleCategory, confidence: Int,
                     status: String, origin: ContactOrigin = .scout, source: String, url: String?) -> ContactItem {
            let parts = name.lowercased().split(separator: " ")
            let email = "\(parts.first ?? "hello").\(parts.last ?? "team")@\(domain(job))"
            let c = ContactItem(id: nextContact, companyID: job.companyID, company: job.company, fullName: name, title: title,
                                roleCategory: role, email: email, emailStatus: status, emailConfidence: confidence, origin: origin,
                                linkedinURL: "https://www.linkedin.com/in/\(parts.joined(separator: "-"))",
                                createdAt: now.addingTimeInterval(-86_400 * 3))
            o.contacts.append(c)
            evidence.append(ContactEvidenceItem(id: nextEvidence, contactID: c.id, kind: source, field: "name", url: url,
                                                snippet: "\(name), \(title) at \(job.company)", observedAt: now.addingTimeInterval(-86_400 * 3)))
            evidence.append(ContactEvidenceItem(id: nextEvidence + 1, contactID: c.id, kind: status == "published" ? source : "pattern",
                                                field: "email", url: status == "published" ? url : nil,
                                                snippet: status == "published" ? email : "first.last@\(domain(job)) from 3 published addresses",
                                                observedAt: now.addingTimeInterval(-86_400 * 2)))
            nextEvidence += 2
            nextContact += 1
            return c
        }

        @discardableResult
        func thread(_ job: JobItem, _ c: ContactItem, state: OutreachThreadState, unread: Bool = false, updated: Date) -> OutreachThreadItem {
            let t = OutreachThreadItem(id: nextThread, kind: .application, contactID: c.id, companyID: job.companyID, company: job.company,
                                       jobID: job.id, applicationID: job.applicationID, state: state,
                                       subject: "\(job.title) application – Asha Rao", unreadReply: unread,
                                       createdAt: updated.addingTimeInterval(-3_600), updatedAt: updated)
            o.threads.append(t)
            nextThread += 1
            return t
        }

        @discardableResult
        func message(_ t: OutreachThreadItem, _ c: ContactItem, state: OutreachMessageState, body: String, inbound: Bool = false,
                     grounded: Bool = true, claims: [String] = [], sendAt: Date? = nil, sentAt: Date? = nil,
                     classification: String? = nil, seq: Int = 0, at: Date) -> OutreachMessageItem {
            let m = OutreachMessageItem(
                id: nextMessage, threadID: t.id, seq: seq, isInbound: inbound, kind: inbound ? nil : (seq > 0 ? "followup" : "application_followup"),
                state: state, toEmail: inbound ? mailbox : c.email, fromEmail: inbound ? c.email : mailbox,
                subject: inbound ? "Re: \(t.subject ?? "")" : t.subject, body: body,
                footer: inbound ? nil : footer(c.emailStatus == "published" ? "\(c.company?.lowercased() ?? "the company")'s team page" : "the \(t.company) job posting"),
                grounded: grounded, unsupportedClaims: claims,
                messageIDHeader: (state == .sent || state == .unknown || inbound) ? "<mock-\(nextMessage)@mail.gmail.com>" : nil,
                sendAt: sendAt, sentAt: sentAt, classification: classification, createdAt: at, updatedAt: at)
            o.messages.append(m)
            nextMessage += 1
            return m
        }

        func body(_ job: JobItem, _ c: ContactItem, extra: String = "") -> String {
            let first = c.fullName.split(separator: " ").first.map(String.init) ?? c.fullName
            return """
            Hi \(first),

            I applied for the \(job.title) role at \(job.company) this week. I build backend systems in Go and Python; at my current team I \
            rebuilt our payments reconciliation service\(extra), and I'd like to bring that to \(job.company).

            If you're the right person, would you be open to a 15-minute chat? If not, a pointer to whoever is would be very kind.

            Thanks,
            Asha
            """
        }

        let names: [(String, String, ContactRoleCategory)] = [
            ("Priya Nair", "Technical Recruiter", .recruiter), ("Daniel Kim", "Engineering Manager, Payments", .hiringManager),
            ("Meera Iyer", "Talent Partner", .talentLead), ("Tom Becker", "Head of Platform", .engLeader),
            ("Ananya Rao", "Senior Software Engineer", .engineer), ("Lucas Silva", "Recruiter", .recruiter),
            ("Kavya Menon", "Engineering Manager", .hiringManager), ("Rohan Shah", "Staff Engineer", .engineer),
            ("Sara Lindqvist", "Talent Acquisition Lead", .talentLead), ("Arjun Patel", "Co-founder & CTO", .founder),
        ]
        let page = { (job: JobItem) in "https://\(domain(job))/team" }
        for (i, job) in applied.enumerated() {
            let (name, title, role) = names[i % names.count]
            let ago = { (h: Double) in now.addingTimeInterval(-h * 3_600) }
            switch i {
            case 0: // clean draft, verified address
                let c = contact(job, name, title, role, confidence: 94, status: "published", source: "company_page", url: page(job))
                let t = thread(job, c, state: .draft, updated: ago(2))
                message(t, c, state: .draft, body: body(job, c), at: ago(2))
                contact(job, "Ishaan Gupta", "Engineering Manager", .hiringManager, confidence: 72, status: "pattern",
                        source: "google_serp", url: "https://www.google.com/search?q=\(job.company)")
            case 1: // draft with a claim the fact check couldn't find
                let c = contact(job, name, title, role, confidence: 78, status: "pattern", source: "google_serp",
                                url: "https://www.google.com/search?q=\(job.company)")
                let t = thread(job, c, state: .draft, updated: ago(5))
                message(t, c, state: .draft, body: body(job, c, extra: ", which cut p99 latency by 60%"), grounded: false,
                        claims: ["cut p99 latency by 60%"], at: ago(5))
            case 2: // draft below the confidence bar (a pattern guess)
                let c = contact(job, name, title, role, confidence: 48, status: "pattern", source: "github",
                                url: "https://github.com/\(name.lowercased().replacingOccurrences(of: " ", with: ""))")
                let t = thread(job, c, state: .draft, updated: ago(9))
                message(t, c, state: .draft, body: body(job, c), at: ago(9))
            case 3: // scheduled
                let c = contact(job, name, title, role, confidence: 91, status: "published", source: "job_posting", url: job.applyURL)
                let t = thread(job, c, state: .draft, updated: ago(1))
                message(t, c, state: .scheduled, body: body(job, c), sendAt: now.addingTimeInterval(2 * 3_600), at: ago(1))
            case 4: // sent, waiting
                let c = contact(job, name, title, role, confidence: 88, status: "delivered", source: "company_page", url: page(job))
                let t = thread(job, c, state: .active, updated: ago(50))
                message(t, c, state: .sent, body: body(job, c), sentAt: ago(50), at: ago(52))
            case 5: // replied, unread
                let c = contact(job, name, title, role, confidence: 96, status: "replied", source: "company_page", url: page(job))
                let t = thread(job, c, state: .replied, unread: true, updated: ago(3))
                message(t, c, state: .sent, body: body(job, c), sentAt: ago(30), at: ago(31))
                message(t, c, state: .received, body: "Thanks Asha! I've passed your profile to the hiring manager for the \(job.title) role. Expect to hear from us this week about a first call.",
                        inbound: true, classification: "positive", seq: 1, at: ago(3))
            case 6: // possibly sent (crash during sending)
                let c = contact(job, name, title, role, confidence: 90, status: "published", source: "company_page", url: page(job))
                let t = thread(job, c, state: .draft, updated: ago(6))
                message(t, c, state: .unknown, body: body(job, c), sendAt: ago(6), at: ago(7))
            case 7: // people found, nothing drafted yet
                contact(job, name, title, role, confidence: 82, status: "pattern", source: "google_serp",
                        url: "https://www.google.com/search?q=\(job.company)")
                contact(job, "Neha Kapoor", "Senior Recruiter", .recruiter, confidence: 64, status: "pattern", source: "github",
                        url: "https://github.com/nehak")
            case 8: // replied earlier, read, closed with an outcome
                let c = contact(job, name, title, role, confidence: 93, status: "replied", source: "company_page", url: page(job))
                var t = thread(job, c, state: .replied, updated: ago(120))
                t.outcome = .notInterested
                o.threads[o.threads.count - 1] = t
                message(t, c, state: .sent, body: body(job, c), sentAt: ago(200), at: ago(201))
                message(t, c, state: .received, body: "Hi Asha, thanks for reaching out. We've filled this role, but I'll keep your details on file.",
                        inbound: true, classification: "not_interested", seq: 1, at: ago(120))
            default:
                break // no contact yet
            }
        }
        // A manual contact (a friend) without a thread.
        if let job = applied.dropFirst(9).first ?? applied.last {
            o.contacts.append(ContactItem(id: nextContact, companyID: job.companyID, company: job.company, fullName: "Vikram Joshi",
                                          title: "Product Engineer", roleCategory: .engineer, email: "vikram.joshi@\(domain(job))",
                                          emailStatus: "user", emailConfidence: 100, origin: .user, relationship: .exColleague,
                                          notes: "Worked together at Juspay", createdAt: now.addingTimeInterval(-86_400 * 12)))
            evidence.append(ContactEvidenceItem(id: nextEvidence, contactID: nextContact, kind: "user", field: "email",
                                                observedAt: now.addingTimeInterval(-86_400 * 12)))
            nextContact += 1
            nextEvidence += 1
        }

        // Prospects (company search + watchlist).
        let prospectCompanies: [(String, Int, ProspectStatus, String, String)] = [
            ("Sarvam AI", 88, .shortlisted, "search", "Builds full-stack generative AI for India: speech, translation and LLMs in Indian languages."),
            ("Neon", 81, .suggested, "search", "Serverless Postgres with branching, autoscaling and bottomless storage."),
            ("Modal", 76, .suggested, "watchlist", "Serverless cloud for AI and data teams: run Python functions on GPUs in seconds."),
            ("Hasura", 64, .suggested, "search", "Instant GraphQL and REST APIs on your data."),
        ]
        for (k, p) in prospectCompanies.enumerated() {
            let company = MockFixtures.companies.first { $0.name == p.0 }
            o.prospects.append(ProspectItem(
                id: k + 1, companyID: company?.id ?? 900 + k, company: p.0, domain: company?.domain, status: p.2, fitScore: p.1,
                fitSummary: p.1 >= 80 ? "Close to your backend + ML work; hiring in Bengaluru." : "Some overlap with your API work.",
                fitFactors: ["domain": p.1, "stack": min(100, p.1 + 4), "stage": max(0, p.1 - 10)],
                summary: p.4, summaryURL: company.map { "https://\($0.domain)" }, matchingRoles: [3, 1, 0, 2][k],
                foundVia: p.3, searchQuery: p.3 == "search" ? "AI infra startups in Bengaluru" : nil,
                createdAt: now.addingTimeInterval(-Double(k + 1) * 86_400)))
        }

        // Referrals (the user sends everything on LinkedIn themselves).
        if let target = applied.first {
            let refs: [(String, String, ReferralBasis, String, ReferralState)] = [
                ("Karthik Raman", "Senior Engineer", .alumni, "IIT Madras", .connected),
                ("Nisha Verma", "Engineering Manager", .exColleague, "Juspay", .toConnect),
                ("Ben Ortiz", "Backend Engineer", .sameFunction, "Payments, Bengaluru", .suggested),
                ("Leah Cohen", "Staff Engineer", .alumni, "IIT Madras", .requested),
                ("Farhan Ali", "Platform Engineer", .exColleague, "Juspay", .referred),
            ]
            for (k, r) in refs.enumerated() {
                let slug = r.0.lowercased().replacingOccurrences(of: " ", with: "-")
                o.referrals.append(ReferralItem(
                    id: k + 1, companyID: target.companyID, company: target.company, jobID: target.id, jobTitle: target.title,
                    personName: r.0, title: r.1, linkedinURL: "https://www.linkedin.com/in/\(slug)", basis: r.2, basisDetail: r.3,
                    evidenceURL: "https://www.linkedin.com/in/\(slug)", evidenceSnippet: "\(r.0) – \(r.1) – \(target.company) · \(r.3)",
                    state: r.4,
                    connectNote: k < 2 ? "Hi \(r.0.split(separator: " ")[0]), we both \(r.2 == .alumni ? "studied at \(r.3)" : "worked at \(r.3)"). I'm applying for the \(target.title) role at \(target.company) and would love to connect." : nil,
                    referralDM: k == 0 ? "Hi \(r.0.split(separator: " ")[0]), thanks for connecting! I've applied for the \(target.title) role at \(target.company). Would you be open to referring me? Happy to send my resume and a short note you can forward." : nil,
                    stateUpdatedAt: now.addingTimeInterval(-Double(k + 1) * 30_000), createdAt: now.addingTimeInterval(-Double(k + 2) * 86_400)))
            }
        }

        // Do-not-contact list.
        o.suppression = [
            SuppressionItem(id: 1, emailNorm: "careers@example-ltd.com", reason: .optOut, source: "reply", createdAt: now.addingTimeInterval(-86_400 * 9)),
            SuppressionItem(id: 2, emailNorm: "j.doe@oldco.io", reason: .hardBounce, source: "bounce", createdAt: now.addingTimeInterval(-86_400 * 4)),
            SuppressionItem(id: 3, domain: "staffing-agency.example", reason: .user, source: "you", createdAt: now.addingTimeInterval(-86_400 * 2)),
        ]
        data.outreach = o
        data.contactEvidence = evidence

        // Employer replies: two suggested board moves waiting, one plain acknowledgement.
        let replyJobs = applied.dropFirst(3).prefix(3)
        for (k, job) in replyJobs.enumerated() {
            guard let app = job.applicationID else { continue }
            let rows: [(ApplicationReplyLabel, BoardStatus?, String, String)] = [
                (.interviewInvite, .interview, "Next steps for your \(job.title) application",
                 "Hi Asha, thanks for applying to \(job.company). We'd like to set up a 30-minute call with the team. Could you share a few times that work next week?"),
                (.rejection, .rejected, "Your application to \(job.company)",
                 "Thank you for your interest in \(job.company). After careful review we've decided to move forward with other candidates for this role."),
                (.receivedAck, nil, "We received your application",
                 "Thanks for applying! Our team will review your application and get back to you."),
            ]
            let r = rows[k]
            data.applicationReplies.append(ApplicationReplyItem(
                id: k + 1, applicationID: app, messageID: "<reply-\(k + 1)@\(domain(job))>", fromEmail: "talent@\(domain(job))",
                fromName: "\(job.company) Talent", subject: r.2, snippet: r.3, receivedAt: now.addingTimeInterval(-Double(k + 1) * 5_400),
                label: r.0, suggestedStatus: r.1, suggestionState: r.1 == nil ? .none : .pending))
        }
    }

    // MARK: Commands

    typealias Handled = MockCommandHandler.Handled

    private static func ack(_ result: [String: JSONValue]? = nil) -> DaemonEvent { MockCommandHandler.ack(result) }
    private static func error(_ code: ErrorCode, _ message: String, details: [String: JSONValue]? = nil) -> DaemonEvent {
        .error(ErrorPayload(code: code, message: message, details: details))
    }

    private static func companyName(_ data: RepositoryData, _ id: Int) -> String {
        data.jobs.first { $0.companyID == id }?.company
            ?? data.outreach.prospects.first { $0.companyID == id }?.company
            ?? MockFixtures.companies.first { $0.id == id }?.name ?? "Company \(id)"
    }

    private static func stateEvent(thread: Int, message: Int?, entity: OutreachStatePayload.Entity = .message,
                                   from: String?, to: String) -> DaemonEvent {
        .outreachState(OutreachStatePayload(threadId: thread, messageId: message, entity: entity, fromState: from, toState: to, at: Date()))
    }

    /// Outreach and employer-reply commands; nil for anything else.
    static func handle(_ command: Command, world: MockWorld) -> Handled? {
        let repo = world.repository
        switch command {
        case .scoutContacts(let p):
            let companyID = p.companyId ?? p.applicationId.flatMap { app in repo.read { $0.jobs.first { $0.applicationID == app }?.companyID } } ?? 1
            return Handled(reply: ack(["company_id": .int(companyID), "queued_google": .bool(true)])) { world in
                await world.sleep(1.5)
                let found: Int = world.repository.update { data in
                    let name = companyName(data, companyID)
                    let domain = data.jobs.first { $0.companyID == companyID }?.companyDomain ?? "\(name.lowercased().filter(\.isLetter)).com"
                    let start = (data.outreach.contacts.map(\.id).max() ?? 0) + 1
                    let people = [("Riya Sen", "Recruiter", ContactRoleCategory.recruiter, 86), ("Omar Haddad", "Engineering Manager", .hiringManager, 68)]
                    for (k, person) in people.enumerated() {
                        let parts = person.0.lowercased().split(separator: " ")
                        data.outreach.contacts.append(ContactItem(
                            id: start + k, companyID: companyID, company: name, fullName: person.0, title: person.1, roleCategory: person.2,
                            email: "\(parts[0]).\(parts[1])@\(domain)", emailStatus: "pattern", emailConfidence: person.3, origin: .scout,
                            createdAt: Date()))
                        data.contactEvidence.append(ContactEvidenceItem(id: (data.contactEvidence.map(\.id).max() ?? 0) + 1, contactID: start + k,
                                                                        kind: "company_page", field: "name", url: "https://\(domain)/about",
                                                                        snippet: "\(person.0), \(person.1)", observedAt: Date()))
                    }
                    data.log("outreach", "found 2 people at \(name)")
                    return people.count
                }
                world.emit(.scoutFinished(ScoutFinishedPayload(companyId: companyID, purpose: p.purpose, applicationId: p.applicationId,
                                                               found: found, withEmail: found, bestConfidence: 86, queuedGoogle: true)))
            }

        case .addContact(let p):
            let id: Int = repo.update { data in
                let id = (data.outreach.contacts.map(\.id).max() ?? 0) + 1
                let companyID = p.companyId ?? data.jobs.first { $0.company.caseInsensitiveCompare(p.companyName ?? "") == .orderedSame }?.companyID
                data.outreach.contacts.append(ContactItem(
                    id: id, companyID: companyID, company: companyID.map { companyName(data, $0) } ?? p.companyName, fullName: p.fullName,
                    title: p.title, roleCategory: .other, email: p.email, emailStatus: p.email == nil ? "none" : "user",
                    emailConfidence: p.email == nil ? 0 : 100, origin: .user, relationship: p.relationship, linkedinURL: p.linkedinUrl,
                    notes: p.notes, shareOk: p.shareOk, createdAt: Date()))
                data.contactEvidence.append(ContactEvidenceItem(id: (data.contactEvidence.map(\.id).max() ?? 0) + 1, contactID: id, kind: "user",
                                                                field: "email", observedAt: Date()))
                return id
            }
            return Handled(reply: ack(["contact_id": .int(id), "merged": .bool(false)]))

        case .updateContact(let p):
            let found: Bool = repo.update { data in
                guard let i = data.outreach.contacts.firstIndex(where: { $0.id == p.id }) else { return false }
                if let v = p.fullName { data.outreach.contacts[i].fullName = v }
                if let v = p.title { data.outreach.contacts[i].title = v }
                if let v = p.email { data.outreach.contacts[i].email = v; data.outreach.contacts[i].emailConfidence = 100; data.outreach.contacts[i].emailStatus = "user" }
                if let v = p.notes { data.outreach.contacts[i].notes = v }
                if let v = p.relationship { data.outreach.contacts[i].relationship = v }
                if let v = p.shareOk { data.outreach.contacts[i].shareOk = v }
                return true
            }
            return Handled(reply: found ? ack() : error(.notFound, "contact \(p.id) not found"))

        case .deleteContact(let p):
            let found: Bool = repo.update { data in
                guard let i = data.outreach.contacts.firstIndex(where: { $0.id == p.id }) else { return false }
                let c = data.outreach.contacts.remove(at: i)
                if p.suppress, let email = c.email?.lowercased() {
                    data.outreach.suppression.insert(SuppressionItem(id: (data.outreach.suppression.map(\.id).max() ?? 0) + 1, emailNorm: email,
                                                                     reason: .user, source: "deleted contact", createdAt: Date()), at: 0)
                }
                for t in data.outreach.threads.indices where data.outreach.threads[t].contactID == c.id && data.outreach.threads[t].state == .draft {
                    data.outreach.threads[t].state = .cancelled
                }
                return true
            }
            return Handled(reply: found ? ack() : error(.notFound, "contact \(p.id) not found"))

        case .deleteContacts(let p):
            // Same selection rules as the daemon (protocol.md §5.1): filters AND; typed / imported
            // contacts only by id or `all`; contacts in a live conversation are skipped.
            guard p.all || p.ids != nil || p.olderThanDays != nil else {
                return Handled(reply: error(.invalidPayload, "give ids, older_than_days or all"))
            }
            let counts: (Int, Int) = repo.update { data in
                let cutoff = p.olderThanDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
                let live = Set(data.outreach.threads.filter { $0.state == .active }.compactMap(\.contactID))
                var deleted = 0, skipped = 0
                data.outreach.contacts.removeAll { c in
                    let selected = p.all || ((p.ids.map { $0.contains(c.id) } ?? (c.origin != .user && c.origin != .import))
                        && (cutoff.map { c.createdAt < $0 } ?? true))
                    guard selected else { return false }
                    if live.contains(c.id) { skipped += 1; return false }
                    deleted += 1
                    return true
                }
                return (deleted, skipped)
            }
            return Handled(reply: ack(["deleted": .int(counts.0), "skipped_active": .int(counts.1)]))

        case .acceptOutreachSuggestion(let p):
            // The mock world keeps no thread suggestions yet.
            return Handled(reply: error(.conflict, "thread \(p.threadId) has no pending suggestion"))

        case .dismissOutreachSuggestion:
            return Handled(reply: ack())

        case .markApplicationReplyRead:
            return Handled(reply: ack())

        case .importContacts(let p):
            guard p.filePath.lowercased().hasSuffix(".csv") else { return Handled(reply: error(.invalidPayload, "choose a .csv file")) }
            return Handled(reply: ack(["added": .int(0), "merged": .int(0), "skipped": .int(0)]))

        case .draftOutreach(let p):
            if p.kind == .application && p.applicationId == nil {
                return Handled(reply: error(.invalidPayload, "application_id is required for an application email"))
            }
            let result: (Int, Int)? = repo.update { data in
                guard let c = data.outreach.contacts.first(where: { $0.id == p.contactId }), let companyID = c.companyID else { return nil }
                let job = p.applicationId.flatMap { app in data.jobs.first { $0.applicationID == app } }
                let now = Date()
                let first = c.fullName.split(separator: " ").first.map(String.init) ?? c.fullName
                let body = p.kind == .prospect
                    ? "Hi \(first),\n\nI've followed \(c.company ?? "your team")'s work and I build backend and ML systems in Go and Python. Would you be open to a 15-minute chat about the team, or a pointer to the right person?\n\nThanks,\nAsha"
                    : "Hi \(first),\n\nI applied for the \(job?.title ?? "open") role at \(c.company ?? "your company") this week. I build backend systems in Go and Python and would love to bring that to your team.\n\nWould you be open to a 15-minute chat?\n\nThanks,\nAsha"
                let threadIndex = data.outreach.threads.firstIndex { t in
                    t.state == .draft && (p.applicationId != nil ? t.applicationID == p.applicationId : (t.companyID == companyID && t.kind == p.kind))
                }
                let threadID: Int
                if let ti = threadIndex {
                    data.outreach.threads[ti].contactID = c.id
                    data.outreach.threads[ti].updatedAt = now
                    threadID = data.outreach.threads[ti].id
                    for mi in data.outreach.messages.indices where data.outreach.messages[mi].threadID == threadID && data.outreach.messages[mi].state == .draft {
                        data.outreach.messages[mi].state = .cancelled
                    }
                    data.outreach.messages.removeAll { $0.threadID == threadID && $0.state == .cancelled }
                } else {
                    threadID = (data.outreach.threads.map(\.id).max() ?? 0) + 1
                    data.outreach.threads.append(OutreachThreadItem(
                        id: threadID, kind: p.kind, contactID: c.id, companyID: companyID, company: c.company ?? companyName(data, companyID),
                        jobID: job?.id, applicationID: p.applicationId, state: .draft,
                        subject: job.map { "\($0.title) application – Asha Rao" } ?? "Backend engineer – Asha Rao", createdAt: now, updatedAt: now))
                }
                let messageID = (data.outreach.messages.map(\.id).max() ?? 0) + 1
                let subject = data.outreach.threads.first { $0.id == threadID }?.subject
                data.outreach.messages.append(OutreachMessageItem(
                    id: messageID, threadID: threadID, kind: p.kind == .prospect ? "prospect" : "application_followup", state: .draft,
                    toEmail: c.email, fromEmail: mailbox, subject: subject, body: body,
                    footer: footer(c.origin == .user ? "a mutual contact" : "the \(c.company ?? "company") website"),
                    createdAt: now, updatedAt: now))
                data.log("outreach", "drafted an email to \(c.fullName) at \(c.company ?? "")")
                return (threadID, messageID)
            }
            guard let result else { return Handled(reply: error(.notFound, "contact \(p.contactId) not found")) }
            return Handled(reply: ack(["thread_id": .int(result.0), "message_id": .int(result.1), "grounded": .bool(true),
                                       "unsupported_claims": .array([])]))

        case .editOutreachDraft(let p):
            let result: (Bool, [String])? = repo.update { data in
                guard let i = data.outreach.messages.firstIndex(where: { $0.id == p.messageId }), data.outreach.messages[i].state == .draft else { return nil }
                let claims = data.outreach.messages[i].unsupportedClaims.filter { p.body.localizedCaseInsensitiveContains($0) }
                data.outreach.messages[i].body = p.body
                if let s = p.subject { data.outreach.messages[i].subject = s }
                data.outreach.messages[i].origin = "user"
                data.outreach.messages[i].unsupportedClaims = claims
                data.outreach.messages[i].grounded = claims.isEmpty
                if p.confirmClaims { data.outreach.messages[i].claimsOverridden = true }
                data.outreach.messages[i].updatedAt = Date()
                return (claims.isEmpty, claims)
            }
            guard let result else { return Handled(reply: error(.illegalTransition, "message \(p.messageId) is not a draft")) }
            return Handled(reply: ack(["grounded": .bool(result.0), "unsupported_claims": .array(result.1.map { .string($0) })]))

        case .approveOutreach(let p):
            let account = repo.read { $0.outreach.mailAccount }
            guard account.isConnected else { return Handled(reply: error(.unavailable, "connect your mailbox first (Settings ▸ Outreach)")) }
            guard account.sendEnabled else {
                return Handled(reply: error(.unavailable, "sending is off: turn on 'Enable sending' (it sends you a test email first)"))
            }
            let minConfidence = world.read { $0.preferences.outreachMinEmailConfidence }
            var problems: [String: [Int]] = [:]
            var bad: (Int, String)?
            repo.read { data in
                for id in p.messageIds {
                    guard let m = data.outreach.messages.first(where: { $0.id == id }), !m.isInbound, m.state == .draft else {
                        bad = (id, data.outreach.messages.first { $0.id == id }?.state.rawValue ?? "missing"); return
                    }
                    let t = data.outreach.threads.first { $0.id == m.threadID }
                    let suppressed = data.outreach.suppression.contains { s in
                        guard let to = m.toEmail?.lowercased() else { return false }
                        return s.emailNorm == to || s.domain.map { to.hasSuffix("@\($0)") } == true
                    }
                    if !m.grounded && !m.claimsOverridden { problems["ungrounded", default: []].append(id); continue }
                    if m.toEmail == nil || suppressed { problems["do_not_contact", default: []].append(id); continue }
                    if let t, ![OutreachThreadState.draft, .active].contains(t.state) { problems["thread_closed", default: []].append(id); continue }
                    if let cid = t?.contactID, m.seq == 0, !p.sendAnyway.contains(id),
                       let c = data.outreach.contacts.first(where: { $0.id == cid }), c.emailConfidence < minConfidence {
                        problems["low_confidence", default: []].append(id)
                    }
                }
            }
            if let bad { return Handled(reply: error(.illegalTransition, "message \(bad.0) is \(bad.1), not a draft")) }
            if !problems.isEmpty {
                var parts: [String] = []
                if problems["ungrounded"] != nil { parts.append("some drafts have claims the fact check could not find (edit them, or confirm they are true)") }
                if problems["low_confidence"] != nil { parts.append("some addresses are below your confidence bar (use 'Send anyway' for each)") }
                if problems["do_not_contact"] != nil { parts.append("some recipients are on the do-not-contact list") }
                if problems["thread_closed"] != nil { parts.append("some conversations are already closed") }
                return Handled(reply: error(.conflict, parts.joined(separator: "; "),
                                            details: problems.mapValues { .array($0.map { .int($0) }) }))
            }
            let now = Date()
            let f = ISO8601DateFormatter()
            var scheduled: [JSONValue] = []
            var events: [DaemonEvent] = []
            repo.update { data in
                for (k, id) in p.messageIds.enumerated() {
                    guard let i = data.outreach.messages.firstIndex(where: { $0.id == id }) else { continue }
                    let at = now.addingTimeInterval(600 + Double(k) * 360)
                    data.outreach.messages[i].state = .scheduled
                    data.outreach.messages[i].sendAt = at
                    data.outreach.messages[i].updatedAt = now
                    let tid = data.outreach.messages[i].threadID
                    if p.includeFollowups, let ti = data.outreach.threads.firstIndex(where: { $0.id == tid }) {
                        data.outreach.threads[ti].followupApproved = true
                    }
                    scheduled.append(.object(["message_id": .int(id), "send_at": .string(f.string(from: at))]))
                    events.append(stateEvent(thread: tid, message: id, from: "draft", to: "approved"))
                    events.append(stateEvent(thread: tid, message: id, from: "approved", to: "scheduled"))
                }
                data.log("user", "approved \(p.messageIds.count) email(s) to send", actor: .user)
            }
            let day = f.string(from: now).prefix(10)
            let emitted = events
            return Handled(reply: ack(["batch_uid": .string("mockbatch\(Int(now.timeIntervalSince1970))"), "scheduled": .array(scheduled),
                                       "days": .array([.object(["date": .string(String(day)), "count": .int(p.messageIds.count)])])])) { world in
                for e in emitted { world.emit(e) }
            }

        case .cancelOutreach(let p):
            var events: [DaemonEvent] = []
            let n: Int = repo.update { data in
                var n = 0
                for id in p.messageIds {
                    guard let i = data.outreach.messages.firstIndex(where: { $0.id == id }),
                          [.approved, .scheduled].contains(data.outreach.messages[i].state) else { continue }
                    events.append(stateEvent(thread: data.outreach.messages[i].threadID, message: id,
                                             from: data.outreach.messages[i].state.rawValue, to: "draft"))
                    data.outreach.messages[i].state = .draft
                    data.outreach.messages[i].sendAt = nil
                    n += 1
                }
                return n
            }
            let emitted = events
            return Handled(reply: ack(["cancelled": .int(n)])) { world in for e in emitted { world.emit(e) } }

        case .discardOutreach(let p):
            let outcome: String? = repo.update { data in
                guard let ti = data.outreach.threads.firstIndex(where: { $0.id == p.threadId }) else { return "missing" }
                if data.outreach.messages.contains(where: { $0.threadID == p.threadId && $0.state == .sent }) { return "sent" }
                data.outreach.threads[ti].state = .cancelled
                data.outreach.messages.removeAll { $0.threadID == p.threadId && !$0.isInbound && $0.state != .sent }
                return nil
            }
            switch outcome {
            case "missing": return Handled(reply: error(.notFound, "thread \(p.threadId) not found"))
            case "sent": return Handled(reply: error(.conflict, "an email in this conversation already went out; close it instead"))
            default:
                return Handled(reply: ack()) { $0.emit(stateEvent(thread: p.threadId, message: nil, entity: .thread, from: "draft", to: "cancelled")) }
            }

        case .resolveOutreachUnknown(let p):
            let tid: Int? = repo.update { data in
                guard let i = data.outreach.messages.firstIndex(where: { $0.id == p.messageId }), data.outreach.messages[i].state == .unknown else { return nil }
                data.outreach.messages[i].state = p.sent ? .sent : .failed
                if p.sent {
                    data.outreach.messages[i].sentAt = data.outreach.messages[i].updatedAt
                    let tid = data.outreach.messages[i].threadID
                    if let ti = data.outreach.threads.firstIndex(where: { $0.id == tid }) { data.outreach.threads[ti].state = .active }
                }
                return data.outreach.messages[i].threadID
            }
            guard let tid else { return Handled(reply: error(.illegalTransition, "message \(p.messageId) is not unknown")) }
            return Handled(reply: ack()) { $0.emit(stateEvent(thread: tid, message: p.messageId, from: "unknown", to: p.sent ? "sent" : "failed")) }

        case .markReplyRead(let p):
            repo.update { data in
                if let i = data.outreach.threads.firstIndex(where: { $0.id == p.threadId }) { data.outreach.threads[i].unreadReply = false }
            }
            return Handled(reply: ack())

        case .setThreadOutcome(let p):
            repo.update { data in
                guard let i = data.outreach.threads.firstIndex(where: { $0.id == p.threadId }) else { return }
                data.outreach.threads[i].outcome = p.outcome
                if p.close { data.outreach.threads[i].state = .closed }
            }
            return Handled(reply: ack())

        case .suppress(let p):
            guard p.email != nil || p.domain != nil else { return Handled(reply: error(.invalidPayload, "give an email or a domain")) }
            repo.update { data in
                let email = p.email?.lowercased().trimmingCharacters(in: .whitespaces)
                let domain = p.domain?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
                guard !data.outreach.suppression.contains(where: { ($0.emailNorm != nil && $0.emailNorm == email) || ($0.domain != nil && $0.domain == domain) }) else { return }
                data.outreach.suppression.insert(SuppressionItem(id: (data.outreach.suppression.map(\.id).max() ?? 0) + 1, emailNorm: email,
                                                                 domain: email == nil ? domain : nil, reason: p.reason, source: "you",
                                                                 createdAt: Date()), at: 0)
                for i in data.outreach.messages.indices where [.approved, .scheduled].contains(data.outreach.messages[i].state) {
                    let to = data.outreach.messages[i].toEmail?.lowercased() ?? ""
                    if to == email || domain.map({ to.hasSuffix("@\($0)") }) == true { data.outreach.messages[i].state = .draft }
                }
            }
            return Handled(reply: ack())

        case .unsuppress(let p):
            let outcome: String? = repo.update { data in
                guard let i = data.outreach.suppression.firstIndex(where: { s in
                    (p.email != nil && s.emailNorm == p.email?.lowercased()) || (p.domain != nil && s.domain == p.domain?.lowercased())
                }) else { return "missing" }
                if data.outreach.suppression[i].reason == .optOut { return "opt_out" }
                data.outreach.suppression.remove(at: i)
                return nil
            }
            switch outcome {
            case "missing": return Handled(reply: error(.notFound, "not on the do-not-contact list"))
            case "opt_out": return Handled(reply: error(.conflict, "they asked not to be emailed; an opt-out can't be removed"))
            default: return Handled(reply: ack())
            }

        case .enableSending(let p):
            let account = repo.read { $0.outreach.mailAccount }
            if !p.enabled {
                repo.update { $0.outreach.mailAccount.sendEnabled = false }
                return Handled(reply: ack(["send_enabled": .bool(false), "test_sent_to": .null]))
            }
            guard let email = account.email, account.isConnected else {
                return Handled(reply: error(.unavailable, "connect your mailbox first (the same app password works for sending)"))
            }
            repo.update { data in
                data.outreach.mailAccount.sendEnabled = true
                data.log("user", "enabled outreach sending from \(email) (test email sent)", actor: .user)
            }
            return Handled(reply: ack(["send_enabled": .bool(true), "test_sent_to": .string(email)]))

        case .searchProspects(let p):
            return Handled(reply: ack(["search_id": .string("mocksearch")])) { world in
                await world.sleep(2)
                world.repository.update { data in
                    let start = (data.outreach.prospects.map(\.id).max() ?? 0) + 1
                    for (k, name) in ["Clickhouse", "Temporal"].enumerated() where !data.outreach.prospects.contains(where: { $0.company == name }) {
                        let company = MockFixtures.companies.first { $0.name == name }
                        data.outreach.prospects.append(ProspectItem(
                            id: start + k, companyID: company?.id ?? 950 + k, company: name, domain: company?.domain, status: .suggested,
                            fitScore: 79 - k * 6, fitSummary: "Matches “\(p.query)”.", summary: "\(name) builds developer infrastructure.",
                            summaryURL: company.map { "https://\($0.domain)" }, matchingRoles: 1, foundVia: "search", searchQuery: p.query,
                            createdAt: Date()))
                    }
                }
            }

        case .addProspect(let p):
            guard p.companyName != nil || p.url != nil else { return Handled(reply: error(.invalidPayload, "give a company name or a website")) }
            let ids: (Int, Int) = repo.update { data in
                let id = (data.outreach.prospects.map(\.id).max() ?? 0) + 1
                let name = p.companyName ?? URL(string: p.url ?? "")?.host()?.split(separator: ".").first.map { $0.capitalized } ?? "Company"
                let companyID = MockFixtures.companies.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id ?? 2_000 + id
                data.outreach.prospects.append(ProspectItem(id: id, companyID: companyID, company: name, domain: p.url.flatMap { URL(string: $0)?.host() },
                                                            status: .suggested, summaryURL: p.url, foundVia: "user", createdAt: Date()))
                return (id, companyID)
            }
            return Handled(reply: ack(["prospect_id": .int(ids.0), "company_id": .int(ids.1)]))

        case .updateProspect(let p):
            let found: Bool = repo.update { data in
                guard let i = data.outreach.prospects.firstIndex(where: { $0.id == p.id }) else { return false }
                if let s = p.status { data.outreach.prospects[i].status = s }
                if let watch = p.watch { data.outreach.prospects[i].watched = watch }
                return true
            }
            return Handled(reply: found ? ack() : error(.notFound, "prospect \(p.id) not found"))

        case .suggestReferrers(let p):
            return Handled(reply: ack(["queued_google": .bool(true)])) { world in
                await world.sleep(2)
                world.repository.update { data in
                    let id = (data.outreach.referrals.map(\.id).max() ?? 0) + 1
                    data.outreach.referrals.append(ReferralItem(
                        id: id, companyID: p.companyId, company: companyName(data, p.companyId), jobID: p.jobId, personName: "Aditi Sharma",
                        title: "Software Engineer", linkedinURL: "https://www.linkedin.com/in/aditi-sharma", basis: .alumni,
                        basisDetail: "IIT Madras", evidenceSnippet: "Aditi Sharma – Software Engineer · IIT Madras", state: .suggested,
                        stateUpdatedAt: Date(), createdAt: Date()))
                }
            }

        case .addReferral(let p):
            guard let companyID = p.companyId ?? p.contactId.flatMap({ cid in repo.read { $0.outreach.contacts.first { $0.id == cid }?.companyID } }) else {
                return Handled(reply: error(.invalidPayload, "pick a company"))
            }
            let id: Int = repo.update { data in
                let id = (data.outreach.referrals.map(\.id).max() ?? 0) + 1
                let contact = p.contactId.flatMap { cid in data.outreach.contacts.first { $0.id == cid } }
                data.outreach.referrals.append(ReferralItem(
                    id: id, companyID: companyID, company: companyName(data, companyID), jobID: p.jobId,
                    jobTitle: p.jobId.flatMap { jid in data.jobs.first { $0.id == jid }?.title }, contactID: p.contactId,
                    personName: p.personName ?? contact?.fullName ?? "Someone", title: p.title ?? contact?.title,
                    linkedinURL: p.linkedinUrl ?? contact?.linkedinURL, basis: p.basis, basisDetail: p.basisDetail, state: .toConnect,
                    stateUpdatedAt: Date(), createdAt: Date()))
                return id
            }
            return Handled(reply: ack(["referral_id": .int(id), "created": .bool(true)]))

        case .draftReferral(let p):
            let texts: (String, String)? = repo.update { data in
                guard let i = data.outreach.referrals.firstIndex(where: { $0.id == p.id }) else { return nil }
                let r = data.outreach.referrals[i]
                let first = r.personName.split(separator: " ").first.map(String.init) ?? r.personName
                let note = "Hi \(first), \(r.basis == .alumni ? "fellow \(r.basisDetail ?? "alum") here" : "we share \(r.basisDetail ?? "a background")"). I'm applying to \(r.company) and would love to connect."
                let dm = "Hi \(first), thanks for connecting! I've applied for \(r.jobTitle.map { "the \($0) role" } ?? "a role") at \(r.company). Would you be open to referring me? I can send my resume and a two-line summary you can forward."
                data.outreach.referrals[i].connectNote = String(note.prefix(300))
                data.outreach.referrals[i].referralDM = dm
                return (String(note.prefix(300)), dm)
            }
            guard let texts else { return Handled(reply: error(.notFound, "referral \(p.id) not found")) }
            return Handled(reply: ack(["connect_note": .string(texts.0), "referral_dm": .string(texts.1), "grounded": .bool(true),
                                       "unsupported_claims": .array([])]))

        case .updateReferral(let p):
            let outcome: String? = repo.update { data in
                guard let i = data.outreach.referrals.firstIndex(where: { $0.id == p.id }) else { return "missing" }
                if let note = p.connectNote {
                    guard note.count <= 300 else { return "too_long" }
                    data.outreach.referrals[i].connectNote = note
                }
                if let dm = p.referralDm { data.outreach.referrals[i].referralDM = dm }
                if let s = p.state, s != data.outreach.referrals[i].state {
                    guard data.outreach.referrals[i].state.nextStates.contains(s) else { return "illegal:\(data.outreach.referrals[i].state.rawValue)" }
                    data.outreach.referrals[i].state = s
                    data.outreach.referrals[i].stateUpdatedAt = Date()
                }
                return nil
            }
            switch outcome {
            case nil: return Handled(reply: ack())
            case "missing": return Handled(reply: error(.notFound, "referral \(p.id) not found"))
            case "too_long": return Handled(reply: error(.invalidPayload, "a connection note is at most 300 characters"))
            default: return Handled(reply: error(.illegalTransition, "referral \(p.id) can't move from \(outcome!.dropFirst(8))"))
            }

        case .setProviderKey(let p):
            let ok = p.apiKey.map { $0.count >= 10 } ?? true
            if !ok { return Handled(reply: error(.unavailable, "Hunter didn't accept that key")) }
            return Handled(reply: ack(["provider": .string(p.provider.rawValue), "ok": .bool(true)]))

        case .acceptReplySuggestion(let p):
            let moved: (Int, Int, BoardStatus?, BoardStatus)? = repo.update { data in
                guard let ri = data.applicationReplies.firstIndex(where: { $0.id == p.replyId }), data.applicationReplies[ri].isPendingSuggestion,
                      let target = data.applicationReplies[ri].suggestedStatus,
                      let ji = data.jobIndex(applicationID: data.applicationReplies[ri].applicationID) else { return nil }
                data.applicationReplies[ri].suggestionState = .accepted
                let previous = data.jobs[ji].status
                data.jobs[ji].status = target
                data.jobs[ji].statusUpdatedAt = Date()
                data.log("status", "moved to \(target.label) (from an employer reply)", actor: .user, jobID: data.jobs[ji].id,
                         applicationID: data.applicationReplies[ri].applicationID)
                return (data.applicationReplies[ri].applicationID, data.jobs[ji].id, previous, target)
            }
            guard let moved else { return Handled(reply: error(.conflict, "reply \(p.replyId) has no pending suggestion")) }
            return Handled(reply: ack(["reply_id": .int(p.replyId), "application_id": .int(moved.0), "status": .string(moved.3.rawValue)])) { world in
                world.emit(.applicationStatus(ApplicationStatusPayload(applicationId: moved.0, jobId: moved.1, previousStatus: moved.2,
                                                                       status: moved.3, actor: .user, at: Date())))
            }

        case .dismissReplySuggestion(let p):
            repo.update { data in
                if let i = data.applicationReplies.firstIndex(where: { $0.id == p.replyId }), data.applicationReplies[i].suggestionState == .pending {
                    data.applicationReplies[i].suggestionState = .dismissed
                }
            }
            return Handled(reply: ack())

        default:
            return nil
        }
    }
}
