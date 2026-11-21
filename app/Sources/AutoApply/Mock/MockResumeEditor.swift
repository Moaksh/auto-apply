// MockResumeEditor.swift — the daemon's resume editor (contract/protocol.md §5.6) against the mock
// world, so "Edit with Claude" works in mock mode, previews and tests. Attaching a source gives the
// resume segments built from the profile; Claude's edits are deterministic: tailoring for a job
// moves the JD's skills to the front of the skills line, "shorter" trims filler, "add a metric"
// invents a number (which is flagged, like the real fact check). Saving makes the next version.
import Foundation

enum MockResumeEditor {
    typealias Handled = MockCommandHandler.Handled

    static func handle(_ command: Command, world: MockWorld) -> Handled {
        switch command {
        case .attachResumeSource(let p):
            guard let variant = variant(p.id, world) else { return notFound(p.id) }
            let ext = (p.filePath as NSString).pathExtension.lowercased()
            guard let kind = ["html": "html", "htm": "html", "tex": "latex", "docx": "docx"][ext] else {
                return Handled(reply: MockCommandHandler.error(.invalidPayload, "The editable source must be an .html, .tex or .docx file."))
            }
            let profile = world.repository.read { $0.profile }
            world.mutate { $0.resumeSources[variant.id] = segments(from: profile) }
            world.repository.update { data in
                if let i = data.resumeVariants.firstIndex(where: { $0.id == variant.id }) { data.resumeVariants[i].sourceKind = kind }
            }
            return Handled(reply: MockCommandHandler.ack(encoding: source(variant.id, kind: kind, fileName: (p.filePath as NSString).lastPathComponent, world)))
        case .getResumeSource(let p):
            guard let variant = variant(p.id, world), let kind = variant.sourceKind else {
                return Handled(reply: MockCommandHandler.error(.notFound, "This resume has no editable source yet. Attach the .docx, .tex or .html it was made from."))
            }
            return Handled(reply: MockCommandHandler.ack(encoding: source(variant.id, kind: kind, fileName: "resume.\(kind == "latex" ? "tex" : kind)", world)))
        case .proposeResumeEdits(let p):
            guard var segs = segments(p.id, world) else { return notFound(p.id) }
            for w in p.working { if let i = segs.firstIndex(where: { $0.id == w.segmentId }) { segs[i].text = w.text } }
            let (profile, job) = world.repository.read { d in (d.profile, p.jobId.flatMap { id in d.jobs.first { $0.id == id } }) }
            let edits = propose(segs, instructions: p.instructions, job: job, profile: profile)
            let summary = edits.isEmpty ? "Nothing to change for that: the resume already reads that way."
                : job.map { "Moved what \($0.company) asks for to the front." } ?? "Rewrote \(edits.count) line\(edits.count == 1 ? "" : "s") as you asked."
            let result = ResumeEditProposal(resumeVariantId: p.id, jobId: p.jobId, summary: summary, edits: edits,
                                            grounded: edits.allSatisfy(\.unsupportedClaims.isEmpty), tokensIn: 2_400, tokensOut: 380)
            return Handled(reply: MockCommandHandler.ack(encoding: result))
        case .previewResumeEdit(let p):
            // No renderer in mock mode: the resume's own (fixture) PDF.
            guard let v = variant(p.id, world) else { return notFound(p.id) }
            return Handled(reply: MockCommandHandler.ack(encoding: ResumePreview(filePath: v.filePath, pages: 1)))
        case .saveResumeEdit(let p):
            guard let old = variant(p.id, world), var segs = segments(p.id, world) else { return notFound(p.id) }
            if old.replacedBy != nil {
                return Handled(reply: MockCommandHandler.error(.invalidPayload, "This is an older version; edit the current one."))
            }
            for e in p.edits {
                guard let i = segs.firstIndex(where: { $0.id == e.segmentId }) else {
                    return Handled(reply: MockCommandHandler.error(.invalidPayload, "unknown segment(s): \(e.segmentId)"))
                }
                segs[i].text = e.text
            }
            let id: Int = world.read { $0.nextResumeID }
            world.mutate { $0.nextResumeID += 1; $0.resumeSources[id] = segs }
            let version = p.asNew ? 1 : old.version + 1
            world.repository.update { data in
                var new = old
                new.id = id
                new.version = version
                new.replacedBy = nil
                new.createdAt = Date()
                new.updatedAt = Date()
                if p.asNew {
                    let label = p.label?.trimmingCharacters(in: .whitespaces) ?? ""
                    new.label = label.isEmpty ? "\(old.label) (edited)" : label
                    new.isDefault = false
                } else if let i = data.resumeVariants.firstIndex(where: { $0.id == old.id }) {
                    data.resumeVariants[i].replacedBy = id
                    data.resumeVariants[i].enabled = false
                    data.resumeVariants[i].isDefault = false
                }
                data.resumeVariants.append(new)
            }
            return Handled(reply: MockCommandHandler.ack(encoding: SaveResumeEditResult(resumeVariantId: id, filePath: old.filePath,
                                                                                        version: version, pages: 1)))
        default:
            return Handled(reply: MockCommandHandler.error(.unknownType, "not a resume editor command"))
        }
    }

    private static func variant(_ id: Int, _ world: MockWorld) -> ResumeVariantItem? {
        world.repository.read { $0.resumeVariants.first { $0.id == id } }
    }

    /// The variant's segments: attached in this session, else built from the profile for a resume
    /// that came with a source (the fixtures' Backend resume).
    private static func segments(_ id: Int, _ world: MockWorld) -> [ResumeSegment]? {
        if let segs = world.read({ $0.resumeSources[id] }) { return segs }
        guard variant(id, world)?.sourceKind != nil else { return nil }
        let segs = segments(from: world.repository.read { $0.profile })
        world.mutate { $0.resumeSources[id] = segs }
        return segs
    }

    private static func notFound(_ id: Int) -> Handled {
        Handled(reply: MockCommandHandler.error(.notFound, "resume variant \(id) has no source"))
    }

    private static func source(_ id: Int, kind: String, fileName: String, _ world: MockWorld) -> ResumeSource {
        ResumeSource(resumeVariantId: id, kind: ResumeSource.Kind(rawValue: kind) ?? .html, fileName: fileName,
                     segments: segments(id, world) ?? [], renderer: kind == "docx" ? "Microsoft Word" : kind == "latex" ? "pdflatex" : "Chromium")
    }

    /// Name, headline, each role's highlights, then the skills line.
    static func segments(from profile: Profile) -> [ResumeSegment] {
        var texts: [String] = [profile.fullName ?? "Your Name"]
        if let h = profile.headline ?? profile.summary { texts.append(h) }
        for role in profile.workHistory {
            texts.append("\(role.title) — \(role.company)")
            texts += role.highlights
        }
        if !profile.skills.isEmpty { texts.append("Skills: " + profile.skills.joined(separator: ", ")) }
        return texts.enumerated().map { ResumeSegment(id: "s\($0.offset + 1)", text: $0.element) }
    }

    /// A highlight line: not the name / headline, a role line ("Title — Company") or the skills line.
    private static func isBullet(_ s: ResumeSegment) -> Bool {
        !s.text.contains(" — ") && !s.text.hasPrefix("Skills: ")
    }

    static func propose(_ segs: [ResumeSegment], instructions: String, job: JobItem?, profile: Profile) -> [ResumeEdit] {
        let ask = instructions.lowercased()
        var edits: [ResumeEdit] = []
        if let job, let skills = segs.last(where: { $0.text.hasPrefix("Skills: ") }) {
            let jd = (job.title + " " + (job.description ?? "")).lowercased()
            let list = skills.text.dropFirst("Skills: ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let ordered = list.filter { jd.contains($0.lowercased()) } + list.filter { !jd.contains($0.lowercased()) }
            if ordered != list {
                edits.append(ResumeEdit(segmentId: skills.id, before: skills.text, after: "Skills: " + ordered.joined(separator: ", "),
                                        reason: "Leads with the skills \(job.company) lists."))
            }
        }
        if ask.contains("short") || ask.contains("tight") || ask.contains("concise") {
            for s in segs.dropFirst(2) where isBullet(s) {
                var t = s.text
                for filler in ["Successfully ", "successfully ", "Responsible for ", "responsible for ", " in order to", " various", " service"] {
                    t = t.replacingOccurrences(of: filler, with: "")
                }
                if t.hasSuffix(".") { t.removeLast() }
                if let comma = t.range(of: ", ", options: .backwards), t.distance(from: t.startIndex, to: comma.lowerBound) > 40 {
                    t = String(t[..<comma.lowerBound]) + "."
                }
                if t != s.text { edits.append(ResumeEdit(segmentId: s.id, before: s.text, after: t, reason: "Tighter.")) }
            }
        }
        if ask.contains("metric") || ask.contains("number"),
           let bullet = segs.dropFirst(2).first(where: { isBullet($0) && !$0.text.contains("%") && !$0.text.contains(where: \.isNumber) }) {
            let after = bullet.text.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + ", cutting costs by 30%."
            edits.append(ResumeEdit(segmentId: bullet.id, before: bullet.text, after: after, reason: "Adds an outcome.",
                                    unsupportedClaims: ["30%"]))
        }
        if edits.isEmpty, !ask.isEmpty, segs.count > 1 {
            let head = segs[1]
            let after = head.text.hasSuffix(".") ? head.text : head.text + "."
            if after != head.text { edits.append(ResumeEdit(segmentId: head.id, before: head.text, after: after, reason: "Reads as a sentence.")) }
        }
        return edits
    }
}
