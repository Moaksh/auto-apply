// DashboardHeroTests.swift — the living Dashboard hero: pure rules (countdown, count-up policy,
// breathing curve, ambient flow, when motion runs) and offscreen renders of the hero in its idle,
// working and needs-you states, light and dark, Reduce Motion on and off.
// AUTOAPPLY_SNAPSHOT_DIR=<dir> writes PNGs for visual review (ImageRenderer for the hero alone,
// an offscreen NSWindow for the whole scrolling Dashboard).
import AppKit
import SwiftUI
import Testing
@testable import AutoApply

@MainActor
@Suite("Dashboard hero", .serialized)
struct DashboardHeroTests {
    let outputDir = ProcessInfo.processInfo.environment["AUTOAPPLY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    // MARK: Pure rules

    @Test func countdownText() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(HeroCountdown.remaining(until: now.addingTimeInterval(3 * 3600 + 12 * 60), now: now) == "3h 12m")
        #expect(HeroCountdown.remaining(until: now.addingTimeInterval(2 * 3600), now: now) == "2h")
        #expect(HeroCountdown.remaining(until: now.addingTimeInterval(11 * 60 + 5), now: now) == "12m")
        #expect(HeroCountdown.remaining(until: now.addingTimeInterval(45), now: now) == "45s")
        #expect(HeroCountdown.remaining(until: now.addingTimeInterval(2), now: now) == "now")
        #expect(HeroCountdown.remaining(until: now.addingTimeInterval(-60), now: now) == "now")
        #expect(HeroCountdown.remaining(until: now.addingTimeInterval(28 * 3600), now: now) == "1d 4h")
        #expect(HeroCountdown.phrase(nextRun: now.addingTimeInterval(3 * 3600 + 12 * 60), now: now) == "in 3h 12m")
        #expect(HeroCountdown.phrase(nextRun: now, now: now) == "starting now")
    }

    @Test func countdownRefreshAndRing() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(HeroCountdown.refreshInterval(nextRun: nil, now: now) == 300)
        #expect(HeroCountdown.refreshInterval(nextRun: now.addingTimeInterval(3600), now: now) == 30)
        #expect(HeroCountdown.refreshInterval(nextRun: now.addingTimeInterval(90), now: now) == 1)
        #expect(HeroCountdown.progress(from: nil, to: now, now: now) == nil)
        #expect(HeroCountdown.progress(from: now, to: now.addingTimeInterval(100), now: now.addingTimeInterval(25)) == 0.25)
        #expect(HeroCountdown.progress(from: now, to: now.addingTimeInterval(100), now: now.addingTimeInterval(500)) == 1)
        #expect(HeroCountdown.progress(from: now, to: now.addingTimeInterval(-1), now: now) == nil)
    }

    @Test func countUpOncePerDay() {
        let day = C2.now
        let stamp = CountUpPolicy.dayStamp(day, calendar: C2.utc)
        #expect(CountUpPolicy.shouldCountUp(lastStamp: "", now: day, reduceMotion: false, calendar: C2.utc))
        #expect(!CountUpPolicy.shouldCountUp(lastStamp: stamp, now: day, reduceMotion: false, calendar: C2.utc))
        #expect(CountUpPolicy.shouldCountUp(lastStamp: stamp, now: day.addingTimeInterval(86_400), reduceMotion: false, calendar: C2.utc))
        #expect(!CountUpPolicy.shouldCountUp(lastStamp: "", now: day, reduceMotion: true, calendar: C2.utc), "never under Reduce Motion")
    }

    @Test func breathingAndAmbientFlow() {
        #expect(abs(HeroBreathCurve.phase(at: 0, period: 6) - 0) < 1e-9)
        #expect(abs(HeroBreathCurve.phase(at: 3, period: 6) - 1) < 1e-9)
        #expect(HeroBreathCurve.phase(at: 10, period: 0) == 0.5)
        for t in stride(from: 0.0, to: 10, by: 0.37) {
            let dots = FlowGeometry.ambientDots(edge: 2, at: t)
            #expect(dots.count == 3)
            #expect(dots.allSatisfy { (0..<1).contains($0.progress) && (0...1).contains($0.opacity) })
        }
        #expect(FlowGeometry.ambientDots(edge: 0, at: 0, perEdge: 0).isEmpty)
    }

    @Test func motionRunsOnlyWhenItMeansSomething() {
        #expect(DashboardHero.motionActive(state: .idle, windowVisible: true, reduceMotion: false))
        #expect(DashboardHero.motionActive(state: .filling, windowVisible: true, reduceMotion: false))
        #expect(!DashboardHero.motionActive(state: .filling, windowVisible: false, reduceMotion: false), "hidden window")
        #expect(!DashboardHero.motionActive(state: .filling, windowVisible: true, reduceMotion: true), "Reduce Motion")
        #expect(!DashboardHero.motionActive(state: .paused, windowVisible: true, reduceMotion: false), "paused")
        #expect(!DashboardHero.motionActive(state: .unreachable(lastSeen: nil), windowVisible: true, reduceMotion: false))
        #expect(!DashboardHero.motionActive(state: .loading, windowVisible: true, reduceMotion: false))
        #expect(HeroFocus.stage(for: .filling) == .filling)
        #expect(HeroFocus.stage(for: .discovering) == .discovered)
        #expect(HeroFocus.stage(for: .idle) == nil)
    }

    @Test func entranceIsOncePerLaunch() {
        let saved = HeroEntrance.hasPlayed
        defer { HeroEntrance.hasPlayed = saved }
        HeroEntrance.hasPlayed = false
        #expect(!HeroEntrance.claim(reduceMotion: true), "never under Reduce Motion")
        #expect(HeroEntrance.claim(reduceMotion: false))
        #expect(!HeroEntrance.claim(reduceMotion: false), "only once")
    }

    // MARK: Renders

    private func makeStore(_ scenario: MockScenario) async -> AppStore {
        let daemon = MockDaemon(scenario: scenario, speed: 1)
        let store = AppStore(client: daemon, repository: daemon.repository, mockScenarioName: scenario.rawValue)
        store.statsDebounce = .milliseconds(1)
        store.start()
        _ = await waitUntil { store.hasSnapshot && store.jobs.isLoaded }
        store.recomputeStats()
        return store
    }

    /// A fake application page for the live Chrome frame.
    private func fakeFrame() -> CGImage? {
        let page = VStack(alignment: .leading, spacing: 10) {
            Text("Senior iOS Engineer · Ramp").font(.system(size: 20, weight: .semibold))
            ForEach(["First name", "Last name", "Email", "LinkedIn", "Years with Swift"], id: \.self) { field in
                VStack(alignment: .leading, spacing: 3) {
                    Text(field).font(.system(size: 11)).foregroundStyle(.gray)
                    RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.5)).frame(height: 22)
                }
            }
        }
        .padding(24)
        .frame(width: 640, height: 400, alignment: .topLeading)
        .background(.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Puts the live agent into "filling" with steps and a frame (the mock idle scenario stays put).
    private func startFilling(_ store: AppStore) {
        guard let job = store.jobs.all.first(where: { $0.state == .queued }) ?? store.jobs.all.first else { return }
        let app = job.applicationID ?? job.id
        store.live.apply(.state(StatePayload(daemon: .applying, runId: "r1", message: "Filling the form",
                                             activeApplicationId: app, activeJobId: job.id)), replyTo: nil)
        for (i, action) in ["open_form", "upload_resume", "fill_fields", "answer"].enumerated() {
            store.live.apply(.agentStep(AgentStepPayload(applicationId: app, jobId: job.id, index: i, total: 7, action: action,
                                                         detail: i == 3 ? "\"Years with Swift?\" → 6" : nil, confidence: 0.9,
                                                         at: Date().addingTimeInterval(Double(i) - 4))), replyTo: nil)
        }
        if let image = fakeFrame() {
            store.live.apply(frame: DecodedFrame(applicationID: app, jobID: job.id, image: image, receivedAt: Date()))
        }
    }

    @discardableResult
    private func renderHero(_ name: String, store: AppStore, scheme: ColorScheme, reduceMotion: Bool, width: CGFloat = 1240) -> CGImage? {
        let content = DashboardHero(isWindowVisible: true)
            .padding(Space.contentPadding)
            .appEnvironment(store, simulateReduceMotion: reduceMotion)
            .environment(\.heroGlassOpaque, true)
            .frame(width: width)
            .background(Palette.windowBackground)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.cgImage
        write(image, "hero-\(name)-\(scheme == .dark ? "dark" : "light")\(reduceMotion ? "-reduced" : "")")
        return image
    }

    private func write(_ image: CGImage?, _ name: String) {
        guard let image, let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    private func renderAllVariants(_ name: String, store: AppStore) {
        for scheme in [ColorScheme.light, .dark] {
            for reduce in [false, true] {
                let image = renderHero(name, store: store, scheme: scheme, reduceMotion: reduce)
                #expect(image != nil, "\(name) \(scheme) reduce:\(reduce)")
                #expect((image?.height ?? 0) > 400, "the hero has real content in \(name)")
            }
        }
    }

    @Test func heroRendersIdleWorkingAndNeedsYou() async {
        HeroEntrance.hasPlayed = true
        UserDefaults.standard.set(CountUpPolicy.dayStamp(Date()), forKey: CountUpPolicy.storageKey)

        // Needs you: the idle mock has open questions.
        let store = await makeStore(.idle)
        #expect(store.heroState == .idle)
        if store.inbox.openCount > 0 {
            #expect(store.heroVerb == .needsYou)
            renderAllVariants("needs-you", store: store)
        }
        // Working: filling an application, with steps and a live frame.
        startFilling(store)
        #expect(store.heroState == .filling)
        renderAllVariants("working", store: store)
        renderHero("working-narrow", store: store, scheme: .dark, reduceMotion: false, width: 880)
        // Discovering: the live count panel.
        store.live.apply(.state(StatePayload(daemon: .discovering, runId: "r1", message: "LinkedIn · 'iOS engineer' · page 3")), replyTo: nil)
        #expect(store.heroState == .discovering)
        renderHero("discovering", store: store, scheme: .dark, reduceMotion: false)
        // Back to idle.
        store.live.apply(.state(StatePayload(daemon: .idle)), replyTo: nil)
        #expect(!store.heroState.isRunning)
        await store.stop()

        // Idle without anything waiting, and done for today.
        for scenario in [MockScenario.happyRun, .capReached, .firstRunEmpty] {
            let s = await makeStore(scenario)
            s.live.apply(.state(StatePayload(daemon: .idle)), replyTo: nil)
            renderAllVariants("idle-\(scenario.rawValue)", store: s)
            await s.stop()
        }
    }

    @Test func idlePanelsNeverShowAnEmptyBox() async {
        let store = await makeStore(.idle)
        for kind: HeroNextRunPanel.Kind in [.idle, .needsYou, .doneForToday(used: 15, limit: 15), .paused] {
            let panel = HeroNextRunPanel(kind: kind, nextRun: Date().addingTimeInterval(3 * 3600 + 12 * 60),
                                         since: Date().addingTimeInterval(-3600), mode: .auto)
                .frame(width: 400)
                .padding()
                .brandHeroBand()
                .appEnvironment(store, simulateReduceMotion: true)
                .environment(\.heroGlassOpaque, true)
            let image = ImageRenderer(content: panel).cgImage
            #expect(image != nil)
            write(image, "panel-next-run-\(kind)")
        }
        let today = HeroTodayPanel(applied: 3, found: 41, needYou: 2, queued: 14,
                                   lastApplied: .init(jobID: 1, company: "Ramp", title: "Senior iOS Engineer", at: Date()), lastFrame: nil)
            .frame(width: 480).padding().brandHeroBand().appEnvironment(store, simulateReduceMotion: true)
            .environment(\.heroGlassOpaque, true)
        let image = ImageRenderer(content: today).cgImage
        #expect(image != nil)
        write(image, "panel-today")
        await store.stop()
    }

    /// The whole scrolling Dashboard, drawn through an offscreen window (ImageRenderer skips
    /// ScrollView content). Only when snapshots are requested.
    @Test func fullDashboardSnapshots() async {
        guard outputDir != nil else { return }
        HeroEntrance.hasPlayed = true
        UserDefaults.standard.set(CountUpPolicy.dayStamp(Date()), forKey: CountUpPolicy.storageKey)
        let store = await makeStore(.idle)
        for working in [false, true] {
            if working { startFilling(store) }
            for scheme in [ColorScheme.light, .dark] {
                let view = DashboardView()
                    .appEnvironment(store, simulateReduceMotion: false)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 1280, height: 1500)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 1280, height: 1500)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    write(rep.cgImage, "dashboard-\(working ? "working" : "needs-you")-\(scheme == .dark ? "dark" : "light")")
                }
                window.contentView = nil
            }
        }
        await store.stop()
    }
}
