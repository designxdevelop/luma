import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? { if case .object(let v) = self { v[key] } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var pretty: String { (try? String(data: JSONEncoder.pretty.encode(self), encoding: .utf8)) ?? "null" }
}

extension JSONEncoder {
    public static var pretty: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return encoder
    }
}

public struct Capability: Codable, Sendable, Equatable, Identifiable {
    public var type: String
    public var instance: String
    public var parameters: JSONValue?
    public var id: String { type + ":" + instance }
    public init(type: String, instance: String, parameters: JSONValue? = nil) {
        self.type = type; self.instance = instance; self.parameters = parameters
    }
}

public struct LightDevice: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var sku: String
    public var name: String
    /// User-set label that survives cloud and LAN refreshes; `name` stays the device's own.
    public var customName: String?
    public var room: String
    public var ip: String?
    public var capabilities: [Capability]
    public var power: Bool?
    public var brightness: Int?
    public var rgb: Int?
    public var colorTemperature: Int?
    public var online: Bool?
    public var lastSeen: Date?
    public var isDemo: Bool
    public init(id: String, sku: String, name: String, room: String = "Unassigned", ip: String? = nil,
                capabilities: [Capability] = [], power: Bool? = nil, brightness: Int? = nil, rgb: Int? = nil,
                colorTemperature: Int? = nil, online: Bool? = nil, lastSeen: Date? = nil, isDemo: Bool = false, customName: String? = nil) {
        self.id = id; self.sku = sku; self.name = name; self.room = room; self.ip = ip
        self.capabilities = capabilities; self.power = power; self.brightness = brightness
        self.rgb = rgb; self.colorTemperature = colorTemperature; self.online = online
        self.lastSeen = lastSeen; self.isDemo = isDemo; self.customName = customName
    }
    public func supports(_ instance: String) -> Bool { ip != nil && ["powerSwitch", "brightness", "colorRgb", "colorTemperatureK"].contains(instance) || capabilities.contains { $0.instance == instance } }
}

public struct CapabilityCommand: Codable, Sendable, Equatable {
    public var type: String
    public var instance: String
    public var value: JSONValue
    public init(type: String, instance: String, value: JSONValue) { self.type = type; self.instance = instance; self.value = value }
    public static func power(_ on: Bool) -> Self { .init(type: "devices.capabilities.on_off", instance: "powerSwitch", value: .number(on ? 1 : 0)) }
    public static func brightness(_ value: Int) -> Self { .init(type: "devices.capabilities.range", instance: "brightness", value: .number(Double(value))) }
    public static func rgb(_ value: Int) -> Self { .init(type: "devices.capabilities.color_setting", instance: "colorRgb", value: .number(Double(value))) }
    public static func kelvin(_ value: Int) -> Self { .init(type: "devices.capabilities.color_setting", instance: "colorTemperatureK", value: .number(Double(value))) }
}

public enum LumaError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { "Unknown error" } }
}

public struct SceneStep: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var deviceID: String
    public var command: CapabilityCommand
    public var delayMilliseconds: Int
    public init(id: UUID = UUID(), deviceID: String, command: CapabilityCommand, delayMilliseconds: Int = 0) {
        self.id = id; self.deviceID = deviceID; self.command = command; self.delayMilliseconds = delayMilliseconds
    }
}

public struct LightScene: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var steps: [SceneStep]
    public init(id: UUID = UUID(), name: String, symbol: String = "sparkles", steps: [SceneStep]) {
        self.id = id; self.name = name; self.symbol = symbol; self.steps = steps
    }
}

public struct SceneSchedule: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var sceneID: UUID
    public var hour: Int
    public var minute: Int
    public var weekdays: [Int]
    public var enabled: Bool
    public var lastRunMinute: String?
    public init(id: UUID = UUID(), sceneID: UUID, hour: Int, minute: Int, weekdays: [Int] = Array(1...7), enabled: Bool = true, lastRunMinute: String? = nil) {
        self.id = id; self.sceneID = sceneID; self.hour = hour; self.minute = minute
        self.weekdays = weekdays; self.enabled = enabled; self.lastRunMinute = lastRunMinute
    }
    public func shouldRun(at date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        return enabled && c.hour == hour && c.minute == minute && weekdays.contains(c.weekday ?? 0) && lastRunMinute != minuteKey(date, calendar: calendar)
    }
    public func minuteKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)-\(c.hour ?? 0)-\(c.minute ?? 0)"
    }
}
