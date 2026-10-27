import Foundation

// Messages between the iPhone app and its Apple Watch companion. The watch
// never talks to lights or Govee directly: watchOS has no general UDP sockets
// for LAN control, and the API key stays on the phone.

/// What the watch shows. Sent as WatchConnectivity application context.
public struct WatchSnapshot: Codable, Sendable, Equatable {
    public struct Light: Codable, Sendable, Equatable, Identifiable {
        public var id: String, name: String, room: String
        public var power: Bool?, brightness: Int?, rgb: Int?, online: Bool?
        public var canDim: Bool
        public init(id: String, name: String, room: String, power: Bool?, brightness: Int?, rgb: Int?, online: Bool?, canDim: Bool) {
            self.id = id; self.name = name; self.room = room; self.power = power; self.brightness = brightness; self.rgb = rgb; self.online = online; self.canDim = canDim
        }
    }
    public struct Scene: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID, name: String, symbol: String
        public init(id: UUID, name: String, symbol: String) { self.id = id; self.name = name; self.symbol = symbol }
    }
    public var lights: [Light]
    public var scenes: [Scene]
    public var runningSceneID: UUID?
    public var demo: Bool
    public init(lights: [Light] = [], scenes: [Scene] = [], runningSceneID: UUID? = nil, demo: Bool = false) {
        self.lights = lights; self.scenes = scenes; self.runningSceneID = runningSceneID; self.demo = demo
    }
}

/// What the watch asks the phone to do.
public enum WatchRequest: Codable, Sendable, Equatable {
    /// `ids` empty means every light.
    case power(ids: [String], on: Bool)
    case brightness(id: String, value: Int)
    case runScene(UUID)
    case stopScene

    public static let key = "request"
    public static let snapshotKey = "snapshot"

    public func encoded() throws -> [String: Any] { [Self.key: try JSONEncoder().encode(self)] }
    public static func decode(_ message: [String: Any]) -> WatchRequest? {
        (message[key] as? Data).flatMap { try? JSONDecoder().decode(WatchRequest.self, from: $0) }
    }
}

extension WatchSnapshot {
    public func encoded() throws -> [String: Any] { [WatchRequest.snapshotKey: try JSONEncoder().encode(self)] }
    public static func decode(_ context: [String: Any]) -> WatchSnapshot? {
        (context[WatchRequest.snapshotKey] as? Data).flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) }
    }
}
