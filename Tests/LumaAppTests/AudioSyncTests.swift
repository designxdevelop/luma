import Foundation
import Testing
import LumaCore
@testable import LumaUI

// Audio Sync wiring. Fake sessions push hand-made `AudioLevels` (synthetic test input), so no
// audio is captured and no permission prompt can appear. Real capture is covered by QA notes
// in docs/AUDIO-SYNC-NATIVE.md.

@MainActor private final class FakeAudio: AudioCaptureSession {
    var onLevels: (@MainActor (AudioLevels) -> Void)?
    var onEnd: (@MainActor (ScreenCaptureEnd) -> Void)?
    var starts = 0, stops = 0
    var failure: ScreenCaptureEnd?
    func start(onLevels: @escaping @MainActor (AudioLevels) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws {
        starts += 1; self.onLevels = onLevels; self.onEnd = onEnd
        if let failure { throw failure }
    }
    func stop() { stops += 1 }
}

@MainActor private final class AudioFixture {
    let store = HomeStore(demo: true, screenSyncDefaults: nil, folder: testFolder())
    var sessions: [FakeAudio] = []
    var sent: [StreamUpdate] = []
    var sync: ScreenSync { store.screenSync }
    var session: FakeAudio { sessions.last! }
    init(include ids: [String] = ["demo-floor"]) {
        store.notice = nil
        sync.send = { [unowned self] _, update in sent.append(update) }
        for id in ids { sync.setIncluded(true, for: id) }
    }
    func source(kind: ScreenSource.Kind = .systemAudio, failure: ScreenCaptureEnd? = nil) -> ScreenSource {
        .audio(name: "Test audio", kind: kind) { [unowned self] in
            let capture = FakeAudio(); capture.failure = failure
            sessions.append(capture); return capture
        }
    }
    func start() async { sync.select(source()); await sync.start() }
    /// Feeds one analysis at a chosen time, as real capture would through `onLevels`.
    func levels(_ level: Double, _ bands: [Double], at now: Double) { sync.receive(AudioLevels(level: level, bands: bands)!, generation: sync.generation, now: now) }
    func finish() { store.shutdown() }
}

private let loudBass: [Double] = [0.95, 0.9, 0.3, 0.1, 0, 0, 0, 0]

@MainActor struct AudioSyncTests {
    @Test func audioSessionStreamsAnalysisWithinFloorAndCapAndStopEndsIt() async {
        let f = AudioFixture(); defer { f.finish() }
        f.sync.select(f.source())
        #expect(f.sync.mode == .audio && f.sessions.isEmpty, "Choosing an audio source must not capture")
        await f.sync.start()
        #expect(f.sync.phase == .running && f.session.starts == 1 && f.sync.title == "Audio Sync")
        #expect(f.sent.isEmpty, "Nothing is sent before real audio arrives")
        f.session.onLevels?(AudioLevels(level: 0.9, bands: loudBass)!)
        #expect(f.sync.audioLevels?.level == 0.9 && f.sync.stats.analyzed == 1)
        #expect(f.sent.map(\.deviceID) == ["demo-floor"])
        #expect((16...80).contains(f.sent[0].target.brightness))
        #expect(f.sync.regionPreview == nil, "Audio never fills the screen color map")
        let stale = f.session.onLevels
        f.sync.stop()
        #expect(f.session.stops == 1 && f.sync.phase == .idle && f.sync.audioLevels == nil)
        stale?(AudioLevels(level: 0.9, bands: loudBass)!)
        #expect(f.sent.count == 1, "No sends after Stop")
    }

    @Test func modeSwitchesOnlyWhileIdleAndForgetsTheOtherKindsSource() async {
        let f = AudioFixture(); defer { f.finish() }
        f.sync.select(ScreenSource(name: "Display", kind: .display) { SampleScreenCapture() })
        #expect(f.sync.mode == .screen)
        f.sync.setMode(.audio)
        #expect(f.sync.mode == .audio && f.sync.source == nil)
        await f.start()
        f.sync.setMode(.screen)
        #expect(f.sync.mode == .audio && f.sync.source?.isAudio == true, "No switching while active")
    }

    @Test func spectrumSpreadsLightsBassToTrebleByNameAndKeepsBandsOnTakeover() async {
        let f = AudioFixture(include: ["demo-floor", "demo-strip", "demo-desk"]); defer { f.finish() }
        f.sync.audioOptions.style = .spectrum
        f.sync.settings.updateHz = 10
        await f.start()
        // "Behind the sofa" < "Corner glow" < "Desk lights".
        #expect(f.sync.audioOrder == ["demo-strip", "demo-floor", "demo-desk"])
        f.levels(0.9, loudBass, at: 10)
        let byID = Dictionary(uniqueKeysWithValues: f.sent.map { ($0.deviceID, $0.target) })
        #expect(byID["demo-strip"]?.rgb == 0xFF0000, "Bass light is red")
        #expect(byID["demo-strip"]!.brightness > byID["demo-desk"]!.brightness, "Bass-heavy music lights the bass light more")
        f.store.perform(.brightness(30), ids: ["demo-strip"])
        #expect(f.sync.excluded["demo-strip"] != nil)
        #expect(f.sync.audioOrder == ["demo-strip", "demo-floor", "demo-desk"], "Takeover doesn't shift other lights' bands")
        f.sent.removeAll()
        f.levels(0.2, [0, 0, 0, 0, 0.2, 0.6, 0.9, 0.9], at: 11)
        #expect(!f.sent.contains { $0.deviceID == "demo-strip" })
    }

    @Test func lightsEaseToTheFloorWhenCaptureGoesQuiet() async {
        let f = AudioFixture(); defer { f.finish() }
        f.sync.settings.smoothing = 0
        f.sync.settings.updateHz = 10
        await f.start()
        f.levels(0.9, loudBass, at: 10)
        #expect(f.sent.last!.target.brightness > 40)
        var now = 10.0
        while now < 13 { now += 0.1; f.sync.tick(now: now) }
        #expect(f.sync.audioLevels == nil, "The meter shows no signal")
        #expect(f.sync.stats.analyzed == 1, "Decay steps are not counted as analysis")
        #expect(f.sent.last!.target.brightness == AudioReactive.brightnessRange(cap: 80).lowerBound)
    }

    @Test func audioRestoresLightsOnStopLikeScreenSync() async {
        let f = AudioFixture(); defer { f.finish() }
        f.sync.settings.restore = true
        var calls: [String] = []
        f.sync.restore = { device, _ in calls.append(device.id) }
        await f.start()
        f.levels(0.9, loudBass, at: 10)
        f.sync.stop()
        #expect(calls == ["demo-floor"])
    }

    @Test func microphoneDenialIsExplainedAndKeepsTheSource() async {
        let f = AudioFixture(); defer { f.finish() }
        f.sync.select(f.source(kind: .microphone, failure: .permissionDenied))
        await f.sync.start()
        #expect(f.sync.phase == .idle && f.sync.permissionDenied && f.sync.source?.kind == .microphone)
        #expect(f.sync.message == "iOS didn't allow Luma to use the microphone.")
    }

    @Test func audioOptionsAndModePersistOutsideScreenSyncSettings() throws {
        let suite = "app.luma.tests.audio-sync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ScreenSync(defaults: defaults)
        first.setMode(.audio)
        first.audioOptions = AudioSyncOptions(style: .spectrum, sensitivity: 1.5)
        let second = ScreenSync(defaults: defaults)
        #expect(second.mode == .audio && second.audioOptions == AudioSyncOptions(style: .spectrum, sensitivity: 1.5))
        #expect(second.source == nil && second.phase == .idle)
        let settings = try #require(defaults.data(forKey: "screenSync.settings"))
        let keys = try #require(JSONSerialization.jsonObject(with: settings) as? [String: Any]).keys
        #expect(!keys.contains("style") && !keys.contains("sensitivity") && !keys.contains("mode"))
        defaults.set(Data(#"{"style":"pulse","sensitivity":9}"#.utf8), forKey: "audioSync.options")
        #expect(ScreenSync(defaults: defaults).audioOptions.sensitivity == 2)
        let fresh = ScreenSync(defaults: nil)
        fresh.usePreferences(defaults)
        #expect(fresh.mode == .audio)
    }

    @Test func pumpTurnsSamplesIntoBandsAboutTwentyTimesASecond() async throws {
        // Synthetic 60 Hz tone through the real analysis path (not OS capture).
        let box = LevelsBox()
        let made = AudioLevelPump(onLevels: { box.levels.append($0) }, onEnd: { _ in })
        let pump = try #require(made)
        let rate = 48_000.0
        let tone = (0..<Int(rate)).map { Float(0.5 * sin(2 * Double.pi * 60 * Double($0) / rate)) }
        for chunk in stride(from: 0, to: tone.count, by: 480) { pump.feed(Array(tone[chunk..<chunk + 480]), sampleRate: rate) }
        for _ in 0..<50 where box.levels.isEmpty { await Task.yield() }
        let levels = try #require(box.levels.last)
        #expect(levels.bands[0] == levels.bands.max(), "60 Hz lands in the bass band")
        #expect(levels.level > 0.8)
        pump.cancel()
        pump.feed(tone, sampleRate: rate)
        let count = box.levels.count
        for _ in 0..<10 { await Task.yield() }
        #expect(box.levels.count == count, "Nothing is delivered after cancel")
    }
}

@MainActor private final class LevelsBox { var levels: [AudioLevels] = [] }

#if os(macOS)
import AppKit

@MainActor struct AudioSyncSystemEventTests {
    // Calls the observer's handler directly: posting real NSWorkspace notifications would
    // also pause sessions in tests running in parallel.
    @Test func displaySleepPausesScreenSyncButNotAudioSync() async {
        let audio = AudioFixture(); defer { audio.finish() }
        await audio.start()
        audio.sync.systemPause(NSWorkspace.screensDidSleepNotification, reason: "displays slept")
        #expect(audio.sync.phase == .running)
        audio.sync.systemPause(NSWorkspace.willSleepNotification, reason: "Mac slept")
        #expect(audio.sync.phase == .paused, "System sleep still pauses Audio Sync")

        let screen = AudioFixture(); defer { screen.finish() }
        screen.sync.select(ScreenSource(name: "Display", kind: .display) { SampleScreenCapture() })
        await screen.sync.start()
        screen.sync.systemPause(NSWorkspace.screensDidSleepNotification, reason: "displays slept")
        #expect(screen.sync.phase == .paused)

        // A camera aimed at the TV doesn't use this Mac's picture either.
        let camera = AudioFixture(); defer { camera.finish() }
        camera.sync.useCamera(ScreenSource(name: "Camera", kind: .camera) { SampleScreenCapture() })
        #expect(camera.sync.mode == .screen)
        await camera.sync.start()
        camera.sync.systemPause(NSWorkspace.screensDidSleepNotification, reason: "displays slept")
        #expect(camera.sync.phase == .running)
        camera.sync.systemPause(Notification.Name("com.apple.screenIsLocked"), reason: "locked")
        #expect(camera.sync.phase == .paused, "Locking still pauses a camera")
    }
}
#endif
