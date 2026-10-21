// ProspectsTab.swift — Cold Email ▸ Prospects (plan §A.2–A.3): companies to reach out to without
// an application. Search ("Series B fintech in Bangalore") runs on Google when the browser is
// free; results come back scored for fit. Shortlist finds people, Watch adds the company to the
// job watchlist, Dismiss hides it for good. The detail pane shows the company summary with its
// source link, the fit reasons and the people found there. Search is the tab's one primary action.
import SwiftUI

struct ProspectsTab: View {
    @Bindable var model: ColdEmailModel
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                searchBar
                Divider()
                list
            }
            .frame(width: 420)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TextField("Companies to look for, e.g. developer tools startups", text: $model.prospectQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.search() } }
            HStack(spacing: Space.s) {
                TextField("Location (optional)", text: $model.prospectLocation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.search() } }
                Button("Search") { Task { await model.search() } }
                    .buttonStyle(.primaryPill)
                    .disabled(model.prospectQuery.trimmingCharacters(in: .whitespaces).isEmpty || !store.isConnected)
                    .help("Searches Google at a human pace when the browser is free (\(store.preferences.peopleFinderVisitsPerDay) result pages a day)")
            }
            HStack(spacing: Space.s) {
                TextField("Add a company by name or website", text: $model.newProspect)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.addProspect() } }
                Button("Add company") { Task { await model.addProspect() } }
                    .buttonStyle(.secondaryLink)
                    .disabled(model.newProspect.trimmingCharacters(in: .whitespaces).isEmpty || !store.isConnected)
            }
        }
        .padding(Space.l)
    }

    @ViewBuilder
    private var list: some View {
        let prospects = store.outreach.activeProspects
        if prospects.isEmpty {
            EmptyState(symbol: "building.2", title: "No prospects yet",
                       message: "Search for companies you'd like to work at, or add one. The agent reads their site and scores the fit; nothing is sent.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(prospects) { p in
                        ProspectRow(prospect: p, isSelected: model.selectedProspect?.id == p.id)
                            .onTapGesture { model.selectedProspectID = p.id }
                    }
                }
                .padding(Space.s)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let p = model.selectedProspect {
            ScrollView {
                ProspectDetail(prospect: p, model: model)
                    .padding(Space.contentPadding)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            .id(p.id)
        } else {
            EmptyState(symbol: "building.2", title: "Pick a company", message: "See what they do, why they fit, and who to write to.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProspectRow: View {
    var prospect: ProspectItem
    var isSelected: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            CompanyMonogram(name: prospect.company, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(prospect.company).font(Typography.bodyEmph).lineLimit(1)
                    if prospect.status != .suggested { Badge(prospect.status.label, tone: prospect.status == .shortlisted ? .accent : .neutral) }
                    if prospect.watched { Image(systemName: "eye").imageScale(.small).foregroundStyle(Palette.textSecondary).help("On your watch list") }
                }
                Text(prospect.fitSummary ?? prospect.summary ?? prospect.foundViaLabel)
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let score = prospect.fitScore { Badge(score: score) }
        }
        .selectableRow(isSelected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct ProspectDetail: View {
    var prospect: ProspectItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        let contacts = store.outreach.contacts(companyID: prospect.companyID)
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                CompanyMonogram(name: prospect.company, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prospect.company).font(Typography.title2)
                    if let domain = prospect.domain { Text(domain).font(Typography.mono).foregroundStyle(Palette.textSecondary) }
                }
                Spacer()
                if let score = prospect.fitScore { Badge(score: score) }
            }
            HStack(spacing: Space.l) {
                if prospect.status != .shortlisted && prospect.status != .contacted {
                    Button("Shortlist") { act { await store.updateProspect(id: prospect.id, status: .shortlisted) } }
                        .buttonStyle(.secondaryLink)
                        .help("Find people to write to at \(prospect.company)")
                }
                if !prospect.watched {
                    Button("Watch") { act { await store.updateProspect(id: prospect.id, status: nil, watch: true) } }
                        .buttonStyle(.secondaryLink)
                        .help("Add \(prospect.company) to your watched companies so new roles show up in Pipeline")
                }
                Button("Dismiss") { act { await store.updateProspect(id: prospect.id, status: .dismissed) } }
                    .buttonStyle(.secondaryLink)
                    .help("Hide it; it won't be suggested again")
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy || !store.isConnected)
            if let summary = prospect.summary {
                VStack(alignment: .leading, spacing: Space.xs) {
                    SectionHeader("What they do")
                    Text(summary).font(Typography.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let url = prospect.summaryURL.flatMap(URL.init(string:)) {
                        Link("Source: \(prospect.summaryURL ?? "")", destination: url).font(Typography.callout).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                SectionHeader("Why it fits")
                if let s = prospect.fitSummary { Text(s).font(Typography.body).fixedSize(horizontal: false, vertical: true) }
                ForEach(prospect.fitFactors.sorted { $0.key < $1.key }, id: \.key) { k, v in
                    ColdEmailFact(k.capitalized, "\(v)")
                }
                if let roles = prospect.matchingRoles {
                    ColdEmailFact("Open roles", roles == 0 ? "None matching right now" : C3Format.plural(roles, "matching role"))
                }
                ColdEmailFact("Found via", prospect.foundViaLabel)
                if let until = prospect.cooldownUntil, until > Date() {
                    ColdEmailFact("Cooldown", "No new email before \(until.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                SectionHeader("People") {
                    Button("Find people") {
                        act { await store.scoutContacts(companyID: prospect.companyID, purpose: .prospect) }
                    }
                    .buttonStyle(.secondaryLink)
                    .disabled(busy || !store.isConnected)
                }
                if store.outreach.scouting.contains(prospect.companyID) {
                    HStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Finding people…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                }
                if contacts.isEmpty {
                    Text("No one found yet. Shortlist or Find people to look on their site, GitHub and Google results.")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(contacts.prefix(12)) { c in
                    HStack(spacing: Space.s) {
                        Text(c.nameAndTitle).font(Typography.callout).lineLimit(1)
                        Badge(contact: c)
                        ProvenanceButton(contact: c)
                        Spacer()
                        if c.hasEmail {
                            Button("Draft") {
                                act {
                                    if let check = await store.draftOutreach(contactID: c.id, kind: .prospect), let tid = check.threadId {
                                        model.open(threadID: tid)
                                    }
                                    return true
                                }
                            }
                            .buttonStyle(.secondaryLink)
                            .disabled(busy || !store.isConnected)
                            .help("Draft an introduction for your review. It never claims you applied.")
                        }
                    }
                    .padding(.vertical, Space.xxs)
                }
            }
        }
    }

    private func act(_ op: @escaping () async -> Bool) {
        busy = true
        Task {
            _ = await op()
            busy = false
        }
    }
}
