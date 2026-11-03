import Foundation
import Testing
@testable import LumaCore

/// A fake home on a virtual clock: every write is recorded with its virtual time,
/// and the fake lights take the written values so restores can be checked.
@MainActor final class FakeAlertHome {
    struct Write: Equatable { let t: Double; let id: String; let command: CapabilityCommand; let restore: Bool }
    var devices: [LightDevice]
    var routes: [String: DoorbellAlertEngine.Route] = [:]
    var t = 0.0
    var writes: [Write] = []
    var logs: [String] = []
    var failPulseAfter: [String: Double] = [:]
    var failRestore: Set<String> = []
    var at: [(Double, () -> Void)] = []
    var engine: DoorbellAlertEngine!
    func makeEngine() -> DoorbellAlertEngine {
        let engine = DoorbellAlertEngine(io: .init(
            devices: { [unowned self] in self.devices },
            prepare: { [unowned self] targets in
                targets.map { d in
                    do { return .init(id: d.id, name: d.name, route: self.routes[d.id] ?? .lan, snapshot: try DoorbellAlert.snapshot(of: d)) }
                    catch { return .init(id: d.id, name: d.name, route: .lan, snapshot: nil, skip: error.localizedDescription) }
                }
            },
            pulse: { [unowned self] id, command in
                if let after = self.failPulseAfter[id], self.t >= after { throw LumaError.message("light offline") }
                self.writes.append(.init(t: self.t, id: id, command: command, restore: false)); self.apply(command, to: id)
            },
            restore: { [unowned self] id, snapshot in
                if self.failRestore.contains(id) { throw LumaError.message("light offline") }
                for command in snapshot.restoreCommands { self.writes.append(.init(t: self.t, id: id, command: command, restore: true)); self.apply(command, to: id) }
                return snapshot.matches(self.devices.first { $0.id == id }!)
            },
            log: { [unowned self] message, _ in self.logs.append(message) }))
        engine.now = { [unowned self] in self.t }
        engine.sleep = { [unowned self] seconds in
            try Task.checkCancellation()
            self.t += seconds
            let due = self.at.filter { $0.0 <= self.t }
            self.at.removeAll { $0.0 <= self.t }
            for (_, action) in due { action() }
            await Task.yield()
        }
        return engine
    }

    static let caps = ["powerSwitch", "brightness", "colorRgb", "colorTemperatureK"].map { Capability(type: "x", instance: $0) }
    init(_ devices: [LightDevice]) { self.devices = devices; engine = makeEngine() }
    static func light(_ id: String, room: String = "Hall", power: Bool? = true, brightness: Int? = 60, rgb: Int? = 0x112233, kelvin: Int? = nil) -> LightDevice {
        .init(id: id, sku: "H6008", name: id, room: room, capabilities: caps, power: power, brightness: brightness, rgb: rgb, colorTemperature: kelvin, online: true)
    }
    func apply(_ command: CapabilityCommand, to id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }), let n = command.value.number.map(Int.init) else { return }
        switch command.instance {
        case "powerSwitch": devices[i].power = n == 1
        case "brightness": devices[i].brightness = n
        case "colorRgb": devices[i].rgb = n; devices[i].colorTemperature = 0
        case "colorTemperatureK": devices[i].colorTemperature = n
        default: break
        }
    }
    func configure(_ edit: (inout DoorbellAlertConfig) -> Void = { _ in }) {
        var config = DoorbellAlertConfig(); config.enabled = true; config.rooms = ["Hall"]; config.durationSeconds = 6; config.pulseSeconds = 2; config.rgb = 0x2F7BFF
        edit(&config); engine.config = config
    }
    func ring(_ id: String = UUID().uuidString) async -> DoorbellAlertEngine.Outcome {
        let outcome = engine.trigger(eventID: id); await engine.settle(); return outcome
    }
    func pulses(_ id: String) -> [Write] { writes.filter { $0.id == id && !$0.restore } }
    func restores(_ id: String) -> [CapabilityCommand] { writes.filter { $0.id == id && $0.restore }.map(\.command) }
}

@MainActor struct DoorbellAlertTests {
    @Test func timedPulseThenExactRestoreIncludingOffLampAndCloudHold() async {
        let original = [FakeAlertHome.light("lamp"), FakeAlertHome.light("off-lamp", power: false, brightness: 30, rgb: nil, kelvin: 2700), FakeAlertHome.light("cloud", rgb: 0xFF0000)]
        let home = FakeAlertHome(original)
        home.routes["cloud"] = .cloud
        home.configure()
        #expect(await home.ring("e1") == .started)

        // First frame: power only for the off lamp, then the alert color at full brightness.
        #expect(home.pulses("off-lamp").prefix(3).map(\.command) == [.power(true), .rgb(0x2F7BFF), .brightness(100)])
        #expect(home.pulses("lamp").prefix(2).map(\.command) == [.rgb(0x2F7BFF), .brightness(100)])
        // LAN lights pulse between 100% and 20%, at most once per half cycle (≤ 0.5 Hz full cycles).
        let lamp = home.pulses("lamp").dropFirst(2)
        #expect(lamp.map { $0.command.value.number } == [20, 100, 20, 100, 20].map { Double($0) })
        for (a, b) in zip(home.pulses("lamp"), home.pulses("lamp").dropFirst()) where a.command.instance == "brightness" { #expect(b.t - a.t >= 0.99) }
        // The cloud light holds the color: two writes, no pulse train.
        #expect(home.pulses("cloud").map(\.command) == [.rgb(0x2F7BFF), .brightness(100)])
        #expect(home.pulses("lamp").last!.t <= 6.2)
        // Restore: color or white, brightness, then power, so the off lamp keeps no hidden alert color.
        #expect(home.restores("off-lamp") == [.kelvin(2700), .brightness(30), .power(false)])
        #expect(home.restores("lamp") == [.rgb(0x112233), .brightness(60), .power(true)])
        for light in original { #expect(try! DoorbellAlert.snapshot(of: light).matches(home.devices.first { $0.id == light.id }!)) }
        #expect(home.engine.status.hasPrefix("Flashed 3 lights; restored 3"))
        #expect(home.engine.phase == .idle)
    }

    @Test func unknownStateIsNeverFlashedOrGuessed() async {
        let home = FakeAlertHome([FakeAlertHome.light("no-power", power: nil), FakeAlertHome.light("no-color", rgb: nil), FakeAlertHome.light("ok")])
        home.configure()
        #expect(await home.ring() == .started)
        #expect(home.writes.allSatisfy { $0.id == "ok" })
        #expect(home.logs.contains { $0.contains("no-power (power unknown)") && $0.contains("no-color (color unknown)") })
    }

    @Test func manualChangeWinsAndCancelsThatLightsRestore() async {
        let home = FakeAlertHome([FakeAlertHome.light("a"), FakeAlertHome.light("b")])
        home.configure()
        home.at = [(2.5, { home.engine.yield("a") })]
        _ = await home.ring()
        #expect(home.pulses("a").allSatisfy { $0.t < 2.5 })
        #expect(home.restores("a").isEmpty)
        #expect(home.restores("b") == [.rgb(0x112233), .brightness(60), .power(true)])
        #expect(home.engine.status.contains("1 left as changed during the alert"))
    }

    @Test func repeatedRingsCoalesceDeduplicateAndCoolDown() async {
        let home = FakeAlertHome([FakeAlertHome.light("a")])
        home.configure { $0.cooldownSeconds = 20 }
        #expect(home.engine.trigger(eventID: "e1") == .started)
        #expect(home.engine.trigger(eventID: "e2") == .coalesced)
        #expect(home.engine.trigger(eventID: "e1") == .duplicate)
        await home.engine.settle()
        let firstAlertWrites = home.writes.count
        #expect(home.engine.trigger(eventID: "e3") == .cooldown)
        #expect(home.writes.count == firstAlertWrites)
        home.t += 20
        #expect(await home.ring("e4") == .started)
        #expect(home.pulses("a").filter { $0.command == .rgb(0x2F7BFF) }.count == 2) // two alerts, never stacked
    }

    @Test func failedWriteStopsThatLightAndStillTriesItsRestore() async {
        let home = FakeAlertHome([FakeAlertHome.light("flaky"), FakeAlertHome.light("ok")])
        home.configure()
        home.failPulseAfter["flaky"] = 2
        home.failRestore = ["flaky"]
        _ = await home.ring()
        #expect(home.pulses("flaky").allSatisfy { $0.t < 2 })
        #expect(home.pulses("ok").last!.t >= 5)
        #expect(home.engine.status.contains("restored 1") && home.engine.status.contains("couldn't restore flaky: light offline"))
    }

    @Test func stopEndsEarlyAndRestores() async {
        let home = FakeAlertHome([FakeAlertHome.light("a")])
        home.configure { $0.durationSeconds = 30 }
        home.at = [(1.5, { home.engine.stop() })]
        _ = await home.ring()
        #expect(home.pulses("a").last!.t < 2)
        #expect(home.restores("a") == [.rgb(0x112233), .brightness(60), .power(true)])
    }

    @Test func quietHoursCapOrSkip() async throws {
        let home = FakeAlertHome([FakeAlertHome.light("a")])
        let night = try #require(Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date()))
        home.engine.date = { night }
        home.configure { $0.quietStart = 22 * 60; $0.quietEnd = 7 * 60; $0.quietBrightnessCap = 0 }
        #expect(await home.ring() == .quiet)
        #expect(home.writes.isEmpty)
        home.configure { $0.quietStart = 22 * 60; $0.quietEnd = 7 * 60; $0.quietBrightnessCap = 30 }
        #expect(await home.ring() == .started)
        #expect(home.pulses("a").compactMap { $0.command.instance == "brightness" ? $0.command.value.number : nil }.max() == 30)
        #expect(!DoorbellAlert.inQuietHours(home.engine.config, at: try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))))
    }

    @Test func roomMembershipIsResolvedAtRingTimeAndAppliancesExcluded() {
        var config = DoorbellAlertConfig(); config.rooms = ["Hall"]; config.deviceIDs = ["desk"]
        var heater = FakeAlertHome.light("heater"); heater.deviceType = "devices.types.heater"
        var moved = FakeAlertHome.light("moved", room: "Office")
        let desk = FakeAlertHome.light("desk", room: "Office")
        #expect(DoorbellAlert.targets(config, devices: [heater, moved, desk]).map(\.id) == ["desk"])
        moved.room = "Hall"
        #expect(DoorbellAlert.targets(config, devices: [heater, moved, desk]).map(\.id) == ["moved", "desk"])
    }

    @Test func cloudLightsAreNotReusedWithinAMinute() async {
        let home = FakeAlertHome([FakeAlertHome.light("cloud")])
        home.routes["cloud"] = .cloud
        home.configure { $0.cooldownSeconds = 0 }
        _ = await home.ring()
        let count = home.writes.count
        _ = await home.ring()
        #expect(home.writes.count == count)
        #expect(home.logs.contains { $0.contains("cloud limit") })
    }

    @Test func shutdownHandsBackOwedRestores() async {
        let home = FakeAlertHome([FakeAlertHome.light("a"), FakeAlertHome.light("b")])
        home.configure { $0.durationSeconds = 30 }
        var owed: [(id: String, route: DoorbellAlertEngine.Route, snapshot: AlertSnapshot)] = []
        home.at = [(3, { owed = home.engine.takePendingRestores() })]
        home.engine.trigger(eventID: "x")
        await home.engine.settle()
        #expect(owed.map(\.id) == ["a", "b"])
        #expect(owed.first?.snapshot.restoreCommands == [.rgb(0x112233), .brightness(60), .power(true)])
        #expect(home.writes.allSatisfy { !$0.restore })
        #expect(home.engine.phase == .idle)
    }

    @Test func configValidationBoundsFlashRateAndRelayAddress() throws {
        var config = DoorbellAlertConfig()
        try config.validate()
        config.pulseSeconds = 1; #expect(throws: LumaError.self) { try config.validate() }
        config.pulseSeconds = 2; config.relayURL = "http://relay.example"; #expect(throws: LumaError.self) { try config.validate() }
        config.relayURL = "https://relay.example?token=x"; #expect(throws: LumaError.self) { try config.validate() }
        config.relayURL = "https://relay.example"; config.quietStart = 60; #expect(throws: LumaError.self) { try config.validate() }
        let decoded = try JSONDecoder().decode(DoorbellAlertConfig.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(decoded.enabled && decoded.durationSeconds == 15)
    }
}

/// Stubbed relay: checks the bearer header and returns canned long-poll replies.
final class RelayStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (Int, String) = (204, "")
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct AlexaRelayClientTests {
    let session: URLSession = { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [RelayStub.self]; return URLSession(configuration: c) }()
    let token = String(repeating: "t", count: 43)

    @Test func longPollKeepsOnlyFreshWellFormedEvents() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        RelayStub.seen = []
        RelayStub.reply = (200, #"{"events":[{"id":"m1","type":"activate","issuedAt":1800000000},{"id":"old","type":"activate","issuedAt":1799999000},{"id":"m2","type":"rm -rf","issuedAt":1800000000}]}"#)
        let client = try AlexaRelayClient(base: "https://relay.example/", token: token, session: session)
        #expect(try await client.next(now: now).map(\.id) == ["m1"])
        #expect(RelayStub.seen.last?.url?.absoluteString == "https://relay.example/hub/next")
        #expect(RelayStub.seen.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        RelayStub.reply = (204, "")
        #expect(try await client.next(now: now).isEmpty)
        RelayStub.reply = (401, "")
        await #expect(throws: LumaError.self) { try await client.next(now: now) }
    }

    @Test func rejectsPlainHTTPAndShortTokens() {
        #expect(throws: LumaError.self) { try AlexaRelayClient(base: "http://relay.example", token: token) }
        #expect(throws: LumaError.self) { try AlexaRelayClient(base: "https://relay.example", token: "short") }
    }
}
