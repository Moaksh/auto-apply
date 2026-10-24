// ProspectsTab.swift — Cold Email ▸ Companies (prospects, plan §A.2–A.3): companies to reach out to without
// an application. Two ways to find them: Startups near you (YC's public directory right away, regional
// funding news from Google results when the browser is free; place prefilled from your profile) or a
// typed search ("Series B fintech in Bangalore"). Rows are ranked by the startup score and your fit and
// print the key facts (round, amount, date, YC batch, city). The detail pane shows what they do, the
// Funding & signals breakdown with every source, why it fits, the people found there and people who
// could refer you (your LinkedIn connections first, then people in your city). Find startups / Search
// is the tab's one primary action; Find people at the top 5 is a link. Under the finder, the activity
// strip says what I'm doing (searches by stage, people being found, why Google work waits) and a
// finished search's result; each row shows its own "Finding people…" (OutreachActivityViews.swift).
import SwiftUI

struct ProspectsTab: View {
    @Bindable var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @Namespace private var selectionNS

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                finder
                OutreachActivityStrip()
                Divider()
                listHeader
                list
            }
            .frame(width: 420)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { model.prefillStartupLocation() }
    }

    private var finder: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Picker("Find", selection: $model.prospectFinder) {
                ForEach(ProspectFinder.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch model.prospectFinder {
            case .startups: startupsFinder
            case .search: searchFinder
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

    private var startupsFinder: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                TextField("City and country, e.g. Bengaluru, India", text: $model.startupLocation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.discoverStartups() } }
                Button("Find startups") { Task { await model.discoverStartups() } }
                    .buttonStyle(.primaryPill)
                    .disabled((model.startupLocation.nonEmptyTrimmed ?? model.homeLocation) == nil || !store.isConnected)
                    .help("I read YC's public directory now, and funding news from Google results when the browser is free")
            }
            HStack(spacing: Space.m) {
                Toggle("YC only", isOn: $model.startupsYCOnly).toggleStyle(.checkbox)
                    .help("Only YC's directory; no funding-news search")
                Toggle("Hiring now", isOn: $model.startupsHiringOnly).toggleStyle(.checkbox)
                Picker("Stage", selection: $model.startupStage) {
                    ForEach(StartupStageFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .font(Typography.callout)
            Text("I rank them by fresh funding, stage, investors, YC, team size and roles that match yours. Nothing is sent.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchFinder: some View {
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
        }
    }

    @ViewBuilder
    private var listHeader: some View {
        let prospects = model.visibleProspects
        if !prospects.isEmpty {
            HStack(spacing: Space.s) {
                Text(C3Format.plural(prospects.count, "company", "companies") + " · best first")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Find people at the top \(ColdEmailModel.topN)") { Task { await model.findPeopleAtTop() } }
                    .buttonStyle(.secondaryLink)
                    .disabled(!store.isConnected)
                    .help("I look for founders, engineering leads and recruiters at the \(ColdEmailModel.topN) best-ranked companies, one after another. Companies you applied to, excluded, cooling down or already being emailed are skipped.")
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
    }

    @ViewBuilder
    private var list: some View {
        let prospects = model.visibleProspects
        if prospects.isEmpty {
            EmptyState(symbol: "building.2", title: store.outreach.activeProspects.isEmpty ? "No companies yet" : "None match these filters",
                       message: store.outreach.activeProspects.isEmpty
                        ? "Find startups near you or search for companies you'd like to work at. I read their pages and score them. Nothing is sent."
                        : "Clear YC only, Hiring now or the stage to see the rest.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let scouts = store.outreach.activity().scouts
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(prospects) { p in
                        ProspectRow(prospect: p, isSelected: model.selectedProspect?.id == p.id, phase: scouts[p.companyID])
                            .onTapGesture { model.selectedProspectID = p.id }
                            .motionTransition(.row)
                    }
                }
                .padding(Space.s)
                // The selection travels; new prospects rise in and the list makes room.
                .selectionHighlightGroup(selectionNS, selection: model.selectedProspect?.id)
                .motion(Motion.move, value: prospects.map(\.id))
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
    /// People being found here ("Find people", "Find people at the top 5", Shortlist).
    var phase: OutreachActivity.ScoutPhase?
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
                if let line = prospect.factsLine {
                    Text(line).font(Typography.monoSmall).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Text(prospect.fitSummary ?? prospect.summary ?? prospect.foundViaLabel)
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(2)
                if let phase {
                    ScoutPhaseTag(phase: phase)
                        .motionTransition(.fade)
                }
            }
            Spacer(minLength: 0)
            if let score = prospect.score { Badge(score: score) }
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
                if let score = prospect.score { Badge(score: score) }
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
            if prospect.facts != nil || !prospect.startupReasons.isEmpty {
                FundingSignals(prospect: prospect)
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
                if let phase = store.outreach.activity().scouts[prospect.companyID] {
                    ScoutPhaseNote(phase: phase, company: prospect.company)
                }
                if contacts.isEmpty {
                    Text(isSmallTeam
                         ? "No one found yet. At a team this small I write to a founder or the CTO first; Find people looks on their site, YC's page, GitHub and Google results."
                         : "No one found yet. Shortlist or Find people to look on their site, GitHub and Google results.")
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
            LocalReferrals(prospect: prospect, model: model)
        }
    }

    private var isSmallTeam: Bool { (prospect.facts?.teamSize ?? .max) <= 50 }

    private func act(_ op: @escaping () async -> Bool) {
        busy = true
        Task {
            _ = await op()
            busy = false
        }
    }
}

/// Funding & signals: the printed facts, the startup score's parts, and every source.
private struct FundingSignals: View {
    var prospect: ProspectItem

    private var fields: [(label: String, value: String)] {
        guard let f = prospect.facts else { return [] }
        var out: [(String, String)] = []
        if let r = f.roundLabel { out.append(("Round", r)) }
        if let a = f.amountLabel { out.append(("Amount", a)) }
        if let d = f.roundDateLabel { out.append(("Date", d)) }
        if let y = f.ycBatch { out.append(("YC", y)) }
        if let t = f.teamSize { out.append(("Team", "\(t)")) }
        if let c = f.hqCity ?? f.hqCountry { out.append(("HQ", c)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Funding & signals")
            if !fields.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Space.l, alignment: .leading)], alignment: .leading,
                          spacing: Space.m) {
                    ForEach(fields, id: \.label) { TicketField(label: $0.label, value: $0.value) }
                }
            }
            if let note = prospect.facts?.usdNote {
                Text("\(note) at a fixed rate, for ranking").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            if let score = prospect.startupScore {
                HStack(spacing: Space.s) {
                    TicketField(label: "Startup score", value: "\(score)", tint: Palette.accent, axis: .horizontal)
                    if let confidence = prospect.startupConfidence {
                        Text("· I know \(confidence)% of what it weighs")
                            .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            ForEach(prospect.startupReasons) { r in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: r.known ? "checkmark.circle" : "questionmark.circle")
                        .imageScale(.small).foregroundStyle(r.known ? Palette.accent : Palette.textSecondary)
                    Text(r.reason).font(Typography.callout)
                        .foregroundStyle(r.known ? Palette.textPrimary : Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.s)
                    Text("\(r.points)/\(r.max)").font(Typography.monoSmall).foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let f = prospect.facts {
                if !f.investors.isEmpty { ColdEmailFact("Investors", f.investors.joined(separator: ", ")) }
                if !f.founders.isEmpty {
                    ColdEmailFact("Founders", f.founders.map { [$0.name, $0.title].compactMap { $0 }.joined(separator: ", ") }.joined(separator: " · "))
                }
                ForEach(f.sourceLinks, id: \.url) { s in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        if let url = URL(string: s.url) {
                            Link("\(s.facts.joined(separator: ", ")): \(url.host() ?? s.url)", destination: url)
                                .font(Typography.callout).lineLimit(1).truncationMode(.middle)
                        }
                        if let quote = s.quote {
                            Text("“\(quote)”").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// People who could refer you at this company: your LinkedIn connections first, then people in your city.
private struct LocalReferrals: View {
    var prospect: ProspectItem
    var model: ColdEmailModel
    @Environment(AppStore.self) private var store
    @State private var busy = false

    var body: some View {
        let refs = store.outreach.referrals(companyID: prospect.companyID)
        let city = model.homeCity
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeader("Could refer you") {
                Button(city.map { "Find people in \($0)" } ?? "Find people who could refer you") {
                    busy = true
                    Task {
                        await store.suggestReferrers(companyID: prospect.companyID, location: city)
                        busy = false
                    }
                }
                .buttonStyle(.secondaryLink)
                .disabled(busy || !store.isConnected)
                .help("I read Google results for people at \(prospect.company)\(city.map { " in \($0)" } ?? "") and check your imported LinkedIn connections. LinkedIn itself is never opened.")
            }
            if refs.isEmpty {
                Text("No one yet. Your LinkedIn connections who work here show up first.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            ForEach(refs.prefix(8)) { r in
                HStack(spacing: Space.s) {
                    Text([r.personName, r.title].compactMap { $0 }.joined(separator: ", ")).font(Typography.callout).lineLimit(1)
                    if r.basis == .user {
                        Badge("Your connection", symbol: "person.crop.circle.badge.checkmark", tone: .accent)
                    } else {
                        Badge(r.basisLabel)
                    }
                    Spacer()
                    Badge(r.state.label)
                }
                .padding(.vertical, Space.xxs)
            }
            if refs.count > 8 {
                Button("See all in People ▸ Could refer you") { model.showPeople(.couldRefer) }
                    .buttonStyle(.secondaryLink)
            }
        }
    }
}
