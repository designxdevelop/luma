import Foundation
import CryptoKit
import Darwin

/// A self-signed P-256 certificate for the local webhook server. Clients trust
/// it by importing `pem` or pinning `spkiPin`. The SAN always covers loopback;
/// in LAN mode it also lists this machine's LAN addresses and hostname.local,
/// and is regenerated when those change.
public struct LocalCertificate: Sendable {
    public let der: Data
    public let privateKey: P256.Signing.PrivateKey
    public let notAfter: Date

    /// 825 days is the longest validity Apple platforms accept for TLS server certificates.
    public static let validityDays = 825

    public init(now: Date = .now, commonName: String = "Luma local webhooks", extraNames: [String] = []) throws {
        let key = P256.Signing.PrivateKey()
        let notBefore = now.addingTimeInterval(-3600)
        let notAfter = now.addingTimeInterval(TimeInterval(Self.validityDays - 1) * 86_400)
        var serial = (0..<16).map { _ in UInt8.random(in: 0...255) }
        serial[0] = (serial[0] & 0x7F) | 0x01   // positive, non-zero, no padding needed
        let name = DER.sequence(DER.set(DER.sequence(DER.oid("2.5.4.3") + DER.tlv(0x0C, Data(commonName.utf8)))))
        let algorithm = DER.sequence(DER.oid("1.2.840.10045.4.3.2"))   // ecdsa-with-SHA256
        let publicKey = DER.sequence(DER.sequence(DER.oid("1.2.840.10045.2.1") + DER.oid("1.2.840.10045.3.1.7"))
                                     + DER.bitString(key.publicKey.x963Representation))
        let san = DER.sequence((["localhost", "127.0.0.1", "::1"] + extraNames).map(Self.generalName).reduce(Data(), +))
        let extensions = DER.sequence(
            DER.sequence(DER.oid("2.5.29.17") + DER.octetString(san))
            + DER.sequence(DER.oid("2.5.29.37") + DER.octetString(DER.sequence(DER.oid("1.3.6.1.5.5.7.3.1"))))   // serverAuth
            + DER.sequence(DER.oid("2.5.29.19") + DER.boolean(true) + DER.octetString(DER.sequence(Data())))     // not a CA
            + DER.sequence(DER.oid("2.5.29.15") + DER.boolean(true) + DER.octetString(Data([0x03, 0x02, 0x07, 0x80])))) // digitalSignature
        let tbs = DER.sequence(
            DER.tlv(0xA0, DER.integer(Data([2])))
            + DER.integer(Data(serial)) + algorithm + name
            + DER.sequence(DER.time(notBefore) + DER.time(notAfter))
            + name + publicKey
            + DER.tlv(0xA3, extensions))
        let signature = try key.signature(for: tbs).derRepresentation
        der = DER.sequence(tbs + algorithm + DER.bitString(signature))
        privateKey = key
        self.notAfter = notAfter
    }

    public init(der: Data, privateKey: P256.Signing.PrivateKey, notAfter: Date) {
        self.der = der; self.privateKey = privateKey; self.notAfter = notAfter
    }

    /// An IP literal becomes an iPAddress name, anything else a dNSName.
    static func generalName(_ name: String) -> Data {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, name, &v4) == 1 { return DER.tlv(0x87, withUnsafeBytes(of: &v4) { Data($0) }) }
        if inet_pton(AF_INET6, name, &v6) == 1 { return DER.tlv(0x87, withUnsafeBytes(of: &v6) { Data($0) }) }
        return DER.tlv(0x82, Data(name.utf8))
    }

    /// This machine's LAN addresses (up, non-loopback, non-link-local) and
    /// hostname.local, sorted so an unchanged network gives the same list.
    public static func lanNames() -> [String] {
        var names = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(list) }
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = pointer.pointee
                guard let address = entry.ifa_addr, entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
                let family = Int32(address.pointee.sa_family)
                guard family == AF_INET || family == AF_INET6 else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if text.hasPrefix("169.254.") || text.lowercased().hasPrefix("fe80") { continue }
                names.insert(text)
            }
        }
        var hostname = [CChar](repeating: 0, count: 256)
        if gethostname(&hostname, hostname.count) == 0 {
            var name = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !name.isEmpty, name != "localhost" {
                if !name.contains(".") { name += ".local" }
                names.insert(name)
            }
        }
        return names.sorted()
    }

    /// curl's --pinnedpubkey form: sha256// + base64 SHA-256 of the SubjectPublicKeyInfo.
    public static func spkiPin(_ publicKey: P256.Signing.PublicKey) -> String {
        "sha256//" + Data(SHA256.hash(data: publicKey.derRepresentation)).base64EncodedString()
    }

    /// SHA-256 of the certificate, as colon-separated hex (what `openssl x509 -fingerprint -sha256` prints).
    public var fingerprint: String { Self.fingerprint(der) }
    public static func fingerprint(_ der: Data) -> String { SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":") }

    public var pem: String {
        let lines = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(lines)\n-----END CERTIFICATE-----\n"
    }
}

/// The few DER encodings an X.509 certificate needs.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 128 { out.append(UInt8(n)) }
        else {
            let bytes = withUnsafeBytes(of: UInt32(n).bigEndian, Array.init).drop { $0 == 0 }
            out.append(0x80 | UInt8(bytes.count)); out.append(contentsOf: bytes)
        }
        return out + content
    }
    static func sequence(_ content: Data) -> Data { tlv(0x30, content) }
    static func set(_ content: Data) -> Data { tlv(0x31, content) }
    static func octetString(_ content: Data) -> Data { tlv(0x04, content) }
    static func bitString(_ content: Data) -> Data { tlv(0x03, Data([0]) + content) }
    static func boolean(_ value: Bool) -> Data { tlv(0x01, Data([value ? 0xFF : 0])) }
    static func integer(_ bytes: Data) -> Data { tlv(0x02, bytes.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + bytes : bytes) }
    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        var body = Data([UInt8(parts[0] * 40 + parts[1])])
        for var value in parts.dropFirst(2) {
            var chunk = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 { chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0); value >>= 7 }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }
    /// UTCTime through 2049, GeneralizedTime after, as RFC 5280 requires.
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        formatter.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tlv(year < 2050 ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
    }
}
