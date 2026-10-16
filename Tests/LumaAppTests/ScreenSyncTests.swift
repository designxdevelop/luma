import Foundation
import Testing
import LumaCore
@testable import Luma

/// Stands in for ScreenCaptureKit. Tests push region colors and endings by hand,
/// so no screen is captured and no permission prompt can appear.
@MainActor private final class FakeCapture: ScreenCaptureSession {
    var onFrame: (@MainActor (RegionColors) -> Void)?
    var onEnd: (@MainActor (ScreenCaptureEnd) -> Void)?
    var starts = 0, stops = 0
    var failure: ScreenCaptureEnd?
    var gated = false
    private var gate: CheckedContinuation<Void, Never>?
    func start(onFrame: @escaping @MainActor (RegionColors) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws {
        starts += 1; self.onFrame = onFrame; self.onEnd = onEnd
        if gated { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
    }
    func stop() { stops += 1 }
    func release() { gate?.resume(); gate = nil }
}

@MainActor private final class Fixture {
    let store = HomeStore(demo: true, screenSyncDefaults: nil)
    var sessions: [FakeCapture] = []
    var sent: [StreamUpdate] = []
    var sync: ScreenSync { store.screenSync }
    var session: FakeCapture { sessions.last! }
    init(include ids: [String] = ["demo-floor"]) {
        store.notice = nil
        sync.send = { [unowned self] _, update in sent.append(update) }
        for id in ids { sync.setIncluded(true, for: id) }
    }
    func source(failure: ScreenCaptureEnd? = nil, gated: Bool = false) -> ScreenSource {
        ScreenSource(name: "Test display", kind: .display) { [unowned self] in
            let capture = FakeCapture(); capture.failure = failure; capture.gated = gated
            sessions.append(capture); return capture
        }
    }
    func start() async { sync.select(source()); await sync.start() }
    func finish() { store.shutdown() }
}

private let red = RegionColors(all: LinearColor(1, 0, 0))
private let blue = RegionColors(all: LinearColor(0, 0, 1))

/// Holds a mock cloud control at a real async boundary. Every URLRequest is
/// intercepted; no test request can leave the process.
private final class ScreenSyncCloudGate: @unchecked Sendable {
    private let lock = NSLock()
    private var response: (@Sendable () -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requested = false
    func receive(_ response: @escaping @Sendable () -> Void) {
        let ready = lock.withLock {
            self.response = response; requested = true
            let ready = waiters; waiters.removeAll(); return ready
        }
        for waiter in ready { waiter.resume() }
    }
    func waitUntilRequested() async {
        await withCheckedContinuation { waiter in
            let ready = lock.withLock { if requested { return true }; waiters.append(waiter); return false }
            if ready { waiter.resume() }
        }
    }
    func release() { lock.withLock { let response = self.response; self.response = nil; return response }?() }
}

private final class ScreenSyncCloudProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [String: ScreenSyncCloudGate] = [:]
    static func install(_ gate: ScreenSyncCloudGate, id: String) { lock.withLock { gates[id] = gate } }
    static func remove(_ id: String) { _ = lock.withLock { gates.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let gate = Self.lock.withLock { Self.gates[request.value(forHTTPHeaderField: "X-Luma-Sync-Test") ?? ""] }
        gate?.receive { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"code":400,"message":"Test command refused"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor struct ScreenSyncTests {
    @Test func captureStartsOnlyOnExplicitStartAndStopEndsIt() async {
        let f = Fixture(); defer { f.finish() }
        #expect(f.sync.phase == .idle && f.sync.source == nil)
        f.sync.select(f.source())
        #expect(f.sessions.isEmpty, "Choosing a source must not capture")
        await f.sync.start()
        #expect(f.sync.phase == .running && f.session.starts == 1)
        f.session.onFrame?(red)
        f.sync.tick(now: 100)
        #expect(f.sent.map(\.deviceID) == ["demo-floor"])
        #expect(f.sent.first?.target.rgb == 0xFF0000)
        let stale = f.session.onFrame
        f.sync.stop()
        #expect(f.session.stops == 1 && f.sync.phase == .idle && f.sync.source == nil)
        #expect(f.sync.preview.isEmpty && f.sync.regionPreview == nil)
        stale?(blue)
        f.sync.tick(now: 200)
        #expect(f.sent.count == 1, "No sends after Stop")
    }

    @Test func onlyTheLatestFrameIsSentAndUnchangedColorsAreNotRepeated() async {
        let f = Fixture(); defer { f.finish() }
        f.sync.settings.smoothing = 0
        await f.start()
        for color in [red, RegionColors(all: LinearColor(0, 1, 0)), blue] { f.session.onFrame?(color) }
        f.sync.tick(now: 10)
        #expect(f.sent.map(\.target.rgb) == [0x0000FF])
        f.sync.tick(now: 20)
        f.sync.tick(now: 30)
        #expect(f.sent.count == 1)
    }

    @Test func lightUpdatesRespectTheRateCap() async {
        let f = Fixture(); defer { f.finish() }
        f.sync.settings.smoothing = 0
        f.sync.settings.updateHz = 2
        await f.start()
        f.session.onFrame?(red); f.sync.tick(now: 10)
        f.session.onFrame?(blue); f.sync.tick(now: 10.2)
        #expect(f.sent.count == 1)
        f.sync.tick(now: 10.5)
        #expect(f.sent.map(\.target.rgb) == [0xFF0000, 0x0000FF])
    }

    @Test func manualControlTakesOverBeforeItsWriteIsQueued() async {
        let f = Fixture(include: ["demo-floor", "demo-strip"]); defer { f.finish() }
        f.sync.settings.smoothing = 0
        await f.start()
        f.session.onFrame?(red); f.sync.tick(now: 10)
        #expect(Set(f.sent.map(\.deviceID)) == ["demo-floor", "demo-strip"])
        f.store.perform(.brightness(30), ids: ["demo-floor"])
        // Synchronous: the light is out before any later frame or tick.
        #expect(f.sync.excluded["demo-floor"] != nil)
        #expect(f.sync.streamingLights.keys.sorted() == ["demo-strip"])
        f.sent.removeAll()
        f.session.onFrame?(blue); f.sync.tick(now: 20)
        #expect(f.sent.map(\.deviceID) == ["demo-strip"])
        f.sync.includeAgain("demo-floor")
        f.sync.tick(now: 30)
        #expect(f.sent.map(\.deviceID) == ["demo-strip"], "Include Again cannot override a queued manual command")
        for _ in 0..<100 where f.store.hasOrdinaryControl(for: "demo-floor") { await Task.yield() }
        f.sync.includeAgain("demo-floor")
        f.sync.tick(now: 40)
        #expect(f.sent.last?.deviceID == "demo-floor")
    }

    @Test func webhookActionsTakeOverLightsToo() async {
        let f = Fixture(include: ["demo-desk"]); defer { f.finish() }
        await f.start()
        let response = await f.store.handle(.init(method: "POST", path: "/v1/actions", body: Data(#"{"target":"demo-desk","brightness":20}"#.utf8)))
        #expect(response.status == 202)
        for _ in 0..<100 where f.store.runningSceneID != nil { await Task.yield() }
        #expect(f.sync.excluded["demo-desk"] != nil)
    }

    @Test func streamedColorsStayOutOfConfirmedAndAPIState() async throws {
        let f = Fixture(); defer { f.finish() }
        f.sync.send = { [unowned f] device, update in try f.store.streamToLight(device, update) }
        let before = f.store.home.devices
        let api = await f.store.handle(.init(method: "GET", path: "/v1/devices", body: Data()))
        await f.start()
        f.session.onFrame?(blue); f.sync.tick(now: 10)
        #expect(f.sync.preview["demo-floor"]?.rgb == 0x0000FF)
        #expect(f.store.home.devices == before)
        #expect(f.store.controlStatus(for: "demo-floor") == nil)
        let after = await f.store.handle(.init(method: "GET", path: "/v1/devices", body: Data()))
        #expect(after.body == api.body)
        #expect(f.store.activity.filter { $0.message.contains("colorRgb") }.isEmpty)
    }

    @Test func onlyOnlinePoweredLocalLightsAreStreamed() async throws {
        let f = Fixture(include: []); defer { f.finish() }
        f.store.home.devices = [
            .init(id: "cloud", sku: "H1", name: "Cloud", power: true, online: true),
            .init(id: "offline", sku: "H1", name: "Offline", ip: "192.168.1.20", power: true, online: false),
            .init(id: "off", sku: "H1", name: "Off", ip: "192.168.1.21", power: false, online: true),
            .init(id: "unknown", sku: "H1", name: "Unknown", ip: "192.168.1.22"),
            .init(id: "lan", sku: "H1", name: "Local", ip: "192.168.1.23", power: true)
        ]
        for device in f.store.home.devices { f.sync.setIncluded(true, for: device.id) }
        await f.start()
        f.session.onFrame?(red); f.sync.tick(now: 10)
        #expect(f.sent.map(\.deviceID) == ["lan"])
        #expect(throws: (any Error).self) {
            try f.store.streamToLight(f.store.home.devices[0], .init(deviceID: "cloud", target: .init(rgb: 0xFF0000, brightness: 50), sendsColor: true, sendsBrightness: true))
        }
    }

    @Test func pauseStopsCaptureIgnoresStaleFramesAndResumeIsExplicit() async {
        let f = Fixture(); defer { f.finish() }
        await f.start()
        let first = f.session
        first.onFrame?(red); f.sync.tick(now: 1)
        #expect(f.sent.count == 1)
        f.sync.pause(reason: "Paused while your Mac was locked.")
        #expect(f.sync.phase == .paused && first.stops == 1 && f.sync.source != nil)
        first.onFrame?(red)
        f.sync.tick(now: 10)
        #expect(f.sent.count == 1)
        await f.sync.start()
        #expect(f.sync.phase == .running && f.sessions.count == 2)
        f.sync.tick(now: 20)
        #expect(f.sent.count == 1, "The old session's last frame must not be replayed on Resume")
        f.session.onFrame?(blue); f.sync.tick(now: 21)
        #expect(f.sent.last?.target.rgb == 0x0000FF, "Resume starts from fresh content, without blending old colors")
        first.onEnd?(.sourceGone)
        #expect(f.sync.phase == .running, "A stale session cannot end the new one")
    }

    @Test func aFrameDuringStartingIsKeptButCannotStreamUntilStartCompletes() async {
        let f = Fixture(); defer { f.finish() }
        f.sync.select(f.source(gated: true))
        let starting = Task { await f.sync.start() }
        for _ in 0..<100 where f.sessions.isEmpty { await Task.yield() }
        #expect(f.sync.phase == .starting)
        f.session.onFrame?(red); f.sync.tick(now: 1)
        #expect(f.sent.isEmpty)
        f.session.release(); await starting.value
        f.sync.tick(now: 2)
        #expect(f.sent.first?.target.rgb == 0xFF0000)
    }

    @Test func shutdownCancelsReadbackQueuedByAnEarlierPause() async {
        let f = Fixture(); defer { f.finish() }
        f.store.home.devices[0].isDemo = false
        f.store.home.devices[0].ip = "192.0.2.10"
        var readbacks: [String] = []
        f.sync.readback = { readbacks.append($0.id) }
        await f.start()
        f.session.onFrame?(red); f.sync.tick(now: 1)
        f.sync.pause()
        f.store.shutdown()
        for _ in 0..<10 { await Task.yield() }
        #expect(readbacks.isEmpty, "A pending refresh must not reopen LAN after shutdown")
    }

    @Test func directShutdownDoesNotScheduleReadback() async {
        let f = Fixture(); defer { f.finish() }
        f.store.home.devices[0].isDemo = false
        f.store.home.devices[0].ip = "192.0.2.10"
        var readbacks: [String] = []
        f.sync.readback = { readbacks.append($0.id) }
        await f.start()
        f.session.onFrame?(red); f.sync.tick(now: 1)
        f.store.shutdown()
        for _ in 0..<10 { await Task.yield() }
        #expect(readbacks.isEmpty)
    }

    @Test func removingAStreamedLightRequestsItsActualState() async {
        let f = Fixture(); defer { f.finish() }
        f.store.home.devices[0].isDemo = false
        f.store.home.devices[0].ip = "192.0.2.10"
        var readbacks: [String] = []
        f.sync.readback = { readbacks.append($0.id) }
        await f.start()
        f.session.onFrame?(red); f.sync.tick(now: 1)
        #expect(f.sync.preview["demo-floor"] != nil)
        f.sync.setIncluded(false, for: "demo-floor")
        #expect(f.sync.preview["demo-floor"] == nil)
        for _ in 0..<100 where readbacks.isEmpty { await Task.yield() }
        #expect(readbacks == ["demo-floor"])
    }

    @Test func aCommandQueuedBeforeStartOwnsTheLightUntilCompletion() async {
        let f = Fixture(); defer { f.finish() }
        f.store.perform(.brightness(30), ids: ["demo-floor"])
        #expect(f.store.hasOrdinaryControl(for: "demo-floor"))
        #expect(f.sync.ownershipIssue(for: "demo-floor") != nil)
        #expect(f.sync.streamingLights.isEmpty)
        await f.start()
        for _ in 0..<100 where f.store.hasOrdinaryControl(for: "demo-floor") { await Task.yield() }
        #expect(f.sync.ownershipIssue(for: "demo-floor") == nil)
        f.session.onFrame?(red); f.sync.tick(now: 1)
        #expect(f.sent.map(\.deviceID) == ["demo-floor"])
    }

    @Test(.timeLimit(.minutes(1))) func anInflightCloudCommandBlocksStartAndEarlyIncludeAgain() async {
        let id = UUID().uuidString, gate = ScreenSyncCloudGate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenSyncCloudProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Luma-Sync-Test": id]
        let session = URLSession(configuration: configuration)
        ScreenSyncCloudProtocol.install(gate, id: id)
        let store = HomeStore(demo: true, cloud: GoveeCloud(apiKey: "synthetic-key", session: session), screenSyncDefaults: nil)
        defer { store.shutdown(); session.invalidateAndCancel(); ScreenSyncCloudProtocol.remove(id) }
        let sync = store.screenSync, capture = FakeCapture()
        var sent: [StreamUpdate] = []
        sync.send = { _, update in sent.append(update) }
        sync.settings.smoothing = 0
        // Choose cloud routing for the ordinary command, then make local sync
        // eligibility available while that command is suspended in the mock.
        store.home.devices[0].isDemo = false
        let lightID = store.home.devices[0].id
        sync.setIncluded(true, for: lightID)
        store.perform(.brightness(30), ids: [lightID])
        await gate.waitUntilRequested()
        store.home.devices[0].ip = "192.0.2.10"
        sync.select(.init(name: "Synthetic", kind: .sample, makeSession: { capture }))
        await sync.start()
        capture.onFrame?(red); sync.tick(now: 1)
        #expect(sent.isEmpty, "Start cannot race an already inflight ordinary write")
        sync.yield(lightID)
        sync.includeAgain(lightID)
        #expect(sync.excluded[lightID] != nil, "An early retry must leave manual ownership intact")
        sync.tick(now: 2)
        #expect(sent.isEmpty)
        gate.release()
        for _ in 0..<1000 where store.hasOrdinaryControl(for: lightID) { await Task.yield() }
        #expect(!store.hasOrdinaryControl(for: lightID))
        sync.includeAgain(lightID)
        sync.tick(now: 3)
        #expect(sent.map(\.deviceID) == [lightID])
    }

    @Test func leavingDemoLoadsAndRebindsRealPreferencesWithoutSavingDemoEdits() throws {
        let suite = "app.luma.tests.screen-sync.demo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ScreenSync(defaults: defaults)
        original.settings.updateHz = 4
        original.setIncluded(true, for: "real-light")
        original.setRegion(.right, for: "real-light")
        let store = HomeStore(demo: true, screenSyncDefaults: defaults)
        defer { store.shutdown() }
        #expect(store.screenSync.regions.isEmpty)
        store.screenSync.settings.updateHz = 1
        store.screenSync.setIncluded(true, for: "demo-floor")
        store.leaveDemo()
        #expect(store.screenSync.settings.updateHz == 4)
        #expect(store.screenSync.regions == ["real-light": .right])
        store.screenSync.settings.updateHz = 3
        let reloaded = ScreenSync(defaults: defaults)
        #expect(reloaded.settings.updateHz == 3)
        #expect(reloaded.regions == ["real-light": .right])
    }

    @Test func leavingADemoWithNilDefaultsStaysIsolated() {
        let store = HomeStore(demo: true, screenSyncDefaults: nil)
        defer { store.shutdown() }
        store.screenSync.settings.updateHz = 4
        store.screenSync.setIncluded(true, for: "demo-floor")
        store.leaveDemo()
        #expect(store.screenSync.settings == ScreenSyncSettings())
        #expect(store.screenSync.regions.isEmpty)
    }

    @Test func enteringDemoStopsRealSessionAndIsolatesPreferencesUntilExit() async throws {
        let suite = "app.luma.tests.screen-sync.enter-demo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = ScreenSync(defaults: defaults)
        saved.settings.updateHz = 4
        saved.settings.brightnessCap = 31
        saved.setIncluded(true, for: "real-light")
        saved.setRegion(.left, for: "real-light")

        let store = HomeStore(demo: true, screenSyncDefaults: defaults)
        defer { store.shutdown() }
        store.leaveDemo()
        store.home.devices = [] // Match the real empty-home Explore Demo path.
        let capture = FakeCapture(), sync = store.screenSync
        sync.select(.init(name: "Synthetic real source", kind: .display, makeSession: { capture }))
        await sync.start()
        capture.onFrame?(red)
        #expect(sync.phase == .running && sync.settings.updateHz == 4)

        // LightsView sets demo first, then calls loadDemo().
        store.demo = true
        store.loadDemo()
        #expect(capture.stops == 1)
        #expect(sync.phase == .idle && sync.source == nil)
        #expect(sync.regionPreview == nil && sync.preview.isEmpty)
        #expect(sync.settings == ScreenSyncSettings())
        #expect(sync.regions.isEmpty)
        sync.settings.updateHz = 1
        sync.setIncluded(true, for: "demo-floor")
        sync.setRegion(.right, for: "demo-floor")
        let untouched = ScreenSync(defaults: defaults)
        #expect(untouched.settings.updateHz == 4 && untouched.settings.brightnessCap == 31)
        #expect(untouched.regions == ["real-light": .left])

        store.leaveDemo()
        #expect(sync.phase == .idle && sync.source == nil)
        #expect(sync.settings == untouched.settings)
        #expect(sync.regions == ["real-light": .left])
    }

    @Test func stopDuringStartCancelsTheLateSession() async {
        let f = Fixture(); defer { f.finish() }
        f.sync.select(f.source(gated: true))
        let starting = Task { await f.sync.start() }
        for _ in 0..<100 where f.sessions.isEmpty { await Task.yield() }
        #expect(f.sync.phase == .starting)
        f.sync.stop()
        f.session.release()
        await starting.value
        #expect(f.sync.phase == .idle)
        #expect(f.session.stops >= 1)
    }

    @Test(arguments: [ScreenCaptureEnd.permissionDenied, .sourceGone, .userStopped, .failed("boom")])
    func captureEndingsStopCleanly(end: ScreenCaptureEnd) async {
        let f = Fixture(); defer { f.finish() }
        await f.start()
        f.session.onEnd?(end)
        #expect(f.sync.phase == .idle && f.sync.message != nil)
        #expect(f.sync.permissionDenied == (end == .permissionDenied))
        // Denied keeps the choice so the person can retry after allowing capture.
        #expect((f.sync.source != nil) == (end == .permissionDenied))
        f.session.onFrame?(red); f.sync.tick(now: 10)
        #expect(f.sent.isEmpty)
    }

    @Test func permissionDeniedAtStartIsExplained() async {
        let f = Fixture(); defer { f.finish() }
        f.sync.select(f.source(failure: .permissionDenied))
        await f.sync.start()
        #expect(f.sync.phase == .idle && f.sync.permissionDenied)
    }

    @Test func settingsPersistButCaptureNeverDoes() throws {
        let suite = "app.luma.tests.screen-sync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ScreenSync(defaults: defaults)
        first.settings.updateHz = 4
        first.setIncluded(true, for: "lamp")
        first.setRegion(.left, for: "lamp")
        let second = ScreenSync(defaults: defaults)
        #expect(second.settings.updateHz == 4 && second.regions == ["lamp": .left])
        #expect(second.phase == .idle && second.source == nil)
        defaults.set(Data(#"{"smoothing":5,"threshold":-1,"brightnessCap":1000,"updateHz":99}"#.utf8), forKey: "screenSync.settings")
        #expect(ScreenSync(defaults: defaults).settings == ScreenSyncSettings().clamped().with { $0.smoothing = 0.95; $0.threshold = 0.005; $0.brightnessCap = 100; $0.updateHz = 5 })
    }

    @Test func demoSampleFramesRunThroughTheAnalyzer() throws {
        let colors = try #require(SampleScreenCapture.frame(phase: 0))
        // Hue 0 is red on the left; bars are cropped so the picture isn't dimmed.
        #expect(colors.left.r > colors.left.g && colors.left.r > colors.left.b)
        #expect(colors.left != colors.right)
        #expect(max(colors.top.r, colors.top.g, colors.top.b) > 0.3)
    }
}

private extension ScreenSyncSettings {
    func with(_ change: (inout Self) -> Void) -> Self { var copy = self; change(&copy); return copy }
}
