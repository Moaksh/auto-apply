// AddJobSheet.swift — "Add job by link" (⌘N, toolbar, ⌘K): paste any apply link and the daemon
// reads the posting, queues it and starts filling (protocol.md `add_job_url`). Title / company
// are read from the page; the optional fields only override a bad guess.
import AppKit
import SwiftUI

struct AddJobSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    let seed: String
    @State private var url = ""
    @State private var title = ""
    @State private var company = ""
    @State private var applyNow = true
    @State private var showDetails = false
    @State private var isAdding = false
    /// Bumped to shake the link field when Add is tried with a bad link (the one validation error).
    @State private var shake = 0
    @FocusState private var urlFocused: Bool

    private var problem: String? { AddJobLink.problem(url) }
    private var canAdd: Bool { !isAdding && problem == nil && store.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Add job by link", systemImage: "link.badge.plus").font(Typography.title2)
                Text("Paste the company's apply link (Greenhouse, Lever, Ashby, Rippling, Workday or any career page). The agent reads the posting and fills the application.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("https://jobs.example.com/…", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFocused)
                    .onSubmit { Task { await add() } }
                    .errorShake(trigger: shake)
                if !url.isEmpty, let problem {
                    Text(problem).font(Typography.callout).foregroundStyle(Palette.error)
                        .wordSwap(problem)
                        .motionTransition(.rise)
                }
            }

            DisclosureGroup("Title and company (optional)", isExpanded: $showDetails) {
                VStack(spacing: 8) {
                    TextField("Job title — read from the page if empty", text: $title)
                    TextField("Company — read from the page if empty", text: $company)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
            .font(Typography.callout)

            Toggle(isOn: $applyNow) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start filling now")
                    Text(store.isPaused ? "The agent is paused: it will start when you resume."
                         : store.mode == .review ? "Review mode: it waits for your approval before sending."
                         : "Auto mode: it sends on its own when the checks pass, and asks you when it's unsure.")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                if isAdding {
                    Group {
                        ProgressView().controlSize(.small)
                        Text("Reading the posting…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                    .motionTransition(.fade)
                } else if !store.isConnected {
                    Text("Not connected to the agent").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add job") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.primaryPill)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            url = seed.isEmpty ? (AddJobLink.fromPasteboard() ?? "") : seed
            urlFocused = true
        }
    }

    private func add() async {
        // Return with a bad link: say so with the field (the reason is already under it).
        if problem != nil && !isAdding { shake += 1 }
        guard canAdd else { return }
        isAdding = true
        defer { isAdding = false }
        guard let added = await store.addJob(url: url, title: title, company: company, applyNow: applyNow) else { return }
        dismiss()
        router.openJob(id: added.jobId)
    }
}

/// Link validation shared by the sheet and the ⌘K "add this link" row.
enum AddJobLink {
    /// nil when `text` looks like a job link the daemon can take; otherwise a short reason.
    static func problem(_ text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Paste a link" }
        guard let host = url(raw)?.host()?.lowercased(), host.contains(".") else { return "That doesn't look like a link" }
        if host.hasSuffix("linkedin.com") || host.contains("glassdoor.") {
            return "LinkedIn / Glassdoor can't be applied to automatically. Use the company's own apply link (or the Easy Apply list)."
        }
        return nil
    }

    static func isLink(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.contains(" "), raw.contains(".") else { return false }
        return raw.lowercased().hasPrefix("http") && problem(raw) == nil
    }

    static func url(_ raw: String) -> URL? {
        let s = raw.contains("://") ? raw : "https://" + raw
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }

    @MainActor
    static func fromPasteboard() -> String? {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isLink(s) else { return nil }
        return s
    }
}
