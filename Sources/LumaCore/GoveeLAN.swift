import Foundation
import Darwin

/// The documented, basic Govee UDP protocol. A successful send is not a device acknowledgment.
@MainActor public final class GoveeLAN {
    private var descriptor: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var onDevice: (@MainActor (LightDevice) -> Void)?
    private var onError: (@MainActor (String) -> Void)?
    private var knownByIP: [String: LightDevice] = [:]

    public init() {}

    deinit { source?.cancel() }

    public func start(onDevice: @escaping @MainActor (LightDevice) -> Void,
                      onError: @escaping @MainActor (String) -> Void) throws {
        if descriptor >= 0 {
            self.onDevice = onDevice; self.onError = onError
            return
        }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw socketError("create socket") }
        do {
            var enabled: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw socketError("configure socket")
            }
            var address = try Self.address(ip: "0.0.0.0", port: 4002)
            let bound = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { throw socketError("listen on UDP port 4002") }
            var membership = ip_mreq()
            membership.imr_multiaddr.s_addr = inet_addr("239.255.255.250")
            membership.imr_interface.s_addr = INADDR_ANY
            guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
                throw socketError("join Govee multicast group")
            }
            var ttl: UInt8 = 1
            guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size)) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw socketError("configure UDP socket") }
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.onDevice = onDevice; self.onError = onError; descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.receive() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    public func discover() throws {
        try send(LANPacket.envelope(command: "scan", data: ["account_topic": .string("reserve")]), ip: "239.255.255.250", port: 4001)
    }

    public func requestStatus(ip: String) throws {
        guard LANPacket.isUnicastIPv4(ip) else { throw LumaError.message("A valid device IPv4 address is required.") }
        try send(LANPacket.envelope(command: "devStatus", data: [:]), ip: ip, port: 4003)
    }

    /// Register a cached device before requesting status so its reply retains identity and metadata.
    public func requestStatus(for device: LightDevice) throws {
        guard descriptor >= 0 else { throw LumaError.message("Start LAN discovery first.") }
        guard let ip = device.ip, LANPacket.isUnicastIPv4(ip) else {
            throw LumaError.message("This light has no valid LAN address.")
        }
        knownByIP[ip] = device
        try requestStatus(ip: ip)
    }

    public func control(device: LightDevice, command: CapabilityCommand) throws {
        guard let ip = device.ip, LANPacket.isUnicastIPv4(ip) else { throw LumaError.message("This light has no discovered LAN address.") }
        let packet = try LANPacket.control(command)
        // Preserve cloud identity/name when a status packet subsequently arrives.
        knownByIP[ip] = device
        try send(packet, ip: ip, port: 4003)
    }

    public func stop() {
        source?.cancel()
        source = nil; descriptor = -1
        onDevice = nil; onError = nil
        knownByIP.removeAll()
    }

    private func send(_ data: Data, ip: String, port: UInt16) throws {
        guard descriptor >= 0 else { throw LumaError.message("Start LAN discovery first.") }
        var address = try Self.address(ip: ip, port: port)
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard sent == data.count else { throw socketError("send Govee UDP packet") }
    }

    private func receive() {
        guard descriptor >= 0 else { return }
        // Bound parsing and work per queue event; oversized datagrams are discarded.
        for _ in 0..<64 {
            var bytes = [UInt8](repeating: 0, count: 8193)
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { buffer in
                withUnsafeMutablePointer(to: &sender) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(descriptor, buffer.baseAddress, buffer.count, 0, $0, &length) }
                }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { onError?(socketError("receive Govee UDP packet").localizedDescription) }
                return
            }
            guard count > 0, count <= 8192, sender.sin_family == AF_INET else { continue }
            var address = sender.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { continue }
            let ip = String(decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let packet = try? LANPacket.parse(Data(bytes.prefix(count)), sourceIP: ip) else { continue }
            switch packet {
            case .discovery(let discovered):
                var light = knownByIP[ip].flatMap { $0.id.caseInsensitiveCompare(discovered.id) == .orderedSame ? $0 : nil } ?? discovered
                light.ip = ip; light.online = true; light.lastSeen = Date()
                knownByIP[ip] = light
                onDevice?(light)
                // Discovery alone carries no actual state. Request it separately.
                do { try requestStatus(ip: ip) } catch { onError?(error.localizedDescription) }
            case .status(let status):
                guard var light = knownByIP[ip] else { continue }
                light.power = status.power; light.brightness = status.brightness
                light.rgb = status.rgb; light.colorTemperature = status.kelvin
                light.online = true; light.lastSeen = Date()
                knownByIP[ip] = light
                onDevice?(light)
            }
        }
    }

    private static func address(ip: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { throw LumaError.message("Invalid IPv4 address.") }
        return address
    }

    private func socketError(_ operation: String) -> LumaError {
        .message("Could not \(operation): \(String(cString: strerror(errno))).")
    }
}

/// Pure wire helpers are independently testable without sending commands to real lights.
enum LANPacket {
    struct Status: Equatable { let power: Bool; let brightness: Int; let rgb: Int; let kelvin: Int }
    enum Received { case discovery(LightDevice), status(Status) }

    static func envelope(command: String, data: [String: JSONValue]) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(["msg": .object(["cmd": .string(command), "data": .object(data)])]))
    }

    static func isUnicastIPv4(_ ip: String) -> Bool {
        let components = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components.allSatisfy({ UInt8($0) != nil }),
              let first = UInt8(components[0]), first > 0, first < 224, first != 127 else { return false }
        var address = in_addr()
        return inet_pton(AF_INET, ip, &address) == 1
    }

    static func control(_ command: CapabilityCommand) throws -> Data {
        guard let number = command.value.number, number.isFinite, number.rounded() == number,
              number >= 0, number <= 0xFFFFFF else { throw LumaError.message("LAN commands require a valid integer value.") }
        let value = Int(number)
        switch (command.type, command.instance) {
        case ("devices.capabilities.on_off", "powerSwitch") where (0...1).contains(value):
            return try envelope(command: "turn", data: ["value": .number(number)])
        case ("devices.capabilities.range", "brightness") where (1...100).contains(value):
            return try envelope(command: "brightness", data: ["value": .number(number)])
        case ("devices.capabilities.color_setting", "colorRgb"):
            return try envelope(command: "colorwc", data: ["color": .object([
                "r": .number(Double((value >> 16) & 255)), "g": .number(Double((value >> 8) & 255)), "b": .number(Double(value & 255))
            ]), "colorTemInKelvin": .number(0)])
        case ("devices.capabilities.color_setting", "colorTemperatureK") where (2000...9000).contains(value):
            return try envelope(command: "colorwc", data: ["color": .object(["r": .number(0), "g": .number(0), "b": .number(0)]), "colorTemInKelvin": .number(number)])
        default: throw LumaError.message("This command or value is not supported by Govee's LAN API. Use cloud control for scenes and advanced capabilities.")
        }
    }

    static func parse(_ data: Data, sourceIP: String) throws -> Received {
        guard data.count <= 8192, isUnicastIPv4(sourceIP) else { throw LumaError.message("Invalid LAN datagram.") }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let message = root["msg"], let command = message["cmd"]?.string, let body = message["data"] else {
            throw LumaError.message("Invalid LAN envelope.")
        }
        switch command {
        case "scan":
            guard let ip = body["ip"]?.string, ip == sourceIP,
                  let id = body["device"]?.string, !id.isEmpty, id.count <= 128,
                  let sku = body["sku"]?.string, !sku.isEmpty, sku.count <= 32 else { throw LumaError.message("Invalid Govee discovery response.") }
            return .discovery(LightDevice(id: id, sku: sku, name: "Govee \(sku)", ip: ip))
        case "devStatus":
            guard let power = integer(body["onOff"], range: 0...1),
                  let brightness = integer(body["brightness"], range: 0...100),
                  let red = integer(body["color"]?["r"], range: 0...255),
                  let green = integer(body["color"]?["g"], range: 0...255),
                  let blue = integer(body["color"]?["b"], range: 0...255),
                  let kelvin = integer(body["colorTemInKelvin"], range: 0...9000), kelvin == 0 || kelvin >= 2000 else {
                throw LumaError.message("Invalid Govee status response.")
            }
            return .status(Status(power: power == 1, brightness: brightness, rgb: red << 16 | green << 8 | blue, kelvin: kelvin))
        default: throw LumaError.message("Unsupported LAN response.")
        }
    }

    private static func integer(_ value: JSONValue?, range: ClosedRange<Int>) -> Int? {
        guard let number = value?.number, number.isFinite, number.rounded() == number,
              number >= Double(range.lowerBound), number <= Double(range.upperBound) else { return nil }
        return Int(number)
    }
}
