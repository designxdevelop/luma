import Foundation
import CryptoKit

/// Shared schedule sync, the Swift side of `desktop/src/core/schedule-sync.ts`. One desktop
/// (the runner) holds the authoritative scenes and schedules and is the only device that runs
/// them; phones and other computers pair with it over the LAN and send changes as operations.
/// Both implementations replay `desktop/src/test/fixtures/schedule-sync-vectors.json`.
///
/// - Revisions are the runner's sequence numbers. Device clocks never decide conflicts.
/// - Create, edit, enable and resume must name the revision they were based on; stale ones are refused.
/// - Disable, pause and delete always apply.
/// - Deleted records stay as tombstones, so nothing brings them back.
public enum ScheduleSync {
    public static let protocolVersion = 1
    public static let syncPath = "/v1/sync"
    public static let retirePath = "/v1/sync/retire"
    public static let defaultPort: UInt16 = 8788
    /// Both servers cap request bodies at 64 KB.
    public static let batchBytes = 48 * 1024
    public static let opsPerRequest = 200
    public static let recordLimit = 5000
    /// Runs this late still start (timer jitter, App Nap); later ones are reported as missed.
    public static let runGrace: TimeInterval = 120
    static let appliedPerClient = 500
    static let clientLimit = 64

    public enum Kind: String, Codable, Sendable { case scene, schedule }

    public struct Step: Codable, Sendable, Equatable {
        public var id: String
        public var deviceID: String
        public var command: CapabilityCommand
        public var delayMilliseconds: Int
    }
    /// Same shape as a scene in a `luma-home-backup` file.
    public struct SceneValue: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var symbol: String
        public var icon: String?
        public var steps: [Step]
    }
    public struct ScheduleValue: Codable, Sendable, Equatable {
        public var id: String
        public var sceneID: String
        public var hour: Int
        public var minute: Int
        public var weekdays: [Int]
        public var enabled: Bool
        /// Epoch milliseconds.
        public var pausedUntil: Int64?
    }
    public enum Value: Sendable, Equatable {
        case scene(SceneValue), schedule(ScheduleValue)
        public var id: String { switch self { case .scene(let s): s.id; case .schedule(let s): s.id } }
        public var kind: Kind { if case .scene = self { .scene } else { .schedule } }
    }

    public struct Record: Codable, Sendable, Equatable {
        public var kind: Kind
        public var id: String
        public var rev: Int
        public var deleted: Bool?
        public var value: Value?
        public var updatedBy: String
        public var updatedAt: Int64
        var key: String { ScheduleSync.key(kind, id) }
        public var live: Value? { deleted == true ? nil : value }
        enum CodingKeys: String, CodingKey { case kind, id, rev, deleted, value, updatedBy, updatedAt }
        public init(kind: Kind, id: String, rev: Int, deleted: Bool? = nil, value: Value?, updatedBy: String, updatedAt: Int64) {
            self.kind = kind; self.id = id; self.rev = rev; self.deleted = deleted; self.value = value; self.updatedBy = updatedBy; self.updatedAt = updatedAt
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            guard let id = ScheduleSync.canonicalID(try c.decode(String.self, forKey: .id)) else { throw SyncError.invalid("record") }
            self.id = id
            rev = try c.decode(Int.self, forKey: .rev)
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
            updatedBy = String((try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? "").prefix(64))
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
            guard rev >= 1 else { throw SyncError.invalid("record") }
            if deleted == true { value = nil; return }
            let v = try ScheduleSync.decodeValue(kind, from: c.superDecoder(forKey: .value))
            guard v.id == id else { throw SyncError.invalid("record") }
            value = v
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind); try c.encode(id, forKey: .id); try c.encode(rev, forKey: .rev)
            if deleted == true { try c.encode(true, forKey: .deleted) }
            switch value {
            case .scene(let s): try c.encode(s, forKey: .value)
            case .schedule(let s): try c.encode(s, forKey: .value)
            case nil: break
            }
            try c.encode(updatedBy, forKey: .updatedBy); try c.encode(updatedAt, forKey: .updatedAt)
        }
    }

    public enum Op: Codable, Sendable, Equatable {
        case put(opID: String, kind: Kind, id: String, baseRev: Int, value: Value)
        case reduce(opID: String, id: String, disable: Bool, pausedUntil: Int64?)
        case delete(opID: String, kind: Kind, id: String)
        public var opID: String { switch self { case .put(let o, _, _, _, _), .reduce(let o, _, _, _), .delete(let o, _, _): o } }
        public var kind: Kind { switch self { case .put(_, let k, _, _, _), .delete(_, let k, _): k; case .reduce: .schedule } }
        public var id: String { switch self { case .put(_, _, let i, _, _), .reduce(_, let i, _, _), .delete(_, _, let i): i } }
        enum CodingKeys: String, CodingKey { case opID, type, kind, id, baseRev, value, enabled, pausedUntil }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let opID = ScheduleSync.canonicalID(try c.decode(String.self, forKey: .opID)),
                  let id = ScheduleSync.canonicalID(try c.decode(String.self, forKey: .id)) else { throw SyncError.invalid("change") }
            let kind = try c.decode(Kind.self, forKey: .kind)
            switch try c.decode(String.self, forKey: .type) {
            case "put":
                let baseRev = try c.decode(Int.self, forKey: .baseRev)
                guard baseRev >= 0 else { throw SyncError.invalid("change") }
                // An invalid value is reported per change by the runner, not as a failed request.
                let value = (try? ScheduleSync.decodeValue(kind, from: c.superDecoder(forKey: .value))) ?? .scene(.init(id: "", name: "", symbol: "", steps: []))
                self = .put(opID: opID, kind: kind, id: id, baseRev: baseRev, value: value)
            case "reduce":
                guard kind == .schedule else { throw SyncError.invalid("change") }
                let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
                guard enabled != true else { throw SyncError.invalid("change") }
                let paused = try c.decodeIfPresent(Int64.self, forKey: .pausedUntil)
                guard (paused ?? 0) >= 0 else { throw SyncError.invalid("change") }
                self = .reduce(opID: opID, id: id, disable: enabled == false, pausedUntil: paused)
            case "delete": self = .delete(opID: opID, kind: kind, id: id)
            default: throw SyncError.invalid("change")
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(opID, forKey: .opID); try c.encode(kind, forKey: .kind); try c.encode(id, forKey: .id)
            switch self {
            case .put(_, _, _, let baseRev, let value):
                try c.encode("put", forKey: .type); try c.encode(baseRev, forKey: .baseRev)
                switch value { case .scene(let s): try c.encode(s, forKey: .value); case .schedule(let s): try c.encode(s, forKey: .value) }
            case .reduce(_, _, let disable, let paused):
                try c.encode("reduce", forKey: .type)
                if disable { try c.encode(false, forKey: .enabled) }
                try c.encodeIfPresent(paused, forKey: .pausedUntil)
            case .delete: try c.encode("delete", forKey: .type)
            }
        }
    }

    public enum Status: String, Codable, Sendable { case applied, conflict, gone, invalid }
    public struct OpResult: Codable, Sendable, Equatable {
        public var opID: String
        public var status: Status
        public var rev: Int?
        public var reason: String?
    }
    public struct Peer: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var platform: String
        public init(id: String, name: String, platform: String) { self.id = id; self.name = name; self.platform = platform }
    }
    public struct SeenPeer: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var platform: String
        public var lastSeen: Int64
    }
    /// What the runner observed when it ran (or skipped) a schedule. Telemetry, not settings.
    public struct RunReport: Codable, Sendable, Equatable {
        public var scheduleID: String
        public var occurrence: String
        public var at: Int64
        public var status: String
        public var detail: String?
        public var runID: String?
        public init(scheduleID: String, occurrence: String, at: Int64, status: String, detail: String? = nil, runID: String? = nil) {
            self.scheduleID = scheduleID; self.occurrence = occurrence; self.at = at; self.status = status; self.detail = detail; self.runID = runID
        }
    }
    public struct Request: Codable, Sendable {
        public var `protocol`: Int
        public var client: Peer
        public var hubID: String?
        public var since: Int
        public var ops: [Op]
        public init(protocol p: Int, client: Peer, hubID: String?, since: Int, ops: [Op]) { self.protocol = p; self.client = client; self.hubID = hubID; self.since = since; self.ops = ops }
    }
    public struct HubInfo: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var platform: String
        public var timeZone: String
        public var now: Int64
        public var executing: Bool
    }
    public struct Response: Codable, Sendable {
        public var `protocol`: Int
        public var hub: HubInfo
        public var seq: Int
        public var reset: Bool
        public var results: [OpResult]
        public var changes: [Record]
        public var runs: [RunReport]
        public var clients: [SeenPeer]
    }
    public struct Retired: Codable, Sendable, Equatable {
        public var id: String; public var name: String; public var at: Int64
        public init(id: String, name: String, at: Int64) { self.id = id; self.name = name; self.at = at }
    }
    public struct AppliedEntry: Codable, Sendable { public var opID: String; public var result: OpResult }
    public struct HubDoc: Codable, Sendable {
        public var `protocol` = 1
        public var hubID: String
        public var seq = 0
        public var records: [String: Record] = [:]
        public var applied: [String: [AppliedEntry]] = [:]
        public var clients: [String: SeenPeer] = [:]
        public var runs: [String: RunReport] = [:]
        public var retiredTo: Retired?
        public init(hubID: String = UUID().uuidString) { self.hubID = hubID }
    }

    public enum SyncError: LocalizedError, Equatable, Sendable {
        case invalid(String)
        case http(Int, String)
        public var errorDescription: String? {
            switch self { case .invalid(let what): "Invalid \(what)."; case .http(_, let message): message }
        }
        public var status: Int { if case .http(let s, _) = self { s } else { 400 } }
    }

    // MARK: Validation

    public static func canonicalID(_ id: String?) -> String? {
        guard let id, let uuid = UUID(uuidString: id), id.count == 36 else { return nil }
        return uuid.uuidString
    }
    static func key(_ kind: Kind, _ id: String) -> String { "\(kind.rawValue):\(id)" }
    static func label(_ text: String, max: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && text.count <= max && !text.unicodeScalars.contains { $0.value < 0x20 }
    }

    static func decodeValue(_ kind: Kind, from decoder: any Decoder) throws -> Value {
        switch kind {
        case .scene: .scene(try validScene(SceneValue(from: decoder)))
        case .schedule: .schedule(try validSchedule(ScheduleValue(from: decoder)))
        }
    }
    /// Structural checks only; the runner checks commands against its lights when it runs them.
    public static func validScene(_ s: SceneValue) throws -> SceneValue {
        guard let id = canonicalID(s.id), label(s.name, max: 200), !s.steps.isEmpty, s.steps.count <= 200 else { throw SyncError.invalid("scene") }
        var total = 0, seen = Set<String>()
        let steps = try s.steps.map { step -> Step in
            guard let stepID = canonicalID(step.id), !seen.contains(stepID), label(step.deviceID, max: 128), (0...60_000).contains(step.delayMilliseconds),
                  label(step.command.type, max: 128), label(step.command.instance, max: 128) else { throw SyncError.invalid("scene step") }
            seen.insert(stepID); total += step.delayMilliseconds
            guard total <= 300_000 else { throw SyncError.invalid("scene delay") }
            return Step(id: stepID, deviceID: step.deviceID, command: step.command, delayMilliseconds: step.delayMilliseconds)
        }
        let icon = s.icon.flatMap { $0.range(of: "^[a-z-]{1,24}$", options: .regularExpression) != nil ? $0 : nil }
        return SceneValue(id: id, name: s.name, symbol: label(s.symbol, max: 64) ? s.symbol : "sparkles", icon: icon, steps: steps)
    }
    public static func validSchedule(_ s: ScheduleValue) throws -> ScheduleValue {
        guard let id = canonicalID(s.id), let sceneID = canonicalID(s.sceneID), (0...23).contains(s.hour), (0...59).contains(s.minute),
              s.weekdays.count <= 7, s.weekdays.allSatisfy({ (1...7).contains($0) }), (s.pausedUntil ?? 0) >= 0 else { throw SyncError.invalid("schedule") }
        return ScheduleValue(id: id, sceneID: sceneID, hour: s.hour, minute: s.minute, weekdays: Array(Set(s.weekdays)).sorted(), enabled: s.enabled, pausedUntil: s.pausedUntil)
    }

    public static func decodeRequest(_ data: Data) throws -> Request {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["protocol"] as? Int == protocolVersion else {
            throw SyncError.http(400, "This Luma uses a different sync version. Update both apps.")
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: data), request.since >= 0, request.ops.count <= opsPerRequest,
              let clientID = canonicalID(request.client.id), label(request.client.name, max: 64), label(request.client.platform, max: 16),
              request.hubID == nil || canonicalID(request.hubID) != nil else { throw SyncError.invalid("request") }
        var r = request
        r.client.id = clientID
        r.hubID = request.hubID.flatMap(canonicalID)
        return r
    }

    // MARK: Runner

    @discardableResult
    static func bump(_ doc: inout HubDoc, kind: Kind, id: String, value: Value?, deleted: Bool = false, by: String, now: Int64) -> Int {
        doc.seq += 1
        doc.records[key(kind, id)] = Record(kind: kind, id: id, rev: doc.seq, deleted: deleted ? true : nil, value: deleted ? nil : value, updatedBy: by, updatedAt: now)
        return doc.seq
    }

    /// Applies one change. The caller saves before answering.
    public static func apply(_ op: Op, to doc: inout HubDoc, by: String, now: Int64) -> OpResult {
        let k = key(op.kind, op.id)
        let current = doc.records[k]
        func result(_ status: Status, _ reason: String? = nil, rev: Int? = nil) -> OpResult {
            OpResult(opID: op.opID, status: status, rev: rev ?? doc.records[k]?.rev, reason: reason)
        }
        switch op {
        case .delete(_, let kind, let id):
            if current?.deleted == true { return result(.applied) }
            bump(&doc, kind: kind, id: id, value: nil, deleted: true, by: by, now: now)
            if kind == .scene {
                // As in either app: deleting a scene deletes its schedules.
                for r in doc.records.values.sorted(by: { $0.rev < $1.rev }) {
                    if case .schedule(let s)? = r.live, s.sceneID == id { bump(&doc, kind: .schedule, id: r.id, value: nil, deleted: true, by: by, now: now) }
                }
            }
            return result(.applied)
        case .reduce(_, let id, let disable, let paused):
            guard let current else { return result(.gone, "This schedule was never saved on the runner.") }
            guard case .schedule(var value)? = current.live else { return result(.applied) }
            var changed = false
            if disable && value.enabled { value.enabled = false; changed = true }
            if let paused, paused > (value.pausedUntil ?? 0) { value.pausedUntil = paused; changed = true }
            if changed { bump(&doc, kind: .schedule, id: id, value: .schedule(value), by: by, now: now) }
            return result(.applied)
        case .put(_, let kind, let id, let baseRev, let value):
            guard value.kind == kind, !value.id.isEmpty else { return result(.invalid, "Invalid \(kind.rawValue).") }
            guard value.id == id else { return result(.invalid, "The record ID does not match.") }
            if current?.deleted == true { return result(.conflict, "It was deleted on another device.") }
            if current == nil && baseRev != 0 { return result(.gone, "It no longer exists on the runner.") }
            if let current, current.rev != baseRev { return result(.conflict, "It was changed on another device first.") }
            if case .schedule(let s) = value, doc.records[key(.scene, s.sceneID)]?.live == nil { return result(.invalid, "Its scene is not on the runner.") }
            if current == nil && doc.records.count >= recordLimit { return result(.invalid, "The runner holds the maximum number of records.") }
            return result(.applied, rev: bump(&doc, kind: kind, id: id, value: value, by: by, now: now))
        }
    }

    /// Handles one request against a copy of the runner's state. The caller saves the returned
    /// state before sending the response, and answers 503 (keeping the old state) if that fails.
    public static func handle(_ doc: HubDoc, body: Data, hub: Peer, timeZone: String, now: Int64) throws -> (HubDoc, Response) {
        if let retired = doc.retiredTo { throw SyncError.http(410, "Schedules now run on \(retired.name). Pair with it instead.") }
        let request = try decodeRequest(body)
        if let hubID = request.hubID, hubID != doc.hubID { throw SyncError.http(409, "This is a different runner than the one you paired with. Pair again.") }
        var next = doc
        var log = next.applied[request.client.id] ?? []
        let results = request.ops.map { op -> OpResult in
            if let seen = log.first(where: { $0.opID == op.opID }) { return seen.result }
            let r = apply(op, to: &next, by: request.client.name, now: now)
            log.append(.init(opID: op.opID, result: r))
            return r
        }
        next.applied[request.client.id] = Array(log.suffix(appliedPerClient))
        next.clients[request.client.id] = SeenPeer(id: request.client.id, name: request.client.name, platform: request.client.platform, lastSeen: now)
        let clients = next.clients.values.sorted { $0.lastSeen > $1.lastSeen }
        for stale in clients.dropFirst(clientLimit) { next.clients[stale.id] = nil; next.applied[stale.id] = nil }
        let reset = request.since > next.seq || (request.hubID == nil && request.since != 0)
        let since = reset ? 0 : request.since
        let response = Response(protocol: protocolVersion,
                                hub: HubInfo(id: next.hubID, name: hub.name, platform: hub.platform, timeZone: timeZone, now: now, executing: next.retiredTo == nil),
                                seq: next.seq, reset: reset, results: results,
                                changes: next.records.values.filter { $0.rev > since }.sorted { $0.rev < $1.rev },
                                runs: Array(next.runs.values), clients: Array(clients.prefix(clientLimit)))
        return (next, response)
    }

    public static func liveScenes(_ records: [String: Record]) -> [SceneValue] {
        records.values.compactMap { if case .scene(let s)? = $0.live { s } else { nil } }
    }
    public static func liveSchedules(_ records: [String: Record]) -> [ScheduleValue] {
        records.values.compactMap { if case .schedule(let s)? = $0.live { s } else { nil } }
    }

    // MARK: Paired device

    public struct Pending: Codable, Sendable, Equatable {
        public var kind: Kind
        public var id: String
        public var opID: String
        public var baseRev: Int
        /// nil = delete
        public var desired: Value?
        enum CodingKeys: String, CodingKey { case kind, id, opID, baseRev, desired }
        init(kind: Kind, id: String, opID: String, baseRev: Int, desired: Value?) { self.kind = kind; self.id = id; self.opID = opID; self.baseRev = baseRev; self.desired = desired }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            guard let id = ScheduleSync.canonicalID(try c.decode(String.self, forKey: .id)), let opID = ScheduleSync.canonicalID(try c.decode(String.self, forKey: .opID)) else { throw SyncError.invalid("sync file") }
            self.id = id; self.opID = opID
            baseRev = try c.decode(Int.self, forKey: .baseRev)
            desired = try c.decodeNil(forKey: .desired) ? nil : try ScheduleSync.decodeValue(kind, from: c.superDecoder(forKey: .desired))
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind); try c.encode(id, forKey: .id); try c.encode(opID, forKey: .opID); try c.encode(baseRev, forKey: .baseRev)
            switch desired { case .scene(let s)?: try c.encode(s, forKey: .desired); case .schedule(let s)?: try c.encode(s, forKey: .desired); case nil: try c.encodeNil(forKey: .desired) }
        }
    }

    public struct ClientState: Codable, Sendable {
        public var hubID: String?
        public var cursor = 0
        public var mirror: [String: Record] = [:]
        public var pending: [String: Pending] = [:]
        public init() {}

        /// Records a local change to send later. Several edits before a sync collapse into one.
        public mutating func stage(_ kind: Kind, id rawID: String, desired: Value?) throws {
            guard let id = ScheduleSync.canonicalID(rawID) else { throw SyncError.invalid("record ID") }
            let k = ScheduleSync.key(kind, id)
            let mirrored = mirror[k]
            let valid: Value? = try desired.map {
                switch $0 { case .scene(let s): .scene(try ScheduleSync.validScene(s)); case .schedule(let s): .schedule(try ScheduleSync.validSchedule(s)) }
            }
            if (valid == nil && (mirrored == nil || mirrored?.deleted == true)) || (valid != nil && mirrored?.live == valid) { pending[k] = nil; return }
            pending[k] = Pending(kind: kind, id: id, opID: UUID().uuidString, baseRev: pending[k]?.baseRev ?? mirrored?.rev ?? 0, desired: valid)
        }

        /// The runner's copy with unsent local changes on top.
        public var scenes: [SceneValue] { view().compactMap { if case .scene(let s) = $0 { s } else { nil } } }
        public var schedules: [ScheduleValue] { view().compactMap { if case .schedule(let s) = $0 { s } else { nil } } }
        public func view() -> [Value] {
            var values: [String: Value] = [:]
            for (k, r) in mirror { if let v = r.live { values[k] = v } }
            for (k, p) in pending { values[k] = p.desired }
            return values.sorted { $0.key < $1.key }.map(\.value)
        }

        /// Changes in a safe order (scenes before their schedules), split under the body limit.
        public func batches() -> [[Op]] {
            func order(_ p: Pending) -> Int { p.desired == nil ? (p.kind == .schedule ? 2 : 3) : (p.kind == .scene ? 0 : 1) }
            let ops = pending.values.sorted { (order($0), $0.id) < (order($1), $1.id) }.map { p -> Op in
                guard let desired = p.desired else { return .delete(opID: p.opID, kind: p.kind, id: p.id) }
                if case .schedule(let before)? = mirror[ScheduleSync.key(p.kind, p.id)]?.live, case .schedule(let next) = desired, ScheduleSync.onlyReduces(before, next) {
                    return .reduce(opID: p.opID, id: p.id, disable: before.enabled && !next.enabled,
                                   pausedUntil: (next.pausedUntil ?? 0) > (before.pausedUntil ?? 0) ? next.pausedUntil : nil)
                }
                return .put(opID: p.opID, kind: p.kind, id: p.id, baseRev: p.baseRev, value: desired)
            }
            var batches: [[Op]] = [[]], size = 0
            for op in ops {
                let bytes = ((try? JSONEncoder().encode(op))?.count ?? 0) + 1
                if !batches[batches.count - 1].isEmpty && (size + bytes > ScheduleSync.batchBytes || batches[batches.count - 1].count >= ScheduleSync.opsPerRequest) {
                    batches.append([op]); size = bytes
                } else { batches[batches.count - 1].append(op); size += bytes }
            }
            return batches
        }

        /// Folds a response into the mirror. Returns refused changes.
        public mutating func apply(_ response: Response, sent: [Op]) throws -> [(kind: Kind, id: String, status: Status, reason: String)] {
            if let hubID, hubID != response.hub.id { throw SyncError.http(409, "This is a different runner than the one you paired with. Pair again.") }
            hubID = response.hub.id
            if response.reset { mirror = [:] }
            for r in response.changes where response.reset || (mirror[r.key]?.rev ?? 0) < r.rev { mirror[r.key] = r }
            cursor = response.seq
            var refused: [(kind: Kind, id: String, status: Status, reason: String)] = []
            for op in sent {
                guard let result = response.results.first(where: { $0.opID == op.opID }) else { continue }
                let k = ScheduleSync.key(op.kind, op.id)
                if result.status == .applied {
                    if pending[k]?.opID == op.opID { pending[k] = nil }
                    else if pending[k] != nil, let rev = result.rev { pending[k]?.baseRev = rev } // edited again while in flight
                } else {
                    refused.append((op.kind, op.id, result.status, result.reason ?? "Refused by the runner."))
                    if pending[k]?.opID == op.opID { pending[k] = nil }
                }
            }
            for (k, p) in pending where mirror[k]?.deleted == true && p.desired != nil && p.baseRev != 0 { pending[k] = nil }
            return refused
        }
    }

    /// True when `next` only turns a schedule off or pauses it for longer.
    public static func onlyReduces(_ before: ScheduleValue, _ next: ScheduleValue) -> Bool {
        var a = before, b = next
        a.enabled = true; b.enabled = true; a.pausedUntil = nil; b.pausedUntil = nil
        guard a == b else { return false }
        let disables = before.enabled && !next.enabled, keeps = before.enabled == next.enabled
        let p1 = before.pausedUntil ?? 0, p2 = next.pausedUntil ?? 0
        return (disables || keeps) && p2 >= p1 && (disables || p2 > p1)
    }

    // MARK: Execution

    public struct Occurrence: Equatable, Sendable { public var key: String; public var at: Date; public var late: TimeInterval; public var paused: Bool }

    /// Scheduled local minutes in (lastTick, now], at most a day back. A time skipped by a
    /// spring-forward change never occurs; one repeated by fall-back shares a key, so it runs once.
    public static func occurrences(_ s: ScheduleValue, lastTick: Date, now: Date, calendar: Calendar = .current) -> [Occurrence] {
        guard s.enabled, now > lastTick else { return [] }
        let from = max(lastTick.timeIntervalSince1970, now.timeIntervalSince1970 - 86_400)
        var t = (from / 60).rounded(.down) * 60 + 60
        var found: [Occurrence] = []
        let probe = SceneSchedule(sceneID: UUID(), hour: 0, minute: 0)
        while t <= now.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: t)
            let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
            if c.hour == s.hour, c.minute == s.minute, s.weekdays.contains(c.weekday ?? 0) {
                found.append(Occurrence(key: probe.minuteKey(date, calendar: calendar), at: date, late: now.timeIntervalSince(date),
                                        paused: Double(s.pausedUntil ?? 0) / 1000 > t))
            }
            t += 60
        }
        return found
    }

    // MARK: Pairing

    public static func base32(_ bytes: some Sequence<UInt8>) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", bits = 0, value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte); bits += 8
            while bits >= 5 { out.append(alphabet[Int((value >> UInt32(bits - 5)) & 31)]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[Int((value << UInt32(5 - bits)) & 31)]) }
        return out
    }
    /// First 128 bits of the certificate's SHA-256, base32: short enough to type, long enough to pin.
    public static func certPin(_ der: Data) -> String { base32(SHA256.hash(data: der).prefix(16)) }
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return base32((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    public struct PairingCode: Equatable, Sendable {
        public var host: String
        public var port: UInt16
        public var pin: String
        public var token: String
        public init(host: String, port: UInt16, pin: String, token: String) { self.host = host; self.port = port; self.pin = pin; self.token = token }
        public var text: String { "luma1/\(host)/\(port)/\(pin)/\(token)" }
        public init(parsing raw: String) throws {
            let parts = raw.filter { !$0.isWhitespace }.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let bad = SyncError.http(400, "That pairing code is not complete. Copy it again from the computer that runs schedules.")
            guard parts.count == 5, parts[0].lowercased() == "luma1", let port = Int(parts[2]), (1...65535).contains(port),
                  parts[1].range(of: "^[A-Za-z0-9.-]{1,253}$", options: .regularExpression) != nil else { throw bad }
            let pin = parts[3].uppercased(), token = parts[4].uppercased()
            guard pin.range(of: "^[A-Z2-7]{26}$", options: .regularExpression) != nil, token.range(of: "^[A-Z2-7]{26}$", options: .regularExpression) != nil else { throw bad }
            self.init(host: parts[1], port: UInt16(port), pin: pin, token: token)
        }
    }
}

extension ScheduleSync.SceneValue {
    /// The wire form of a native scene: uppercase UUIDs, Electron icon derived on the other side.
    public init(_ scene: LightScene) {
        self.init(id: scene.id.uuidString, name: scene.name, symbol: scene.symbol, icon: nil,
                  steps: scene.steps.map { .init(id: $0.id.uuidString, deviceID: $0.deviceID, command: $0.command, delayMilliseconds: $0.delayMilliseconds) })
    }
    public var scene: LightScene? {
        guard let id = UUID(uuidString: id) else { return nil }
        let steps = self.steps.compactMap { s in UUID(uuidString: s.id).map { SceneStep(id: $0, deviceID: s.deviceID, command: s.command, delayMilliseconds: s.delayMilliseconds) } }
        return LightScene(id: id, name: name, symbol: symbol, steps: steps)
    }
}

extension ScheduleSync.ScheduleValue {
    public init(_ s: SceneSchedule) {
        self.init(id: s.id.uuidString, sceneID: s.sceneID.uuidString, hour: s.hour, minute: s.minute, weekdays: Array(Set(s.weekdays)).sorted(), enabled: s.enabled,
                  pausedUntil: s.pausedUntil.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) })
    }
    public func schedule(lastRunMinute: String?) -> SceneSchedule? {
        guard let id = UUID(uuidString: id), let sceneID = UUID(uuidString: sceneID) else { return nil }
        var s = SceneSchedule(id: id, sceneID: sceneID, hour: hour, minute: minute, weekdays: weekdays, enabled: enabled, lastRunMinute: lastRunMinute)
        s.pausedUntil = pausedUntil.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        return s
    }
}

/// One HTTPS request to a runner whose certificate must match the pairing pin. The pin is
/// checked in the TLS trust challenge, before the request (and its bearer token) is sent.
public enum ScheduleSyncTransport {
    public static func send(_ target: ScheduleSync.PairingCode, path: String, body: Data, timeout: TimeInterval = 10) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: "https://\(target.host):\(target.port)\(path)") else { throw ScheduleSync.SyncError.http(400, "Invalid runner address.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let delegate = PinDelegate(pin: target.pin)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            if delegate.mismatched { throw ScheduleSync.SyncError.http(495, "The runner's identity doesn't match the pairing code. Pair again.") }
            throw ScheduleSync.SyncError.http(503, "Can't reach the runner (\((error as NSError).localizedDescription)).")
        }
    }

    final class PinDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let pin: String
        private let lock = NSLock()
        private var _mismatched = false
        var mismatched: Bool { lock.withLock { _mismatched } }
        init(pin: String) { self.pin = pin }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return (.cancelAuthenticationChallenge, nil) }
            guard ScheduleSync.certPin(SecCertificateCopyData(leaf) as Data) == pin else {
                lock.withLock { _mismatched = true }
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
    }
}
