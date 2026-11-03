import CommonCrypto
import CryptoKit
import Foundation

/// Govee's Bluetooth link encryption, ported from ha-govee-led-ble @ b845c59
/// (`govee_encryption/__init__.py`, `session.py`, `govee_encryption.ksy`).
///
/// V1 is the vendor's unauthenticated AES-ECB scheme with an RC4 tail; V2 is
/// AES-GCM with a per-device key. The keys below are vendor-global constants
/// shipped in every Govee Home install, not per-device secrets; the session keys
/// they protect are never logged or persisted.
enum GoveeBLECrypto {
    static let communicationKey: [UInt8] = hex("4d616b696e674c696665536d61727465")
    static let handshakeKey: [UInt8] = hex("fc03783c7c42cb83e202a1643648aff6")
    static let deviceKey: [UInt8] = hex("ae028b630bae6ecc4bff1b249e22f955")
    static let tagLength = 16
    /// ATT payload a V2 handshake reply needs (MTU 53 minus 3).
    static let minimumV2WriteLength = 50

    /// Constants only; untrusted text goes through `parseHex`.
    static func hex(_ s: String) -> [UInt8] { parseHex(s)! }

    static func parseHex(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []; var it = s.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard a.isASCII, b.isASCII, let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// Whole 16-byte blocks through AES-ECB, any remainder through a fresh RC4 stream.
    static func v1(_ data: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        let boundary = data.count / 16 * 16
        var out = cc(CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), Array(data[..<boundary]), key: key, encrypt: encrypt)
        if boundary < data.count { out += cc(CCAlgorithm(kCCAlgorithmRC4), 0, Array(data[boundary...]), key: key, encrypt: true) }
        return out
    }

    static func aesECB(_ block: [UInt8], key: [UInt8]) -> [UInt8] { cc(CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), block, key: key, encrypt: true) }

    private static func cc(_ algorithm: CCAlgorithm, _ options: CCOptions, _ data: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algorithm, options, key, key.count, nil,
                             data, data.count, &out, out.count, &moved)
        precondition(status == kCCSuccess, "CommonCrypto rejected fixed-size input")
        return Array(out[..<moved])
    }

    /// `E7 <opcode> <17 random bytes> <xor>` under the shared key.
    static func v1Handshake(opcode: UInt8, random: [UInt8]) -> [UInt8] {
        let body = [0xE7, opcode] + random
        return v1(body + [GoveeBLE.checksum(body)], key: communicationKey, encrypt: true)
    }

    /// The reply's opcode and 16-byte body, or nil when it isn't a valid handshake frame.
    static func parseV1Handshake(_ frame: [UInt8]) -> (opcode: UInt8, body: [UInt8])? {
        guard frame.count == 20 else { return nil }
        let plain = v1(frame, key: communicationKey, encrypt: false)
        guard plain[0] == 0xE7, plain[1] == 1 || plain[1] == 2, GoveeBLE.checksum(plain) == 0 else { return nil }
        return (plain[1], Array(plain[2..<18]))
    }

    static func v2Request(clientIV: [UInt8], nonce: [UInt8]) throws -> [UInt8] {
        let header = [0xE7, 0x11, 0x01] + nonce + [UInt8(tagLength)]
        return header + (try gcmSeal(clientIV, key: handshakeKey, nonce: nonce, aad: header))
    }

    /// Client IV from a captured request (for offline capture decoding).
    static func parseV2Request(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count == 40, frame[0] == 0xE7, frame[1] == 0x11, frame[2] == 0x01, frame[15] == UInt8(tagLength) else { return nil }
        return try? gcmOpen(Array(frame[16...]), key: handshakeKey, nonce: Array(frame[3..<15]), aad: Array(frame[..<16]))
    }

    struct V2Identity: Equatable, Sendable { var deviceIV: [UInt8]; var sku: String; var mac: [UInt8]; var key: [UInt8] }

    static func parseV2Response(_ frame: [UInt8]) -> V2Identity? {
        guard frame.count == 50, frame[0] == 0xE7, frame[1] == 0x11, frame[2] == 0x00,
              let plain = try? gcmOpen(Array(frame[15...]), key: handshakeKey, nonce: Array(frame[3..<15]), aad: Array(frame[..<15])),
              plain.count == 19 else { return nil }
        let info = Array(plain[8..<19])
        return V2Identity(deviceIV: Array(plain[..<8]), sku: String(decoding: plain[8..<13], as: UTF8.self), mac: Array(plain[13..<19]),
                          key: aesECB(info + [UInt8](repeating: 0, count: 16 - info.count), key: deviceKey))
    }

    static func seal(_ plain: [UInt8], iv: [UInt8], key: [UInt8], counter: UInt32) throws -> [UInt8] {
        let ctr = withUnsafeBytes(of: counter.bigEndian, Array.init)
        return ctr + (try gcmSeal(plain, key: key, nonce: iv + ctr, aad: ctr))
    }

    static func unseal(_ frame: [UInt8], iv: [UInt8], key: [UInt8]) -> (counter: UInt32, plain: [UInt8])? {
        guard frame.count >= 4 + tagLength else { return nil }
        let ctr = Array(frame[..<4])
        guard let plain = try? gcmOpen(Array(frame[4...]), key: key, nonce: iv + ctr, aad: ctr) else { return nil }
        return (ctr.reduce(0) { $0 << 8 | UInt32($1) }, plain)
    }

    private static func gcmSeal(_ plain: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return Array(box.ciphertext) + Array(box.tag)
    }

    private static func gcmOpen(_ sealed: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        guard sealed.count >= tagLength else { throw GoveeBLESession.Failure.invalidFrame }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(tagLength), tag: sealed.suffix(tagLength))
        return Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad))
    }
}

/// Encryption for one connection, transport-agnostic and fail-closed. The
/// CoreBluetooth layer feeds it the marker read, notifications and the write
/// length, and sends what it returns. Selection rules follow `session.py`
/// exactly: positive encryption evidence (advertised flag, a marker, or an
/// earlier encrypted connection) never falls back to plaintext.
public struct GoveeBLESession: Sendable {
    public enum Marker: Sendable, Equatable {
        /// The device has no `2b12` characteristic.
        case absent
        case value([UInt8])
        case readFailed
    }

    /// Fixed reasons: never carry keys, addresses or raw bytes.
    public enum Failure: String, Error, Sendable {
        case selectionFailed, previousSelectionFailed, notSelected, notReady
        case v2NeedsLargerWrites, handshakeRejected, counterExhausted, invalidFrame
    }

    public enum Event: Equatable, Sendable {
        /// Send this handshake frame next.
        case write([UInt8])
        case ready
        /// A decrypted 20-byte notification.
        case packet([UInt8])
        /// A duplicate, replayed or undecryptable frame, dropped.
        case ignored
    }

    public private(set) var version = 0
    public private(set) var requiredVersion = 0
    public private(set) var ready = false
    public private(set) var markerPact: GoveeBLE.Pact?
    /// From a V2 handshake: the model and MAC the device reports for itself.
    public private(set) var deviceSKU: String?
    public private(set) var deviceMAC: [UInt8]?
    public private(set) var rejectedFrames = 0
    private var selectionFailed = false
    private var awaiting: UInt8?
    private var key: [UInt8]?
    private var clientIV: [UInt8]?
    private var deviceIV: [UInt8]?
    private var counter: UInt32 = 2
    private var received: UInt32 = 0
    private var maxWrite = 0
    /// Injected for tests; otherwise the system CSPRNG.
    var random: @Sendable (Int) -> [UInt8] = { n in (0..<n).map { _ in UInt8.random(in: .min ... .max) } }

    public init() {}

    public var encrypted: Bool { ready && version != 0 }

    /// Forget this connection. The encryption requirement survives, as in the source.
    public mutating func reset() {
        ready = false; markerPact = nil; awaiting = nil; key = nil; clientIV = nil; deviceIV = nil
        counter = 2; received = 0; maxWrite = 0; deviceSKU = nil; deviceMAC = nil
    }

    /// Choose plaintext, V1 or V2 from what the device shows, without probing.
    public mutating func select(marker: Marker, advertisedEncryption: Bool, plaintextEvidence: Bool = false) throws {
        reset()
        version = 0
        if advertisedEncryption && requiredVersion == 0 { requiredVersion = 1 }
        func fail(_ reason: Failure = .selectionFailed) -> Failure { selectionFailed = true; reset(); return reason }
        switch marker {
        case .absent:
            if selectionFailed { throw fail(.previousSelectionFailed) }
            version = requiredVersion != 0 ? requiredVersion : (advertisedEncryption ? 1 : 0)
        case .value(let bytes):
            guard let parsed = Self.parseMarker(bytes) else {
                if !plaintextEvidence || advertisedEncryption || requiredVersion != 0 { throw fail() }
                selectionFailed = false; ready = true
                return
            }
            // Version zero means plaintext only without earlier encryption evidence.
            version = parsed.version != 0 ? parsed.version : requiredVersion
            markerPact = parsed.pact
            selectionFailed = false
        case .readFailed:
            if !plaintextEvidence || advertisedEncryption || requiredVersion != 0 { throw fail() }
            selectionFailed = false; ready = true
            return
        }
        if version != 0 { requiredVersion = version }
        ready = version == 0
    }

    /// `format version [flag pactType(be16) pactCode if format 2] tail…`
    static func parseMarker(_ b: [UInt8]) -> (version: Int, pact: GoveeBLE.Pact?)? {
        guard b.count >= 2, b[0] == 1 || b[0] == 2, b[1] <= 2 else { return nil }
        if b[0] == 2 {
            guard b.count >= 6 else { return nil }
            return (Int(b[1]), .init(type: Int(b[3]) << 8 | Int(b[4]), code: Int(b[5])))
        }
        return (Int(b[1]), nil)
    }

    /// The first handshake frame, or nil when the link is plaintext and ready.
    /// `maxWriteLength` is the ATT payload for writes without response.
    public mutating func startNegotiation(maxWriteLength: Int) throws -> [UInt8]? {
        if ready && version == 0 { return nil }
        maxWrite = maxWriteLength
        switch version {
        case 1:
            awaiting = 1
            return GoveeBLECrypto.v1Handshake(opcode: 1, random: random(17))
        case 2:
            guard maxWriteLength >= GoveeBLECrypto.minimumV2WriteLength else { reset(); throw Failure.v2NeedsLargerWrites }
            let iv = random(8)
            clientIV = iv; awaiting = 0x11
            return try GoveeBLECrypto.v2Request(clientIV: iv, nonce: random(12))
        default:
            throw Failure.notSelected
        }
    }

    public mutating func receive(_ frame: [UInt8]) throws -> Event {
        guard ready else {
            guard let expected = awaiting else { return .ignored }
            if version == 1 {
                guard let reply = GoveeBLECrypto.parseV1Handshake(frame) else { rejectedFrames += 1; reset(); throw Failure.handshakeRejected }
                // A duplicate key reply is not confirmation of the next phase.
                guard reply.opcode == expected else { rejectedFrames += 1; return .ignored }
                if expected == 1 {
                    key = reply.body; awaiting = 2
                    return .write(GoveeBLECrypto.v1Handshake(opcode: 2, random: random(17)))
                }
                awaiting = nil; ready = true
                return .ready
            }
            guard let identity = GoveeBLECrypto.parseV2Response(frame) else { rejectedFrames += 1; reset(); throw Failure.handshakeRejected }
            deviceIV = identity.deviceIV; key = identity.key; deviceSKU = identity.sku; deviceMAC = identity.mac
            awaiting = nil; ready = true
            return .ready
        }
        switch version {
        case 0: return .packet(frame)
        case 1:
            guard let key else { throw Failure.notReady }
            let plain = GoveeBLECrypto.v1(frame, key: key, encrypt: false)
            guard plain.count == 20, GoveeBLE.checksum(plain) == 0 else { rejectedFrames += 1; return .ignored }
            return .packet(plain)
        default:
            guard let key, let deviceIV else { throw Failure.notReady }
            guard let opened = GoveeBLECrypto.unseal(frame, iv: deviceIV, key: key), opened.counter > received else { rejectedFrames += 1; return .ignored }
            received = opened.counter
            return .packet(opened.plain)
        }
    }

    public mutating func encode(_ packet: [UInt8]) throws -> [UInt8] {
        guard ready else { throw Failure.notReady }
        switch version {
        case 0: return packet
        case 1:
            guard let key else { throw Failure.notReady }
            return GoveeBLECrypto.v1(packet, key: key, encrypt: true)
        default:
            guard let key, let clientIV else { throw Failure.notReady }
            guard packet.count + 20 <= maxWrite else { throw Failure.v2NeedsLargerWrites }
            guard counter < .max else { throw Failure.counterExhausted }
            defer { counter += 1 }
            return try GoveeBLECrypto.seal(packet, iv: clientIV, key: key, counter: counter)
        }
    }
}
