import Foundation

/// One entry from a light's Govee scene lists: a built-in (`lightScene`), DIY
/// (`diyScene`), or snapshot option exactly as Govee's public API listed it.
/// That list is what the API returns for the model, not Govee Home's full catalog.
public struct GoveeSceneOption: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case builtIn = "lightScene", diy = "diyScene", snapshot = "snapshot"
        public var title: String {
            switch self {
            case .builtIn: "Built-in"
            case .diy: "DIY"
            case .snapshot: "Snapshot"
            }
        }
    }
    public var kind: Kind
    public var name: String
    /// Capability type from the light, sent back unchanged.
    public var type: String
    /// Opaque option value from Govee (an id, or an `{id, paramId}` object).
    public var value: JSONValue
    /// Kind, position in the light's list, and name: stable for one list, and cheap
    /// (no JSON encoding), since the browser reads it for every row on each keystroke.
    public let id: String
    public var command: CapabilityCommand { .init(type: type, instance: kind.rawValue, value: value) }
    public init(kind: Kind, name: String, type: String, value: JSONValue, index: Int = 0) {
        self.kind = kind; self.name = name; self.type = type; self.value = value
        id = kind.rawValue + "|\(index)|" + name
    }
}

public enum GoveeSceneLibrary {
    /// Every scene option the light has listed so far, in Govee's order, built-in first.
    /// Unnamed options get a placeholder so they stay reachable; duplicates are dropped.
    public static func options(for device: LightDevice) -> [GoveeSceneOption] {
        var result: [GoveeSceneOption] = []
        for kind in GoveeSceneOption.Kind.allCases {
            guard let capability = device.capabilities.first(where: { $0.instance == kind.rawValue }) else { continue }
            var seen: [String: [JSONValue]] = [:]
            for (index, option) in (capability.parameters?["options"]?.array ?? []).enumerated() {
                guard let value = option["value"] else { continue }
                let trimmed = option["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = trimmed.isEmpty ? "\(kind.title) \(index + 1)" : trimmed
                // Same name and value listed twice (static + dynamic lists) shows once.
                if seen[name]?.contains(value) == true { continue }
                seen[name, default: []].append(value)
                result.append(GoveeSceneOption(kind: kind, name: name, type: capability.type, value: value, index: index))
            }
        }
        return result
    }

    /// Whether the model advertises a scene list at all, loaded or not.
    public static func advertisesScenes(_ device: LightDevice) -> Bool {
        device.capabilities.contains { GoveeSceneOption.Kind(rawValue: $0.instance) != nil }
    }

    /// Case- and accent-insensitive name filter; an empty query keeps everything.
    public static func filter(_ options: [GoveeSceneOption], query: String, kind: GoveeSceneOption.Kind? = nil) -> [GoveeSceneOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter { option in
            (kind == nil || option.kind == kind) && (query.isEmpty || option.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// The option on this light with the same kind and name (case-insensitive), for
    /// applying one scene name across a room of different models.
    public static func match(kind: GoveeSceneOption.Kind, name: String, on device: LightDevice) -> GoveeSceneOption? {
        options(for: device).first { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
