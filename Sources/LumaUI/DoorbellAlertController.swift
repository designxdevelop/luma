import Foundation
import Observation
import LumaCore

/// The app side of the doorbell alert: its settings file, the engine's light I/O,
/// the outbound Alexa relay poll, and the `/v1/alerts/doorbell` webhook routes.
@Observable final class DoorbellAlertController {
    static let tokenKey = "alexa-relay-token"
    private(set) var config = DoorbellAlertConfig()
    private(set) var phase = DoorbellAlertEngine.Phase.idle
    private(set) var status = "Ready"
    private(set) var relayState = "Off"
    private(set) var relayTokenSaved = false
    var pairing: AlexaRelayClient.Pairing?
    @ObservationIgnored private weak var store: HomeStore?
    @ObservationIgnored private(set) var engine: DoorbellAlertEngine!
    @ObservationIgnored private var relayTask: Task<Void, Never>?
    @ObservationIgnored var relaySession: URLSession = .shared

    private var file: URL { (store?.storageFolder ?? HomeStorage(demo: false).folder).appending(path: "doorbell-alert.json") }
    /// The settings file exists but couldn't be read: it is preserved, and `update` refuses to overwrite it.
    @ObservationIgnored var configUnreadable = false
    static let unreadableMessage = "Doorbell alert settings could not be read and were left in place. Fix or remove doorbell-alert.json to change them."

    /// Called at launch and whenever the store enters or leaves the demo.
    func attach(_ store: HomeStore) {
        self.store = store
        if engine == nil { engine = DoorbellAlertEngine(io: io()) } else { engine.stop() }
        var loaded = DoorbellAlertConfig()
        configUnreadable = false
        if store.demo { loaded.enabled = true; loaded.rooms = ["Living room"] }
        else {
            do { if let saved = try HomeStore.readIfPresent(DoorbellAlertConfig.self, file) { try saved.validate(); loaded = saved } }
            catch { configUnreadable = true; status = Self.unreadableMessage; store.log(Self.unreadableMessage, error: true) }
        }
        config = loaded; engine.config = loaded
        relayTokenSaved = !store.demo && ((try? SecretStore.read(Self.tokenKey)) ?? nil) != nil
        startRelay()
    }

    func update(_ edit: (inout DoorbellAlertConfig) -> Void) throws {
        // Defaults stand in for a file that failed to decode; saving them would overwrite the user's settings.
        guard !configUnreadable else { throw LumaError.message(Self.unreadableMessage) }
        var next = config; edit(&next)
        try next.validate()
        let relayChanged = next.relayURL != config.relayURL || next.enabled != config.enabled
        config = next; engine.config = next
        if let store, !store.demo {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder.pretty.encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if relayChanged { startRelay() }
    }

    @discardableResult func trigger(eventID: String) -> DoorbellAlertEngine.Outcome {
        let outcome = engine.trigger(eventID: eventID)
        sync()
        if outcome != .started { status = Self.describe(outcome) }
        return outcome
    }
    func test() { trigger(eventID: "test-\(UUID().uuidString)") }
    func stop() { engine.stop(); sync() }
    func yield(_ id: String) { engine?.yield(id) }
    func isAlerting(_ id: String) -> Bool { engine?.isAlerting(id) ?? false }
    func settle() async { await engine.settle(); sync() }
    private func sync() { phase = engine.phase; status = engine.status }

    static func describe(_ outcome: DoorbellAlertEngine.Outcome) -> String {
        switch outcome {
        case .started: "Ringing…"
        case .coalesced: "Rang again; the running alert continues."
        case .cooldown: "Rang again during the cooldown; lights left alone."
        case .duplicate: "Ignored a repeated delivery of the same ring."
        case .disabled: "Rang, but the doorbell alert is off."
        case .quiet: "Rang during quiet hours; lights left alone."
        }
    }

    /// Best effort at app exit: LAN restores are sent synchronously; cloud restores may not finish.
    func shutdown() {
        relayTask?.cancel(); relayTask = nil
        guard let engine, let store else { return }
        for owed in engine.takePendingRestores() {
            guard let device = store.home.devices.first(where: { $0.id == owed.id }) else { continue }
            if device.isDemo { owed.snapshot.restoreCommands.forEach { applyDemo($0, to: owed.id) }; continue }
            if device.ip != nil, (try? store.startLAN()) != nil {
                for command in owed.snapshot.restoreCommands { try? store.lan.control(device: device, command: command) }
            } else if let cloud = store.cloud {
                Task { for command in owed.snapshot.restoreCommands { try? await cloud.control(device: device, command: command) } }
            }
        }
    }

    // MARK: Light I/O

    private func io() -> DoorbellAlertEngine.IO {
        .init(devices: { [weak self] in self?.store?.lights ?? [] },
              prepare: { [weak self] targets in await self?.prepare(targets) ?? [] },
              pulse: { [weak self] id, command in try await self?.write(command, to: id) },
              restore: { [weak self] id, snapshot in try await self?.restore(id, snapshot) ?? false },
              log: { [weak self] message, error in self?.store?.log(message, error: error); self?.sync() })
    }

    private func route(_ device: LightDevice) -> DoorbellAlertEngine.Route { device.isDemo || device.ip != nil ? .lan : .cloud }

    /// Busy lights are skipped, then every target is read fresh: a stale saved state is never restored.
    private func prepare(_ targets: [LightDevice]) async -> [DoorbellAlertEngine.Candidate] {
        guard let store else { return [] }
        var skip: [String: String] = [:]
        for d in targets {
            let sync = store.screenSync
            if sync.isActive && sync.regions[d.id] != nil && sync.excluded[d.id] == nil { skip[d.id] = "in Screen or Audio Sync" }
            else if d.dreamView == true { skip[d.id] = "DreamView is on" }
            else if store.hasOrdinaryControl(for: d.id) { skip[d.id] = "being changed" }
        }
        let started = Date()
        let lan = targets.filter { skip[$0.id] == nil && !$0.isDemo && $0.ip != nil }
        for d in lan {
            do { try store.startLAN(); try store.lan.requestStatus(for: d) } catch { skip[d.id] = "no LAN status" }
        }
        for d in targets where skip[d.id] == nil && !d.isDemo && d.ip == nil {
            guard let cloud = store.cloud else { skip[d.id] = "no cloud connection"; continue }
            let revision = store.deviceRevisions[d.id, default: 0]
            do { store.merge(try await Self.within(3) { try await cloud.state(for: d) }, stateRevision: revision) }
            catch { skip[d.id] = "couldn't read its state" }
        }
        let deadline = started.addingTimeInterval(1.5)
        func fresh(_ id: String) -> Bool { (store.home.devices.first { $0.id == id }?.lastSeen ?? .distantPast) >= started }
        while Date() < deadline, lan.contains(where: { skip[$0.id] == nil && !fresh($0.id) }) { try? await Task.sleep(for: .milliseconds(50)) }
        for d in lan where skip[d.id] == nil && !fresh(d.id) { skip[d.id] = "no fresh status from the light" }
        if !lan.isEmpty || targets.contains(where: { !$0.isDemo && $0.ip == nil }) { store.persist() }
        return targets.map { target in
            let current = store.home.devices.first { $0.id == target.id } ?? target
            let name = current.customName ?? current.name
            if let reason = skip[target.id] { return .init(id: target.id, name: name, route: route(current), snapshot: nil, skip: reason) }
            do { return .init(id: target.id, name: name, route: route(current), snapshot: try DoorbellAlert.snapshot(of: current)) }
            catch { return .init(id: target.id, name: name, route: route(current), snapshot: nil, skip: error.localizedDescription) }
        }
    }

    /// A direct write like Screen Sync's: no queue, no pending overlay, no status request.
    private func write(_ command: CapabilityCommand, to id: String) async throws {
        guard let store, let device = store.home.devices.first(where: { $0.id == id }) else { throw LumaError.message("Light not found.") }
        try CommandValidation.validate(command, for: device)
        // Reads that started before this write can't bring back older values.
        store.deviceRevisions[id, default: 0] += 1
        if device.isDemo { applyDemo(command, to: id) }
        else if device.ip != nil, Self.lanEligible(command) { try store.startLAN(); try store.lan.control(device: device, command: command) }
        else if let cloud = store.cloud { try await cloud.control(device: device, command: command) }
        else { throw LumaError.message("No LAN or cloud route.") }
    }

    /// Writes the snapshot back, then reads the light once to confirm it.
    private func restore(_ id: String, _ snapshot: AlertSnapshot) async throws -> Bool {
        for command in snapshot.restoreCommands { try await write(command, to: id) }
        guard let store, let device = store.home.devices.first(where: { $0.id == id }) else { return false }
        if device.isDemo { return snapshot.matches(device) }
        if device.ip != nil {
            let started = Date()
            try store.lan.requestStatus(for: device)
            for _ in 0..<40 {
                if let current = store.home.devices.first(where: { $0.id == id }), (current.lastSeen ?? .distantPast) >= started { return snapshot.matches(current) }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        guard let cloud = store.cloud else { return false }
        try await Task.sleep(for: .seconds(1))
        let revision = store.deviceRevisions[id, default: 0]
        store.merge(try await Self.within(3) { try await cloud.state(for: device) }, stateRevision: revision)
        store.persist()
        return store.home.devices.first { $0.id == id }.map(snapshot.matches) ?? false
    }

    /// The same rule as HomeStore.transmit: basic controls, and white only in the LAN range.
    static func lanEligible(_ command: CapabilityCommand) -> Bool {
        ["powerSwitch", "brightness", "colorRgb"].contains(command.instance)
            || command.instance == "colorTemperatureK" && (2000...9000).contains(command.value.number ?? 0)
    }

    private func applyDemo(_ command: CapabilityCommand, to id: String) {
        guard let store, let i = store.home.devices.firstIndex(where: { $0.id == id }), let n = command.value.number.map(Int.init) else { return }
        switch command.instance {
        case "powerSwitch": store.home.devices[i].power = n == 1
        case "brightness": store.home.devices[i].brightness = n
        case "colorRgb": store.home.devices[i].rgb = n; store.home.devices[i].colorTemperature = 0
        case "colorTemperatureK": store.home.devices[i].colorTemperature = n
        default: break
        }
    }

    private static func within<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw LumaError.message("timed out") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Alexa relay

    func saveRelay(url: String, token: String) throws {
        guard let store, !store.demo else { throw LumaError.message("Leave the demo to connect your Alexa relay.") }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try AlexaRelayClient(base: trimmed, token: secret)
        try SecretStore.save(secret, account: Self.tokenKey)
        relayTokenSaved = true
        try update { $0.relayURL = trimmed }
        startRelay()
    }

    func forgetRelay() throws {
        try SecretStore.delete(Self.tokenKey)
        relayTokenSaved = false; pairing = nil
        try update { $0.relayURL = nil }
    }

    private func client() throws -> AlexaRelayClient {
        guard let url = config.relayURL, let token = try SecretStore.read(Self.tokenKey) else { throw LumaError.message("Connect your Alexa relay first.") }
        return try AlexaRelayClient(base: url, token: token, session: relaySession)
    }

    func requestPairingCode() async {
        do { pairing = try await client().pairingCode() } catch { store?.log("Alexa pairing: \(error.localizedDescription)", error: true) }
    }

    func unlinkAlexa() async {
        do { try await client().unlink(); pairing = nil; store?.log("Alexa account links on your relay were revoked.") }
        catch { store?.log("Alexa unlink: \(error.localizedDescription)", error: true) }
    }

    /// Outbound long poll; runs while the alert is on and a relay is connected.
    func startRelay() {
        relayTask?.cancel(); relayTask = nil
        guard let store, !store.demo, config.enabled, config.relayURL != nil, relayTokenSaved, let client = try? client() else {
            relayState = config.relayURL == nil ? "Off" : (config.enabled ? "Needs the relay token" : "Paused: the alert is off"); return
        }
        relayState = "Connecting…"
        relayTask = Task { [weak self] in
            var backoff = 2.0, connected = false
            while !Task.isCancelled {
                do {
                    let events = try await client.next(wait: connected)
                    connected = true
                    guard !Task.isCancelled, let self else { return }
                    self.relayState = "Connected · waiting for Alexa"
                    backoff = 2
                    for event in events { self.receive(event) }
                } catch {
                    guard !Task.isCancelled else { return }
                    connected = false
                    self?.relayState = "Reconnecting: \(error.localizedDescription)"
                    try? await Task.sleep(for: .seconds(backoff)); backoff = min(backoff * 2, 60)
                }
            }
        }
    }

    func receive(_ event: AlexaRelayClient.Event) {
        if event.type == "deactivate" { store?.log("Alexa stopped the doorbell alert."); stop(); return }
        let outcome = trigger(eventID: "alexa:\(event.id)")
        store?.log("Alexa doorbell scene: \(outcome.rawValue).")
    }

    // MARK: Webhook routes (bearer-authenticated by the server before this runs)

    /// GET status, POST a ring with `eventId` and `timestamp` (Unix seconds, ±120 s), or POST `/stop`.
    func handle(_ request: WebhookRequest, path: [String], now: Date = Date()) -> WebhookResponse? {
        guard path.count >= 3, path[0...2] == ["v1", "alerts", "doorbell"] else { return nil }
        func reply(_ status: Int, _ fields: [String: JSONValue]) -> WebhookResponse { .init(status: status, json: .object(fields)) }
        if request.method == "GET", path.count == 3 {
            return reply(200, ["enabled": .bool(config.enabled), "phase": .string(phase.rawValue), "status": .string(status)])
        }
        guard request.method == "POST" else { return reply(405, ["error": .string("Use POST")]) }
        if path.count == 4, path[3] == "stop" { stop(); return reply(202, ["accepted": .bool(true)]) }
        guard path.count == 3 else { return nil }
        struct Ring: Decodable { let eventId: String; let timestamp: Double }
        guard let ring = try? JSONDecoder().decode(Ring.self, from: request.body),
              (8...128).contains(ring.eventId.count),
              ring.eventId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.:".unicodeScalars.contains($0) })
        else { return reply(400, ["error": .string("Send {\"eventId\": 8–128 letters, digits or -_.:, \"timestamp\": Unix seconds}")]) }
        guard abs(now.timeIntervalSince1970 - ring.timestamp) <= 120 else { return reply(409, ["error": .string("Stale or future timestamp; check the caller's clock.")]) }
        let outcome = trigger(eventID: "webhook:\(ring.eventId)")
        store?.log("Doorbell webhook: \(outcome.rawValue).")
        return reply(outcome == .disabled ? 409 : 202, ["outcome": .string(outcome.rawValue), "status": .string(status)])
    }
}
