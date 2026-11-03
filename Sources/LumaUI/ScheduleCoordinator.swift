import CloudKit
import Foundation
import LumaCore

struct LeaseConflict: Error {}

/// Thrown by `HomeStore.send` when a command failed before it left this device,
/// so a scheduled run may safely retry that single step.
struct CommandNotSent: LocalizedError {
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }
}

@MainActor protocol ScheduleLeaseStore: AnyObject {
    func accountID() async throws -> String
    func read(_ occurrence: String) async throws -> OccurrenceLease?
    /// Compare-and-swap. Throws `LeaseConflict` when the server record is not `previous`.
    func write(_ occurrence: String, _ lease: OccurrenceLease, expecting previous: OccurrenceLease?) async throws
}

@MainActor protocol ScheduleHost: AnyObject {
    func coordinatedSchedule(_ id: UUID) -> (SceneSchedule, ScheduleCoordination, LightScene)?
    func beginScheduledRun(_ scene: LightScene) -> UUID?
    func endScheduledRun(_ runID: UUID, status: String, error: String?)
    func sendScheduled(_ step: SceneStep) async throws
}

/// Runs coordinated schedules only under a confirmed cloud lease. Never claims
/// exactly-once delivery: an ambiguous send ends the run as `uncertain` instead of replaying.
@MainActor final class ScheduleCoordinator {
    private enum Local: String, Codable { case started }
    let device: String
    let policy: FailoverPolicy
    private let store: any ScheduleLeaseStore
    private weak var host: (any ScheduleHost)?
    private let file: URL?
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var local: [String: Local] = [:]
    private var ticking = false
    private var runTask: Task<Void, Never>?
    private(set) var status: [UUID: String] = [:]
    var onStatus: () -> Void = {}
    /// The account whose synced configuration defined these schedules. Leases in any other account are never claimed.
    var expectedAccount: () -> String? = { nil }

    init(device: String, store: any ScheduleLeaseStore, host: any ScheduleHost, file: URL?, policy: FailoverPolicy = .init(),
         now: @escaping () -> Date = Date.init, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.device = device; self.store = store; self.host = host; self.file = file; self.policy = policy; self.now = now; self.sleep = sleep
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Local].self, from: data) {
            // Anything started before a crash or quit stays done; it is never resumed or replayed.
            local = saved
        }
    }

    func cancel() { runTask?.cancel() }

    func tick(_ schedules: [(SceneSchedule, ScheduleCoordination)]) async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        for (schedule, coordination) in schedules where schedule.enabled {
            guard let role = ScheduleFailover.role(of: device, in: coordination) else { continue }
            guard let zone = TimeZone(identifier: coordination.timeZone) else { report(schedule.id, "Paused: unknown time zone"); continue }
            let time = now()
            guard let fire = ScheduleFailover.fireInstant(schedule, zone: zone, atOrBefore: time),
                  time <= fire + TimeInterval(coordination.graceSeconds) else { continue }
            let occurrence = ScheduleFailover.occurrenceID(schedule.id, fire: fire)
            guard local[occurrence] == nil else { continue }
            let task = Task { await self.attempt(schedule.id, occurrence: occurrence, fire: fire, role: role) }
            runTask = task
            await task.value
            runTask = nil
        }
    }

    private func report(_ id: UUID, _ text: String) { status[id] = text; onStatus() }

    private func markStarted(_ occurrence: String) {
        local[occurrence] = .started
        // ponytail: keeps two days of keys; occurrence IDs end in their epoch.
        let cutoff = Int64(now().timeIntervalSince1970) - 172_800
        local = local.filter { Int64($0.key.split(separator: "-").last ?? "") ?? 0 > cutoff }
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(local).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Whole seconds: CloudKit dates round-trip at millisecond precision, and lease equality includes `expiresAt`.
    private func stamp(_ start: Date) -> Date { Date(timeIntervalSince1970: (start.timeIntervalSince1970 + policy.leaseTTL).rounded(.down)) }

    private func backoff(_ attempt: Int) -> TimeInterval { min(16, pow(2, Double(attempt + 1))) }

    private func attempt(_ id: UUID, occurrence: String, fire: Date, role: ScheduleFailover.Role) async {
        guard let host, let (schedule, coordination, scene) = host.coordinatedSchedule(id) else { return }
        let deadline = fire + TimeInterval(coordination.graceSeconds)
        let nonce = UUID().uuidString
        var lease: OccurrenceLease!
        var validUntil = Date.distantPast
        let account: String
        do { account = try await store.accountID() } catch { report(id, "Not run: iCloud unavailable"); return }
        guard account == expectedAccount() else { report(id, "Paused: waiting for iCloud sync or Apple Account changed"); return }

        // Claim: bounded retries, never past the deadline.
        for attempt in 0..<policy.maxAttempts {
            guard !Task.isCancelled else { return }
            let start = now()
            guard start <= deadline else { break }
            do {
                let current = try await store.read(occurrence)
                if let current, current.nonce == nonce { lease = current; validUntil = stamp(start) - policy.skew; break }
                guard ScheduleFailover.mayClaim(current, device: device, role: role, fire: fire, now: start, grace: TimeInterval(coordination.graceSeconds), policy: policy) else {
                    if let current, current.holder != device, current.state != .claimed || start > deadline {
                        // Expired running lease: the holder may have sent commands. Record, never resume.
                        if current.state == .running, start > current.expiresAt + policy.skew {
                            var marked = current; marked.state = .uncertain; marked.note = "Holder stopped responding"
                            try? await store.write(occurrence, marked, expecting: current)
                        }
                        markStarted(occurrence)
                        report(id, "Handled by another device")
                    }
                    return // Fallback still waiting, or nothing to do yet.
                }
                let mine = OccurrenceLease(holder: device, nonce: nonce, state: .claimed, expiresAt: stamp(start))
                try await store.write(occurrence, mine, expecting: current)
                lease = mine; validUntil = stamp(start) - policy.skew
                break
            } catch is LeaseConflict {
                continue
            } catch {
                guard attempt + 1 < policy.maxAttempts, now() + backoff(attempt) < deadline else { break }
                try? await sleep(.seconds(backoff(attempt)))
            }
        }
        guard lease != nil else { report(id, "Not run: could not reach iCloud before \(deadline.formatted(date: .omitted, time: .shortened))"); return }
        markStarted(occurrence)

        func commit(_ next: OccurrenceLease) async -> Bool {
            for attempt in 0..<3 {
                let start = now()
                var stamped = next
                if !(next.state == .completed || next.state == .failed || next.state == .uncertain || next.state == .cancelled || next.state == .skipped) {
                    stamped.expiresAt = stamp(start)
                }
                do {
                    guard try await store.accountID() == account else { return false }
                    try await store.write(occurrence, stamped, expecting: lease)
                    lease = stamped; validUntil = stamp(start) - policy.skew
                    return true
                } catch {
                    let server = try? await store.read(occurrence)
                    if server == stamped { lease = stamped; validUntil = stamp(start) - policy.skew; return true }
                    guard server == lease, !(error is LeaseConflict), attempt < 2 else { return false }
                    try? await sleep(.seconds(backoff(attempt)))
                }
            }
            return false
        }
        func finish(_ state: OccurrenceLease.State, _ note: String?) async {
            var final = lease!; final.state = state; final.note = note
            _ = await commit(final)
        }

        // Nothing has been sent. Confirm `running` before the first command.
        guard now() <= deadline else { await finish(.skipped, "Too late"); report(id, "Skipped: started too late"); return }
        guard let runID = host.beginScheduledRun(scene) else { await finish(.skipped, "Another scene was running"); report(id, "Skipped: another scene was running"); return }
        var running = lease!; running.state = .running
        guard await commit(running) else {
            host.endScheduledRun(runID, status: "skipped", error: "Lost the iCloud claim")
            report(id, "Skipped: another device took over"); return
        }

        let ttlGuard = policy.renewBelow
        func keepLease(step: Int) async -> Bool {
            if validUntil.timeIntervalSince(now()) < ttlGuard {
                var renewed = lease!; renewed.step = step
                if await commit(renewed) { return true }
            }
            return now() < validUntil
        }
        func stillCurrent() -> Bool {
            guard let (s, c, sc) = host.coordinatedSchedule(id) else { return false }
            return s == schedule && c == coordination && sc == scene
        }

        var outcome: (OccurrenceLease.State, String?) = (.completed, nil)
        steps: for (index, step) in scene.steps.enumerated() {
            var remaining = Double(step.delayMilliseconds) / 1000
            while remaining > 0 {
                guard await keepLease(step: index) else { outcome = (.uncertain, "Lost iCloud lease"); break steps }
                let chunk = min(remaining, policy.leaseTTL / 4)
                do { try await sleep(.seconds(chunk)) } catch { outcome = (.cancelled, "Stopped"); break steps }
                remaining -= chunk
            }
            for attempt in 0... {
                if Task.isCancelled { outcome = (.cancelled, "Stopped"); break steps }
                guard stillCurrent() else { outcome = (.cancelled, "Schedule changed or was deleted"); break steps }
                guard await keepLease(step: index) else { outcome = (.uncertain, "Lost iCloud lease"); break steps }
                do {
                    try await host.sendScheduled(step)
                    break
                } catch let error as CommandNotSent {
                    // Provably unsent: retry this step only, bounded by attempts and the deadline.
                    guard attempt + 1 < policy.maxAttempts, now() + backoff(attempt) < deadline else {
                        outcome = (.failed, "Step \(index + 1): \(error.localizedDescription)"); break steps
                    }
                    try? await sleep(.seconds(backoff(attempt)))
                } catch is CancellationError {
                    outcome = (.cancelled, "Stopped"); break steps
                } catch {
                    // Possibly delivered; replaying could duplicate brightness or color.
                    outcome = (.uncertain, "Step \(index + 1): \(error.localizedDescription)"); break steps
                }
            }
        }
        await finish(outcome.0, outcome.1)
        host.endScheduledRun(runID, status: outcome.0.rawValue, error: outcome.1)
        let label = switch outcome.0 {
        case .completed: "Ran on this device"
        case .uncertain: "Stopped; result uncertain, not retried"
        default: "\(outcome.0.rawValue.capitalized): \(outcome.1 ?? "")"
        }
        report(id, label)
    }
}

/// Private-database leases in their own zone, so configuration sync never downloads them.
@MainActor final class CloudScheduleLeaseStore: ScheduleLeaseStore {
    private let container = CKContainer(identifier: CloudSyncTransport.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "LumaSchedule", ownerName: CKCurrentUserDefaultName)
    private var records: [String: CKRecord] = [:]
    private var zoneReady = false

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CloudSyncTransport.Failure.unavailable }
        return try await container.userRecordID().recordName
    }

    func read(_ occurrence: String) async throws -> OccurrenceLease? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: occurrence, zoneID: zoneID))
            records[occurrence] = record
            return try Self.decode(record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            if error.code == .zoneNotFound { zoneReady = false }
            records[occurrence] = nil
            return nil
        }
    }

    func write(_ occurrence: String, _ lease: OccurrenceLease, expecting previous: OccurrenceLease?) async throws {
        if !zoneReady { _ = try await database.save(CKRecordZone(zoneID: zoneID)); zoneReady = true }
        let id = CKRecord.ID(recordName: occurrence, zoneID: zoneID)
        let record: CKRecord
        if let previous {
            guard let cached = records[occurrence], (try? Self.decode(cached)) == previous else { throw LeaseConflict() }
            record = cached.copy() as! CKRecord
        } else {
            record = CKRecord(recordType: "LumaScheduleLease", recordID: id)
        }
        record["holder"] = lease.holder as CKRecordValue
        record["nonce"] = lease.nonce as CKRecordValue
        record["state"] = lease.state.rawValue as CKRecordValue
        record["expiresAt"] = lease.expiresAt as CKRecordValue
        record["step"] = NSNumber(value: lease.step)
        record["note"] = lease.note as CKRecordValue?
        do {
            // A new record with this policy fails with serverRecordChanged if one already exists.
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = result.saveResults[id] else { throw CloudSyncTransport.Failure.malformedRecord }
            records[occurrence] = try saved.get()
        } catch let error as CKError where error.code == .serverRecordChanged {
            records[occurrence] = error.serverRecord
            throw LeaseConflict()
        } catch let error as CKError where error.code == .zoneNotFound {
            zoneReady = false
            throw error
        }
    }

    private static func decode(_ record: CKRecord) throws -> OccurrenceLease {
        guard let holder = record["holder"] as? String, let nonce = record["nonce"] as? String,
              let raw = record["state"] as? String, let state = OccurrenceLease.State(rawValue: raw),
              let expiresAt = record["expiresAt"] as? Date, let step = record["step"] as? NSNumber else {
            throw CloudSyncTransport.Failure.malformedRecord
        }
        return OccurrenceLease(holder: holder, nonce: nonce, state: state, expiresAt: expiresAt, step: step.intValue, note: record["note"] as? String)
    }
}

enum CloudAvailability {
    /// Must be checked before any `CKContainer` exists: CloudKit traps without the entitlement.
    static var isEntitled: Bool {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String] else { return false }
        return containers.contains(CloudSyncTransport.containerIdentifier) && (services.contains("CloudKit") || services.contains("*"))
#elseif targetEnvironment(simulator)
        return false
#else
        return true // iOS device builds are always provisioned with the project's iCloud entitlement.
#endif
    }
}
