import Foundation
import Testing
import LumaCore
@testable import LumaUI

@MainActor struct DoorbellAlertStoreTests {
    /// Runs the engine on a virtual clock; `at` actions fire when virtual time passes them.
    final class Clock { var t = 0.0; var at: [(Double, () -> Void)] = [] }
    func virtualClock(_ store: HomeStore, _ clock: Clock = Clock()) -> Clock {
        store.doorbell.engine.now = { clock.t }
        store.doorbell.engine.sleep = { seconds in
            try Task.checkCancellation()
            clock.t += seconds
            let due = clock.at.filter { $0.0 <= clock.t }
            clock.at.removeAll { $0.0 <= clock.t }
            for (_, action) in due { action() }
            await Task.yield()
        }
        return clock
    }
    func ring(_ store: HomeStore, id: String = UUID().uuidString, timestamp: Double = Date().timeIntervalSince1970) -> WebhookResponse? {
        let body = try! JSONEncoder().encode(["eventId": JSONValue.string(id), "timestamp": .number(timestamp)])
        return store.doorbell.handle(.init(method: "POST", path: "/v1/alerts/doorbell", body: body), path: ["v1", "alerts", "doorbell"])
    }
    func outcome(_ response: WebhookResponse?) -> String? { response.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0.body) }?["outcome"]?.string }

    /// Actual cloud transport (stubbed URLSession): a fresh state read, the alert frame,
    /// the exact restore, and a confirming read, in that order on the wire.
    @Test(.timeLimit(.minutes(1))) func cloudLightGetsFreshReadAlertFrameAndExactRestoreOnTheWire() async throws {
        let state = #"{"code":200,"payload":{"device":"porch","sku":"H6008","capabilities":[{"instance":"online","state":{"value":true}},{"instance":"powerSwitch","state":{"value":1}},{"instance":"brightness","state":{"value":60}},{"instance":"colorRgb","state":{"value":1122867}},{"instance":"colorTemperatureK","state":{"value":0}}]}}"#
        let fixture = InteractionFixture([.init(body: state), .init(), .init(), .init(), .init(), .init(), .init(body: state)])
        defer { fixture.finish() }
        let store = fixture.store
        store.home.devices = [.init(id: "porch", sku: "H6008", name: "Porch", room: "Hall", capabilities: ["powerSwitch", "brightness", "colorRgb", "colorTemperatureK"].map {
            Capability(type: $0 == "powerSwitch" ? "devices.capabilities.on_off" : $0 == "brightness" ? "devices.capabilities.range" : "devices.capabilities.color_setting", instance: $0)
        }, power: false, brightness: 5, rgb: 0xFFFFFF, online: true)] // stale saved state: must not be what's restored
        try store.doorbell.update { $0.enabled = true; $0.rooms = ["Hall"]; $0.rgb = 0x2F7BFF; $0.durationSeconds = 5 }
        _ = virtualClock(store)
        #expect(outcome(ring(store)) == "started")
        await store.doorbell.settle()
        #expect(fixture.script.paths.map { $0.split(separator: "/").last.map(String.init) ?? "" } == ["state", "control", "control", "control", "control", "control", "state"])
        #expect(fixture.script.commands.map { "\($0["instance"]?.string ?? "")=\(Int($0["value"]?.number ?? -1))" }
                == ["colorRgb=\(0x2F7BFF)", "brightness=100", "colorRgb=\(0x112233)", "brightness=60", "powerSwitch=1"])
        #expect(store.doorbell.status.hasPrefix("Flashed 1 light; restored 1"))
    }

    @Test func restoreUsesLANOnlyForValuesTheLANEncoderAccepts() {
        #expect(DoorbellAlertController.lanEligible(.kelvin(2700)) && DoorbellAlertController.lanEligible(.rgb(0x112233)))
        #expect(!DoorbellAlertController.lanEligible(.kelvin(1500)) && !DoorbellAlertController.lanEligible(.kelvin(9500)))
    }

    @Test func webhookRingIsAuthenticatedUpstreamAndRejectsReplaysAndBadInput() async {
        let store = HomeStore(demo: true, screenSyncDefaults: nil)
        defer { store.shutdown() }
        _ = virtualClock(store)
        #expect(ring(store, id: "short")?.status == 400)
        #expect(ring(store, id: "has space in it")?.status == 400)
        #expect(ring(store, timestamp: Date().timeIntervalSince1970 - 600)?.status == 409)
        #expect(outcome(ring(store, id: "ring-0001")) == "started")
        #expect(outcome(ring(store, id: "ring-0001")) == "duplicate")
        #expect(outcome(ring(store, id: "ring-0002")) == "coalesced")
        await store.doorbell.settle()
        let status = store.doorbell.handle(.init(method: "GET", path: "/v1/alerts/doorbell", body: Data()), path: ["v1", "alerts", "doorbell"])
        #expect(status?.status == 200)
        #expect(store.doorbell.handle(.init(method: "GET", path: "/v1/devices", body: Data()), path: ["v1", "devices"]) == nil)
    }

    @Test func manualControlDuringAlertWinsAndOthersAreRestored() async {
        let store = HomeStore(demo: true, screenSyncDefaults: nil)
        defer { store.shutdown() }
        let before = store.home.devices
        let clock = virtualClock(store)
        var heldDuringFlash = false
        clock.at = [(1, { heldDuringFlash = store.hasOrdinaryControl(for: "demo-strip") }), (2, { store.perform(.brightness(10), ids: ["demo-floor"]) })]
        store.doorbell.test()
        await store.doorbell.engine.settle()
        #expect(store.doorbell.phase == .idle) // the UI learns the alert ended without a separate sync
        for _ in 0..<20 where store.home.devices.first(where: { $0.id == "demo-floor" })?.brightness != 10 { await Task.yield() }
        #expect(store.home.devices.first { $0.id == "demo-floor" }?.brightness == 10)
        for id in ["demo-strip", "demo-tv"] {
            let was = before.first { $0.id == id }!, now = store.home.devices.first { $0.id == id }!
            #expect(now.power == was.power && now.brightness == was.brightness && now.rgb == was.rgb, "\(id)")
        }
        #expect(store.doorbell.status.contains("1 left as changed during the alert"))
        #expect(heldDuringFlash) // Screen Sync frames wait while a light flashes
    }

    @Test func dreamViewLightsAreSkippedAndShutdownRestoresBestEffort() async {
        let store = HomeStore(demo: true, screenSyncDefaults: nil)
        let i = store.home.devices.firstIndex { $0.id == "demo-tv" }!
        store.home.devices[i].dreamView = true
        let before = store.home.devices
        let clock = virtualClock(store)
        clock.at = [(2, { store.shutdown() })]
        try? store.doorbell.update { $0.durationSeconds = 30 }
        store.doorbell.test()
        await store.doorbell.settle()
        #expect(store.activity.contains { $0.message.contains("TV backlight (DreamView is on)") })
        #expect(store.home.devices.map(\.brightness) == before.map(\.brightness))
        #expect(store.home.devices.map(\.rgb) == before.map(\.rgb))
    }
}
