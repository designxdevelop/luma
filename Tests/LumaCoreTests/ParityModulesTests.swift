import Foundation
import Testing
@testable import LumaCore

struct ParityModulesTests {
    static let color = Capability(type: "devices.capabilities.segment_color_setting", instance: "segmentedColorRgb", parameters: .object([
        "dataType": .string("STRUCT"), "fields": .array([
            .object(["fieldName": .string("segment"), "dataType": .string("Array"), "elementType": .string("INTEGER"),
                     "elementRange": .object(["min": .number(0), "max": .number(14)]), "size": .object(["min": .number(1), "max": .number(4)]), "required": .bool(true)]),
            .object(["fieldName": .string("rgb"), "dataType": .string("INTEGER"), "range": .object(["min": .number(0), "max": .number(16777215)]), "required": .bool(true)]),
        ]),
    ]))
    static let level = Capability(type: "devices.capabilities.segment_color_setting", instance: "segmentedBrightness", parameters: .object([
        "dataType": .string("STRUCT"), "fields": .array([
            .object(["fieldName": .string("segment"), "dataType": .string("Array"), "options": .array([.object(["value": .number(3)]), .object(["value": .number(1)])])]),
            .object(["fieldName": .string("brightness"), "dataType": .string("INTEGER"), "range": .object(["min": .number(0), "max": .number(100)]), "required": .bool(true)]),
        ]),
    ]))
    let strip = LightDevice(id: "strip", sku: "H619A", name: "Strip", capabilities: [color, level])

    @Test func segmentSchemaReadsRangeOptionsAndLimit() throws {
        let paint = try #require(SegmentPaint(Self.color))
        #expect(paint.indexes == Array(0...14) && paint.isColor && paint.perCommand == 4)
        let brightness = try #require(SegmentPaint(Self.level))
        #expect(brightness.indexes == [1, 3] && brightness.valueRange == 0...100 && !brightness.isColor)
        #expect(SegmentPaint(Capability(type: "x", instance: "segmentedColorRgb", parameters: .object(["dataType": .string("STRUCT")]))) == nil)
        #expect(SegmentPaint.all(for: strip).map(\.instance) == ["segmentedColorRgb", "segmentedBrightness"])
    }

    @Test func paintingBecomesFewestOrderedValidatedCommands() throws {
        let paint = try #require(SegmentPaint(Self.color))
        let commands = try paint.commands(for: [5: 0xFF0000, 0: 0xFF0000, 1: 0x00FF00, 2: 0xFF0000, 3: 0xFF0000, 4: 0xFF0000, 9: 0x0000FF])
        #expect(commands.map { $0.value["segment"]?.array?.compactMap(\.number).map(Int.init) ?? [] } == [[0, 2, 3, 4], [1], [5], [9]])
        #expect(commands.map { Int($0.value["rgb"]?.number ?? -1) } == [0xFF0000, 0x00FF00, 0xFF0000, 0x0000FF])
        for command in commands { try CommandValidation.validate(command, for: strip) }
        #expect(throws: LumaError.self) { try paint.commands(for: [15: 1]) }
        #expect(throws: LumaError.self) { try paint.commands(for: [0: 0x1000000]) }
        #expect(try paint.commands(for: [:]).isEmpty)
    }

    @Test func readingsUseAdvertisedUnitsAndSkipControls() throws {
        let caps = [Capability(type: "devices.capabilities.property", instance: "sensorTemperature", parameters: .object(["unit": .string("unit.temperature.celsius")])),
                    Capability(type: "devices.capabilities.property", instance: "sensorHumidity", parameters: .object(["unit": .string("unit.percent")])),
                    Capability(type: "devices.capabilities.work_mode", instance: "workMode", parameters: .object(["options": .array([.object(["name": .string("Sleep"), "value": .number(2)])])]))]
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"sku":"H5179","device":"X","capabilities":[
          {"instance":"online","state":{"value":true}},{"instance":"powerSwitch","state":{"value":1}},
          {"instance":"sensorTemperature","state":{"value":21.456}},{"instance":"sensorHumidity","state":{"value":48}},
          {"instance":"workMode","state":{"value":2}},{"instance":"filterLifeTime","state":{"value":{"remaining":80}}},
          {"instance":"lightScene","state":{"value":""}},{"instance":"empty","state":{"value":""}}]}
        """#.utf8))
        #expect(DeviceReadings.parse(payload, capabilities: caps).map { "\($0.label): \($0.text)" } ==
                ["Temperature: 21.46 °C", "Humidity: 48%", "Mode: Sleep", #"Filter life: {"remaining":80}"#])
        #expect(DeviceReadings.label("airPurifierSpeed") == "Air purifier speed")
        #expect(DeviceReadings.isLight(type: nil) && DeviceReadings.isLight(type: "devices.types.light") && !DeviceReadings.isLight(type: "devices.types.heater"))
    }
}

struct LightLookTests {
    @Test func paletteFollowsWhatLumaSends() throws {
        let segments = Capability(type: "devices.capabilities.segment_color_setting", instance: "segmentedColorRgb", parameters: .object([
            "dataType": .string("STRUCT"), "fields": .array([
                .object(["fieldName": .string("segment"), "dataType": .string("Array"), "elementRange": .object(["min": .number(0), "max": .number(3)])]),
                .object(["fieldName": .string("rgb"), "dataType": .string("INTEGER")])])]))
        let scenes = Capability(type: "devices.capabilities.dynamic_scene", instance: "lightScene", parameters: .object(["options": .array([
            .object(["name": .string("Sunset Glow"), "value": .number(1)]), .object(["name": .string("Mode 7"), "value": .number(2)])])]))
        var light = LightDevice(id: "a", sku: "H", name: "Strip", capabilities: [segments, scenes], rgb: 0x111111)
        light.noteLook(.init(type: segments.type, instance: "segmentedColorRgb", value: .object(["segment": .array([.number(1), .number(3)]), "rgb": .number(0xFF0000)])))
        #expect(light.palette == [0x111111, 0xFF0000, 0x111111, 0xFF0000])
        light.noteLook(.init(type: segments.type, instance: "segmentedColorRgb", value: .object(["segment": .array([.number(0)]), "rgb": .number(0x00FF00)])))
        #expect(light.palette == [0x00FF00, 0xFF0000, 0x111111, 0xFF0000])
        light.noteLook(.brightness(40))
        #expect(light.palette != nil)
        light.noteLook(.init(type: scenes.type, instance: "lightScene", value: .number(1)))
        #expect(light.palette == ScenePalette.colors(named: "sunset"))
        light.noteLook(.init(type: scenes.type, instance: "lightScene", value: .number(2)))
        #expect(light.palette == nil)
        light.palette = [1, 2]
        light.noteLook(.rgb(0x0000FF))
        #expect(light.palette == nil)
        #expect(try JSONDecoder().decode(LightDevice.self, from: Data(#"{"id":"a","sku":"H","name":"n","room":"r","capabilities":[],"isDemo":false}"#.utf8)).palette == nil)
    }
}
