// QuickFill.swift — curated quick-fill lists for the chip inputs (roles, locations, excludes) and
// the work-authorization country picker, ordered so the user's own profile comes first.
import SwiftUI

enum QuickFillLists {
    // MARK: Roles

    static let roles: [String] = [
        "Software Engineer", "Backend Engineer", "Frontend Engineer", "Full Stack Engineer",
        "AI Engineer", "Machine Learning Engineer", "LLM Engineer", "Applied AI Engineer", "Applied Scientist",
        "Research Engineer", "Research Scientist", "ML Ops Engineer", "Prompt Engineer", "Computer Vision Engineer",
        "NLP Engineer", "Data Scientist", "Data Engineer", "Data Analyst", "Analytics Engineer", "Business Analyst",
        "Platform Engineer", "DevOps Engineer", "Site Reliability Engineer", "Cloud Engineer", "Infrastructure Engineer",
        "Security Engineer", "Mobile Engineer", "iOS Engineer", "Android Engineer", "React Native Developer",
        "QA Engineer", "SDET", "Test Automation Engineer", "Embedded Engineer", "Firmware Engineer",
        "Systems Engineer", "Distributed Systems Engineer", "Blockchain Engineer", "Game Developer",
        "Python Developer", "Java Developer", "Go Developer", "Node.js Developer", "Golang Engineer",
        "Solutions Engineer", "Forward Deployed Engineer", "Sales Engineer", "Customer Engineer", "Developer Advocate",
        "Technical Writer", "Product Manager", "Technical Product Manager", "Technical Program Manager",
        "Engineering Manager", "Product Designer", "UX Designer", "UI Engineer", "Founding Engineer",
        "Software Development Engineer", "Member of Technical Staff",
    ]

    /// Keyword families: a profile mentioning any trigger pulls these roles to the front.
    private static let roleFamilies: [(triggers: [String], roles: [String])] = [
        (["ai", "llm", "genai", "gpt", "agent", "rag", "langchain", "openai", "claude"],
         ["AI Engineer", "LLM Engineer", "Applied AI Engineer", "Machine Learning Engineer", "Forward Deployed Engineer",
          "Prompt Engineer", "Research Engineer", "Applied Scientist"]),
        (["ml", "machine learning", "pytorch", "tensorflow", "deep learning", "model"],
         ["Machine Learning Engineer", "ML Ops Engineer", "Applied Scientist", "Research Engineer", "Data Scientist",
          "Computer Vision Engineer", "NLP Engineer"]),
        (["data", "sql", "spark", "etl", "analytics", "pandas"],
         ["Data Engineer", "Data Scientist", "Data Analyst", "Analytics Engineer"]),
        (["backend", "api", "django", "fastapi", "node", "java", "go", "golang", "microservice", "python"],
         ["Backend Engineer", "Software Engineer", "Python Developer", "Platform Engineer", "Distributed Systems Engineer"]),
        (["frontend", "react", "typescript", "javascript", "css", "next.js", "vue"],
         ["Frontend Engineer", "Full Stack Engineer", "UI Engineer"]),
        (["ios", "swift", "android", "kotlin", "mobile", "flutter", "react native"],
         ["Mobile Engineer", "iOS Engineer", "Android Engineer", "React Native Developer"]),
        (["devops", "kubernetes", "aws", "gcp", "azure", "terraform", "docker", "sre", "cloud"],
         ["DevOps Engineer", "Site Reliability Engineer", "Cloud Engineer", "Platform Engineer", "Infrastructure Engineer"]),
        (["security", "pentest", "appsec"], ["Security Engineer"]),
        (["product manager", "roadmap"], ["Product Manager", "Technical Product Manager"]),
        (["design", "figma", "ux"], ["Product Designer", "UX Designer"]),
    ]

    /// Roles ordered for this user: profile-related families first, then the rest of the list.
    static func roles(for profile: Profile?, chosen: [String] = []) -> [String] {
        var text = [profile?.headline, profile?.summary].compactMap { $0 }.joined(separator: " ")
        text += " " + (profile?.workHistory.map(\.title).joined(separator: " ") ?? "")
        text += " " + (profile?.skills.joined(separator: " ") ?? "")
        text += " " + chosen.joined(separator: " ")
        let words = " " + text.lowercased().replacingOccurrences(of: "[^a-z0-9.+ ]", with: " ", options: .regularExpression) + " "
        var front: [String] = []
        for family in roleFamilies where family.triggers.contains(where: { words.contains(" \($0) ") }) {
            front += family.roles
        }
        // The user's own titles (from work history) are good searches too.
        let own = (profile?.workHistory.prefix(3).map(\.title) ?? []).filter { !$0.isEmpty && $0.count <= 40 }
        return dedupe(own + front + roles)
    }

    // MARK: Locations

    static let indiaCities = ["Bengaluru", "Hyderabad", "Pune", "Gurugram", "Noida", "Mumbai", "Chennai", "Delhi NCR", "Kolkata", "Ahmedabad"]
    static let usCities = ["San Francisco Bay Area", "New York", "Seattle", "Austin", "Boston", "Los Angeles", "Chicago", "Denver"]
    static let europeCities = ["London", "Berlin", "Amsterdam", "Dublin", "Paris", "Munich", "Zurich", "Stockholm", "Barcelona", "Lisbon"]
    static let otherCities = ["Singapore", "Dubai", "Toronto", "Vancouver", "Sydney", "Melbourne", "Tokyo", "Tel Aviv"]
    static let countries = ["India", "United States", "United Kingdom", "Germany", "Canada", "Singapore", "United Arab Emirates",
                            "Netherlands", "Australia", "Ireland", "France", "Switzerland", "Sweden", "Japan", "Spain"]

    /// "Remote", the user's own city and country, their region's hubs, then everything else.
    static func locations(for profile: Profile?) -> [String] {
        let parts = (profile?.location ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let city = parts.first
        let homeCountry = parts.count > 1 ? countryName(parts.last!) : nil
        let regional: [String]
        switch homeCountry {
        case "India": regional = indiaCities
        case "United States": regional = usCities
        case "United Kingdom", "Germany", "Netherlands", "Ireland", "France", "Spain", "Sweden", "Switzerland": regional = europeCities
        default: regional = []
        }
        let head = ["Remote", city, homeCountry].compactMap { $0 }
        return dedupe(head + regional + countries + indiaCities + usCities + europeCities + otherCities)
    }

    /// Normalizes a country written as a name or ISO code ("IN", "india", "USA").
    static func countryName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let c = countryCodes.first(where: { $0.code.caseInsensitiveCompare(t) == .orderedSame || $0.name.caseInsensitiveCompare(t) == .orderedSame }) {
            return c.name
        }
        switch t.lowercased() {
        case "usa", "us", "u.s.", "united states of america": return "United States"
        case "uk", "england", "great britain": return "United Kingdom"
        case "uae": return "United Arab Emirates"
        default: return nil
        }
    }

    // MARK: Excludes

    static let excludeKeywords = ["crypto", "web3", "blockchain", "gambling", "betting", "defense", "military", "staffing agency",
                                  "contract", "freelance", "unpaid", "commission only", "night shift", "clearance required"]
    static let excludeIndustries = ["Gambling", "Defense", "Tobacco", "Crypto", "Adult", "Staffing & Recruiting", "Oil & Gas",
                                    "Payday lending", "Firearms"]

    // MARK: Countries (work authorization)

    struct Country: Hashable, Sendable {
        var code: String
        var name: String
        var label: String { "\(code) · \(name)" }
    }

    static let countryCodes: [Country] = [
        ("IN", "India"), ("US", "United States"), ("GB", "United Kingdom"), ("CA", "Canada"), ("DE", "Germany"),
        ("SG", "Singapore"), ("AE", "United Arab Emirates"), ("NL", "Netherlands"), ("AU", "Australia"), ("IE", "Ireland"),
        ("FR", "France"), ("ES", "Spain"), ("IT", "Italy"), ("PT", "Portugal"), ("CH", "Switzerland"), ("AT", "Austria"),
        ("BE", "Belgium"), ("LU", "Luxembourg"), ("SE", "Sweden"), ("NO", "Norway"), ("DK", "Denmark"), ("FI", "Finland"),
        ("PL", "Poland"), ("CZ", "Czechia"), ("RO", "Romania"), ("HU", "Hungary"), ("GR", "Greece"), ("EE", "Estonia"),
        ("LT", "Lithuania"), ("UA", "Ukraine"), ("TR", "Türkiye"), ("IL", "Israel"), ("SA", "Saudi Arabia"), ("QA", "Qatar"),
        ("KW", "Kuwait"), ("BH", "Bahrain"), ("OM", "Oman"), ("EG", "Egypt"), ("ZA", "South Africa"), ("NG", "Nigeria"),
        ("KE", "Kenya"), ("JP", "Japan"), ("KR", "South Korea"), ("CN", "China"), ("HK", "Hong Kong"), ("TW", "Taiwan"),
        ("MY", "Malaysia"), ("TH", "Thailand"), ("VN", "Vietnam"), ("ID", "Indonesia"), ("PH", "Philippines"),
        ("NZ", "New Zealand"), ("PK", "Pakistan"), ("BD", "Bangladesh"), ("LK", "Sri Lanka"), ("NP", "Nepal"),
        ("BR", "Brazil"), ("MX", "Mexico"), ("AR", "Argentina"), ("CL", "Chile"), ("CO", "Colombia"),
    ].map { Country(code: $0.0, name: $0.1) }

    static let commonCountryCodes = ["IN", "US", "GB", "CA", "DE", "SG", "AE", "NL", "AU", "IE"]

    /// Countries for the picker: the user's home country, then the common ones, then the rest.
    static func countries(for profile: Profile?, excluding taken: some Collection<String>) -> [Country] {
        let takenSet = Set(taken.map { $0.uppercased() })
        let home = (profile?.location ?? "").split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap(countryName)
            .flatMap { name in countryCodes.first { $0.name == name }?.code }
        let order = ([home].compactMap { $0 } + commonCountryCodes)
        let head = order.compactMap { code in countryCodes.first { $0.code == code } }
        return dedupe(head + countryCodes).filter { !takenSet.contains($0.code) }
    }

    /// Search countries by code or name ("in", "ind", "kingdom").
    static func searchCountries(_ query: String, in list: [Country]) -> [Country] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        let exact = list.filter { $0.code.lowercased() == q }
        let prefix = list.filter { $0.name.lowercased().hasPrefix(q) || $0.code.lowercased().hasPrefix(q) }
        let contains = list.filter { $0.name.lowercased().contains(q) }
        return dedupe(exact + prefix + contains)
    }

    // MARK: Filtering

    /// Suggestions not yet chosen (case-insensitive), narrowed by the typed text: prefix matches,
    /// then word-prefix matches ("eng" → "Backend Engineer"), then substring matches.
    static func filter(_ suggestions: [String], query: String, excluding chosen: [String]) -> [String] {
        let taken = Set(chosen.map { $0.lowercased() })
        let pool = suggestions.filter { !taken.contains($0.lowercased()) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return dedupe(pool) }
        let prefix = pool.filter { $0.lowercased().hasPrefix(q) }
        let wordPrefix = pool.filter { s in s.lowercased().split(separator: " ").contains { $0.hasPrefix(q) } }
        let contains = pool.filter { $0.lowercased().contains(q) }
        return dedupe(prefix + wordPrefix + contains)
    }

    static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }

    static func dedupe<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}

// MARK: - Country code field

/// Searchable country picker for the per-country work-authorization editor: type a code or name,
/// pick from the matches, or tap one of the quick chips. Writes the ISO-2 code into `code`.
struct CountryCodeField: View {
    @Binding var code: String
    var options: [QuickFillLists.Country]
    var onPick: (String) -> Void = { _ in }
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [QuickFillLists.Country] { Array(QuickFillLists.searchCountries(query, in: options).prefix(6)) }
    private var selected: QuickFillLists.Country? { QuickFillLists.countryCodes.first { $0.code == code } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            TextField(selected?.label ?? "Country (IN, India…)", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($focused)
                .onSubmit { if let top = matches.first { pick(top) } }
                .accessibilityLabel("Country")
            if focused && !query.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { c in
                        Button { pick(c) } label: {
                            Text(c.label).font(Typography.body).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Space.s).padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty {
                        Text("No match").font(Typography.callout).foregroundStyle(Palette.textTertiary).padding(Space.s)
                    }
                }
                .frame(width: 200, alignment: .leading)
                .sunkenWell()
            }
            FlowLayout(spacing: Space.xs) {
                ForEach(options.prefix(8), id: \.self) { c in
                    QuickFillChip(title: c.code, help: c.name, selected: c.code == code) { pick(c) }
                }
            }
        }
    }

    private func pick(_ c: QuickFillLists.Country) {
        code = c.code
        query = ""
        focused = false
        onPick(c.code)
    }
}

/// "+ Suggestion" capsule used by ChipField and the country picker.
struct QuickFillChip: View {
    var title: String
    var help: String? = nil
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: selected ? "checkmark" : "plus").imageScale(.small)
                Text(title)
            }
            .font(Typography.callout)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 2)
            .foregroundStyle(selected ? Palette.accent : Palette.textSecondary)
            .background(selected ? Palette.accent.opacity(0.14) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 0.5, dash: selected ? [] : [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? "Add \(title)")
        .accessibilityLabel(help.map { "\(title), \($0)" } ?? "Add \(title)")
    }
}
