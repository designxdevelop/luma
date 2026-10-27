import Foundation
import Testing
import LumaCore
@testable import LumaUI

@MainActor struct HomeWorkflowTests {
    @Test func webhookActionExecutesAndExposesRunStatus() async throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        for index in store.home.devices.indices where store.home.devices[index].room == "Living room" {
            store.home.devices[index].colorTemperature = 3000
        }
        let response = await store.handle(.init(method: "POST", path: "/v1/actions", body: Data(##"{"target":"room:Living room","power":false,"brightness":25,"color":"#FF8800"}"##.utf8)))
        #expect(response.status == 202)
        let accepted = try JSONDecoder().decode(JSONValue.self, from: response.body)
        let url = try #require(accepted["statusURL"]?.string)
        for _ in 0..<100 where store.runningSceneID != nil { await Task.yield() }
        #expect(store.devices.filter { $0.room == "Living room" }.allSatisfy { $0.power == false && $0.brightness == 25 && $0.rgb == 0xFF8800 && $0.colorTemperature == 0 })
        #expect(store.devices.first { $0.id == "demo-desk" }?.power == true)
        let status = await store.handle(.init(method: "GET", path: url, body: Data()))
        #expect(status.status == 200)
        #expect(try JSONDecoder().decode(JSONValue.self, from: status.body)["status"]?.string == "completed")
    }
    @Test func rejectsEntireInvalidActionBeforeChangingLights() async {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let original = store.devices
        let result = await store.handle(.init(method: "POST", path: "/v1/actions", body: Data(##"{"target":"all","power":false,"brightness":200}"##.utf8)))
        #expect(result.status == 400)
        #expect(store.devices == original)
        #expect(store.runs.isEmpty)
    }
    @Test func savedSceneWebhookAndCancellation() async throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let scene = LightScene(name: "Delayed", steps: [.init(deviceID: "demo-floor", command: .power(false), delayMilliseconds: 10000)])
        try store.saveScene(scene)
        let result = await store.handle(.init(method: "POST", path: "/v1/scenes/\(scene.id)/run", body: Data("{}".utf8)))
        #expect(result.status == 202)
        store.stopScene()
        for _ in 0..<100 where store.runningSceneID != nil { await Task.yield() }
        #expect(store.runs.first?.status == "cancelled")
        #expect(store.devices.first { $0.id == "demo-floor" }?.power == true)
    }
    @Test func customNameOverlaysWithoutLosingTheDeviceName() {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        store.rename("  Reading nook  ", id: "demo-floor")
        #expect(store.devices.first { $0.id == "demo-floor" }?.name == "Reading nook")
        #expect(store.home.devices.first { $0.id == "demo-floor" }?.name == "Corner glow")
        store.rename(String(repeating: "x", count: 100), id: "demo-floor")
        #expect(store.devices.first { $0.id == "demo-floor" }?.name.count == 64)
        store.rename("  ", id: "demo-floor")
        #expect(store.devices.first { $0.id == "demo-floor" }?.name == "Corner glow")
        store.rename("Corner glow", id: "demo-floor")
        #expect(store.home.devices.first { $0.id == "demo-floor" }?.customName == nil)
    }
    @Test func customNameSurvivesCloudRefreshAndLANDiscovery() {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        store.rename("Reading nook", id: "demo-floor")
        let cap = Capability(type: "devices.capabilities.on_off", instance: "powerSwitch")
        store.merge(.init(id: "demo-floor", sku: "Demo lamp", name: "Cloud says new name", capabilities: [cap], power: false, online: true))
        store.merge(.init(id: "DEMO-FLOOR", sku: "", name: "LAN name", ip: "192.168.1.9", power: true, online: true))
        let light = store.devices.first { $0.id == "demo-floor" }
        #expect(light?.name == "Reading nook")
        #expect(store.home.devices.first { $0.id == "demo-floor" }?.name == "Cloud says new name")
        store.rename("", id: "demo-floor")
        #expect(store.devices.first { $0.id == "demo-floor" }?.name == "Cloud says new name")
    }
    @Test func customNamePersistsInSavedHomeAndOldFilesStillDecode() throws {
        var home = SavedHome()
        home.devices = [.init(id: "a", sku: "H1", name: "Own", customName: "Mine"), .init(id: "b", sku: "H1", name: "Plain")]
        let decoded = try JSONDecoder().decode(SavedHome.self, from: JSONEncoder.pretty.encode(home))
        #expect(decoded.devices.map(\.customName) == ["Mine", nil])
        let legacy = Data(#"{"devices":[{"id":"a","sku":"H1","name":"Own","room":"Den","capabilities":[],"isDemo":false}],"scenes":[],"schedules":[],"webhookPort":8787,"allowLAN":false}"#.utf8)
        let old = try JSONDecoder().decode(SavedHome.self, from: legacy)
        #expect(old.devices.first?.name == "Own" && old.devices.first?.customName == nil)
    }
    @Test func staticAndDynamicScenesBothRemainSelectable() {
        let a = Capability(type: "devices.capabilities.dynamic_scene", instance: "lightScene", parameters: .object(["dataType": .string("ENUM"), "options": .array([.object(["name": .string("Static"), "value": .number(1)])])]))
        let b = Capability(type: a.type, instance: a.instance, parameters: .object(["dataType": .string("ENUM"), "options": .array([.object(["name": .string("Dynamic"), "value": .number(2)])])]))
        #expect(mergedCapabilities([a], [b]).first?.parameters?["options"]?.array?.count == 2)
    }
    @Test(arguments: ["brightness", "colorRgb", "colorTemperatureK"])
    func advancedSceneRejectsExtremeNumbersBeforeVisualEditing(instance: String) throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let type = instance == "brightness" ? "devices.capabilities.range" : "devices.capabilities.color_setting"
        let scene = LightScene(name: "Extreme value", steps: [
            .init(deviceID: "demo-floor", command: .init(type: type, instance: instance, value: .number(1e100)))
        ])
        let text = String(decoding: try JSONEncoder().encode(scene), as: UTF8.self)
        #expect(throws: (any Error).self) { try SceneEditor.validatedJSON(text, devices: store.devices) }
    }
    @Test func editorRepairsLegacyStepIDsWithoutDroppingCommands() {
        let step = SceneStep(deviceID: "lamp", command: .power(true))
        let repaired = SceneEditor.editableSteps([step, step])
        #expect(Set(repaired.map(\.id)).count == 2)
        #expect(repaired.map(\.command) == [step.command, step.command])
        #expect(repaired.first?.id == step.id)
    }
    @Test func sceneWhiteEditorMatchesAdvertisedLimits() {
        let capability = Capability(type: "devices.capabilities.color_setting", instance: "colorTemperatureK", parameters: .object([
            "dataType": .string("INTEGER"), "range": .object(["min": .number(2700), "max": .number(6500)])
        ]))
        let device = LightDevice(id: "white", sku: "Test", name: "White lamp", capabilities: [capability])
        #expect(sceneWhiteRange(for: device) == 2700...6500)
        #expect(sceneWhiteRange(for: nil) == 2000...9000)
    }
}
