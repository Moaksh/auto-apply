// SiteAccountsSection.swift — Settings ▸ Guardrails: "Create accounts for me" and the job-site
// accounts the agent made. Passwords live only in the macOS Keychain: a row reveals one on demand
// (hidden again after 30 s) and can copy it; Forget removes the saved login, not the site account.
import AppKit
import SwiftUI

struct SiteAccountsSection: View {
    @Binding var createAccounts: Bool
    @Environment(AppStore.self) private var store
    @State private var list: AppStore.SiteAccountList?
    @State private var mailbox: AppStore.MailAccountStatus?
    @State private var revealed: [String: String] = [:]
    @State private var confirmForget: AppStore.SiteAccount?

    private var mailboxConnected: Bool { mailbox?.connected == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SettingsRow("Job-site accounts",
                        help: "Some sites (Workday, iCIMS, Taleo…) want an account before they show the form. The agent signs up with your connected email and a unique password per site, confirms the email from your inbox, and resets the password if the email is already registered. CAPTCHAs still come to you.") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("Create accounts on job sites for me", isOn: $createAccounts)
                        .toggleStyle(.switch)
                        .disabled(!mailboxConnected && !createAccounts)
                    if !mailboxConnected {
                        Label("Connect your email in Sources ▸ Email inbox first: the agent needs it to confirm new accounts.",
                              systemImage: "envelope.badge")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.needsYou)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let accounts = list?.accounts, !accounts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        row(account)
                        if account.id != accounts.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, Space.m)
                .surface(cornerRadius: Radius.inner)
                Text("Passwords are stored in your Mac's Keychain as \"AutoApply: <site>\" (Keychain Access ▸ login).")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary)
            } else if list != nil {
                Text("No accounts yet. They appear here as the agent creates them.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .task { await reload() }
        .confirmationDialog("Forget the saved login for \(confirmForget?.host ?? "")?", isPresented: Binding(
            get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } })) {
            Button("Forget", role: .destructive) {
                if let account = confirmForget { Task { await forget(account) } }
            }
        } message: {
            Text("The password is removed from your Keychain. The account on the site itself stays; the agent resets its password if it needs it again.")
        }
    }

    private func row(_ account: AppStore.SiteAccount) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(account.company ?? account.host).font(Typography.bodyEmph).lineLimit(1)
                    statusBadge(account.status)
                }
                Text([account.host, account.email].compactMap { $0 }.joined(separator: " · "))
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Space.s)
            if let password = revealed[account.host] {
                Text(password)
                    .font(Typography.monoSmall)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize()
                Button { copy(password) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy the password")
                Button { revealed[account.host] = nil } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.borderless)
                    .help("Hide")
            } else {
                Button { Task { await reveal(account) } } label: { Label("Show password", systemImage: "eye") }
                    .buttonStyle(.borderless)
                    .disabled(!store.isConnected)
            }
            Button { confirmForget = account } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Forget this saved login")
                .disabled(!store.isConnected)
        }
        .padding(.vertical, Space.s)
    }

    @ViewBuilder
    private func statusBadge(_ status: String?) -> some View {
        switch status {
        case "creating": Badge("signing up…")
        case "resetting": Badge("resetting password…")
        case "unconfirmed": Badge("not confirmed yet", tone: .warning)
        default: EmptyView()
        }
    }

    private func reload() async {
        async let accounts = store.listSiteAccounts()
        async let mail = store.getMailAccount()
        (list, mailbox) = await (accounts, mail)
    }

    private func reveal(_ account: AppStore.SiteAccount) async {
        guard let password = await store.revealSiteAccountPassword(host: account.host) else { return }
        revealed[account.host] = password
        try? await Task.sleep(for: .seconds(30))
        revealed[account.host] = nil
    }

    private func copy(_ password: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        store.toasts.show("Password copied", symbol: "doc.on.doc", style: .info, duration: .seconds(2))
    }

    private func forget(_ account: AppStore.SiteAccount) async {
        confirmForget = nil
        if await store.deleteSiteAccount(host: account.host) {
            revealed[account.host] = nil
            await reload()
        }
    }
}

/// The account-creation consent, shown right next to the email connect form (Settings ▸ Sources
/// and onboarding): the toggle and, in one plain line, what turning it on lets the agent do.
struct AccountCreationConsent: View {
    @Binding var createAccounts: Bool

    static let explanation = "When an application site requires an account, the agent signs up with this email and a unique password saved in your Keychain. You can see and remove these accounts in Settings ▸ Guardrails."

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Toggle("Create accounts on job sites for me", isOn: $createAccounts)
                .toggleStyle(.checkbox)
            Text(Self.explanation)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Space.l + 2)
        }
        .padding(.top, Space.xs)
        .accessibilityElement(children: .combine)
    }
}
