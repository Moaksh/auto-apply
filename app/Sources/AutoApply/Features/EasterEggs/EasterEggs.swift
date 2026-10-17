// EasterEggs.swift — small surprises: the Konami code (↑↑↓↓←→←→BA) rains confetti over the main
// window, a few secret phrases in the ⌘K palette answer back, and the heart in the Settings
// footer bursts after seven clicks. All harmless: nothing here touches jobs or settings.
import AppKit
import SwiftUI

enum EasterEggs {
    static let confettiNotification = Notification.Name("AutoApply.confetti")

    // MARK: Konami code

    /// ↑ ↑ ↓ ↓ ← → ← → B A, as macOS key codes.
    static let konami: [UInt16] = [126, 126, 125, 125, 123, 124, 123, 124, 11, 0]

    /// Feeds key codes in and reports when the full sequence was typed (pure; tested).
    struct SequenceMatcher {
        let target: [UInt16]
        private(set) var progress = 0

        init(_ target: [UInt16]) { self.target = target }

        mutating func feed(_ code: UInt16) -> Bool {
            if code == target[progress] {
                progress += 1
            } else {
                progress = code == target[0] ? 1 : 0
            }
            if progress == target.count {
                progress = 0
                return true
            }
            return false
        }
    }

    @MainActor private static var monitor: Any?
    @MainActor private static var matcher = SequenceMatcher(konami)

    /// Watches key presses (never swallows them) for the Konami code.
    @MainActor
    static func installKonami() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if matcher.feed(event.keyCode) {
                NotificationCenter.default.post(name: confettiNotification, object: nil)
            }
            return event
        }
    }

    // MARK: Palette phrases

    struct Phrase: Sendable {
        var trigger: String
        var title: String
        var reply: String
        var symbol: String
        var confetti = false
    }

    static let phrases: [Phrase] = [
        Phrase(trigger: "hire me", title: "Hire me", reply: "The agent heard you. It's already on it.", symbol: "briefcase.fill", confetti: true),
        Phrase(trigger: "coffee", title: "Coffee", reply: "☕ The agent runs on tokens. You run on this. Fair trade.", symbol: "cup.and.saucer.fill"),
        Phrase(trigger: "42", title: "42", reply: "The answer to life, the universe and job hunting.", symbol: "sparkles"),
        Phrase(trigger: "sudo apply", title: "sudo apply", reply: "Nice try. Even sudo waits for your review. 😄", symbol: "lock.fill"),
        Phrase(trigger: "hello there", title: "Hello there", reply: "General Kenobi! Your applications are in good hands.", symbol: "hand.wave.fill"),
        Phrase(trigger: "moaksh", title: "Moaksh", reply: "Made with ❤️ by Moaksh Kakkar. Thanks for using AutoApply!", symbol: "heart.fill", confetti: true),
    ]

    /// The phrase typed exactly (case and extra spaces ignored), if any.
    static func phrase(for query: String) -> Phrase? {
        let q = query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return phrases.first { $0.trigger == q }
    }

    @MainActor
    static func play(_ phrase: Phrase, toasts: ToastCenter) {
        toasts.show(phrase.reply, symbol: phrase.symbol, style: .success, duration: .seconds(3))
        if phrase.confetti { NotificationCenter.default.post(name: confettiNotification, object: nil) }
    }
}

// MARK: Confetti

/// A short burst of falling confetti over the window (skipped when Reduce Motion is on).
struct ConfettiOverlay: View {
    @Environment(\.motionReduced) private var reduced
    @State private var burst: Date?

    var body: some View {
        ZStack {
            if let start = burst, !reduced {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(start)
                    Canvas { ctx, size in
                        for piece in ConfettiPiece.all {
                            let y = -20 + (t * piece.speed + piece.delay * -120) * 1.0
                            guard y > -30, y < size.height + 30 else { continue }
                            let x = piece.x * size.width + sin(t * piece.wobble + piece.phase) * 18
                            var p = ctx
                            p.translateBy(x: x, y: y)
                            p.rotate(by: .radians(t * piece.spin))
                            p.fill(Path(CGRect(x: -4, y: -2, width: 8, height: 4)), with: .color(piece.color))
                        }
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: EasterEggs.confettiNotification)) { _ in
            burst = .now
            Task {
                try? await Task.sleep(for: .seconds(4))
                if let b = burst, Date.now.timeIntervalSince(b) >= 3.9 { burst = nil }
            }
        }
    }
}

private struct ConfettiPiece {
    var x: Double, speed: Double, delay: Double, wobble: Double, phase: Double, spin: Double, color: Color

    static let all: [ConfettiPiece] = {
        var rng = SystemRandomNumberGenerator()
        let colors: [Color] = [.pink, .orange, .yellow, .green, .mint, .blue, .purple]
        return (0..<140).map { i in
            ConfettiPiece(
                x: Double.random(in: 0...1, using: &rng), speed: Double.random(in: 180...360, using: &rng),
                delay: Double.random(in: 0...1.2, using: &rng), wobble: Double.random(in: 2...5, using: &rng),
                phase: Double.random(in: 0...6.28, using: &rng), spin: Double.random(in: -6...6, using: &rng),
                color: colors[i % colors.count]
            )
        }
    }()
}

// MARK: Settings footer

/// "Made with ❤️ by Moaksh Kakkar" — and the heart has a secret.
struct MadeWithLoveFooter: View {
    @Environment(AppStore.self) private var store
    @Environment(\.motionReduced) private var reduced
    @State private var taps = 0
    @State private var beat = false

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Made with")
            Button {
                taps += 1
                withAnimation(reduced ? nil : .spring(response: 0.25, dampingFraction: 0.4)) { beat.toggle() }
                if taps == 7 {
                    taps = 0
                    store.toasts.show("You found the heart. Moaksh says hi 👋 Go land that job!", symbol: "heart.fill",
                                      style: .success, duration: .seconds(3))
                    NotificationCenter.default.post(name: EasterEggs.confettiNotification, object: nil)
                }
            } label: {
                Text("❤️").scaleEffect(beat ? 1.25 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("love")
            Text("by Moaksh Kakkar")
            Spacer()
        }
        .font(Typography.callout)
        .foregroundStyle(Palette.textTertiary)
        .padding(.vertical, Space.s)
    }
}
