// ActivityInspector.swift — inspector for the selected log row: full JSON payload in tinted
// mono, a link to the job, and "Copy diagnostic" for errors (§5.11).
import SwiftUI

struct ActivityInspector: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var model = ActivityLogModel.shared
    @State private var copied = false

    var body: some View {
        if let e = model.selectedEvent {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    HStack(spacing: Space.s) {
                        let tag = ActivityRules.tag(for: e)
                        Text(tag.text.trimmingCharacters(in: .whitespaces))
                            .font(Typography.mono).fontWeight(.semibold)
                            .foregroundStyle(tag.kind?.color ?? Palette.textSecondary)
                        Text(e.ts.formatted(date: .abbreviated, time: .standard)).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
                    }
                    Text(e.message).font(Typography.mono).textSelection(.enabled)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        row("actor", e.actor.rawValue)
                        row("level", e.level.rawValue)
                        if let run = e.runID { row("run", "#\(run)") }
                        if let app = e.applicationID { row("application", "#\(app)") }
                    }
                    if let jobID = e.jobID, let job = store.jobs.job(id: jobID) {
                        Button {
                            router.openJobFromDashboard(jobID)
                        } label: {
                            HStack(spacing: Space.s) {
                                CompanyMonogram(name: job.company)
                                Text(job.displayName).lineLimit(1)
                                Image(systemName: "arrow.up.forward")
                            }
                        }
                        .buttonStyle(.link)
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Payload").eyebrowStyle()
                        JSONText(json: ActivityRules.prettyJSON(e.payload))
                            .padding(Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sunkenWell()
                    }
                    if ActivityRules.isError(e) {
                        Button {
                            model.copyDiagnostic(e, jobLabel: e.jobID.flatMap { store.jobs.job(id: $0)?.displayName })
                            copied = true
                            store.toasts.show("Copied diagnostic", symbol: "checkmark", style: .success)
                        } label: {
                            Label(copied ? "Copied" : "Copy diagnostic", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(Space.l)
            }
            .onChange(of: e.id) { copied = false }
        } else {
            EmptyState(symbol: "sidebar.right", title: "No event selected", message: "Select a row to see its full payload.")
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary).frame(width: 84, alignment: .leading)
            Text(value).font(Typography.monoSmall)
        }
    }
}

/// Syntax-tinted JSON: keys in accent, strings secondary, numbers/bools/null in the queued hue.
struct JSONText: View {
    var json: String

    var body: some View {
        Text(JSONHighlighter.attributed(json))
            .font(Typography.mono)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum JSONHighlighter {
    enum TokenKind: Equatable { case key, string, literal, punctuation }

    /// Tokenize pretty-printed JSON into (text, kind) runs.
    static func tokens(_ json: String) -> [(String, TokenKind)] {
        var out: [(String, TokenKind)] = []
        let chars = Array(json)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "\"" { break }
                    j += 1
                }
                let end = min(j, chars.count - 1)
                let text = String(chars[i...end])
                // A key is a string followed (after spaces) by a colon.
                var k = end + 1
                while k < chars.count, chars[k] == " " { k += 1 }
                out.append((text, k < chars.count && chars[k] == ":" ? .key : .string))
                i = end + 1
            } else if c.isNumber || c == "-" || c == "t" || c == "f" || c == "n" {
                var j = i
                while j < chars.count, !",}] \n".contains(chars[j]) { j += 1 }
                out.append((String(chars[i..<j]), .literal))
                i = j
            } else {
                var j = i
                while j < chars.count, chars[j] != "\"", !(chars[j].isNumber || chars[j] == "-" || chars[j] == "t" || chars[j] == "f" || chars[j] == "n") { j += 1 }
                if j == i { j += 1 }
                out.append((String(chars[i..<j]), .punctuation))
                i = j
            }
        }
        return out
    }

    static func attributed(_ json: String) -> AttributedString {
        var result = AttributedString()
        for (text, kind) in tokens(json) {
            var run = AttributedString(text)
            switch kind {
            case .key: run.foregroundColor = Palette.accent
            case .string: run.foregroundColor = Palette.textSecondary
            case .literal: run.foregroundColor = Palette.queued
            case .punctuation: run.foregroundColor = Palette.textTertiary
            }
            result += run
        }
        return result
    }
}
