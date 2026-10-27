import Foundation
import Security
import Network
import LumaCore

struct SavedHome: Codable {
    var devices: [LightDevice] = []
    var scenes: [LightScene] = []
    var schedules: [SceneSchedule] = []
    var webhookPort: UInt16 = 8787
    var allowLAN: Bool = false
}

struct HomeStorage {
    let folder: URL
    init(demo: Bool) {
        if let path = ProcessInfo.processInfo.environment["LUMA_DATA_DIR"] { folder = URL(fileURLWithPath: path) }
        else { folder = URL.applicationSupportDirectory.appending(path: demo ? "Luma-Demo" : "Luma") }
    }
    func load() throws -> SavedHome {
        let file = folder.appending(path: "home.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return SavedHome() }
        return try JSONDecoder().decode(SavedHome.self, from: Data(contentsOf: file))
    }
    func save(_ home: SavedHome) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: "home.json")
        // Until first unlock, like the Keychain items: a watch request can launch
        // Luma in the background while the iPhone is locked.
        try JSONEncoder.pretty.encode(home).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum SecretStore {
    static let service = "app.luma.govee"
    static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw error(status) }
        return value
    }
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw error(status) }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw error(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func error(_ status: OSStatus) -> LumaError { .message("Keychain: \((SecCopyErrorMessageString(status, nil) as String?) ?? String(status))") }
}

/// The webhook server's TLS identity: a self-signed key and certificate kept in
/// the Keychain, replaced a week before it expires. Demo mode uses its own
/// label and deletes it when the server stops.
struct WebhookTLS {
    let identity: sec_identity_t
    let certificate: Data
    var fingerprint: String { LocalCertificate.fingerprint(certificate) }
    var pem: String {
        "-----BEGIN CERTIFICATE-----\n\(certificate.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
    }

    static func label(demo: Bool) -> String { demo ? "app.luma.webhook-tls.demo" : "app.luma.webhook-tls" }

    static func load(demo: Bool, now: Date = .now) throws -> WebhookTLS {
        let label = label(demo: demo)
        if !demo, let expires = try SecretStore.read(label + ".expires").flatMap({ ISO8601DateFormatter().date(from: $0) }),
           expires > now.addingTimeInterval(7 * 86_400), let existing = try? find(label) {
            return existing
        }
        try delete(demo: demo)
        let cert = try LocalCertificate(now: now)
        let keyAttributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(cert.privateKey.x963Representation as CFData, keyAttributes as CFDictionary, &error) else {
            throw LumaError.message("Couldn't create the HTTPS key: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
        }
        guard let certificate = SecCertificateCreateWithData(nil, cert.der as CFData) else { throw LumaError.message("Couldn't create the HTTPS certificate.") }
        try check(SecItemAdd([kSecClass as String: kSecClassKey, kSecValueRef as String: key, kSecAttrLabel as String: label,
                              kSecAttrApplicationTag as String: Data(label.utf8),
                              kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil))
        try check(SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate, kSecAttrLabel as String: label,
                              kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil))
        if !demo { try SecretStore.save(ISO8601DateFormatter().string(from: cert.notAfter), account: label + ".expires") }
        return try find(label)
    }

    static func delete(demo: Bool) throws {
        let label = label(demo: demo)
        for query in [[kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(label.utf8)],
                      [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label]] as [[String: Any]] {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStore.error(status) }
        }
        try SecretStore.delete(label + ".expires")
    }

    private static func find(_ label: String) throws -> WebhookTLS {
        var result: CFTypeRef?
        try check(SecItemCopyMatching([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label,
                                       kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &result))
        let certificate = result as! SecCertificate
        var identity: SecIdentity?
        #if os(macOS)
        try check(SecIdentityCreateWithCertificate(nil, certificate, &identity))
        #else
        var found: CFTypeRef?
        try check(SecItemCopyMatching([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label,
                                       kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &found))
        identity = (found as! SecIdentity)
        #endif
        guard let identity, let secIdentity = sec_identity_create(identity) else { throw LumaError.message("The HTTPS identity is incomplete.") }
        return WebhookTLS(identity: secIdentity, certificate: SecCertificateCopyData(certificate) as Data)
    }

    private static func check(_ status: OSStatus) throws { guard status == errSecSuccess else { throw SecretStore.error(status) } }
}
