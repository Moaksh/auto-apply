// Surface.swift — the content container (eyebrow title, trailing accessory, content and its
// built-in loading / empty / error states), the one screen header and the one section header.
import SwiftUI

enum SurfaceState: Equatable {
    case content
    case loading
    case empty(symbol: String, message: String)
    case error(message: String)
}

/// A titled block of content on the flat `surface()`. Replaces Card / KPICard / tinted cards.
struct Surface<Content: View, Accessory: View>: View {
    var title: String?
    var state: SurfaceState
    var onRetry: (() -> Void)?
    var padding: CGFloat
    /// Inside a grid row: stretch to the row's height so tiles line up.
    @Environment(\.surfaceFillsHeight) private var fillsHeight
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, state: SurfaceState = .content, padding: CGFloat = Space.cardPadding,
         onRetry: (() -> Void)? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.state = state
        self.padding = padding
        self.onRetry = onRetry
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if title != nil || Accessory.self != EmptyView.self {
                SectionHeader(title ?? "") { accessory() }
            }
            switch state {
            case .content:
                content()
            case .loading:
                SkeletonBlock(lines: 3)
            case .empty(let symbol, let message):
                Label {
                    Text(message).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            case .error(let message):
                ErrorState(title: message, compact: true, actionTitle: onRetry == nil ? nil : "Try again", action: onRetry)
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .surface()
    }
}

extension EnvironmentValues {
    /// Set on a grid (e.g. `AdaptiveColumns`) so the surfaces in a row share its height.
    @Entry var surfaceFillsHeight = false
}

/// The one screen header: title, one plain summary line, and a trailing slot (filters, or the
/// screen's single action). Sits at the top of every primary screen.
struct ScreenHeader<Summary: View, Trailing: View>: View {
    var title: String
    @ViewBuilder var summary: () -> Summary
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder summary: @escaping () -> Summary,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.summary = summary
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(title)
                .font(Typography.title1)
                .accessibilityAddTraits(.isHeader)
            summary()
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            trailing()
        }
        .padding(.horizontal, Space.contentPadding)
        .padding(.vertical, Space.l)
    }
}

extension ScreenHeader where Summary == Text {
    init(_ title: String, summary: String = "", @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.init(title, summary: { Text(summary) }, trailing: trailing)
    }
}

/// Eyebrow + optional trailing content, used above sections inside a screen.
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if !title.isEmpty { Text(title).eyebrowStyle().accessibilityAddTraits(.isHeader) }
            Spacer(minLength: Space.s)
            trailing()
        }
    }
}

/// A keyboard shortcut hint ("⌘J"): a hairline key cap that takes its colour from the context
/// (so it reads on a plain row and inside the ink pill alike).
struct KeyCap: View {
    var text: String

    init(_ text: String) { self.text = text }
    init(_ shortcut: AppShortcut) { self.text = shortcut.displayString }

    var body: some View {
        Text(text)
            .font(Typography.monoSmall)
            .opacity(0.75)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

#Preview("Surface") {
    VStack(spacing: Space.gutter) {
        ScreenHeader("Review", summary: "3 ready · Review mode")
        Surface("Applied today") { Text("9").font(Typography.metricXL) }
        Surface("Loading", state: .loading) { EmptyView() }
        Surface("Empty", state: .empty(symbol: "tray", message: "Nothing yet today")) { EmptyView() }
        Surface("Error", state: .error(message: "Couldn't read stats"), onRetry: {}) { EmptyView() }
    }
    .padding()
    .frame(width: 420)
}
