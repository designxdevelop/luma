import Foundation
import Testing
@testable import LumaCore

// Audio Sync math. Vectors marked "desktop" were produced by desktop/src/shared/audio-math.ts,
// so Mac and Windows/Linux map the same analysis to the same light values.

private func settings(cap: Double, smoothing: Double) -> ScreenSyncSettings {
    var s = ScreenSyncSettings(); s.brightnessCap = cap; s.smoothing = smoothing; return s
}
private func lv(_ level: Double, _ bands: [Double] = Array(repeating: 0, count: 8)) -> AudioLevels { AudioLevels(level: level, bands: bands)! }

@Test func audioMapperMatchesDesktopVectors() {
    let seq: [(Double, [Double])] = [(0.9, [0.9, 0.6, 0.2, 0, 0, 0, 0, 0]), (0.9, [0.9, 0.6, 0.2, 0, 0, 0, 0, 0]), (0.3, [0, 0, 0, 0, 0.2, 0.5, 0.7, 0.4]), (0.05, Array(repeating: 0, count: 8)), (0.7, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])]
    func run(_ style: AudioSyncOptions.Style, count: Int, cap: Double, smoothing: Double) -> [[[Int]]] {
        var m = AudioMapper()
        return seq.map { l, b in m.step(lv(l, b), count: count, settings: settings(cap: cap, smoothing: smoothing), options: .init(style: style, sensitivity: 1.2), dt: 0.05).map { [$0.rgb, $0.brightness] } }
    }
    // desktop
    #expect(run(.pulse, count: 2, cap: 80, smoothing: 0.4) == [
        [[16744704, 56], [16744704, 56]], [[16744704, 71], [16744704, 71]], [[16767744, 69], [16767744, 69]],
        [[16767744, 65], [16767744, 65]], [[15531776, 72], [15531776, 72]],
    ])
    #expect(run(.spectrum, count: 3, cap: 60, smoothing: 0) == [
        [[16711680, 42], [65322, 12], [5570815, 12]], [[16711680, 54], [65322, 12], [5570815, 12]], [[16711680, 46], [65322, 20], [5570815, 42]],
        [[16711680, 40], [65322, 19], [5570815, 37]], [[16711680, 35], [65322, 45], [5570815, 51]],
    ])
}

@Test func audioBandsAndLoudnessMatchDesktop() {
    var db = [Float](repeating: -.infinity, count: 1024)
    db[3] = -20; db[200] = -35
    let bands = AudioReactive.bandLevels(db: db, sampleRate: 48_000)
    let desktop = [0.9569957149051456, 0, 0, 0, 0, 0, 0.4670787255173894, 0] // desktop
    #expect(zip(bands, desktop).allSatisfy { abs($0 - $1) < 1e-9 })
    let sine = (0..<2048).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
    #expect(abs(AudioReactive.rmsLevel(sine) - 0.8495389755675116) < 1e-6) // desktop
    #expect(AudioReactive.rmsLevel([Float](repeating: 0, count: 2048)) == 0)
    #expect(AudioLevels(level: 1.1, bands: Array(repeating: 0, count: 8)) == nil)
    #expect(AudioLevels(level: 0.5, bands: Array(repeating: 0, count: 7)) == nil)
    #expect(AudioLevels(level: 0.5, bands: [.nan] + Array(repeating: 0, count: 7)) == nil)
}

@Test func audioSpectrumPutsATonesEnergyInItsBand() throws {
    let spectrum = try #require(AudioSpectrum())
    func tone(_ hz: Double) -> [Float] { (0..<AudioSpectrum.size).map { Float(0.8 * sin(2 * Double.pi * hz * Double($0) / 48_000)) } }
    for (hz, band) in [(60.0, 0), (1500.0, 4), (5000.0, 6)] {
        let levels = try #require(spectrum.levels(tone(hz), sampleRate: 48_000))
        #expect(levels.bands.firstIndex(of: levels.bands.max()!) == band, "\(hz) Hz → \(levels.bands)")
        #expect(levels.bands[band] > 0.6)
        #expect(levels.level > 0.9)
    }
    let silent = try #require(spectrum.levels([Float](repeating: 0, count: AudioSpectrum.size), sampleRate: 48_000))
    #expect(silent.level == 0 && silent.bands.allSatisfy { $0 == 0 })
    #expect(spectrum.levels([0, 1], sampleRate: 48_000) == nil)
}

@Test func audioBrightnessStaysWithinFloorAndCapAndStrobesAreDamped() {
    var seed: UInt64 = 7
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    var m = AudioMapper()
    for _ in 0..<2000 {
        let cap = Double(1 + Int(rnd() * 100)), count = 1 + Int(rnd() * 8)
        let out = m.step(lv(rnd(), (0..<8).map { _ in rnd() }), count: count, settings: settings(cap: cap, smoothing: rnd() * 0.95),
                         options: .init(style: rnd() < 0.5 ? .pulse : .spectrum, sensitivity: 0.5 + rnd() * 1.5), dt: rnd() * 2)
        let range = AudioReactive.brightnessRange(cap: cap)
        #expect(out.count == count && out.allSatisfy { range.contains($0.brightness) })
    }
    func swing(halfPeriodSteps: Int) -> Double {
        var m = AudioMapper(); var seen: [Int] = []
        for i in 0..<200 {
            let b = m.step(lv((i / halfPeriodSteps) % 2 == 0 ? 1 : 0), count: 1, settings: settings(cap: 100, smoothing: 0), options: .init(), dt: 0.05)[0].brightness
            if i >= 100 { seen.append(b) }
        }
        return Double(seen.max()! - seen.min()!) / 80
    }
    #expect(swing(halfPeriodSteps: 1) < 0.3) // 10 Hz flicker barely moves
    #expect(swing(halfPeriodSteps: 10) > 0.8) // 1 Hz beat swings fully
    #expect(AudioReactive.hueToRGB(260) == 0x5500FF && AudioReactive.hueToRGB(0) == 0xFF0000)
}

@Test func mixerTargetsPathKeepsRateCapDeadBandAndCap() {
    var s = ScreenSyncSettings(); s.updateHz = 2; s.threshold = 0.05; s.brightnessCap = 60
    var m = ScreenSyncMixer(settings: s)
    let red = LightTarget(rgb: 0xFF0000, brightness: 50)
    #expect(m.tick(now: 0, targets: ["a": red]) == [.init(deviceID: "a", target: red, sendsColor: true, sendsBrightness: true)])
    // Inside the rate interval nothing is sent, and a replaced pending change is counted.
    #expect(m.tick(now: 0.1, targets: ["a": LightTarget(rgb: 0x00FF00, brightness: 50)]).isEmpty)
    #expect(m.tick(now: 0.2, targets: ["a": LightTarget(rgb: 0x0000FF, brightness: 50)]).isEmpty)
    #expect(m.superseded == 1)
    // After it, a change smaller than the dead band is still held back…
    #expect(m.tick(now: 0.6, targets: ["a": LightTarget(rgb: 0xFF0000, brightness: 52)]).isEmpty)
    // …and a larger one sends only the field that changed.
    #expect(m.tick(now: 0.7, targets: ["a": LightTarget(rgb: 0xFF0000, brightness: 30)]) == [.init(deviceID: "a", target: .init(rgb: 0xFF0000, brightness: 30), sendsColor: false, sendsBrightness: true)])
    // Targets above the cap are clamped, and a lowered cap pulls a light down even below the dead band.
    #expect(m.tick(now: 2, targets: ["b": LightTarget(rgb: 0xFF0000, brightness: 99)]).first?.target.brightness == 60)
    m.settings.brightnessCap = 59
    #expect(m.tick(now: 3, targets: ["b": LightTarget(rgb: 0xFF0000, brightness: 99)]).first?.target.brightness == 59)
}
