import Foundation
import LumaCore

/// What happened when one action ran across a set of lights. Uses names, not IDs,
/// so Siri and the Activity log can read it out.
struct LightActionReport: Equatable {
    struct Miss: Equatable { var light: String; var reason: String }
    var target: String
    /// Past-tense phrase for the summary, e.g. "turned on".
    var verb = "updated"
    var sent: [String] = []
    var skipped: [Miss] = []
    var failed: [Miss] = []

    var summary: String {
        var parts: [String] = []
        if !sent.isEmpty { parts.append("\(target): \(verb) \(sent.count) \(sent.count == 1 ? "light" : "lights").") }
        if !skipped.isEmpty { parts.append("Skipped " + Self.grouped(skipped) + ".") }
        if !failed.isEmpty { parts.append("Failed: " + Self.grouped(failed) + ".") }
        return parts.joined(separator: " ")
    }
    /// "A, B (offline), C (no color control)": lights sharing a reason are listed once.
    private static func grouped(_ misses: [Miss]) -> String {
        var reasons: [String] = []
        for miss in misses where !reasons.contains(miss.reason) { reasons.append(miss.reason) }
        return reasons.map { reason in misses.filter { $0.reason == reason }.map(\.light).joined(separator: ", ") + " (\(reason))" }.joined(separator: ", ")
    }
}

/// Room and scene actions for Siri, Shortcuts, and one-click Govee scenes. Rooms
/// are resolved to their member lights each time an action runs, never when a
/// shortcut is made, so lights added to or moved out of a room are picked up.
extension HomeStore {
    /// Pseudo-room meaning every light, so "All Lights" works like any room.
    static let allLightsRoom = "luma.all-lights"

    /// Current members, by the room name shown in Luma (case-insensitive).
    func lights(inRoom room: String) -> [LightDevice] {
        // Siri room and All Lights actions never switch appliances or sensors.
        room == Self.allLightsRoom ? lights : lights.filter { $0.room.caseInsensitiveCompare(room) == .orderedSame }
    }
    func roomTitle(_ room: String) -> String {
        room == Self.allLightsRoom ? "All lights" : rooms.first { $0.caseInsensitiveCompare(room) == .orderedSame } ?? room
    }

    /// Runs one command per light. `command` returns nil plus a reason to skip a
    /// light. Lights reported offline are skipped. Writes go out together and the
    /// call returns once each was accepted by LAN or the cloud, not after readback.
    /// Throws when nothing could be sent, so Siri reports a failure.
    func run(on lights: [LightDevice], target: String, verb: String = "updated", command: (LightDevice) -> (CapabilityCommand?, String)) async throws -> LightActionReport {
        var report = LightActionReport(target: target, verb: verb)
        guard !lights.isEmpty else { throw LumaError.message("Luma has no lights in \(target) right now.") }
        var jobs: [(LightDevice, CapabilityCommand)] = []
        for light in lights {
            if light.online == false { report.skipped.append(.init(light: light.name, reason: "offline")); continue }
            let (cmd, reason) = command(light)
            if let cmd { jobs.append((light, cmd)) } else { report.skipped.append(.init(light: light.name, reason: reason)) }
        }
        // Each light has its own write queue, so starting all sends first lets them overlap.
        let tasks = jobs.map { light, cmd in
            (light, Task { () -> String? in
                do { try await self.send(cmd, to: light.id, resumeOnAccept: true); return nil }
                catch { return error.localizedDescription }
            })
        }
        for (light, task) in tasks {
            if let error = await task.value { report.failed.append(.init(light: light.name, reason: error)) } else { report.sent.append(light.name) }
        }
        log(report.summary, error: report.sent.isEmpty)
        guard !report.sent.isEmpty else { throw LumaError.message(report.summary) }
        return report
    }

    func setPower(_ on: Bool, room: String) async throws -> LightActionReport {
        try await run(on: lights(inRoom: room), target: roomTitle(room), verb: on ? "turned on" : "turned off") {
            $0.supports("powerSwitch") ? (.power(on), "") : (nil, "no power control")
        }
    }
    func setBrightness(_ percent: Int, room: String) async throws -> LightActionReport {
        let value = min(max(percent, 1), 100)
        return try await run(on: lights(inRoom: room), target: roomTitle(room), verb: "set \(value)% brightness on") {
            $0.supports("brightness") ? (.brightness(value), "") : (nil, "no brightness control")
        }
    }
    func setColor(_ rgb: Int, room: String) async throws -> LightActionReport {
        try await run(on: lights(inRoom: room), target: roomTitle(room), verb: "changed the color of") {
            $0.supports("colorRgb") ? (.rgb(rgb), "") : (nil, "no color control")
        }
    }
    func setWhite(_ kelvin: Int, room: String) async throws -> LightActionReport {
        try await run(on: lights(inRoom: room), target: roomTitle(room), verb: "set white on") {
            $0.supports("colorTemperatureK") ? (.kelvin(Self.clampedKelvin(kelvin, for: $0)), "") : (nil, "no white control")
        }
    }
    /// The temperature limited to the light's advertised range.
    static func clampedKelvin(_ kelvin: Int, for device: LightDevice) -> Int {
        let range = device.capabilities.first { $0.instance == "colorTemperatureK" }?.parameters?["range"]
        let low = range?["min"]?.number.map(Int.init) ?? 2000, high = range?["max"]?.number.map(Int.init) ?? 9000
        return min(max(kelvin, low), high)
    }

    /// Applies a Govee scene by kind and name to every light that lists it, sent
    /// directly (no Luma scene is created). Lights without it are skipped.
    func applyGoveeScene(kind: GoveeSceneOption.Kind, name: String, to lights: [LightDevice], target: String) async throws -> LightActionReport {
        guard cloudConnected || lights.allSatisfy(\.isDemo) else {
            throw LumaError.message("Govee scenes need the Govee cloud. Connect your account in Settings.")
        }
        return try await run(on: lights, target: target, verb: "applied \(name) to") { light in
            if let option = GoveeSceneLibrary.match(kind: kind, name: name, on: light) { return (option.command, "") }
            return (nil, GoveeSceneLibrary.options(for: light).isEmpty ? "scenes not loaded" : "doesn't list \(name)")
        }
    }

    /// Scene names (with kind) listed by at least one light in the room, for the
    /// Siri / Shortcuts picker. `count` is how many current members list it.
    func goveeSceneChoices(room: String? = nil) -> [(kind: GoveeSceneOption.Kind, name: String, count: Int)] {
        var result: [(kind: GoveeSceneOption.Kind, name: String, count: Int)] = []
        var index: [String: Int] = [:]
        for light in room.map(lights(inRoom:)) ?? devices {
            var seen = Set<String>()
            for option in GoveeSceneLibrary.options(for: light) {
                let key = option.kind.rawValue + "|" + option.name.lowercased()
                guard seen.insert(key).inserted else { continue }
                if let i = index[key] { result[i].count += 1 } else { index[key] = result.count; result.append((option.kind, option.name, 1)) }
            }
        }
        return result
    }

    /// Starts a saved Luma scene and waits (up to `limit`) for it to finish, so a
    /// Siri request doesn't return while steps are still queued. A scene with long
    /// waits may outlast that; iOS can then suspend Luma before the rest is sent.
    func runSceneAndWait(_ id: UUID, limit: Duration = .seconds(20)) async throws -> String {
        guard let scene = home.scenes.first(where: { $0.id == id }) else {
            throw LumaError.message("That Luma scene no longer exists. Edit the shortcut and pick another.")
        }
        let runID = try runScene(scene)
        let deadline = ContinuousClock.now.advanced(by: limit)
        while runs.first(where: { $0.id == runID })?.status == "running", ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let run = runs.first { $0.id == runID }
        switch run?.status {
        case "completed": return "Ran \(scene.name)."
        case "running": return "Started \(scene.name). It's still running."
        default: throw LumaError.message(run?.error ?? "\(scene.name) stopped before it finished.")
        }
    }

    /// Changes whenever a name used in a Siri phrase changes (rooms, Luma scenes),
    /// so the app can refresh its App Shortcut parameters. Govee scene names aren't
    /// in any phrase (Siri asks for them), and are too costly to rebuild on every edit.
    var shortcutVocabulary: [String] { rooms + home.scenes.map(\.name) }
}

/// The store Siri actions use: the app's shared store. Tests set `testStore`.
enum IntentHost {
    static var testStore: HomeStore?
    static var store: HomeStore { testStore ?? .shared }
    /// Waits for the launch-time cloud reconnect (a Siri request can cold-launch Luma).
    static func ready() async -> HomeStore {
        let store = store
        await store.ready()
        return store
    }
}

/// Public surface for the LumaIntents module (Siri / Shortcuts). Everything is
/// looked up when called, so stored shortcuts never hold light IDs.
public enum LumaSiri {
    public nonisolated struct Room: Sendable, Equatable { public let id: String; public let title: String; public let lightCount: Int }
    public nonisolated struct Scene: Sendable, Equatable { public let id: UUID; public let name: String }
    public nonisolated struct GoveeScene: Sendable, Equatable {
        /// "<kind>|<name>", e.g. "lightScene|Sunrise".
        public let id: String; public let name: String; public let kindTitle: String; public let lightCount: Int
    }

    /// Set by the app target (which owns the App Shortcuts provider) to refresh Siri's
    /// phrase vocabulary when room or scene names change.
    public static var vocabularyChanged: () -> Void = {}
    /// Pseudo-room for every light.
    public static let allLightsRoom = HomeStore.allLightsRoom

    public static func room(_ id: String) -> Room {
        let store = IntentHost.store
        return Room(id: id, title: store.roomTitle(id), lightCount: store.lights(inRoom: id).count)
    }
    public static func rooms() -> [Room] { ([HomeStore.allLightsRoom] + IntentHost.store.rooms).map(room) }
    public static func scenes() -> [Scene] { IntentHost.store.home.scenes.map { Scene(id: $0.id, name: $0.name) } }
    public static func goveeScenes() -> [GoveeScene] {
        IntentHost.store.goveeSceneChoices().map { GoveeScene(id: $0.kind.rawValue + "|" + $0.name, name: $0.name, kindTitle: $0.kind.title, lightCount: $0.count) }
    }
    /// Known IDs resolve even when no light lists the scene now (count 0), so the
    /// action can explain instead of Siri asking for something else.
    public static func goveeScene(id: String) -> GoveeScene? {
        guard let (kind, name) = parse(id) else { return nil }
        let count = IntentHost.store.goveeSceneChoices().first { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }?.count ?? 0
        return GoveeScene(id: id, name: name, kindTitle: kind.title, lightCount: count)
    }

    public static func setPower(_ on: Bool, room: String) async throws -> String { try await IntentHost.ready().setPower(on, room: room).summary }
    public static func setBrightness(_ percent: Int, room: String) async throws -> String { try await IntentHost.ready().setBrightness(percent, room: room).summary }
    public static func setColor(_ rgb: Int, room: String) async throws -> String { try await IntentHost.ready().setColor(rgb, room: room).summary }
    public static func setWhite(_ kelvin: Int, room: String) async throws -> String { try await IntentHost.ready().setWhite(kelvin, room: room).summary }
    public static func runScene(_ id: UUID) async throws -> String { try await IntentHost.ready().runSceneAndWait(id) }
    public static func applyGoveeScene(_ id: String, room: String) async throws -> String {
        guard let (kind, name) = parse(id) else { throw LumaError.message("That Govee scene isn't valid. Pick it again.") }
        let store = await IntentHost.ready()
        return try await store.applyGoveeScene(kind: kind, name: name, to: store.lights(inRoom: room), target: store.roomTitle(room)).summary
    }

    private static func parse(_ id: String) -> (GoveeSceneOption.Kind, String)? {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = GoveeSceneOption.Kind(rawValue: parts[0]) else { return nil }
        return (kind, parts[1])
    }
}
