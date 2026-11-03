import Foundation

/// The doorbell alert's settings. Saved in their own file (`doorbell-alert.json`), not in the home.
public struct DoorbellAlertConfig: Codable, Sendable, Equatable {
    public var enabled = false
    /// Room names, resolved to lights each time the bell rings.
    public var rooms: [String] = []
    public var deviceIDs: [String] = []
    public var rgb = 0x2F7BFF
    public var durationSeconds = 15
    /// One full bright-dim cycle. The range keeps the flash rate at or below 0.5 Hz.
    public var pulseSeconds = 2.0
    public var brightnessCap = 100
    /// Minutes after local midnight; the window may cross midnight. Nil: no quiet hours.
    public var quietStart: Int?
    public var quietEnd: Int?
    /// Brightness cap during quiet hours. 0 leaves the lights alone.
    public var quietBrightnessCap = 20
    public var cooldownSeconds = 20
    /// HTTPS address of your own Alexa relay (docs/DOORBELL-ALERT.md). Its token is kept in the Keychain.
    public var relayURL: String?

    public static let durationRange = 5...60
    public static let pulseRange = 2.0...6.0
    public static let cooldownRange = 0...300
    public static let maxLights = 20

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        rooms = try c.decodeIfPresent([String].self, forKey: .rooms) ?? d.rooms
        deviceIDs = try c.decodeIfPresent([String].self, forKey: .deviceIDs) ?? d.deviceIDs
        rgb = try c.decodeIfPresent(Int.self, forKey: .rgb) ?? d.rgb
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? d.durationSeconds
        pulseSeconds = try c.decodeIfPresent(Double.self, forKey: .pulseSeconds) ?? d.pulseSeconds
        brightnessCap = try c.decodeIfPresent(Int.self, forKey: .brightnessCap) ?? d.brightnessCap
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart)
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd)
        quietBrightnessCap = try c.decodeIfPresent(Int.self, forKey: .quietBrightnessCap) ?? d.quietBrightnessCap
        cooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? d.cooldownSeconds
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL)
    }

    public func validate() throws {
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw LumaError.message(message) } }
        try check((0...0xFFFFFF).contains(rgb), "Choose a valid alert color.")
        try check(Self.durationRange.contains(durationSeconds), "Alert length must be 5–60 seconds.")
        try check(Self.pulseRange.contains(pulseSeconds), "Pulse must be 2–6 seconds per cycle.")
        try check((10...100).contains(brightnessCap), "Brightness cap must be 10–100%.")
        try check((0...100).contains(quietBrightnessCap), "Quiet-hours brightness must be 0–100%.")
        try check(Self.cooldownRange.contains(cooldownSeconds), "Cooldown must be 0–300 seconds.")
        try check((quietStart == nil) == (quietEnd == nil), "Set both quiet-hours times, or neither.")
        for minute in [quietStart, quietEnd].compactMap({ $0 }) { try check((0..<1440).contains(minute), "Quiet hours must be times of day.") }
        try check(rooms.count + deviceIDs.count <= 50, "Too many alert targets.")
        if let relayURL {
            let url = URL(string: relayURL)
            try check(url?.scheme == "https" && url?.host?.isEmpty == false && url?.query == nil && url?.user == nil, "The relay address must be an https:// URL without a query or password.")
        }
    }
}

/// A light's confirmed state from just before an alert: what the restore writes back.
public struct AlertSnapshot: Sendable, Equatable {
    public var power: Bool
    public var brightness: Int
    public var rgb: Int?
    public var kelvin: Int?

    /// Color or white first, then brightness, then power, so an off lamp doesn't keep the alert color hidden.
    public var restoreCommands: [CapabilityCommand] {
        var commands: [CapabilityCommand] = []
        if let kelvin { commands.append(.kelvin(kelvin)) } else if let rgb { commands.append(.rgb(rgb)) }
        commands.append(.brightness(brightness))
        commands.append(.power(power))
        return commands
    }

    /// True when `device` reports this state. Off lights are compared by power only:
    /// many models don't report color while off.
    public func matches(_ device: LightDevice) -> Bool {
        guard device.power == power else { return false }
        guard power else { return true }
        if device.brightness != brightness { return false }
        if let kelvin { return device.colorTemperature == kelvin }
        return device.rgb == rgb
    }
}

public enum DoorbellAlert {
    /// Lights in the chosen rooms (looked up now) plus individually chosen lights.
    /// Never appliances or sensors; only lights with power, brightness and color.
    public static func targets(_ config: DoorbellAlertConfig, devices: [LightDevice]) -> [LightDevice] {
        let rooms = Set(config.rooms), ids = Set(config.deviceIDs)
        let chosen = devices.filter { (rooms.contains($0.room) || ids.contains($0.id))
            && DeviceReadings.isLight(type: $0.deviceType)
            && ["powerSwitch", "brightness", "colorRgb"].allSatisfy($0.supports) }
        return Array(chosen.prefix(DoorbellAlertConfig.maxLights))
    }

    /// The state to restore, or why the light is left out. Nothing is guessed:
    /// power, brightness, and color or white must all be known.
    public static func snapshot(of device: LightDevice) throws -> AlertSnapshot {
        guard device.online != false else { throw LumaError.message("offline") }
        guard let power = device.power else { throw LumaError.message("power unknown") }
        guard let brightness = device.brightness, brightness > 0 else { throw LumaError.message("brightness unknown") }
        if let kelvin = device.colorTemperature, kelvin > 0 { return .init(power: power, brightness: brightness, kelvin: kelvin) }
        guard let rgb = device.rgb else { throw LumaError.message("color unknown") }
        return .init(power: power, brightness: brightness, rgb: rgb)
    }

    public static func inQuietHours(_ config: DoorbellAlertConfig, at date: Date, calendar: Calendar = .current) -> Bool {
        guard let start = config.quietStart, let end = config.quietEnd, start != end else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }
}

/// Runs one alert at a time: snapshot, a slow bounded pulse, then restore.
/// Writes go through `IO`, so tests drive it with a fake clock and fake transport.
@MainActor public final class DoorbellAlertEngine {
    public enum Route: Sendable { case lan, cloud }
    public struct Candidate: Sendable {
        public var id: String, name: String, route: Route
        public var snapshot: AlertSnapshot?
        public var skip: String?
        public init(id: String, name: String, route: Route, snapshot: AlertSnapshot?, skip: String? = nil) {
            self.id = id; self.name = name; self.route = route; self.snapshot = snapshot; self.skip = skip
        }
    }
    public struct IO {
        public var devices: @MainActor () -> [LightDevice]
        /// Fresh-reads each target and returns its snapshot or skip reason.
        public var prepare: @MainActor ([LightDevice]) async -> [Candidate]
        /// One direct write: no queue, no readback, never saved as reported state.
        public var pulse: @MainActor (String, CapabilityCommand) async throws -> Void
        /// Writes the snapshot back, reads the light once, and returns whether it confirmed.
        public var restore: @MainActor (String, AlertSnapshot) async throws -> Bool
        public var log: @MainActor (String, Bool) -> Void
        public init(devices: @escaping @MainActor () -> [LightDevice], prepare: @escaping @MainActor ([LightDevice]) async -> [Candidate],
                    pulse: @escaping @MainActor (String, CapabilityCommand) async throws -> Void,
                    restore: @escaping @MainActor (String, AlertSnapshot) async throws -> Bool,
                    log: @escaping @MainActor (String, Bool) -> Void) {
            self.devices = devices; self.prepare = prepare; self.pulse = pulse; self.restore = restore; self.log = log
        }
    }
    public enum Outcome: String, Sendable { case started, coalesced, cooldown, duplicate, disabled, quiet }
    public enum Phase: String, Sendable { case idle, starting, flashing, restoring }

    private struct Light {
        let id: String, name: String, route: Route, snapshot: AlertSnapshot
        var touched = false, takenOver = false, restored = false, failed = false
        var active: Bool { !takenOver && !failed }
    }

    // ponytail: write budgets are fixed. Govee documents 10,000 cloud requests a day;
    // ~10 per device per minute is community-reported, so cloud lights hold instead of pulsing.
    static let lanGap = 0.02, cloudGap = 0.35, cloudReuse = 60.0

    public var config: DoorbellAlertConfig
    public private(set) var phase = Phase.idle
    public private(set) var status = "Ready"
    public var now: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    public var date: @MainActor () -> Date = { Date() }
    public var sleep: @MainActor (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    private let io: IO
    private var lights: [Light] = []
    private var takenOver: Set<String> = []
    private var seen: [String: Double] = [:]
    private var cloudUsed: [String: Double] = [:]
    private var cooldownUntil = -Double.infinity
    private var stopRequested = false
    private var runner: Task<Void, Never>?
    private var flashing: Task<Void, Never>?

    public init(config: DoorbellAlertConfig = .init(), io: IO) { self.config = config; self.io = io }

    /// Repeated rings coalesce into the running alert; replays of the same event are ignored.
    @discardableResult public func trigger(eventID: String) -> Outcome {
        guard config.enabled else { return .disabled }
        let t = now()
        seen = seen.filter { t - $0.value < 600 }
        guard seen[eventID] == nil else { return .duplicate }
        if seen.count >= 256, let oldest = seen.min(by: { $0.value < $1.value }) { seen.removeValue(forKey: oldest.key) }
        seen[eventID] = t
        guard phase == .idle else { return .coalesced }
        guard t >= cooldownUntil else { return .cooldown }
        let quiet = DoorbellAlert.inQuietHours(config, at: date())
        let cap = quiet ? min(config.quietBrightnessCap, config.brightnessCap) : config.brightnessCap
        guard cap > 0 else { status = "Rang during quiet hours; lights left alone."; return .quiet }
        phase = .starting; stopRequested = false; takenOver = []; lights = []
        status = "Ringing…"
        runner = Task { await self.run(cap: cap) }
        return .started
    }

    /// Ends the pulse early and restores.
    public func stop() {
        guard phase != .idle else { return }
        stopRequested = true
        flashing?.cancel()
    }

    /// Someone (or a scene, schedule or webhook) changed this light: it is theirs now and is not restored.
    public func yield(_ id: String) {
        guard phase != .idle else { return }
        takenOver.insert(id)
        if let i = lights.firstIndex(where: { $0.id == id }) { lights[i].takenOver = true }
    }

    public func isAlerting(_ id: String) -> Bool { phase != .idle && lights.contains { $0.id == id && $0.active } }

    /// For app shutdown: the restores still owed, handed to the caller to send synchronously. Ends the alert.
    public func takePendingRestores() -> [(id: String, route: Route, snapshot: AlertSnapshot)] {
        let owed = lights.filter { $0.touched && !$0.takenOver && !$0.restored }.map { ($0.id, $0.route, $0.snapshot) }
        flashing?.cancel(); runner?.cancel()
        lights = []; phase = .idle
        return owed
    }

    /// Waits for the current alert to finish. For tests and shutdown.
    public func settle() async { await runner?.value }

    private func run(cap: Int) async {
        let t0 = now()
        let candidates = await io.prepare(DoorbellAlert.targets(config, devices: io.devices()))
        var skipped: [String] = []
        for c in candidates {
            guard let snapshot = c.snapshot else { skipped.append("\(c.name) (\(c.skip ?? "skipped"))"); continue }
            if c.route == .cloud, let used = cloudUsed[c.id], t0 - used < Self.cloudReuse { skipped.append("\(c.name) (cloud limit: alerted under a minute ago)"); continue }
            lights.append(Light(id: c.id, name: c.name, route: c.route, snapshot: snapshot, takenOver: takenOver.contains(c.id)))
        }
        if !skipped.isEmpty { io.log("Doorbell alert skipped \(skipped.joined(separator: ", ")).", false) }
        guard !lights.isEmpty, !stopRequested, !Task.isCancelled else {
            finish(lights.isEmpty ? "Rang, but no light could be alerted safely." : "Stopped before flashing.")
            return
        }
        for light in lights where light.route == .cloud { cloudUsed[light.id] = t0 }
        phase = .flashing
        let pulse = Task { await self.flash(cap: cap) }
        flashing = pulse
        await pulse.value
        flashing = nil
        guard !Task.isCancelled else { return } // shutdown took the restores
        phase = .restoring
        var confirmed = 0, unconfirmed: [String] = [], failed: [String] = []
        for i in lights.indices where lights[i].touched {
            guard !lights[i].takenOver else { continue }
            do {
                if try await io.restore(lights[i].id, lights[i].snapshot) { confirmed += 1 } else { unconfirmed.append(lights[i].name) }
            } catch { failed.append("\(lights[i].name): \(error.localizedDescription)") }
            lights[i].restored = true
            try? await sleep(lights[i].route == .cloud ? 1 : Self.lanGap)
        }
        let taken = lights.filter(\.takenOver).count
        let flashed = lights.filter(\.touched).count
        var summary = "Flashed \(flashed) light\(flashed == 1 ? "" : "s"); restored \(confirmed)"
        if !unconfirmed.isEmpty { summary += "; sent but not confirmed: \(unconfirmed.joined(separator: ", "))" }
        if taken > 0 { summary += "; \(taken) left as changed during the alert" }
        if !failed.isEmpty { summary += "; couldn't restore \(failed.joined(separator: "; "))" }
        finish(summary + ".", error: !failed.isEmpty)
    }

    private func finish(_ summary: String, error: Bool = false) {
        status = summary
        cooldownUntil = now() + Double(config.cooldownSeconds)
        lights = []; phase = .idle; runner = nil
        io.log("Doorbell alert: \(summary)", error)
    }

    private func flash(cap: Int) async {
        let high = cap, low = max(1, Int((Double(cap) * 0.2).rounded()))
        let end = now() + Double(config.durationSeconds)
        for i in lights.indices {
            var first: [CapabilityCommand] = lights[i].snapshot.power ? [] : [.power(true)]
            first += [.rgb(config.rgb), .brightness(high)]
            for command in first { guard await write(i, command) else { break } }
            if Task.isCancelled { return }
        }
        var bright = true
        while now() < end, lights.contains(where: \.active) {
            do { try await sleep(config.pulseSeconds / 2) } catch { return }
            guard now() < end else { return }
            bright.toggle()
            // Cloud lights hold the alert color: pulsing them would exceed Govee's per-device limits.
            for i in lights.indices where lights[i].route == .lan && lights[i].active {
                _ = await write(i, .brightness(bright ? high : low))
                if Task.isCancelled { return }
            }
        }
    }

    private func write(_ i: Int, _ command: CapabilityCommand) async -> Bool {
        guard lights[i].active, !Task.isCancelled else { return false }
        lights[i].touched = true
        do { try await io.pulse(lights[i].id, command) }
        catch {
            lights[i].failed = true
            io.log("Doorbell alert: \(lights[i].name) stopped flashing: \(error.localizedDescription)", true)
            return false
        }
        try? await sleep(lights[i].route == .cloud ? Self.cloudGap : Self.lanGap)
        return true
    }
}
