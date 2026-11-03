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
    @Test func delayedDemoSceneStaysRunningAndBlocksOtherRunsUntilStopped() async throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let slow = LightScene(name: "Slow", steps: [.init(deviceID: "demo-floor", command: .power(false), delayMilliseconds: 10000)])
        let other = LightScene(name: "Other", steps: [.init(deviceID: "demo-floor", command: .power(true))])
        try store.runScene(slow)
        await Task.yield()
        // The scene card shows Running/Stop for `slow` and a disabled Run for every other scene in this state.
        #expect(store.runningSceneID == slow.id && store.runs.first?.status == "running")
        #expect(throws: (any Error).self) { try store.runScene(other) }
        store.stopScene()
        for _ in 0..<100 where store.runningSceneID != nil { await Task.yield() }
        #expect(store.runningSceneID == nil && store.runs.first?.status == "cancelled")
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
        #expect(old.dreamViewDrafts == nil && old.goveeHomeGroups == nil && old.goveeHomeAutomations == nil)
        var saved = SavedHome()
        saved.goveeHomeGroups = [.init(id: 1, name: "DV", enabled: true, reportedLightCount: 2, mainDevice: "aa", mainSKU: "H6097", isDreamView: true)]
        saved.goveeHomeAutomations = [.init(id: 2, name: "Night", enabled: true, times: [.init(hour: 22, minute: 0)], repeatDays: [1], targets: [.init(sku: "H6056", name: "Bars", isDreamView: false)])]
        let back = try JSONDecoder().decode(SavedHome.self, from: JSONEncoder.pretty.encode(saved))
        #expect(back.goveeHomeGroups == saved.goveeHomeGroups && back.goveeHomeAutomations == saved.goveeHomeAutomations)
    }
    @Test func dreamViewDraftIsStoredLocallyAndSignInIsOffInDemo() async throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        store.saveDreamViewDraft(.init(members: [.init(deviceID: "demo-strip", areas: [2, 3])]), for: "demo-tv")
        #expect(store.dreamViewDraft(for: "demo-tv").members.map(\.areas) == [[2, 3]])
        let decoded = try JSONDecoder().decode(SavedHome.self, from: JSONEncoder.pretty.encode(store.home))
        #expect(decoded.dreamViewDrafts?["demo-tv"]?.members.first?.deviceID == "demo-strip")
        store.saveDreamViewDraft(.init(), for: "demo-tv")
        #expect(store.home.dreamViewDrafts == nil)
        await #expect(throws: (any Error).self) { try await store.signInToGoveeHome(email: "a@b.c", password: "p", code: nil) }
        #expect(!store.accountSignedIn)
        #expect(DreamViewDraft.memberLimit(sku: "h66a0") == 10 && DreamViewDraft.memberLimit(sku: "H6008") == nil)
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
    @Test func roomImportAppliesOnlySelectedRows() throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let file = #"{"data":{"groups":[{"groupId":1,"groupName":"Den"}],"devices":[{"device":"demo-floor","sku":"Demo lamp","groupId":1},{"device":"demo-bed","sku":"Demo bulb","groupId":1}]}}"#
        let plan = GoveeHomeImport.plan(try GoveeHomeImport.parse(Data(file.utf8)), devices: store.home.devices)
        #expect(plan.changes.allSatisfy { !$0.selectedByDefault })
        store.applyRoomImport(plan.changes.filter { $0.deviceID == "demo-floor" })
        #expect(store.devices.first { $0.id == "demo-floor" }?.room == "Den")
        #expect(store.devices.first { $0.id == "demo-bed" }?.room == "Bedroom")
    }
}

@MainActor struct ParityFeatureTests {
    @Test func sceneSavesRestorePointThatPutsLightsBack() async throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let before = try #require(store.devices.first { $0.id == "demo-floor" })
        try store.runScene(LightScene(name: "Off", steps: [.init(deviceID: "demo-floor", command: .power(false))]))
        for _ in 0..<200 where store.runningSceneID != nil { await Task.yield() }
        #expect(store.devices.first { $0.id == "demo-floor" }?.power == false)
        let point = try #require(store.restorePoint)
        #expect(point.steps.allSatisfy { $0.deviceID == "demo-floor" } && point.steps.first?.command == .power(true))
        try store.restoreBeforeScene()
        #expect(store.restorePoint == nil)
        for _ in 0..<200 where store.runningSceneID != nil { await Task.yield() }
        let after = try #require(store.devices.first { $0.id == "demo-floor" })
        #expect(after.power == true && after.brightness == before.brightness && after.rgb == before.rgb)
    }

    @Test func backupRoundTripsAndRestoresOnlyOntoKnownLights() throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        store.home.devices = store.home.devices.map { var d = $0; d.isDemo = false; return d }
        store.rename("Sofa", id: "demo-strip")
        let scene = store.home.scenes[0]
        store.home.schedules = [SceneSchedule(sceneID: scene.id, hour: 7, minute: 30)]
        var backup = try HomeBackup.decode(store.backup().encoded())
        #expect(backup.scenes == store.home.scenes && backup.schedules == store.home.schedules)
        #expect(backup.lights.first { $0.id == "demo-strip" }?.customName == "Sofa")
        backup.lights.append(.init(id: "gone", sku: "H1", customName: "Gone", room: "Attic"))
        backup.lights[0].room = "Studio"
        backup.schedules.append(SceneSchedule(sceneID: UUID(), hour: 1, minute: 0)) // its scene isn't in the backup
        store.rename("", id: "demo-strip"); store.home.scenes = []; store.home.schedules = []
        let result = try store.restore(backup)
        #expect(result.lightsNotFound == 1 && result.lightsUpdated == backup.lights.count - 1)
        #expect(store.devices.first { $0.id == "demo-strip" }?.customName == "Sofa")
        #expect(store.devices.first { $0.id == backup.lights[0].id }?.room == "Studio")
        #expect(store.home.scenes.count == backup.scenes.count && store.home.schedules.count == 1)
        var future = backup; future.version = HomeBackup.currentVersion + 1
        #expect(throws: (any Error).self) { try store.restore(future) }
        #expect(throws: (any Error).self) { try HomeBackup.decode(Data(#"{"scenes":[]}"#.utf8)) }
        // No secrets or network details in the file.
        let text = String(decoding: try store.backup().encoded(), as: UTF8.self)
        #expect(!text.contains("webhookPort") && !text.contains("\"ip\""))
    }

    @Test func roomWhiteClampsToEachLightsRangeAndGroupLookupIgnoresCase() async throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let i = try #require(store.home.devices.firstIndex { $0.id == "demo-desk" })
        store.home.devices[i].capabilities = store.home.devices[i].capabilities.map { cap in
            cap.instance == "colorTemperatureK" ? Capability(type: cap.type, instance: cap.instance, parameters: .object(["dataType": .string("INTEGER"), "range": .object(["min": .number(2700), "max": .number(6500)])])) : cap
        }
        store.performWhite(9000, ids: ["demo-desk"])
        for _ in 0..<200 where store.controlStatus(for: "demo-desk") != nil { await Task.yield() }
        #expect(store.devices.first { $0.id == "demo-desk" }?.colorTemperature == 6500)
        store.accountGroups = try GoveeHomeImport.parseGroups(Data(#"{"data":{"list":[{"groupId":1,"sceneFeastId":9,"name":"Den DV","type":10,"enable":1,"deviceCount":3,"mainDevice":{"device":"DEMO-TV","sku":"H6097"}}]}}"#.utf8))
        #expect(store.dreamViewGroup(for: "demo-tv")?.name == "Den DV")
        #expect(store.dreamViewGroup(for: "demo-desk") == nil)
    }
}
