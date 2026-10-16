import Foundation

public struct AutomationAction: Decodable, Sendable {
    public var target: String
    public var power: Bool?
    public var brightness: Int?
    public var color: String?
    public var kelvin: Int?
    public func deviceIDs(in devices: [LightDevice]) throws -> [String] {
        let selected: [LightDevice]
        if target == "all" { selected = devices }
        else if target.hasPrefix("room:") { selected = devices.filter { $0.room == String(target.dropFirst(5)) } }
        else { selected = devices.filter { $0.id == target } }
        guard !selected.isEmpty, selected.count <= 100 else { throw LumaError.message("Target must match 1–100 lights.") }
        return selected.map(\.id)
    }
    public func commands() throws -> [CapabilityCommand] {
        var commands: [CapabilityCommand] = []
        if let power { commands.append(.power(power)) }
        if let brightness { guard (1...100).contains(brightness) else { throw LumaError.message("Brightness must be 1–100.") }; commands.append(.brightness(brightness)) }
        if let color {
            let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = Int(hex, radix: 16) else { throw LumaError.message("Color must be a six-digit RGB hex color.") }
            commands.append(.rgb(value))
        }
        if let kelvin { guard (1000...10000).contains(kelvin) else { throw LumaError.message("Kelvin must be 1000–10000.") }; commands.append(.kelvin(kelvin)) }
        guard !(color != nil && kelvin != nil) else { throw LumaError.message("Choose color or kelvin in one action.") }
        guard !commands.isEmpty else { throw LumaError.message("Supply power, brightness, color, or kelvin.") }
        return commands
    }
}
