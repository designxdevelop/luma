import Foundation
import Testing
import LumaCore
import LumaIntents
@testable import LumaUI

private func sceneCapability(_ instance: String, _ options: [(String, JSONValue)]) -> Capability {
    Capability(type: "devices.capabilities.dynamic_scene", instance: instance, parameters: .object([
        "dataType": .string("ENUM"), "options": .array(options.map { .object(["name": .string($0.0), "value": $0.1]) })
    ]))
}

/// Runs the real App Intents against a demo store. Serialized: they share `IntentHost.testStore`.
@MainActor @Suite(.serialized) struct SiriIntentTests {
    private func withStore(_ body: (HomeStore) async throws -> Void) async rethrows {
        let store = HomeStore(demo: true, folder: testFolder())
        IntentHost.testStore = store
        defer { IntentHost.testStore = nil; store.shutdown() }
        try await body(store)
    }

    @Test func roomShortcutPicksUpLightsAddedAndMovedAfterItWasMade() async throws {
        try await withStore { store in
            // The shortcut is made while Bedroom holds one light.
            let bedroom = try #require(try await RoomQuery().entities(for: ["Bedroom"]).first)
            #expect(bedroom.lightCount == 1)
            var on = TurnOnRoomIntent(); on.room = bedroom
            var off = TurnOffRoomIntent(); off.room = bedroom
            // Later the desk lights join Bedroom; the same shortcut now controls both.
            store.assignRoom("Bedroom", id: "demo-desk")
            _ = try await off.perform()
            #expect(store.devices.first { $0.id == "demo-desk" }?.power == false)
            #expect(store.devices.first { $0.id == "demo-bed" }?.power == false)
            // Moved back out: the shortcut no longer touches it.
            store.assignRoom("Office", id: "demo-desk")
            _ = try await on.perform()
            #expect(store.devices.first { $0.id == "demo-bed" }?.power == true)
            #expect(store.devices.first { $0.id == "demo-desk" }?.power == false)
        }
    }

    @Test func roomQueryOffersAllLightsAndKeepsRenamedRoomsResolvable() async throws {
        try await withStore { store in
            let suggested = try await RoomQuery().suggestedEntities()
            #expect(suggested.first?.title == "All lights" && suggested.first?.lightCount == store.devices.count)
            #expect(Set(suggested.dropFirst().map(\.title)) == Set(store.rooms))
            #expect(try await RoomQuery().entities(matching: "liv").map(\.title) == ["Living room"])
            // A room that was renamed away still resolves, so the action can explain.
            let stale = try #require(try await RoomQuery().entities(for: ["Garage"]).first)
            #expect(stale.lightCount == 0)
            var intent = TurnOnRoomIntent(); intent.room = stale
            await #expect(throws: LumaError.self) { _ = try await intent.perform() }
            #expect(store.activity.isEmpty || store.activity.first?.message.contains("Garage") == false)
        }
    }

    @Test func colorIntentSetsWhitesWithinEachRangeAndSkipsUnsupportedOrOfflineLights() async throws {
        try await withStore { store in
            store.home.devices[store.home.devices.firstIndex { $0.id == "demo-strip" }!].capabilities.removeAll { $0.instance == "colorRgb" }
            store.home.devices[store.home.devices.firstIndex { $0.id == "demo-tv" }!].online = false
            let living = try #require(try await RoomQuery().entities(for: ["Living room"]).first)
            var blue = SetRoomColorIntent(); blue.room = living; blue.color = .blue
            _ = try await blue.perform()
            #expect(store.devices.first { $0.id == "demo-floor" }?.rgb == LightColor.blue.rgb)
            #expect(store.devices.first { $0.id == "demo-strip" }?.rgb == 0xCA8BFF)
            #expect(store.devices.first { $0.id == "demo-tv" }?.rgb == 0x7FA8FF)
            let summary = try #require(store.activity.first?.message)
            #expect(summary.contains("Behind the sofa (no color control)") && summary.contains("TV backlight (offline)"))
            var warm = SetRoomColorIntent(); warm.room = living; warm.color = .warmWhite
            _ = try await warm.perform()
            #expect(store.devices.first { $0.id == "demo-strip" }?.colorTemperature == 2700)
        }
    }

    @Test func brightnessAndLumaSceneIntentsAndDeletedScene() async throws {
        try await withStore { store in
            let all = try #require(try await RoomQuery().entities(for: [LumaSiri.allLightsRoom]).first)
            var dim = SetRoomBrightnessIntent(); dim.room = all; dim.percent = 30
            _ = try await dim.perform()
            #expect(store.devices.allSatisfy { $0.brightness == 30 })
            let scene = try #require(try await LumaSceneQuery().entities(matching: "focus").first)
            var run = RunLumaSceneIntent(); run.scene = scene
            _ = try await run.perform()
            #expect(store.runs.first?.status == "completed")
            #expect(store.devices.first { $0.id == "demo-desk" }?.colorTemperature == 4500)
            store.home.scenes.removeAll()
            await #expect(throws: LumaError.self) { _ = try await run.perform() }
        }
    }

    @Test func goveeSceneIntentAppliesByNameAndSkipsLightsWithoutIt() async throws {
        try await withStore { store in
            let aurora = try #require(try await GoveeSceneQuery().entities(matching: "aurora").first)
            #expect(aurora.id == "lightScene|Aurora" && aurora.lightCount == 3)
            let living = try #require(try await RoomQuery().entities(for: ["Living room"]).first)
            var apply = ApplyGoveeSceneIntent(); apply.room = living; apply.scene = aurora
            _ = try await apply.perform()
            let summary = try #require(store.activity.first?.message)
            #expect(summary.contains("applied Aurora to 2 lights") && summary.contains("TV backlight (scenes not loaded)"))
            // Bedroom's model lists fewer scenes: a name it lacks is a clear failure.
            let bedroom = try #require(try await RoomQuery().entities(for: ["Bedroom"]).first)
            apply.room = bedroom
            apply.scene = try #require(try await GoveeSceneQuery().entities(for: ["lightScene|Starry Sky"]).first)
            await #expect(throws: LumaError.self) { _ = try await apply.perform() }
            #expect(store.activity.first?.message.contains("doesn't list Starry Sky") == true)
        }
    }
}

@MainActor struct GoveeSceneTransportTests {
    @Test(.timeLimit(.minutes(1))) func oneClickSceneSendsTheExactOptionWithoutSavingAScene() async throws {
        let fixture = InteractionFixture([.init()])
        defer { fixture.finish() }
        let value = JSONValue.object(["paramId": .number(4280), "id": .number(3853)])
        fixture.store.home.devices[0].capabilities.append(sceneCapability("lightScene", [("Sunrise", value), ("Aurora", .object(["paramId": .number(1), "id": .number(2)]))]))
        let scenesBefore = fixture.store.home.scenes
        let report = try await fixture.store.applyGoveeScene(kind: .builtIn, name: "sunrise", to: fixture.store.devices, target: "Test")
        #expect(report.sent == ["Test light"])
        #expect(fixture.script.commands == [.object(["type": .string("devices.capabilities.dynamic_scene"), "instance": .string("lightScene"), "value": value])])
        #expect(fixture.store.home.scenes == scenesBefore)
        // Scenes have no readable state, so nothing waits on a confirmation read.
        #expect(fixture.script.paths.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func roomActionReturnsOnceTheCloudAcceptsWithoutWaitingForReadback() async throws {
        let fixture = InteractionFixture([.init(), .state(power: true, held: true)])
        defer { fixture.finish() }
        let report = try await fixture.store.setPower(true, room: "Unassigned")
        #expect(report.sent == ["Test light"])
        // Returned while the confirmation read is still held open.
        await fixture.script.waitForRequestCount(2)
        #expect(fixture.script.paths.last?.hasSuffix("/device/state") == true)
        fixture.script.release(1)
        await fixture.waitUntilSettled()
        #expect(fixture.store.devices[0].power == true)
    }

    @Test(.timeLimit(.minutes(1))) func failedCloudWriteIsReportedAndThrown() async {
        let fixture = InteractionFixture([.init(status: 500)])
        defer { fixture.finish() }
        await #expect(throws: LumaError.self) { _ = try await fixture.store.setPower(true, room: "Unassigned") }
        #expect(fixture.store.activity.contains { $0.message.contains("Failed: Test light") })
    }

    @Test(.timeLimit(.minutes(1))) func deletedDIYSceneDisappearsAndSavedScenesUsingItFailClearly() async throws {
        let reply = InteractionReply(body: #"{"code":200,"payload":{"device":"interaction-lamp","sku":"H6008","capabilities":[{"type":"devices.capabilities.dynamic_scene","instance":"diyScene","parameters":{"dataType":"ENUM","options":[{"name":"Keep","value":1}]}}]}}"#)
        let fixture = InteractionFixture([reply])
        defer { fixture.finish() }
        fixture.store.home.devices[0].capabilities.append(sceneCapability("diyScene", [("Keep", .number(1)), ("Deleted", .number(2))]))
        let saved = LightScene(name: "Old DIY", steps: [.init(deviceID: "interaction-lamp", command: .init(type: "devices.capabilities.dynamic_scene", instance: "diyScene", value: .number(2)))])
        try fixture.store.saveScene(saved)
        await fixture.store.loadDeviceScenes(fixture.store.home.devices[0], diy: true)
        #expect(GoveeSceneLibrary.options(for: fixture.store.home.devices[0]).map(\.name) == ["Keep"])
        let error = #expect(throws: LumaError.self) { try fixture.store.runScene(saved) }
        #expect(error?.errorDescription == "Test light no longer lists this Govee scene. Reload its scenes, then choose it again.")
        // What the Siri scene picker sees (LumaSiri.goveeScene reads this list).
        #expect(!fixture.store.goveeSceneChoices().contains { $0.name == "Deleted" })
    }
}

@MainActor struct GoveeSceneLibraryTests {
    @Test func summaryListsLightsSharingAReasonOnce() {
        let report = LightActionReport(target: "Guest room", verb: "turned on", sent: ["Lamp"], skipped: [.init(light: "Fan", reason: "no power control")],
                                       failed: [.init(light: "Nightstand", reason: "no cloud"), .init(light: "Closet", reason: "no cloud")])
        #expect(report.summary == "Guest room: turned on 1 light. Skipped Fan (no power control). Failed: Nightstand, Closet (no cloud).")
    }

    @Test func optionsKeepGoveeOrderNamesAndSearchIgnoresCaseAndAccents() {
        let light = LightDevice(id: "a", sku: "H6008", name: "Lamp", capabilities: [
            sceneCapability("diyScene", [("Café Glow", .number(9))]),
            sceneCapability("lightScene", [("Sunrise", .number(1)), ("", .number(2)), ("Sunrise", .number(1))]),
            sceneCapability("snapshot", [("Evening", .number(3))])
        ])
        let options = GoveeSceneLibrary.options(for: light)
        #expect(options.map(\.name) == ["Sunrise", "Built-in 2", "Café Glow", "Evening"])
        #expect(GoveeSceneLibrary.filter(options, query: "cafe").map(\.name) == ["Café Glow"])
        #expect(GoveeSceneLibrary.filter(options, query: "", kind: .snapshot).map(\.name) == ["Evening"])
        #expect(GoveeSceneLibrary.match(kind: .builtIn, name: "SUNRISE", on: light)?.command.instance == "lightScene")
        #expect(GoveeSceneLibrary.advertisesScenes(light) && !GoveeSceneLibrary.advertisesScenes(.init(id: "b", sku: "H1", name: "B")))
    }

    @Test func browserGroupsSharedNamesAcrossLightsAndKeepsOneLightsExactList() {
        let store = HomeStore(demo: true, folder: testFolder()); defer { store.shutdown() }
        let living = store.lights(inRoom: "Living room")
        let rows = GoveeSceneList.rows(for: living)
        #expect(rows.first { $0.name == "Aurora" }?.count == 2)
        #expect(rows.first { $0.name == "Party Pulse" }?.kind == .diy)
        let single = GoveeSceneList.rows(for: [store.devices.first { $0.id == "demo-bed" }!])
        #expect(single.count == 6 && single.allSatisfy { $0.option != nil })
    }
}
