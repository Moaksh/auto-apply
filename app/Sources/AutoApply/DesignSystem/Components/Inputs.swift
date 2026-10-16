// Inputs.swift — ChipField (token input), ToggleChips (multi-select capsules),
// ThresholdSlider (+ MiniHistogram), DropZone.
import SwiftUI
import UniformTypeIdentifiers

/// Token input for roles, cities, excludes: chips with × plus an inline "+ add" field.
/// With `suggestions`, quick-fill capsules sit under the field (tap to add) and typing filters
/// them into a match list; Return takes the top match, or the typed text when nothing matches.
struct ChipField: View {
    @Binding var values: [String]
    var placeholder: String = "Add"
    var suggestions: [String] = []
    /// Capsules shown before "More…".
    var visibleSuggestions = 8
    @State private var draft = ""
    @State private var showAll = false
    @FocusState private var focused: Bool

    private var matches: [String] { QuickFillLists.filter(suggestions, query: draft, excluding: values) }
    private var typing: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && !draft.contains(",") }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            field
            if !suggestions.isEmpty {
                if typing {
                    matchList
                } else {
                    quickFill
                }
            }
        }
    }

    private var field: some View {
        FlowLayout(spacing: Space.xs) {
            ForEach(values, id: \.self) { value in
                HStack(spacing: 3) {
                    Text(value).font(Typography.body)
                    Button {
                        values.removeAll { $0 == value }
                    } label: {
                        Image(systemName: "xmark").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityLabel("Remove \(value)")
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, 3)
                .background(Palette.sunken, in: Capsule())
                .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.5))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .frame(minWidth: 90, maxWidth: 180)
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(.delete) {
                    guard draft.isEmpty, !values.isEmpty else { return .ignored }
                    values.removeLast()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !draft.isEmpty else { return .ignored }
                    draft = ""
                    return .handled
                }
        }
        .padding(Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkenWell()
        .motion(Motion.snappy, value: values)
        .onTapGesture { focused = true }
    }

    /// Unchosen suggestions as tappable capsules.
    @ViewBuilder
    private var quickFill: some View {
        let pool = matches
        if !pool.isEmpty {
            FlowLayout(spacing: Space.xs) {
                ForEach(showAll ? pool : Array(pool.prefix(visibleSuggestions)), id: \.self) { s in
                    QuickFillChip(title: s) { add(s) }
                }
                if pool.count > visibleSuggestions {
                    Button(showAll ? "Less" : "More…") { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(Typography.callout)
                }
            }
        }
    }

    /// While typing: the matching suggestions; the first is what Return adds.
    @ViewBuilder
    private var matchList: some View {
        let top = Array(matches.prefix(6))
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element) { i, s in
                    Button { add(s) } label: {
                        HStack(spacing: Space.xs) {
                            Text(s).font(Typography.body)
                            Spacer()
                            if i == 0 { Text("↩").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary) }
                        }
                        .padding(.horizontal, Space.s).padding(.vertical, 3)
                        .background(i == 0 ? Palette.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { commitTyped() } label: {
                    Text("Add “\(draft.trimmingCharacters(in: .whitespaces))”")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Space.s).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(Space.xs)
            .frame(maxWidth: 320, alignment: .leading)
            .sunkenWell()
        }
    }

    private func add(_ s: String) {
        if !values.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { values.append(s) }
        draft = ""
        focused = true
    }

    private func commit() {
        if typing, let top = ChipField.pick(draft: draft, matches: matches) {
            add(top)
            return
        }
        commitTyped()
    }

    private func commitTyped() {
        let parts = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for p in parts where !values.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) {
            values.append(p)
        }
        draft = ""
    }

    /// What Return adds: the top suggestion when one matches, else nil (add the typed text).
    static func pick(draft: String, matches: [String]) -> String? {
        let q = draft.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !q.contains(","), let top = matches.first else { return nil }
        return top
    }
}

/// Multi-select capsule toggles ("( Junior ) ( Mid ) (●Senior )").
struct ToggleChips<Value: Hashable>: View {
    var options: [Value]
    @Binding var selection: Set<Value>
    var label: (Value) -> String
    var singleSelection = false

    var body: some View {
        FlowLayout(spacing: Space.xs) {
            ForEach(options, id: \.self) { option in
                let on = selection.contains(option)
                Button {
                    if singleSelection {
                        selection = [option]
                    } else if on {
                        selection.remove(option)
                    } else {
                        selection.insert(option)
                    }
                } label: {
                    HStack(spacing: Space.xs) {
                        Circle().fill(on ? Palette.accent : Color.clear)
                            .overlay(Circle().stroke(on ? Palette.accent : Palette.strokeStrong, lineWidth: 1))
                            .frame(width: 7, height: 7)
                        Text(label(option)).font(Typography.body)
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 5)
                    .background(on ? Palette.accent.opacity(0.12) : Palette.sunken, in: Capsule())
                    .overlay(Capsule().stroke(on ? Palette.accent.opacity(0.5) : Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .motion(Motion.snappy, value: selection)
    }
}

/// Simple wrapping layout (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: proposal.width ?? width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Histogram of match scores in 5-point bins, split at `threshold` (W10 in miniature).
struct MiniHistogram: View {
    /// 20 bins (0–4, 5–9, … 95–100).
    var bins: [Int]
    var threshold: Int

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(1, bins.max() ?? 1)
            let barWidth = geo.size.width / CGFloat(max(1, bins.count))
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(bins.enumerated()), id: \.offset) { i, v in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(i * 5 >= threshold ? Palette.accent : Palette.categorical[4].opacity(0.4))
                            .frame(width: max(1, barWidth - 1), height: geo.size.height * CGFloat(v) / CGFloat(maxValue))
                    }
                }
                Rectangle()
                    .fill(Palette.textSecondary)
                    .frame(width: 1, height: geo.size.height)
                    .offset(x: geo.size.width * CGFloat(threshold) / 100)
            }
            .motion(Motion.snappy, value: threshold)
        }
        .accessibilityLabel("Match score distribution with threshold at \(threshold)")
    }

    /// Plausible benchmark distribution used until real data exists (onboarding).
    static let benchmark: [Int] = [0, 0, 1, 1, 2, 3, 5, 8, 12, 16, 20, 24, 26, 25, 21, 16, 10, 6, 3, 1]
}

/// Slider + live mini histogram + "≈ N jobs/week" caption, with alignment haptics every 5 pts.
struct ThresholdSlider: View {
    @Binding var value: Int
    var bins: [Int] = MiniHistogram.benchmark
    var weeklyEstimate: ((Int) -> Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            MiniHistogram(bins: bins, threshold: value).frame(height: 36)
            HStack(spacing: Space.m) {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: 40...95, step: 1)
                Text("\(value)").font(Typography.metricSmall).frame(width: 30, alignment: .trailing).numericRoll(Double(value))
            }
            if let weeklyEstimate {
                Text("≈ \(weeklyEstimate(value)) jobs/week at current volume")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
        }
        .onChange(of: value) { old, new in
            if old / 5 != new / 5 { Haptics.alignment() }
        }
    }
}

/// Dashed drop target (resume upload). Scales 1.01 and turns solid accent on drag-over.
struct DropZone: View {
    var title: String
    var subtitle: String?
    var allowedTypes: [UTType] = [.pdf]
    var onDrop: ([URL]) -> Void
    var onChoose: () -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "arrow.down.doc").font(.system(size: 28)).foregroundStyle(isTargeted ? Palette.accent : Palette.textSecondary)
            HStack(spacing: Space.xs) {
                Text(title).font(Typography.bodyEmph)
                Button("Choose files…", action: onChoose).buttonStyle(.link)
            }
            if let subtitle { Text(subtitle).font(Typography.callout).foregroundStyle(Palette.textTertiary) }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(isTargeted ? Palette.accent.opacity(0.06) : Color.clear, in: .card)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(isTargeted ? Palette.accent : Palette.strokeStrong,
                        style: StrokeStyle(lineWidth: 1.5, dash: isTargeted ? [] : [6, 4]))
        }
        .scaleEffect(isTargeted ? 1.01 : 1)
        .motion(Motion.snappy, value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return allowedTypes.contains { type.conforms(to: $0) }
            }
            guard !accepted.isEmpty else { return false }
            onDrop(accepted)
            return true
        } isTargeted: { targeted in
            if targeted && !isTargeted { Haptics.generic() }
            isTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop PDF resumes here")
    }
}

#Preview("Inputs") {
    @Previewable @State var roles = ["Backend Engineer", "ML Engineer"]
    @Previewable @State var seniority: Set<String> = ["Senior"]
    @Previewable @State var threshold = 70
    VStack(alignment: .leading, spacing: Space.l) {
        ChipField(values: $roles, placeholder: "+ add role")
        ToggleChips(options: ["Junior", "Mid", "Senior", "Staff"], selection: $seniority, label: { $0 })
        ThresholdSlider(value: $threshold, weeklyEstimate: { 40 - $0 / 3 })
        DropZone(title: "Drop PDFs here or", onDrop: { _ in }, onChoose: {})
    }
    .padding()
    .frame(width: 520)
}
