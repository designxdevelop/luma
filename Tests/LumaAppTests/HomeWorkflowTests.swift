import Foundation
import Testing
import LumaCore
@testable import LumaUI

/// A fresh, not-yet-created temp folder for a test store, so no test reads or writes the real Luma folder.
func testFolder() -> URL { FileManager.default.temporaryDirectory.appending(path: "luma-tests/\(UUID().uuidString)") }

@MainActor struct HomeWorkflowTests {
    @Test func webhookActionExecutesAndExposesRunStatus() async throws {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
    @Test func storeFolderKeepsDemoAndLeavingDemoOffTheRealLumaFolder() throws {
        let folder = testFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var saved = SavedHome(); saved.devices = [.init(id: "temp-lamp", sku: "H1", name: "Temp lamp")]
        try HomeStorage(folder: folder).save(saved)
        let store = HomeStore(demo: true, folder: folder); defer { store.shutdown() }
        #expect(store.storageFolder == folder)
        store.leaveDemo()
        #expect(store.home.devices.map(\.id) == ["temp-lamp"])
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "activity.log").path))
        store.rename("Mine", id: "temp-lamp")
        #expect(try HomeStorage(folder: folder).load().devices.first?.customName == "Mine")
    }
    @Test func rejectsEntireInvalidActionBeforeChangingLights() async {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let original = store.devices
        let result = await store.handle(.init(method: "POST", path: "/v1/actions", body: Data(##"{"target":"all","power":false,"brightness":200}"##.utf8)))
        #expect(result.status == 400)
        #expect(store.devices == original)
        #expect(store.runs.isEmpty)
    }
    @Test func savedSceneWebhookAndCancellation() async throws {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
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

    static func local(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func unreadableScheduleSidecarIsKeptAndPausesLegacySchedulesAndSync() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "luma-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "schedule-owners.json")
        #expect(try HomeStore.readIfPresent([UUID: String].self, file) == nil, "missing is empty, not unreadable")
        try Data("{\"not\": a newer schema".utf8).write(to: file)
        #expect(throws: (any Error).self) { try HomeStore.readIfPresent([UUID: String].self, file) }
        let id = UUID()
        try JSONEncoder().encode([id: "mac"]).write(to: file)
        #expect(try HomeStore.readIfPresent([UUID: String].self, file) == [id: "mac"])

        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let scene = try #require(store.home.scenes.first)
        store.home.schedules = [SceneSchedule(sceneID: scene.id, hour: 7, minute: 0)]
        store.canSaveSchedules = false
        #expect(throws: (any Error).self) { try store.syncSnapshot() }
        store.tickSchedules(now: Self.local(1, 6, 59, 50)); store.tickSchedules(now: Self.local(1, 7, 0, 10))
        #expect(store.runs.isEmpty, "ownership is unknown, so the legacy scheduler runs nothing")
        store.canSaveSchedules = true
        #expect(try store.syncSnapshot()["schedule:\(store.home.schedules[0].id)/value"] != nil)
    }

    @Test func legacySchedulerCatchesUpAfterSleepAndLogsMissedRuns() throws {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        store.canSaveSchedules = true
        let scene = try #require(store.home.scenes.first)
        store.home.schedules = [SceneSchedule(sceneID: scene.id, hour: 7, minute: 0)]
        // Woke at 7:01: the 7:00 run is inside the grace window and runs once.
        store.tickSchedules(now: Self.local(1, 6, 59, 50)); store.tickSchedules(now: Self.local(1, 7, 1, 30))
        #expect(store.runs.count == 1)
        #expect(store.home.schedules[0].lastRunMinute == store.home.schedules[0].minuteKey(Self.local(1, 7, 0)))
        store.tickSchedules(now: Self.local(1, 7, 1, 45))
        #expect(store.runs.count == 1)
        // Woke at 7:05: past the grace window, so it's logged as missed instead of dropped silently.
        store.tickSchedules(now: Self.local(2, 6, 59, 50)); store.tickSchedules(now: Self.local(2, 7, 5))
        #expect(store.runs.count == 1)
        #expect(store.activity.first?.message.contains("Missed a schedule") == true)
        // lastRunMinute still prevents a second run of the same minute.
        store.home.schedules[0].lastRunMinute = store.home.schedules[0].minuteKey(Self.local(3, 7, 0))
        store.tickSchedules(now: Self.local(3, 6, 59, 50))
        let entries = store.activity.count
        store.tickSchedules(now: Self.local(3, 7, 0, 20))
        #expect(store.runs.count == 1 && store.activity.count == entries)
    }

    @Test func schedulesDueInTheSameMinuteBothRunInOrder() async throws {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let (first, second) = (store.home.scenes[0], store.home.scenes[1])
        store.home.schedules = [SceneSchedule(sceneID: first.id, hour: 7, minute: 0), SceneSchedule(sceneID: second.id, hour: 7, minute: 0),
                                SceneSchedule(sceneID: second.id, hour: 7, minute: 0)]
        store.tickSchedules(now: Self.local(1, 6, 59, 50)); store.tickSchedules(now: Self.local(1, 7, 0, 10))
        #expect(store.runs.map(\.sceneID) == [first.id], "the second waits for the first")
        store.home.schedules[2].enabled = false // turned off while queued: dropped
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        store.tickSchedules(now: Self.local(1, 7, 0, 25))
        #expect(store.runs.map(\.sceneID) == [second.id, first.id])
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        store.tickSchedules(now: Self.local(1, 7, 0, 40)); store.tickSchedules(now: Self.local(1, 7, 1, 0))
        #expect(store.runs.count == 2, "never twice for the same minute")
    }

    @Test func scheduleQueuedBehindASceneLongerThanTheGraceIsMissed() async throws {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let slow = LightScene(name: "Slow", steps: (0..<5).map { _ in .init(deviceID: "demo-floor", command: .power(false), delayMilliseconds: 60_000) })
        try store.runScene(slow)
        store.home.schedules = [SceneSchedule(sceneID: store.home.scenes[0].id, hour: 7, minute: 0)]
        store.tickSchedules(now: Self.local(1, 6, 59, 50)); store.tickSchedules(now: Self.local(1, 7, 0, 10))
        store.tickSchedules(now: Self.local(1, 7, 1, 30))
        #expect(store.runs.count == 1 && !store.activity.contains { $0.message.contains("Missed") }, "still waiting inside the grace")
        store.tickSchedules(now: Self.local(1, 7, 2, 10))
        #expect(store.activity.first?.message.contains("another scene was still running") == true)
        store.stopScene()
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        store.tickSchedules(now: Self.local(1, 7, 2, 30))
        #expect(store.runs.map(\.sceneID) == [slow.id])
    }

    @Test func onlyScenesRunByHandReplaceTheRestorePoint() async throws {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let scene = store.home.scenes[0]
        try store.runScene(scene)
        let point = try #require(store.restorePoint)
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        let webhook = await store.handle(.init(method: "POST", path: "/v1/actions", body: Data(#"{"target":"all","power":false}"#.utf8)))
        #expect(webhook.status == 202)
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        _ = await store.handle(.init(method: "POST", path: "/v1/devices/demo-desk/commands", body: try JSONEncoder().encode(CapabilityCommand.power(true))))
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        _ = await store.handle(.init(method: "POST", path: "/v1/scenes/\(scene.id)/run", body: Data("{}".utf8)))
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        store.home.schedules = [SceneSchedule(sceneID: scene.id, hour: 7, minute: 0)]
        store.tickSchedules(now: Self.local(1, 6, 59, 50)); store.tickSchedules(now: Self.local(1, 7, 0, 10))
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        _ = try store.scheduleSync.run(scene.id) // the shared-schedule runner's hook
        for _ in 0..<1000 where store.runningSceneID != nil { await Task.yield() }
        #expect(store.runs.count == 6)
        #expect(store.restorePoint?.id == point.id)
    }

    @Test func backgroundCloudRetryBacksOffAndStopsForARejectedKey() {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(store.retryCloudInBackground(key: "k", now: t))
        #expect(!store.retryCloudInBackground(key: "k", now: t + 29))
        #expect(store.retryCloudInBackground(key: "k", now: t + 30))
        #expect(!store.retryCloudInBackground(key: "k", now: t + 89))
        #expect(store.retryCloudInBackground(key: "k", now: t + 90))
        var now = t + 90
        for _ in 0..<12 { now = store.cloudRetry.at; #expect(store.retryCloudInBackground(key: "k", now: now)) }
        #expect(store.cloudRetry.at.timeIntervalSince(now) == 1800, "capped at 30 minutes")
        store.cloudRetry.rejectedKey = "k"
        #expect(!store.retryCloudInBackground(key: "k", now: now + 86_400))
        #expect(store.retryCloudInBackground(key: "new key", now: now + 86_400))
    }

    @Test func iCloudUpsertReplacesInPlaceAndAppendsNewScenesInAStableOrder() {
        let a = LightScene(name: "A", steps: []), b = LightScene(name: "B", steps: []), c = LightScene(name: "C", steps: [])
        let new = (0..<5).map { LightScene(name: "New \($0)", steps: []) }
        var edited = b; edited.name = "B2"
        var first = [a, b, c], second = [a, b, c]
        HomeStore.upsert(&first, [(b.id, edited), (a.id, nil)] + new.map { ($0.id, $0) })
        HomeStore.upsert(&second, new.reversed().map { ($0.id, $0) } + [(a.id, nil), (b.id, edited)])
        #expect(first.map(\.id) == [b.id, c.id] + new.map(\.id).sorted { $0.uuidString < $1.uuidString })
        #expect(first == second, "record order doesn't change the result")
        #expect(first[0].name == "B2")
    }

    @Test func reusedLANAddressMovesToTheAnnouncingLight() throws {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let stale = try #require(store.home.devices.firstIndex { $0.id == "demo-floor" })
        store.home.devices[stale].ip = "192.0.2.10"
        store.merge(LightDevice(id: "demo-strip", sku: "Demo strip", name: "Behind the sofa", ip: "192.0.2.10", online: true))
        let floor = try #require(store.home.devices.first { $0.id == "demo-floor" })
        let strip = try #require(store.home.devices.first { $0.id == "demo-strip" })
        #expect(floor.ip == nil && floor.sku == "Demo lamp")
        #expect(strip.ip == "192.0.2.10")
        #expect(store.home.devices.filter { $0.ip == "192.0.2.10" }.count == 1)
    }

    @Test func importedSceneWithAnExistingIDGetsAFreshOne() throws {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let existing = try #require(store.home.scenes.first)
        var file = existing; file.name = "Imported copy"
        try store.importScene(file)
        #expect(store.home.scenes.first { $0.id == existing.id } == existing)
        #expect(store.home.scenes.last?.name == "Imported copy" && store.home.scenes.last?.id != existing.id)
        let fresh = LightScene(name: "Fresh", steps: [.init(deviceID: "demo-desk", command: .power(true))])
        try store.importScene(fresh)
        #expect(store.home.scenes.last?.id == fresh.id)
    }
}
