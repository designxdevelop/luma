import Foundation
import Testing
@testable import LumaCore

// MARK: - Helpers

@Test func loweredBrightnessCapOverridesDeadBandAtNextRateInterval() throws {
    var mixer = ScreenSyncMixer()
    mixer.ingest(RegionColors(all: LinearColor(1, 1, 1)))
    #expect(try #require(mixer.tick(now: 0, lights: ["lamp": .full]).first).target.brightness == 80)
    mixer.settings.brightnessCap = 79
    #expect(mixer.tick(now: 0.1, lights: ["lamp": .full]).isEmpty)
    let update = try #require(mixer.tick(now: 0.5, lights: ["lamp": .full]).first)
    #expect(update.target.brightness == 79)
    #expect(update.sendsBrightness && !update.sendsColor)
    #expect(mixer.tick(now: 1, lights: ["lamp": .full]).isEmpty)
}

typealias SyncRGB = (r: UInt8, g: UInt8, b: UInt8)
private let black: SyncRGB = (0, 0, 0), red: SyncRGB = (255, 0, 0), blue: SyncRGB = (0, 0, 255), gray: SyncRGB = (128, 128, 128)
private let lg = ScreenColorMath.linear(128)

/// 32BGRA frame. Row padding (and alpha) are deliberately garbage so a wrong stride or alpha use shows up.
private struct Frame {
    var bytes: [UInt8]
    let w: Int, h: Int, bpr: Int
    init(_ w: Int, _ h: Int, bpr: Int? = nil, _ pixel: (Int, Int) -> SyncRGB) {
        self.w = w; self.h = h; self.bpr = bpr ?? w * 4
        bytes = [UInt8](repeating: 0xFF, count: self.bpr * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = pixel(x, y), o = y * self.bpr + x * 4
                bytes[o] = p.b; bytes[o + 1] = p.g; bytes[o + 2] = p.r; bytes[o + 3] = 0
            }
        }
    }
    var colors: RegionColors? { analyze(bytes, w, h, bpr) }
}

private func analyze(_ bytes: [UInt8], _ w: Int, _ h: Int, _ bpr: Int) -> RegionColors? {
    bytes.withUnsafeBytes { ScreenColorMath.analyze($0, width: w, height: h, bytesPerRow: bpr) }?.colors()
}

private func close(_ a: LinearColor, _ b: LinearColor, _ tol: Double = 1e-9) -> Bool {
    abs(a.r - b.r) < tol && abs(a.g - b.g) < tol && abs(a.b - b.b) < tol
}
private func close(_ a: RegionColors, _ b: RegionColors, _ tol: Double = 1e-9) -> Bool {
    ScreenRegion.allCases.allSatisfy { close(a[$0], b[$0], tol) }
}
private func grayColor(_ f: Double) -> LinearColor { LinearColor(lg * f, lg * f, lg * f) }

// MARK: - analyze: channel order, padding, letterbox

@Test(arguments: [
    (red, LinearColor(1, 0, 0)), (blue, LinearColor(0, 0, 1)), ((0, 255, 0) as SyncRGB, LinearColor(0, 1, 0)),
    ((255, 128, 0) as SyncRGB, LinearColor(1, lg, 0)),
])
func solidFramesKeepChannelOrder(pixel: SyncRGB, expected: LinearColor) throws {
    let c = try #require(Frame(32, 18) { _, _ in pixel }.colors)
    #expect(close(c, RegionColors(all: expected)))
}

@Test func rowPaddingIsIgnored() throws {
    // Letterboxed, non-uniform content so a wrong stride would shear rows and dilute colors.
    let pixel: (Int, Int) -> SyncRGB = { x, y in y < 6 || y >= 54 ? black : (x < 20 ? red : x >= 40 ? blue : gray) }
    let tight = try #require(Frame(60, 60, pixel).colors)
    let padded = try #require(Frame(60, 60, bpr: 60 * 4 + 36, pixel).colors)
    #expect(close(tight, padded))
    #expect(close(padded[.left], LinearColor(1, 0, 0)))
}

@Test func minimalBufferWithoutTrailingPaddingIsAccepted() throws {
    let f = Frame(10, 4, bpr: 64) { _, _ in red }
    let minimal = Array(f.bytes.prefix((4 - 1) * 64 + 10 * 4))
    #expect(analyze(minimal, 10, 4, 64) != nil)
    #expect(analyze(Array(minimal.dropLast()), 10, 4, 64) == nil)
}

@Test func letterboxBarsAreCroppedFromEveryRegion() throws {
    // 160x90, 10-row black bars. Content columns: red x<54, gray 54..106, blue x>=107.
    let content: (Int) -> SyncRGB = { $0 < 54 ? red : $0 >= 107 ? blue : gray }
    let boxed = try #require(Frame(160, 90) { x, y in y < 10 || y >= 80 ? black : content(x) }.colors)
    let bare = try #require(Frame(160, 70) { x, _ in content(x) }.colors)
    #expect(close(boxed, bare))
    #expect(close(boxed[.left], LinearColor(1, 0, 0)))
    #expect(close(boxed[.right], LinearColor(0, 0, 1)))
    let expected = LinearColor((54 + 53 * lg) / 160, 53 * lg / 160, (53 + 53 * lg) / 160)
    for region in [ScreenRegion.top, .bottom, .full] { #expect(close(boxed[region], expected), "\(region)") }
}

@Test func pillarboxBarsAreCroppedFromEveryRegion() throws {
    // 160x90, 20-column black bars. Content rows: red y<30, gray 30..59, blue y>=60.
    let content: (Int) -> SyncRGB = { $0 < 30 ? red : $0 >= 60 ? blue : gray }
    let boxed = try #require(Frame(160, 90) { x, y in x < 20 || x >= 140 ? black : content(y) }.colors)
    let bare = try #require(Frame(120, 90) { _, y in content(y) }.colors)
    #expect(close(boxed, bare))
    #expect(close(boxed[.top], LinearColor(1, 0, 0)))
    #expect(close(boxed[.bottom], LinearColor(0, 0, 1)))
    let expected = LinearColor((1 + lg) / 3, lg / 3, (1 + lg) / 3)
    for region in [ScreenRegion.left, .right, .full] { #expect(close(boxed[region], expected), "\(region)") }
}

@Test func asymmetricDarkBandIsNotCropped() throws {
    // Dark sky: 20 dark rows on top only. Smaller side (0) wins, so nothing is cropped.
    let sky = try #require(Frame(160, 90) { _, y in y < 20 ? black : gray }.colors)
    #expect(close(sky[.top], grayColor(10.0 / 30)))
    #expect(close(sky[.full], grayColor(70.0 / 90)))
    // The same band mirrored at the bottom is symmetric, so it is cropped and the top is plain content.
    let boxed = try #require(Frame(160, 90) { _, y in y < 20 || y >= 70 ? black : gray }.colors)
    #expect(close(boxed[.top], grayColor(1)))
    #expect(sky[.top].r < boxed[.top].r / 2)
}

@Test(arguments: [10, 25, 26, 40])
func barsAreCappedAtQuarterOfEachSide(bars: Int) throws {
    let c = try #require(Frame(100, 100) { _, y in y < bars || y >= 100 - bars ? black : gray }.colors)
    // After cropping 25 rows per side, 50 rows remain; any bars beyond 25 stay in view.
    let grayRows = Double(100 - 2 * bars)
    #expect(close(c[.full], grayColor(bars <= 25 ? 1 : grayRows / 50)))
}

@Test func darkThresholdIsInclusiveAt24() throws {
    func full(_ bar: UInt8) throws -> LinearColor {
        try #require(Frame(100, 100) { _, y in y < 10 || y >= 90 ? (bar, bar, bar) : gray }.colors)[.full]
    }
    #expect(close(try full(24), grayColor(1)))
    let lit = ScreenColorMath.linear(25)
    #expect(close(try full(25), LinearColor(lg * 0.8 + lit * 0.2, lg * 0.8 + lit * 0.2, lg * 0.8 + lit * 0.2)))
}

@Test func encoderNoiseWithinTwoPercentStillCountsAsBar() throws {
    // 100px-wide rows tolerate 2 bright pixels; a third makes the row content.
    func full(noisy: Int) throws -> LinearColor {
        try #require(Frame(100, 60) { x, y in
            (y < 6 || y >= 54) ? (x < noisy ? (40, 40, 40) : black) : gray
        }.colors)[.full]
    }
    #expect(close(try full(noisy: 2), grayColor(1)))
    #expect(try full(noisy: 3).g < lg * 0.85)
}

@Test func darkSceneIsNotAllBars() throws {
    let zero = try #require(Frame(32, 18) { _, _ in black }.colors)
    #expect(zero == RegionColors(all: .black))
    // Near-black (below the dark threshold) is kept as a dim picture, not cropped away.
    let dim = ScreenColorMath.linear(10)
    let c = try #require(Frame(32, 18) { _, _ in (10, 10, 10) }.colors)
    #expect(close(c, RegionColors(all: LinearColor(dim, dim, dim))))
    #expect(ScreenColorMath.target(zero[.full], brightnessCap: 80) == LightTarget(rgb: 0xFFFFFF, brightness: 1))
}

@Test func analyzeRejectsInvalidInput() {
    let ok = Frame(8, 8) { _, _ in red }
    #expect(analyze(ok.bytes, 8, 8, 32) != nil)
    #expect(analyze(ok.bytes, 0, 8, 32) == nil)
    #expect(analyze(ok.bytes, 8, 0, 32) == nil)
    #expect(analyze(ok.bytes, 8, 8, 31) == nil)                         // stride < width*4
    #expect(analyze(Array(ok.bytes.dropLast()), 8, 8, 32) == nil)       // truncated
    #expect(analyze([], 8, 8, 32) == nil)
}

@Test func analyzeRejectsOversizedFramesWithoutOverflow() {
    let side = 1025                                                      // 1025*1025 > maxPixels
    #expect(side * side > ScreenColorMath.maxPixels)
    let big = [UInt8](repeating: 0x80, count: side * side * 4)
    #expect(analyze(big, side, side, side * 4) == nil)
    #expect(analyze(big, side * side, 1, side * side * 4) == nil)
    #expect(analyze(big, Int.max, 1, Int.max) == nil)
    #expect(analyze(big, 1, Int.max, 4) == nil)
}

// MARK: - target / threshold / smoothing

@Test(arguments: [(50.0, 50), (80.0, 80), (100.0, 100), (500.0, 100), (0.0, 1), (-5.0, 1), (.nan, 80), (.infinity, 80)])
func targetScalesWhiteBrightnessByClampedCap(cap: Double, expected: Int) {
    #expect(ScreenColorMath.target(LinearColor(1, 1, 1), brightnessCap: cap) == LightTarget(rgb: 0xFFFFFF, brightness: expected))
}

@Test func targetUsesFullSaturationHue() {
    let r = ScreenColorMath.target(LinearColor(0.5, 0, 0), brightnessCap: 80)
    #expect(r.rgb == 0xFF0000)
    #expect((58...60).contains(r.brightness))                          // 80 * srgb(0.5)/255 ≈ 58.8
    let half = ScreenColorMath.target(LinearColor(0.2, 0.1, 0), brightnessCap: 100)
    #expect(half.rgb >> 16 == 255 && half.rgb & 0xFF == 0)              // brightest channel pinned to 255
    #expect((187...188).contains((half.rgb >> 8) & 0xFF))               // 0.1/0.2 -> srgb(0.5)
}

@Test func targetNeverDropsBelowOnePercentOrTurnsOff() {
    #expect(ScreenColorMath.target(LinearColor(0.001, 0.001, 0.001), brightnessCap: 10).brightness == 1)
    #expect(ScreenColorMath.target(.black, brightnessCap: 100) == LightTarget(rgb: 0xFFFFFF, brightness: 1))
    #expect(ScreenColorMath.target(LinearColor(1.0 / 5000, 0, 0), brightnessCap: 80) == LightTarget(rgb: 0xFFFFFF, brightness: 1))
}

@Test func targetSurvivesNonFiniteChannels() {
    let neutral = LightTarget(rgb: 0xFFFFFF, brightness: 1)
    #expect(ScreenColorMath.target(LinearColor(0.5, .nan, 0), brightnessCap: 80) == neutral)
    #expect(ScreenColorMath.target(LinearColor(0.5, 0, .nan), brightnessCap: 80) == neutral)
    #expect(ScreenColorMath.target(LinearColor(.nan, 0.5, 0), brightnessCap: 80) == neutral)
    #expect(ScreenColorMath.target(LinearColor(.infinity, 0.5, 0), brightnessCap: 80) == neutral)
    #expect(ScreenColorMath.target(LinearColor(0.5, .infinity, 0), brightnessCap: 80) == neutral)
}

@Test func thresholdTreatsNoPreviousAsChangeAndIdenticalAsNoChange() {
    let t = LightTarget(rgb: 0x808080, brightness: 50)
    #expect(ScreenColorMath.exceedsThreshold(nil, t, threshold: 0.2))
    #expect(!ScreenColorMath.exceedsThreshold(t, t, threshold: 0.005))
}

@Test(arguments: [16, 8, 0])
func thresholdDeadBandAppliesPerColorChannel(shift: Int) {
    // threshold 0.03 -> channels need >= 7.65 (so 8); brightness needs >= 3.
    let prev = LightTarget(rgb: 0x808080, brightness: 50)
    func next(_ delta: Int) -> LightTarget { LightTarget(rgb: 0x808080 + delta << shift, brightness: 50) }
    #expect(!ScreenColorMath.exceedsThreshold(prev, next(7), threshold: 0.03))
    #expect(!ScreenColorMath.exceedsThreshold(prev, next(-7), threshold: 0.03))
    #expect(ScreenColorMath.exceedsThreshold(prev, next(8), threshold: 0.03))
    #expect(ScreenColorMath.exceedsThreshold(prev, next(-8), threshold: 0.03))
}

@Test func thresholdDeadBandAppliesToBrightnessAndHasOneStepFloor() {
    let prev = LightTarget(rgb: 0x808080, brightness: 50)
    #expect(!ScreenColorMath.exceedsThreshold(prev, LightTarget(rgb: 0x808080, brightness: 52), threshold: 0.03))
    #expect(ScreenColorMath.exceedsThreshold(prev, LightTarget(rgb: 0x808080, brightness: 53), threshold: 0.03))
    #expect(ScreenColorMath.exceedsThreshold(prev, LightTarget(rgb: 0x808080, brightness: 49), threshold: 0.03) == false)
    // A tiny threshold still requires at least one step of change.
    #expect(ScreenColorMath.exceedsThreshold(prev, LightTarget(rgb: 0x808081, brightness: 50), threshold: 0.001))
}

@Test func smoothingBlendsInLinearLight() {
    let a = LinearColor(0.5, 0.5, 0.5), b = LinearColor(0.501, 0.499, 0.5)
    #expect(ScreenColorMath.smooth(nil, b, smoothing: 0.9) == b)
    #expect(ScreenColorMath.smooth(a, b, smoothing: 0) == b)
    // Noise-sized steps keep (almost) the full smoothing.
    func moved(_ c: LinearColor) -> Double { (c.r - a.r) / (b.r - a.r) }
    #expect(abs(moved(ScreenColorMath.smooth(a, b, smoothing: 0.5)) - 0.5) < 0.01)
    #expect(abs(moved(ScreenColorMath.smooth(a, b, smoothing: 0.95)) - 0.05) < 0.01)
}

@Test func smoothingIsNormalizedToElapsedTime() {
    let a = LinearColor(0.5, 0.5, 0.5), b = LinearColor(0.501, 0.5, 0.5)
    func moved(_ dt: Double) -> Double { (ScreenColorMath.smooth(a, b, smoothing: 0.5, dt: dt).r - a.r) / (b.r - a.r) }
    #expect(abs(moved(0.2) - 0.75) < 0.01)            // two reference steps
    #expect(abs(moved(0.05) - (1 - 0.5.squareRoot())) < 0.01)
    #expect(moved(.nan) == moved(ScreenColorMath.smoothingStep))
}

@Test func largeJumpsBypassSmoothing() {
    let dark = LinearColor(0.01, 0.01, 0.01), bright = LinearColor(0.8, 0.2, 0.1)
    #expect(ScreenColorMath.smooth(dark, bright, smoothing: 0.95) == bright)  // scene cut lands at once
    // A mid-sized jump eases off partway: faster than full smoothing, slower than instant.
    let a = LinearColor(0.2, 0.2, 0.2), b = LinearColor(0.25, 0.2, 0.2)
    let moved = (ScreenColorMath.smooth(a, b, smoothing: 0.5).r - a.r) / (b.r - a.r)
    #expect(moved > 0.55 && moved < 1)
}

// MARK: - Settings

@Test func settingsClampToDocumentedRanges() {
    var low = ScreenSyncSettings()
    low.smoothing = -1; low.threshold = 0; low.brightnessCap = -10; low.updateHz = 0
    let l = low.clamped()
    #expect(l.smoothing == 0 && l.threshold == 0.005 && l.brightnessCap == 1 && l.updateHz == 0.5)
    var high = ScreenSyncSettings()
    high.smoothing = 5; high.threshold = 5; high.brightnessCap = 500; high.updateHz = 60
    let h = high.clamped()
    #expect(h.smoothing == 0.95 && h.threshold == 0.2 && h.brightnessCap == 100 && h.updateHz == 10)
    var mid = ScreenSyncSettings()
    mid.smoothing = 0.3; mid.threshold = 0.1; mid.brightnessCap = 42; mid.updateHz = 3
    #expect(mid.clamped() == mid)
}

@Test func settingsFallBackToDefaultsForNonFiniteValues() {
    var s = ScreenSyncSettings()
    s.smoothing = .nan; s.threshold = .infinity; s.brightnessCap = -.infinity; s.updateHz = .nan
    #expect(s.clamped() == ScreenSyncSettings())
}

@Test func settingsRoundTripThroughCodable() throws {
    var s = ScreenSyncSettings()
    s.smoothing = 0.25; s.threshold = 0.07; s.brightnessCap = 65; s.updateHz = 4
    let decoded = try JSONDecoder().decode(ScreenSyncSettings.self, from: JSONEncoder().encode(s))
    #expect(decoded == s)
}

// MARK: - Mixer

private func solid(_ r: Double, _ g: Double, _ b: Double) -> RegionColors { RegionColors(all: LinearColor(r, g, b)) }
private func mixer(smoothing: Double = 0, hz: Double = 2) -> ScreenSyncMixer {
    var s = ScreenSyncSettings()
    s.smoothing = smoothing; s.updateHz = hz
    return ScreenSyncMixer(settings: s)
}
private let one: [String: ScreenRegion] = ["a": .full]

@Test func mixerWithoutTargetSendsNothing() {
    var m = mixer()
    #expect(m.tick(now: 0, lights: one).isEmpty)
    #expect(m.smoothed == nil)
}

@Test func mixerFirstTickSendsColorAndBrightness() {
    var m = mixer()
    m.ingest(solid(1, 0, 0))
    #expect(m.tick(now: 0, lights: one) == [StreamUpdate(deviceID: "a", target: LightTarget(rgb: 0xFF0000, brightness: 80), sendsColor: true, sendsBrightness: true)])
}

@Test func mixerRateCapsPerLightAndSendsLatestOnly() {
    var m = mixer(hz: 2)
    m.ingest(solid(1, 0, 0))
    #expect(m.tick(now: 0, lights: one).count == 1)
    m.ingest(solid(0, 1, 0))
    m.ingest(solid(0, 0, 1))
    #expect(m.tick(now: 0.1, lights: one).isEmpty)
    let sent = m.tick(now: 0.5, lights: one)
    #expect(sent.map(\.target.rgb) == [0x0000FF])                       // newest frame only, green never replayed
}

@Test func mixerNeverResendsUnchangedTarget() {
    var m = mixer()
    m.ingest(solid(1, 0, 0))
    #expect(m.tick(now: 0, lights: one).count == 1)
    #expect(m.tick(now: 10, lights: one).isEmpty)
    #expect(m.tick(now: 20, lights: one).isEmpty)
    // A change below the dead band is also held back, even long after the interval.
    m.ingest(solid(0.99, 0, 0))
    #expect(m.tick(now: 30, lights: one).isEmpty)
}

@Test func mixerFlagsOnlyChangedFields() {
    var m = mixer()
    m.ingest(solid(1, 0, 0))
    _ = m.tick(now: 0, lights: one)
    m.ingest(solid(0.5, 0, 0))                                          // same hue, dimmer
    let dimmer = m.tick(now: 1, lights: one)
    #expect(dimmer.count == 1 && !dimmer[0].sendsColor && dimmer[0].sendsBrightness)
    m.ingest(solid(0, 0.5, 0))                                          // new hue, same brightness
    let hue = m.tick(now: 2, lights: one)
    #expect(hue.count == 1 && hue[0].sendsColor && !hue[0].sendsBrightness && hue[0].target.rgb == 0x00FF00)
}

@Test func mixerMapsEachLightToItsRegion() {
    var m = mixer()
    var colors = RegionColors(all: .black)
    colors[.left] = LinearColor(1, 0, 0); colors[.right] = LinearColor(0, 0, 1)
    m.ingest(colors)
    let updates = m.tick(now: 0, lights: ["b": .right, "a": .left, "c": .top])
    #expect(updates.map(\.deviceID) == ["a", "b", "c"])
    #expect(updates.map(\.target.rgb) == [0xFF0000, 0x0000FF, 0xFFFFFF])
    #expect(updates[2].target.brightness == 1)
}

@Test func mixerIgnoresLightsNotInTheMap() {
    var m = mixer()
    m.ingest(solid(1, 0, 0))
    #expect(m.tick(now: 0, lights: [:]).isEmpty)
    #expect(m.tick(now: 1, lights: ["a": .full]).map(\.deviceID) == ["a"])
    #expect(m.tick(now: 10, lights: ["b": .full]).map(\.deviceID) == ["b"])  // "a" left the map: no further updates for it
}

@Test func mixerForgetResendsOnNextTick() {
    var m = mixer()
    m.ingest(solid(1, 0, 0))
    #expect(m.tick(now: 0, lights: one).count == 1)
    #expect(m.tick(now: 0.1, lights: one).isEmpty)
    m.forget("a")
    let again = m.tick(now: 0.1, lights: one)                           // no interval wait, full resend
    #expect(again.count == 1 && again[0].sendsColor && again[0].sendsBrightness)
}

@Test func mixerResetClearsEverything() {
    var m = mixer()
    m.ingest(solid(1, 0, 0))
    _ = m.tick(now: 0, lights: one)
    m.reset()
    #expect(m.smoothed == nil)
    #expect(m.tick(now: 100, lights: one).isEmpty)
    m.ingest(solid(1, 0, 0))
    #expect(m.tick(now: 100, lights: one).count == 1)                   // lanes were cleared too
}

@Test func mixerSmoothingConvergesMonotonically() {
    var m = mixer(smoothing: 0.8, hz: 5)
    m.ingest(solid(0.2, 0.2, 0.2))
    _ = m.tick(now: 0, lights: one)
    m.ingest(solid(0.3, 0.3, 0.3))
    var reds: [Double] = [], brightness: [Int] = []
    for i in 1...20 {
        brightness += m.tick(now: Double(i) / 10, lights: one).map(\.target.brightness)
        reds.append(m.smoothed![.full].r)
    }
    #expect(reds == reds.sorted() && Set(reds).count == reds.count)
    #expect(reds[0] > 0.2 && reds[0] < 0.3 && reds.last! < 0.3 && reds.last! > 0.29)
    #expect(brightness.count > 1 && brightness == brightness.sorted())
}

@Test func mixerSettingsAreClampedOnAssignment() {
    var m = mixer()
    m.settings.updateHz = 100
    m.settings.brightnessCap = 500
    #expect(m.settings.updateHz == 10 && m.settings.brightnessCap == 100)
    m.ingest(solid(1, 1, 1))
    #expect(m.tick(now: 0, lights: one).first?.target.brightness == 100)
    m.ingest(solid(0, 0, 1))
    #expect(m.tick(now: 0.09, lights: one).isEmpty)                      // 10 Hz -> 0.1s lane
    #expect(m.tick(now: 0.2, lights: one).count == 1)
}

// MARK: - LightDevice eligibility

private func device(ip: String? = "192.168.1.5", power: Bool? = true, online: Bool? = nil, demo: Bool = false) -> LightDevice {
    LightDevice(id: "d", sku: "H6001", name: "Lamp", ip: ip, power: power, online: online, isDemo: demo)
}

@Test func screenSyncIssueDescribesWhyALightIsIneligible() {
    #expect(device(ip: nil, power: nil, online: false, demo: true).screenSyncIssue == nil)
    #expect(device(ip: nil).screenSyncIssue?.contains("LAN") == true)
    #expect(device(online: false).screenSyncIssue == "Offline")
    #expect(device(power: nil).screenSyncIssue?.contains("Waiting") == true)
    #expect(device(power: false).screenSyncIssue?.hasPrefix("Off") == true)
}

@Test(arguments: [nil, true] as [Bool?])
func screenSyncIssueIsNilForOnlineLanLightThatIsOn(online: Bool?) {
    #expect(device(power: true, online: online).screenSyncIssue == nil)
}

// MARK: - Edges, corners, half edges, vivid

private func grid(_ f: Frame) -> ScreenGrid? { f.bytes.withUnsafeBytes { ScreenColorMath.analyze($0, width: f.w, height: f.h, bytesPerRow: f.bpr) } }

@Test func edgeBandsFollowTheDepthSetting() throws {
    // Red outer 20% columns on the left, blue on the right, gray between.
    let g = try #require(grid(Frame(160, 90) { x, _ in x < 32 ? red : x >= 128 ? blue : gray }))
    #expect(close(g.color(.edgeLeft, depth: 0.15, vivid: false), LinearColor(1, 0, 0)))
    #expect(close(g.color(.edgeRight, depth: 0.15, vivid: false), LinearColor(0, 0, 1)))
    // A deeper band reaches past the red into the gray.
    let deep = g.color(.edgeLeft, depth: 0.33, vivid: false)
    #expect(deep.r < 1 && deep.g > 0)
    // Thirds don't depend on depth.
    #expect(g.color(.left, depth: 0.05, vivid: false) == g.color(.left, depth: 0.33, vivid: false))
}

@Test func cornersAndHalfEdgesPickTheirQuadrant() throws {
    let tl: SyncRGB = (255, 0, 0), tr: SyncRGB = (0, 255, 0), bl: SyncRGB = (0, 0, 255), br: SyncRGB = (255, 255, 0)
    let g = try #require(grid(Frame(160, 90) { x, y in y < 45 ? (x < 80 ? tl : tr) : (x < 80 ? bl : br) }))
    let c = g.colors(depth: 0.2)
    #expect(close(c[.cornerTopLeft], LinearColor(1, 0, 0)) && close(c[.cornerTopRight], LinearColor(0, 1, 0)))
    #expect(close(c[.cornerBottomLeft], LinearColor(0, 0, 1)) && close(c[.cornerBottomRight], LinearColor(1, 1, 0)))
    #expect(close(c[.edgeTopLeft], LinearColor(1, 0, 0)) && close(c[.edgeTopRight], LinearColor(0, 1, 0)))
    #expect(close(c[.edgeBottomLeft], LinearColor(0, 0, 1)) && close(c[.edgeBottomRight], LinearColor(1, 1, 0)))
    #expect(close(c[.edgeLeftUpper], LinearColor(1, 0, 0)) && close(c[.edgeLeftLower], LinearColor(0, 0, 1)))
    #expect(close(c[.edgeRightUpper], LinearColor(0, 1, 0)) && close(c[.edgeRightLower], LinearColor(1, 1, 0)))
    #expect(close(c[.edgeTop], LinearColor(0.5, 0.5, 0)))
}

@Test func vividFavorsColorOverWhite() throws {
    // A white document with a thin red stripe.
    let g = try #require(grid(Frame(160, 90) { x, _ in x < 16 ? red : (255, 255, 255) }))
    let plain = g.color(.full, depth: 0.15, vivid: false), vivid = g.color(.full, depth: 0.15, vivid: true)
    #expect(plain.g > 0.85)                       // average is nearly white
    #expect(vivid.g < plain.g / 2 && vivid.r > 0.99)
    // Gray-only pictures still get a color in vivid mode.
    let grayOnly = try #require(grid(Frame(32, 18) { _, _ in gray }))
    #expect(close(grayOnly.color(.full, depth: 0.15, vivid: true), grayColor(1)))
}

@Test func tinyPicturesStillCoverEveryRegion() throws {
    let g = try #require(grid(Frame(4, 2) { _, _ in red }))
    #expect(g.columns == 4 && g.rows == 2)
    for region in ScreenRegion.allCases { #expect(close(g.color(region, depth: 0.05, vivid: false), LinearColor(1, 0, 0)), "\(region)") }
    #expect(ScreenGrid(columns: 31, rows: 1, cells: .init(repeating: 0, count: 31 * 8)) == nil)
    #expect(ScreenGrid(columns: 2, rows: 2, cells: [0]) == nil)
}

@Test func settingsSavedBeforeNewFieldsKeepTheirValues() throws {
    let old = try JSONDecoder().decode(ScreenSyncSettings.self, from: Data(#"{"smoothing":0.6,"threshold":0.03,"brightnessCap":70,"updateHz":2}"#.utf8))
    #expect(old.smoothing == 0.6 && old.brightnessCap == 70 && old.updateHz == 2)
    #expect(old.edgeDepth == 0.15 && !old.vivid)
    var s = ScreenSyncSettings(); s.edgeDepth = 2
    #expect(s.clamped().edgeDepth == 0.33)
}
