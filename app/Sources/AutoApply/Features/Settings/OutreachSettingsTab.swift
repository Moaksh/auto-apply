// OutreachSettingsTab.swift — Settings ▸ Outreach (docs/COLD_EMAIL_PLAN.md §C, §G.6): sending
// (on only after a test email to yourself goes through), the daily limit, send window, weekdays
// only, follow-ups, the email confidence bar, what happens after each application, the people
// finder's daily Google budget, the Hunter key (Keychain only, never shown back), the
// do-not-contact list (opt-outs can't be removed) and deleting contacts. Preference fields
// auto-save through the shared draft like every other tab.
import SwiftUI

struct OutreachSettingsTab: View {
    @Bindable var model: SettingsModel
    @Environment(AppStore.self) private var store

    var body: some View {
        SendingSettingsRow()
        SettingsRow("New emails a day",
                    help: "First emails to new people. Follow-ups count separately (up to twice this). A new mailbox ramps up over its first week.",
                    issue: model.issue(for: .outreachDailyCap)) {
            Stepper("\(model.preferencesDraft.outreachDailyCap) a day", value: $model.preferencesDraft.outreachDailyCap, in: 0...40)
                .monospacedDigit()
            Text("Sent today: \(store.snapshotCaps.outreachSentToday)").font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
        SettingsRow("Send window", help: "Emails go out a few minutes apart inside this window, in your time zone.",
                    issue: model.issue(for: .outreachSendWindow)) {
            HStack(spacing: Space.s) {
                Picker("From", selection: windowBinding(0)) { ForEach(Self.times, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 90)
                Text("to").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Picker("To", selection: windowBinding(1)) { ForEach(Self.times, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 90)
            }
            Toggle("Weekdays only", isOn: $model.preferencesDraft.outreachWeekdaysOnly).toggleStyle(.checkbox)
        }
        SettingsRow("Follow-ups",
                    help: "A follow-up is sent only if you approved it with the first email; otherwise it comes back to the Outbox as a draft. It stops if they reply, bounce or ask not to be emailed.",
                    issue: model.issue(for: .outreachMaxFollowups) ?? model.issue(for: .outreachFollowupDays)) {
            Stepper(model.preferencesDraft.outreachMaxFollowups == 0 ? "No follow-ups"
                    : "At most \(C3Format.plural(model.preferencesDraft.outreachMaxFollowups, "follow-up")) per person",
                    value: $model.preferencesDraft.outreachMaxFollowups, in: 0...2)
            Stepper("After \(model.preferencesDraft.outreachFollowupDays) business days without a reply",
                    value: $model.preferencesDraft.outreachFollowupDays, in: 1...30)
                .disabled(model.preferencesDraft.outreachMaxFollowups == 0)
        }
        SettingsRow("Email confidence", help: "Addresses below this need a “Send anyway” from you. Verified ≥ 90, Likely 70–89, Guess 40–69.",
                    issue: model.issue(for: .outreachMinEmailConfidence)) {
            HStack(spacing: Space.m) {
                Slider(value: Binding(get: { Double(model.preferencesDraft.outreachMinEmailConfidence) },
                                      set: { model.preferencesDraft.outreachMinEmailConfidence = Int($0.rounded()) }), in: 0...100, step: 5)
                    .frame(maxWidth: 240)
                Text("\(model.preferencesDraft.outreachMinEmailConfidence) · \(EmailTier(confidence: model.preferencesDraft.outreachMinEmailConfidence).label)")
                    .font(Typography.metricSmall).monospacedDigit()
            }
        }
        SettingsRow("After each application",
                    help: "Finding people uses Google results and model time. Drafts wait in Cold Email ▸ Outbox; nothing is sent without your approval.") {
            Toggle("Find people at the company", isOn: $model.preferencesDraft.outreachAutoScout)
            Toggle("Draft a note to the best match for your review", isOn: $model.preferencesDraft.outreachAutoDraft)
                .disabled(!model.preferencesDraft.outreachAutoScout)
        }
        SettingsRow("People finder", help: "Google result pages read per day to find people and companies. LinkedIn is never opened.",
                    issue: model.issue(for: .peopleFinderVisitsPerDay)) {
            Stepper("\(model.preferencesDraft.peopleFinderVisitsPerDay) result pages a day", value: $model.preferencesDraft.peopleFinderVisitsPerDay, in: 0...30)
                .monospacedDigit()
            Text("Used today: \(store.snapshotCaps.peopleFinderUsed) of \(store.snapshotCaps.peopleFinderLimit)")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
        HunterKeyRow()
        Divider()
        SuppressionListRow()
        ContactDataRow()
    }

    /// Half-hour steps, 06:00–22:00.
    static let times: [String] = stride(from: 6 * 60, through: 22 * 60, by: 30).map { ScheduleTimes.format(hour: $0 / 60, minute: $0 % 60) }

    private func windowBinding(_ i: Int) -> Binding<String> {
        Binding(get: {
            let w = model.preferencesDraft.outreachSendWindow
            return w.count == 2 ? w[i] : (i == 0 ? "09:30" : "17:30")
        }, set: { new in
            var w = model.preferencesDraft.outreachSendWindow
            if w.count != 2 { w = ["09:30", "17:30"] }
            w[i] = new
            model.preferencesDraft.outreachSendWindow = w
        })
    }
}

/// Mailbox status and the sending switch. Turning it on sends a test email to yourself first.
private struct SendingSettingsRow: View {
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        let account = store.outreach.mailAccount
        let cold = ColdEmailModel.shared(for: store)
        SettingsRow("Sending", help: "Plain-text email from your own Gmail, after you approve each batch. No tracking pixels, no link rewriting.") {
            if !account.isConnected {
                Text("No mailbox connected. Connect your Gmail in Sources (the same app password is used for sending).")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Go to Sources") { SettingsNavigation.shared.tab = .sources }.buttonStyle(.secondaryLink)
            } else {
                HStack(spacing: Space.s) {
                    StatusDot(kind: account.sendEnabled ? .applied : .skipped)
                    Text(account.sendEnabled ? "On · from \(account.email ?? "")" : "Off · \(account.email ?? "")").font(Typography.body)
                    Spacer()
                    if account.sendEnabled {
                        Button("Turn off") {
                            busy = true
                            Task { _ = await store.enableSending(false); busy = false }
                        }
                        .disabled(busy || !store.isConnected)
                    } else {
                        Button(cold.enableState == .testing ? "Sending test…" : "Send a test email and turn on") {
                            Task { await cold.enableSending() }
                        }
                        .buttonStyle(.secondaryLink)
                        .disabled(cold.enableState == .testing || !store.isConnected)
                    }
                }
                switch cold.enableState {
                case .enabled(let to):
                    Label("Test email sent to \(to). Sending is on.", systemImage: "checkmark.circle.fill")
                        .font(Typography.callout).foregroundStyle(Palette.applied)
                case .failed(let message):
                    Label(message, systemImage: StatusKind.error.symbol).font(Typography.callout).foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                case .testing, .idle:
                    EmptyView()
                }
                if let profileEmail = store.library.profile.email, let mailbox = account.email,
                   profileEmail.caseInsensitiveCompare(mailbox) != .orderedSame {
                    Text("Replies will go to the mailbox you connected (\(mailbox)), not \(profileEmail).")
                        .font(Typography.callout).foregroundStyle(Palette.needsYou)
                }
            }
        }
    }
}

/// Hunter: an optional email-lookup provider. The key is checked, then kept in the Keychain only.
private struct HunterKeyRow: View {
    @Environment(AppStore.self) private var store
    @State private var key = ""
    @State private var busy = false
    @State private var message: String?
    @State private var ok = false

    var body: some View {
        SettingsRow("Hunter key", help: "Optional. Looks up published work emails when the agent can't find one. Stored in your Mac's Keychain; it's never shown here again.") {
            HStack(spacing: Space.s) {
                SecureField("Paste a Hunter API key", text: $key).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Button(busy ? "Checking…" : "Save") { save(key) }
                    .disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty || !store.isConnected)
                Button("Remove") { save(nil) }
                    .buttonStyle(.secondaryLink)
                    .disabled(busy || !store.isConnected)
            }
            if let message {
                Text(message).font(Typography.callout).foregroundStyle(ok ? Palette.applied : Palette.error)
            }
        }
    }

    private func save(_ value: String?) {
        busy = true
        message = nil
        Task {
            let result = await store.setProviderKey(.hunter, apiKey: value)
            busy = false
            key = ""
            switch result {
            case true?: ok = true; message = value == nil ? "Removed." : "Saved in your Keychain."
            case false?: ok = false; message = "Hunter didn't accept that key."
            case nil: ok = false; message = store.lastOutreachErrorMessage
            }
        }
    }
}

/// The do-not-contact list: addresses and whole domains that are never emailed.
private struct SuppressionListRow: View {
    @Environment(AppStore.self) private var store
    @State private var entry = ""

    var body: some View {
        let items = store.outreach.data.suppression
        SettingsRow("Do-not-contact",
                    help: "Checked when drafting, when you approve, and right before each email goes out. People who asked not to be emailed stay on the list for good.") {
            HStack(spacing: Space.s) {
                TextField("name@company.com or @company.com", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit(add)
                Button("Add", action: add).disabled(!isValid || !store.isConnected)
            }
            if items.isEmpty {
                Text("Nobody on the list.").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            ForEach(items.prefix(200)) { item in
                HStack(spacing: Space.s) {
                    Text(item.value).font(Typography.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text(item.reasonLabel).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    if item.isRemovable {
                        Button { Task { await store.unsuppress(item) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(!store.isConnected)
                            .accessibilityLabel("Remove \(item.value) from the do-not-contact list")
                    } else {
                        Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(Palette.textTertiary)
                            .help("They asked not to be emailed. This can't be removed.")
                            .accessibilityLabel("Can't be removed")
                    }
                }
            }
        }
    }

    private var trimmed: String { entry.trimmingCharacters(in: .whitespaces).lowercased() }
    private var isValid: Bool { trimmed.contains("@") ? trimmed.split(separator: "@").last?.contains(".") == true : false }

    private func add() {
        guard isValid else { return }
        let value = trimmed
        Task {
            let ok = value.hasPrefix("@") ? await store.suppress(domain: String(value.dropFirst())) : await store.suppress(email: value)
            if ok { entry = "" }
        }
    }
}

/// Data controls: delete contacts (optionally keeping them on the do-not-contact list).
private struct ContactDataRow: View {
    @Environment(AppStore.self) private var store
    @State private var confirm = false
    @State private var neverEmail = true
    @State private var deleting = false

    var body: some View {
        let count = store.outreach.data.contacts.count
        SettingsRow("Contacts", help: "Contacts live only on this Mac. Deleting one cancels its drafts.") {
            HStack(spacing: Space.s) {
                Text(C3Format.plural(count, "contact")).font(Typography.body)
                Spacer()
                if deleting { ProgressView().controlSize(.small) }
                Button("Delete all contacts…") { confirm = true }
                    .disabled(count == 0 || deleting || !store.isConnected)
            }
            Toggle("Also never email them again", isOn: $neverEmail).toggleStyle(.checkbox)
        }
        .confirmationDialog("Delete all \(C3Format.plural(count, "contact"))?", isPresented: $confirm) {
            Button("Delete all", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(neverEmail ? "Their addresses stay on the do-not-contact list." : "They could be found and drafted for again later.")
        }
    }

    private func deleteAll() {
        let ids = store.outreach.data.contacts.map(\.id)
        let suppress = neverEmail
        deleting = true
        Task {
            for id in ids { _ = await store.deleteContact(id: id, suppress: suppress) }
            deleting = false
        }
    }
}
