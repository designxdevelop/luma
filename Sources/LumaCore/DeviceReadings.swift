import Foundation

/// Readable values from Govee's official `device/state` reply for capabilities with no
/// dedicated control: thermometer/hygrometer readings, appliance modes, filter life.
/// Units come only from the advertised capability; nothing is converted or guessed.
/// Event capabilities (lack of water, etc.) are MQTT pushes and never appear in state.
/// Same rules as Luma for Windows/Linux (`desktop/src/core/readings.ts`).
public enum DeviceReadings {
    public struct Reading: Sendable, Equatable, Identifiable {
        public var instance: String
        public var label: String
        public var text: String
        public var id: String { instance }
    }

    /// Govee device types other than lights. Bulk light actions must skip these.
    public static func isLight(type: String?) -> Bool { type == nil || type == "devices.types.light" }

    static let skipped: Set<String> = ["online", "powerSwitch", "brightness", "colorRgb", "colorTemperatureK", DreamView.instance, "lightScene", "diyScene", "snapshot"]
    static let labels = ["sensorTemperature": "Temperature", "sensorHumidity": "Humidity", "airQuality": "Air quality", "filterLifeTime": "Filter life",
                         "workMode": "Mode", "gearMode": "Gear", "fanSpeed": "Fan speed", "targetTemperature": "Target temperature"]
    static let units = ["unit.percent": "%", "unit.temperature.celsius": " °C", "unit.temperature.fahrenheit": " °F", "unit.kelvin": " K"]

    /// `state` is the reply's `payload` (or its `capabilities` array). Unknown and empty values are left out; at most 32.
    public static func parse(_ state: JSONValue, capabilities: [Capability]) -> [Reading] {
        let rows = state["capabilities"]?.array ?? state.array ?? []
        var out: [Reading] = []
        for row in rows {
            guard let instance = row["instance"]?.string, instance.count <= 64, !skipped.contains(instance), let value = row["state"]?["value"],
                  let text = text(value, capability: capabilities.first { $0.instance == instance }) else { continue }
            out.append(.init(instance: instance, label: label(instance), text: text))
            if out.count == 32 { break }
        }
        return out
    }

    public static func label(_ instance: String) -> String {
        if let known = labels[instance] { return known }
        let words = instance.replacing(/([a-z0-9])([A-Z])/) { "\($0.1) \($0.2)" }.lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func text(_ value: JSONValue, capability: Capability?) -> String? {
        if let name = capability?.parameters?["options"]?.array?.first(where: { $0["value"] == value })?["name"]?.string { return String(name.prefix(80)) }
        switch value {
        case .number(let n) where n.isFinite:
            let unit = capability?.parameters?["unit"]?.string.map { units[$0] ?? ($0.hasPrefix("unit.") ? " " + $0.dropFirst(5).replacingOccurrences(of: ".", with: " ") : "") } ?? ""
            let rounded = abs(n) < 1e15 ? (n * 100).rounded() / 100 : n
            return (rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(rounded)) + unit
        case .bool(let on): return on ? "On" : "Off"
        case .string(let s): return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(s.prefix(80))
        case .object(let o) where o.isEmpty: return nil
        case .array(let a) where a.isEmpty: return nil
        case .object, .array:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else { return nil }
            return json.count > 120 ? String(json.prefix(119)) + "…" : json
        default: return nil
        }
    }
}
