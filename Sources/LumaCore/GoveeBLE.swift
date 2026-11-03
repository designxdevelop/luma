import Foundation

/// Govee's Bluetooth LE light protocol, for the models whose wire format is
/// evidenced in public source. Pure bytes: no CoreBluetooth here, so the watch
/// target can keep linking LumaCore.
///
/// Source of every frame, profile rule and test vector: teh-hippo/ha-govee-led-ble
/// @ b845c59 (`transport.py`, `advertisement.py`, `const.py`, the `h6099_*` and
/// `h6097_*` Kaitai schemas, and `tests/test_h6099*.py`). Nothing is guessed: a
/// model or setting the source doesn't establish has no builder here.
public enum GoveeBLE {
    /// GATT characteristics (`transport.py`). Writes go without response.
    public static let writeCharacteristic = "00010203-0405-0607-0809-0A0B0C0D2B11"
    public static let notifyCharacteristic = "00010203-0405-0607-0809-0A0B0C0D2B10"
    /// Optional: a readable marker saying whether, and how, the link is encrypted.
    public static let encryptionCharacteristic = "00010203-0405-0607-0809-0A0B0C0D2B12"

    public static func checksum<S: Sequence<UInt8>>(_ bytes: S) -> UInt8 { bytes.reduce(0, ^) }

    /// 19 content bytes, zero-padded, then their XOR.
    static func frame(_ prefix: [UInt8]) -> [UInt8] {
        precondition(prefix.count <= 19)
        let body = prefix + [UInt8](repeating: 0, count: 19 - prefix.count)
        return body + [checksum(body)]
    }

    public static func isValidFrame(_ frame: [UInt8]) -> Bool { frame.count == 20 && checksum(frame.prefix(19)) == frame[19] }

    // MARK: Advertisement

    public struct Advertisement: Equatable, Sendable {
        public var flags: UInt8
        public var pactType: Int
        public var pactCode: Int
        /// Flag bit 0x40. Its absence is not proof the link is plaintext.
        public var supportsEncryption: Bool { flags & 0x40 != 0 }
        public var pact: Pact { .init(type: pactType, code: pactCode) }

        /// CoreBluetooth manufacturer data: the company ID little-endian, then the
        /// payload. Govee puts flags in the low byte, 0x88 in the high byte, then
        /// 0xEC, a big-endian Pact type and a Pact code.
        public init?(manufacturerData data: [UInt8]) {
            guard data.count >= 6, data[1] == 0x88, data[2] == 0xEC else { return nil }
            flags = data[0]; pactType = Int(data[3]) << 8 | Int(data[4]); pactCode = Int(data[5])
        }
    }

    /// A product revision. Some models change capabilities by Pact.
    public struct Pact: Hashable, Sendable { public var type: Int; public var code: Int }

    private static let namePattern = try! NSRegularExpression(
        pattern: #"(?:(?:ihoment|Govee|Minger|GBK|GVH)_(H[0-9A-Z]{4})(?:_|$)|^GVH?([0-9A-Z]{4})(?:_[0-9A-Z]+|[0-9A-Z]{4}|$)$|^(H[0-9A-Z]{4})_[0-9A-Z]+$)"#,
        options: [.caseInsensitive])

    /// The model in an advertised local name such as `Govee_H6097_1A2B` (`const.py` `_BLE_MODEL_PATTERN`).
    public static func model(fromLocalName name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = namePattern.firstMatch(in: name, range: range) else { return nil }
        for group in 1...3 {
            if let r = Range(match.range(at: group), in: name) {
                let raw = name[r].uppercased()
                return raw.count == 5 ? raw : "H" + raw
            }
        }
        return nil
    }

    // MARK: Commands (H6099 grammar, shared by H6097 and H66A0)

    public static func power(_ on: Bool) -> [UInt8] { frame([0x33, 0x01, on ? 1 : 0]) }

    public static func brightness(_ percent: Int) throws -> [UInt8] {
        guard (0...100).contains(percent) else { throw LumaError.message("Brightness must be 0–100.") }
        return frame([0x33, 0x04, UInt8(percent)])
    }

    /// Static colour on every segment in `mask` (Kelvin 0, preview black, as the source sends it).
    public static func color(red: UInt8, green: UInt8, blue: UInt8, mask: UInt16) -> [UInt8] {
        frame([0x33, 0x05, 0x15, 0x01, red, green, blue, 0, 0, 0, 0, 0, UInt8(mask & 0xFF), UInt8(mask >> 8)])
    }

    public enum VideoSource: UInt8, Sendable, CaseIterable { case movie = 0, game = 1 }

    /// The backlight's own camera mode (Govee Home's Video tab): Movie or Game,
    /// whole screen or part, saturation and sound effects.
    public static func videoMode(_ source: VideoSource, wholeScreen: Bool, saturation: Int, soundEffects: Bool, softness: Int) throws -> [UInt8] {
        guard (1...100).contains(saturation) else { throw LumaError.message("Saturation must be 1–100.") }
        guard (0...100).contains(softness) else { throw LumaError.message("Softness must be 0–100.") }
        return frame([0x33, 0x05, 0x00, source.rawValue, wholeScreen ? 0x09 : 0x08, UInt8(saturation), soundEffects ? 1 : 0, 0x02, UInt8(softness)])
    }

    // MARK: Status

    public enum Query: CaseIterable, Sendable {
        case power, brightness, colorMode, firmware, hardware
        public var frame: [UInt8] {
            switch self {
            case .power: GoveeBLE.frame([0xAA, 0x01])
            case .brightness: GoveeBLE.frame([0xAA, 0x04])
            case .colorMode: GoveeBLE.frame([0xAA, 0x05, 0x01])
            case .firmware: GoveeBLE.frame([0xAA, 0x06])
            case .hardware: GoveeBLE.frame([0xAA, 0x07, 0x03])
            }
        }
    }

    public enum Mode: Equatable, Sendable {
        case video(source: VideoSource?, wholeScreen: Bool?, saturation: Int, soundEffects: Bool, softness: Int)
        /// The reply carries Kelvin only (0 = RGB); colour comes from segment pages, not read here.
        case staticColor(kelvin: Int)
        case scene(id: Int)
        case other(UInt8)
    }

    public enum Status: Equatable, Sendable {
        case power(Bool), brightness(Int), mode(Mode), firmware(String), hardware(String)
        case dreamView(DreamView.Reading)
    }

    /// One notification. Anything unrecognised (command echoes, unmodelled domains) is nil.
    public static func parseStatus(_ f: [UInt8]) -> Status? {
        guard isValidFrame(f), f[0] == 0xAA else { return nil }
        let body = Array(f[2..<19])
        switch f[1] {
        case 0x01: return .power(body[0] != 0)
        case 0x04: return body[0] <= 100 ? .brightness(Int(body[0])) : nil
        case 0x06: return .firmware(ascii(body))
        case 0x07: return body[0] == 0x03 ? .hardware(ascii(Array(body.dropFirst()))) : nil
        case 0x05:
            let d = body
            switch d[0] {
            case 0x00: return .mode(.video(source: VideoSource(rawValue: d[1]), wholeScreen: d[2] == 9 ? true : d[2] == 8 ? false : nil,
                                           saturation: Int(d[3]), soundEffects: d[4] != 0, softness: Int(d[6])))
            case 0x15: return .mode(.staticColor(kelvin: Int(d[2]) << 8 | Int(d[3])))
            case 0x04: return .mode(.scene(id: Int(d[1]) | Int(d[2]) << 8))
            default: return .mode(.other(d[0]))
            }
        case 0x60: return DreamView.parse(f).map(Status.dreamView)
        default: return nil
        }
    }

    private static func ascii(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.filter { (0x20..<0x7F).contains($0) }, as: UTF8.self)
    }

    // MARK: DreamView module 0x60

    /// The controller's DreamView settings (`h6099_dreamview_frame.ksy`). Reads are
    /// individual replies; zero slot bytes are not proof a slot is empty, and none
    /// of this reads group membership. Group upload (A3 `0x50`) and delete (`0x0d`)
    /// have no builder: membership needs evidenced `cmd_ver` (see `GoveeBLECapture`).
    public enum DreamView {
        public enum Setting: UInt8, CaseIterable, Sendable {
            case switchGroup = 0x01, memberBrightness = 0x03, sameBrightness = 0x04, memberConnect = 0x05
            case saturation = 0x09, videoSettings = 0x0A, sound = 0x0B
        }

        public enum Reading: Equatable, Sendable {
            case enabled(Bool)
            case memberBrightness(raw: [UInt8])
            case sameBrightness(Bool)
            case memberConnect(raw: [UInt8])
            case saturation(Int)
            /// Raw values kept: 0 All / 1 Part, 0 Game / 1 Movie; anything else is unknown.
            case videoSettings(applyArea: UInt8, contentMode: UInt8)
            case sound(enabled: Bool, softness: Int)
        }

        public static func query(_ setting: Setting) -> [UInt8] {
            frame([0xAA, 0x60, setting.rawValue] + (setting == .switchGroup ? [1] : []))
        }

        public static func parse(_ f: [UInt8]) -> Reading? {
            guard isValidFrame(f), f[0] == 0xAA, f[1] == 0x60, let setting = Setting(rawValue: f[2]) else { return nil }
            let b = Array(f[3..<19])
            switch setting {
            case .switchGroup: return .enabled(b[0] != 0)
            case .memberBrightness: return .memberBrightness(raw: b)
            case .sameBrightness: return .sameBrightness(b[0] != 0)
            case .memberConnect: return .memberConnect(raw: Array(b.prefix(10)))
            case .saturation: return .saturation(Int(b[0]))
            case .videoSettings: return .videoSettings(applyArea: b[0], contentMode: b[1])
            case .sound: return .sound(enabled: b[0] != 0, softness: Int(b[1]))
            }
        }

        /// Start or stop the group already set up on the controller.
        public static func setEnabled(_ on: Bool) -> [UInt8] { frame([0x33, 0x60, 0x01, on ? 1 : 0, 1]) }

        public static func setSaturation(_ value: Int) throws -> [UInt8] {
            guard (0...100).contains(value) else { throw LumaError.message("Saturation must be 0–100.") }
            return frame([0x33, 0x60, 0x09, UInt8(value)])
        }

        public static func setVideo(wholeScreen: Bool, movie: Bool) -> [UInt8] {
            frame([0x33, 0x60, 0x0A, wholeScreen ? 0 : 1, movie ? 1 : 0])
        }
    }

    // MARK: A3 multi-frame payloads

    /// Joins `a3 <index> <17 bytes> <xor>` frames (indexes 0, 1, … then 0xFF) into
    /// the envelope `01 <frame count> <type> <body…>` (`transport.py reassemble_a3`).
    public static func reassembleA3(_ frames: [[UInt8]]) -> [UInt8]? {
        guard !frames.isEmpty else { return nil }
        var envelope: [UInt8] = []
        for (i, f) in frames.enumerated() {
            guard isValidFrame(f), f[0] == 0xA3, f[1] == (i == frames.count - 1 ? 0xFF : UInt8(truncatingIfNeeded: i)) else { return nil }
            envelope += f[2..<19]
        }
        guard envelope.count >= 3, envelope[0] == 0x01, Int(envelope[1]) == frames.count else { return nil }
        return envelope
    }
}

// MARK: - Profiles

/// What Luma may do over Bluetooth for one model and revision. Only the TV
/// backlights sharing the H6099 command grammar are profiled (all "supported"
/// in the source, with owner confirmation issues 445/446/450); other recognised
/// Govee names are listed but not controlled.
public struct GoveeBLEProfile: Equatable, Sendable {
    public enum Feature: String, Sendable, CaseIterable { case power, brightness, color, videoMode, hardwareQuery, dreamView }

    public var model: String
    public var name: String
    public var features: Set<Feature>
    public var wholeMask: UInt16
    public var dreamViewMemberLimit: Int
    /// Why a capability is missing, when the revision isn't known well enough.
    public var limitation: String?

    public func supports(_ feature: Feature) -> Bool { features.contains(feature) }

    /// `pact` comes from the advertisement or a format-2 encryption marker.
    public static func resolve(model: String, pact: GoveeBLE.Pact?) -> GoveeBLEProfile? {
        let full: Set<Feature> = [.power, .brightness, .color, .videoMode, .hardwareQuery, .dreamView]
        switch model.uppercased() {
        case "H6097":
            // `device_profile`: only Pact 1/1 and 2/1 are known to have the full feature set.
            if let pact, [GoveeBLE.Pact(type: 1, code: 1), .init(type: 2, code: 1)].contains(pact) {
                return .init(model: "H6097", name: "TV Backlight 3 Lite", features: full, wholeMask: 0x3FFF, dreamViewMemberLimit: 7)
            }
            return .init(model: "H6097", name: "TV Backlight 3 Lite", features: [.power, .brightness], wholeMask: 0x3FFF, dreamViewMemberLimit: 7,
                         limitation: pact == nil ? "Revision not advertised yet: power and brightness only." : "Unrecognised revision: power and brightness only.")
        case "H6099":
            return .init(model: "H6099", name: "TV Backlight 3 Lite", features: full, wholeMask: 0x3FFF, dreamViewMemberLimit: 7)
        case "H66A0":
            // Its video and status grammars differ from H6099's, so its own video mode isn't built.
            return .init(model: "H66A0", name: "TV Backlight 3 Pro", features: [.power, .brightness, .color, .dreamView], wholeMask: 0x3FFF, dreamViewMemberLimit: 10)
        default:
            return nil
        }
    }
}
