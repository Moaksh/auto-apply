// Card.swift — the content surface: eyebrow title, trailing accessory, 16pt padding, and
// built-in loading / empty / error states (§4.4: skeletons, never spinners).
import SwiftUI

enum CardState: Equatable {
    case content
    case loading
    case empty(symbol: String, message: String)
    case error(message: String)
}

struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var state: CardState
    var tint: Color?
    var onRetry: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, state: CardState = .content, tint: Color? = nil, onRetry: (() -> Void)? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.state = state
        self.tint = tint
        self.onRetry = onRetry
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).eyebrowStyle() }
                    Spacer(minLength: Space.s)
                    accessory()
                }
            }
            Group {
                switch state {
                case .content:
                    content()
                case .loading:
                    SkeletonBlock(lines: 3)
                case .empty(let symbol, let message):
                    HStack(spacing: Space.s) {
                        Image(systemName: symbol).foregroundStyle(Palette.textTertiary)
                        Text(message).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                case .error(let message):
                    InlineError(message: message, onRetry: onRetry)
                }
            }
            .transition(.opacity)
        }
        .padding(Space.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let tint { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(tint.opacity(0.12)) }
        }
        .surfaceCard()
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}

/// "Couldn't read stats · Retry" — per-widget error; the rest of the screen keeps working.
struct InlineError: View {
    var message: String
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: StatusKind.error.symbol).foregroundStyle(Palette.error)
            Text(message).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            if let onRetry {
                Button("Retry", action: onRetry).buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Eyebrow + optional trailing content, used above sections and lists.
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).eyebrowStyle()
            Spacer()
            trailing()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A keyboard shortcut hint ("⌘J") rendered as a small key cap.
struct KeyCap: View {
    var text: String

    init(_ text: String) { self.text = text }
    init(_ shortcut: AppShortcut) { self.text = shortcut.displayString }

    var body: some View {
        Text(text)
            .font(Typography.monoSmall)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Palette.hairline, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

#Preview("Card states") {
    VStack(spacing: Space.gutter) {
        Card("Applied today") { Text("9").font(Typography.metricXL) }
        Card("Loading", state: .loading) { EmptyView() }
        Card("Empty", state: .empty(symbol: "tray", message: "Nothing yet today")) { EmptyView() }
        Card("Error", state: .error(message: "Couldn't read stats"), onRetry: {}) { EmptyView() }
    }
    .padding()
    .frame(width: 360)
}
