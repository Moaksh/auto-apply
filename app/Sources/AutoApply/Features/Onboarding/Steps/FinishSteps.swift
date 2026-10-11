// FinishSteps.swift — onboarding steps 6–7 and the finish moment: connect sources (card flips
// when a session is detected), choose Auto/Review (looping mini animations while hovered or
// selected), and "Ready" (Run Prep pass / Not now).
import SwiftUI

// MARK: - Step 6: Connect sources

struct SourcesStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(title: "Where should we look?",
                   subtitle: "LinkedIn is only browsed, never used to apply. Easy Apply jobs go to a manual list.")
        Grid(horizontalSpacing: Space.m, verticalSpacing: Space.m) {
            GridRow {
                LoginSourceCard(name: "LinkedIn", glyph: "in", status: model.sourceStatus(.linkedin),
                                onConnect: { Task { await model.connect(.linkedin) } },
                                onCheck: { await model.checkLogin(.linkedin) })
                LoginSourceCard(name: "Glassdoor", glyph: "G", status: model.sourceStatus(.glassdoor),
                                onConnect: { Task { await model.connect(.glassdoor) } },
                                onCheck: { await model.checkLogin(.glassdoor) })
            }
            GridRow {
                SourceCard(glyph: "circle.fill", title: "Greenhouse · Lever · Ashby", subtitle: "Public boards · no login") {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.applied).font(Typography.body)
                }
                SourceCard(glyph: "globe", title: "Career pages", subtitle: "Company sites you add") {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack {
                            TextField("stripe.com/jobs", text: $model.careerURLDraft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.addCareerURL() }
                            Button { model.addCareerURL() } label: { Image(systemName: "plus") }
                                .buttonStyle(.glass)
                                .accessibilityLabel("Add company URL")
                        }
                        FlowLayout(spacing: Space.xs) {
                            ForEach(model.careerURLs, id: \.self) { url in
                                HStack(spacing: 3) {
                                    Text(URL(string: url)?.host ?? url).font(Typography.callout)
                                    Button { model.careerURLs.removeAll { $0 == url } } label: { Image(systemName: "xmark").imageScale(.small) }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove \(url)")
                                }
                                .padding(.horizontal, Space.s)
                                .padding(.vertical, 2)
                                .background(Palette.sunken, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        // Optional: lets the agent finish applications that need an emailed security code (Greenhouse)
        // without asking. Same control as Settings ▸ Sources.
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(Palette.accent)
                Text("Security codes").font(Typography.title2)
                Text("optional").font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            MailAccountRow()
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surfaceCard()
    }
}

private struct SourceCard<Footer: View>: View {
    var glyph: String
    var title: String
    var subtitle: String
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: glyph).foregroundStyle(Palette.accent)
                Text(title).font(Typography.title2)
            }
            Text(subtitle).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Space.s)
            footer()
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .surfaceCard()
    }
}

/// LinkedIn/Glassdoor: "Log in in agent Chrome" → waiting → flips (3D, 0.5 s) to its connected face.
private struct LoginSourceCard: View {
    var name: String
    var glyph: String
    var status: SourceStatus?
    var onConnect: () -> Void
    var onCheck: () async -> Void
    @State private var requested = false
    @State private var checking = false
    @Environment(\.motionReduced) private var reduced

    private var connected: Bool { status?.connected == true }

    var body: some View {
        ZStack {
            front.opacity(connected ? 0 : 1)
            back.opacity(connected ? 1 : 0).rotation3DEffect(.degrees(reduced ? 0 : 180), axis: (x: 0, y: 1, z: 0))
        }
        .rotation3DEffect(.degrees(connected && !reduced ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(reduced ? .easeInOut(duration: 0.18) : .easeInOut(duration: 0.5), value: connected)
        // A new status (success or failure) ends the optimistic "waiting" state.
        .onChange(of: status?.checkedAt) { requested = false }
    }

    /// The daemon's last word is a failure (closed window, timeout, not logged in, can't check).
    private var failure: String? {
        guard !connected, !checking, let s = status, s.checkedAt != nil, let d = s.detail, !d.contains("Waiting") else { return nil }
        return d
    }

    private var isWaiting: Bool { !connected && failure == nil && (requested || status?.detail?.contains("Waiting") == true) }

    private var front: some View {
        card {
            VStack(alignment: .leading, spacing: Space.xs) {
                if checking {
                    Label("Checking your saved login…", systemImage: "magnifyingglass")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduced)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                } else if isWaiting {
                    Label("Waiting for you to log in in Chrome…", systemImage: "globe")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduced)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.needsYou)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !checking {
                    HStack(spacing: Space.s) {
                        if !isWaiting {
                            Button(failure == nil ? "Log in in agent Chrome" : "Try again") {
                                requested = true
                                onConnect()
                            }
                            .buttonStyle(.glass)
                        }
                        Button("Check now") {
                            checking = true
                            Task {
                                await onCheck()
                                checking = false
                            }
                        }
                        .buttonStyle(.plain)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.accent)
                        .help("Look at your saved Chrome login without opening a window")
                    }
                }
            }
        }
    }

    private var back: some View {
        card {
            Label("Connected · \((status?.checkedAt ?? Date()).formatted(.dateTime.day().month(.abbreviated)))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.applied)
                .font(Typography.body)
        }
    }

    private func card<Footer: View>(@ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(glyph)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(name).font(Typography.title2)
            }
            Text("Read-only browsing").font(Typography.callout).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Space.s)
            footer()
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .surfaceCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(connected ? "connected" : "not connected")")
    }
}

// MARK: - Step 7: Mode

struct ModeStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(title: "How much should the agent do on its own?")
        HStack(spacing: Space.l) {
            ModeCard(mode: .auto, symbol: "bolt.fill", title: "Auto", detail: "Applies when confident.\nAsks when unsure.",
                     isSelected: model.selectedMode == .auto) { model.selectedMode = .auto }
            ModeCard(mode: .review, symbol: "checkmark.rectangle.stack", title: "Review", detail: "Fills everything, waits\nfor your approval.",
                     isSelected: model.selectedMode == .review) { model.selectedMode = .review }
        }
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Recommended for your first week: Review").font(Typography.bodyEmph)
            Text("You can override this per ATS or per job anytime.").font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
    }
}

private struct ModeCard: View {
    var mode: Mode
    var symbol: String
    var title: String
    var detail: String
    var isSelected: Bool
    var onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    Image(systemName: symbol).foregroundStyle(Palette.accent)
                    Text(title).font(Typography.title2)
                    Spacer()
                    if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                }
                Text(detail).font(Typography.body).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                ModeMiniAnimation(pausesForYou: mode == .review, isActive: hovering || isSelected)
                    .frame(height: 36)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(isSelected ? Palette.accent : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Auto: a particle goes straight to ✓. Review: it pauses at a small "you" avatar, then ✓.
/// Loops (≤ 3 s) only while hovered or selected.
private struct ModeMiniAnimation: View {
    var pausesForYou: Bool
    var isActive: Bool
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive || reduced)) { timeline in
            Canvas { ctx, size in
                let y = size.height / 2
                let start = CGPoint(x: 8, y: y), end = CGPoint(x: size.width - 16, y: y)
                var rail = Path()
                rail.move(to: start)
                rail.addLine(to: end)
                ctx.stroke(rail, with: .color(Palette.hairline), lineWidth: 1)
                let mid = CGPoint(x: size.width / 2, y: y)
                if pausesForYou {
                    ctx.draw(Text(Image(systemName: "person.crop.circle")).foregroundStyle(Palette.textSecondary), at: CGPoint(x: mid.x, y: y - 12))
                }
                ctx.draw(Text(Image(systemName: "checkmark.circle.fill")).foregroundStyle(Palette.applied), at: end)
                let period = 2.6
                let t = isActive && !reduced ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period : 1
                var progress: Double
                if pausesForYou {
                    progress = t < 0.35 ? (t / 0.35) * 0.5 : (t < 0.65 ? 0.5 : 0.5 + (t - 0.65) / 0.35 * 0.5)
                } else {
                    progress = t
                }
                progress = Motion.flowEase(progress)
                let x = start.x + (end.x - start.x - 10) * progress
                ctx.fill(Circle().path(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(Palette.accent))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Finish: Ready

struct ReadyStep: View {
    @Bindable var model: OnboardingModel
    var onFinished: () -> Void
    @State private var appeared = false
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        VStack(spacing: Space.l) {
            Spacer(minLength: Space.xxl)
            PaperPlaneMark(trimEnd: 1, glassOpacity: 1, sweep: appeared ? 1 : -1, checkProgress: 1)
                .frame(width: 140, height: 110)
                .scaleEffect(appeared || reduced ? 1 : 0.6)
                .animation(Motion.resolve(Motion.celebrate, reduceMotion: reduced), value: appeared)
            Text("You're set.").displayStyle()
            Text("Your agent starts at \(model.firstRunText). First, a Prep pass?")
                .font(Typography.title2).foregroundStyle(Palette.textSecondary)
            Text("A Prep pass collects the questions forms will ask, so you can answer them once up front.")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
            HStack(spacing: Space.m) {
                Button("Not now") { finish(runPrep: false) }
                    .buttonStyle(.glass)
                Button("Run Prep pass") { finish(runPrep: true) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .disabled(model.isSaving)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }

    private func finish(runPrep: Bool) {
        Task {
            if await model.finish(runPrep: runPrep) {
                onFinished()
            }
        }
    }
}
