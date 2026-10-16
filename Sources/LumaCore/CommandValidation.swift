import Foundation

public enum CommandValidation {
    public static func validate(_ command: CapabilityCommand, for device: LightDevice) throws {
        guard device.supports(command.instance) else { throw LumaError.message("\(device.name) does not advertise \(command.instance). Connect cloud to load all capabilities.") }
        if let cap = device.capabilities.first(where: { $0.instance == command.instance }) {
            guard cap.type == command.type else { throw LumaError.message("Capability type does not match this device.") }
            try validateValue(command.value, parameters: cap.parameters)
        } else {
            let expected: String
            switch command.instance {
            case "powerSwitch": expected = "devices.capabilities.on_off"
            case "brightness": expected = "devices.capabilities.range"
            default: expected = "devices.capabilities.color_setting"
            }
            guard command.type == expected else { throw LumaError.message("Invalid LAN capability type.") }
        }
        let ranges: [String: ClosedRange<Double>] = ["powerSwitch": 0...1, "brightness": 1...100, "colorRgb": 0...16777215, "colorTemperatureK": 1000...10000]
        if let range = ranges[command.instance] {
            guard let n = command.value.number, n.isFinite, n.rounded() == n, range.contains(n) else { throw LumaError.message("\(command.instance) must be an integer in \(Int(range.lowerBound))…\(Int(range.upperBound)).") }
        }
    }
    static func validateValue(_ value: JSONValue, parameters: JSONValue?) throws {
        guard let parameters else { return }
        switch parameters["dataType"]?.string {
        case "INTEGER":
            guard let n = value.number, n.isFinite, n.rounded() == n else { throw LumaError.message("Expected an integer value.") }
            if let min = parameters["range"]?["min"]?.number, n < min { throw LumaError.message("Value is below the device minimum (\(Int(min))).") }
            if let max = parameters["range"]?["max"]?.number, n > max { throw LumaError.message("Value exceeds the device maximum (\(Int(max))).") }
        case "ENUM":
            if let options = parameters["options"]?.array, !options.isEmpty, !options.contains(where: { $0["value"] == value }) { throw LumaError.message("Choose one of the device's advertised values.") }
        case "STRUCT":
            guard case .object(let object) = value else { throw LumaError.message("Expected a JSON object for this capability.") }
            for field in parameters["fields"]?.array ?? [] {
                guard let name = field["fieldName"]?.string else { continue }
                if let supplied = object[name] { try validateValue(supplied, parameters: field) }
                else if field["required"] == .bool(true) { throw LumaError.message("Missing required field: \(name).") }
            }
        case "Array", "ARRAY":
            guard case .array(let elements) = value else { throw LumaError.message("Expected an array.") }
            if let minimum = parameters["size"]?["min"]?.number, Double(elements.count) < minimum {
                throw LumaError.message("Array has fewer items than the device minimum.")
            }
            if let maximum = parameters["size"]?["max"]?.number, Double(elements.count) > maximum {
                throw LumaError.message("Array has more items than the device maximum.")
            }
            if let elementType = parameters["elementType"]?.string {
                var elementParameters: [String: JSONValue] = ["dataType": .string(elementType)]
                if let range = parameters["elementRange"] { elementParameters["range"] = range }
                for element in elements { try validateValue(element, parameters: .object(elementParameters)) }
            }
            if parameters["fieldName"]?.string == "segment" {
                var indexes = Set<Double>()
                for element in elements {
                    guard let index = element.number, index.isFinite, index.rounded() == index else {
                        throw LumaError.message("Segment indexes must be integers.")
                    }
                    guard indexes.insert(index).inserted else { throw LumaError.message("Segment indexes must be unique.") }
                }
            }
        default: break
        }
    }
    public static func validateScene(_ scene: LightScene, devices: [LightDevice]) throws {
        guard !scene.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LumaError.message("Give the scene a name.") }
        guard !scene.steps.isEmpty, scene.steps.count <= 200 else { throw LumaError.message("Scenes need 1–200 steps.") }
        guard Set(scene.steps.map(\.id)).count == scene.steps.count else { throw LumaError.message("Each scene step needs a unique ID.") }
        var delay = 0
        for step in scene.steps {
            guard (0...60000).contains(step.delayMilliseconds) else { throw LumaError.message("Step delays must be 0–60000 milliseconds.") }
            delay += step.delayMilliseconds
            guard delay <= 300000 else { throw LumaError.message("Total scene delay must be 5 minutes or less.") }
            guard let device = devices.first(where: { $0.id == step.deviceID }) else { throw LumaError.message("Scene references a light that is no longer connected.") }
            try validate(step.command, for: device)
        }
    }
}
