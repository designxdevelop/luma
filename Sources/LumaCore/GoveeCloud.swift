import Foundation

/// Govee's current capability API. Requests are serialized and paced; commands are never retried automatically.
public actor GoveeCloud {
    private let apiKey: String
    private let session: URLSession
    private var tail: Task<Void, Never>?
    private var nextAccount = ContinuousClock.now
    private var nextDevice: [String: ContinuousClock.Instant] = [:]
    private var nextRead: [String: ContinuousClock.Instant] = [:]

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func devices() async throws -> [LightDevice] {
        let root = try await request(path: "user/devices")
        guard let rows = root["data"]?.array else { throw LumaError.message("Govee returned an invalid device list.") }
        return try rows.compactMap { row in
            guard let id = row["device"]?.string, let sku = row["sku"]?.string else {
                throw LumaError.message("Govee returned a device without an ID or model.")
            }
            if let type = row["type"]?.string, type != "devices.types.light" { return nil }
            let capabilities = try row["capabilities"].map(decodeCapabilities) ?? []
            return LightDevice(id: id, sku: sku, name: row["deviceName"]?.string ?? sku, capabilities: capabilities)
        }
    }

    public func state(for device: LightDevice) async throws -> LightDevice {
        let root = try await request(path: "device/state", device: device)
        guard let payload = root["payload"], let capabilities = payload["capabilities"]?.array else {
            throw LumaError.message("Govee returned invalid device state.")
        }
        try validateIdentity(payload, device: device)
        var updated = device
        if let value = capabilities.first(where: { $0["instance"]?.string == "online" })?["state"]?["value"], case .bool(let online) = value {
            updated.online = online
        }
        // Govee explicitly identifies offline state as historical; do not present it as fresh telemetry.
        guard updated.online != false else { return updated }
        for capability in capabilities {
            guard let instance = capability["instance"]?.string, let value = capability["state"]?["value"]?.number,
                  value.isFinite, value.rounded() == value, value >= 0, value <= Double(Int32.max) else { continue }
            switch instance {
            case "powerSwitch" where value <= 1: updated.power = value == 1
            case "brightness" where value <= 100: updated.brightness = Int(value)
            case "colorRgb" where value <= 0xFFFFFF: updated.rgb = Int(value)
            case "colorTemperatureK": updated.colorTemperature = Int(value)
            default: break
            }
        }
        if updated.online == true { updated.lastSeen = Date() }
        return updated
    }

    public func control(device: LightDevice, command: CapabilityCommand) async throws {
        _ = try await request(path: "device/control", device: device, command: command)
    }

    public func scenes(for device: LightDevice, diy: Bool = false) async throws -> [Capability] {
        let root = try await request(path: diy ? "device/diy-scenes" : "device/scenes", device: device)
        guard let payload = root["payload"] else { throw LumaError.message("Govee returned invalid scene data.") }
        try validateIdentity(payload, device: device)
        if let capabilities = payload["capabilities"] { return try decodeCapabilities(capabilities) }
        // The dynamic-scene documentation also shows a single capability/value payload.
        if let type = payload["type"]?.string, let instance = payload["instance"]?.string, let value = payload["value"] {
            return [Capability(type: type, instance: instance, parameters: .object([
                "dataType": .string("ENUM"), "options": .array([.object(["name": .string(instance), "value": value])])
            ]))]
        }
        throw LumaError.message("Govee returned invalid scene capabilities.")
    }

    private func decodeCapabilities(_ value: JSONValue) throws -> [Capability] {
        guard let values = value.array else { throw LumaError.message("Govee returned invalid capabilities.") }
        return try values.map { row in
            guard let type = row["type"]?.string, let instance = row["instance"]?.string else {
                throw LumaError.message("Govee returned an incomplete capability.")
            }
            return Capability(type: type, instance: instance, parameters: row["parameters"])
        }
    }

    private func validateIdentity(_ payload: JSONValue, device: LightDevice) throws {
        if let id = payload["device"]?.string, id != device.id { throw LumaError.message("Govee returned state for a different device.") }
        if let sku = payload["sku"]?.string, sku != device.sku { throw LumaError.message("Govee returned a different device model.") }
    }

    private func request(path: String, device: LightDevice? = nil, command: CapabilityCommand? = nil) async throws -> JSONValue {
        let previous = tail
        let operation = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await execute(path: path, device: device, command: command)
        }
        tail = Task { _ = await operation.result }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func execute(path: String, device: LightDevice?, command: CapabilityCommand?) async throws -> JSONValue {
        guard !apiKey.isEmpty else { throw LumaError.message("Add your Govee API key in Settings first.") }
        let readKey = path + ":" + (device?.id ?? "account")
        var ready = nextAccount
        if let device, let next = nextDevice[device.id] { ready = max(ready, next) }
        if command == nil, let next = nextRead[readKey] { ready = max(ready, next) }
        if ready > .now { try await ContinuousClock().sleep(until: ready) }
        try Task.checkCancellation()
        let now = ContinuousClock.now
        nextAccount = now.advanced(by: .milliseconds(84))
        if let device { nextDevice[device.id] = now.advanced(by: .seconds(1)) }
        if command == nil { nextRead[readKey] = now.advanced(by: .seconds(2)) }
        guard let url = URL(string: "https://openapi.api.govee.com/router/api/v1/" + path) else {
            throw LumaError.message("Invalid Govee endpoint.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let device {
            request.httpMethod = "POST"
            var payload: [String: JSONValue] = ["sku": .string(device.sku), "device": .string(device.id)]
            if let command {
                payload["capability"] = .object(["type": .string(command.type), "instance": .string(command.instance), "value": command.value])
            }
            request.httpBody = try JSONEncoder().encode(JSONValue.object(["requestId": .string(UUID().uuidString), "payload": .object(payload)]))
        } else { request.httpMethod = "GET" }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LumaError.message("Govee did not return an HTTP response.") }
        if response.statusCode == 429 {
            let seconds = min(3600, max(2, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60))
            nextAccount = .now.advanced(by: .seconds(seconds))
        }
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 401, 403: throw LumaError.message("Govee rejected the API key (HTTP \(response.statusCode)). Check your key in Settings.")
            case 429: throw LumaError.message("Govee's rate limit was reached. Requests are paused; try again later.")
            default: throw LumaError.message("Govee request failed (HTTP \(response.statusCode)).")
            }
        }
        guard data.count <= 8 * 1024 * 1024 else { throw LumaError.message("Govee response is too large.") }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard root["code"]?.number == 200 else {
            if root["code"]?.number == 429 { nextAccount = .now.advanced(by: .seconds(60)) }
            let code = root["code"]?.number.map { String($0) } ?? "missing code"
            // Avoid echoing arbitrary remote response text, which may include account details.
            throw LumaError.message("Govee rejected the request (\(code)).")
        }
        return root
    }
}
