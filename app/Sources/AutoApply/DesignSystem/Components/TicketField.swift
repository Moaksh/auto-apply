// TicketField.swift — a printed fact: an SF Mono caps label over its value ("MATCH 92",
// "CLOSES FRI 25"). Borrowed from ticket typography: the label is what the machine printed,
// the value is what you read. Use for job facts (Job detail, Review rows), never for prose.
import SwiftUI

struct TicketField: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var axis: Axis = .vertical

    var body: some View {
        let layout = axis == .vertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        layout {
            Text(label)
                .font(Typography.ticketLabel)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(Typography.ticketValue)
                .foregroundStyle(tint ?? Palette.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row of ticket fields separated by the field gap.
struct TicketFieldRow: View {
    let fields: [(label: String, value: String, tint: Color?)]

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                TicketField(label: field.label, value: field.value, tint: field.tint)
            }
        }
    }
}

#Preview("Ticket fields") {
    TicketFieldRow(fields: [("Match", "92", Palette.accent), ("Closes", "Fri 25", nil), ("Enclosed", "Letter + 3", nil)])
        .padding()
}
