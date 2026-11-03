import Foundation
import Security
import Network
import CryptoKit
import LumaCore

struct SavedHome: Codable {
    var devices: [LightDevice] = []
    var scenes: [LightScene] = []
    var schedules: [SceneSchedule] = []
    var webhookPort: UInt16 = 8787
    var allowLAN: Bool = false
    /// Optional so homes saved before drafts existed still decode. Keyed by the TV light's ID.
    var dreamViewDrafts: [String: DreamViewDraft]?
    /// Last signed-in Govee Home import (names, counts, times; no secrets), so the
    /// DreamView card and schedule conflicts survive a relaunch. Optional for old homes.
    var goveeHomeGroups: [GoveeHomeImport.HomeGroup]?
    var goveeHomeAutomations: [GoveeHomeImport.Automation]?
}

/// A portable home backup. Versioned so later formats can refuse or migrate older files.
struct HomeBackup: Codable, Equatable {
    static let formatName = "luma-home-backup"
    static let currentVersion = 1
    struct Light: Codable, Equatable { var id: String; var sku: String; var customName: String?; var room: String }
    struct Result: Equatable { var scenes = 0, schedules = 0, lightsUpdated = 0, lightsNotFound = 0, scenesWithMissingLights = 0 }
    var format = formatName
    var version = currentVersion
    var exportedAt: Date
    var scenes: [LightScene]
    var schedules: [SceneSchedule]
    var lights: [Light]
    var dreamViewDrafts: [String: DreamViewDraft]?

    static func decode(_ data: Data) throws -> HomeBackup {
        guard data.count <= 8 * 1024 * 1024 else { throw LumaError.message("That backup is too large.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(HomeBackup.self, from: data) }
        catch { throw LumaError.message("That file isn't a Luma home backup.") }
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder.pretty; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
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
    /// A safety copy beside home.json (for example before a restore), replaced each time.
    func saveCopy(_ home: SavedHome, named name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: name)
        try JSONEncoder.pretty.encode(home).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum SecretStore {
    static let service = "app.luma.govee"
    static func read(_ account: String) throws -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        var result: CFTypeRef?
        query[kSecAttrSynchronizable as String] = account == "govee-api-key"
        var migrating = false
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound, account == "govee-api-key" {
            query[kSecAttrSynchronizable as String] = false
            migrating = true
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw error(status) }
        // Copy to the synchronizable class before removing the legacy item.
        // A failed copy leaves the original usable and recoverable.
        if migrating { try? save(value, account: account) }
        return value
    }
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: account == "govee-api-key"]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = account == "govee-api-key" ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw error(status) }
        if account == "govee-api-key" {
            let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
            let removal = SecItemDelete(legacy as CFDictionary)
            guard removal == errSecSuccess || removal == errSecItemNotFound else { throw error(removal) }
        }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: account == "govee-api-key" ? kSecAttrSynchronizableAny : false] as CFDictionary)
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
    var spkiPin: String? {
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData), let key = SecCertificateCopyKey(cert),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?, let publicKey = try? P256.Signing.PublicKey(x963Representation: raw) else { return nil }
        return LocalCertificate.spkiPin(publicKey)
    }
    var pem: String {
        "-----BEGIN CERTIFICATE-----\n\(certificate.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
    }

    static func label(demo: Bool) -> String { demo ? "app.luma.webhook-tls.demo" : "app.luma.webhook-tls" }

    /// `extraNames` (LAN addresses, hostname.local) must match the stored certificate's, or it is replaced.
    /// `label` gives another server (schedule sync) its own identity, so webhook certificate changes never break pairing.
    static func load(demo: Bool, extraNames: [String] = [], now: Date = .now, label custom: String? = nil) throws -> WebhookTLS {
        let label = custom ?? label(demo: demo)
        let names = extraNames.joined(separator: ",")
        if !demo, let expires = try SecretStore.read(label + ".expires").flatMap({ ISO8601DateFormatter().date(from: $0) }),
           expires > now.addingTimeInterval(7 * 86_400), (try SecretStore.read(label + ".names")) ?? "" == names, let existing = try? find(label) {
            return existing
        }
        try delete(demo: demo, label: custom)
        let cert = try LocalCertificate(now: now, extraNames: extraNames)
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
        if !demo {
            try SecretStore.save(ISO8601DateFormatter().string(from: cert.notAfter), account: label + ".expires")
            try SecretStore.save(names, account: label + ".names")
        }
        return try find(label)
    }

    static func delete(demo: Bool, label custom: String? = nil) throws {
        let label = custom ?? label(demo: demo)
        for query in [[kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(label.utf8)],
                      [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label]] as [[String: Any]] {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStore.error(status) }
        }
        try SecretStore.delete(label + ".expires")
        try SecretStore.delete(label + ".names")
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
