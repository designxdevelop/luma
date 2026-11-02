import Foundation
import Testing
@testable import LumaCore

/// Integration patch: appliances and sensors are listed but never reached by bulk light actions.
struct NonLightIntegrationTests {
    let lamp = LightDevice(id: "lamp", sku: "H6008", name: "Lamp", room: "Den", ip: "10.0.0.2", power: true, online: true)
    let heater = LightDevice(id: "heat", sku: "H7130", name: "Heater", room: "Den", power: true, online: true, deviceType: "devices.types.heater")

    @Test func bulkTargetsMeanLights() throws {
        let all = try JSONDecoder().decode(AutomationAction.self, from: Data(#"{"target":"all","power":false}"#.utf8))
        #expect(try all.deviceIDs(in: [lamp, heater]) == ["lamp"])
        let room = try JSONDecoder().decode(AutomationAction.self, from: Data(#"{"target":"room:Den","power":false}"#.utf8))
        #expect(try room.deviceIDs(in: [lamp, heater]) == ["lamp"])
        let direct = try JSONDecoder().decode(AutomationAction.self, from: Data(#"{"target":"heat","power":false}"#.utf8))
        #expect(try direct.deviceIDs(in: [lamp, heater]) == ["heat"])
        #expect(heater.screenSyncIssue == "Not a light" && lamp.screenSyncIssue == nil)
    }

    @Test func savedHomesWithoutTheFieldStillDecode() throws {
        let old = try JSONDecoder().decode(LightDevice.self, from: Data(#"{"id":"a","sku":"H1","name":"A","room":"R","capabilities":[],"isDemo":false}"#.utf8))
        #expect(old.deviceType == nil)
        let round = try JSONDecoder().decode(LightDevice.self, from: JSONEncoder().encode(heater))
        #expect(round.deviceType == "devices.types.heater")
    }
}
