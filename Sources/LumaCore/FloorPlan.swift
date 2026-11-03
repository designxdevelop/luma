import Foundation

/// Coordinates refer to the image itself, independent of zoom or screen size.
public struct FloorPlanPin: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceID }
    public let deviceID: String
    public let x: Double
    public let y: Double

    public init(deviceID: String, x: Double, y: Double) throws {
        guard !deviceID.isEmpty, x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y) else {
            throw LumaError.message("Choose a light and a position inside the floor plan.")
        }
        self.deviceID = deviceID; self.x = x; self.y = y
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(deviceID: c.decode(String.self, forKey: .deviceID),
                      x: c.decode(Double.self, forKey: .x), y: c.decode(Double.self, forKey: .y))
    }
}

public struct FloorPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var pins: [FloorPlanPin]
    public init(id: UUID = UUID(), name: String, pins: [FloorPlanPin] = []) {
        self.id = id; self.name = name; self.pins = pins
    }
}
