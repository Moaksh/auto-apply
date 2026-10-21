// OnboardingView.swift — the 880×620 borderless onboarding window: Ignition opener, then the
// step rail + step content + footer (Back / primary ⌘↵), then the Ready moment (§5.1).
import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.motionReduced) private var reduced
    @State private var model: OnboardingModel?

    var body: some View {
        Group {
            if let model {
                OnboardingContent(model: model) {
                    openWindow(id: WindowID.main)
                    dismissWindow(id: WindowID.onboarding)
                }
            } else {
                Palette.ignitionGround
            }
        }
        .frame(width: LayoutMetrics.onboardingSize.width, height: LayoutMetrics.onboardingSize.height)
        .background(Palette.ignitionGround)
        .onAppear {
            if model == nil {
                let m = OnboardingModel(store: store)
                m.load()
                model = m
            }
        }
    }
}

private struct OnboardingContent: View {
    @Bindable var model: OnboardingModel
    var onFinished: () -> Void
    @Environment(\.motionReduced) private var reduced

    var body: some View {
        ZStack {
            if model.step == .ignition {
                IgnitionView { model.begin() }
                    .transition(.opacity)
            } else {
                stepsLayout
                    .transition(.opacity)
            }
        }
        .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: model.step == .ignition)
    }

    private var stepsLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xl) {
                StepRail(
                    steps: OnboardingModel.Step.railSteps.map { StepRail.Step(id: $0.rawValue, title: $0.title, isOptional: $0.isOptional) },
                    current: model.railIndex,
                    onSelect: { index in model.go(to: OnboardingModel.Step.railSteps[index]) })
                Spacer()
                PaperPlaneMark(trimEnd: 1, glassOpacity: 1, sweep: 1, checkProgress: 1)
                    .frame(width: 44, height: 34)
                    .opacity(0.8)
            }
            .padding(Space.xl)
            .frame(width: 230, alignment: .leading)
            .frame(maxHeight: .infinity)
            // The rail is a brand media panel: the same live field Ignition settled into.
            .brandHeroBand(cornerRadius: 0)

            VStack(spacing: 0) {
                ZStack {
                    stepContent
                        .id(model.step.rawValue * 10 + (model.showProfileConfirm ? 1 : 0))
                        .transition(AnyTransition.reduced(.step(forward: model.movingForward), reduced))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: model.step)
                .animation(Motion.resolve(Motion.settle, reduceMotion: reduced), value: model.showProfileConfirm)

                if model.step != .ready {
                    footer
                }
            }
            .background(Palette.windowBackground)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                switch model.step {
                case .ignition: EmptyView()
                case .systemCheck: SystemCheckStep(model: model)
                case .resumes:
                    if model.showProfileConfirm { ConfirmProfileStep(model: model) } else { ResumesStep(model: model) }
                case .preferences: PreferencesStep(model: model)
                case .neverGuess: NeverGuessStep(model: model)
                case .stories: StoriesStep(model: model)
                case .sources: SourcesStep(model: model)
                case .mode: ModeStep(model: model)
                case .ready: ReadyStep(model: model, onFinished: onFinished)
                }
            }
            .padding(Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            if let message = model.validationMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.needsYou)
                    .transition(.opacity)
            }
            Spacer()
            if model.step == .systemCheck {
                Button("Re-check") { Task { await model.runSystemCheck() } }
                    .buttonStyle(.glass)
                    .disabled(model.isCheckingSystem)
            }
            if model.canGoBack {
                Button("Back") { model.back() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
            Button {
                Task { await model.primaryAction() }
            } label: {
                HStack(spacing: Space.xs) {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    Text(model.continueTitle)
                    KeyCap("⌘↵")
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isSaving || (model.step == .systemCheck && !model.canContinue))
            .errorShake(trigger: model.shakeTrigger)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.l)
        .background(Palette.windowBackground)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Step heading: title (title1) + one-line subtitle.
struct StepHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(Typography.title1)
            if let subtitle {
                Text(subtitle).font(Typography.body).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.bottom, Space.s)
        .accessibilityAddTraits(.isHeader)
    }
}
