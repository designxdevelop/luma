import Foundation

/// Reads a Bluetooth capture of Govee Home talking to a light and recovers what
/// Luma can't read from the light itself: the DreamView group Govee Home uploaded,
/// with each member's `cmd_ver`. Nothing is sent anywhere.
///
/// Encrypted captures still decode, because both handshakes are protected only by
/// vendor-global keys: V1's session key travels in the device's reply, and V2's
/// IVs, model and MAC travel in frames sealed with the shared handshake key.
///
/// Input: one frame per line, `W <hex>` for a write to `2b11` and `N <hex>` for a
/// notification from `2b10`, in capture order. Hex may contain spaces or colons;
/// blank lines and `#` comments are skipped. PacketLogger and Wireshark can both
/// export ATT values this way.
public enum GoveeBLECapture {
    public struct Member: Equatable, Sendable {
        public enum Identity: Equatable, Sendable {
            /// Display order (the wire carries it reversed).
            case mac([UInt8])
            case name(String)
        }
        public var isRGBIC: Bool
        public var cmdVer: Int
        public var identity: Identity
        /// Wire area values: 1…10, 0 unassigned, 0xFF disabled.
        public var areas: [Int]
        public init(isRGBIC: Bool, cmdVer: Int, identity: Identity, areas: [Int]) {
            self.isRGBIC = isRGBIC; self.cmdVer = cmdVer; self.identity = identity; self.areas = areas
        }
    }

    public struct Report: Equatable, Sendable {
        /// nil when no handshake or plaintext frame was seen.
        public var encryption: Int?
        public var deviceSKU: String?
        public var frames = 0
        public var decoded = 0
        public var undecodable = 0
        /// Every A3 `0x50` upload, oldest first. The last one is the group Govee Home saved.
        public var groupUploads: [[Member]] = []
        public var dreamViewReadings: [GoveeBLE.DreamView.Reading] = []

        /// A summary safe to show or copy: identities are reduced to their kind.
        public var summary: String {
            var lines = ["Encryption: \(encryption.map { $0 == 0 ? "none" : "V\($0)" } ?? "unknown")\(deviceSKU.map { " · \($0)" } ?? "")",
                         "Frames: \(frames), decoded \(decoded), undecodable \(undecodable)"]
            if let group = groupUploads.last {
                lines.append("DreamView group upload: \(group.count) member\(group.count == 1 ? "" : "s")")
                for (i, m) in group.enumerated() {
                    let kind = if case .mac = m.identity { "address" } else { "name" }
                    lines.append("  \(i + 1). cmd_ver \(m.cmdVer) · \(m.isRGBIC ? "RGBIC" : "single colour") · by \(kind) · areas \(m.areas.map(String.init).joined(separator: ","))")
                }
            } else {
                lines.append("No DreamView group upload in this capture. Save the group in Govee Home while capturing.")
            }
            return lines.joined(separator: "\n")
        }
    }

    public static func decode(_ text: String) throws -> Report {
        guard text.utf8.count <= 16 * 1024 * 1024 else { throw LumaError.message("That capture is too large.") }
        var report = Report()
        var v1Key: [UInt8]?, clientIV: [UInt8]?, v2: GoveeBLECrypto.V2Identity?
        var lastDeviceCounter: UInt32 = 0
        var a3: [[UInt8]] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let dir = line.first, dir == "W" || dir == "N" else { continue }
            let hex = line.dropFirst().filter { $0.isASCII && $0.isHexDigit }
            guard hex.count >= 2, let bytes = GoveeBLECrypto.parseHex(String(hex)) else { report.undecodable += 1; continue }
            report.frames += 1
            let write = dir == "W"

            // Handshakes first: they set the keys for everything after them.
            if let iv = write ? GoveeBLECrypto.parseV2Request(bytes) : nil { clientIV = iv; report.encryption = 2; continue }
            if !write, let id = GoveeBLECrypto.parseV2Response(bytes) { v2 = id; report.deviceSKU = id.sku; report.encryption = 2; continue }
            if let hs = GoveeBLECrypto.parseV1Handshake(bytes) {
                if !write && hs.opcode == 1 { v1Key = hs.body }
                report.encryption = 1
                continue
            }

            var plain: [UInt8]?
            if let v2 {
                if write, let clientIV { plain = GoveeBLECrypto.unseal(bytes, iv: clientIV, key: v2.key)?.plain }
                if !write, let opened = GoveeBLECrypto.unseal(bytes, iv: v2.deviceIV, key: v2.key), opened.counter > lastDeviceCounter {
                    lastDeviceCounter = opened.counter; plain = opened.plain
                }
            } else if let v1Key {
                let p = GoveeBLECrypto.v1(bytes, key: v1Key, encrypt: false)
                if GoveeBLE.isValidFrame(p) { plain = p }
            } else if GoveeBLE.isValidFrame(bytes) {
                plain = bytes
                if report.encryption == nil { report.encryption = 0 }
            }
            guard let frame = plain, GoveeBLE.isValidFrame(frame) else { report.undecodable += 1; continue }
            report.decoded += 1

            if write && frame[0] == 0xA3 {
                if frame[1] == 0 { a3 = [] }
                a3.append(frame)
                if frame[1] == 0xFF {
                    if let env = GoveeBLE.reassembleA3(a3), env[2] == 0x50, let group = parseGroup(Array(env[3...])) { report.groupUploads.append(group) }
                    a3 = []
                }
            } else if !write, let reading = GoveeBLE.DreamView.parse(frame) {
                report.dreamViewReadings.append(reading)
            }
        }
        return report
    }

    /// `count, members…, zero padding` (`h6099_dreamview_group.ksy`).
    public static func parseGroup(_ body: [UInt8]) -> [Member]? {
        var i = 0
        func next() -> UInt8? { guard i < body.count else { return nil }; defer { i += 1 }; return body[i] }
        func take(_ n: Int) -> [UInt8]? { guard n >= 0, i + n <= body.count else { return nil }; defer { i += n }; return Array(body[i..<i + n]) }
        guard let count = next(), count > 0 else { return nil }
        var members: [Member] = []
        for _ in 0..<count {
            guard let rgbic = next(), rgbic <= 1, let kind = next(), let ver = next() else { return nil }
            let identity: Member.Identity
            switch kind {
            case 0: guard let mac = take(6) else { return nil }; identity = .mac(mac.reversed())
            case 1: guard let n = next(), let name = take(Int(n)), let text = String(bytes: name, encoding: .utf8) else { return nil }; identity = .name(text)
            default: return nil
            }
            guard let areaCount = next(), let areas = take(Int(areaCount)) else { return nil }
            members.append(Member(isRGBIC: rgbic == 1, cmdVer: Int(ver), identity: identity, areas: areas.map(Int.init)))
        }
        guard body[i...].allSatisfy({ $0 == 0 }) else { return nil }
        return members
    }

    /// The exact record bytes for `members`; used to prove the parser against the
    /// source's vector. Luma has no path that sends a group to a light.
    static func encodeGroup(_ members: [Member]) -> [UInt8] {
        var out: [UInt8] = [UInt8(members.count)]
        for m in members {
            out += [m.isRGBIC ? 1 : 0]
            switch m.identity {
            case .mac(let mac): out += [0, UInt8(m.cmdVer)] + mac.reversed()
            case .name(let name): let b = Array(name.utf8); out += [1, UInt8(m.cmdVer), UInt8(b.count)] + b
            }
            out += [UInt8(m.areas.count)] + m.areas.map { UInt8($0) }
        }
        return out
    }
}
