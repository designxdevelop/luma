import Foundation
import Observation
import LumaCore
#if canImport(UIKit)
import UIKit
#endif

/// Schedule sync for the native app: a Mac can run shared schedules ("runner"); an iPhone,
/// iPad or another Mac pairs with the runner and never runs them itself. Rules live in
/// `LumaCore/ScheduleSync.swift`. Tokens and the TLS key stay in the Keychain; only the
/// shared copy and status are written to `schedule-sync.json`.
@Observable final class ScheduleSyncController {
    enum Role: String, Codable { case off, runner, paired }
    struct Client: Codable {
        var host: String
        var port: UInt16
        var pin: String
        var state = ScheduleSync.ClientState()
        var runner: ScheduleSync.HubInfo?
        var lastSync: Date?
        var lastError: String?
        var moved: String?
        var runs: [ScheduleSync.RunReport] = []
    }
    struct Target: Codable { var host: String; var port: UInt16; var pin: String; var name: String }
    struct Saved: Codable {
        var version = 1
        var role = Role.off
        var device: ScheduleSync.Peer
        var keepAwake = false
        var port = ScheduleSync.defaultPort
        var runner: ScheduleSync.HubDoc?
        var client: Client?
        /// A forced take-over the old runner hasn't confirmed; nothing runs until it does.
        var retirePending: Target?
    }
    /// Keychain access, replaceable in tests.
    struct Secrets {
        var read: (String) throws -> String?
        var save: (String, String) throws -> Void
        var delete: (String) throws -> Void
        static let keychain = Secrets(read: { try SecretStore.read($0) }, save: { try SecretStore.save($1, account: $0) }, delete: { try SecretStore.delete($0) })
    }
    typealias Transport = @Sendable (ScheduleSync.PairingCode, String, Data) async throws -> (status: Int, body: Data)

    static let tokenKey = "schedule-sync-token", clientTokenKey = "schedule-sync-client-token", retireTokenKey = "schedule-sync-retire-token"
    static let tlsLabel = "app.luma.schedule-sync-tls"

    private(set) var saved: Saved
    var notices: [String] = []
    private(set) var serverStatus = "Stopped"
    private(set) var pin: String?
    private(set) var syncing = false

    // Wired by HomeStore.
    var scenes: () -> [LightScene] = { [] }
    var schedules: () -> [SceneSchedule] = { [] }
    /// Replaces the home's scenes and schedules with the shared view and saves home.json.
    var apply: ([LightScene], [SceneSchedule]) -> Void = { _, _ in }
    var run: (UUID) throws -> UUID = { _ in throw LumaError.message("Not connected.") }
    /// True while a scene is running; due runs wait in `queued` until it ends.
    var busy: () -> Bool = { false }
    var runStatus: (UUID) -> String? = { _ in nil }
    var log: (String, Bool) -> Void = { _, _ in }

    private let folder: URL?
    private let secrets: Secrets
    private let transport: Transport
    private let now: () -> Date
    private let calendar: Calendar
    private let server = WebhookServer()
    private var lastTick: Date
    private var loop: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var flushAgain = false
    /// Due runs that found a scene running, in due order. In memory only; reported when they start or are missed.
    private var queued: [(id: String, occ: ScheduleSync.Occurrence)] = []
    /// False in tests: no listener and no Keychain TLS identity.
    private let serves: Bool

    /// `folder` nil (demo) turns sync off entirely.
    init(folder: URL?, secrets: Secrets = .keychain, transport: @escaping Transport = { try await ScheduleSyncTransport.send($0, path: $1, body: $2) },
         now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent, serves: Bool = true) {
        self.folder = folder; self.secrets = secrets; self.transport = transport; self.now = now; self.calendar = calendar; self.serves = serves
        lastTick = now()
        saved = Saved(device: .init(id: UUID().uuidString, name: Self.deviceName, platform: Self.platform))
        guard let file = folder?.appending(path: "schedule-sync.json"), FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            var loaded = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
            guard loaded.version == 1, (loaded.role != .runner || loaded.runner != nil), (loaded.role != .paired || loaded.client != nil) else { throw LumaError.message("bad") }
            loaded.device.platform = Self.platform
            saved = loaded
        } catch {
            // Fail closed: never fall back to running schedules locally.
            saved.role = .paired
            notices.append("The schedule sync file couldn't be read, so schedules won't run on this device. It was left at \(file.path). Turn sync off, then on again.")
        }
    }

    static var platform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }
    static var deviceName: String {
        #if os(macOS)
        String((Host.current().localizedName ?? "Mac").prefix(64))
        #elseif canImport(UIKit)
        UIDevice.current.model
        #else
        "Device"
        #endif
    }
    static var canRun: Bool { platform == "macos" }

    var enabled: Bool { folder != nil }
    var role: Role { saved.role }
    /// Only an active runner, or a device not sharing schedules at all, may run them.
    var mayExecute: Bool {
        switch saved.role {
        case .off: true
        case .runner: saved.runner != nil && saved.runner?.retiredTo == nil && saved.retirePending == nil
        case .paired: false
        }
    }
    var client: Client? { saved.client }
    var runnerDoc: ScheduleSync.HubDoc? { saved.runner }
    var pairingCodes: [String] {
        guard saved.role == .runner, saved.runner?.retiredTo == nil, let pin, let token = try? secrets.read(Self.tokenKey) else { return [] }
        let port = server.boundPort ?? saved.port
        return LocalCertificate.lanNames().filter { $0.range(of: "^[0-9.]+$", options: .regularExpression) != nil }
            .map { ScheduleSync.PairingCode(host: $0, port: port, pin: pin, token: token).text }
    }
    /// Latest report per schedule ID, from whichever side observed it.
    var runReports: [String: ScheduleSync.RunReport] {
        let list = saved.role == .runner ? Array(saved.runner?.runs.values ?? [:].values) : saved.client?.runs ?? []
        return Dictionary(list.map { ($0.scheduleID, $0) }, uniquingKeysWith: { a, b in a.at > b.at ? a : b })
    }
    var unsent: Int { saved.client?.state.pending.count ?? 0 }

    func start() {
        guard enabled else { return }
        if saved.role == .runner { startServer() } // a retired runner keeps answering 410 so devices learn where schedules went
        updateActivity()
        if saved.role == .paired || saved.retirePending != nil { startLoop() }
        materialize()
    }
    func stop() { loop?.cancel(); loop = nil; server.stop(); endActivity() }

    // MARK: Setup

    func becomeRunner() throws {
        try requireReady()
        guard Self.canRun else { throw LumaError.message("Schedules run on a Mac, Windows or Linux computer that stays on. Pair this device with one instead.") }
        guard saved.role == .off else { throw LumaError.message("Turn schedule sync off first.") }
        var doc = ScheduleSync.HubDoc()
        let stamp = millis(now())
        for s in scenes() { _ = ScheduleSync.apply(.put(opID: UUID().uuidString, kind: .scene, id: s.id.uuidString, baseRev: 0, value: .scene(.init(s))), to: &doc, by: saved.device.name, now: stamp) }
        for s in schedules() { _ = ScheduleSync.apply(.put(opID: UUID().uuidString, kind: .schedule, id: s.id.uuidString, baseRev: 0, value: .schedule(.init(s))), to: &doc, by: saved.device.name, now: stamp) }
        if try secrets.read(Self.tokenKey) == nil { try secrets.save(Self.tokenKey, ScheduleSync.newToken()) }
        saved.role = .runner; saved.runner = doc; saved.client = nil
        guard save() else { saved.role = .off; saved.runner = nil; throw LumaError.message("Couldn't save schedule sync.") }
        lastTick = now()
        materialize()
        startServer()
        updateActivity()
        log("This Mac now runs shared schedules. Pair your iPhone or other computers with its pairing code.", false)
    }

    /// Pairs with a runner. This device's scenes and schedules are added to the runner's; same IDs keep the runner's copy.
    func pair(_ code: String) async throws {
        try requireReady()
        if saved.role == .runner, saved.runner?.retiredTo == nil { throw LumaError.message("This Mac runs schedules. Turn that off before pairing it with another computer.") }
        let target = try ScheduleSync.PairingCode(parsing: code)
        let previous = saved.client
        var client = Client(host: target.host, port: target.port, pin: target.pin)
        let response = try await request(&client, token: target.token, ops: [])
        // Same runner at a new address keeps its copy and unsent changes; a runner that was turned off and on is a new one.
        let sameRunner = previous != nil && previous?.pin == target.pin && previous?.state.hubID == response.hub.id
        if sameRunner, let previous { client.state = previous.state }
        else {
            _ = try client.state.apply(response, sent: [])
            if let dropped = previous?.state.pending.count, dropped > 0 { notices.append("\(dropped) unsent change\(dropped == 1 ? " was" : "s were") dropped: this is a different runner than before.") }
        }
        try secrets.save(Self.clientTokenKey, target.token)
        if !sameRunner {
            for s in scenes() where client.state.mirror["scene:\(s.id.uuidString)"] == nil { try? client.state.stage(.scene, id: s.id.uuidString, desired: .scene(.init(s))) }
            for s in schedules() where client.state.mirror["schedule:\(s.id.uuidString)"] == nil { try? client.state.stage(.schedule, id: s.id.uuidString, desired: .schedule(.init(s))) }
        }
        client.runner = response.hub; client.runs = response.runs; client.lastSync = now()
        server.stop(); serverStatus = "Stopped"
        saved.role = .paired; saved.runner = nil; saved.client = client
        _ = save()
        updateActivity()
        materialize()
        startLoop()
        log("Paired with \(response.hub.name). It runs your schedules; this device won't.", false)
        await syncNow()
    }

    /// Turns sharing off. A paired or handed-off device turns its schedules off first, so nothing runs twice.
    func turnOff() {
        let wasRunner = saved.role == .runner && saved.runner?.retiredTo == nil && saved.retirePending == nil
        loop?.cancel(); loop = nil; server.stop(); serverStatus = "Stopped"
        if !wasRunner && saved.role != .off {
            apply(scenes(), schedules().map { var s = $0; s.enabled = false; return s })
            log("Schedule sync is off. Schedules here were turned off so they don't also run on the other computer; turn on the ones this device should run.", false)
        } else if wasRunner { log("Schedule sync is off. Paired devices can no longer see or change these schedules.", false) }
        saved.role = .off; saved.runner = nil; saved.client = nil; saved.retirePending = nil
        try? secrets.delete(Self.clientTokenKey); try? secrets.delete(Self.retireTokenKey)
        _ = save()
        updateActivity()
    }

    /// Moves running schedules here. The old runner must confirm; with `force` this Mac keeps asking and runs nothing until it does.
    func takeOver(force: Bool) async throws {
        try requireReady()
        guard Self.canRun else { throw LumaError.message("Only a computer can run schedules.") }
        guard saved.role == .paired, let token = try secrets.read(Self.clientTokenKey) else { throw LumaError.message("Pair with the current runner first.") }
        await syncNow()
        guard let client = saved.client else { return }
        var doc = ScheduleSync.HubDoc()
        let target = ScheduleSync.PairingCode(host: client.host, port: client.port, pin: client.pin, token: token)
        var confirmed = true
        do { try await retire(target, newRunner: doc.hubID) } catch { if !force { throw error }; confirmed = false }
        for r in client.state.mirror.values { doc.records["\(r.kind.rawValue):\(r.id)"] = r }
        doc.seq = doc.records.values.map(\.rev).max() ?? 0
        let stamp = millis(now())
        for p in client.state.pending.values {
            let rev = doc.records["\(p.kind.rawValue):\(p.id)"]?.rev ?? 0
            let op: ScheduleSync.Op = p.desired.map { .put(opID: UUID().uuidString, kind: p.kind, id: p.id, baseRev: rev, value: $0) } ?? .delete(opID: UUID().uuidString, kind: p.kind, id: p.id)
            _ = ScheduleSync.apply(op, to: &doc, by: saved.device.name, now: stamp)
        }
        if try secrets.read(Self.tokenKey) == nil { try secrets.save(Self.tokenKey, ScheduleSync.newToken()) }
        if !confirmed { try secrets.save(Self.retireTokenKey, token) }
        saved.role = .runner; saved.runner = doc; saved.client = nil
        saved.retirePending = confirmed ? nil : Target(host: client.host, port: client.port, pin: client.pin, name: client.runner?.name ?? "the old runner")
        try? secrets.delete(Self.clientTokenKey)
        _ = save()
        lastTick = now()
        materialize()
        startServer()
        updateActivity()
        loop?.cancel(); loop = nil
        if !confirmed { startLoop() }
        log(confirmed ? "This Mac now runs shared schedules. Pair your other devices with its pairing code."
                      : "This Mac will run shared schedules once \(client.runner?.name ?? "the old runner") confirms it stopped. Until then this computer runs nothing; the old runner may still run its copy.", false)
    }

    func setKeepAwake(_ on: Bool) { saved.keepAwake = on; _ = save(); updateActivity() }

    func rotatePairing() throws {
        try requireReady()
        guard saved.role == .runner else { return }
        try secrets.save(Self.tokenKey, ScheduleSync.newToken())
        startServer()
        log("Pairing code replaced. Pair each device again.", false)
    }

    /// A backup restore would replace everything without the change rules.
    func assertMayReplaceAll() throws {
        if saved.role != .off { throw LumaError.message("Turn schedule sync off before restoring a backup, so restored schedules can't undo changes made on other devices.") }
    }

    // MARK: Local edits

    /// Called by HomeStore.persist(): every scene/schedule edit, wherever it came from, becomes a shared change.
    func reconcile() {
        guard enabled, saved.role != .off else { return }
        if saved.role == .runner, saved.runner?.retiredTo != nil { return }
        let shared = sharedValues()
        let localScenes = Dictionary(scenes().map { scene -> (String, ScheduleSync.Value) in
            var value = ScheduleSync.SceneValue(scene)
            // Native scenes have no Electron icon: keep the shared one while the symbol is unchanged, or every Electron scene would look edited.
            if case .scene(let old)? = shared["scene:\(value.id)"], old.symbol == value.symbol { value.icon = old.icon }
            return (value.id, .scene(value))
        }, uniquingKeysWith: { a, _ in a })
        let localSchedules = Dictionary(schedules().map { ($0.id.uuidString, ScheduleSync.Value.schedule(.init($0))) }, uniquingKeysWith: { a, _ in a })
        var changes: [(ScheduleSync.Kind, String, ScheduleSync.Value?)] = []
        for (kind, local) in [(ScheduleSync.Kind.scene, localScenes), (.schedule, localSchedules)] {
            for (id, value) in local where shared["\(kind.rawValue):\(id)"] != value { changes.append((kind, id, value)) }
            for key in shared.keys where key.hasPrefix(kind.rawValue + ":") {
                let id = String(key.dropFirst(kind.rawValue.count + 1))
                if local[id] == nil { changes.append((kind, id, nil)) }
            }
        }
        guard !changes.isEmpty else { return }
        changes.sort { ($0.2 == nil ? 1 : 0, $0.0 == .scene ? 0 : 1) < ($1.2 == nil ? 1 : 0, $1.0 == .scene ? 0 : 1) }
        if saved.role == .runner, var doc = saved.runner {
            let stamp = millis(now())
            for (kind, id, value) in changes {
                let rev = doc.records["\(kind.rawValue):\(id)"]?.rev ?? 0
                let op: ScheduleSync.Op = value.map { .put(opID: UUID().uuidString, kind: kind, id: id, baseRev: rev, value: $0) } ?? .delete(opID: UUID().uuidString, kind: kind, id: id)
                let r = ScheduleSync.apply(op, to: &doc, by: saved.device.name, now: stamp)
                if r.status != .applied { notices.append("Not shared: \(r.reason ?? r.status.rawValue)") }
            }
            saved.runner = doc
            _ = save()
        } else if saved.role == .paired, var client = saved.client {
            for (kind, id, value) in changes {
                do { try client.state.stage(kind, id: id, desired: value) } catch { notices.append("Not shared: \(error.localizedDescription)") }
            }
            saved.client = client
            _ = save()
            Task { await self.syncNow() }
        }
    }

    // MARK: Execution (runner only)

    /// Runs due shared schedules. Returns false when HomeStore's own scheduler should run instead.
    func tick(_ date: Date? = nil) -> Bool {
        guard enabled, saved.role != .off else { queued.removeAll(); return false }
        let current = date ?? now()
        let previous = lastTick
        lastTick = current
        guard mayExecute, var doc = saved.runner else { queued.removeAll(); return true }
        var local = schedules()
        var changed = false, localChanged = false
        for value in ScheduleSync.liveSchedules(doc.records) {
            let index = local.firstIndex { $0.id.uuidString == value.id }
            for occ in ScheduleSync.occurrences(value, lastTick: previous, now: current, calendar: calendar) {
                if let index, local[index].lastRunMinute == occ.key { continue }
                if doc.runs[value.id]?.occurrence == occ.key { continue }
                // Recorded before the scene starts, so a crash skips the run rather than repeating it.
                if let index { local[index].lastRunMinute = occ.key; localChanged = true }
                var report = ScheduleSync.RunReport(scheduleID: value.id, occurrence: occ.key, at: millis(current), status: "started")
                if occ.paused { report.status = "paused" }
                else if occ.late > ScheduleSync.runGrace {
                    report.status = "missed"
                    report.detail = "This Mac was asleep or Luma was closed until \(Int(occ.late / 60)) min after the scheduled time."
                    log("Missed a schedule: \(report.detail!)", true)
                } else { queued.append((value.id, occ)); continue }
                doc.runs[value.id] = report
                changed = true
            }
        }
        // Oldest first; one still waiting past the grace is reported missed. Each must still be live, enabled and unpaused.
        // ponytail: drained only on ticks (15 s), like HomeStore's legacy queue.
        queued.sort { ($0.occ.at, $0.id) < ($1.occ.at, $1.id) }
        while let next = queued.first {
            guard let value = ScheduleSync.liveSchedules(doc.records).first(where: { $0.id == next.id }), value.enabled,
                  Double(value.pausedUntil ?? 0) / 1000 <= next.occ.at.timeIntervalSince1970 else { queued.removeFirst(); continue }
            var report = ScheduleSync.RunReport(scheduleID: next.id, occurrence: next.occ.key, at: millis(current), status: "started")
            let late = current.timeIntervalSince(next.occ.at)
            if late > ScheduleSync.runGrace {
                report.status = "missed"
                report.detail = "Another scene was still running \(Int(late / 60)) min after the scheduled time."
                log("Missed a schedule: \(report.detail!)", true)
            } else {
                guard !busy() else { break }
                if let sceneID = UUID(uuidString: value.sceneID) {
                    if localChanged { apply(scenes(), local); localChanged = false }
                    do { report.runID = try run(sceneID).uuidString }
                    catch { report.status = "failed"; report.detail = error.localizedDescription; log("Schedule skipped: \(error.localizedDescription)", true) }
                }
            }
            queued.removeFirst()
            doc.runs[next.id] = report
            changed = true
        }
        if localChanged { apply(scenes(), local) }
        if changed { saved.runner = doc; _ = save() }
        return true
    }

    // MARK: Paired device

    func syncNow() async {
        if syncing { flushAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            flushAgain = false
            await flush()
        } while flushAgain
    }

    private func flush() async {
        if let pending = saved.retirePending, let token = try? secrets.read(Self.retireTokenKey), let doc = saved.runner {
            do {
                try await retire(.init(host: pending.host, port: pending.port, pin: pending.pin, token: token), newRunner: doc.hubID)
                saved.retirePending = nil; try? secrets.delete(Self.retireTokenKey); lastTick = now(); _ = save()
                if saved.role != .paired { loop?.cancel(); loop = nil }
                updateActivity()
                log("\(pending.name) confirmed it stopped running schedules. They run on this Mac now.", false)
            } catch { /* still unreachable; retried next round */ }
        }
        guard saved.role == .paired, var client = saved.client, let token = try? secrets.read(Self.clientTokenKey) else { return }
        do {
            for batch in client.state.batches() {
                let response = try await request(&client, token: token, ops: batch)
                let refused = try client.state.apply(response, sent: batch)
                client.runner = response.hub; client.runs = response.runs; client.lastSync = now(); client.lastError = nil; client.moved = nil
                for r in refused { notices.append("A change to a \(r.kind.rawValue) wasn't applied: \(r.reason) The runner's version is shown.") }
                if notices.count > 10 { notices.removeFirst(notices.count - 10) }
                if saved.role == .paired { saved.client = client; _ = save() }
            }
        } catch {
            client.lastError = error.localizedDescription
            if (error as? ScheduleSync.SyncError)?.status == 410 { client.moved = error.localizedDescription }
            if saved.role == .paired { saved.client = client; _ = save() }
        }
        if saved.role == .paired { materialize() }
    }

    private func retire(_ target: ScheduleSync.PairingCode, newRunner: String) async throws {
        let body = try JSONEncoder().encode(RetireBody(protocol: ScheduleSync.protocolVersion, runner: .init(id: newRunner, name: saved.device.name)))
        let r = try await transport(target, ScheduleSync.retirePath, body)
        guard r.status == 200 || r.status == 410 else { throw ScheduleSync.SyncError.http(r.status, Self.errorText(r.body) ?? "The runner refused (\(r.status)).") }
    }
    struct RetireBody: Codable { var `protocol`: Int; var runner: RetireRunner }
    struct RetireRunner: Codable { var id: String; var name: String }

    private func request(_ client: inout Client, token: String, ops: [ScheduleSync.Op]) async throws -> ScheduleSync.Response {
        let body = try JSONEncoder().encode(ScheduleSync.Request(protocol: ScheduleSync.protocolVersion, client: saved.device, hubID: client.state.hubID, since: client.state.cursor, ops: ops))
        let r = try await transport(.init(host: client.host, port: client.port, pin: client.pin, token: token), ScheduleSync.syncPath, body)
        guard r.status == 200 else { throw ScheduleSync.SyncError.http(r.status, Self.errorText(r.body) ?? "The runner answered \(r.status).") }
        do { return try JSONDecoder().decode(ScheduleSync.Response.self, from: r.body) }
        catch { throw ScheduleSync.SyncError.http(502, "The runner sent an answer this version can't read.") }
    }
    static func errorText(_ data: Data) -> String? { (try? JSONDecoder().decode([String: String].self, from: data))?["error"] }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                await self.syncNow()
            }
        }
    }

    // MARK: Runner server

    private func startServer() {
        guard serves else { return }
        do {
            guard let token = try secrets.read(Self.tokenKey) else { throw LumaError.message("Missing pairing secret.") }
            let tls = try WebhookTLS.load(demo: false, label: Self.tlsLabel)
            pin = ScheduleSync.certPin(tls.certificate)
            try server.start(port: saved.port, allowLAN: true, token: token, identity: tls.identity, handler: { [weak self] request in
                guard let self else { return WebhookResponse(status: 503, json: .object(["error": .string("App shutting down")])) }
                return self.handle(request)
            }, onState: { [weak self] state in self?.serverStatus = state })
        } catch {
            serverStatus = "Not running: \(error.localizedDescription)"
            log("Schedule sync: \(serverStatus)", true)
        }
    }

    /// The runner's request handler (exposed for tests).
    func handle(_ request: WebhookRequest) -> WebhookResponse {
        guard saved.role == .runner, let doc = saved.runner else { return .init(status: 503, json: .object(["error": .string("This device no longer runs schedules.")])) }
        guard request.method == "POST" else { return .init(status: 405, json: .object(["error": .string("Use POST")])) }
        do {
            if request.path == ScheduleSync.syncPath {
                var (next, response) = try ScheduleSync.handle(doc, body: request.body, hub: saved.device, timeZone: calendar.timeZone.identifier, now: millis(now()))
                for i in response.runs.indices {
                    if let id = response.runs[i].runID.flatMap(UUID.init(uuidString:)), let status = runStatus(id), status != "running" { response.runs[i].status = status }
                }
                next.protocol = 1
                guard commit(next) else { return .init(status: 503, json: .object(["error": .string("The runner could not save the change. Nothing was applied.")])) }
                if !response.results.isEmpty { materialize() }
                return .init(status: 200, body: try JSONEncoder().encode(response))
            }
            if request.path == ScheduleSync.retirePath {
                guard let body = try? JSONDecoder().decode(RetireBody.self, from: request.body), body.protocol == ScheduleSync.protocolVersion,
                      let id = ScheduleSync.canonicalID(body.runner.id), !body.runner.name.isEmpty else { return .init(status: 400, json: .object(["error": .string("Invalid request.")])) }
                if let retired = doc.retiredTo { return .init(status: 410, json: .object(["error": .string("Schedules already run on \(retired.name).")])) }
                var next = doc
                next.retiredTo = .init(id: id, name: String(body.runner.name.prefix(64)), at: millis(now()))
                guard commit(next) else { return .init(status: 503, json: .object(["error": .string("The runner could not save the change.")])) }
                updateActivity()
                log("Schedules now run on \(next.retiredTo!.name). This Mac stopped running them.", false)
                return .init(status: 200, json: .object(["retired": .bool(true)]))
            }
            return .init(status: 404, json: .object(["error": .string("Route not found")]))
        } catch let error as ScheduleSync.SyncError {
            return .init(status: error.status, json: .object(["error": .string(error.localizedDescription)]))
        } catch {
            return .init(status: 500, json: .object(["error": .string("Internal error")]))
        }
    }

    /// Saves first, adopts second: an acknowledged change is always on disk.
    private func commit(_ next: ScheduleSync.HubDoc) -> Bool {
        let previous = saved.runner
        saved.runner = next
        if save() { return true }
        saved.runner = previous
        return false
    }

    // MARK: State

    private func sharedValues() -> [String: ScheduleSync.Value] {
        var out: [String: ScheduleSync.Value] = [:]
        if saved.role == .runner, let doc = saved.runner { for (k, r) in doc.records { if let v = r.live { out[k] = v } } }
        else if let state = saved.client?.state { for v in state.view() { out["\(v.kind.rawValue):\(v.id)"] = v } }
        return out
    }

    /// Pushes the shared view into the home.
    private func materialize() {
        guard saved.role == .runner && saved.runner?.retiredTo == nil || saved.role == .paired else { return }
        let values = sharedValues().sorted { $0.key < $1.key }.map(\.value)
        let last = Dictionary(schedules().map { ($0.id.uuidString, $0.lastRunMinute) }, uniquingKeysWith: { a, _ in a })
        let order = Dictionary(scenes().enumerated().map { ($1.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let newScenes = values.compactMap { if case .scene(let s) = $0 { s.scene } else { nil } }.sorted { (order[$0.id.uuidString] ?? .max) < (order[$1.id.uuidString] ?? .max) }
        let newSchedules = values.compactMap { if case .schedule(let s) = $0 { s.schedule(lastRunMinute: last[s.id] ?? nil) } else { nil } }.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        if newScenes != scenes() || newSchedules != schedules() { apply(newScenes, newSchedules) }
    }

    @discardableResult private func save() -> Bool {
        guard let folder else { return true }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appending(path: "schedule-sync.json")
            #if os(iOS)
            try JSONEncoder().encode(saved).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try JSONEncoder().encode(saved).write(to: file, options: [.atomic])
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            log("Could not save schedule sync: \(error.localizedDescription)", true)
            return false
        }
    }

    private func requireReady() throws {
        guard enabled else { throw LumaError.message("Demo mode: schedule sync is disabled.") }
    }

    /// While this Mac runs schedules: no App Nap (timers stay on time), and optionally no idle sleep.
    private func updateActivity() {
        endActivity()
        guard Self.canRun, saved.role == .runner, mayExecute || saved.retirePending != nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: saved.keepAwake ? .userInitiated : .userInitiatedAllowingIdleSystemSleep,
                                                          reason: "Running shared Luma schedules")
    }
    private func endActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil }

    private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
