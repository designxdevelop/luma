#if canImport(AppIntents)
import AppIntents
import LumaUI

// Siri and Shortcuts actions. They run inside the Luma app process (no extension),
// so they use the same home.json and Keychain items as the app. Rooms and scenes
// are looked up by name or ID each time an action runs, so a shortcut made for
// "Bedroom" always controls whatever lights are in Bedroom at that moment.

/// The app target lists this in its own AppIntentsPackage so these types are registered.
public struct LumaIntentsPackage: AppIntentsPackage {}

// MARK: - Rooms

public struct RoomEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room"
    public static let defaultQuery = RoomQuery()
    /// The room name as shown in Luma, or `LumaSiri.allLightsRoom`.
    public let id: String
    public let title: String
    public let lightCount: Int
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(lightCount) \(lightCount == 1 ? "light" : "lights") now")
    }
    init(_ room: LumaSiri.Room) { id = room.id; title = room.title; lightCount = room.lightCount }
}

public struct RoomQuery: EntityStringQuery {
    public init() {}
    /// Known IDs always resolve, even a room that is empty now, so the action can
    /// say so instead of Siri silently asking for a different room.
    @MainActor public func entities(for identifiers: [String]) async throws -> [RoomEntity] {
        identifiers.map { RoomEntity(LumaSiri.room($0)) }
    }
    @MainActor public func entities(matching string: String) async throws -> [RoomEntity] {
        LumaSiri.rooms().filter { $0.title.range(of: string, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(RoomEntity.init)
    }
    @MainActor public func suggestedEntities() async throws -> [RoomEntity] { LumaSiri.rooms().map(RoomEntity.init) }
}

public struct TurnOnRoomIntent: AppIntent {
    public static let title: LocalizedStringResource = "Turn On Room"
    public static let description = IntentDescription("Turns on every light that is in the room when the action runs, including lights added later.")
    @Parameter(title: "Room") public var room: RoomEntity
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Turn on \(\.$room)") }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await LumaSiri.setPower(true, room: room.id))")
    }
}

public struct TurnOffRoomIntent: AppIntent {
    public static let title: LocalizedStringResource = "Turn Off Room"
    public static let description = IntentDescription("Turns off every light that is in the room when the action runs, including lights added later.")
    @Parameter(title: "Room") public var room: RoomEntity
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Turn off \(\.$room)") }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await LumaSiri.setPower(false, room: room.id))")
    }
}

public struct SetRoomBrightnessIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Room Brightness"
    public static let description = IntentDescription("Sets the brightness of every dimmable light in the room when the action runs.")
    @Parameter(title: "Room") public var room: RoomEntity
    @Parameter(title: "Brightness", description: "Percent, 1 to 100", inclusiveRange: (1, 100)) public var percent: Int
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Set \(\.$room) to \(\.$percent)%") }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await LumaSiri.setBrightness(percent, room: room.id))")
    }
}

/// Named colors and whites, so Siri understands "warm white" or "blue".
public enum LightColor: String, AppEnum {
    case red, orange, yellow, green, teal, blue, purple, pink, warmWhite, softWhite, daylight, coolWhite
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Color"
    public static let caseDisplayRepresentations: [LightColor: DisplayRepresentation] = [
        .red: "Red", .orange: "Orange", .yellow: "Yellow", .green: "Green", .teal: "Teal", .blue: "Blue",
        .purple: "Purple", .pink: "Pink", .warmWhite: "Warm White", .softWhite: "Soft White", .daylight: "Daylight", .coolWhite: "Cool White"
    ]
    public var rgb: Int? {
        switch self {
        case .red: 0xFF2A1F
        case .orange: 0xFF7A1A
        case .yellow: 0xFFD21F
        case .green: 0x2BD94A
        case .teal: 0x1FC9C0
        case .blue: 0x2457FF
        case .purple: 0x8A3BFF
        case .pink: 0xFF4FA3
        default: nil
        }
    }
    public var kelvin: Int? {
        switch self {
        case .warmWhite: 2700
        case .softWhite: 3000
        case .daylight: 5000
        case .coolWhite: 6500
        default: nil
        }
    }
}

public struct SetRoomColorIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Room Color"
    public static let description = IntentDescription("Sets a color or white on every light in the room when the action runs. Whites stay within each light's own range.")
    @Parameter(title: "Room") public var room: RoomEntity
    @Parameter(title: "Color") public var color: LightColor
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Set \(\.$room) to \(\.$color)") }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = if let kelvin = color.kelvin { try await LumaSiri.setWhite(kelvin, room: room.id) }
                      else { try await LumaSiri.setColor(color.rgb ?? 0xFFFFFF, room: room.id) }
        return .result(dialog: "\(message)")
    }
}

// MARK: - Luma scenes

public struct LumaSceneEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Luma Scene"
    public static let defaultQuery = LumaSceneQuery()
    public let id: UUID
    public let name: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    init(_ scene: LumaSiri.Scene) { id = scene.id; name = scene.name }
}

public struct LumaSceneQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [UUID]) async throws -> [LumaSceneEntity] {
        LumaSiri.scenes().filter { identifiers.contains($0.id) }.map(LumaSceneEntity.init)
    }
    @MainActor public func entities(matching string: String) async throws -> [LumaSceneEntity] {
        LumaSiri.scenes().filter { $0.name.range(of: string, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(LumaSceneEntity.init)
    }
    @MainActor public func suggestedEntities() async throws -> [LumaSceneEntity] { LumaSiri.scenes().map(LumaSceneEntity.init) }
}

public struct RunLumaSceneIntent: AppIntent {
    public static let title: LocalizedStringResource = "Run Luma Scene"
    public static let description = IntentDescription("Runs a scene saved in Luma and waits up to 20 seconds for its steps to be sent.")
    @Parameter(title: "Scene") public var scene: LumaSceneEntity
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Run \(\.$scene)") }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await LumaSiri.runScene(scene.id))")
    }
}

// MARK: - Govee scenes

/// A Govee built-in, DIY, or snapshot scene name. The same name can exist on
/// several models; applying it sends each light its own option with that name.
public struct GoveeSceneEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Govee Scene"
    public static let defaultQuery = GoveeSceneQuery()
    public let id: String
    public let name: String
    public let kindTitle: String
    public let lightCount: Int
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kindTitle) · \(lightCount) \(lightCount == 1 ? "light" : "lights")")
    }
    init(_ scene: LumaSiri.GoveeScene) { id = scene.id; name = scene.name; kindTitle = scene.kindTitle; lightCount = scene.lightCount }
}

public struct GoveeSceneQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [GoveeSceneEntity] {
        identifiers.compactMap(LumaSiri.goveeScene(id:)).map(GoveeSceneEntity.init)
    }
    @MainActor public func entities(matching string: String) async throws -> [GoveeSceneEntity] {
        LumaSiri.goveeScenes().filter { $0.name.range(of: string, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(GoveeSceneEntity.init)
    }
    @MainActor public func suggestedEntities() async throws -> [GoveeSceneEntity] { LumaSiri.goveeScenes().map(GoveeSceneEntity.init) }
}

public struct ApplyGoveeSceneIntent: AppIntent {
    public static let title: LocalizedStringResource = "Apply Govee Scene"
    public static let description = IntentDescription("Applies a Govee scene to every light in the room that lists it, using the scene lists Luma has loaded. Other lights are skipped.")
    @Parameter(title: "Room") public var room: RoomEntity
    @Parameter(title: "Scene") public var scene: GoveeSceneEntity
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$scene) to \(\.$room)") }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await LumaSiri.applyGoveeScene(scene.id, room: room.id))")
    }
}
#endif
