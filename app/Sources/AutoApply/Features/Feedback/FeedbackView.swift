// FeedbackView.swift — the "Send Feedback" window: bug report or feature request, pre-filled into
// a GitHub issue by IssueReporter (no agent involved). Opened from Help ▸ Report a Bug… /
// Request a Feature… and Settings → General → Feedback.
import SwiftUI

/// Which kind the window opens on (set by the menu item / settings button before opening).
@MainActor
enum FeedbackRequest {
    static var kind: IssueReporter.Kind = .bug
}

struct FeedbackView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var kind: IssueReporter.Kind = FeedbackRequest.kind
    @State private var title = ""
    @State private var details = ""
    @State private var includeLogs = true
    @State private var showPreview = false

    private var env: IssueReporter.Environment {
        .current(connected: store.isConnected, mode: store.mode.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Picker("", selection: $kind) {
                ForEach(IssueReporter.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(kind == .bug ? "Short summary of the bug" : "Short summary of the idea", text: $title)
                .textFieldStyle(.roundedBorder)

            Text(kind == .bug ? "What happened? What did you expect?" : "What would you like, and why?")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            TextEditor(text: $details)
                .font(Typography.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(Space.xs)
                .well()

            if kind == .bug {
                Toggle("Include recent logs (redacted)", isOn: $includeLogs).toggleStyle(.checkbox)
                Text("Emails, phone numbers, keys and your home folder are removed. A fuller redacted log file is saved and shown in Finder so you can attach it.")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Preview", isExpanded: $showPreview) {
                ScrollView {
                    Text(previewText)
                        .font(Typography.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(Space.xs)
                .well()
            }

            HStack {
                Text("Opens GitHub in your browser with this filled in. Nothing is sent until you press Submit there.")
                    .font(Typography.callout).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open GitHub Issue") {
                    IssueReporter.open(kind: kind, title: title, description: details,
                                       includeLogs: kind == .bug && includeLogs, env: env)
                    dismissWindow(id: WindowID.feedback)
                }
                .buttonStyle(.secondaryLink)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.l)
        .frame(width: 560)
        .onAppear { kind = FeedbackRequest.kind }
    }

    private var previewText: String {
        let logs = kind == .bug && includeLogs ? IssueReporter.recentLogExcerpt() : nil
        let body = IssueReporter.body(kind: kind, description: details, env: env, logs: logs,
                                      bundleName: kind == .bug && includeLogs ? "AutoApply-logs-<time>.txt" : nil)
        return "Title: \(title.isEmpty ? "(empty)" : title)\nLabel: \(kind.label)\n\n\(body)"
    }
}
