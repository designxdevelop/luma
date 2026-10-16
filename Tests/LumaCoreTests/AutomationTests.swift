import Foundation
import Testing
@testable import LumaCore

struct AutomationTests {
    let device = LightDevice(id: "lamp", sku: "H-test", name: "Lamp", room: "Office", capabilities: [
        Capability(type: "devices.capabilities.on_off", instance: "powerSwitch"),
        Capability(type: "devices.capabilities.range", instance: "brightness", parameters: .object(["dataType": .string("INTEGER"), "range": .object(["min": .number(1), "max": .number(80)])]))
    ])
    @Test func actionTargetsAndCommands() throws {
        let action = try JSONDecoder().decode(AutomationAction.self, from: Data(##"{"target":"room:Office","power":true,"brightness":40,"color":"#FF8800"}"##.utf8))
        #expect(try action.deviceIDs(in: [device]) == ["lamp"])
        #expect(try action.commands() == [.power(true), .brightness(40), .rgb(0xFF8800)])
    }
    @Test(arguments: [##"{"target":"all","brightness":0}"##, ##"{"target":"all","color":"#xxyyzz"}"##, ##"{"target":"all","color":"#FF0000","kelvin":3000}"##, ##"{"target":"all"}"##])
    func invalidActions(_ json: String) throws {
        let action = try JSONDecoder().decode(AutomationAction.self, from: Data(json.utf8))
        #expect(throws: (any Error).self) { try action.commands() }
    }
    @Test func emptyTargetRejected() throws {
        let action = try JSONDecoder().decode(AutomationAction.self, from: Data(##"{"target":"missing","power":true}"##.utf8))
        #expect(throws: (any Error).self) { try action.deviceIDs(in: [device]) }
    }
    @Test func validatesAdvertisedCapabilitiesAndBounds() throws {
        try CommandValidation.validate(.brightness(80), for: device)
        #expect(throws: (any Error).self) { try CommandValidation.validate(.brightness(81), for: device) }
        #expect(throws: (any Error).self) { try CommandValidation.validate(.rgb(0), for: device) }
        #expect(throws: (any Error).self) { try CommandValidation.validate(.init(type: "wrong", instance: "powerSwitch", value: .number(1)), for: device) }
    }
    @Test func validatesGoveeSegmentArraySchema() throws {
        let parameters = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"dataType":"STRUCT","fields":[{"dataType":"Array","elementType":"INTEGER","elementRange":{"min":0,"max":14},"fieldName":"segment","required":true,"size":{"min":1,"max":15}}]}"#.utf8))
        let capability = Capability(type: "devices.capabilities.segment_color_setting", instance: "segmentedColorRgb", parameters: parameters)
        let strip = LightDevice(id: "strip", sku: "H-test", name: "Strip", capabilities: [capability])
        func command(_ segments: [JSONValue]) -> CapabilityCommand {
            .init(type: capability.type, instance: capability.instance, value: .object(["segment": .array(segments)]))
        }
        try CommandValidation.validate(command([.number(0), .number(14)]), for: strip)
        let invalid: [[JSONValue]] = [[], [.number(15)], [.number(-1)], [.number(0.5)], [.string("0")], [.number(.infinity)], [.number(.nan)], [.number(0), .number(0)]]
        for segments in invalid {
            #expect(throws: (any Error).self) { try CommandValidation.validate(command(segments), for: strip) }
        }
        #expect(throws: (any Error).self) {
            try CommandValidation.validate(.init(type: capability.type, instance: capability.instance, value: .object([:])), for: strip)
        }
    }
    @Test func validatesGeneralIntegerArraySizeWithoutRequiringUniqueness() throws {
        let schema: JSONValue = .object([
            "dataType": .string("ARRAY"), "elementType": .string("INTEGER"),
            "elementRange": .object(["min": .number(0), "max": .number(14)]),
            "size": .object(["min": .number(1), "max": .number(2)])
        ])
        try CommandValidation.validateValue(.array([.number(1), .number(1)]), parameters: schema)
        #expect(throws: (any Error).self) {
            try CommandValidation.validateValue(.array([.number(0), .number(1), .number(2)]), parameters: schema)
        }
    }
    @Test func boundedSceneValidation() throws {
        let valid = LightScene(name: "Evening", steps: [.init(deviceID: "lamp", command: .power(true))])
        try CommandValidation.validateScene(valid, devices: [device])
        for scene in [LightScene(name: "", steps: valid.steps), LightScene(name: "Empty", steps: []), LightScene(name: "Wrong light", steps: [.init(deviceID: "missing", command: .power(true))]), LightScene(name: "Too long", steps: [.init(deviceID: "lamp", command: .power(true), delayMilliseconds: 60001)])] {
            #expect(throws: (any Error).self) { try CommandValidation.validateScene(scene, devices: [device]) }
        }
        let duplicate = LightScene(name: "Duplicate IDs", steps: [valid.steps[0], valid.steps[0]])
        #expect(throws: (any Error).self) { try CommandValidation.validateScene(duplicate, devices: [device]) }
    }
    @Test func schedulesRunOncePerMatchingLocalMinute() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-15T18:30:00Z"))
        var schedule = SceneSchedule(sceneID: UUID(), hour: 18, minute: 30, weekdays: [5])
        #expect(schedule.shouldRun(at: date, calendar: calendar))
        schedule.lastRunMinute = schedule.minuteKey(date, calendar: calendar)
        #expect(!schedule.shouldRun(at: date.addingTimeInterval(25), calendar: calendar))
        #expect(!schedule.shouldRun(at: date.addingTimeInterval(60), calendar: calendar))
        schedule.lastRunMinute = nil; schedule.enabled = false
        #expect(!schedule.shouldRun(at: date, calendar: calendar))
    }
    @Test func sceneJSONRoundTrip() throws {
        let scene = LightScene(name: "Color scene", steps: [.init(deviceID: "lamp", command: .rgb(0xFFFFFF), delayMilliseconds: 1500)])
        #expect(try JSONDecoder().decode(LightScene.self, from: JSONEncoder.pretty.encode(scene)) == scene)
    }
}
