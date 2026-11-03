import Foundation

/// Rooms and partner-light metadata from a Govee Home device list: the private
/// app API's `GET /bff-app/v1/device/list` body (shape per goveetl @ 3890402 and
/// homebridge-govee @ c7b3037). It comes from `GoveeAccount` sign-in or a saved
/// file. The official API key already imports devices, names, and capabilities,
/// but not rooms or BLE identity.
public enum GoveeHomeImport {
    public struct Entry: Sendable, Equatable {
        public var device: String
        public var sku: String
        public var name: String
        public var room: String?
        /// From `deviceExt.deviceSettings`: what a DreamView member record identifies a light by.
        public var bleName: String? = nil
        public var bleAddress: String? = nil
        public var firmware: String? = nil
    }

    public struct RoomChange: Sendable, Equatable, Identifiable {
        public var deviceID: String
        public var name: String
        public var currentRoom: String
        public var goveeRoom: String
        /// Only rooms Luma never assigned are preselected; anything else is a Luma edit.
        public var selectedByDefault: Bool { currentRoom == "Unassigned" }
        public var id: String { deviceID }
    }

    public struct Plan: Sendable, Equatable, Identifiable {
        public let id = UUID()
        public var changes: [RoomChange] = []
        public var unchanged = 0
        public var withoutRoom = 0
        /// In the Govee file but not known to Luma (or a different model under the same ID).
        public var notInLuma: [Entry] = []
        /// Entries matched to a Luma light, for BLE identity and partner metadata.
        public var matched: [String: Entry] = [:]
        /// Filled only by a signed-in import; a saved device-list file has neither.
        public var groups: [HomeGroup] = []
        public var automations: [Automation] = []
        /// Account reads that failed without failing the room import.
        public var unavailable: [String] = []
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        guard data.count <= 8 * 1024 * 1024 else { throw LumaError.message("The Govee Home file is too large.") }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw LumaError.message("That file isn't JSON.") }
        if let status = root["status"]?.number, status != 200 { throw LumaError.message("That file is a failed Govee response (status \(Int(status))).") }
        let body = root["data"] ?? root
        guard let devices = body["devices"]?.array else {
            throw LumaError.message("No device list found. Save the response of GET /bff-app/v1/device/list.")
        }
        var rooms: [Double: String] = [:]
        for group in body["groups"]?.array ?? [] {
            guard let id = group["groupId"]?.number, let name = clean(group["groupName"]?.string) else { continue }
            rooms[id] = name
        }
        // Only identity, model, name, and room are read; everything else is ignored.
        return devices.compactMap { row in
            guard let device = clean(row["device"]?.string), let sku = clean(row["sku"]?.string) else { return nil }
            // A live account (2026-11-02) had no DreamView group fields here; groups come from `parseGroups`.
            let settings = nested(row["deviceExt"]?["deviceSettings"])
            return Entry(device: device, sku: sku, name: clean(row["deviceName"]?.string) ?? sku,
                         room: row["groupId"]?.number.flatMap { rooms[$0] },
                         bleName: clean(settings?["bleName"]?.string), bleAddress: clean(settings?["address"]?.string),
                         firmware: clean(row["versionSoft"]?.string ?? settings?["wifiSoftVersion"]?.string))
        }
    }

    /// `deviceExt` fields arrive as JSON-encoded strings (homebridge parses them); accept objects too.
    private static func nested(_ value: JSONValue?) -> JSONValue? {
        if case .string(let text)? = value { return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        return value
    }

    /// Matches on device ID (case-insensitive) and model. Never creates lights:
    /// a light without capabilities from the API or LAN can't be controlled.
    public static func plan(_ entries: [Entry], devices: [LightDevice]) -> Plan {
        var plan = Plan()
        for entry in entries {
            guard let device = devices.first(where: { $0.id.caseInsensitiveCompare(entry.device) == .orderedSame && $0.sku.caseInsensitiveCompare(entry.sku) == .orderedSame }) else {
                plan.notInLuma.append(entry); continue
            }
            plan.matched[device.id] = entry
            guard let room = entry.room else { plan.withoutRoom += 1; continue }
            if room == device.room { plan.unchanged += 1; continue }
            plan.changes.append(.init(deviceID: device.id, name: device.customName ?? device.name, currentRoom: device.room, goveeRoom: room))
        }
        return plan
    }

    // MARK: Groups and automations (signed-in import only)

    /// A Govee Home control group from `GET bff-app/v1/general-control/list`.
    public struct HomeGroup: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var name: String
        /// Govee's `enable`. Not the same as sync running: that is `dreamViewToggle`.
        public var enabled: Bool
        /// Govee's `deviceCount`; whether it counts the main light isn't known.
        public var reportedLightCount: Int?
        public var mainDevice: String?
        public var mainSKU: String?
        /// Observed on one live account: the DreamView group had `type` 10 and a
        /// `sceneFeastId` ("feast" is Govee's internal name for DreamView).
        public var isDreamView: Bool
        public init(id: Int, name: String, enabled: Bool, reportedLightCount: Int?, mainDevice: String?, mainSKU: String?, isDreamView: Bool) {
            self.id = id; self.name = name; self.enabled = enabled; self.reportedLightCount = reportedLightCount
            self.mainDevice = mainDevice; self.mainSKU = mainSKU; self.isDreamView = isDreamView
        }
    }

    public static func parseGroups(_ data: Data) throws -> [HomeGroup] {
        let body = try envelope(data)
        return (body["list"]?.array ?? []).compactMap { row in
            guard let id = row["groupId"]?.number, let name = clean(row["name"]?.string) else { return nil }
            let main = row["mainDevice"]
            return HomeGroup(id: Int(id), name: name, enabled: row["enable"]?.number == 1,
                             reportedLightCount: row["deviceCount"]?.number.map { Int($0) },
                             mainDevice: clean(main?["device"]?.string), mainSKU: clean(main?["sku"]?.string),
                             isDreamView: row["type"]?.number == 10 && (row["sceneFeastId"]?.number ?? 0) > 0)
        }
    }

    /// A Govee Home automation from `GET bff-app/v1/ecology/resource/automations`. Read-only.
    public struct Automation: Codable, Sendable, Equatable, Identifiable {
        public struct Time: Codable, Sendable, Equatable {
            public var hour: Int; public var minute: Int
            public init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }
        }
        public struct Target: Codable, Sendable, Equatable {
            public var sku: String; public var name: String; public var isDreamView: Bool
            public init(sku: String, name: String, isDreamView: Bool) { self.sku = sku; self.name = name; self.isDreamView = isDreamView }
        }
        public var id: Int
        public var name: String
        public var enabled: Bool
        public var times: [Time]
        /// Govee's `repeat` values 1–7, as sent. Which number is which weekday isn't verified.
        public var repeatDays: [Int]
        public var targets: [Target]
        public var everyDay: Bool { Set(repeatDays) == Set(1...7) }
        public init(id: Int, name: String, enabled: Bool, times: [Time], repeatDays: [Int], targets: [Target]) {
            self.id = id; self.name = name; self.enabled = enabled; self.times = times; self.repeatDays = repeatDays; self.targets = targets
        }
    }

    public static func parseAutomations(_ data: Data) throws -> [Automation] {
        let body = try envelope(data)
        return (body["autoExecs"]?.array ?? []).compactMap { row in
            guard let id = row["groupId"]?.number, let name = clean(row["name"]?.string) else { return nil }
            let schedule = row["schedule"]
            let times = (schedule?["times"]?.array ?? []).compactMap { t -> Automation.Time? in
                guard let h = t["hour"]?.number, let m = t["minute"]?.number, (0..<24).contains(h), (0..<60).contains(m) else { return nil }
                return .init(hour: Int(h), minute: Int(m))
            }
            let targets = (schedule?["skus"]?.array ?? []).compactMap { t -> Automation.Target? in
                guard let sku = clean(t["sku"]?.string) else { return nil }
                let dreamView = t["isFeast"]?.number == 1
                return .init(sku: sku, name: clean(dreamView ? t["feastName"]?.string : t["deviceName"]?.string) ?? sku, isDreamView: dreamView)
            }
            return Automation(id: Int(id), name: name, enabled: row["enable"]?.number == 1, times: times,
                              repeatDays: (schedule?["repeat"]?.array ?? []).compactMap { $0.number.map { Int($0) } }, targets: targets)
        }
    }

    public struct Conflict: Sendable, Equatable {
        public var automation: String
        public var scheduleID: UUID
        public var light: String
    }

    /// Enabled Govee automations that fire at the same minute as an enabled Luma
    /// schedule touching the same light (matched by model and Govee name, as the
    /// automation list has no device ID). Days aren't compared: Govee's weekday
    /// numbering isn't verified, so a match is a possible conflict.
    public static func conflicts(_ automations: [Automation], schedules: [SceneSchedule], scenes: [LightScene], devices: [LightDevice]) -> [Conflict] {
        var found: [Conflict] = []
        for automation in automations where automation.enabled {
            for schedule in schedules where schedule.enabled && automation.times.contains(.init(hour: schedule.hour, minute: schedule.minute)) {
                let ids = Set(scenes.first { $0.id == schedule.sceneID }?.steps.map(\.deviceID) ?? [])
                for device in devices where ids.contains(device.id) {
                    guard let target = automation.targets.first(where: { !$0.isDreamView && $0.sku.caseInsensitiveCompare(device.sku) == .orderedSame && $0.name == device.name }) else { continue }
                    found.append(.init(automation: automation.name, scheduleID: schedule.id, light: device.customName ?? target.name))
                }
            }
        }
        return found
    }

    private static func envelope(_ data: Data) throws -> JSONValue {
        guard data.count <= 8 * 1024 * 1024, let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw LumaError.message("Govee Home returned an unreadable response.") }
        if let status = root["status"]?.number, status != 200 { throw LumaError.message("Govee Home request failed (status \(Int(status))).") }
        return root["data"] ?? root
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(64))
    }
}
